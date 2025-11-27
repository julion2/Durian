//
//  IMAPStreamingPipeline.swift
//  colonSend
//
//  Streaming pipeline architecture for attachment downloads
//

import Foundation

// MARK: - Stream Protocol

protocol DataStream {
    associatedtype Output
    func subscribe(_ handler: @escaping (StreamEvent<Output>) -> Void) -> StreamSubscription
}

enum StreamEvent<T> {
    case data(T)
    case progress(bytesReceived: Int, totalBytes: Int)
    case complete
    case error(Error)
}

// STABILITY FIX: Use identifiable subscription tokens instead of closure comparison
struct StreamSubscription {
    let id: UUID
    let cancel: () -> Void
    
    init(id: UUID = UUID(), cancel: @escaping () -> Void) {
        self.id = id
        self.cancel = cancel
    }
}

// MARK: - Attachment Stream

@MainActor
class AttachmentStream: DataStream {
    typealias Output = Data
    
    private let uid: UInt32
    private let section: String
    private let expectedSize: Int64
    // STABILITY FIX: Use identified subscribers to enable proper cleanup
    private var subscribers: [UUID: (StreamEvent<Data>) -> Void] = [:]
    private var receivedBytes: Int = 0
    private var buffer: Data = Data()
    private var isCompleted: Bool = false
    
    init(uid: UInt32, section: String, expectedSize: Int64) {
        self.uid = uid
        self.section = section
        self.expectedSize = expectedSize
        
        // Pre-allocate buffer capacity (with BASE64 overhead)
        let estimatedCapacity = Int(Double(expectedSize) * 1.4)
        buffer.reserveCapacity(estimatedCapacity)
        
        print("STREAM: Created for UID \(uid), section \(section), expecting \(expectedSize) bytes")
    }
    
    func subscribe(_ handler: @escaping (StreamEvent<Data>) -> Void) -> StreamSubscription {
        let subscriptionId = UUID()
        subscribers[subscriptionId] = handler
        
        // If already completed, immediately notify
        if isCompleted {
            handler(.complete)
        }
        
        // STABILITY FIX: Return subscription with ID for proper removal
        return StreamSubscription(id: subscriptionId) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.subscribers.removeValue(forKey: subscriptionId)
                print("STREAM: Unsubscribed \(subscriptionId)")
            }
        }
    }
    
    /// Called by network layer when data arrives
    func push(_ chunk: Data) {
        guard !isCompleted else {
            print("⚠️ STREAM: Received data after completion")
            return
        }
        
        buffer.append(chunk)
        receivedBytes += chunk.count
        
        // Emit progress
        let progress = StreamEvent<Data>.progress(
            bytesReceived: receivedBytes,
            totalBytes: Int(expectedSize)
        )
        emitEvent(progress)
        
        // Check completion
        if receivedBytes >= expectedSize {
            completeStream()
        }
    }
    
    /// Called when data transfer is complete (regardless of size)
    func forceComplete() {
        guard !isCompleted else { return }
        completeStream()
    }
    
    private func completeStream() {
        isCompleted = true
        
        // Decode BASE64 if needed
        let decoded = decodeIfBase64(buffer)
        
        print("📦 STREAM: Complete - received \(buffer.count) bytes, decoded to \(decoded.count) bytes")
        
        emitEvent(.data(decoded))
        emitEvent(.complete)
    }
    
    func emitError(_ error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        emitEvent(.error(error))
    }
    
    private func emitEvent(_ event: StreamEvent<Data>) {
        // STABILITY FIX: Iterate over values of the dictionary
        subscribers.values.forEach { handler in
            handler(event)
        }
    }
    
    private func decodeIfBase64(_ data: Data) -> Data {
        // Try to decode as BASE64
        guard let string = String(data: data, encoding: .ascii) else {
            // Not ASCII, return as-is
            return data
        }
        
        // Remove whitespace (BASE64 can have newlines)
        let cleaned = string.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        
        guard let decoded = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) else {
            // Not valid BASE64, return original
            return data
        }
        
        return decoded
    }
    
    var progress: Double {
        guard expectedSize > 0 else { return 1.0 }
        return Double(receivedBytes) / Double(expectedSize)
    }
}

// MARK: - Stream Router

@MainActor
class ResponseStreamRouter {
    private var activeStreams: [String: AttachmentStream] = [:]  // Key: "UID:section"
    
    func registerStream(_ stream: AttachmentStream, forUID uid: UInt32, section: String) {
        let key = "\(uid):\(section)"
        activeStreams[key] = stream
        print("📡 ROUTER: Registered stream for \(key)")
    }
    
    func routeData(_ data: Data, toUID uid: UInt32, section: String) {
        let key = "\(uid):\(section)"
        if let stream = activeStreams[key] {
            stream.push(data)
        } else {
            print("⚠️ ROUTER: No stream found for \(key)")
        }
    }
    
    func completeStream(forUID uid: UInt32, section: String) {
        let key = "\(uid):\(section)"
        if let stream = activeStreams[key] {
            stream.forceComplete()
            activeStreams.removeValue(forKey: key)
            print("📡 ROUTER: Completed stream for \(key)")
        }
    }
    
    func emitError(_ error: Error, forUID uid: UInt32, section: String) {
        let key = "\(uid):\(section)"
        if let stream = activeStreams[key] {
            stream.emitError(error)
            activeStreams.removeValue(forKey: key)
        }
    }
    
    func cancelStream(forUID uid: UInt32, section: String) {
        let key = "\(uid):\(section)"
        activeStreams.removeValue(forKey: key)
        print("📡 ROUTER: Cancelled stream for \(key)")
    }
    
    func hasActiveStream(forUID uid: UInt32, section: String) -> Bool {
        let key = "\(uid):\(section)"
        return activeStreams[key] != nil
    }
}
