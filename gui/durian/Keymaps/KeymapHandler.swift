//
//  KeymapHandler.swift
//  Durian
//
//  Handles keyboard events and delegates to KeySequenceEngine
//

import Foundation
import SwiftUI
import Combine
import AppKit
import WebKit

@MainActor
class KeymapHandler: ObservableObject {
    static let shared = KeymapHandler()
    
    // MARK: - Dependencies
    
    private var keymapsManager = KeymapsManager.shared
    private let sequenceEngine = KeySequenceEngine.shared
    
    // MARK: - State
    
    private var cancellables = Set<AnyCancellable>()
    private var keyEventMonitor: Any?
    private var isAppInForeground = false
    
    // Legacy action handlers (for keymaps.toml defined shortcuts with modifiers)
    private var legacyActionHandlers: [String: () async -> Void] = [:]
    
    // MARK: - Published (proxy from sequence engine)
    
    @Published private(set) var currentSequence: String = ""
    @Published private(set) var isWaitingForMore: Bool = false
    
    /// Public access to the sequence engine (for visual mode state, etc.)
    var engine: KeySequenceEngine { sequenceEngine }
    
    // MARK: - Init
    
    private init() {
        setupForegroundDetection()
        setupKeymapObserver()
        setupSequenceEngineBindings()
    }
    
    deinit {
        // Note: Can't call MainActor methods in deinit
        // The event monitor will be cleaned up when the app terminates
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // MARK: - Public API
    
    /// Register a handler for a KeymapAction (goes through sequence engine)
    func registerHandler(for action: KeymapAction, handler: @escaping (Int) async -> Void) {
        sequenceEngine.registerHandler(for: action, handler: handler)
        Log.debug("KEYMAPS", "Handler registered for action: \(action.rawValue)")
    }
    
    /// Register a simple handler (count ignored)
    func registerSimpleHandler(for action: KeymapAction, handler: @escaping () async -> Void) {
        sequenceEngine.registerSimpleHandler(for: action, handler: handler)
        Log.debug("KEYMAPS", "Simple handler registered for action: \(action.rawValue)")
    }
    
    /// Register a legacy handler for keymaps.toml defined shortcuts (Cmd+r, etc.)
    func registerLegacyHandler(for action: String, handler: @escaping () async -> Void) {
        legacyActionHandlers[action] = handler
        Log.debug("KEYMAPS", "Legacy handler registered for action: \(action)")
    }
    
    func startKeyEventMonitoring() {
        stopKeyEventMonitoring()
        
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // Consume event
            }
            return event // Pass through
        }
        
        Log.debug("KEYMAPS", "Key event monitoring started")
    }
    
    func stopKeyEventMonitoring() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
            Log.debug("KEYMAPS", "Key event monitoring stopped")
        }
    }
    
    /// Clear the sequence buffer
    func clearSequence() {
        sequenceEngine.clearBuffer()
    }
    
    // MARK: - Private Methods
    
    private func setupForegroundDetection() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppInForeground = true
                self?.startKeyEventMonitoring()
                Log.debug("KEYMAPS", "App became active")
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isAppInForeground = false
                self?.stopKeyEventMonitoring()
                self?.sequenceEngine.clearBuffer()
                Log.debug("KEYMAPS", "App resigned active")
            }
        }
    }
    
    private func setupKeymapObserver() {
        keymapsManager.$keymaps
            .sink { _ in
                Log.debug("KEYMAPS", "Config updated")
            }
            .store(in: &cancellables)
    }
    
    private func setupSequenceEngineBindings() {
        // Bind sequence engine state to this handler for UI
        sequenceEngine.$currentSequence
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSequence)
        
        sequenceEngine.$isWaitingForMore
            .receive(on: DispatchQueue.main)
            .assign(to: &$isWaitingForMore)
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Skip if a text input field is focused (search, compose, etc.)
        if isTextInputFocused() {
            return false
        }
        
        guard isAppInForeground,
              keymapsManager.keymaps.globalSettings.keymapsEnabled else {
            Log.debug("KEYMAPS", "Event ignored - app not in foreground or keymaps disabled")
            return false
        }
        
        let key = event.charactersIgnoringModifiers ?? ""
        Log.debug("KEYMAPS", "Received key event: '\(key)' keyCode: \(event.keyCode)")
        
        // First, check for legacy keymaps with modifiers (Cmd+r, etc.)
        if handleLegacyKeymap(event) {
            Log.debug("KEYMAPS", "Handled by legacy keymap")
            return true
        }
        
        // Then delegate to sequence engine
        let consumed = sequenceEngine.handleKeyEvent(event)
        Log.debug("KEYMAPS", "Sequence engine returned: \(consumed)")
        return consumed
    }
    
    /// Handle keymaps.toml defined shortcuts with modifiers
    private func handleLegacyKeymap(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = getModifiers(from: event)
        
        // Only handle if there are modifiers (except pure shift)
        guard !modifiers.isEmpty && modifiers != ["shift"] else {
            return false
        }
        
        // Check keymaps.toml entries
        for keymapEntry in keymapsManager.keymaps.keymaps {
            guard keymapEntry.enabled else { continue }
            guard !keymapEntry.modifiers.isEmpty else { continue } // Skip no-modifier entries
            
            if keymapEntry.key.lowercased() == key && Set(keymapEntry.modifiers) == Set(modifiers) {
                if let handler = legacyActionHandlers[keymapEntry.action] {
                    Task {
                        await handler()
                    }
                    return true
                }
            }
        }
        
        return false
    }
    
    private func getModifiers(from event: NSEvent) -> [String] {
        var modifiers: [String] = []
        
        if event.modifierFlags.contains(.command) {
            modifiers.append("cmd")
        }
        if event.modifierFlags.contains(.option) {
            modifiers.append("option")
        }
        if event.modifierFlags.contains(.control) {
            modifiers.append("ctrl")
        }
        if event.modifierFlags.contains(.shift) {
            modifiers.append("shift")
        }
        
        return modifiers
    }
    
    /// Check if a text input field is currently focused
    /// This prevents vim keymaps from interfering with typing in search, compose, etc.
    private func isTextInputFocused() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }
        
        // NSTextView is the editor for TextField, TextEditor, WebView input, etc.
        if firstResponder is NSTextView {
            return true
        }

        // Directly editable NSTextField
        if let textField = firstResponder as? NSTextField,
           textField.isEditable {
            return true
        }

        // WKWebView with contentEditable (e.g. EditableWebView in compose)
        if firstResponder is WKWebView {
            return true
        }

        return false
    }
}
