import Foundation
import SwiftUI
import Combine

// MARK: - Notifications

extension Notification.Name {
    static let keymapsDidChange = Notification.Name("keymapsDidChange")
}

class KeymapsManager: ObservableObject {
    static let shared = KeymapsManager()
    
    @Published var keymaps: KeymapConfig = KeymapConfig()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        Task { await loadKeymapsAsync() }
    }

    private func loadKeymapsAsync() async {
        let pklURL = getKeymapsURL()

        guard FileManager.default.fileExists(atPath: pklURL.path) else {
            Log.warning("KEYMAPS", "keymaps.pkl not found, using defaults")
            keymaps = KeymapConfig()
            keymaps.keymaps = getDefaultKeymaps()
            NotificationCenter.default.post(name: .keymapsDidChange, object: nil)
            return
        }

        do {
            keymaps = try await PklEvaluator.eval(KeymapConfig.self, from: pklURL)
            Log.info("KEYMAPS", "Loaded from: \(pklURL.path)")
        } catch {
            Log.error("KEYMAPS", "Failed to load: \(error)")
            keymaps = KeymapConfig()
            keymaps.keymaps = getDefaultKeymaps()
        }

        NotificationCenter.default.post(name: .keymapsDidChange, object: nil)
    }
    
    /// Returns the default keymaps array
    private func getDefaultKeymaps() -> [KeymapEntry] {
        return [
            // Navigation
            KeymapEntry(action: "next_email", key: "j", modifiers: [], description: "Next email (vim j)", sequence: false, supportsCount: true),
            KeymapEntry(action: "prev_email", key: "k", modifiers: [], description: "Previous email (vim k)", sequence: false, supportsCount: true),
            KeymapEntry(action: "next_email", key: "Down", modifiers: [], description: "Next email (arrow)", sequence: false, supportsCount: false),
            KeymapEntry(action: "prev_email", key: "Up", modifiers: [], description: "Previous email (arrow)", sequence: false, supportsCount: false),
            KeymapEntry(action: "last_email", key: "G", modifiers: [], description: "Last email (Shift+G)", sequence: false, supportsCount: false),
            KeymapEntry(action: "first_email", key: "gg", modifiers: [], description: "First email (vim gg)", sequence: true, supportsCount: false),
            KeymapEntry(action: "page_down", key: "d", modifiers: ["ctrl"], description: "Half-page down (Ctrl+d)", sequence: false, supportsCount: true),
            KeymapEntry(action: "page_up", key: "u", modifiers: ["ctrl"], description: "Half-page up (Ctrl+u)", sequence: false, supportsCount: true),
            KeymapEntry(action: "archive", key: "a", modifiers: [], description: "Archive email (remove inbox)", sequence: false, supportsCount: false),
            KeymapEntry(action: "compose", key: "c", modifiers: [], description: "Compose new email", sequence: false, supportsCount: false),
            KeymapEntry(action: "reply", key: "r", modifiers: [], description: "Reply to email", sequence: false, supportsCount: false),
            KeymapEntry(action: "reply_all", key: "R", modifiers: [], description: "Reply to all (Shift+R)", sequence: false, supportsCount: false),
            KeymapEntry(action: "forward", key: "f", modifiers: [], description: "Forward email", sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_read", key: "u", modifiers: [], description: "Toggle read/unread", sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_star", key: "s", modifiers: [], description: "Toggle star", sequence: false, supportsCount: false),
            KeymapEntry(action: "delete", key: "dd", modifiers: [], description: "Delete email (vim dd)", sequence: true, supportsCount: true),
            // Folder Navigation
            KeymapEntry(action: "go_inbox", key: "gi", modifiers: [], description: "Go to inbox", sequence: true, supportsCount: false),
            KeymapEntry(action: "go_sent", key: "gs", modifiers: [], description: "Go to sent", sequence: true, supportsCount: false),
            KeymapEntry(action: "go_drafts", key: "gd", modifiers: [], description: "Go to drafts", sequence: true, supportsCount: false),
            KeymapEntry(action: "go_archive", key: "ga", modifiers: [], description: "Go to archive", sequence: true, supportsCount: false),
            // Search
            KeymapEntry(action: "search", key: "/", modifiers: [], description: "Search emails (vim /)", sequence: false, supportsCount: false),
            KeymapEntry(action: "search", key: "/", modifiers: ["cmd"], description: "Search emails (Cmd+/)", sequence: false, supportsCount: false),
            // Tag Picker
            KeymapEntry(action: "tag_picker", key: "t", modifiers: [], description: "Open tag picker", sequence: false, supportsCount: false),
            // View Control
            KeymapEntry(action: "close_detail", key: "q", modifiers: [], description: "Close/back (vim q)", sequence: false, supportsCount: false),
            KeymapEntry(action: "close_detail", key: "Escape", modifiers: [], description: "Close/back (Escape)", sequence: false, supportsCount: false),
            KeymapEntry(action: "reload_inbox", key: "r", modifiers: ["cmd"], description: "Reload inbox (Cmd+r)", sequence: false, supportsCount: false),
            // Visual Mode
            KeymapEntry(action: "enter_visual_mode", key: "v", modifiers: [], description: "Enter line visual mode (range select)", sequence: false, supportsCount: false),
            KeymapEntry(action: "enter_toggle_mode", key: "V", modifiers: [], description: "Enter toggle visual mode (Shift+V)", sequence: false, supportsCount: false),
            KeymapEntry(action: "toggle_selection", key: " ", modifiers: [], description: "Toggle current email (only in toggle mode)", sequence: false, supportsCount: false),
            KeymapEntry(action: "exit_visual_mode", key: "Escape", modifiers: [], description: "Exit visual mode and clear selection", sequence: false, supportsCount: false),
            // Search context
            KeymapEntry(action: "select_next", key: "j", modifiers: ["ctrl"], description: "Next search result (Ctrl+j)", sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_prev", key: "k", modifiers: ["ctrl"], description: "Previous search result (Ctrl+k)", sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_next", key: "n", modifiers: ["ctrl"], description: "Next search result (Ctrl+n)", sequence: false, supportsCount: false, context: "search"),
            KeymapEntry(action: "select_prev", key: "p", modifiers: ["ctrl"], description: "Previous search result (Ctrl+p)", sequence: false, supportsCount: false, context: "search"),
            // Tag picker context
            KeymapEntry(action: "select_next", key: "j", modifiers: ["ctrl"], description: "Next tag (Ctrl+j)", sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_prev", key: "k", modifiers: ["ctrl"], description: "Previous tag (Ctrl+k)", sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_next", key: "n", modifiers: ["ctrl"], description: "Next tag (Ctrl+n)", sequence: false, supportsCount: false, context: "tag_picker"),
            KeymapEntry(action: "select_prev", key: "p", modifiers: ["ctrl"], description: "Previous tag (Ctrl+p)", sequence: false, supportsCount: false, context: "tag_picker"),
            // Compose normal context
            KeymapEntry(action: "exit_insert", key: "jk", modifiers: [], description: "Exit insert mode (jk)", sequence: true, supportsCount: false, context: "compose_normal"),
            // List context: enter thread
            KeymapEntry(action: "enter_thread", key: "l", modifiers: [], description: "Enter thread view (l)", sequence: false, supportsCount: false),
            // Thread context
            KeymapEntry(action: "scroll_down", key: "j", modifiers: [], description: "Scroll down in thread", sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "scroll_up", key: "k", modifiers: [], description: "Scroll up in thread", sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "page_down", key: "d", modifiers: ["ctrl"], description: "Half-page down in thread", sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "page_up", key: "u", modifiers: ["ctrl"], description: "Half-page up in thread", sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "next_message", key: "n", modifiers: [], description: "Next message in thread", sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "prev_message", key: "N", modifiers: [], description: "Previous message in thread", sequence: false, supportsCount: true, context: "thread"),
            KeymapEntry(action: "first_email", key: "gg", modifiers: [], description: "First message in thread", sequence: true, supportsCount: false, context: "thread"),
            KeymapEntry(action: "last_email", key: "G", modifiers: [], description: "Last message in thread", sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "close_detail", key: "h", modifiers: [], description: "Back to email list", sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "close_detail", key: "Escape", modifiers: [], description: "Back to email list", sequence: false, supportsCount: false, context: "thread"),
            KeymapEntry(action: "reply", key: "r", modifiers: [], description: "Reply to email", sequence: false, supportsCount: false, context: "thread"),
        ]
    }

    private func getKeymapsURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/durian/keymaps.pkl")
    }

    
    // MARK: - Public API
    
    func setKeymap(for action: String, key: String, modifiers: [String] = []) {
        if let index = keymaps.keymaps.firstIndex(where: { $0.action == action }) {
            keymaps.keymaps[index].key = key
            keymaps.keymaps[index].modifiers = modifiers
            Log.debug("KEYMAPS", "Set \(action) = \(formatKeymap(key: key, modifiers: modifiers))")
        }
    }
    
    func getKeymap(for action: String) -> KeymapEntry? {
        return keymaps.keymaps.first(where: { $0.action == action })
    }

    func getKeymapsForAction(_ action: String) -> [KeymapEntry] {
        return keymaps.keymaps.filter { $0.action == action }
    }

    func isKeymapPressed(key: String, modifiers: [String], for action: String) -> Bool {
        guard keymaps.globalSettings.keymapsEnabled else {
            return false
        }

        let matchingKeymaps = keymaps.keymaps.filter {
            $0.action == action
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
        Task { await loadKeymapsAsync() }
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
    var sequence: Bool
    var supportsCount: Bool
    var context: String
    var tags: String?  // For tag_op action: "+todo -inbox"

    enum CodingKeys: String, CodingKey {
        case action, key, modifiers, description, sequence
        case supportsCount = "supports_count"
        case context, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        key = try container.decode(String.self, forKey: .key)
        modifiers = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        sequence = try container.decodeIfPresent(Bool.self, forKey: .sequence) ?? false
        supportsCount = try container.decodeIfPresent(Bool.self, forKey: .supportsCount) ?? false
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? "list"
        tags = try container.decodeIfPresent(String.self, forKey: .tags)
    }

    init(action: String, key: String, modifiers: [String] = [], description: String = "", sequence: Bool = false, supportsCount: Bool = false, context: String = "list", tags: String? = nil) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
        self.description = description
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
