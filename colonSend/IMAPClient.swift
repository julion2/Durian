import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Security
import Combine

class IMAPClient: ObservableObject {
    private var eventLoopGroup: EventLoopGroup?
    private var channel: Channel?
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var folders: [IMAPFolder] = []
    @Published var emails: [IMAPEmail] = []
    @Published var selectedFolderName: String?
    private var selectedFolder: String?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupSettingsObserver()
    }
    
    func connect(account: MailAccount) async {
        print("🔵 Starting IMAP connection to \(account.imap.host):\(account.imap.port)")
        await MainActor.run {
            connectionStatus = "Connecting..."
        }
        
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
                            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: account.imap.host)
                            return channel.pipeline.addHandler(sslHandler).flatMap {
                                channel.pipeline.addHandler(imapHandler)
                            }
                        } catch {
                            print("❌ Failed to create SSL handler: \(error)")
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
            
            await MainActor.run {
                isConnected = true
                connectionStatus = "Connected"
            }
            
            // Start auto-refresh timer
            setupAutoRefresh()
            
        } catch {
            await MainActor.run {
                connectionStatus = "Error: \(error.localizedDescription)"
            }
            print("❌ IMAP connection error: \(error)")
            print("❌ Error details: \(String(describing: error))")
        }
    }
    
    private func login(account: MailAccount) async throws {
        guard let channel = self.channel else {
            throw IMAPError.noConnection
        }
        
        await MainActor.run {
            connectionStatus = "Authenticating..."
        }
        
        print("🔵 Retrieving password from keychain...")
        guard let password = getPasswordFromKeychain(service: account.auth.passwordKeychain ?? "", account: account.auth.username) else {
            throw IMAPError.authenticationFailed
        }
        
        print("🔵 Sending IMAP LOGIN command...")
        let loginCommand = "A001 LOGIN \"\(account.auth.username)\" \"\(password)\"\r\n"
        
        var buffer = channel.allocator.buffer(capacity: loginCommand.count)
        buffer.writeString(loginCommand)
        
        let _ = try await channel.writeAndFlush(buffer).get()
        print("✅ LOGIN command sent")
        
        // Wait a moment for server response
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        print("✅ Login completed for: \(account.auth.username)")
        
        // Fetch folder list
        try await fetchFolders()
    }
    
    private func fetchFolders() async throws {
        guard let channel = self.channel else {
            throw IMAPError.noConnection
        }
        
        print("🔵 Fetching folder list...")
        let listCommand = "A002 LIST \"\" \"*\"\r\n"
        
        var buffer = channel.allocator.buffer(capacity: listCommand.count)
        buffer.writeString(listCommand)
        
        let _ = try await channel.writeAndFlush(buffer).get()
        print("✅ LIST command sent")
        
        // Wait for folder response
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        print("✅ Folder list retrieved")
    }
    
    func parseFolderResponse(_ response: String) {
        // Parse: * LIST (\HasNoChildren \Drafts) "/" "Drafts"
        let lines = response.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("* LIST") {
                if let folder = parseListLine(line) {
                    Task { @MainActor in
                        if !folders.contains(where: { $0.name == folder.name }) {
                            folders.append(folder)
                            print("📁 Added folder: \(folder.name) (\(folder.icon)) - Total folders: \(folders.count)")
                        }
                    }
                }
            }
        }
    }
    
    private func parseListLine(_ line: String) -> IMAPFolder? {
        // Parse: * LIST (\HasNoChildren \Drafts) "/" "Drafts"
        let pattern = #"\* LIST \(([^)]*)\) "([^"]*)" "([^"]*)""#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        
        guard let match = regex?.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 4 else {
            return nil
        }
        
        let attributesString = String(line[Range(match.range(at: 1), in: line)!])
        let separator = String(line[Range(match.range(at: 2), in: line)!])
        let name = String(line[Range(match.range(at: 3), in: line)!])
        
        let attributes = attributesString.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        
        return IMAPFolder(name: name, attributes: attributes, separator: separator)
    }
    
    func selectFolder(_ folderName: String) async {
        guard let channel = self.channel, isConnected else {
            print("❌ Cannot select folder: not connected")
            return
        }
        
        print("🔵 Selecting folder: \(folderName)")
        self.selectedFolder = folderName
        
        // Clear previous emails and update selected folder
        await MainActor.run {
            emails.removeAll()
            selectedFolderName = folderName
        }
        
        let selectCommand = "A003 SELECT \"\(folderName)\"\r\n"
        var buffer = channel.allocator.buffer(capacity: selectCommand.count)
        buffer.writeString(selectCommand)
        
        do {
            let _ = try await channel.writeAndFlush(buffer).get()
            print("✅ SELECT command sent for \(folderName)")
            
            // Wait for response and then fetch emails
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await fetchEmails()
        } catch {
            print("❌ Failed to select folder: \(error)")
        }
    }
    
    private func fetchEmails() async {
        guard let channel = self.channel, let folder = selectedFolder else {
            print("❌ Cannot fetch emails: no folder selected")
            return
        }
        
        print("🔵 Fetching emails from \(folder)...")
        
        // Fetch recent 10 emails with headers
        let fetchCommand = "A004 FETCH 1:10 (UID FLAGS ENVELOPE BODY[HEADER.FIELDS (SUBJECT FROM DATE)])\r\n"
        var buffer = channel.allocator.buffer(capacity: fetchCommand.count)
        buffer.writeString(fetchCommand)
        
        do {
            let _ = try await channel.writeAndFlush(buffer).get()
            print("✅ FETCH command sent")
            
            // Wait for email response
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            print("✅ Emails fetched")
        } catch {
            print("❌ Failed to fetch emails: \(error)")
        }
    }
    
    func parseEmailResponse(_ response: String) {
        // Parse: * 1 FETCH (UID 1 ... ENVELOPE ("date" "subject" (("from"...
        if let email = parseEmailFetch(response) {
            Task { @MainActor in
                if !emails.contains(where: { $0.uid == email.uid }) {
                    emails.append(email)
                    print("📧 Added email: \(email.subject) - Total emails: \(emails.count)")
                }
            }
        }
    }
    
    private func parseEmailFetch(_ response: String) -> IMAPEmail? {
        // Basic parsing for ENVELOPE response
        // Look for Subject and From in the response
        
        let lines = response.components(separatedBy: .newlines)
        var subject = "No Subject"
        var from = "Unknown Sender"
        var date = "Unknown Date"
        var uid: UInt32 = 0
        
        for line in lines {
            if line.contains("Subject:") {
                if let subjectMatch = line.range(of: "Subject: (.+)$", options: .regularExpression) {
                    subject = String(line[subjectMatch]).replacingOccurrences(of: "Subject: ", with: "")
                }
            }
            
            if line.contains("From:") {
                if let fromMatch = line.range(of: "From: (.+)$", options: .regularExpression) {
                    from = String(line[fromMatch]).replacingOccurrences(of: "From: ", with: "")
                }
            }
            
            if line.contains("Date:") {
                if let dateMatch = line.range(of: "Date: (.+)$", options: .regularExpression) {
                    date = String(line[dateMatch]).replacingOccurrences(of: "Date: ", with: "")
                }
            }
            
            if line.contains("UID") {
                let uidPattern = "UID (\\d+)"
                if let regex = try? NSRegularExpression(pattern: uidPattern),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) {
                    let uidString = String(line[Range(match.range(at: 1), in: line)!])
                    uid = UInt32(uidString) ?? 0
                }
            }
        }
        
        guard uid > 0 else { return nil }
        
        return IMAPEmail(
            uid: uid,
            subject: subject,
            from: from,
            date: date,
            body: "Click to load content..."
        )
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
            print("✅ Password retrieved from keychain for \(account)")
            return password
        } else {
            print("❌ Failed to retrieve password from keychain for \(account): \(status)")
            return nil
        }
    }
    
    func disconnect() async {
        await MainActor.run {
            connectionStatus = "Disconnecting..."
        }
        
        try? await channel?.close()
        try? eventLoopGroup?.syncShutdownGracefully()
        
        await MainActor.run {
            isConnected = false
            connectionStatus = "Disconnected"
        }
        
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
            print("🔄 Auto-refresh disabled")
            return
        }
        
        Task { @MainActor in
            refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.autoFetchInterval, repeats: true) { [weak self] _ in
                guard let self = self, let folder = self.selectedFolder else { return }
                
                print("🔄 Auto-refreshing emails for \(folder)...")
                Task {
                    await self.refreshCurrentFolder()
                }
            }
            print("🔄 Auto-refresh enabled: every \(settings.autoFetchInterval)s")
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        print("🔄 Auto-refresh stopped")
    }
    
    private func refreshCurrentFolder() async {
        guard let folderName = selectedFolder, isConnected else { return }
        
        print("🔄 Refreshing \(folderName)...")
        await fetchEmails()
    }
    
    // MARK: - Public Methods
    
    func reloadCurrentFolder() async {
        print("🔄 DEBUG: reloadCurrentFolder() called")
        print("🔄 DEBUG: selectedFolder = \(selectedFolder ?? "nil")")
        print("🔄 DEBUG: isConnected = \(isConnected)")
        print("🔄 DEBUG: channel = \(channel != nil ? "available" : "nil")")
        
        guard let folderName = selectedFolder, isConnected else {
            print("⚠️ Cannot reload: no folder selected or not connected")
            return
        }
        
        print("🔄 Manual reload requested for \(folderName)")
        await refreshCurrentFolder()
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
            
            // Parse LIST responses
            if string.contains("* LIST") {
                imapClient?.parseFolderResponse(string)
            }
            
            // Parse FETCH responses
            if string.contains("* ") && string.contains("FETCH") {
                imapClient?.parseEmailResponse(string)
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
    let body: String
}

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed
}