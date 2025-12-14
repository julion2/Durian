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
    
    func setMaxEmailsToFetch(_ count: Int) {
        settings.maxEmailsToFetch = count
        print("🔧 Max emails to fetch set to \(count)")
    }
    
    func resetToDefaults() {
        settings = AppSettings()
        print("🔧 Settings reset to defaults")
    }
}

struct AppSettings: Codable {
    var autoFetchEnabled: Bool = true
    var autoFetchInterval: TimeInterval = 60.0 // 60 seconds
    var maxEmailsToFetch: Int = 10
    var notificationsEnabled: Bool = true
    var theme: String = "system"
    
    enum CodingKeys: String, CodingKey {
        case autoFetchEnabled = "auto_fetch_enabled"
        case autoFetchInterval = "auto_fetch_interval"
        case maxEmailsToFetch = "max_emails_to_fetch"
        case notificationsEnabled = "notifications_enabled"
        case theme
    }
}