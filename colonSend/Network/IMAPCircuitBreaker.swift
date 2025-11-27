//
//  IMAPCircuitBreaker.swift
//  colonSend
//
//  Circuit breaker pattern for fault tolerance in attachment downloads
//

import Foundation

/// Circuit breaker for protecting against cascade failures
@MainActor
class AttachmentFetchCircuitBreaker {
    enum State {
        case closed  // Normal operation
        case open    // Failures detected, rejecting requests
        case halfOpen  // Testing if system recovered
    }
    
    private var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureTime: Date?
    private var successCount: Int = 0
    
    private let failureThreshold: Int = 5  // Open after 5 failures
    private let successThreshold: Int = 2  // Close after 2 successes in half-open
    private let timeout: TimeInterval = 30.0  // Stay open for 30s
    
    var currentState: State {
        state
    }
    
    func execute<T>(_ operation: () async throws -> T) async throws -> T {
        // Check if we should transition from open to half-open
        if state == .open {
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) > timeout {
                print("🔄 CIRCUIT_BREAKER: open → halfOpen")
                state = .halfOpen
                successCount = 0
            } else {
                throw AttachmentError.circuitBreakerOpen
            }
        }
        
        do {
            let result = try await operation()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
        }
    }
    
    private func recordSuccess() {
        switch state {
        case .halfOpen:
            successCount += 1
            print("✅ CIRCUIT_BREAKER: Success in halfOpen (\(successCount)/\(successThreshold))")
            if successCount >= successThreshold {
                print("✅ CIRCUIT_BREAKER: halfOpen → closed")
                state = .closed
                failureCount = 0
                successCount = 0
            }
        case .closed:
            failureCount = max(0, failureCount - 1)  // Gradually recover failure count
        case .open:
            break
        }
    }
    
    private func recordFailure() {
        lastFailureTime = Date()
        
        switch state {
        case .closed:
            failureCount += 1
            print("⚠️ CIRCUIT_BREAKER: Failure \(failureCount)/\(failureThreshold)")
            if failureCount >= failureThreshold {
                print("⚠️ CIRCUIT_BREAKER: closed → open")
                state = .open
            }
        case .halfOpen:
            print("⚠️ CIRCUIT_BREAKER: halfOpen → open (failed recovery test)")
            state = .open
            successCount = 0
            failureCount = failureThreshold  // Reset to threshold
        case .open:
            break
        }
    }
    
    func reset() {
        state = .closed
        failureCount = 0
        successCount = 0
        lastFailureTime = nil
        print("🔄 CIRCUIT_BREAKER: Manual reset to closed")
    }
}