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
            print("KEYMAPS: Migrating from JSON to TOML...")
            migrateFromJSON(jsonURL: jsonURL, tomlURL: tomlURL)
        }
        
        // Create keymaps file if it doesn't exist
        if !FileManager.default.fileExists(atPath: tomlURL.path) {
            createDefaultKeymaps()
        }
        
        do {
            let tomlString = try String(contentsOf: tomlURL, encoding: .utf8)
            keymaps = try TOMLDecoder().decode(KeymapConfig.self, from: tomlString)
            print("KEYMAPS: Loaded from: \(tomlURL.path)")
        } catch {
            print("KEYMAPS_ERROR: Failed to load: \(error)")
            keymaps = KeymapConfig()
        }
        
        // Notify observers (SequenceMatcher, etc.)
        NotificationCenter.default.post(name: .keymapsDidChange, object: nil)
    }
    
    private func migrateFromJSON(jsonURL: URL, tomlURL: URL) {
        // For now, just create new TOML - old JSON structure was different
        // Users can manually migrate if needed
        print("KEYMAPS: Old JSON config found, creating new TOML config")
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
            print("KEYMAPS: Saved to \(configURL.path)")
        } catch {
            print("KEYMAPS_ERROR: Failed to save: \(error)")
        }
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
            toml += "supports_count = \(entry.supportsCount)\n\n"
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
            KeymapEntry(action: "center_view", key: "zz", modifiers: [],
                       description: "Center current email in view", enabled: true,
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
            KeymapEntry(action: "open_email", key: "o", modifiers: [],
                       description: "Open email", enabled: true,
                       sequence: false, supportsCount: false),
            KeymapEntry(action: "open_email", key: "Return", modifiers: [],
                       description: "Open email (Enter)", enabled: true,
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
                       description: "Enter visual mode for multi-select", enabled: true,
                       sequence: false, supportsCount: false),
        ]
        
        keymaps = config
        saveKeymaps()
    }
    
    // MARK: - Public API
    
    func setKeymap(for action: String, key: String, modifiers: [String] = []) {
        if let index = keymaps.keymaps.firstIndex(where: { $0.action == action }) {
            keymaps.keymaps[index].key = key
            keymaps.keymaps[index].modifiers = modifiers
            print("KEYMAPS: Set \(action) = \(formatKeymap(key: key, modifiers: modifiers))")
        }
    }
    
    func enableKeymap(for action: String, enabled: Bool) {
        if let index = keymaps.keymaps.firstIndex(where: { $0.action == action }) {
            keymaps.keymaps[index].enabled = enabled
            print("KEYMAPS: \(action) \(enabled ? "enabled" : "disabled")")
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
        print("🎹 Manual keymaps reload requested")
        loadKeymaps()
        print("🎹 Keymaps reloaded from file")
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
    
    enum CodingKeys: String, CodingKey {
        case action
        case key
        case modifiers
        case description
        case enabled
        case sequence
        case supportsCount = "supports_count"
    }
    
    // Custom init for backwards compatibility with old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        key = try container.decode(String.self, forKey: .key)
        modifiers = try container.decode([String].self, forKey: .modifiers)
        description = try container.decode(String.self, forKey: .description)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        // Defaults for old configs without these fields
        sequence = try container.decodeIfPresent(Bool.self, forKey: .sequence) ?? false
        supportsCount = try container.decodeIfPresent(Bool.self, forKey: .supportsCount) ?? false
    }
    
    // Memberwise init for creating entries programmatically
    init(action: String, key: String, modifiers: [String], description: String, enabled: Bool, sequence: Bool = false, supportsCount: Bool = false) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
        self.description = description
        self.enabled = enabled
        self.sequence = sequence
        self.supportsCount = supportsCount
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
