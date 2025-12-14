//
//  ContentView.swift
//  colonSend
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import Combine
import TOMLDecoder

enum DetailViewMode: Equatable {
    case notmuchEmailDetail(emailId: String)
    case empty
}

struct ContentView: View {
    @StateObject private var accountManager = AccountManager.shared
    @StateObject private var keymapsManager = KeymapsManager.shared
    @StateObject private var keymapHandler = KeymapHandler.shared
    @StateObject private var profileManager = ProfileManager.shared
    @State private var selectedTagID: String? = "inbox"
    @State private var selectedNotmuchEmails: Set<String> = []
    @State private var detailMode: DetailViewMode = .empty

    var body: some View {
        notmuchView
    }
    
    // MARK: - Notmuch View
    
    @ViewBuilder
    private var notmuchView: some View {
        NavigationSplitView {
            // Sidebar: Tags + Profile Picker at bottom
            VStack(spacing: 0) {
                List(selection: $selectedTagID) {
                    Section("Tags") {
                        ForEach(accountManager.mailFolders) { folder in
                            Label(folder.displayName, systemImage: folder.icon)
                                .tag(folder.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                
                // Profile Picker - fixed at bottom
                if profileManager.profiles.count > 1 {
                    Picker("", selection: Binding(
                        get: { profileManager.currentProfile },
                        set: { newProfile in
                            if let profile = newProfile {
                                Task {
                                    await accountManager.switchProfile(profile)
                                }
                            }
                        }
                    )) {
                        ForEach(profileManager.profiles) { profile in
                            Text(profile.name).tag(profile as Profile?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("colonSend")
        } content: {
            // Email List
            VStack {
                if accountManager.isLoadingEmails && !accountManager.loadingProgress.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(accountManager.loadingProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                if !accountManager.mailMessages.isEmpty {
                    List(accountManager.mailMessages, selection: $selectedNotmuchEmails) { email in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if !email.isRead {
                                    Circle()
                                        .fill(.blue)
                                        .frame(width: 8, height: 8)
                                }
                                
                                Text(formatSenderName(email.from))
                                    .font(.headline)
                                    .fontWeight(email.isRead ? .regular : .bold)
                                
                                Spacer()
                                
                                Text(email.date)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            
                            HStack(spacing: 4) {
                                Text(email.subject)
                                    .font(.callout)
                                    .fontWeight(email.isRead ? .regular : .semibold)
                                
                                if email.hasAttachment {
                                    Image(systemName: "paperclip")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            if let tags = email.tags {
                                Text(tags)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .onAppear {
                            // Prefetch body when email becomes visible
                            if case .notLoaded = email.bodyState {
                                Task {
                                    await accountManager.fetchNotmuchEmailBody(id: email.id)
                                }
                            }
                        }
                    }
                } else if accountManager.isLoadingEmails {
                    VStack {
                        ProgressView()
                        Text(accountManager.loadingProgress)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                } else {
                    Text("No emails")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                }
            }
            .navigationTitle("colonSend")
            .navigationSubtitle(accountManager.selectedFolder)
            .toolbar {
                ToolbarItem {
                    Button(action: {
                        Task {
                            await accountManager.reloadNotmuch()
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        } detail: {
            // Detail View
            if case .notmuchEmailDetail(let emailId) = detailMode,
               let email = accountManager.mailMessages.first(where: { $0.id == emailId }) {
                notmuchEmailDetailView(email: email)
            } else {
                Text("Select an email")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            Task {
                await accountManager.connectToAllAccounts()
            }
        }
        .onChange(of: selectedTagID) { tagId in
            if let tagId = tagId {
                Task {
                    await accountManager.selectNotmuchTag(tagId)
                }
            }
        }
        .onChange(of: selectedNotmuchEmails) { newSelection in
            if newSelection.count == 1, let emailId = newSelection.first {
                handleNotmuchEmailSelection(emailId)
            }
        }
    }
    
    // MARK: - Email Detail View
    
    @ViewBuilder
    private func notmuchEmailDetailView(email: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed Header
            VStack(alignment: .leading, spacing: 8) {
                Text(email.subject)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("From:")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(email.from)
                            .textSelection(.enabled)
                    }
                    
                    HStack {
                        Text("Date:")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(email.date)
                            .textSelection(.enabled)
                    }
                    
                    if let tags = email.tags {
                        HStack {
                            Text("Tags:")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text(tags)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
            .padding(20)
            .padding(.bottom, 12)
            
            Divider()
            
            // Body - WebView hat eigenes Scrolling, Text braucht ScrollView
            switch email.bodyState {
            case .notLoaded:
                ScrollView {
                    Text("Click to load")
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onTapGesture {
                    Task {
                        await accountManager.fetchNotmuchEmailBody(id: email.id)
                    }
                }
            case .loading:
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let body, _):
                if let html = email.htmlBody, !html.isEmpty {
                    // WebView hat eigenes Scrolling - keine ScrollView nötig
                    EmailWebView(html: html)
                } else {
                    // Text braucht ScrollView
                    ScrollView {
                        Text(makeLinksClickable(body))
                            .textSelection(.enabled)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .failed(let message):
                Text("Failed: \(message)")
                    .foregroundStyle(.red)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .navigationTitle("Email")
        .onAppear {
            // Auto-load body
            if case .notLoaded = email.bodyState {
                Task {
                    await accountManager.fetchNotmuchEmailBody(id: email.id)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func makeLinksClickable(_ text: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        // HTTP/HTTPS URLs - clickable, opens in browser
        let urlPattern = #"https?://[^\s<>\"'\]\)]+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            
            for match in matches {
                if let swiftRange = Range(match.range, in: text),
                   let attrRange = Range(swiftRange, in: attributedString) {
                    let urlString = String(text[swiftRange])
                    if let url = URL(string: urlString) {
                        attributedString[attrRange].link = url
                        attributedString[attrRange].foregroundColor = .blue
                        attributedString[attrRange].underlineStyle = .single
                    }
                }
            }
        }
        
        // Mailto links - just styled blue, not clickable (for now)
        let mailtoPattern = #"mailto:[^\s<>\"'\]\)]+"#
        if let regex = try? NSRegularExpression(pattern: mailtoPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            
            for match in matches {
                if let swiftRange = Range(match.range, in: text),
                   let attrRange = Range(swiftRange, in: attributedString) {
                    attributedString[attrRange].foregroundColor = .blue
                    attributedString[attrRange].underlineStyle = .single
                }
            }
        }
        
        return attributedString
    }
    
    private func handleNotmuchEmailSelection(_ emailId: String) {
        detailMode = .notmuchEmailDetail(emailId: emailId)
        
        // Auto-load body if not loaded
        if let email = accountManager.mailMessages.first(where: { $0.id == emailId }) {
            if case .notLoaded = email.bodyState {
                Task {
                    await accountManager.fetchNotmuchEmailBody(id: emailId)
                }
            }
            
            // Mark as read
            if !email.isRead {
                Task {
                    await accountManager.markNotmuchAsRead(id: emailId)
                }
            }
        }
    }
    
    private func formatSenderName(_ from: String) -> String {
        // Extract name from "Name <email@domain.com>" format
        if let nameRange = from.range(of: "^(.+?)\\s*<.*>$", options: .regularExpression) {
            let name = String(from[nameRange]).replacingOccurrences(of: " <.*>$", with: "", options: .regularExpression)
            return name.trimmingCharacters(in: .whitespaces)
        }
        return from
    }
}

// MARK: - Key Sequence Indicator

/// Shows the current key sequence being typed (vim-style) and visual mode indicator
struct KeySequenceIndicator: View {
    @ObservedObject private var keymapHandler = KeymapHandler.shared
    
    var body: some View {
        HStack(spacing: 8) {
            // Visual Mode Indicator
            if keymapHandler.engine.isVisualMode {
                Text("-- VISUAL --")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.15))
                    )
            }
            
            // Key Sequence Indicator
            if !keymapHandler.currentSequence.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.caption)
                    Text(keymapHandler.currentSequence)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            }
        }
    }
}

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
        return homeURL.appendingPathComponent(".config/colonSend/config.toml")
    }
    
    private func getLegacyConfigURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/colonSend/config.json")
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
        var toml = "# colonSend Configuration\n"
        toml += "# Documentation: https://github.com/julion2/colonSend\n\n"
        
        // Settings section
        toml += "[settings]\n"
        toml += "auto_fetch_enabled = \(config.settings.autoFetchEnabled)\n"
        toml += "auto_fetch_interval = \(config.settings.autoFetchInterval)\n"
        toml += "max_emails_to_fetch = \(config.settings.maxEmailsToFetch)\n"
        toml += "notifications_enabled = \(config.settings.notificationsEnabled)\n"
        toml += "theme = \"\(config.settings.theme)\"\n\n"
        
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
        # colonSend Configuration
        # Documentation: https://github.com/julion2/colonSend

        [settings]
        auto_fetch_enabled = true
        auto_fetch_interval = 60.0
        max_emails_to_fetch = 10
        notifications_enabled = true
        theme = "auto"

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
    
    func getAccounts() -> [MailAccount] {
        return config?.accounts ?? []
    }
    
    func getSettings() -> AppSettings {
        return config?.settings ?? AppSettings()
    }
    
    func getSignatures() -> [String: String] {
        return config?.signatures ?? [:]
    }
    
    func updateSettings(_ newSettings: AppSettings) {
        guard let currentConfig = self.config else { return }
        
        let updatedConfig = AppConfig(accounts: currentConfig.accounts, settings: newSettings, signatures: currentConfig.signatures)
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

#Preview {
    ContentView()
}
