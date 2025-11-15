//
//  IMAPStateMachine.swift
//  colonSend
//
//  State machine for explicit command lifecycle management
//

import Foundation

// MARK: - Command State Machine

enum CommandState: Equatable {
    case pending(tag: String, sentAt: Date)
    case awaitingContinuation
    case receivingLiterals(progress: LiteralProgress)
    case receivingTaggedResponse
    case completed(response: String)
    case failed(error: IMAPError)
    case timedOut
    
    var canReceiveData: Bool {
        switch self {
        case .pending, .awaitingContinuation, .receivingLiterals, .receivingTaggedResponse:
            return true
        default:
            return false
        }
    }
    
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .timedOut:
            return true
        default:
            return false
        }
    }
    
    static func == (lhs: CommandState, rhs: CommandState) -> Bool {
        switch (lhs, rhs) {
        case (.pending(let t1, _), .pending(let t2, _)): return t1 == t2
        case (.awaitingContinuation, .awaitingContinuation): return true
        case (.receivingLiterals, .receivingLiterals): return true
        case (.receivingTaggedResponse, .receivingTaggedResponse): return true
        case (.completed, .completed): return true
        case (.failed, .failed): return true
        case (.timedOut, .timedOut): return true
        default: return false
        }
    }
}

struct LiteralProgress: Equatable {
    let expectations: [LiteralExpectation]
    var received: [Int: Int] = [:]  // Index -> bytes received
    
    var isComplete: Bool {
        expectations.indices.allSatisfy { index in
            (received[index] ?? 0) >= expectations[index].size
        }
    }
    
    var completionPercentage: Double {
        guard !expectations.isEmpty else { return 1.0 }
        let totalExpected = expectations.reduce(0) { $0 + $1.size }
        let totalReceived = received.values.reduce(0, +)
        guard totalExpected > 0 else { return 1.0 }
        return Double(totalReceived) / Double(totalExpected)
    }
    
    static func == (lhs: LiteralProgress, rhs: LiteralProgress) -> Bool {
        lhs.expectations == rhs.expectations && lhs.received == rhs.received
    }
}

@MainActor
class CommandStateMachine {
    private(set) var state: CommandState
    private let context: CommandContext
    private var responseBuffer: String = ""
    let completion: (Result<String, Error>) -> Void
    private var stateHistory: [(CommandState, Date)] = []
    
    init(tag: String, context: CommandContext, completion: @escaping (Result<String, Error>) -> Void) {
        self.state = .pending(tag: tag, sentAt: Date())
        self.context = context
        self.completion = completion
        self.stateHistory.append((state, Date()))
    }
    
    func transition(to newState: CommandState) throws {
        guard isValidTransition(from: state, to: newState) else {
            throw IMAPError.invalidStateTransition(from: "\(state)", to: "\(newState)")
        }
        
        let oldState = state
        state = newState
        stateHistory.append((newState, Date()))
        
        print("🔄 STATE: \(stateShortName(oldState)) → \(stateShortName(newState))")
        
        // Side effects
        switch newState {
        case .completed(let response):
            completion(.success(response))
        case .failed(let error):
            completion(.failure(error))
        case .timedOut:
            completion(.failure(IMAPError.commandTimeout))
        default:
            break
        }
    }
    
    func handleIncomingData(_ data: String) throws {
        guard state.canReceiveData else {
            throw IMAPError.unexpectedData("Received data in state: \(state)")
        }
        
        responseBuffer += data
        
        // Auto-transition based on buffer content
        if data.contains("{"), case .pending = state {
            // Literal detected - parse expectations
            let literals = parseLiteralExpectations(responseBuffer)
            if !literals.isEmpty {
                try transition(to: .receivingLiterals(progress: LiteralProgress(
                    expectations: literals,
                    received: [:]
                )))
            }
        } else if data.range(of: "^A\\d+\\s+(OK|NO|BAD)", options: .regularExpression) != nil {
            // Tagged completion received
            try transition(to: .receivingTaggedResponse)
            
            // Check if all data received
            if case .receivingLiterals(let progress) = state, progress.isComplete {
                try transition(to: .completed(response: responseBuffer))
            } else if case .pending = state {
                // Simple command with no literals
                try transition(to: .completed(response: responseBuffer))
            } else if case .receivingTaggedResponse = state {
                // Check if we were waiting for literals
                let hasLiterals = responseBuffer.contains("{")
                if !hasLiterals {
                    try transition(to: .completed(response: responseBuffer))
                }
            }
        }
        
        // Update literal progress if in that state
        if case .receivingLiterals(var progress) = state {
            // Recalculate received bytes
            updateLiteralProgress(&progress)
            try transition(to: .receivingLiterals(progress: progress))
            
            // Check completion
            if progress.isComplete && responseBuffer.range(of: "A\\d+\\s+OK", options: .regularExpression) != nil {
                try transition(to: .completed(response: responseBuffer))
            }
        }
    }
    
    private func updateLiteralProgress(_ progress: inout LiteralProgress) {
        guard let bufferData = responseBuffer.data(using: .utf8) else { return }
        
        for (index, expectation) in progress.expectations.enumerated() {
            let startOffset = expectation.startOffset
            let availableBytes = max(0, bufferData.count - startOffset)
            progress.received[index] = min(availableBytes, expectation.size)
        }
    }
    
    private func isValidTransition(from: CommandState, to: CommandState) -> Bool {
        switch (from, to) {
        case (.pending, .awaitingContinuation),
             (.pending, .receivingLiterals),
             (.pending, .receivingTaggedResponse),
             (.pending, .completed),
             (.awaitingContinuation, .receivingLiterals),
             (.awaitingContinuation, .receivingTaggedResponse),
             (.receivingLiterals, .receivingTaggedResponse),
             (.receivingLiterals, .completed),
             (.receivingTaggedResponse, .completed),
             (_, .failed),
             (_, .timedOut):
            return true
        default:
            return false
        }
    }
    
    private func parseLiteralExpectations(_ buffer: String) -> [LiteralExpectation] {
        let literalPattern = "\\{(\\d+)\\}"
        guard let regex = try? NSRegularExpression(pattern: literalPattern, options: []),
              let bufferData = buffer.data(using: .utf8) else {
            return []
        }
        
        let nsRange = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
        let matches = regex.matches(in: buffer, range: nsRange)
        
        var expectations: [LiteralExpectation] = []
        
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let sizeRange = Range(match.range(at: 1), in: buffer),
                  let size = Int(buffer[sizeRange]) else {
                continue
            }
            
            // Calculate byte offset
            let matchEndUtf16 = match.range.upperBound
            let matchEndIndex = buffer.utf16.index(buffer.utf16.startIndex, offsetBy: matchEndUtf16)
            let matchEndStringIndex = String.Index(matchEndIndex, within: buffer)!
            
            let prefixString = String(buffer[..<matchEndStringIndex])
            guard let prefixData = prefixString.data(using: .utf8) else { continue }
            
            var byteOffset = prefixData.count
            
            // Skip CRLF
            while byteOffset < bufferData.count {
                let byte = bufferData[byteOffset]
                if byte == 0x0D || byte == 0x0A {
                    byteOffset += 1
                } else {
                    break
                }
            }
            
            expectations.append(LiteralExpectation(size: size, receivedBytes: 0, startOffset: byteOffset))
        }
        
        return expectations
    }
    
    private func stateShortName(_ state: CommandState) -> String {
        switch state {
        case .pending: return "PENDING"
        case .awaitingContinuation: return "AWAIT_CONT"
        case .receivingLiterals(let progress): return "RX_LITERALS(\(Int(progress.completionPercentage * 100))%)"
        case .receivingTaggedResponse: return "RX_TAGGED"
        case .completed: return "COMPLETED"
        case .failed: return "FAILED"
        case .timedOut: return "TIMEOUT"
        }
    }
    
    func getStateHistory() -> String {
        stateHistory.enumerated().map { index, item in
            let elapsed = index > 0 ? item.1.timeIntervalSince(stateHistory[index-1].1) : 0
            return "\(stateShortName(item.0)) +\(String(format: "%.3fs", elapsed))"
        }.joined(separator: " → ")
    }
}
