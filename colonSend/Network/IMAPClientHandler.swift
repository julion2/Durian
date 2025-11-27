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
        
        // FIX 2: Reduce logging frequency - only log large chunks
        if data.count > 10_000 {
            print("IMAP Server: \(data.count) bytes [Session: \(bytesReceivedInSession)]")
        }
        
        // FIX 4: Consolidate all async work into a single Task
        // This reduces Task creation overhead and MainActor contention
        Task { @MainActor in
            // Append to response buffer (binary-safe)
            imapClient?.appendToResponseBuffer(data)
            
            // Check for tagged completion and parse responses (ASCII protocol only)
            if let asciiString = String(data: data, encoding: .ascii) {
                let lines = asciiString.components(separatedBy: .newlines)
                
                // Check for tagged completion
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("A") && (trimmed.contains(" OK") || trimmed.contains(" NO") || trimmed.contains(" BAD")) {
                        if let spaceIndex = trimmed.firstIndex(of: " ") {
                            let tag = String(trimmed[..<spaceIndex])
                            await imapClient?.waitForBufferStabilization(tag: tag)
                        }
                    }
                }
                
                // Parse LIST responses (ASCII protocol)
                if asciiString.contains("* LIST") {
                    imapClient?.parseFolderResponse(asciiString)
                }
                
                // Parse EXISTS responses (ASCII protocol)
                if asciiString.contains("* ") && asciiString.contains(" EXISTS") {
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
