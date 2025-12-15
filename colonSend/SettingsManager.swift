import Foundation
import Combine

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var settings: AppSettings = AppSettings()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        loadSettings()
        setupAutoSave()
    }
    
    private func loadSettings() {
        // Settings are loaded from the same config.json file
        settings = ConfigManager.shared.getSettings()
    }
    
    private func setupAutoSave() {
        // Auto-save when settings change
        $settings
            .dropFirst() // Skip initial value
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveSettings()
            }
            .store(in: &cancellables)
    }
    
    private func saveSettings() {
        ConfigManager.shared.updateSettings(settings)
    }
    
    // MARK: - Public API
    
    func setAutoFetchInterval(_ interval: TimeInterval) {
        settings.autoFetchInterval = interval
        print("🔧 Auto-fetch interval set to \(interval) seconds")
    }
    
    func enableAutoFetch(_ enabled: Bool) {
        settings.autoFetchEnabled = enabled
        print("🔧 Auto-fetch \(enabled ? "enabled" : "disabled")")
    }
    
    func resetToDefaults() {
        settings = AppSettings()
        print("SETTINGS: Reset to defaults")
    }
    
    @MainActor
    func reloadSettings() {
        ConfigManager.shared.reloadConfig()
        settings = ConfigManager.shared.getSettings()
        print("SETTINGS: Reloaded from config file")
        
        // Restart sync timers with new settings
        SyncManager.shared.restartTimers()
    }
}

struct AppSettings: Codable {
    var autoFetchEnabled: Bool = true
    var autoFetchInterval: TimeInterval = 60.0 // Quick sync interval (60 seconds)
    var notificationsEnabled: Bool = true
    var theme: String = "system"
    var loadRemoteImages: Bool = false  // Security: block tracking pixels by default
    
    // Sync configuration
    var mbsyncChannels: [String] = []  // Quick sync channels (empty = mbsync -a)
    var fullSyncInterval: TimeInterval = 7200  // Full sync interval (2 hours)
    
    enum CodingKeys: String, CodingKey {
        case autoFetchEnabled = "auto_fetch_enabled"
        case autoFetchInterval = "auto_fetch_interval"
        case notificationsEnabled = "notifications_enabled"
        case theme
        case loadRemoteImages = "load_remote_images"
        case mbsyncChannels = "mbsync_channels"
        case fullSyncInterval = "full_sync_interval"
    }
    
    // Default initializer
    init() {}
    
    // Custom decoder that handles missing keys gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoFetchEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoFetchEnabled) ?? true
        autoFetchInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .autoFetchInterval) ?? 60.0
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        loadRemoteImages = try container.decodeIfPresent(Bool.self, forKey: .loadRemoteImages) ?? false
        mbsyncChannels = try container.decodeIfPresent([String].self, forKey: .mbsyncChannels) ?? []
        fullSyncInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .fullSyncInterval) ?? 7200
    }
}