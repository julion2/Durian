
//
//  EmailBackend.swift
//  Durian
//
//  Email backend using durian CLI HTTP server
//

import Foundation
import Combine
import AppKit

// MARK: - JSON Models (unchanged, but DurianRequest is no longer needed)

struct DurianResponse: Decodable {
    let ok: Bool
    let error: String?
    let results: [MailSearchResult]?
    let mail: MailContent?
    let thread: ThreadContent?
    let threads: [String: ThreadContent]?
    let message_body: MessageBodyResponse?
    let tags: [String]?
}

struct ContactResponse: Decodable, Identifiable, Hashable {
    let id: String
    let email: String
    let name: String?
    let last_used: String?
    let usage_count: Int
    let source: String
    let created_at: String
}

/// Dummy type for POST endpoints that return no JSON body
private struct EmptyResponse: Decodable {}

// MARK: - Outbox Models

/// Payload for POST /api/v1/outbox/send
struct OutboxPayload: Encodable {
    let from: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let is_html: Bool
    let in_reply_to: String?
    let references: String?
    let attachments: [OutboxAttachmentPayload]
    let delay_seconds: Int
}

struct OutboxAttachmentPayload: Encodable {
    let filename: String
    let mime_type: String
    let data_base64: String
}

/// Entry returned by GET /api/v1/outbox
struct OutboxEntry: Decodable, Identifiable {
    let id: Int64
    let subject: String
    let to: String
    let attempts: Int
    let last_error: String?
    let created_at: Int64
}

struct MessageBodyResponse: Decodable {
    let body: String
    let html: String?
}

struct MailSearchResult: Decodable {
    let thread_id: String
    let subject: String
    let from: String
    let to: String?
    let date: String
    let timestamp: Int
    let tags: String
}

struct MailContent: Decodable {
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
    let attachments: [AttachmentInfo]?
}

struct ThreadContent: Decodable {
    let thread_id: String
    let subject: String
    let messages: [ThreadMessage]
}

enum TagError: Error, LocalizedError {
    case tagFailed(String)
    var errorDescription: String? {
        switch self { case .tagFailed(let msg): return msg }
    }
}

// MARK: - Email Backend

@MainActor
class EmailBackend: ObservableObject {
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

    // Generation counter to discard stale search results on rapid folder/profile switches
    private var searchGeneration: Int = 0

    // Thread cache
    private var threadCache: [String: CachedThread] = [:]
    private let maxCacheSize = 200

    private struct CachedThread {
        let messages: [ThreadMessage]
        let timestamp: Date
    }

    init() {
        folders = MailFolder.defaultTags
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
            Log.debug("BACKEND", "Server already running")
            return
        }

        guard let durianPath = resolveDurianPath() else {
            connectionStatus = "durian CLI not found"
            Log.error("BACKEND", connectionStatus)
            BannerManager.shared.showCritical(title: "Durian CLI Not Found", message: "Cannot start mail server.")
            return
        }

        // Kill any existing durian serve process to free the port.
        // This handles the case where another app instance (Nightly vs Release)
        // or a stale process is already bound to :9723.
        killExistingServeProcesses()

        durianProcess = Process()
        durianProcess?.executableURL = URL(fileURLWithPath: durianPath)
        durianProcess?.arguments = ["serve"]

        // Ensure child process can find durian and other tools
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        durianProcess?.environment = env

        // Go manages serve.log directly (truncate-on-start, leveled via slog)
        durianProcess?.standardOutput = FileHandle.nullDevice
        durianProcess?.standardError = FileHandle.nullDevice

        do {
            try durianProcess?.run()
            Log.info("BACKEND", "Started durian server process")

            // Give the server a moment to start
            try? await Task.sleep(for: .seconds(1))

            // Check if the server is reachable
            var request = URLRequest(url: baseURL)
            request.httpMethod = "HEAD" // Lightweight request to check server status
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 { // 404 is ok, means our base endpoint is handled
                isConnected = true
                connectionStatus = "Connected"
                Log.info("BACKEND", "Server is responsive")
                await selectFolder("inbox")
            } else {
                throw NSError(domain: "EmailBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server not responsive"])
            }
        } catch {
            connectionStatus = "Failed to start or connect to server: \(error.localizedDescription)"
            Log.error("BACKEND", connectionStatus)
            BannerManager.shared.showCritical(title: "Mail Server Error", message: "Could not connect. Try restarting.")
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
        Log.info("BACKEND", "Disconnected and server terminated")
    }

    /// Kill any existing `durian serve` processes to free port 9723.
    private func killExistingServeProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "durian serve"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            Log.info("BACKEND", "Killed existing durian serve process")
            // Brief pause to let the port be released
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Folder/Tag Selection (unchanged)
    
    func selectFolder(_ name: String) async {
        shouldCancelPrefetch = true
        prefetchTask?.cancel()
        prefetchTask = nil
        
        currentFolder = name
        currentQuery = ProfileManager.shared.buildQuery(folderName: name)
        Log.debug("BACKEND", "selectFolder: \(currentQuery)")
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
            Log.error("BACKEND", "Failed to encode request body: \(error)")
            return nil
        }
    }

    /// Returns the CLI backend version info.
    func fetchVersion() async -> (version: String, commit: String)? {
        struct VersionResponse: Decodable {
            let version: String
            let commit: String
        }
        let response: VersionResponse? = await request(endpoint: "/version")
        guard let r = response else { return nil }
        return (r.version, r.commit)
    }

    /// Returns the number of threads matching a query.
    func searchCount(query: String) async -> Int {
        struct CountResponse: Decodable { let count: Int }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let response: CountResponse? = await request(endpoint: "/search/count?query=\(encoded)")
        return response?.count ?? 0
    }

    private func performRequest<T: Decodable>(endpoint: String, method: String, bodyData: Data?) async -> T? {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            Log.error("BACKEND", "Invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10

        if let bodyData {
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let signposter = Log.signposter(for: "HTTP")
        let state = signposter.beginInterval("Request", "\(method, privacy: .public) \(endpoint, privacy: .public)")
        var status = "Error"
        defer { signposter.endInterval("Request", state, "\(status)") }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try decoder.decode(T.self, from: data)
            status = "OK"
            return response
        } catch is CancellationError {
            status = "Cancelled"
            return nil
        } catch let error as URLError where error.code == .cancelled {
            status = "Cancelled"
            return nil
        } catch {
            Log.error("BACKEND", "Request to \(endpoint) failed: \(error)")
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
                    Log.debug("BACKEND", "Prefetch cancelled for \(id)")
                } else {
                    emails[index].bodyState = .failed(message: "Failed to load thread")
                    Log.error("BACKEND", "Body fetch failed for \(id)")
                }
            }
            return
        }

        // If thread isn't in the current list (e.g. opened from search), add it
        if emails.firstIndex(where: { $0.id == id }) == nil {
            guard let firstMsg = thread.messages.first else { return }
            let tagString = firstMsg.tags?.joined(separator: ",") ?? ""
            let mail = MailMessage(
                threadId: id,
                subject: thread.subject,
                from: firstMsg.from,
                date: firstMsg.date,
                timestamp: firstMsg.timestamp,
                tags: tagString
            )
            emails.append(mail)
        }

        if let index = emails.firstIndex(where: { $0.id == id }) {
            applyThread(thread, to: &emails[index])
            Log.info("BACKEND", "Loaded thread \(id) with \(thread.messages.count) messages")
        }
    }
    
    private func search(_ query: String, limit: Int = 200) async {
        searchGeneration += 1
        let myGeneration = searchGeneration

        isLoadingEmails = true
        loadingProgress = "Searching..."

        var components = URLComponents()
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "enrich", value: "30")
        ]

        guard let endpoint = components.string else {
            loadingProgress = "Search failed: Could not create URL"
            isLoadingEmails = false
            return
        }

        let response: DurianResponse? = await request(endpoint: endpoint)

        // A newer search has started — discard this stale result silently
        guard myGeneration == searchGeneration else {
            Log.debug("BACKEND", "Stale search result discarded (gen \(myGeneration) vs \(searchGeneration))")
            return
        }

        guard let response else {
            isLoadingEmails = false
            loadingProgress = "Search failed"
            BannerManager.shared.showWarning(title: "Search Failed", message: "Could not complete the search.")
            return
        }

        let results = response.results ?? []

        shouldCancelPrefetch = false
        let enrichedThreads = response.threads
        emails = results.map { mail in
            MailMessage(
                threadId: mail.thread_id,
                subject: mail.subject,
                from: mail.from,
                to: mail.to,
                date: mail.date,
                timestamp: mail.timestamp,
                tags: mail.tags
            )
        }

        // Apply enriched thread data from search response
        if let enrichedThreads, !enrichedThreads.isEmpty {
            for (index, email) in emails.enumerated() {
                if let thread = enrichedThreads[email.id] {
                    applyThread(thread, to: &emails[index])
                }
            }
            Log.debug("BACKEND", "Enriched \(enrichedThreads.count) threads from search")
        }

        restoreCachedThreads()
        Log.debug("BACKEND", "Search returned \(emails.count) emails")
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
                to: mail.to,
                date: mail.date,
                timestamp: mail.timestamp,
                tags: mail.tags
            )
        }
    }

    private func tag(query: String, tags: String) async throws {
        struct TagRequest: Encodable { let tags: String }

        let threadId = query.replacingOccurrences(of: "thread:", with: "")

        let response: DurianResponse? = await request(
            endpoint: "/threads/\(threadId)/tags",
            method: "POST",
            body: TagRequest(tags: tags)
        )

        if response?.ok == true {
            Log.info("BACKEND", "Tagged \(query) with \(tags)")
        } else {
            let msg = response?.error ?? "unknown error"
            Log.error("BACKEND", "Tag error: \(msg)")
            throw TagError.tagFailed(msg)
        }
    }

    func fetchAllTags() async -> [String] {
        let response: DurianResponse? = await request(endpoint: "/tags")
        return response?.tags ?? []
    }

    /// Fetch the full (unstripped) body of a single message for reply quoting.
    /// Unlike thread bodies, this preserves the quoted conversation chain.
    func fetchOriginalBody(messageId: String) async -> MessageBodyResponse? {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: messageId)]
        // URLComponents leaves + and @ unencoded (valid in RFC 3986 queries),
        // but Go's Query().Get() treats + as space (x-www-form-urlencoded).
        // Manually encode these to avoid misinterpretation.
        guard var query = components.percentEncodedQuery else { return nil }
        query = query.replacingOccurrences(of: "+", with: "%2B")
        query = query.replacingOccurrences(of: "@", with: "%40")
        let response: DurianResponse? = await request(endpoint: "/message/body?\(query)")
        return response?.message_body
    }

    // MARK: - Attachment Download

    func downloadAttachment(messageId: String, partId: Int) async throws -> (Data, String) {
        // Message IDs contain <, >, @, + which must be percent-encoded
        guard let encodedId = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw AttachmentError.parseError
        }
        guard let url = URL(string: "\(baseURL)/messages/\(encodedId)/attachments/\(partId)") else {
            throw AttachmentError.parseError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60

        let signposter = Log.signposter(for: "HTTP")
        let endpoint = "/messages/\(encodedId)/attachments/\(partId)"
        let state = signposter.beginInterval("Request", "GET \(endpoint, privacy: .public)")
        var status = "Error"
        defer { signposter.endInterval("Request", state, "\(status)") }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentError.networkError
        }
        guard httpResponse.statusCode == 200 else {
            status = "Error \(httpResponse.statusCode)"
            if httpResponse.statusCode == 404 {
                throw AttachmentError.notFound
            }
            throw AttachmentError.networkError
        }
        guard !data.isEmpty else {
            throw AttachmentError.corruptedData
        }

        status = "OK"

        // Extract filename from Content-Disposition header
        let filename: String
        if let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=\""),
           let endRange = disposition[range.upperBound...].range(of: "\"") {
            filename = String(disposition[range.upperBound..<endRange.lowerBound])
        } else {
            filename = "attachment"
        }

        return (data, filename)
    }

    // MARK: - Outbox API

    /// Enqueue an email draft to the outbox for background sending.
    /// Returns (ok, id, error) where id is the outbox item ID on success.
    func enqueueOutbox(_ payload: OutboxPayload) async -> (ok: Bool, id: Int64?, sendAfter: Int64?, error: String?) {
        struct EnqueueResponse: Decodable {
            let ok: Bool
            let id: Int64?
            let send_after: Int64?
            let error: String?
        }

        let response: EnqueueResponse? = await request(
            endpoint: "/outbox/send",
            method: "POST",
            body: payload
        )

        if let response, response.ok {
            return (true, response.id, response.send_after, nil)
        }
        return (false, nil, nil, response?.error ?? "Failed to enqueue email")
    }

    /// List all outbox items.
    func listOutbox() async -> [OutboxEntry] {
        let results: [OutboxEntry]? = await request(endpoint: "/outbox")
        return results ?? []
    }

    /// Delete an outbox item by ID.
    func deleteOutboxItem(id: Int64) async -> Bool {
        struct DeleteResponse: Decodable { let ok: Bool }
        let response: DeleteResponse? = await request(
            endpoint: "/outbox/\(id)",
            method: "DELETE"
        )
        return response?.ok == true
    }

    // MARK: - Contacts API

    /// Search contacts by email or name prefix
    func searchContacts(query: String, limit: Int = 10) async -> [ContactResponse] {
        var components = URLComponents()
        components.path = "/contacts/search"
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let endpoint = components.string else { return [] }
        let results: [ContactResponse]? = await request(endpoint: endpoint)
        return results ?? []
    }

    /// Find contact by exact name (case-insensitive)
    func findContactByExactName(_ name: String) async -> ContactResponse? {
        var components = URLComponents()
        components.path = "/contacts/search"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let endpoint = components.string else { return nil }
        let results: [ContactResponse]? = await request(endpoint: endpoint)
        return results?.first
    }

    /// List contacts ordered by usage
    func listContacts(limit: Int = 100) async -> [ContactResponse] {
        let results: [ContactResponse]? = await request(endpoint: "/contacts?limit=\(limit)")
        return results ?? []
    }

    /// Increment usage count for emails (fire-and-forget)
    func incrementContactUsage(for emails: [String]) async {
        struct UsageRequest: Encodable { let emails: [String] }
        let _: EmptyResponse? = await request(
            endpoint: "/contacts/usage",
            method: "POST",
            body: UsageRequest(emails: emails)
        )
    }

    // MARK: - Unchanged methods (markAsRead, togglePin, etc.)
    // These methods use `tag` internally and don't need to be changed.
    
    func markAsRead(id: String) async throws {
        try await tag(query: "thread:\(id)", tags: "-unread")
        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].isRead = true
        }
    }

    func markAsUnread(id: String) async throws {
        try await tag(query: "thread:\(id)", tags: "+unread")
        if let index = emails.firstIndex(where: { $0.id == id }) {
            emails[index].isRead = false
        }
    }

    func toggleRead(id: String) async throws {
        guard let index = emails.firstIndex(where: { $0.id == id }) else { return }
        if emails[index].isRead {
            try await markAsUnread(id: id)
        } else {
            try await markAsRead(id: id)
        }
    }

    func togglePin(id: String) async throws {
        guard let index = emails.firstIndex(where: { $0.id == id }) else { return }
        let isCurrentlyPinned = emails[index].isPinned

        let tags = isCurrentlyPinned ? "-flagged" : "+flagged"
        try await tag(query: "thread:\(id)", tags: tags)

        emails[index].isPinned = !isCurrentlyPinned
        Log.debug("BACKEND", "Toggled pin for \(id): \(!isCurrentlyPinned)")
        await reload()
    }

    func addTag(id: String, tag: String) async throws {
        try await self.tag(query: "thread:\(id)", tags: "+\(tag)")
        await reload()
    }

    func removeTag(id: String, tag: String) async throws {
        try await self.tag(query: "thread:\(id)", tags: "-\(tag)")
        await reload()
    }

    func modifyTags(id: String, add: [String], remove: [String]) async throws {
        let ops = add.map { "+\($0)" } + remove.map { "-\($0)" }
        try await self.tag(query: "thread:\(id)", tags: ops.joined(separator: " "))
        await reload()
    }

    func deleteMessage(id: String) async throws {
        try await tag(query: "thread:\(id)", tags: "+trash -inbox -unread -draft")
        emails.removeAll { $0.id == id }
        await reload()
    }
    
    func reload() async {
        currentQuery = ProfileManager.shared.buildQuery(folderName: currentFolder)
        await search(currentQuery)
    }

    // MARK: - Thread Application Helper

    /// Applies a ThreadContent to a MailMessage, populating body, metadata, and attachments.
    private func applyThread(_ thread: ThreadContent, to email: inout MailMessage) {
        email.threadMessages = thread.messages
        if let newestMessage = thread.messages.first {
            email.from = newestMessage.from
            email.body = newestMessage.body
            email.htmlBody = newestMessage.html
            email.to = newestMessage.to
            email.cc = newestMessage.cc
            email.messageId = newestMessage.message_id
            email.inReplyTo = newestMessage.in_reply_to
            email.references = newestMessage.references
        }
        let allAttachments = thread.messages.flatMap { msg in
            (msg.attachments ?? []).map { att in
                IncomingAttachmentMetadata(
                    section: msg.id,
                    filename: att.filename,
                    mimeType: att.contentType,
                    sizeBytes: Int64(att.size),
                    disposition: att.disposition == "inline" ? .inline : .attachment,
                    contentId: att.contentId
                )
            }
        }
        email.incomingAttachments = allAttachments
        email.hasAttachment = !allAttachments.isEmpty

        let combinedBody = thread.messages.map { $0.body }.joined(separator: "\n\n---\n\n")
        email.bodyState = .loaded(body: combinedBody, attributedBody: nil)
        cacheThread(id: email.id, messages: thread.messages)
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
            Log.debug("BACKEND", "Cache cleanup: removed \(keysToRemove.count) old entries")
        }
    }
    
    private func restoreCachedThreads() {
        var restoredCount = 0
        for (index, email) in emails.enumerated() {
            // Skip emails already populated (e.g. from enriched search response)
            if email.threadMessages != nil { continue }
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
                // Restore attachment metadata from cached messages
                let allAttachments = cached.messages.flatMap { msg in
                    (msg.attachments ?? []).map { att in
                        IncomingAttachmentMetadata(
                            section: msg.id,
                            filename: att.filename,
                            mimeType: att.contentType,
                            sizeBytes: Int64(att.size),
                            disposition: att.disposition == "inline" ? .inline : .attachment,
                            contentId: att.contentId
                        )
                    }
                }
                emails[index].incomingAttachments = allAttachments
                emails[index].hasAttachment = !allAttachments.isEmpty

                let combinedBody = cached.messages.map { $0.body }.joined(separator: "\n\n---\n\n")
                emails[index].bodyState = .loaded(body: combinedBody, attributedBody: nil)
                restoredCount += 1
            }
        }
        if restoredCount > 0 {
            Log.debug("BACKEND", "Restored \(restoredCount) threads from cache")
        }
    }
    
    private func prefetchInitialBodiesInternal(count: Int = 5) async {
        let emailsToFetch = emails.prefix(count).filter { email in
            if case .notLoaded = email.bodyState { return true }
            return false
        }
        
        guard !emailsToFetch.isEmpty else { return }
        
        Log.debug("BACKEND", "Prefetching \(emailsToFetch.count) bodies...")
        
        for email in emailsToFetch {
            if shouldCancelPrefetch || Task.isCancelled {
                Log.debug("BACKEND", "Prefetch cancelled")
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
extension EmailBackend: MailBackendProtocol {}


