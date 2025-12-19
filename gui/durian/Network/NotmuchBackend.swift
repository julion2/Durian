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
    let subject: String
    let date: String
    let body: String
    let html: String?
    let attachments: [String]?
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
    
    init() {
        // Set default tags as folders
        folders = MailFolder.defaultNotmuchTags
    }
    
    // MARK: - Protocol: Connection
    
    func connect() async {
        let durianPath = "\(NSHomeDirectory())/.local/bin/durian"
        
        guard FileManager.default.fileExists(atPath: durianPath) else {
            connectionStatus = "durian not found at \(durianPath)"
            print("NOTMUCH ERROR: \(connectionStatus)")
            return
        }
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: durianPath)
        
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
            print("NOTMUCH Started durian process")
            
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
    
    func fetchEmailBody(id: String) async {
        // Find and update email state to loading
        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].bodyState = .loading
        }
        
        // Use thread_id directly - durian will resolve the file path
        let request = DurianRequest(cmd: "show", thread: id)
        
        guard let response = await sendCommand(request),
              response.ok,
              let mail = response.mail else {
            if let index = emails.firstIndex(where: { $0.id == id }) {
                emails[index].bodyState = .failed(message: "Failed to load")
            }
            return
        }
        
        // Update email with body
        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].body = mail.body
            emails[index].htmlBody = mail.html
            emails[index].bodyState = .loaded(body: mail.body, attributedBody: nil)
            print("NOTMUCH Loaded body for \(id): \(mail.body.prefix(100))...")
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
            await fetchEmailBody(id: email.id)
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
    
    private func search(_ query: String, limit: Int = 50) async {
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
    
    private func sendCommand(_ request: DurianRequest) async -> DurianResponse? {
        guard let stdin = stdin, let stdout = stdout else {
            print("NOTMUCH ERROR: No stdin/stdout")
            return nil
        }
        
        do {
            var data = try encoder.encode(request)
            data.append(contentsOf: "\n".utf8)
            
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Only one request at a time to prevent response mixing
                    // Use timeout-based wait so we can check for cancellation
                    var waitResult = self.requestSemaphore.wait(timeout: .now() + 0.1)
                    while waitResult == .timedOut {
                        // Check if prefetch should be cancelled
                        if self.shouldCancelPrefetch {
                            print("NOTMUCH sendCommand: Cancelled while waiting for semaphore")
                            continuation.resume(returning: nil)
                            return
                        }
                        waitResult = self.requestSemaphore.wait(timeout: .now() + 0.1)
                    }
                    defer { self.requestSemaphore.signal() }
                    
                    stdin.write(data)
                    
                    // Buffered reading bis Newline (eine JSON-Zeile pro Response)
                    var buffer = Data()
                    let startTime = Date()
                    let timeout: TimeInterval = 30.0
                    
                    while true {
                        // Timeout check
                        if Date().timeIntervalSince(startTime) > timeout {
                            print("NOTMUCH ERROR: Read timeout after 30s")
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        let chunk = stdout.availableData
                        if chunk.isEmpty {
                            Thread.sleep(forTimeInterval: 0.01)
                            continue
                        }
                        buffer.append(chunk)
                        
                        // Prüfe ob vollständige Zeile (endet mit \n)
                        if let str = String(data: buffer, encoding: .utf8), str.contains("\n") {
                            break
                        }
                    }
                    
                    let responseData = buffer
                    
                    if responseData.isEmpty {
                        print("NOTMUCH ERROR: Empty response")
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    do {
                        let response = try self.decoder.decode(DurianResponse.self, from: responseData)
                        continuation.resume(returning: response)
                    } catch {
                        print("NOTMUCH ERROR: Decode failed: \(error)")
                        if let str = String(data: responseData, encoding: .utf8) {
                            print("NOTMUCH Raw: \(str.prefix(500))")
                        }
                        continuation.resume(returning: nil)
                    }
                }
            }
        } catch {
            print("NOTMUCH ERROR: Encode failed: \(error)")
            return nil
        }
    }
}

// MARK: - Protocol Conformance

extension NotmuchBackend: MailBackendProtocol {}
