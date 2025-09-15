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
    @State private var selectedFolder: UUID? = nil
    @State private var selectedEmail: Email.ID? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFolder) {
                ForEach(model.accounts, id: \.email) { account in
                    Section(account.name) {
                        ForEach(model.imapClient.folders) { folder in
                            Label(folder.name, systemImage: folder.icon)
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
            if let folder = model.folder(id: selectedFolder) {
                List(folder.emails, selection: $selectedEmail) { email in
                    VStack(alignment: .leading, spacing: 2) {
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
                        
                        Text(email.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }.navigationTitle(folder.name)
            } else {
                Text("Content")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, minHeight: 240, idealHeight: 320, maxHeight: .infinity)
            }
        } detail: {
            if let email = model.email(folderId: selectedFolder, id: selectedEmail) {
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
    }

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
            
            testIMAPConnection()
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
        
        private func testIMAPConnection() {
            guard let firstAccount = accounts.first else {
                print("No accounts configured for IMAP test")
                return
            }
            
            print("Testing IMAP connection for: \(firstAccount.name)")
            Task {
                await imapClient.connect(account: firstAccount)
            }
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
        let defaultConfig = AppConfig(accounts: [
            MailAccount(
                name: "Ethereal Test",
                email: "test@ethereal.email",
                imap: ServerConfig(host: "imap.ethereal.email", port: 143, ssl: false),
                smtp: ServerConfig(host: "smtp.ethereal.email", port: 587, ssl: false),
                auth: AuthConfig(username: "test", passwordKeychain: "ethereal-test")
            )
        ])
        
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
}

#Preview {
    ContentView()
}
