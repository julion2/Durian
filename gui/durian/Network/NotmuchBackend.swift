
//
//  NotmuchBackend.swift
//  Durian
//
//  notmuch mail backend using durian CLI HTTP server
//

import Foundation
import Combine
import AppKit

// MARK: - JSON Models (unchanged, but DurianRequest is no longer needed)

struct DurianResponse: Decodable {
    let ok: Bool
    let error: String?
    let results: [NotmuchMailResult]?
    let mail: NotmuchMailContent?
    let thread: ThreadContent?
    let tags: [String]?
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

struct ThreadContent: Decodable {
    let thread_id: String
    let subject: String
    let messages: [ThreadMessage]
}

// MARK: - Notmuch Backend

@MainActor
class NotmuchBackend: ObservableObject {
    private var durianProcess: Process?
    private let decoder = JSONDecoder()
    private let baseURL = URL(string: "http://localhost:9723/api/v1")!

    // MARK: - Published State (Protocol conformance)
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var folders: [MailFolder] = []
    @Published var emails: [MailMessage] = []
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""

    // Internal state
    private var currentFolder = "inbox"
    private var currentQuery = "tag:inbox"
    
    // Cancellation support for prefetch
    private var prefetchTask: Task<Void, Never>?
    private var shouldCancelPrefetch = false

    // Thread cache
    private var threadCache: [String: CachedThread] = [:]
    private let maxCacheSize = 200

    private struct CachedThread {
        let messages: [ThreadMessage]
        let timestamp: Date
    }

    init() {
        folders = MailFolder.defaultNotmuchTags
    }

    // MARK: - Connection Management

    private func resolveDurianPath() -> String? {
        // This helper remains the same
        let homePath = "\(NSHomeDirectory())/.local/bin/durian"
        if FileManager.default.fileExists(atPath: homePath) {
            return homePath
        }
        let searchPaths = ["/usr/local/bin/durian", "/opt/homebrew/bin/durian"]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    func connect() async {
        guard durianProcess == nil || !durianProcess!.isRunning else {
            print("NOTMUCH Server already running")
            return
        }

        guard let durianPath = resolveDurianPath() else {
            connectionStatus = "durian CLI not found"
            print("NOTMUCH ERROR: \(connectionStatus)")
            return
        }

        durianProcess = Process()
        durianProcess?.executableURL = URL(fileURLWithPath: durianPath)
        durianProcess?.arguments = ["serve"]

        // Ensure child process can find notmuch and other tools
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        durianProcess?.environment = env

        // Discard output so the pipe doesn't fill up
        durianProcess?.standardOutput = FileHandle.nullDevice
        durianProcess?.standardError = FileHandle.nullDevice

        do {
            try durianProcess?.run()
            print("NOTMUCH Started durian server process")

            // Give the server a moment to start
            try? await Task.sleep(for: .seconds(1))

            // Check if the server is reachable
            var request = URLRequest(url: baseURL)
            request.httpMethod = "HEAD" // Lightweight request to check server status
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 { // 404 is ok, means our base endpoint is handled
                isConnected = true
                connectionStatus = "Connected to notmuch"
                print("NOTMUCH Server is responsive")
                await selectFolder("inbox")
            } else {
                throw NSError(domain: "NotmuchBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server not responsive"])
            }
        } catch {
            connectionStatus = "Failed to start or connect to server: \(error.localizedDescription)"
            print("NOTMUCH ERROR: \(connectionStatus)")
            durianProcess?.terminate()
            durianProcess = nil
            isConnected = false
        }
    }

    func disconnect() async {
        durianProcess?.terminate()
        durianProcess = nil
        isConnected = false
        connectionStatus = "Disconnected"
        print("NOTMUCH Disconnected and server terminated")
    }

    // MARK: - Folder/Tag Selection (unchanged)
    
    func selectFolder(_ name: String) async {
        shouldCancelPrefetch = true
        prefetchTask?.cancel()
        prefetchTask = nil
        
        currentFolder = name
        currentQuery = ProfileManager.shared.buildQuery(folderName: name)
        print("NOTMUCH selectFolder: \(currentQuery)")
        await search(currentQuery)
    }

    // MARK: - Generic HTTP Request Function

    private func request<T: Decodable>(endpoint: String, method: String = "GET") async -> T? {
        return await performRequest(endpoint: endpoint, method: method, bodyData: nil)
    }

    private func request<T: Decodable>(endpoint: String, method: String = "GET", body: some Encodable) async -> T? {
        do {
            let data = try JSONEncoder().encode(body)
            return await performRequest(endpoint: endpoint, method: method, bodyData: data)
        } catch {
            print("NOTMUCH ERROR: Failed to encode request body: \(error)")
            return nil
        }
    }

    private func performRequest<T: Decodable>(endpoint: String, method: String, bodyData: Data?) async -> T? {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            print("NOTMUCH ERROR: Invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10

        if let bodyData {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try decoder.decode(T.self, from: data)
            return response
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            print("NOTMUCH ERROR: Request to \(endpoint) failed: \(error)")
            return nil
        }
    }

    // MARK: - Email Operations (Refactored to use HTTP)

    func fetchEmailBody(id: String) async {
        await fetchEmailBodyInternal(id: id, isPrefetch: false)
    }

    private func fetchEmailBodyInternal(id: String, isPrefetch: Bool) async {
        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].bodyState = .loading
        }

        let response: DurianResponse? = await request(endpoint: "/threads/\(id)")

        guard let thread = response?.thread else {
            if let index = emails.firstIndex(where: { $0.id == id }) {
                 if isPrefetch && (shouldCancelPrefetch || Task.isCancelled) {
                    emails[index].bodyState = .notLoaded
                    print("NOTMUCH Prefetch cancelled for \(id)")
                } else {
                    emails[index].bodyState = .failed(message: "Failed to load thread")
                    print("NOTMUCH Body fetch failed for \(id)")
                }
            }
            return
        }

        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].threadMessages = thread.messages
            if let newestMessage = thread.messages.last {
                emails[index].from = newestMessage.from
                emails[index].body = newestMessage.body
                emails[index].htmlBody = newestMessage.html
                emails[index].to = newestMessage.to
                emails[index].cc = newestMessage.cc
                emails[index].messageId = newestMessage.message_id
                emails[index].inReplyTo = newestMessage.in_reply_to
                emails[index].references = newestMessage.references
            }
            let combinedBody = thread.messages.map { $0.body }.joined(separator: "\n\n---\n\n")
            emails[index].bodyState = .loaded(body: combinedBody, attributedBody: nil)
            print("NOTMUCH Loaded thread \(id) with \(thread.messages.count) messages")
            cacheThread(id: id, messages: thread.messages)
        }
    }
    
    private func search(_ query: String, limit: Int = 200) async {
        isLoadingEmails = true
        loadingProgress = "Searching..."

        var components = URLComponents()
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let endpoint = components.string else {
            loadingProgress = "Search failed: Could not create URL"
            isLoadingEmails = false
            return
        }

        let response: DurianResponse? = await request(endpoint: endpoint)

        guard let results = response?.results else {
            isLoadingEmails = false
            loadingProgress = "Search failed"
            return
        }

        shouldCancelPrefetch = false
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
        
        restoreCachedThreads()
        print("NOTMUCH Search returned \(emails.count) emails")
        isLoadingEmails = false
        loadingProgress = ""
        
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            startPrefetch(count: 5)
        }
    }
    
    func searchAll(query: String, limit: Int = 10) async -> [MailMessage] {
        var components = URLComponents()
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let endpoint = components.string else { return [] }

        let response: DurianResponse? = await request(endpoint: endpoint)
        
        guard let results = response?.results else { return [] }
        
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

    private func tag(query: String, tags: String) async -> Bool {
        struct TagRequest: Encodable { let tags: String }
        
        // The new API expects a thread_id, so we need to extract it.
        // This is a simplification; a more robust solution might be needed
        // if the query is more complex than "thread:some-id".
        let threadId = query.replacingOccurrences(of: "thread:", with: "")

        let response: DurianResponse? = await request(
            endpoint: "/threads/\(threadId)/tags",
            method: "POST",
            body: TagRequest(tags: tags)
        )
        
        if response?.ok == true {
            print("NOTMUCH Tagged \(query) with \(tags)")
            return true
        } else {
            print("NOTMUCH Tag error: \(response?.error ?? "unknown")")
            return false
        }
    }

    func fetchAllTags() async -> [String] {
        let response: DurianResponse? = await request(endpoint: "/tags")
        return response?.tags ?? []
    }

    // MARK: - Unchanged methods (markAsRead, togglePin, etc.)
    // These methods use `tag` internally and don't need to be changed.
    
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
            // Immediately flip for responsive UI
            emails[index].isPinned = !isCurrentlyPinned
            print("NOTMUCH Toggled pin for \(id): \(!isCurrentlyPinned)")
            // Reload from notmuch to ensure state is consistent
            await reload()
        }
    }

    func addTag(id: String, tag: String) async {
        let success = await self.tag(query: "thread:\(id)", tags: "+\(tag)")
        if success { await reload() }
    }

    func removeTag(id: String, tag: String) async {
        let success = await self.tag(query: "thread:\(id)", tags: "-\(tag)")
        if success { await reload() }
    }

    func deleteMessage(id: String) async throws {
        let success = await tag(query: "thread:\(id)", tags: "+deleted -inbox -unread")
        if success {
            emails.removeAll { $0.id == id }
        }
    }
    
    func reload() async {
        currentQuery = ProfileManager.shared.buildQuery(folderName: currentFolder)
        await search(currentQuery)
    }

    // MARK: - Unchanged Caching and Prefetching Logic
    
    private func cacheThread(id: String, messages: [ThreadMessage]) {
        threadCache[id] = CachedThread(messages: messages, timestamp: Date())
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
                if let lastMessage = cached.messages.last {
                    emails[index].from = lastMessage.from
                    emails[index].body = lastMessage.body
                    emails[index].htmlBody = lastMessage.html
                    emails[index].to = lastMessage.to
                    emails[index].cc = lastMessage.cc
                    emails[index].messageId = lastMessage.message_id
                    emails[index].inReplyTo = lastMessage.in_reply_to
                    emails[index].references = lastMessage.references
                }
                let combinedBody = cached.messages.map { $0.body }.joined(separator: "\n\n---\n\n")
                emails[index].bodyState = .loaded(body: combinedBody, attributedBody: nil)
                restoredCount += 1
            }
        }
        if restoredCount > 0 {
            print("NOTMUCH Restored \(restoredCount) threads from cache")
        }
    }
    
    private func prefetchInitialBodiesInternal(count: Int = 5) async {
        let emailsToFetch = emails.prefix(count).filter { email in
            if case .notLoaded = email.bodyState { return true }
            return false
        }
        
        guard !emailsToFetch.isEmpty else { return }
        
        print("NOTMUCH Prefetching \(emailsToFetch.count) bodies...")
        
        for email in emailsToFetch {
            if shouldCancelPrefetch || Task.isCancelled {
                print("NOTMUCH Prefetch cancelled")
                return
            }
            await fetchEmailBodyInternal(id: email.id, isPrefetch: true)
        }
    }

    func startPrefetch(count: Int = 5) {
        shouldCancelPrefetch = false
        prefetchTask = Task {
            await prefetchInitialBodiesInternal(count: count)
        }
    }
}

// MARK: - Protocol Conformance
extension NotmuchBackend: MailBackendProtocol {}


