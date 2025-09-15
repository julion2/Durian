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
                                .onTapGesture {
                                    selectedFolderID = folder.id
                                    Task {
                                        await model.imapClient.selectFolder(folder.name)
                                    }
                                }
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
                                Text(email.from)
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text(email.date)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(email.subject)
                                .font(.callout)
                            
                            Text(email.body)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .navigationTitle(model.imapClient.selectedFolderName ?? "Emails")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            if model.imapClient.hasMoreMessages && !model.imapClient.isLoadingEmails {
                                Button("Load More") {
                                    Task {
                                        await model.imapClient.loadMoreEmails()
                                    }
                                }
                            }
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
        } detail: {
            if let email = model.email(folderId: selectedFolderID, id: selectedEmail) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(email.name)
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text(email.date)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(email.subject)
                                .font(.callout)
                        }
                        
                        Divider()
                        
                        Text(email.body)
                    }.padding(.all, 16)
                }
            } else {
                Text("Detail")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, minHeight: 240, idealHeight: 320, maxHeight: .infinity)
            }
        }
        .onAppear {
            setupKeyboardShortcuts()
            registerKeymapHandlers()
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
                    Email(name: "Steve J.", subject: "Important Meeting", body: "Please review the attached documents for tomorrow's meeting.", date: "Yesterday")
                ]),
                Folder(name: "Inbox", icon: "tray", emails: [
                    Email(name: "Steve J.", subject: "Project Update", body: "The project is progressing well and we should have an update soon.", date: "Yesterday")
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
    var body: String
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
