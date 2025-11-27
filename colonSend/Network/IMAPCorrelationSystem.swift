//
//  IMAPCorrelationSystem.swift
//  colonSend
//
//  Correlation token system for reliable command-response matching
//

import Foundation

// MARK: - Correlation System

/// Unique identifier for tracking commands through their lifecycle
struct CommandCorrelation: Equatable, Hashable {
    let token: UUID
    let tag: String
    let sequence: UInt64
    let sentAt: Date
    let context: CommandContext
}

/// Context information about what type of command was sent
enum CommandContext: Equatable, Hashable {
    case attachmentFetch(uid: UInt32, section: String, expectedBytes: Int64)
    case bodyFetch(uid: UInt32, section: String)
    case envelope(range: String)
    case bodyStructure(uid: UInt32)
    case generic
    
    static func from(command: String, uid: UInt32? = nil, section: String? = nil) -> CommandContext {
        let upperCommand = command.uppercased()
        
        if upperCommand.contains("BODY.PEEK[") || upperCommand.contains("BODY[") {
            if let uid = uid, let section = section {
                // Try to determine if this is an attachment fetch
                if section != "1" && section != "2" && section != "TEXT" {
                    return .attachmentFetch(uid: uid, section: section, expectedBytes: 0)
                }
                return .bodyFetch(uid: uid, section: section)
            }
        }
        
        if upperCommand.contains("ENVELOPE") {
            let range = command.components(separatedBy: " ")[1]
            return .envelope(range: range)
        }
        
        if upperCommand.contains("BODYSTRUCTURE") {
            if let uid = uid {
                return .bodyStructure(uid: uid)
            }
        }
        
        return .generic
    }
}

/// Enhanced response buffer with chunking support
struct ResponseBuffer {
    struct DataChunk {
        let data: String
        let receivedAt: Date
        let byteCount: Int
    }
    
    private(set) var chunks: [DataChunk] = []
    private(set) var totalBytes: Int = 0
    private(set) var expectedLiterals: [LiteralExpectation] = []
    
    mutating func append(_ data: String) {
        let byteCount = data.utf8.count
        let chunk = DataChunk(data: data, receivedAt: Date(), byteCount: byteCount)
        chunks.append(chunk)
        totalBytes += byteCount
    }
    
    mutating func setExpectedLiterals(_ literals: [LiteralExpectation]) {
        self.expectedLiterals = literals
    }
    
    var isComplete: Bool {
        // Check if we have a tagged completion response
        let hasTaggedCompletion = chunks.contains { chunk in
            chunk.data.range(of: "A\\d+\\s+(OK|NO|BAD)", options: .regularExpression) != nil
        }
        
        // Check if all expected literals are received
        let literalsComplete = expectedLiterals.isEmpty || expectedLiterals.allSatisfy { literal in
            totalBytes >= literal.startOffset + literal.size
        }
        
        return hasTaggedCompletion && literalsComplete
    }
    
    func assembledResponse() -> String {
        chunks.map(\.data).joined()
    }
    
    var debugDescription: String {
        "ResponseBuffer(chunks: \(chunks.count), totalBytes: \(totalBytes), expectedLiterals: \(expectedLiterals.count), complete: \(isComplete))"
    }
}

/// Progress tracking for literal data expectations
struct LiteralExpectation: Equatable {
    let size: Int
    var receivedBytes: Int = 0
    var startOffset: Int = 0
    
    var isComplete: Bool {
        receivedBytes >= size || (size - receivedBytes) <= 2
    }
    
    var progress: Double {
        guard size > 0 else { return 1.0 }
        return Double(receivedBytes) / Double(size)
    }
}

// MARK: - Enhanced Pending Command

struct EnhancedPendingCommand {
    let correlation: CommandCorrelation
    var responseBuffer: ResponseBuffer
    var completion: (Result<String, Error>) -> Void
    var createdAt: Date
    
    var age: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }
    
    var debugDescription: String {
        """
        Command[
          token: \(correlation.token),
          tag: \(correlation.tag),
          seq: \(correlation.sequence),
          context: \(correlation.context),
          age: \(String(format: "%.1fs", age)),
          buffer: \(responseBuffer.debugDescription)
        ]
        """
    }
}
