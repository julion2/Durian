//
//  KeyBuffer.swift
//  colonSend
//
//  Collects key presses and manages timeout for key sequences
//

import Foundation

/// Collects key presses for sequence matching with automatic timeout
@MainActor
class KeyBuffer: ObservableObject {
    
    // MARK: - Configuration
    
    /// Timeout in seconds before buffer is cleared
    private let timeout: TimeInterval
    
    // MARK: - State
    
    /// Current buffer of key events
    private var buffer: [KeyEvent] = []
    
    /// Timeout task
    private var timeoutTask: Task<Void, Never>?
    
    /// Callback when timeout expires
    var onTimeout: (() -> Void)?
    
    // MARK: - Published
    
    /// Current buffer as string for display
    @Published private(set) var displayString: String = ""
    
    // MARK: - Init
    
    init(timeout: TimeInterval = 0.5) {
        self.timeout = timeout
    }
    
    // MARK: - Public API
    
    /// Append a key event to the buffer
    func append(_ event: KeyEvent) {
        buffer.append(event)
        updateDisplayString()
        resetTimeout()
    }
    
    /// Append a simple key (no modifiers)
    func append(key: String) {
        append(KeyEvent(key: key))
    }
    
    /// Clear the buffer
    func clear() {
        buffer.removeAll()
        displayString = ""
        cancelTimeout()
    }
    
    /// Get buffer contents as normalized string for matching
    /// e.g., ["5", "j"] → "5j", ["g", "g"] → "gg"
    var asString: String {
        buffer.map { $0.normalized }.joined()
    }
    
    /// Get just the count prefix if present
    /// e.g., "5j" → 5, "12gg" → 12, "gg" → nil
    var countPrefix: Int? {
        let str = asString
        var digits = ""
        
        for char in str {
            if char.isNumber {
                digits.append(char)
            } else {
                break
            }
        }
        
        return digits.isEmpty ? nil : Int(digits)
    }
    
    /// Get sequence without count prefix
    /// e.g., "5j" → "j", "12gg" → "gg", "gg" → "gg"
    var sequenceWithoutCount: String {
        let str = asString
        return String(str.drop(while: { $0.isNumber }))
    }
    
    /// Check if buffer is empty
    var isEmpty: Bool {
        buffer.isEmpty
    }
    
    /// Number of keys in buffer
    var count: Int {
        buffer.count
    }
    
    /// Check if buffer contains only digits (waiting for action)
    var isCountOnly: Bool {
        !asString.isEmpty && asString.allSatisfy { $0.isNumber }
    }
    
    // MARK: - Private
    
    private func updateDisplayString() {
        displayString = asString
    }
    
    private func resetTimeout() {
        cancelTimeout()
        
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.timeout ?? 0.5) * 1_000_000_000)
                
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    self?.handleTimeout()
                }
            } catch {
                // Task was cancelled
            }
        }
    }
    
    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }
    
    private func handleTimeout() {
        print("KEYBUFFER: Timeout - clearing buffer '\(asString)'")
        clear()
        onTimeout?()
    }
}
