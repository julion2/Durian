import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Security
import Combine

@MainActor
class IMAPClient: ObservableObject {
    private var eventLoopGroup: EventLoopGroup?
    private var channel: Channel?
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var folders: [IMAPFolder] = []
    private var accountId: String = ""
    @Published var emails: [IMAPEmail] = []
    @Published var selectedFolderName: String?
    @Published var isLoadingEmails = false
    @Published var loadingProgress: String = ""
    @Published var hasMoreMessages = false
    
    private var selectedFolder: String?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var commandCounter = 1000
    private var pendingCommands: [String: CommandCompletion] = [:]
    private var paginationState = PaginationState()
    
    init() {
        setupSettingsObserver()
    }
    
    func connect(account: MailAccount) async {
        print("🔵 Starting IMAP connection to \(account.imap.host):\(account.imap.port)")
        self.accountId = account.email
        connectionStatus = "Connecting..."
        
        do {
            print("🔵 Creating event loop group...")
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = group
            
            print("🔵 Setting up bootstrap for \(account.imap.host):\(account.imap.port) (SSL: \(account.imap.ssl))")
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .channelOption(ChannelOptions.connectTimeout, value: TimeAmount.seconds(30))
                .channelInitializer { channel in
                    print("🔵 Initializing channel pipeline...")
                    let imapHandler = IMAPClientHandler(imapClient: self)
                    
                    if account.imap.ssl {
                        print("🔵 Adding SSL handler for TLS connection")
                        do {
                            let sslContext = try NIOSSLContext(configuration: .clientDefault)
                            let hostname = account.imap.host
                            
                            // Create SSL handler in a way that bypasses Sendable requirements
                            let sslHandlerResult = Result<any ChannelHandler, Error> {
                                try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)
                            }
                            
                            switch sslHandlerResult {
                            case .success(let sslHandler):
                                return channel.pipeline.addHandler(sslHandler).flatMap { _ in
                                    channel.pipeline.addHandler(imapHandler)
                                }
                            case .failure(let error):
                                print("❌ Failed to create SSL handler: \(error)")
                                return channel.pipeline.addHandler(imapHandler)
                            }
                        } catch {
                            print("❌ Failed to create SSL context: \(error)")
                            return channel.pipeline.addHandler(imapHandler)
                        }
                    } else {
                        print("🔵 Using plain connection (no SSL)")
                        return channel.pipeline.addHandler(imapHandler)
                    }
                }
            
            print("🔵 Attempting connection to \(account.imap.host):\(account.imap.port)...")
            let channel = try await bootstrap.connect(host: account.imap.host, port: account.imap.port).get()
            self.channel = channel
            print("✅ TCP connection established!")
            
            // Attempt login
            try await login(account: account)
            
            isConnected = true
            connectionStatus = "Connected"
            
            // Start auto-refresh timer
            setupAutoRefresh()
            
        } catch {
            connectionStatus = "Error: \(error.localizedDescription)"
            print("❌ IMAP connection error: \(error)")
            print("❌ Error details: \(String(describing: error))")
        }
    }
    
    private func login(account: MailAccount) async throws {
        guard self.channel != nil else {
            throw IMAPError.noConnection
        }
        
        connectionStatus = "Authenticating..."
        
        print("🔵 Retrieving password from keychain...")
        guard let password = getPasswordFromKeychain(service: account.auth.passwordKeychain ?? "", account: account.auth.username) else {
            throw IMAPError.authenticationFailed
        }
        
        print("🔵 Sending IMAP LOGIN command...")
        let loginCommand = "LOGIN \"\(account.auth.username)\" \"\(password)\""
        
        let _ = try await executeCommand(loginCommand)
        print("✅ Login completed for: \(account.auth.username)")
        
        // Fetch folder list
        try await fetchFolders()
    }
    
    private func fetchFolders() async throws {
        print("🔵 Fetching folder list...")
        let listCommand = "LIST \"\" \"*\""
        
        let _ = try await executeCommand(listCommand)
        print("✅ Folder list retrieved")
    }
    
    func parseFolderResponse(_ response: String) {
        // Parse: * LIST (\HasNoChildren \Drafts) "/" "Drafts"
        let lines = response.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("* LIST") {
                if let folder = parseListLine(line) {
                    if !folders.contains(where: { $0.name == folder.name }) {
                        Task { @MainActor in
                            folders.append(folder)
                            print("📁 Added folder: \(folder.name) (\(folder.icon)) - Total folders: \(folders.count)")
                        }
                    }
                }
            }
        }
    }
    
    private func parseListLine(_ line: String) -> IMAPFolder? {
        // Parse both quoted and unquoted formats:
        // * LIST (\HasNoChildren \Drafts) "/" "Drafts" 
        // * LIST (\HasNoChildren) "/" INBOX
        
        // First try quoted pattern: * LIST (attrs) "separator" "name"
        let quotedPattern = #"\* LIST \(([^)]*)\) "([^"]*)" "([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: quotedPattern),
           let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..<line.endIndex, in: line)),
           match.numberOfRanges >= 4 {
            
            let attributesString = String(line[Range(match.range(at: 1), in: line)!])
            let separator = String(line[Range(match.range(at: 2), in: line)!])
            let name = String(line[Range(match.range(at: 3), in: line)!])
            
            let attributes = attributesString.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            return IMAPFolder(name: name, attributes: attributes, separator: separator, accountId: accountId)
        }
        
        // Try unquoted pattern: * LIST (attrs) separator name
        let unquotedPattern = #"\* LIST \(([^)]*)\) ([^\s]+) (.+)"#
        if let regex = try? NSRegularExpression(pattern: unquotedPattern),
           let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..<line.endIndex, in: line)),
           match.numberOfRanges >= 4 {
            
            let attributesString = String(line[Range(match.range(at: 1), in: line)!])
            let separator = String(line[Range(match.range(at: 2), in: line)!])
            let name = String(line[Range(match.range(at: 3), in: line)!])
            
            let attributes = attributesString.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            
            return IMAPFolder(name: name, attributes: attributes, separator: separator, accountId: accountId)
        }
        
        return nil
    }
    
    func selectFolder(_ folderName: String) async {
        guard self.channel != nil, isConnected else {
            print("❌ Cannot select folder: not connected")
            return
        }
        
        print("🔵 Selecting folder: \(folderName)")
        self.selectedFolder = folderName
        
        // Clear previous emails and update selected folder
        emails.removeAll()
        selectedFolderName = folderName
        
        let selectCommand = "SELECT \"\(folderName)\""
        
        do {
            let _ = try await executeCommand(selectCommand)
            print("✅ SELECT completed for \(folderName)")
            
            // fetchEmails() will be called automatically when parseExistsResponse() is triggered
        } catch {
            print("❌ Failed to select folder: \(error)")
        }
    }
    
    private func fetchEmails() async {
        guard selectedFolder != nil else {
            print("❌ Cannot fetch emails: no folder selected")
            return
        }
        
        await loadEmails(loadMore: false)
    }
    
    func loadMoreEmails() async {
        guard selectedFolder != nil else {
            print("❌ Cannot load more emails: no folder selected")
            return
        }
        
        await loadEmails(loadMore: true)
    }
    
    private func loadEmails(loadMore: Bool) async {
        guard let folder = selectedFolder, isConnected else { return }
        
        if loadMore && !paginationState.hasMoreMessages {
            print("📭 No more emails to load")
            return
        }
        
        isLoadingEmails = true
        if loadMore {
            paginationState.isLoadingMore = true
            loadingProgress = "Loading more emails..."
        } else {
            // Don't reset totalMessages if we already have it from EXISTS response
            let existingTotal = paginationState.totalMessages
            paginationState.reset()
            paginationState.totalMessages = existingTotal
            emails.removeAll()
            loadingProgress = "Loading emails..."
        }
        
        print("🔵 \(loadMore ? "Loading more" : "Fetching") emails from \(folder)...")
        
        do {
            // Calculate message range for pagination
            let startIndex: Int
            let endIndex: Int
            
            if loadMore {
                startIndex = paginationState.currentPage * paginationState.pageSize + 1
                endIndex = min(startIndex + paginationState.pageSize - 1, paginationState.totalMessages)
            } else {
                // For initial load, get the most recent messages
                startIndex = max(1, paginationState.totalMessages - paginationState.pageSize + 1)
                endIndex = paginationState.totalMessages
            }
            
            if startIndex <= endIndex && endIndex > 0 {
                let fetchCommand = "FETCH \(startIndex):\(endIndex) (UID FLAGS ENVELOPE BODYSTRUCTURE)"
                _ = try await executeCommand(fetchCommand)
                
                let loadedCount = emails.count
                loadingProgress = "Loaded \(loadedCount) of \(paginationState.totalMessages) messages"
                
                if loadMore {
                    paginationState.nextPage()
                }
                
                print("✅ FETCH command completed for range \(startIndex):\(endIndex)")
            } else {
            }
            
        } catch {
            print("❌ Failed to fetch emails: \(error)")
            loadingProgress = "Failed to load emails: \(error.localizedDescription)"
        }
        
        isLoadingEmails = false
        paginationState.isLoadingMore = false
        hasMoreMessages = paginationState.hasMoreMessages
    }
    
    func parseEmailResponse(_ response: String) {
        // Parse: * 1 FETCH (UID 1 ... ENVELOPE ("date" "subject" (("from"...
        
        if response.contains("BODYSTRUCTURE") {
            // First parse the email data from ENVELOPE
            if let email = parseEmailFetch(response) {
                if !emails.contains(where: { $0.uid == email.uid }) {
                    Task { @MainActor in
                        emails.append(email)
                        print("📧 Added email: \(email.subject)")
                    }
                }
            }
            // Then parse BODYSTRUCTURE and fetch body
            parseBodyStructureAndFetchBody(response: response)
        } else if let email = parseEmailFetch(response) {
            if !emails.contains(where: { $0.uid == email.uid }) {
                Task { @MainActor in
                    emails.append(email)
                    print("📧 Added email: \(email.subject)")
                }
            }
        }
    }
    
    private func parseEmailFetch(_ response: String) -> IMAPEmail? {
        // Enhanced IMAP FETCH response parsing
        
        // Must contain FETCH to be a valid email response
        guard response.contains("FETCH") else {
            return nil
        }
        
        var subject = "No Subject"
        var from = "Unknown Sender"
        var date = "Unknown Date"
        var uid: UInt32 = 0
        var isRead = false
        
        // Parse UID from FETCH line
        if let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) {
            let uidText = String(response[uidMatch])
            if let uidString = uidText.components(separatedBy: " ").last,
               let parsedUID = UInt32(uidString) {
                uid = parsedUID
            }
        }
        
        // Parse FLAGS to determine read status
        if let flagsMatch = response.range(of: "FLAGS \\(([^)]+)\\)", options: .regularExpression) {
            let flagsText = String(response[flagsMatch])
            isRead = flagsText.contains("\\Seen")
        }
        
        // Parse ENVELOPE data - format: ENVELOPE ("date" "subject" (("name" NIL "user" "domain")) ...)
        if let envelopeStart = response.range(of: "ENVELOPE \\(", options: .regularExpression) {
            let envelopeContent = String(response[envelopeStart.upperBound...])
            
            // Parse ENVELOPE fields in order: date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id
            let envelopeFields = parseEnvelopeFields(envelopeContent)
            
            if envelopeFields.count >= 3 {
                date = cleanQuotedString(envelopeFields[0])
                subject = cleanQuotedString(envelopeFields[1])
                from = parseEmailAddress(envelopeFields[2])
            }
        }

        guard uid > 0 else { 
            return nil 
        }
        
        return IMAPEmail(
            uid: uid,
            subject: subject,
            from: from,
            date: date,
            body: nil,
            isRead: isRead
        )
    }
    
    private func parseEnvelopeFields(_ envelope: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        var escape = false
        
        for char in envelope {
            if escape {
                current.append(char)
                escape = false
                continue
            }
            
            if char == "\\" {
                escape = true
                current.append(char)
                continue
            }
            
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
                continue
            }
            
            if !inQuotes {
                if char == "(" {
                    depth += 1
                    current.append(char)
                } else if char == ")" {
                    depth -= 1
                    current.append(char)
                    if depth == 0 && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                        current = ""
                    }
                } else if char == " " && depth == 0 {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                        current = ""
                    }
                } else {
                    current.append(char)
                }
            } else {
                current.append(char)
            }
        }
        
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return fields
    }
    
    private func cleanQuotedString(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed == "NIL" ? "" : trimmed
    }
    
    private func parseEmailAddress(_ addressField: String) -> String {
        // Parse format: (("name" NIL "user" "domain"))
        if addressField.contains("((") {
            // Extract from nested parentheses
            let pattern = "\\(\\(\"([^\"]*)\".+?\"([^\"]+)\".+?\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: addressField, range: NSRange(addressField.startIndex..<addressField.endIndex, in: addressField)) {
                let name = String(addressField[Range(match.range(at: 1), in: addressField)!])
                let user = String(addressField[Range(match.range(at: 2), in: addressField)!])
                let domain = String(addressField[Range(match.range(at: 3), in: addressField)!])
                
                if !name.isEmpty {
                    return "\(name) <\(user)@\(domain)>"
                } else {
                    return "\(user)@\(domain)"
                }
            }
        }
        return addressField
    }

    private func parseBodyStructureAndFetchBody(response: String) {
        guard let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) else {
            return
        }

        let uidString = String(response[uidMatch]).components(separatedBy: " ").last!
        let uid = UInt32(uidString)!
        
        // Look for BODYSTRUCTURE content
        if let bodyStructStart = response.range(of: "BODYSTRUCTURE \\(", options: .regularExpression) {
            let bodyStructContent = String(response[bodyStructStart.upperBound...])
            
            // For simple single-part message, the section is "1"
            if bodyStructContent.contains("\"TEXT\" \"PLAIN\"") {
                Task {
                    await fetchBody(uid: uid, section: "1")
                }
            } else {
                Task {
                    await fetchBody(uid: uid, section: "1")
                }
            }
        }
    }

    private func fetchBody(uid: UInt32, section: String) async {
        let command = "UID FETCH \(uid) (BODY[\(section)])"
        do {
            let response = try await executeCommand(command)
            
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                if let bodyRange = response.range(of: "BODY\\[[\\d.]+\\]\\s*\\{(\\d+)\\}", options: .regularExpression) {
                    let afterBodyTag = String(response[bodyRange.upperBound...])
                    
                    // Extract just the email content, stopping at FLAGS or other IMAP responses
                    var bodyContent = afterBodyTag
                    
                    // Remove trailing IMAP protocol responses
                    if let flagsStart = bodyContent.range(of: "\\s+FLAGS\\s*\\(", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<flagsStart.lowerBound])
                    }
                    
                    // Remove trailing command completion responses
                    if let completionStart = bodyContent.range(of: "\\s+A\\d+\\s+OK", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<completionStart.lowerBound])
                    }
                    
                    // Remove trailing parentheses from IMAP responses
                    if let trailingParen = bodyContent.range(of: "\\s*\\)\\s*$", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<trailingParen.lowerBound])
                    }
                    
                    let cleanBody = bodyContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    emails[emailIndex].body = cleanBody.isEmpty ? "No content available" : cleanBody
                }
            }
        } catch {
            print("❌ Failed to fetch body for UID \(uid): \(error)")
        }
    }
    
    func parseExistsResponse(_ response: String) {
        let lines = response.components(separatedBy: .newlines)
        for line in lines {
            if line.contains(" EXISTS") {
                let components = line.components(separatedBy: .whitespaces)
                if let countString = components.first(where: { $0.allSatisfy(\.isNumber) }),
                   let count = Int(countString) {
                    paginationState.totalMessages = count
                    loadingProgress = "Found \(count) messages"
                    
                    // Now that we know the message count, fetch the emails
                    if count > 0 {
                        Task {
                            await fetchEmails()
                        }
                    }
                }
            }
        }
    }
    
    private func getPasswordFromKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let password = String(data: data, encoding: .utf8) {
            return password
        } else {
            print("❌ Failed to retrieve password from keychain for \(account): \(status)")
            return nil
        }
    }
    
    func disconnect() async {
        connectionStatus = "Disconnecting..."
        
        try? await channel?.close()
        eventLoopGroup = nil
        
        isConnected = false
        connectionStatus = "Disconnected"
        
        // Stop auto-refresh timer
        stopAutoRefresh()
    }
    
    // MARK: - Auto-refresh functionality
    
    private func setupSettingsObserver() {
        SettingsManager.shared.$settings
            .sink { [weak self] settings in
                self?.updateAutoRefresh(with: settings)
            }
            .store(in: &cancellables)
    }
    
    private func updateAutoRefresh(with settings: AppSettings) {
        stopAutoRefresh()
        
        if settings.autoFetchEnabled && isConnected {
            setupAutoRefresh()
        }
    }
    
    private func setupAutoRefresh() {
        let settings = SettingsManager.shared.settings
        
        guard settings.autoFetchEnabled else {
            return
        }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.autoFetchInterval, repeats: true) { _ in
            Task { @MainActor in
                guard let folder = self.selectedFolder else { return }
                
                await self.refreshCurrentFolder()
            }
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    private func refreshCurrentFolder() async {
        guard let folderName = selectedFolder, isConnected else { return }
        
        print("🔄 Refreshing \(folderName)...")
        await fetchEmails()
    }
    
    // MARK: - Public Methods
    
    func reloadCurrentFolder() async {
        
        guard let folderName = selectedFolder, isConnected else {
            print("⚠️ Cannot reload: no folder selected or not connected")
            return
        }
        
        print("🔄 Manual reload requested for \(folderName)")
        await refreshCurrentFolder()
    }
    
    func markAsRead(uid: UInt32) async {
        guard isConnected else {
            print("⚠️ Cannot mark as read: not connected")
            return
        }
        
        print("📧 Marking email UID \(uid) as read")
        
        do {
            let storeCommand = "UID STORE \(uid) +FLAGS (\\Seen)"
            let _ = try await executeCommand(storeCommand)
            
            // Update local email state
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].isRead = true
                print("✅ Email UID \(uid) marked as read locally")
            }
            
        } catch {
            print("❌ Failed to mark email as read: \(error)")
        }
    }
    
    func markAsUnread(uid: UInt32) async {
        guard isConnected else {
            print("⚠️ Cannot mark as unread: not connected")
            return
        }
        
        print("📧 Marking email UID \(uid) as unread")
        
        do {
            let storeCommand = "UID STORE \(uid) -FLAGS (\\Seen)"
            let _ = try await executeCommand(storeCommand)
            
            // Update local email state
            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                emails[emailIndex].isRead = false
                print("✅ Email UID \(uid) marked as unread locally")
            }
            
        } catch {
            print("❌ Failed to mark email as unread: \(error)")
        }
    }
    
    func toggleReadStatus(uid: UInt32) async {
        guard let email = emails.first(where: { $0.uid == uid }) else {
            print("❌ Email with UID \(uid) not found")
            return
        }
        
        if email.isRead {
            await markAsUnread(uid: uid)
        } else {
            await markAsRead(uid: uid)
        }
    }
    
    // MARK: - Command Execution System
    
    private func generateCommandTag() -> String {
        commandCounter += 1
        return "A\(commandCounter)"
    }
    
    private func executeCommand(_ command: String, timeout: TimeInterval = 30.0) async throws -> String {
        guard let channel = self.channel else {
            throw IMAPError.noConnection
        }
        
        let tag = generateCommandTag()
        let fullCommand = "\(tag) \(command)\r\n"
        
        return try await withCheckedThrowingContinuation { continuation in
            pendingCommands[tag] = { result in
                continuation.resume(with: result)
            }
            
            // Set up timeout
            Task { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let completion = pendingCommands.removeValue(forKey: tag) {
                    completion(.failure(IMAPError.commandTimeout))
                }
            }
            
            // Send command
            var buffer = channel.allocator.buffer(capacity: fullCommand.count)
            buffer.writeString(fullCommand)
            
            channel.writeAndFlush(buffer).whenComplete { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        print("✅ Command sent: \(tag) \(command)")
                    case .failure(let error):
                        if let completion = self.pendingCommands.removeValue(forKey: tag) {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }
    
    func handleCommandResponse(tag: String, response: String, isComplete: Bool) {
        guard let completion = pendingCommands[tag] else { return }
        
        if isComplete {
            pendingCommands.removeValue(forKey: tag)
            completion(.success(response))
        }
    }

    func parseBodyResponse(_ response: String) {
        if let uidMatch = response.range(of: "UID (\\d+)", options: .regularExpression) {
            let uidString = String(response[uidMatch]).components(separatedBy: " ").last!
            let uid = UInt32(uidString)!

            if let emailIndex = emails.firstIndex(where: { $0.uid == uid }) {
                if let bodyRange = response.range(of: "BODY\\[[\\d.]+\\]\\s*\\{(\\d+)\\}", options: .regularExpression) {
                    var bodyContent = String(response[bodyRange.upperBound...])
                    
                    // Clean up IMAP protocol data from body content
                    if let flagsStart = bodyContent.range(of: "\\s+FLAGS\\s*\\(", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<flagsStart.lowerBound])
                    }
                    
                    if let completionStart = bodyContent.range(of: "\\s+A\\d+\\s+OK", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<completionStart.lowerBound])
                    }
                    
                    if let trailingParen = bodyContent.range(of: "\\s*\\)\\s*$", options: .regularExpression) {
                        bodyContent = String(bodyContent[..<trailingParen.lowerBound])
                    }
                    
                    let cleanBody = bodyContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    emails[emailIndex].body = cleanBody.isEmpty ? "No content available" : cleanBody
                }
            }
        }
    }
}

private class IMAPClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var imapClient: IMAPClient?
    
    init(imapClient: IMAPClient? = nil) {
        self.imapClient = imapClient
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("IMAP connection established")
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            print("IMAP Server: \(string)")
            
            // Parse command completion responses (starts with tag)
            let lines = string.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("A") && (line.contains(" OK ") || line.contains(" NO ") || line.contains(" BAD ")) {
                    if let spaceIndex = line.firstIndex(of: " ") {
                        let tag = String(line[..<spaceIndex])
                        Task { @MainActor in
                            imapClient?.handleCommandResponse(tag: tag, response: string, isComplete: true)
                        }
                    }
                }
            }
            
            // Parse LIST responses
            if string.contains("* LIST") {
                Task { @MainActor in
                    imapClient?.parseFolderResponse(string)
                }
            }
            
            // Parse FETCH responses
            if string.contains("* ") && string.contains("FETCH") {
                Task { @MainActor in
                    if string.contains("BODY[") {
                        imapClient?.parseBodyResponse(string)
                    } else {
                        imapClient?.parseEmailResponse(string)
                    }
                }
            }
            
            // Parse EXISTS responses for message count
            if string.contains("* ") && string.contains(" EXISTS") {
                Task { @MainActor in
                    imapClient?.parseExistsResponse(string)
                }
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("IMAP Error: \(error)")
        context.close(promise: nil)
    }
}

struct IMAPFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let attributes: [String]
    let separator: String
    let accountId: String
    
    var icon: String {
        if attributes.contains("\\Inbox") || name == "INBOX" {
            return "tray"
        } else if attributes.contains("\\Drafts") {
            return "doc"
        } else if attributes.contains("\\Sent") {
            return "paperplane"
        } else if attributes.contains("\\Junk") {
            return "xmark.bin"
        } else if attributes.contains("\\Trash") {
            return "trash"
        } else {
            return "folder"
        }
    }
}

struct IMAPEmail: Identifiable, Hashable {
    let id = UUID()
    let uid: UInt32
    let subject: String
    let from: String
    let date: String
    var body: String?
    var isRead: Bool
}

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed
    case commandTimeout
    case invalidResponse
}

class PaginationState {
    var currentPage = 0
    var pageSize = 50
    var totalMessages = 0
    var isLoadingMore = false
    var hasMoreMessages: Bool {
        return (currentPage * pageSize) < totalMessages
    }
    
    func reset() {
        currentPage = 0
        totalMessages = 0
        isLoadingMore = false
    }
    
    func nextPage() {
        currentPage += 1
    }
}

typealias CommandCompletion = (Result<String, Error>) -> Void

extension String {
    func matches(pattern: String) -> Bool {
        return range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var accounts: [MailAccount] = []
    @Published var imapClients: [String: IMAPClient] = [:]
    @Published var allFolders: [IMAPFolder] = []
    @Published var allEmails: [IMAPEmail] = []
    @Published var selectedAccount: String?
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        loadAccounts()
    }
    
    private func loadAccounts() {
        accounts = ConfigManager.shared.accounts
        print("🔧 Loaded \(accounts.count) accounts")
    }
    
    func connectToAllAccounts() async {
        print("🔧 Connecting to \(accounts.count) accounts...")
        
        for account in accounts {
            let client = IMAPClient()
            imapClients[account.email] = client
            
            // Subscribe to client changes
            client.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
                self?.updateAggregatedData()
            }.store(in: &cancellables)
            
            Task {
                await client.connect(account: account)
                await updateAggregatedData()
            }
        }
    }
    
    private func updateAggregatedData() {
        // Aggregate all folders from all clients
        allFolders = imapClients.values.flatMap { $0.folders }
        
        // Aggregate emails from selected account
        if let selectedAccount = selectedAccount,
           let client = imapClients[selectedAccount] {
            allEmails = client.emails
            isLoadingEmails = client.isLoadingEmails
            loadingProgress = client.loadingProgress
        } else if let firstClient = imapClients.values.first {
            // Default to first account if none selected
            allEmails = firstClient.emails
            isLoadingEmails = firstClient.isLoadingEmails
            loadingProgress = firstClient.loadingProgress
        }
    }
    
    func selectFolder(_ folderName: String, accountId: String) async {
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
}

struct IMAPCommand {
    let tag: String
    let command: String
    let completion: CommandCompletion
    let timeout: TimeInterval
    
    init(tag: String, command: String, timeout: TimeInterval = 30.0, completion: @escaping CommandCompletion) {
        self.tag = tag
        self.command = command
        self.completion = completion
        self.timeout = timeout
    }
}