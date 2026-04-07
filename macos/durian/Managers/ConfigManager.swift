//
//  ConfigManager.swift
//  Durian
//
//  Manages app configuration from config.toml
//  Note: IMAP/SMTP config is handled by CLI, GUI only needs account names/emails
//

import Foundation
import TOMLDecoder

// MARK: - Config Models

/// Simplified account info - GUI only needs name/email for account picker
/// IMAP/SMTP configuration is handled by the durian CLI
struct MailAccount: Codable {
    let name: String
    let email: String
    let defaultSignature: String?
    let notifications: Bool?

    enum CodingKeys: String, CodingKey {
        case name, email, notifications
        case defaultSignature = "default_signature"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decode(String.self, forKey: .email)
        defaultSignature = try container.decodeIfPresent(String.self, forKey: .defaultSignature)
        notifications = try container.decodeIfPresent(Bool.self, forKey: .notifications)

        // Skip IMAP/SMTP/Auth sections - they're handled by CLI
    }

    init(name: String, email: String, defaultSignature: String? = nil, notifications: Bool? = nil) {
        self.name = name
        self.email = email
        self.defaultSignature = defaultSignature
        self.notifications = notifications
    }
}

/// Sync settings from [sync] TOML section
/// These control GUI auto-sync behavior and intervals
struct SyncSettings: Codable {
    var mode: String = "bidirectional"
    var guiAutoSync: Bool = true
    var autoFetchInterval: TimeInterval = 60.0
    var fullSyncInterval: TimeInterval = 14400
    
    enum CodingKeys: String, CodingKey {
        case mode
        case guiAutoSync = "gui_auto_sync"
        case autoFetchInterval = "auto_fetch_interval"
        case fullSyncInterval = "full_sync_interval"
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "bidirectional"
        guiAutoSync = try container.decodeIfPresent(Bool.self, forKey: .guiAutoSync) ?? true
        autoFetchInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .autoFetchInterval) ?? 60.0
        fullSyncInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .fullSyncInterval) ?? 14400
    }
}

struct AppConfig: Codable {
    let accounts: [MailAccount]
    let settings: AppSettings
    let sync: SyncSettings
    let signatures: [String: String]
    
    init(accounts: [MailAccount], settings: AppSettings = AppSettings(), sync: SyncSettings = SyncSettings(), signatures: [String: String] = [:]) {
        self.accounts = accounts
        self.settings = settings
        self.sync = sync
        self.signatures = signatures
    }
    
    enum CodingKeys: String, CodingKey {
        case accounts, settings, sync, signatures
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([MailAccount].self, forKey: .accounts) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        sync = try container.decodeIfPresent(SyncSettings.self, forKey: .sync) ?? SyncSettings()
        signatures = try container.decodeIfPresent([String: String].self, forKey: .signatures) ?? [:]
    }
}

// MARK: - Config Manager

class ConfigManager {
    static let shared = ConfigManager()
    private var config: AppConfig?
    
    init() {
        loadConfig()
    }

    /// Test-only initializer: inject config directly, skip file loading
    init(config: AppConfig) {
        self.config = config
    }
    
    private func loadConfig() {
        let tomlURL = getConfigURL()
        
        // Create config directory if it doesn't exist
        let configDir = tomlURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: configDir.path) {
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            } catch {
                Log.error("CONFIG", "Failed to create config directory: \(error)")
                return
            }
        }
        
        // Create default config if it doesn't exist
        if !FileManager.default.fileExists(atPath: tomlURL.path) {
            createDefaultConfig(at: tomlURL)
        }
        
        // Load config from TOML
        do {
            let tomlString = try String(contentsOf: tomlURL, encoding: .utf8)
            config = try TOMLDecoder().decode(AppConfig.self, from: tomlString)
            Log.info("CONFIG", "Loaded config from \(tomlURL.path)")
        } catch {
            Log.error("CONFIG", "Failed to load config: \(error)")
        }
    }
    
    private func getConfigURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/durian/config.toml")
    }
    
    private func createDefaultConfig(at url: URL) {
        // Note: This is a minimal GUI config. The CLI config has IMAP/SMTP details.
        let defaultTOML = """
        # Durian Configuration
        # Documentation: https://github.com/julion2/durian
        #
        # Note: IMAP/SMTP configuration should be done in the CLI config.
        # Run 'durian auth login <email>' to set up accounts.

        [settings]
        notifications_enabled = true
        theme = "system"
        load_remote_images = false

        [sync]
        mode = "bidirectional"
        gui_auto_sync = true
        auto_fetch_interval = 60
        full_sync_interval = 7200

        [signatures]
        # Add your signatures here:
        # work = "Best regards,\\nYour Name"

        # Accounts are loaded from the CLI config (~/.config/durian/config.toml)
        # The GUI only needs name and email for the account picker.
        # [[accounts]]
        # name = "Personal"
        # email = "user@example.com"
        # default_signature = "work"

        """
        
        do {
            try defaultTOML.write(to: url, atomically: true, encoding: .utf8)
            Log.debug("CONFIG", "Created default config at \(url.path)")
            
            // Load the config after creating it
            let tomlString = try String(contentsOf: url, encoding: .utf8)
            config = try TOMLDecoder().decode(AppConfig.self, from: tomlString)
        } catch {
            Log.error("CONFIG", "Failed to create default config: \(error)")
        }
    }
    
    // MARK: - Public API
    
    func getAccounts() -> [MailAccount] {
        return config?.accounts ?? []
    }
    
    func getSettings() -> AppSettings {
        return config?.settings ?? AppSettings()
    }
    
    func getSignatures() -> [String: String] {
        return config?.signatures ?? [:]
    }
    
    func getSyncSettings() -> SyncSettings {
        return config?.sync ?? SyncSettings()
    }
    
    /// Reload config from disk (call after editing config.toml)
    func reloadConfig() {
        Log.info("CONFIG", "Reloading config...")
        loadConfig()
        Log.info("CONFIG", "Reload complete")
    }
    
    func updateSettings(_ newSettings: AppSettings) {
        guard let currentConfig = self.config else { return }
        
        let updatedConfig = AppConfig(accounts: currentConfig.accounts, settings: newSettings, sync: currentConfig.sync, signatures: currentConfig.signatures)
        self.config = updatedConfig
        
        saveConfigToFile()
    }
    
    private func saveConfigToFile() {
        guard let config = self.config else { return }
        
        let configURL = getConfigURL()
        do {
            let tomlString = generateTOML(from: config)
            try tomlString.write(to: configURL, atomically: true, encoding: .utf8)
            Log.debug("CONFIG", "Saved config to \(configURL.path)")
        } catch {
            Log.error("CONFIG", "Failed to save config: \(error)")
        }
    }
    
    func generateTOML(from config: AppConfig) -> String {
        var toml = "# Durian Configuration\n"
        toml += "# Documentation: https://github.com/julion2/durian\n\n"
        
        // Settings section
        toml += "[settings]\n"
        toml += "notifications_enabled = \(config.settings.notificationsEnabled)\n"
        toml += "theme = \"\(config.settings.theme)\"\n"
        toml += "load_remote_images = \(config.settings.loadRemoteImages)\n"
        if let accent = config.settings.accentColor {
            toml += "accent_color = \"\(accent)\"\n"
        }
        toml += "\n"
        
        // Sync section
        toml += "[sync]\n"
        toml += "mode = \"\(config.sync.mode)\"\n"
        toml += "gui_auto_sync = \(config.sync.guiAutoSync)\n"
        toml += "auto_fetch_interval = \(Int(config.sync.autoFetchInterval))\n"
        toml += "full_sync_interval = \(Int(config.sync.fullSyncInterval))\n\n"
        
        // Signatures section
        if !config.signatures.isEmpty {
            toml += "[signatures]\n"
            for (name, content) in config.signatures {
                if content.contains("\n") {
                    toml += "\(name) = \"\"\"\n\(content)\"\"\"\n"
                } else {
                    let escapedContent = content
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    toml += "\(name) = \"\(escapedContent)\"\n"
                }
            }
            toml += "\n"
        }
        
        // Accounts array (simplified - no IMAP/SMTP)
        for account in config.accounts {
            toml += "[[accounts]]\n"
            toml += "name = \"\(account.name)\"\n"
            toml += "email = \"\(account.email)\"\n"
            if let sig = account.defaultSignature {
                toml += "default_signature = \"\(sig)\"\n"
            }
            if let notify = account.notifications {
                toml += "notifications = \(notify)\n"
            }
            toml += "\n"
        }
        
        return toml
    }
}
