//
//  ContentView.swift
//  colonSend
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var model = Model()
    @StateObject private var keymapsManager = KeymapsManager.shared
    @StateObject private var keymapHandler = KeymapHandler.shared
    @State private var selectedFolderID: UUID? = nil
    @State private var selectedEmail: Email.ID? = nil
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFolderID) {
                ForEach(model.accounts, id: \.email) { account in
                    Section(account.name) {
                        ForEach(model.imapClient.folders) { folder in
                            Label(folder.name, systemImage: folder.icon)
                                .tag(folder.id)
                        }
                        
                        if model.imapClient.folders.isEmpty {
                            Text("Loading folders...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                if model.accounts.isEmpty {
                    Section("Debug") {
                        Text("No accounts found")
                    }
                }
            }.listStyle(.sidebar)
            .navigationTitle("Navigation Split View")
        } content: {
            VStack {
                if model.imapClient.isLoadingEmails && !model.imapClient.loadingProgress.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(model.imapClient.loadingProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                if !model.imapClient.emails.isEmpty {
                    List(model.imapClient.emails, selection: $selectedEmail) { email in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(formatSenderName(email.from))
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text(formatDate(email.date))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(email.subject)
                                .font(.callout)
                            
                            Text(email.body ?? "")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else if model.imapClient.isLoadingEmails {
                    VStack {
                        ProgressView()
                        Text(model.imapClient.loadingProgress)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, idealHeight: 320, maxHeight: .infinity)
                } else {
                    Text("No emails")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240, idealHeight: 320, maxHeight: .infinity)
                }
            }
            .navigationTitle("colonSend")
            .navigationSubtitle(model.imapClient.selectedFolderName ?? "")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(syncIconColor())
                        .padding(.trailing, 8)
                }
            }
        } detail: {
            if let selectedEmail = selectedEmail,
               let email = model.imapClient.emails.first(where: { $0.id == selectedEmail }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header section
                        VStack(alignment: .leading, spacing: 8) {
                            Text(email.subject)
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("From:")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                    Text(formatSenderName(email.from))
                                }
                                
                                HStack {
                                    Text("Date:")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                    Text(formatDate(email.date))
                                }
                                
                                if !email.from.isEmpty && email.from != formatSenderName(email.from) {
                                    HStack {
                                        Text("Email:")
                                            .fontWeight(.medium)
                                            .foregroundStyle(.secondary)
                                        Text(extractEmailAddress(email.from))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                        
                        Divider()
                        
                        // Body section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Message")
                                .font(.headline)
                                .fontWeight(.medium)
                            
                            Text(email.body ?? "Loading...")
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        
                        Spacer()
                    }
                    .padding(20)
                }
                .background(Color(NSColor.controlBackgroundColor))
                .navigationTitle("Email")
            } else {
                VStack {
                    Image(systemName: "envelope")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select an email to view")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            setupKeyboardShortcuts()
            registerKeymapHandlers()
        }
        .onChange(of: selectedFolderID) { folderID in
            if let folderID = folderID,
               let folder = model.imapClient.folders.first(where: { $0.id == folderID }) {
                Task {
                    await model.imapClient.selectFolder(folder.name)
                }
            }
        }
    }
    
    private func setupKeyboardShortcuts() {
        if let reloadKeymap = keymapsManager.getKeymap(for: "reload_inbox") {
            let modStr = reloadKeymap.modifiers.isEmpty ? "" : reloadKeymap.modifiers.joined(separator: "+") + "+"
            print("🎹 Reload shortcut: \(modStr)\(reloadKeymap.key)")
        }
    }
    
    private func registerKeymapHandlers() {
        // Capture model and keymapsManager
        let imapClient = model.imapClient
        let keymapsManager = self.keymapsManager
        
        // Register reload inbox handler
        keymapHandler.registerHandler(for: "reload_inbox") {
            await Self.handleReloadAction(
                imapClient: imapClient, 
                keymapsManager: keymapsManager
            )
        }
        
        print("🎹 Keymap handlers registered")
        
        // Re-register handlers when keymaps change
        keymapsManager.$keymaps
            .sink { [weak keymapHandler] _ in
                print("🎹 Keymaps changed, re-registering handlers")
                keymapHandler?.registerHandler(for: "reload_inbox") {
                    await Self.handleReloadAction(
                        imapClient: imapClient, 
                        keymapsManager: keymapsManager
                    )
                }
            }
            .store(in: &cancellables)
    }
    
    private static func handleReloadAction(
        imapClient: IMAPClient, 
        keymapsManager: KeymapsManager
    ) async {
        print("🎹 DEBUG: Reload action triggered!")
        
        let keymap = keymapsManager.getKeymap(for: "reload_inbox")
        print("🎹 DEBUG: Keymap found: \(keymap != nil)")
        print("🎹 DEBUG: Keymap enabled: \(keymap?.enabled ?? false)")
        print("🎹 DEBUG: Global keymaps enabled: \(keymapsManager.keymaps.globalSettings.keymapsEnabled)")
        
        guard keymap?.enabled == true && keymapsManager.keymaps.globalSettings.keymapsEnabled else {
            print("🎹 DEBUG: Keymap disabled, not executing")
            return
        }
        
        print("🎹 DEBUG: Executing reload for current folder: \(imapClient.selectedFolderName ?? "none")")
        print("🎹 DEBUG: IMAP connected: \(imapClient.isConnected)")
        
        await imapClient.reloadCurrentFolder()
    }
    
    private func formatSenderName(_ from: String) -> String {
        // Extract name from "Name <email@domain.com>" format
        if let nameRange = from.range(of: "^(.+?)\\s*<.*>$", options: .regularExpression) {
            let name = String(from[nameRange]).replacingOccurrences(of: " <.*>$", with: "", options: .regularExpression)
            return name.trimmingCharacters(in: .whitespaces)
        }
        return from
    }
    
    private func formatDate(_ dateString: String) -> String {
        // Parse common date formats and return without seconds and year
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Try different date formats
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss"
        ]
        
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                let outputFormatter = DateFormatter()
                outputFormatter.dateFormat = "MMM dd, HH:mm"
                return outputFormatter.string(from: date)
            }
        }
        
        // If parsing fails, return original
        return dateString
    }
    
    private func syncIconColor() -> Color {
        if model.imapClient.loadingProgress.contains("Failed") {
            return .red
        } else if model.imapClient.isLoadingEmails {
            return .blue
        } else {
            return .secondary
        }
    }
    
    private func extractEmailAddress(_ from: String) -> String {
        // Extract email from "Name <email@domain.com>" format
        if let emailRange = from.range(of: "<(.+?)>", options: .regularExpression) {
            let email = String(from[emailRange]).replacingOccurrences(of: "[<>]", with: "", options: .regularExpression)
            return email
        }
        return from
    }

    @MainActor
    class Model: ObservableObject {
        @Published var folders: [Folder] = []
        @Published var accounts: [MailAccount] = []
        @Published var imapClient = IMAPClient()
        private var cancellables = Set<AnyCancellable>()
        
        init() {
            loadAccounts()
            setupFolders()
            
            // Forward IMAP client changes to trigger UI updates
            imapClient.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
            }.store(in: &cancellables)
            
            Task {
                await testIMAPConnection()
            }
        }
        
        private func loadAccounts() {
            accounts = ConfigManager.shared.accounts
        }
        
        private func setupFolders() {
            folders = [
                Folder(name: "Important", icon: "folder", emails: [
                    Email(name: "Steve J.", subject: "Important Meeting", date: "Yesterday")
                ]),
                Folder(name: "Inbox", icon: "tray", emails: [
                    Email(name: "Steve J.", subject: "Project Update", date: "Yesterday")
                ]),
                Folder(name: "Drafts", icon: "doc"),
                Folder(name: "Sent", icon: "paperplane"),
                Folder(name: "Junk", icon: "xmark.bin"),
                Folder(name: "Trash", icon: "trash"),
            ]
        }
        
        func folder(id: Folder.ID?) -> Folder? {
            folders.first(where: { $0.id == id })
        }
        
        func email(folderId: Folder.ID?, id: Email.ID?) -> Email? {
            if let folder = folder(id: folderId) {
                folder.emails.first(where: { $0.id == id })
            } else {
                nil
            }
        }
        
        private func testIMAPConnection() async {
            guard let firstAccount = accounts.first else {
                print("No accounts configured for IMAP test")
                return
            }
            
            print("Testing IMAP connection for: \(firstAccount.name)")
            await imapClient.connect(account: firstAccount)
        }
    }
}

struct Folder: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    var emails: [Email] = []
}

struct Email: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var body: String?
    var date: String
}

struct MailAccount: Codable {
    let name: String
    let email: String
    let imap: ServerConfig
    let smtp: ServerConfig
    let auth: AuthConfig
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
    
    init(accounts: [MailAccount], settings: AppSettings = AppSettings()) {
        self.accounts = accounts
        self.settings = settings
    }
}

class ConfigManager {
    static let shared = ConfigManager()
    private var config: AppConfig?
    
    private init() {
        loadConfig()
    }
    
    private func loadConfig() {
        let configURL = getConfigURL()
        
        // Create config directory if it doesn't exist
        let configDir = configURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: configDir.path) {
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            } catch {
                print("Failed to create config directory: \(error)")
                return
            }
        }
        
        // Create default config if it doesn't exist
        if !FileManager.default.fileExists(atPath: configURL.path) {
            createDefaultConfig(at: configURL)
        }
        
        // Load config
        do {
            let data = try Data(contentsOf: configURL)
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            print("Failed to load config: \(error)")
        }
    }
    
    private func getConfigURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        return homeURL.appendingPathComponent(".config/colonSend/config.json")
    }
    
    private func createDefaultConfig(at url: URL) {
        let defaultConfig = AppConfig(
            accounts: [
                MailAccount(
                    name: "Ethereal Test",
                    email: "test@ethereal.email",
                    imap: ServerConfig(host: "imap.ethereal.email", port: 143, ssl: false),
                    smtp: ServerConfig(host: "smtp.ethereal.email", port: 587, ssl: false),
                    auth: AuthConfig(username: "test", passwordKeychain: "ethereal-test")
                )
            ],
            settings: AppSettings()
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(defaultConfig)
            try data.write(to: url)
            print("Created default config at: \(url.path)")
        } catch {
            print("Failed to create default config: \(error)")
        }
    }
    
    var accounts: [MailAccount] {
        return config?.accounts ?? []
    }
    
    var settings: AppSettings {
        return config?.settings ?? AppSettings()
    }
    
    func updateSettings(_ newSettings: AppSettings) {
        guard let config = self.config else { return }
        
        let updatedConfig = AppConfig(accounts: config.accounts, settings: newSettings)
        self.config = updatedConfig
        
        saveConfigToFile()
    }
    
    private func saveConfigToFile() {
        guard let config = self.config else { return }
        
        let configURL = getConfigURL()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL)
            print("✅ Config saved to \(configURL.path)")
        } catch {
            print("❌ Failed to save config: \(error)")
        }
    }
}

#Preview {
    ContentView()
}
