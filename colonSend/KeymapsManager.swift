import Foundation
import SwiftUI
import Combine
import TOMLDecoder

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
        var toml = "# colonSend Keymaps Configuration\n"
        toml += "# Vim-style keybindings for email navigation\n\n"
        
        // Global settings
        toml += "[global_settings]\n"
        toml += "keymaps_enabled = \(config.globalSettings.keymapsEnabled)\n"
        toml += "show_keymap_hints = \(config.globalSettings.showKeymapHints)\n\n"
        
        // Keymaps array
        for entry in config.keymaps {
            toml += "[[keymaps]]\n"
            toml += "action = \"\(entry.action)\"\n"
            toml += "key = \"\(entry.key)\"\n"
            toml += "modifiers = [\(entry.modifiers.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
            toml += "description = \"\(entry.description)\"\n"
            toml += "enabled = \(entry.enabled)\n\n"
        }
        
        return toml
    }
    
    private func getKeymapsURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/colonSend/keymaps.toml")
    }
    
    private func getLegacyKeymapsURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/colonSend/keymaps.json")
    }
    
    private func createDefaultKeymaps() {
        let defaultKeymaps = KeymapConfig()
        keymaps = defaultKeymaps
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
}

struct KeymapGlobalSettings: Codable {
    var keymapsEnabled: Bool = true
    var showKeymapHints: Bool = true
    
    enum CodingKeys: String, CodingKey {
        case keymapsEnabled = "keymaps_enabled"
        case showKeymapHints = "show_keymap_hints"
    }
}