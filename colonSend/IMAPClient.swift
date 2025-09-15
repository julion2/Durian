import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

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
        
        // For now, just simulate login - we'll implement the actual IMAP commands later
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
        
        print("Login attempted for: \(account.auth.username)")
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