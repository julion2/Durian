//
//  ConfigManager.swift
//  Durian
//
//  Manages app configuration from config.toml
//

import Foundation
import TOMLDecoder

// MARK: - Config Models

struct MailAccount: Codable {
    let name: String
    let email: String
    let imap: ServerConfig
    let smtp: ServerConfig
    let auth: AuthConfig
    let defaultSignature: String?
    
    enum CodingKeys: String, CodingKey {
        case name, email, imap, smtp, auth
        case defaultSignature = "default_signature"
    }
}

struct ServerConfig: Codable {
    let host: String
    let port: Int
    let ssl: Bool
}

struct AuthConfig: Codable {
    let username: String
    let passwordKeychain: String?
    
    enum CodingKeys: String, CodingKey {
        case username
        case passwordKeychain = "password_keychain"
    }
}

struct AppConfig: Codable {
    let accounts: [MailAccount]
    let settings: AppSettings
    let signatures: [String: String]
    
    init(accounts: [MailAccount], settings: AppSettings = AppSettings(), signatures: [String: String] = [:]) {
        self.accounts = accounts
        self.settings = settings
        self.signatures = signatures
    }
}

// MARK: - Config Manager

class ConfigManager {
    static let shared = ConfigManager()
    private var config: AppConfig?
    
    private init() {
        loadConfig()
    }
    
    private func loadConfig() {
        let tomlURL = getConfigURL()
        let jsonURL = getLegacyConfigURL()
        
        // Create config directory if it doesn't exist
        let configDir = tomlURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: configDir.path) {
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            } catch {
                print("CONFIG_ERROR: Failed to create config directory: \(error)")
                return
            }
        }
        
        // Migration: Check if JSON config exists but TOML doesn't
        if FileManager.default.fileExists(atPath: jsonURL.path) && !FileManager.default.fileExists(atPath: tomlURL.path) {
            migrateFromJSON(jsonURL: jsonURL, tomlURL: tomlURL)
        }
        
        // Create default config if it doesn't exist
        if !FileManager.default.fileExists(atPath: tomlURL.path) {
            createDefaultConfig(at: tomlURL)
        }
        
        // Load config from TOML
        do {
            let tomlString = try String(contentsOf: tomlURL, encoding: .utf8)
            config = try TOMLDecoder().decode(AppConfig.self, from: tomlString)
            print("CONFIG: Loaded config from \(tomlURL.path)")
        } catch {
            print("CONFIG_ERROR: Failed to load config: \(error)")
        }
    }
    
    private func getConfigURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/durian/config.toml")
    }
    
    private func getLegacyConfigURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/durian/config.json")
    }
    
    private func migrateFromJSON(jsonURL: URL, tomlURL: URL) {
        print("CONFIG: Migrating from JSON to TOML...")
        do {
            let jsonData = try Data(contentsOf: jsonURL)
            let jsonConfig = try JSONDecoder().decode(AppConfig.self, from: jsonData)
            
            // Write as TOML
            let tomlString = generateTOML(from: jsonConfig)
            try tomlString.write(to: tomlURL, atomically: true, encoding: .utf8)
            
            // Backup old JSON file
            let backupURL = jsonURL.deletingPathExtension().appendingPathExtension("json.bak")
            try FileManager.default.moveItem(at: jsonURL, to: backupURL)
            
            print("CONFIG: Migration complete. JSON backup at \(backupURL.path)")
        } catch {
            print("CONFIG_ERROR: Migration failed: \(error)")
        }
    }
    
    private func generateTOML(from config: AppConfig) -> String {
        var toml = "# Durian Configuration\n"
        toml += "# Documentation: https://github.com/julion2/durian\n\n"
        
        // Settings section
        toml += "[settings]\n"
        toml += "auto_fetch_enabled = \(config.settings.autoFetchEnabled)\n"
        toml += "auto_fetch_interval = \(config.settings.autoFetchInterval)\n"
        toml += "notifications_enabled = \(config.settings.notificationsEnabled)\n"
        toml += "theme = \"\(config.settings.theme)\"\n"
        toml += "load_remote_images = \(config.settings.loadRemoteImages)\n"
        
        // Sync configuration
        toml += "full_sync_interval = \(config.settings.fullSyncInterval)  # Full sync every 2 hours\n\n"
        
        // Signatures section
        if !config.signatures.isEmpty {
            toml += "[signatures]\n"
            for (name, content) in config.signatures {
                // Use TOML multi-line strings (triple quotes) for values with newlines
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
        
        // Accounts array
        for account in config.accounts {
            toml += "[[accounts]]\n"
            toml += "name = \"\(account.name)\"\n"
            toml += "email = \"\(account.email)\"\n"
            if let sig = account.defaultSignature {
                toml += "default_signature = \"\(sig)\"\n"
            }
            toml += "\n"
            
            toml += "[accounts.imap]\n"
            toml += "host = \"\(account.imap.host)\"\n"
            toml += "port = \(account.imap.port)\n"
            toml += "ssl = \(account.imap.ssl)\n\n"
            
            toml += "[accounts.smtp]\n"
            toml += "host = \"\(account.smtp.host)\"\n"
            toml += "port = \(account.smtp.port)\n"
            toml += "ssl = \(account.smtp.ssl)\n\n"
            
            toml += "[accounts.auth]\n"
            toml += "username = \"\(account.auth.username)\"\n"
            if let keychain = account.auth.passwordKeychain {
                toml += "password_keychain = \"\(keychain)\"\n"
            }
            toml += "\n"
        }
        
        return toml
    }
    
    private func createDefaultConfig(at url: URL) {
        let defaultTOML = """
        # Durian Configuration
        # Documentation: https://github.com/julion2/durian

        [settings]
        auto_fetch_enabled = true
        auto_fetch_interval = 60.0
        notifications_enabled = true
        theme = "system"
        load_remote_images = false
        
        # Sync configuration
        # Quick sync channels (empty array = mbsync -a for all channels)
        mbsync_channels = []
        # Full sync interval in seconds (7200 = 2 hours)
        full_sync_interval = 7200

        [signatures]
        # Add your signatures here:
        # work = "Best regards,\\nYour Name"

        [[accounts]]
        name = "Default"
        email = "user@example.com"

        [accounts.imap]
        host = "imap.example.com"
        port = 993
        ssl = true

        [accounts.smtp]
        host = "smtp.example.com"
        port = 587
        ssl = false

        [accounts.auth]
        username = "user"
        password_keychain = "example-password"

        """
        
        do {
            try defaultTOML.write(to: url, atomically: true, encoding: .utf8)
            print("CONFIG: Created default config at \(url.path)")
            
            // Load the config after creating it
            let tomlString = try String(contentsOf: url, encoding: .utf8)
            config = try TOMLDecoder().decode(AppConfig.self, from: tomlString)
        } catch {
            print("CONFIG_ERROR: Failed to create default config: \(error)")
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
    
    /// Reload config from disk (call after editing config.toml)
    func reloadConfig() {
        print("CONFIG: Reloading config...")
        loadConfig()
        print("CONFIG: Reload complete")
    }
    
    func updateSettings(_ newSettings: AppSettings) {
        guard let config = self.config else { return }
        
        let updatedConfig = AppConfig(accounts: config.accounts, settings: newSettings, signatures: config.signatures)
        self.config = updatedConfig
        
        saveConfigToFile()
    }
    
    private func saveConfigToFile() {
        guard let config = self.config else { return }
        
        let configURL = getConfigURL()
        do {
            let tomlString = generateTOML(from: config)
            try tomlString.write(to: configURL, atomically: true, encoding: .utf8)
            print("CONFIG: Saved config to \(configURL.path)")
        } catch {
            print("CONFIG_ERROR: Failed to save config: \(error)")
        }
    }
}
