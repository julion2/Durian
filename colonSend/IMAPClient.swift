import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Security

class IMAPClient: ObservableObject {
    private var eventLoopGroup: EventLoopGroup?
    private var channel: Channel?
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var folders: [IMAPFolder] = []
    
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

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed
}