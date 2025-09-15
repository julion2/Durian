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
                    let imapHandler = IMAPClientHandler()
                    
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
    
    func channelActive(context: ChannelHandlerContext) {
        print("IMAP connection established")
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            print("IMAP Server: \(string)")
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("IMAP Error: \(error)")
        context.close(promise: nil)
    }
}

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed
}