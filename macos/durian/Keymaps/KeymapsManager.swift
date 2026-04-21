import Foundation
import SwiftUI
import Combine
import TOMLDecoder

// MARK: - Notifications

extension Notification.Name {
    static let keymapsDidChange = Notification.Name("keymapsDidChange")
}

class KeymapsManager: ObservableObject {
    static let shared = KeymapsManager()
    
    @Published var keymaps: KeymapConfig = KeymapConfig()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        loadKeymaps()
        setupAutoSave()
    }
    
    private func loadKeymaps() {
        let tomlURL = getKeymapsURL()
        let jsonURL = getLegacyKeymapsURL()
        
        // Migration: Check if JSON exists but TOML doesn't
        if FileManager.default.fileExists(atPath: jsonURL.path) && !FileManager.default.fileExists(atPath: tomlURL.path) {
            Log.debug("KEYMAPS", "Migrating from JSON to TOML...")
            migrateFromJSON(jsonURL: jsonURL, tomlURL: tomlURL)
        }
        
        // Create keymaps file if it doesn't exist
        if !FileManager.default.fileExists(atPath: tomlURL.path) {
            createDefaultKeymaps()
        }
        
        do {
            let tomlString = try String(contentsOf: tomlURL, encoding: .utf8)
            keymaps = try TOMLDecoder().decode(KeymapConfig.self, from: tomlString)
            Log.info("KEYMAPS", "Loaded from: \(tomlURL.path)")
            
            // Merge missing keymaps from defaults
            mergeWithDefaults()
        } catch {
            Log.error("KEYMAPS", "Failed to load: \(error)")
            keymaps = KeymapConfig()
        }
        
        // Notify observers (SequenceMatcher, etc.)
        NotificationCenter.default.post(name: .keymapsDidChange, object: nil)
    }
    
    private func migrateFromJSON(jsonURL: URL, tomlURL: URL) {
        // For now, just create new TOML - old JSON structure was different
        // Users can manually migrate if needed
        Log.debug("KEYMAPS", "Old JSON config found, creating new TOML config")
    }
    
    private func setupAutoSave() {
        $keymaps
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveKeymaps()
            }
            .store(in: &cancellables)
    }
    
    private func saveKeymaps() {
        let configURL = getKeymapsURL()
        
        do {
            let tomlString = generateTOML(from: keymaps)
            try tomlString.write(to: configURL, atomically: true, encoding: .utf8)
            Log.debug("KEYMAPS", "Saved to \(configURL.path)")
        } catch {
            Log.error("KEYMAPS", "Failed to save: \(error)")
        }
    }
    
    /// Merge missing keymaps from defaults into loaded config
    /// This ensures new keymaps are available after app updates
    private func mergeWithDefaults() {
        let defaultKeymaps = getDefaultKeymaps()
        let existingActions = Set(keymaps.keymaps.map { $0.context + ":" + $0.action + $0.key })

        var addedCount = 0
        for defaultEntry in defaultKeymaps {
            let key = defaultEntry.context + ":" + defaultEntry.action + defaultEntry.key
            if !existingActions.contains(key) {
                keymaps.keymaps.append(defaultEntry)
                addedCount += 1
                Log.debug("KEYMAPS", "Added missing keymap: \(defaultEntry.context):\(defaultEntry.action) -> \(defaultEntry.key)")
            }
        }
        
        if addedCount > 0 {
            Log.info("KEYMAPS", "Merged \(addedCount) missing keymaps from defaults")
            saveKeymaps()
        }
    }
    
    /// Returns the default keymaps array
    private func getDefaultKeymaps() -> [KeymapEntry] {
        return [
            // Navigation
            KeymapEntry(action: "next_email", key: "j", modifiers: [], description: "Next email (vim j)", enabled: true, sequence: false, supportsCount: true),
            KeymapEntry(action: "prev_email", key: "k", modifiers: [], description: "Previous email (vim k)", enabled: true, sequence: false, supportsCount: true),
            KeymapEntry(action: "next_email", key: "Down", modifiers: [], description: "Next email (arrow)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "prev_email", key: "Up", modifiers: [], description: "Previous email (arrow)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "last_email", key: "G", modifiers: [], description: "Last email (Shift+G)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "first_email", key: "gg", modifiers: [], description: "First email (vim gg)", enabled: true, sequence: true, supportsCount: false),
            KeymapEntry(action: "page_down", key: "d", modifiers: ["ctrl"], description: "Half-page down (Ctrl+d)", enabled: true, sequence: false, supportsCount: true),
            KeymapEntry(action: "page_up", key: "u", modifiers: ["ctrl"], description: "Half-page up (Ctrl+u)", enabled: true, sequence: false, supportsCount: true),
            KeymapEntry(action: "archive", key: "a", modifiers: [], description: "Archive email (remove inbox)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "compose", key: "c", modifiers: [], description: "Compose new email", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "reply", key: "r", modifiers: [], description: "Reply to email", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "reply_all", key: "R", modifiers: [], description: "Reply to all (Shift+R)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "forward", key: "f", modifiers: [], description: "Forward email", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_read", key: "u", modifiers: [], description: "Toggle read/unread", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_star", key: "s", modifiers: [], description: "Toggle star", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "delete", key: "dd", modifiers: [], description: "Delete email (vim dd)", enabled: true, sequence: true, supportsCount: true),
            // Folder Navigation
            KeymapEntry(action: "go_inbox", key: "gi", modifiers: [], description: "Go to inbox", enabled: true, sequence: true, supportsCount: false),
            KeymapEntry(action: "go_sent", key: "gs", modifiers: [], description: "Go to sent", enabled: true, sequence: true, supportsCount: false),
            KeymapEntry(action: "go_drafts", key: "gd", modifiers: [], description: "Go to drafts", enabled: true, sequence: true, supportsCount: false),
            KeymapEntry(action: "go_archive", key: "ga", modifiers: [], description: "Go to archive", enabled: true, sequence: true, supportsCount: false),
            // Search
            KeymapEntry(action: "search", key: "/", modifiers: [], description: "Search emails (vim /)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "search", key: "/", modifiers: ["cmd"], description: "Search emails (Cmd+/)", enabled: true, sequence: false, supportsCount: false),
            // Tag Picker
            KeymapEntry(action: "tag_picker", key: "t", modifiers: [], description: "Open tag picker", enabled: true, sequence: false, supportsCount: false),
            // View Control
            KeymapEntry(action: "close_detail", key: "q", modifiers: [], description: "Close/back (vim q)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "close_detail", key: "Escape", modifiers: [], description: "Close/back (Escape)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "reload_inbox", key: "r", modifiers: ["cmd"], description: "Reload inbox (Cmd+r)", enabled: true, sequence: false, supportsCount: false),
            // Visual Mode
            KeymapEntry(action: "enter_visual_mode", key: "v", modifiers: [], description: "Enter line visual mode (range select)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "enter_toggle_mode", key: "V", modifiers: [], description: "Enter toggle visual mode (Shift+V)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_selection", key: " ", modifiers: [], description: "Toggle current email (only in toggle mode)", enabled: true, sequence: false, supportsCount: false),
            KeymapEntry(action: "exit_visual_mode", key: "Escape", modifiers: [], description: "Exit visual mode and clear selection", enabled: true, sequence: false, supportsCount: false),
            // Search context
            KeymapEntry(action: "select_next", key: "j", modifiers: ["ctrl"], description: "Next search result (Ctrl+j)", enabled: true, sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_prev", key: "k", modifiers: ["ctrl"], description: "Previous search result (Ctrl+k)", enabled: true, sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_next", key: "n", modifiers: ["ctrl"], description: "Next search result (Ctrl+n)", enabled: true, sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_prev", key: "p", modifiers: ["ctrl"], description: "Previous search result (Ctrl+p)", enabled: true, sequence: false, supportsCount: false, context: "search"),
            // Tag picker context
            KeymapEntry(action: "select_next", key: "j", modifiers: ["ctrl"], description: "Next tag (Ctrl+j)", enabled: true, sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_prev", key: "k", modifiers: ["ctrl"], description: "Previous tag (Ctrl+k)", enabled: true, sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_next", key: "n", modifiers: ["ctrl"], description: "Next tag (Ctrl+n)", enabled: true, sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_prev", key: "p", modifiers: ["ctrl"], description: "Previous tag (Ctrl+p)", enabled: true, sequence: false, supportsCount: false, context: "tag_picker"),
            // Compose normal context
            KeymapEntry(action: "exit_insert", key: "jk", modifiers: [], description: "Exit insert mode (jk)", enabled: true, sequence: true, supportsCount: false, context: "compose_normal"),
            // List context: enter thread
            KeymapEntry(action: "enter_thread", key: "l", modifiers: [], description: "Enter thread view (l)", enabled: true, sequence: false, supportsCount: false),
            // Thread context
            KeymapEntry(action: "scroll_down", key: "j", modifiers: [], description: "Scroll down in thread", enabled: true, sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "scroll_up", key: "k", modifiers: [], description: "Scroll up in thread", enabled: true, sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "page_down", key: "d", modifiers: ["ctrl"], description: "Half-page down in thread", enabled: true, sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "page_up", key: "u", modifiers: ["ctrl"], description: "Half-page up in thread", enabled: true, sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "next_message", key: "n", modifiers: [], description: "Next message in thread", enabled: true, sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "prev_message", key: "N", modifiers: [], description: "Previous message in thread", enabled: true, sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "first_email", key: "gg", modifiers: [], description: "First message in thread", enabled: true, sequence: true, supportsCount: false, context: "thread"),
            KeymapEntry(action: "last_email", key: "G", modifiers: [], description: "Last message in thread", enabled: true, sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "close_detail", key: "h", modifiers: [], description: "Back to email list", enabled: true, sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "close_detail", key: "Escape", modifiers: [], description: "Back to email list", enabled: true, sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "reply", key: "r", modifiers: [], description: "Reply to email", enabled: true, sequence: false, supportsCount: false, context: "thread"),
        ]
    }

    private func generateTOML(from config: KeymapConfig) -> String {
        var toml = "# durian Keymaps Configuration\n"
        toml += "# All vim-style keybindings are configurable here\n"
        toml += "# sequence = true: Multi-key sequence like 'gg', 'dd', 'gi'\n"
        toml += "# supports_count = true: Accepts count prefix like '5j', '3dd'\n\n"
        
        // Global settings
        toml += "[global_settings]\n"
        toml += "keymaps_enabled = \(config.globalSettings.keymapsEnabled)\n"
        toml += "show_keymap_hints = \(config.globalSettings.showKeymapHints)\n"
        toml += "sequence_timeout = \(config.globalSettings.sequenceTimeout)\n\n"
        
        // Keymaps array
        for entry in config.keymaps {
            toml += "[[keymaps]]\n"
            toml += "action = \"\(entry.action)\"\n"
            toml += "key = \"\(entry.key)\"\n"
            toml += "modifiers = [\(entry.modifiers.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
            toml += "description = \"\(entry.description)\"\n"
            toml += "enabled = \(entry.enabled)\n"
            toml += "sequence = \(entry.sequence)\n"
            toml += "supports_count = \(entry.supportsCount)\n"
            if entry.context != "list" {
                toml += "context = \"\(entry.context)\"\n"
            }
            toml += "\n"
        }
        
        return toml
    }
    
    private func getKeymapsURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/durian/keymaps.toml")
    }
    
    private func getLegacyKeymapsURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/durian/keymaps.json")
    }
    
    private func createDefaultKeymaps() {
        var config = KeymapConfig()
        config.globalSettings = KeymapGlobalSettings(
            keymapsEnabled: true,
            showKeymapHints: true,
            sequenceTimeout: 1.0
        )
        config.keymaps = [
            // ═══════════════════════════════════════════════════════════
            // NAVIGATION - Single keys
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "next_email", key: "j", modifiers: [],
                       description: "Next email (vim j)", enabled: true,
                       sequence: false, supportsCount: true),
            KeymapEntry(action: "prev_email", key: "k", modifiers: [],
                       description: "Previous email (vim k)", enabled: true,
                       sequence: false, supportsCount: true),
            KeymapEntry(action: "next_email", key: "Down", modifiers: [],
                       description: "Next email (arrow)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "prev_email", key: "Up", modifiers: [],
                       description: "Previous email (arrow)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "last_email", key: "G", modifiers: [],
                       description: "Last email (Shift+G)", enabled: true,
                       sequence: false, supportsCount: false),
            
            // ═══════════════════════════════════════════════════════════
            // NAVIGATION - Sequences
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "first_email", key: "gg", modifiers: [],
                       description: "First email (vim gg)", enabled: true,
                       sequence: true, supportsCount: false),

            // ═══════════════════════════════════════════════════════════
            // PAGE NAVIGATION
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "page_down", key: "d", modifiers: ["ctrl"],
                       description: "Half-page down (Ctrl+d)", enabled: true,
                       sequence: false, supportsCount: true),
            KeymapEntry(action: "page_up", key: "u", modifiers: ["ctrl"],
                       description: "Half-page up (Ctrl+u)", enabled: true,
                       sequence: false, supportsCount: true),

            // ═══════════════════════════════════════════════════════════
            // EMAIL ACTIONS
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "archive", key: "a", modifiers: [],
                       description: "Archive email (remove inbox)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "compose", key: "c", modifiers: [],
                       description: "Compose new email", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "reply", key: "r", modifiers: [],
                       description: "Reply to email", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "reply_all", key: "R", modifiers: [],
                       description: "Reply to all (Shift+R)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "forward", key: "f", modifiers: [],
                       description: "Forward email", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_read", key: "u", modifiers: [],
                       description: "Toggle read/unread", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_star", key: "s", modifiers: [],
                       description: "Toggle star", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "delete", key: "dd", modifiers: [],
                       description: "Delete email (vim dd)", enabled: true,
                       sequence: true, supportsCount: true),
            
            // ═══════════════════════════════════════════════════════════
            // FOLDER NAVIGATION (go-commands)
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "go_inbox", key: "gi", modifiers: [],
                       description: "Go to inbox", enabled: true,
                       sequence: true, supportsCount: false),
            KeymapEntry(action: "go_sent", key: "gs", modifiers: [],
                       description: "Go to sent", enabled: true,
                       sequence: true, supportsCount: false),
            KeymapEntry(action: "go_drafts", key: "gd", modifiers: [],
                       description: "Go to drafts", enabled: true,
                       sequence: true, supportsCount: false),
            KeymapEntry(action: "go_archive", key: "ga", modifiers: [],
                       description: "Go to archive", enabled: true,
                       sequence: true, supportsCount: false),
            
            // ═══════════════════════════════════════════════════════════
            // SEARCH
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "search", key: "/", modifiers: [],
                       description: "Search emails (vim /)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "search", key: "/", modifiers: ["cmd"],
                       description: "Search emails (Cmd+/)", enabled: true,
                       sequence: false, supportsCount: false),
            
            // ═══════════════════════════════════════════════════════════
            // TAG PICKER
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "tag_picker", key: "t", modifiers: [],
                       description: "Open tag picker", enabled: true,
                       sequence: false, supportsCount: false),

            // ═══════════════════════════════════════════════════════════
            // VIEW CONTROL
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "close_detail", key: "q", modifiers: [],
                       description: "Close/back (vim q)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "close_detail", key: "Escape", modifiers: [],
                       description: "Close/back (Escape)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "reload_inbox", key: "r", modifiers: ["cmd"],
                       description: "Reload inbox (Cmd+r)", enabled: true,
                       sequence: false, supportsCount: false),
            
            // ═══════════════════════════════════════════════════════════
            // VISUAL MODE
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "enter_visual_mode", key: "v", modifiers: [],
                       description: "Enter line visual mode (range select)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "enter_toggle_mode", key: "V", modifiers: [],
                       description: "Enter toggle visual mode (Shift+V)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_selection", key: " ", modifiers: [],
                       description: "Toggle current email (only in toggle mode)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "exit_visual_mode", key: "Escape", modifiers: [],
                       description: "Exit visual mode and clear selection", enabled: true,
                       sequence: false, supportsCount: false),

            // ═══════════════════════════════════════════════════════════
            // SEARCH CONTEXT
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "select_next", key: "j", modifiers: ["ctrl"],
                       description: "Next search result (Ctrl+j)", enabled: true,
                       sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_prev", key: "k", modifiers: ["ctrl"],
                       description: "Previous search result (Ctrl+k)", enabled: true,
                       sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_next", key: "n", modifiers: ["ctrl"],
                       description: "Next search result (Ctrl+n)", enabled: true,
                       sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_prev", key: "p", modifiers: ["ctrl"],
                       description: "Previous search result (Ctrl+p)", enabled: true,
                       sequence: false, supportsCount: false, context: "search"),

            // ═══════════════════════════════════════════════════════════
            // TAG PICKER CONTEXT
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "select_next", key: "j", modifiers: ["ctrl"],
                       description: "Next tag (Ctrl+j)", enabled: true,
                       sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_prev", key: "k", modifiers: ["ctrl"],
                       description: "Previous tag (Ctrl+k)", enabled: true,
                       sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_next", key: "n", modifiers: ["ctrl"],
                       description: "Next tag (Ctrl+n)", enabled: true,
                       sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_prev", key: "p", modifiers: ["ctrl"],
                       description: "Previous tag (Ctrl+p)", enabled: true,
                       sequence: false, supportsCount: false, context: "tag_picker"),

            // ═══════════════════════════════════════════════════════════
            // COMPOSE NORMAL CONTEXT
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "exit_insert", key: "jk", modifiers: [],
                       description: "Exit insert mode (jk)", enabled: true,
                       sequence: true, supportsCount: false, context: "compose_normal"),

            // ═══════════════════════════════════════════════════════════
            // THREAD CONTEXT
            // ═══════════════════════════════════════════════════════════
            KeymapEntry(action: "enter_thread", key: "l", modifiers: [],
                       description: "Enter thread view (l)", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "next_message", key: "j", modifiers: [],
                       description: "Next message in thread", enabled: true,
                       sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "prev_message", key: "k", modifiers: [],
                       description: "Previous message in thread", enabled: true,
                       sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "close_detail", key: "h", modifiers: [],
                       description: "Back to email list", enabled: true,
                       sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "close_detail", key: "Escape", modifiers: [],
                       description: "Back to email list", enabled: true,
                       sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "reply", key: "r", modifiers: [],
                       description: "Reply to email", enabled: true,
                       sequence: false, supportsCount: false, context: "thread"),
        ]

        keymaps = config
        saveKeymaps()
    }
    
    // MARK: - Public API
    
    func setKeymap(for action: String, key: String, modifiers: [String] = []) {
        if let index = keymaps.keymaps.firstIndex(where: { $0.action == action }) {
            keymaps.keymaps[index].key = key
            keymaps.keymaps[index].modifiers = modifiers
            Log.debug("KEYMAPS", "Set \(action) = \(formatKeymap(key: key, modifiers: modifiers))")
        }
    }
    
    func enableKeymap(for action: String, enabled: Bool) {
        if let index = keymaps.keymaps.firstIndex(where: { $0.action == action }) {
            keymaps.keymaps[index].enabled = enabled
            Log.debug("KEYMAPS", "\(action) \(enabled ? "enabled" : "disabled")")
        }
    }
    
    func getKeymap(for action: String) -> KeymapEntry? {
        return keymaps.keymaps.first(where: { $0.action == action })
    }
    
    func getKeymapsForAction(_ action: String) -> [KeymapEntry] {
        return keymaps.keymaps.filter { $0.action == action && $0.enabled }
    }
    
    func isKeymapPressed(key: String, modifiers: [String], for action: String) -> Bool {
        guard keymaps.globalSettings.keymapsEnabled else {
            return false
        }
        
        let matchingKeymaps = keymaps.keymaps.filter { 
            $0.action == action && $0.enabled 
        }
        
        return matchingKeymaps.contains { keymap in
            keymap.key.lowercased() == key.lowercased() && 
            Set(keymap.modifiers) == Set(modifiers)
        }
    }
    
    private func formatKeymap(key: String, modifiers: [String]) -> String {
        let modString = modifiers.isEmpty ? "" : modifiers.joined(separator: "+") + "+"
        return modString + key
    }
    
    // Public method to manually reload keymaps
    func reloadKeymaps() {
        Log.info("KEYMAPS", "Manual keymaps reload requested")
        loadKeymaps()
        Log.info("KEYMAPS", "Keymaps reloaded from file")
    }
}

struct KeymapConfig: Codable {
    var keymaps: [KeymapEntry]
    var globalSettings: KeymapGlobalSettings
    
    init() {
        self.keymaps = []
        self.globalSettings = KeymapGlobalSettings()
    }
    
    enum CodingKeys: String, CodingKey {
        case keymaps
        case globalSettings = "global_settings"
    }
}

struct KeymapEntry: Codable {
    var action: String
    var key: String
    var modifiers: [String]
    var description: String
    var enabled: Bool
    var sequence: Bool
    var supportsCount: Bool
    var context: String
    var tags: String?  // For tag_op action: "+todo -inbox"

    enum CodingKeys: String, CodingKey {
        case action
        case key
        case modifiers
        case description
        case enabled
        case sequence
        case supportsCount = "supports_count"
        case context
        case tags
    }

    // Custom init for backwards compatibility with old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        key = try container.decode(String.self, forKey: .key)
        modifiers = try container.decode([String].self, forKey: .modifiers)
        description = try container.decode(String.self, forKey: .description)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sequence = try container.decodeIfPresent(Bool.self, forKey: .sequence) ?? false
        supportsCount = try container.decodeIfPresent(Bool.self, forKey: .supportsCount) ?? false
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? "list"
        tags = try container.decodeIfPresent(String.self, forKey: .tags)
    }

    // Memberwise init for creating entries programmatically
    init(action: String, key: String, modifiers: [String], description: String, enabled: Bool, sequence: Bool = false, supportsCount: Bool = false, context: String = "list", tags: String? = nil) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
        self.description = description
        self.enabled = enabled
        self.sequence = sequence
        self.supportsCount = supportsCount
        self.context = context
        self.tags = tags
    }
}

struct KeymapGlobalSettings: Codable {
    var keymapsEnabled: Bool = true
    var showKeymapHints: Bool = true
    var sequenceTimeout: Double = 1.0
    
    enum CodingKeys: String, CodingKey {
        case keymapsEnabled = "keymaps_enabled"
        case showKeymapHints = "show_keymap_hints"
        case sequenceTimeout = "sequence_timeout"
    }
    
    init() {}
    
    init(keymapsEnabled: Bool = true, showKeymapHints: Bool = true, sequenceTimeout: Double = 1.0) {
        self.keymapsEnabled = keymapsEnabled
        self.showKeymapHints = showKeymapHints
        self.sequenceTimeout = sequenceTimeout
    }
    
    // Custom init for backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keymapsEnabled = try container.decodeIfPresent(Bool.self, forKey: .keymapsEnabled) ?? true
        showKeymapHints = try container.decodeIfPresent(Bool.self, forKey: .showKeymapHints) ?? true
        sequenceTimeout = try container.decodeIfPresent(Double.self, forKey: .sequenceTimeout) ?? 1.0
    }
}
