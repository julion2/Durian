//
//  KeySequenceEngine.swift
//  Kurian
//
//  Main engine for handling key sequences with count support
//

import Foundation
import AppKit
import Combine

/// Visual mode types for multi-selection
enum VisualModeType: Equatable {
    case none       // Normal mode
    case line       // v: Range selection (anchor to cursor)
    case toggle     // V: Individual toggle selection
}

/// Main engine for processing key sequences
/// Handles: single keys (j, k), counts (5j, 12k), sequences (gg, dd)
@MainActor
class KeySequenceEngine: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = KeySequenceEngine()
    
    // MARK: - Dependencies
    
    private let buffer = KeyBuffer()
    private let matcher = SequenceMatcher.shared
    
    // MARK: - State
    
    /// Registered action handlers
    private var actionHandlers: [KeymapAction: (Int) async -> Void] = [:]
    
    /// Current sequence being built (for UI display)
    @Published private(set) var currentSequence: String = ""
    
    /// Whether engine is waiting for more keys
    @Published private(set) var isWaitingForMore: Bool = false
    
    /// Current visual mode type (none, line, toggle)
    @Published private(set) var visualModeType: VisualModeType = .none
    
    /// Convenience: whether any visual mode is active
    var isVisualMode: Bool { visualModeType != .none }
    
    // MARK: - Init
    
    private init() {
        setupBufferTimeout()
    }
    
    private func setupBufferTimeout() {
        buffer.onTimeout = { [weak self] in
            self?.currentSequence = ""
            self?.isWaitingForMore = false
        }
    }
    
    // MARK: - Public API
    
    /// Register a handler for an action
    /// - Parameters:
    ///   - action: The action to handle
    ///   - handler: Closure that executes the action (receives count)
    func registerHandler(for action: KeymapAction, handler: @escaping (Int) async -> Void) {
        actionHandlers[action] = handler
    }
    
    /// Process a key event
    /// - Parameter event: The NSEvent key event
    /// - Returns: true if event was consumed, false to pass through
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers ?? ""
        let modifiers = getModifiers(from: event)
        
        // Skip if key is empty
        guard !key.isEmpty else {
            return false
        }
        
        // Skip pure modifier keys
        if key.isEmpty || event.keyCode == 55 || event.keyCode == 54 || 
           event.keyCode == 56 || event.keyCode == 58 || event.keyCode == 59 {
            return false
        }
        
        // Escape always clears buffer, exits visual mode, and dispatches handler
        if event.keyCode == 53 { // Escape
            if !buffer.isEmpty {
                buffer.clear()
                currentSequence = ""
                isWaitingForMore = false
                print("KEYSEQ: Escape - buffer cleared")
            }

            if isVisualMode {
                exitVisualMode()
            }

            // Always dispatch exitVisualMode handler so it can close
            // search popup, tag picker, detail view, etc.
            if let handler = actionHandlers[.exitVisualMode] {
                Task { await handler(1) }
            }
            return true
        }
        
        // Commands with Cmd/Ctrl go through different path (non-sequence)
        if modifiers.contains(.cmd) || modifiers.contains(.ctrl) {
            // But allow Ctrl+d, Ctrl+u for page navigation
            if modifiers == [.ctrl] && (key == "d" || key == "u") {
                return processKey(key: key, modifiers: modifiers)
            }
            // Other Cmd/Ctrl combos pass through
            return false
        }
        
        return processKey(key: key, modifiers: modifiers)
    }
    
    /// Clear the buffer manually
    func clearBuffer() {
        buffer.clear()
        currentSequence = ""
        isWaitingForMore = false
    }
    
    /// Enter visual mode for multi-selection
    /// - Parameter type: The type of visual mode (.line or .toggle)
    func enterVisualMode(_ type: VisualModeType = .line) {
        guard visualModeType == .none else { return }  // Ignore if already in visual mode
        visualModeType = type
        print("KEYSEQ: Entered visual mode: \(type)")
    }
    
    /// Exit visual mode
    func exitVisualMode() {
        visualModeType = .none
        print("KEYSEQ: Exited visual mode")
    }
    
    // MARK: - Private
    
    private func processKey(key: String, modifiers: Set<KeyModifier>) -> Bool {
        // Create key event
        let keyEvent = KeyEvent(key: key, modifiers: modifiers)
        
        print("KEYSEQ: Key pressed: '\(key)' modifiers: \(modifiers) normalized: '\(keyEvent.normalized)'")
        
        // Add to buffer
        buffer.append(keyEvent)
        currentSequence = buffer.displayString
        
        print("KEYSEQ: Buffer = '\(buffer.asString)' (count: \(buffer.count))")
        
        // Try to match
        let result = matcher.match(buffer: buffer.asString)
        
        switch result {
        case .match(let action, let count):
            print("KEYSEQ: Match! action=\(action.rawValue) count=\(count)")
            executeAction(action, count: count)
            buffer.clear()
            currentSequence = ""
            isWaitingForMore = false
            return true
            
        case .partial:
            print("KEYSEQ: Partial match, waiting for more...")
            isWaitingForMore = true
            return true
            
        case .noMatch:
            print("KEYSEQ: No match, clearing buffer")
            buffer.clear()
            currentSequence = ""
            isWaitingForMore = false
            return false
        }
    }
    
    private func executeAction(_ action: KeymapAction, count: Int) {
        guard let handler = actionHandlers[action] else {
            print("KEYSEQ: No handler registered for \(action.rawValue)")
            return
        }
        
        Task {
            // Pass count to handler - handler is responsible for repeating if needed
            await handler(count)
        }
    }
    
    private func getModifiers(from event: NSEvent) -> Set<KeyModifier> {
        var modifiers: Set<KeyModifier> = []
        
        if event.modifierFlags.contains(.command) {
            modifiers.insert(.cmd)
        }
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if event.modifierFlags.contains(.control) {
            modifiers.insert(.ctrl)
        }
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        
        return modifiers
    }
}

// MARK: - Handler Registration Helpers

extension KeySequenceEngine {
    
    /// Register a simple handler that ignores count
    func registerSimpleHandler(for action: KeymapAction, handler: @escaping () async -> Void) {
        registerHandler(for: action) { _ in
            await handler()
        }
    }
    
    /// Register all navigation handlers at once
    func registerNavigationHandlers(
        onNext: @escaping (Int) async -> Void,
        onPrev: @escaping (Int) async -> Void,
        onFirst: @escaping () async -> Void,
        onLast: @escaping () async -> Void
    ) {
        registerHandler(for: .nextEmail, handler: onNext)
        registerHandler(for: .prevEmail, handler: onPrev)
        registerSimpleHandler(for: .firstEmail, handler: onFirst)
        registerSimpleHandler(for: .lastEmail, handler: onLast)
    }
}
