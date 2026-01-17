//
//  NotmuchBackend.swift
//  Durian
//
//  notmuch mail backend using durian CLI IPC
//

import Foundation
import Combine
import AppKit

// MARK: - JSON Models for durian

struct DurianRequest: Encodable {
    let cmd: String
    var query: String?
    var limit: Int?
    var thread: String?  // thread_id for show command
    var tags: String?
}

struct DurianResponse: Decodable {
    let ok: Bool
    let error: String?
    let results: [NotmuchMailResult]?
    let mail: NotmuchMailContent?
    let thread: ThreadContent?  // New: full thread with all messages
}

struct NotmuchMailResult: Decodable {
    let thread_id: String
    let subject: String
    let from: String
    let date: String
    let timestamp: Int
    let tags: String
}

struct NotmuchMailContent: Decodable {
    let from: String
    let to: String
    let cc: String?
    let subject: String
    let date: String
    let message_id: String?
    let in_reply_to: String?
    let references: String?
    let body: String
    let html: String?
    let attachments: [String]?
}

// MARK: - Thread Models (from CLI show command)

/// Represents a complete email thread with all messages
struct ThreadContent: Decodable {
    let thread_id: String
    let subject: String
    let messages: [ThreadMessage]
}

/// Represents a single message within a thread
struct ThreadMessage: Decodable, Identifiable, Equatable {
    let id: String
    let from: String
    let to: String?
    let cc: String?
    let date: String
    let timestamp: Int
    let body: String
    let html: String?
    let attachments: [String]?
    let tags: [String]?
}

// MARK: - Notmuch Backend

@MainActor
class NotmuchBackend: ObservableObject {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // IPC synchronization - only one request at a time to prevent response mixing
    private let requestSemaphore = DispatchSemaphore(value: 1)
    
    // MARK: - Published State (Protocol conformance)
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var folders: [MailFolder] = []
    @Published var emails: [MailMessage] = []
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""
    
    // Internal state
    private var currentQuery = "tag:inbox"
    
    // Cancellation support for prefetch
    private var prefetchTask: Task<Void, Never>?
    // Use nonisolated(unsafe) to allow access from background thread
    // This is safe because we only set it from MainActor and read from background
    nonisolated(unsafe) private var shouldCancelPrefetch = false
    
    // Thread cache - persists loaded thread messages across search/tag changes
    private var threadCache: [String: CachedThread] = [:]
    private let maxCacheSize = 200
    
    private struct CachedThread {
        let messages: [ThreadMessage]
        let timestamp: Date
    }
    
    init() {
        // Set default tags as folders
        folders = MailFolder.defaultNotmuchTags
    }
    
    // MARK: - Protocol: Connection
    
    /// Resolve durian CLI path: check ~/.local/bin/durian first, then search PATH
    private func resolveDurianPath() -> String? {
        let homePath = "\(NSHomeDirectory())/.local/bin/durian"
        if FileManager.default.fileExists(atPath: homePath) {
            return homePath
        }
        
        // Search in standard PATHs if not in home local bin
        let searchPaths = ["/usr/local/bin/durian", "/opt/homebrew/bin/durian"]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }

    func connect() async {
        guard let durianPath = resolveDurianPath() else {
            connectionStatus = "durian CLI not found in ~/.local/bin or /usr/local/bin"
            print("NOTMUCH ERROR: \(connectionStatus)")
            return
        }
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: durianPath)
        process?.arguments = ["serve"]  // Start JSON protocol server
        
        // Set PATH to include Homebrew bin directories so durian can find notmuch
        var environment = ProcessInfo.processInfo.environment
        let homebrewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        if let existingPath = environment["PATH"] {
            environment["PATH"] = "\(homebrewPaths):\(existingPath)"
        } else {
            environment["PATH"] = "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process?.environment = environment
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        process?.standardInput = inPipe
        process?.standardOutput = outPipe
        process?.standardError = FileHandle.nullDevice
        
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        
        do {
            try process?.run()
            isConnected = true
            connectionStatus = "Connected to notmuch"
            print("NOTMUCH Started durian process: \(durianPath)")
            
            // Initial load
            await selectFolder("inbox")
        } catch {
            connectionStatus = "Failed: \(error.localizedDescription)"
            print("NOTMUCH ERROR: \(error)")
        }
    }
    
    func disconnect() async {
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        isConnected = false
        connectionStatus = "Disconnected"
        print("NOTMUCH Disconnected")
    }
    
    // MARK: - Protocol: Folder/Tag Selection
    
    func selectFolder(_ name: String) async {
        // Cancel any running prefetch to free the semaphore
        shouldCancelPrefetch = true
        prefetchTask?.cancel()
        prefetchTask = nil
        
        // Use ProfileManager to build query from folder config with account filter
        currentQuery = ProfileManager.shared.buildQuery(folderName: name)
        print("NOTMUCH selectFolder: \(currentQuery)")
        await search(currentQuery)
    }
    
    // MARK: - Protocol: Email Operations
    
    /// Protocol conformance: fetch email body (user-initiated, not cancellable)
    func fetchEmailBody(id: String) async {
        await fetchEmailBodyInternal(id: id, isPrefetch: false)
    }
    
    /// Internal fetch email body with prefetch option
    /// - Parameters:
    ///   - id: The thread/email ID
    ///   - isPrefetch: If true, this request can be cancelled when shouldCancelPrefetch is set
    private func fetchEmailBodyInternal(id: String, isPrefetch: Bool) async {
        // Find and update email state to loading
        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].bodyState = .loading
        }
        
        // Use thread_id directly - durian CLI returns full thread with all messages
        let request = DurianRequest(cmd: "show", thread: id)
        
        guard let response = await sendCommand(request, cancelOnPrefetchAbort: isPrefetch),
              response.ok,
              let thread = response.thread else {
            // Check if this was a cancellation vs real failure
            // Only treat as cancellation if this is a prefetch request
            if let index = emails.firstIndex(where: { $0.id == id }) {
                if isPrefetch && (shouldCancelPrefetch || Task.isCancelled) {
                    emails[index].bodyState = .notLoaded
                    print("NOTMUCH Prefetch cancelled for \(id), reset to notLoaded")
                } else if !isPrefetch {
                    // User-initiated request failed - mark as failed
                    emails[index].bodyState = .failed(message: "Failed to load")
                    print("NOTMUCH Body fetch failed for \(id)")
                } else {
                    // Prefetch failed but not due to cancellation
                    emails[index].bodyState = .notLoaded
                    print("NOTMUCH Prefetch failed for \(id), reset to notLoaded")
                }
            }
            return
        }
        
        // Update email with thread messages
        if let index = emails.firstIndex(where: { $0.id == id }) {
            // Store all thread messages for display
            emails[index].threadMessages = thread.messages
            
            // For backward compatibility: use newest message for single-email fields
            if let newestMessage = thread.messages.last {
                emails[index].body = newestMessage.body
                emails[index].htmlBody = newestMessage.html
                emails[index].to = newestMessage.to
                emails[index].cc = newestMessage.cc
            }
            
            // Use combined body for state (for preview purposes)
            let combinedBody = thread.messages.map { $0.body }.joined(separator: "\n\n---\n\n")
            emails[index].bodyState = .loaded(body: combinedBody, attributedBody: nil)
            print("NOTMUCH Loaded thread \(id) with \(thread.messages.count) messages")
            
            // Cache the thread messages
            cacheThread(id: id, messages: thread.messages)
        }
    }
    
    // MARK: - Thread Cache
    
    private func cacheThread(id: String, messages: [ThreadMessage]) {
        // Add to cache
        threadCache[id] = CachedThread(messages: messages, timestamp: Date())
        
        // Cleanup if cache is too large (remove oldest entries)
        if threadCache.count > maxCacheSize {
            let sortedKeys = threadCache.keys.sorted { 
                threadCache[$0]!.timestamp < threadCache[$1]!.timestamp 
            }
            let keysToRemove = sortedKeys.prefix(threadCache.count - maxCacheSize)
            for key in keysToRemove {
                threadCache.removeValue(forKey: key)
            }
            print("NOTMUCH Cache cleanup: removed \(keysToRemove.count) old entries")
        }
    }
    
    private func restoreCachedThreads() {
        var restoredCount = 0
        for (index, email) in emails.enumerated() {
            if let cached = threadCache[email.id] {
                emails[index].threadMessages = cached.messages
                // Use combined body for state
                let combinedBody = cached.messages.map { $0.body }.joined(separator: "\n\n---\n\n")
                emails[index].body = cached.messages.last?.body
                emails[index].htmlBody = cached.messages.last?.html
                emails[index].bodyState = .loaded(body: combinedBody, attributedBody: nil)
                restoredCount += 1
            }
        }
        if restoredCount > 0 {
            print("NOTMUCH Restored \(restoredCount) threads from cache")
        }
    }
    
    func markAsRead(id: String) async {
        let success = await tag(query: "thread:\(id)", tags: "-unread")
        if success {
            if let index = emails.firstIndex(where: { $0.id == id }) {
                emails[index].isRead = true
            }
        }
    }
    
    func markAsUnread(id: String) async {
        let success = await tag(query: "thread:\(id)", tags: "+unread")
        if success {
            if let index = emails.firstIndex(where: { $0.id == id }) {
                emails[index].isRead = false
            }
        }
    }
    
    func toggleRead(id: String) async {
        guard let index = emails.firstIndex(where: { $0.id == id }) else { return }
        if emails[index].isRead {
            await markAsUnread(id: id)
        } else {
            await markAsRead(id: id)
        }
    }
    
    func togglePin(id: String) async {
        guard let index = emails.firstIndex(where: { $0.id == id }) else { return }
        let isCurrentlyPinned = emails[index].isPinned
        
        let tags = isCurrentlyPinned ? "-flagged" : "+flagged"
        let success = await tag(query: "thread:\(id)", tags: tags)
        
        if success {
            emails[index].isPinned = !isCurrentlyPinned
            print("NOTMUCH Toggled pin for \(id): \(!isCurrentlyPinned)")
        }
    }
    
    func deleteMessage(id: String) async throws {
        let success = await tag(query: "thread:\(id)", tags: "+deleted -inbox -unread")
        if success {
            emails.removeAll { $0.id == id }
        }
    }
    
    // MARK: - Protocol: Reload
    
    func reload() async {
        await search(currentQuery)
    }
    
    // MARK: - Prefetching
    
    /// Prefetch bodies for first N emails (called after search)
    /// Now runs sequentially to avoid semaphore blocking, with cancellation support
    private func prefetchInitialBodiesInternal(count: Int = 5) async {
        let emailsToFetch = emails.prefix(count).filter { email in
            if case .notLoaded = email.bodyState { return true }
            return false
        }
        
        guard !emailsToFetch.isEmpty else { return }
        
        print("NOTMUCH Prefetching \(emailsToFetch.count) bodies...")
        
        // Sequential fetching with cancellation check
        for email in emailsToFetch {
            // Check if we should cancel (new search started)
            if shouldCancelPrefetch || Task.isCancelled {
                print("NOTMUCH Prefetch cancelled")
                return
            }
            await fetchEmailBodyInternal(id: email.id, isPrefetch: true)
        }
    }
    
    /// Start prefetch as a cancellable task
    func startPrefetch(count: Int = 5) {
        shouldCancelPrefetch = false
        prefetchTask = Task {
            await prefetchInitialBodiesInternal(count: count)
        }
    }
    
    // MARK: - Internal: Search
    
    private func search(_ query: String, limit: Int = 200) async {
        await restartProcessIfNeeded()
        
        isLoadingEmails = true
        loadingProgress = "Searching..."
        
        let request = DurianRequest(cmd: "search", query: query, limit: limit)
        
        guard let response = await sendCommand(request) else {
            isLoadingEmails = false
            loadingProgress = "Search failed"
            return
        }
        
        if !response.ok {
            print("NOTMUCH ERROR: \(response.error ?? "unknown")")
            isLoadingEmails = false
            loadingProgress = "Error: \(response.error ?? "unknown")"
            return
        }
        
        // Reset prefetch cancellation flag before updating emails
        // This allows onAppear/selection requests to proceed immediately
        shouldCancelPrefetch = false
        
        // Convert to MailMessage
        let results = response.results ?? []
        emails = results.map { mail in
            MailMessage(
                threadId: mail.thread_id,
                subject: mail.subject,
                from: mail.from,
                date: mail.date,
                timestamp: mail.timestamp,
                tags: mail.tags
            )
        }
        
        // Restore cached threads before UI update
        restoreCachedThreads()
        
        print("NOTMUCH Search returned \(emails.count) emails")
        isLoadingEmails = false
        loadingProgress = ""
        
        // Start prefetch after short delay to let UI update first
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            startPrefetch(count: 5)
        }
    }
    
    // MARK: - Public: Global Search (for SearchPopup)
    
    /// Search all emails without affecting the main emails array
    /// Used by SearchPopupView for global search
    func searchAll(query: String, limit: Int = 10) async -> [MailMessage] {
        await restartProcessIfNeeded()
        
        let request = DurianRequest(cmd: "search", query: query, limit: limit)
        
        guard let response = await sendCommand(request) else {
            return []
        }
        
        guard response.ok, let results = response.results else {
            return []
        }
        
        // Convert to MailMessage without modifying self.emails
        return results.map { mail in
            MailMessage(
                threadId: mail.thread_id,
                subject: mail.subject,
                from: mail.from,
                date: mail.date,
                timestamp: mail.timestamp,
                tags: mail.tags
            )
        }
    }
    
    // MARK: - Internal: Tag
    
    private func tag(query: String, tags: String) async -> Bool {
        await restartProcessIfNeeded()
        
        let request = DurianRequest(cmd: "tag", query: query, tags: tags)
        
        guard let response = await sendCommand(request) else {
            return false
        }
        
        if response.ok {
            print("NOTMUCH Tagged \(query) with \(tags)")
            return true
        } else {
            print("NOTMUCH Tag error: \(response.error ?? "unknown")")
            return false
        }
    }
    
    // MARK: - Internal: IPC
    
    private func restartProcessIfNeeded() async {
        if process == nil || !(process?.isRunning ?? false) {
            print("NOTMUCH Restarting process...")
            await connect()
        }
    }
    
    /// Send a command to the durian process
    /// - Parameters:
    ///   - request: The request to send
    ///   - cancelOnPrefetchAbort: If true, this request will be cancelled when shouldCancelPrefetch is set
    private func sendCommand(_ request: DurianRequest, cancelOnPrefetchAbort: Bool = false) async -> DurianResponse? {
        guard let stdin = stdin, let stdout = stdout else {
            print("NOTMUCH ERROR: No stdin/stdout")
            return nil
        }
        
        // Ensure we are connected
        await restartProcessIfNeeded()
        
        do {
            var data = try encoder.encode(request)
            data.append(contentsOf: "\n".utf8)
            
            // Only one request at a time to prevent response mixing
            // We use the semaphore even with async/await to guarantee request-response order
            let waitResult = self.requestSemaphore.wait(timeout: .now() + 30.0)
            guard waitResult == .success else {
                print("NOTMUCH ERROR: Timed out waiting for request semaphore")
                return nil
            }
            defer { self.requestSemaphore.signal() }
            
            // Write request
            try stdin.write(contentsOf: data)
            
            // Use bytes.lines for efficient, modern async reading
            // This is much safer than manual loops and sleeps
            let lineStream = stdout.bytes.lines
            
            for try await line in lineStream {
                if line.isEmpty { continue }
                
                guard let responseData = line.data(using: .utf8) else {
                    print("NOTMUCH ERROR: Failed to convert line to data")
                    return nil
                }
                
                do {
                    let response = try self.decoder.decode(DurianResponse.self, from: responseData)
                    return response
                } catch {
                    print("NOTMUCH ERROR: Decode failed: \(error)")
                    print("NOTMUCH Raw: \(line.prefix(500))")
                    return nil
                }
            }
            
            print("NOTMUCH ERROR: Stream ended without response")
            return nil
            
        } catch {
            print("NOTMUCH ERROR: IPC failed: \(error)")
            return nil
        }
    }
}

// MARK: - Protocol Conformance

extension NotmuchBackend: MailBackendProtocol {}
