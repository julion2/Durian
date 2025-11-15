//
//  IMAPClientHandler.swift
//  colonSend
//
//  Network handler for IMAP connection
//

import Foundation
import NIOCore

class IMAPClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    weak var imapClient: IMAPClient?
    private var bytesReceivedInSession: Int = 0
    
    init(imapClient: IMAPClient? = nil) {
        self.imapClient = imapClient
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("IMAP connection established")
        bytesReceivedInSession = 0
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        
        bytesReceivedInSession += buffer.readableBytes
        
        // Read raw bytes (binary-safe)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }
        
        let data = Data(bytes)
        
        // Log ASCII preview for debugging (safe for protocol, not payload)
        if let asciiPreview = String(data: data.prefix(200), encoding: .ascii) {
            print("IMAP Server: \(asciiPreview.prefix(100))... [Session total: \(bytesReceivedInSession) bytes]")
        } else {
            print("IMAP Server: <binary data> [\(data.count) bytes] [Session total: \(bytesReceivedInSession) bytes]")
        }
        
        // Append to response buffer (binary-safe)
        // Note: appendToResponseBuffer is @MainActor, so we dispatch to main thread
        Task { @MainActor in
            imapClient?.appendToResponseBuffer(data)
        }
        
        // Check for tagged completion (ASCII protocol only)
        if let asciiString = String(data: data, encoding: .ascii) {
            let lines = asciiString.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("A") && (trimmed.contains(" OK") || trimmed.contains(" NO") || trimmed.contains(" BAD")) {
                    if let spaceIndex = trimmed.firstIndex(of: " ") {
                        let tag = String(trimmed[..<spaceIndex])
                        print("DRAFT_DEBUG: Tagged OK detected - tag=\(tag)")
                        Task { @MainActor in
                            await imapClient?.waitForBufferStabilization(tag: tag)
                        }
                    }
                }
            }
            
            // Parse LIST responses (ASCII protocol)
            if asciiString.contains("* LIST") {
                Task { @MainActor in
                    imapClient?.parseFolderResponse(asciiString)
                }
            }
            
            // Parse EXISTS responses (ASCII protocol)
            if asciiString.contains("* ") && asciiString.contains(" EXISTS") {
                Task { @MainActor in
                    imapClient?.parseExistsResponse(asciiString)
                }
            }
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelReadComplete()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("IMAP Error: \(error)")
        context.close(promise: nil)
    }
}
