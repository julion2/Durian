import Foundation
import SwiftUI
import Combine
import AppKit

class KeymapHandler: ObservableObject {
    static let shared = KeymapHandler()
    
    private var keymapsManager = KeymapsManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var keyEventMonitor: Any?
    private var isAppInForeground = false
    
    // Keymap action handlers
    private var actionHandlers: [String: () async -> Void] = [:]
    
    private init() {
        setupForegroundDetection()
        setupKeymapObserver()
    }
    
    deinit {
        stopKeyEventMonitoring()
    }
    
    // MARK: - Public API
    
    func registerHandler(for action: String, handler: @escaping () async -> Void) {
        actionHandlers[action] = handler
        print("🎹 Handler registered for action: \(action)")
    }
    
    func startKeyEventMonitoring() {
        stopKeyEventMonitoring()
        
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        
        print("🎹 Key event monitoring started")
    }
    
    func stopKeyEventMonitoring() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
            print("🎹 Key event monitoring stopped")
        }
    }
    
    // MARK: - Private Methods
    
    private func setupForegroundDetection() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppInForeground = true
            self?.startKeyEventMonitoring()
            print("🎹 App became active - keymap monitoring enabled")
        }
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppInForeground = false
            self?.stopKeyEventMonitoring()
            print("🎹 App resigned active - keymap monitoring disabled")
        }
    }
    
    private func setupKeymapObserver() {
        keymapsManager.$keymaps
            .sink { [weak self] _ in
                print("🎹 Keymaps updated, refreshing handlers")
            }
            .store(in: &cancellables)
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard isAppInForeground,
              keymapsManager.keymaps.globalSettings.keymapsEnabled else {
            return
        }
        
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = getModifiers(from: event)
        
        // Check all enabled keymaps
        for (action, keymap) in keymapsManager.keymaps.keymaps {
            guard keymap.enabled else { continue }
            
            if keymap.key.lowercased() == key && Set(keymap.modifiers) == Set(modifiers) {
                
                if let handler = actionHandlers[action] {
                    Task {
                        await handler()
                    }
                } else {
                }
                break
            }
        }
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
    
    private func formatKeyCombo(key: String, modifiers: [String]) -> String {
        let modStr = modifiers.isEmpty ? "" : modifiers.joined(separator: "+") + "+"
        return modStr + key
    }
}