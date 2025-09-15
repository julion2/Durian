import Foundation
import SwiftUI
import Combine

class KeymapsManager: ObservableObject {
    static let shared = KeymapsManager()
    
    @Published var keymaps: KeymapConfig = KeymapConfig()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        loadKeymaps()
        setupAutoSave()
    }
    
    private func loadKeymaps() {
        let configURL = getKeymapsURL()
        
        // Create keymaps file if it doesn't exist
        if !FileManager.default.fileExists(atPath: configURL.path) {
            createDefaultKeymaps()
        }
        
        do {
            let data = try Data(contentsOf: configURL)
            keymaps = try JSONDecoder().decode(KeymapConfig.self, from: data)
            print("✅ Keymaps loaded from: \(configURL.path)")
        } catch {
            print("❌ Failed to load keymaps: \(error)")
            keymaps = KeymapConfig()
        }
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(keymaps)
            try data.write(to: configURL)
            print("✅ Keymaps saved")
        } catch {
            print("❌ Failed to save keymaps: \(error)")
        }
    }
    
    private func getKeymapsURL() -> URL {
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
        if var keymap = keymaps.keymaps[action] {
            keymap.key = key
            keymap.modifiers = modifiers
            keymaps.keymaps[action] = keymap
            print("🔧 Keymap set: \(action) = \(formatKeymap(key: key, modifiers: modifiers))")
        }
    }
    
    func enableKeymap(for action: String, enabled: Bool) {
        if var keymap = keymaps.keymaps[action] {
            keymap.enabled = enabled
            keymaps.keymaps[action] = keymap
            print("🔧 Keymap \(action) \(enabled ? "enabled" : "disabled")")
        }
    }
    
    func getKeymap(for action: String) -> Keymap? {
        return keymaps.keymaps[action]
    }
    
    func isKeymapPressed(key: String, modifiers: [String], for action: String) -> Bool {
        guard let keymap = keymaps.keymaps[action],
              keymap.enabled,
              keymaps.globalSettings.keymapsEnabled else {
            return false
        }
        
        return keymap.key.lowercased() == key.lowercased() && 
               Set(keymap.modifiers) == Set(modifiers)
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
    var keymaps: [String: Keymap]
    var globalSettings: KeymapGlobalSettings
    
    init() {
        self.keymaps = [
            "reload_inbox": Keymap(
                key: "r",
                modifiers: [],
                description: "Reload current folder/inbox",
                enabled: true
            ),
            "compose_mail": Keymap(
                key: "n", 
                modifiers: ["cmd"],
                description: "Compose new mail",
                enabled: false
            ),
            "mark_read": Keymap(
                key: "u",
                modifiers: [],
                description: "Mark selected email as read", 
                enabled: false
            ),
            "delete_mail": Keymap(
                key: "Delete",
                modifiers: [],
                description: "Delete selected email",
                enabled: false
            )
        ]
        
        self.globalSettings = KeymapGlobalSettings()
    }
}

struct Keymap: Codable {
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