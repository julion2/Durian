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
