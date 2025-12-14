//
//  AccountManager.swift
//  colonSend
//
//  Manages multiple IMAP accounts and aggregates their data
//  Also supports notmuch backend via compile-time flag
//

import Foundation
import Combine

// MARK: - Backend Selection
// Set to true to use notmuch backend, false for IMAP
#if DEBUG
let USE_NOTMUCH_BACKEND = true  // Change to false to use IMAP
#else
let USE_NOTMUCH_BACKEND = false
#endif

@MainActor
class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    // MARK: - IMAP Properties (used when USE_NOTMUCH_BACKEND = false)
    @Published var accounts: [MailAccount] = []
    @Published var imapClients: [String: IMAPClient] = [:]
    @Published var allFolders: [IMAPFolder] = []
    @Published var allEmails: [IMAPEmail] = []
    @Published var selectedAccount: String?
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""
    
    // MARK: - Notmuch Properties (used when USE_NOTMUCH_BACKEND = true)
    @Published var notmuchBackend: NotmuchBackend?
    @Published var mailFolders: [MailFolder] = []      // Unified folders/tags
    @Published var mailMessages: [MailMessage] = []    // Unified messages
    @Published var selectedFolder: String = "inbox"
    
    // MARK: - Backend Type
    var isUsingNotmuch: Bool { USE_NOTMUCH_BACKEND }
    
    private var cancellables = Set<AnyCancellable>()
    var suppressMerge = false
    private var updateDebounceTask: Task<Void, Never>?
    
    private init() {
        if USE_NOTMUCH_BACKEND {
            setupNotmuchBackend()
        } else {
            loadAccounts()
        }
    }
    
    // MARK: - Notmuch Setup
    
    private func setupNotmuchBackend() {
        print("NOTMUCH AccountManager: Setting up notmuch backend")
        notmuchBackend = NotmuchBackend()
        
        // Subscribe to backend changes
        notmuchBackend?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            self?.syncFromNotmuch()
        }.store(in: &cancellables)
    }
    
    private func syncFromNotmuch() {
        guard let backend = notmuchBackend else { return }
        mailFolders = backend.folders
        mailMessages = backend.emails
        isLoadingEmails = backend.isLoadingEmails
        loadingProgress = backend.loadingProgress
    }
    
    // MARK: - IMAP Setup
    
    private func loadAccounts() {
        accounts = ConfigManager.shared.getAccounts()
        print("IMAP Loaded \(accounts.count) accounts")
    }
    
    func connectToAllAccounts() async {
        if USE_NOTMUCH_BACKEND {
            await connectNotmuch()
        } else {
            await connectIMAP()
        }
    }
    
    // MARK: - Notmuch Connection
    
    private func connectNotmuch() async {
        print("NOTMUCH AccountManager: Connecting to notmuch...")
        guard let backend = notmuchBackend else {
            print("NOTMUCH ERROR: Backend not initialized")
            return
        }
        await backend.connect()
        syncFromNotmuch()
    }
    
    // MARK: - Notmuch Folder/Tag Selection
    
    func selectNotmuchTag(_ tag: String) async {
        guard let backend = notmuchBackend else { return }
        selectedFolder = tag
        mailMessages.removeAll()
        await backend.selectFolder(tag)
        syncFromNotmuch()
    }
    
    // MARK: - Profile Switching (Notmuch)
    
    /// Switch to a different profile and reload the current tag/folder
    func switchProfile(_ profile: Profile) async {
        guard USE_NOTMUCH_BACKEND else { return }
        
        // Update ProfileManager
        ProfileManager.shared.currentProfile = profile
        print("NOTMUCH AccountManager: Switched to profile '\(profile.name)'")
        
        // Reload current folder with new profile filter
        await selectNotmuchTag(selectedFolder)
    }
    
    // MARK: - Notmuch Email Operations
    
    func fetchNotmuchEmailBody(id: String) async {
        guard let backend = notmuchBackend else { return }
        await backend.fetchEmailBody(id: id)
        syncFromNotmuch()
    }
    
    func markNotmuchAsRead(id: String) async {
        guard let backend = notmuchBackend else { return }
        await backend.markAsRead(id: id)
        syncFromNotmuch()
    }
    
    func toggleNotmuchReadStatus(id: String) async {
        guard let backend = notmuchBackend else { return }
        if let email = mailMessages.first(where: { $0.id == id }) {
            if email.isRead {
                await backend.markAsUnread(id: id)
            } else {
                await backend.markAsRead(id: id)
            }
        }
        syncFromNotmuch()
    }
    
    func deleteNotmuchMessage(id: String) async {
        guard let backend = notmuchBackend else { return }
        try? await backend.deleteMessage(id: id)
        syncFromNotmuch()
    }
    
    func reloadNotmuch() async {
        guard let backend = notmuchBackend else { return }
        
        // Set PATH for Homebrew binaries
        var environment = ProcessInfo.processInfo.environment
        let homebrewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        if let existingPath = environment["PATH"] {
            environment["PATH"] = "\(homebrewPaths):\(existingPath)"
        } else {
            environment["PATH"] = "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        
        isLoadingEmails = true
        
        // 1. Sync from server via mbsync (60s timeout)
        loadingProgress = "Syncing from server..."
        print("NOTMUCH Reload: Running mbsync -a")
        
        let mbsyncSuccess = await runProcess(
            path: "/opt/homebrew/bin/mbsync",
            arguments: ["-a"],
            environment: environment,
            timeout: 60
        )
        
        if !mbsyncSuccess {
            loadingProgress = "Sync failed - try again"
            print("NOTMUCH Reload: mbsync failed or timed out")
            // Still continue to reload local data
        }
        
        // 2. Index new mail via notmuch new (30s timeout)
        loadingProgress = "Indexing new mail..."
        print("NOTMUCH Reload: Running notmuch new")
        
        let notmuchSuccess = await runProcess(
            path: "/opt/homebrew/bin/notmuch",
            arguments: ["new"],
            environment: environment,
            timeout: 30
        )
        
        if !notmuchSuccess {
            loadingProgress = "Indexing failed"
            print("NOTMUCH Reload: notmuch new failed or timed out")
            isLoadingEmails = false
            return
        }
        
        // 3. Reload from notmuch
        loadingProgress = "Loading..."
        print("NOTMUCH Reload: Reloading from notmuch")
        await backend.reload()
        syncFromNotmuch()
    }
    
    /// Run a process with timeout, returns true if successful
    private func runProcess(path: String, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = environment
                
                do {
                    try process.run()
                } catch {
                    print("NOTMUCH Reload: Failed to start \(path): \(error)")
                    continuation.resume(returning: false)
                    return
                }
                
                // Wait with timeout
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                
                if process.isRunning {
                    print("NOTMUCH Reload: \(path) timed out after \(timeout)s, terminating")
                    process.terminate()
                    continuation.resume(returning: false)
                } else {
                    let success = process.terminationStatus == 0
                    print("NOTMUCH Reload: \(path) finished with status \(process.terminationStatus)")
                    continuation.resume(returning: success)
                }
            }
        }
    }
    
    // MARK: - IMAP Connection
    
    private func connectIMAP() async {
        print("IMAP Connecting to \(accounts.count) accounts...")
        
        for account in accounts {
            let client = IMAPClient()
            imapClients[account.email] = client
            
            // Subscribe to client changes with debounce
            client.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
                self?.debouncedUpdateAggregatedData()
            }.store(in: &cancellables)
            
            Task {
                await client.connect(account: account)
                await updateAggregatedData()
            }
        }
    }
    
    /// Merges fresh email metadata with existing emails while preserving fetched bodies.
    /// When the folder list is refreshed, IMAP sends new metadata (subject, date, etc.)
    /// but not bodies. This function preserves already-loaded bodies by matching UIDs,
    /// preventing the "body swap" bug where opening a draft would show the wrong email's content.
    private func mergeEmailsPreservingBodies(freshEmails: [IMAPEmail]) {
        if suppressMerge {
            return
        }

        if freshEmails.isEmpty {
            allEmails.removeAll()
            return
        }

        var existingByUID: [UInt32: IMAPEmail] = [:]
        for email in allEmails {
            existingByUID[email.uid] = email
        }

        var merged: [IMAPEmail] = []
        for freshEmail in freshEmails {
            var updated = freshEmail
            
            if let existing = existingByUID[freshEmail.uid] {
                // FIX: Prioritize fresh state over existing state
                // The bug was: we always overwrote fresh .loaded with existing .notLoaded
                switch (freshEmail.bodyState, existing.bodyState) {
                case (.loaded, _):
                    // Fresh email has loaded body - use it (it's newer)
                    // Don't overwrite! Keep freshEmail.bodyState
                    print("🔄 MERGE: UID \(freshEmail.uid) - Using fresh .loaded state")
                    break
                    
                case (_, .loaded):
                    // Existing has loaded body, fresh doesn't - preserve it
                    updated.body = existing.body
                    updated.attributedBody = existing.attributedBody
                    updated.bodyState = existing.bodyState
                    updated.rawBody = existing.rawBody
                    updated.attachments = existing.attachments
                    updated.incomingAttachments = existing.incomingAttachments
                    print("🔄 MERGE: UID \(freshEmail.uid) - Preserving existing .loaded state")
                    
                case (.notLoaded, .loading):
                    // Preserve loading state (user triggered load)
                    updated.bodyState = .loading
                    print("🔄 MERGE: UID \(freshEmail.uid) - Preserving .loading state")
                    
                case (.failed, _), (_, .failed):
                    // If either failed, keep the failure
                    if case .failed = existing.bodyState {
                        updated.bodyState = existing.bodyState
                    }
                    print("🔄 MERGE: UID \(freshEmail.uid) - Handling .failed state")
                    
                default:
                    // For all other cases, keep fresh state
                    print("🔄 MERGE: UID \(freshEmail.uid) - Fresh: \(freshEmail.bodyState), Existing: \(existing.bodyState), Using fresh")
                    break
                }
            }
            
            merged.append(updated)
        }

        allEmails = merged
    }

    /// Debounces calls to updateAggregatedData() with a 100ms delay.
    /// This prevents performance issues when loading emails - without debouncing,
    /// updateAggregatedData() can be called 100+ times during a single folder load,
    /// causing UI lag. With debouncing, it's reduced to ~6 calls.
    private func debouncedUpdateAggregatedData() {
        updateDebounceTask?.cancel()
        updateDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Task.isCancelled {
                updateAggregatedData()
            }
        }
    }
    
    private func updateAggregatedData() {
        if suppressMerge {
            return
        }
        
        allFolders = imapClients.values.flatMap { $0.folders }

        if let selectedAccount = selectedAccount,
           let client = imapClients[selectedAccount] {
            mergeEmailsPreservingBodies(freshEmails: client.emails)
            isLoadingEmails = client.isLoadingEmails
            loadingProgress = client.loadingProgress
        } else {
            // No account selected - clear emails instead of showing random account's emails
            if selectedAccount != nil {
                print("⚠️ updateAggregatedData: selectedAccount '\(selectedAccount!)' has no client")
            } else {
                print("⚠️ updateAggregatedData: No account selected yet")
            }
            // Don't modify allEmails if no proper account is selected
            // This prevents race condition showing wrong emails
        }
    }
    
    func selectFolder(_ folderName: String, accountId: String) async {
        print("📂 AccountManager: Selecting folder '\(folderName)' for account '\(accountId)'")

        // CRITICAL: Clear emails immediately to prevent race condition
        // If we don't do this, objectWillChange from the client might show old emails
        allEmails.removeAll()
        selectedAccount = accountId

        guard let client = imapClients[accountId] else {
            print("❌ No IMAP client found for account: \(accountId)")
            return
        }

        await client.selectFolder(folderName)
        await updateAggregatedData()
    }
    
    func getClient(for accountId: String) -> IMAPClient? {
        return imapClients[accountId]
    }
    
    func reloadCurrentFolder() async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for reload")
            return
        }
        
        suppressMerge = false
        await client.reloadCurrentFolder()
        await updateAggregatedData()
    }
    
    func markAsRead(uid: UInt32) async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for mark as read")
            return
        }
        
        await client.markAsRead(uid: uid)
        await updateAggregatedData()
    }
    
    func toggleReadStatus(uid: UInt32) async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for toggle read")
            return
        }
        
        await client.toggleReadStatus(uid: uid)
        await updateAggregatedData()
    }
    
    func saveDraftToIMAP(draft: EmailDraft, accountId: String) async throws -> UInt32? {
        print("DRAFTING: saveDraftToIMAP started for account: \(accountId)")
        
        guard let client = imapClients[accountId] else {
            print("DRAFTING: Error - No IMAP client for account: \(accountId)")
            print("DRAFTING: Available clients: \(imapClients.keys.joined(separator: ", "))")
            return nil
        }
        
        print("DRAFTING: Searching \(allFolders.count) folders for drafts folder")
        guard let draftsFolder = allFolders.first(where: { $0.accountId == accountId && $0.isDraftsFolder }) else {
            print("DRAFTING: Error - No drafts folder found")
            let accountFolders = allFolders.filter { $0.accountId == accountId }
            print("DRAFTING: Account has \(accountFolders.count) folders:")
            for folder in accountFolders {
                print("DRAFTING:   - \(folder.name) [isDrafts: \(folder.isDraftsFolder), attributes: \(folder.attributes)]")
            }
            return nil
        }
        
        print("DRAFTING: Found drafts folder: \(draftsFolder.name)")
        
        let message = formatDraftAsEmail(draft)
        print("DRAFTING: Formatted message - \(message.count) bytes")
        print("DRAFTING: Message preview: \(String(message.prefix(200)))")
        
        print("DRAFTING: Calling client.appendMessage")
        let uid = try await client.appendMessage(to: draftsFolder.name, message: message, flags: ["\\Draft", "\\Seen"])
        
        print("DRAFTING: appendMessage returned UID: \(uid ?? 0)")
        return uid
    }
    
    func updateDraftInIMAP(draft: EmailDraft, accountId: String) async throws -> UInt32? {
        print("DRAFTING: updateDraftInIMAP started for account: \(accountId)")
        
        if let existingUID = draft.uid {
            print("DRAFTING: Draft has existing UID: \(existingUID) - will update")
        } else {
            print("DRAFTING: Creating new draft")
        }
        
        print("DRAFTING: Calling saveDraftToIMAP")
        let result = try await saveDraftToIMAP(draft: draft, accountId: accountId)
        print("DRAFTING: saveDraftToIMAP completed with UID: \(result ?? 0)")
        
        return result
    }
    
    func deleteDraftFromIMAP(uid: UInt32, accountId: String) async throws {
        print("DRAFTING: deleteDraftFromIMAP called for UID: \(uid)")
        
        guard let client = imapClients[accountId] else {
            print("DRAFTING: Error - No IMAP client for account: \(accountId)")
            return
        }
        
        guard let draftsFolder = allFolders.first(where: { $0.accountId == accountId && $0.isDraftsFolder }) else {
            print("DRAFTING: Error - No drafts folder found")
            return
        }
        
        print("DRAFTING: Selecting drafts folder: \(draftsFolder.name)")
        await client.selectFolder(draftsFolder.name)
        
        print("DRAFTING: Marking message as deleted")
        try await client.deleteMessage(uid: uid)
        
        print("DRAFTING: Expunging deleted messages")
        try await client.expunge()
        
        print("DRAFTING: Draft deleted successfully")
    }
    
    func loadDraftsFromIMAP(accountId: String) async -> [EmailDraft] {
        guard let client = imapClients[accountId] else {
            print("❌ No IMAP client found for account: \(accountId)")
            return []
        }
        
        guard let draftsFolder = allFolders.first(where: { $0.accountId == accountId && $0.isDraftsFolder }) else {
            print("❌ No drafts folder found for account: \(accountId)")
            return []
        }
        
        await client.selectFolder(draftsFolder.name)
        
        var drafts: [EmailDraft] = []
        for email in client.emails {
            if let draft = parseDraftFromEmail(email, accountId: accountId) {
                drafts.append(draft)
            }
        }
        
        return drafts
    }
    
    func moveDraftToSent(uid: UInt32, accountId: String) async throws {
        guard let client = imapClients[accountId] else {
            print("❌ No IMAP client found for account: \(accountId)")
            return
        }
        
        guard let draftsFolder = allFolders.first(where: { $0.accountId == accountId && $0.isDraftsFolder }),
              let sentFolder = allFolders.first(where: { $0.accountId == accountId && $0.isSentFolder }) else {
            print("❌ Drafts or Sent folder not found for account: \(accountId)")
            return
        }
        
        await client.selectFolder(draftsFolder.name)
        try await client.moveMessage(uid: uid, toFolder: sentFolder.name)
        
        print("✅ Draft moved to Sent folder")
    }
    
    private func formatDraftAsEmail(_ draft: EmailDraft) -> String {
        return MIMEBuilder.buildMessage(from: draft)
    }
    
    func parseDraftFromEmail(_ email: IMAPEmail, accountId: String) -> EmailDraft? {
        guard let fullBody = email.body else {
            print("❌ Draft parse failed: No body for UID \(email.uid)")
            return nil
        }
        
        print("DRAFT_PARSE: Starting parse for UID=\(email.uid) Subject=\(email.subject)")
        print("DRAFT_PARSE: Body length=\(fullBody.count)")
        
        var toAddresses: [String] = []
        var ccAddresses: [String] = []
        var bccAddresses: [String] = []
        var subject = email.subject
        var body = fullBody
        var inReplyTo: String? = nil
        var references: String? = nil
        var attachments: [EmailAttachment] = []
        var boundary: String? = nil
        var contentTypeHeader = ""
        
        let lines = fullBody.components(separatedBy: .newlines)
        var bodyStartIndex = 0
        var headersParsed = 0
        var isParsingContentType = false
        
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if index < 30 {
                print("DRAFT_PARSE: Line \(index): |\(line)|")
            }
            
            if trimmedLine.hasPrefix("To:") {
                let toLine = trimmedLine.replacingOccurrences(of: "To:", with: "").trimmingCharacters(in: .whitespaces)
                toAddresses = toLine.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                headersParsed += 1
                isParsingContentType = false
            } else if trimmedLine.hasPrefix("Cc:") {
                let ccLine = trimmedLine.replacingOccurrences(of: "Cc:", with: "").trimmingCharacters(in: .whitespaces)
                ccAddresses = ccLine.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                headersParsed += 1
                isParsingContentType = false
            } else if trimmedLine.hasPrefix("Bcc:") {
                let bccLine = trimmedLine.replacingOccurrences(of: "Bcc:", with: "").trimmingCharacters(in: .whitespaces)
                bccAddresses = bccLine.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                headersParsed += 1
                isParsingContentType = false
            } else if trimmedLine.hasPrefix("Subject:") {
                subject = trimmedLine.replacingOccurrences(of: "Subject:", with: "").trimmingCharacters(in: .whitespaces)
                headersParsed += 1
                isParsingContentType = false
            } else if trimmedLine.hasPrefix("In-Reply-To:") {
                inReplyTo = trimmedLine.replacingOccurrences(of: "In-Reply-To:", with: "").trimmingCharacters(in: .whitespaces)
                headersParsed += 1
                isParsingContentType = false
            } else if trimmedLine.hasPrefix("References:") {
                references = trimmedLine.replacingOccurrences(of: "References:", with: "").trimmingCharacters(in: .whitespaces)
                headersParsed += 1
                isParsingContentType = false
            } else if trimmedLine.hasPrefix("Content-Type:") {
                contentTypeHeader = trimmedLine
                isParsingContentType = true
            } else if isParsingContentType && (line.hasPrefix(" ") || line.hasPrefix("\t")) {
                contentTypeHeader += " " + trimmedLine
            } else if trimmedLine.isEmpty {
                bodyStartIndex = index + 1
                break
            } else {
                isParsingContentType = false
            }
        }
        
        if !contentTypeHeader.isEmpty {
            print("DRAFT_PARSE: Content-Type header: \(contentTypeHeader)")
            
            let patterns = [
                "boundary=\"([^\"]+)\"",
                "boundary='([^']+)'",
                "boundary=([^;\\s]+)"
            ]
            
            for pattern in patterns {
                if let match = contentTypeHeader.range(of: pattern, options: .regularExpression) {
                    let matchedString = String(contentTypeHeader[match])
                    boundary = matchedString
                        .replacingOccurrences(of: "boundary=\"", with: "")
                        .replacingOccurrences(of: "boundary='", with: "")
                        .replacingOccurrences(of: "boundary=", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    print("DRAFT_PARSE: Found boundary: \(boundary ?? "nil")")
                    break
                }
            }
        }
        
        if !email.attachments.isEmpty {
            print("DRAFT_PARSE: Using pre-parsed attachments from IMAPEmail (\(email.attachments.count) attachments)")
            attachments = email.attachments
            if let emailBody = email.body, !emailBody.isEmpty {
                print("DRAFT_PARSE: Using pre-parsed body from IMAPEmail (\(emailBody.count) chars)")
                body = emailBody
            }
        }
        
        if bodyStartIndex > 0 && bodyStartIndex < lines.count && body.isEmpty {
            let fullContent = lines[bodyStartIndex...].joined(separator: "\n")
            
            if let boundary = boundary {
                print("DRAFT_PARSE: Parsing MIME multipart with boundary: \(boundary)")
                let parsed = parseMIMEMultipart(content: fullContent, boundary: boundary)
                body = parsed.body
                if email.attachments.isEmpty {
                    attachments = parsed.attachments
                }
                print("DRAFT_PARSE: Parsed body.count=\(body.count) attachments.count=\(attachments.count)")
            } else {
                print("DRAFT_PARSE: No boundary found, using full content as body")
                body = fullContent
            }
        }
        
        var draft = EmailDraft(
            from: accountId,
            to: toAddresses,
            cc: ccAddresses,
            subject: subject,
            body: body,
            isHTML: false,
            inReplyTo: inReplyTo,
            references: references
        )
        draft.bcc = bccAddresses
        draft.uid = email.uid
        draft.accountId = accountId
        draft.attachments = attachments
        
        print("DRAFT_PARSE: Final draft - UID=\(draft.uid ?? 0) attachments=\(draft.attachments.count)")
        
        return draft
    }
    
    private func parseMIMEMultipart(content: String, boundary: String) -> (body: String, attachments: [EmailAttachment]) {
        print("MIME_PARSE: Boundary=\(boundary) Content.count=\(content.count)")
        let parts = content.components(separatedBy: "--\(boundary)")
        print("MIME_PARSE: Found \(parts.count) parts")
        var body = ""
        var attachments: [EmailAttachment] = []
        
        for (partIndex, part) in parts.enumerated() {
            print("MIME_PARSE: Processing part \(partIndex) length=\(part.count)")
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmedPart.isEmpty || trimmedPart == "--" {
                continue
            }
            
            let partLines = part.components(separatedBy: .newlines)
            var isAttachment = false
            var filename: String?
            var mimeType: String?
            var encoding: String?
            var contentStartIndex = 0
            
            for (index, line) in partLines.enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                
                if trimmedLine.hasPrefix("Content-Type:") {
                    if let typeMatch = trimmedLine.range(of: "Content-Type: ([^;]+)", options: .regularExpression) {
                        mimeType = String(trimmedLine[typeMatch]).replacingOccurrences(of: "Content-Type: ", with: "")
                    }
                    
                    if trimmedLine.contains("name=") {
                        if let nameRange = trimmedLine.range(of: "name=\"([^\"]+)\"", options: .regularExpression) {
                            filename = String(trimmedLine[nameRange]).replacingOccurrences(of: "name=\"", with: "").replacingOccurrences(of: "\"", with: "")
                        }
                    }
                } else if trimmedLine.hasPrefix("Content-Disposition:") && trimmedLine.contains("attachment") {
                    isAttachment = true
                    
                    if trimmedLine.contains("filename=") {
                        if let filenameRange = trimmedLine.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
                            filename = String(trimmedLine[filenameRange]).replacingOccurrences(of: "filename=\"", with: "").replacingOccurrences(of: "\"", with: "")
                        }
                    }
                } else if trimmedLine.hasPrefix("Content-Transfer-Encoding:") {
                    encoding = trimmedLine.replacingOccurrences(of: "Content-Transfer-Encoding:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmedLine.isEmpty && contentStartIndex == 0 {
                    contentStartIndex = index + 1
                    break
                }
            }
            
            if contentStartIndex > 0 && contentStartIndex < partLines.count {
                let content = partLines[contentStartIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                
                if isAttachment, let filename = filename, let mimeType = mimeType {
                    print("MIME_PARSE: Found attachment - filename=\(filename) mimeType=\(mimeType) encoding=\(encoding ?? "nil")")
                    if encoding?.lowercased() == "base64" {
                        let cleanedContent = content.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                        if let data = Data(base64Encoded: cleanedContent) {
                            let attachment = EmailAttachment(filename: filename, mimeType: mimeType, data: data)
                            attachments.append(attachment)
                            print("MIME_PARSE: Attachment decoded successfully - size=\(data.count)")
                        } else {
                            print("MIME_PARSE: Base64 decode FAILED for \(filename)")
                        }
                    }
                } else if !isAttachment && mimeType?.contains("text/plain") == true {
                    print("MIME_PARSE: Found text/plain body - length=\(content.count)")
                    body = content
                }
            }
        }
        
        print("MIME_PARSE: Final result - body.count=\(body.count) attachments.count=\(attachments.count)")
        return (body: body, attachments: attachments)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
