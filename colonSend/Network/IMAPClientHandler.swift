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
        let buffer = self.unwrapInboundIn(data)
        
        bytesReceivedInSession += buffer.readableBytes
        
        if let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            print("IMAP Server: \(string) [Session total: \(bytesReceivedInSession) bytes]")
            
            // Always append to response buffer for the current command
            Task { @MainActor in
                imapClient?.appendToResponseBuffer(string)
            }
            
            // Check for tagged completion responses (starts with tag)
            let lines = string.components(separatedBy: .newlines)
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
            
            // IMAP Response Parsing Strategy:
            // - LIST/EXISTS: Immediate (single-line, synchronous)
            // - FETCH: Deferred to handleCommandResponse (multi-line, accumulation required)
            
            // Parse LIST responses
            if string.contains("* LIST") {
                Task { @MainActor in
                    imapClient?.parseFolderResponse(string)
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
    
    func channelReadComplete(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelReadComplete()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("IMAP Error: \(error)")
        context.close(promise: nil)
    }
}
