//
//  ContentView.swift
//  colonSend
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import Combine

enum DetailViewMode: Equatable {
    case emailDetail(IMAPEmail)
    case compose(replyTo: IMAPEmail?)
    case empty
}

struct ContentView: View {
    @StateObject private var accountManager = AccountManager.shared
    @StateObject private var keymapsManager = KeymapsManager.shared
    @StateObject private var keymapHandler = KeymapHandler.shared
    @State private var selectedFolderID: UUID? = nil
    @State private var selectedEmail: Email.ID? = nil
    @State private var cancellables = Set<AnyCancellable>()
    @State private var detailMode: DetailViewMode = .empty
    @State private var lastViewedEmail: IMAPEmail? = nil
    @State private var triggerSend = false
    @State private var composeDraft: EmailDraft?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFolderID) {
                ForEach(accountManager.accounts, id: \.email) { account in
                    Section(account.name) {
                        ForEach(accountManager.allFolders.filter { $0.accountId == account.email }) { folder in
                            Label(folder.name, systemImage: folder.icon)
                                .tag(folder.id)
                        }
                        
                        if accountManager.allFolders.filter({ $0.accountId == account.email }).isEmpty {
                            Text("Loading folders...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                if accountManager.accounts.isEmpty {
                    Section("Debug") {
                        Text("No accounts found")
                    }
                }
            }.listStyle(.sidebar)
            .navigationTitle("Navigation Split View")
        } content: {
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
                
                if !accountManager.allEmails.isEmpty {
                    List(accountManager.allEmails.sorted { $0.uid > $1.uid }, selection: $selectedEmail) { email in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                // Unread indicator
                                if !email.isRead {
                                    Circle()
                                        .fill(.blue)
                                        .frame(width: 8, height: 8)
                                }
                                
                                Text(formatSenderName(email.from))
                                    .font(.headline)
                                    .fontWeight(email.isRead ? .regular : .bold)
                                
                                Spacer()
                                
                                Text(formatDate(email.date))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(email.subject)
                                .font(.callout)
                                .fontWeight(email.isRead ? .regular : .semibold)
                            
                            Text(email.body ?? "")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
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
            .navigationSubtitle(getSelectedFolderName())
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        detailMode = .compose(replyTo: nil)
                    }) {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
                
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        Task {
                            await accountManager.reloadCurrentFolder()
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(syncIconColor())
                    }
                }
                
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        triggerSend = true
                    }) {
                        Label("Send", systemImage: "paperplane")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(shouldDisableSend())
                }
            }
        } detail: {
            switch detailMode {
            case .emailDetail(let email):
                emailDetailView(email: email)
                
            case .compose(let replyTo):
                EmailComposeView(
                    accounts: accountManager.accounts,
                    replyTo: replyTo,
                    existingDraft: composeDraft,
                    triggerSend: $triggerSend,
                    currentDraft: $composeDraft,
                    onDismiss: {
                        if let lastEmail = lastViewedEmail {
                            detailMode = .emailDetail(lastEmail)
                        } else {
                            detailMode = .empty
                        }
                    }
                )
                
            case .empty:
                VStack {
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
            Task {
                await accountManager.connectToAllAccounts()
            }
        }
        .onChange(of: selectedFolderID) { folderID in
            if let folderID = folderID,
               let folder = accountManager.allFolders.first(where: { $0.id == folderID }) {
                Task {
                    await accountManager.selectFolder(folder.name, accountId: folder.accountId)
                }
            }
        }
        .onChange(of: selectedEmail) { emailID in
            handleEmailSelection(emailID)
        }
    }
    
    private func setupKeyboardShortcuts() {
        if let reloadKeymap = keymapsManager.getKeymap(for: "reload_inbox") {
            let modStr = reloadKeymap.modifiers.isEmpty ? "" : reloadKeymap.modifiers.joined(separator: "+") + "+"
            print("🎹 Reload shortcut: \(modStr)\(reloadKeymap.key)")
        }
    }
    
    private func registerKeymapHandlers() {
        // Capture accountManager and keymapsManager
        let accountManager = self.accountManager
        let keymapsManager = self.keymapsManager
        
        // Register reload inbox handler
        keymapHandler.registerHandler(for: "reload_inbox") {
            await Self.handleReloadAction(
                accountManager: accountManager, 
                keymapsManager: keymapsManager
            )
        }
        
        // Register toggle read status handler
        keymapHandler.registerHandler(for: "toggle_read") {
            await Self.handleToggleReadAction(
                selectedEmail: selectedEmail,
                accountManager: accountManager,
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
                        accountManager: accountManager, 
                        keymapsManager: keymapsManager
                    )
                }
                keymapHandler?.registerHandler(for: "toggle_read") {
                    await Self.handleToggleReadAction(
                        selectedEmail: selectedEmail,
                        accountManager: accountManager,
                        keymapsManager: keymapsManager
                    )
                }
            }
            .store(in: &cancellables)
    }
    
    private static func handleReloadAction(
        accountManager: AccountManager, 
        keymapsManager: KeymapsManager
    ) async {
        let keymap = keymapsManager.getKeymap(for: "reload_inbox")
        
        guard keymap?.enabled == true && keymapsManager.keymaps.globalSettings.keymapsEnabled else {
            return
        }
        
        await accountManager.reloadCurrentFolder()
    }
    
    private static func handleToggleReadAction(
        selectedEmail: Email.ID?,
        accountManager: AccountManager,
        keymapsManager: KeymapsManager
    ) async {
        let keymap = keymapsManager.getKeymap(for: "toggle_read")
        
        guard keymap?.enabled == true && keymapsManager.keymaps.globalSettings.keymapsEnabled else {
            return
        }
        
        guard let selectedEmailID = selectedEmail,
              let email = accountManager.allEmails.first(where: { $0.id == selectedEmailID }) else {
            return
        }
        await accountManager.toggleReadStatus(uid: email.uid)
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
        // Parse common date formats and return in dd.MM.yy format
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Try different date formats (most common first)
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",      // Standard RFC 2822
            "EEE, d MMM yyyy HH:mm:ss Z",       // Single digit day
            "dd MMM yyyy HH:mm:ss Z",           // Without weekday
            "d MMM yyyy HH:mm:ss Z",            // Single digit, no weekday
            "EEE, dd MMM yyyy HH:mm:ss",        // Without timezone
            "EEE, d MMM yyyy HH:mm:ss",         // Single digit, no timezone
            "yyyy-MM-dd HH:mm:ss Z",            // ISO-like with timezone
            "yyyy-MM-dd'T'HH:mm:ssZ",           // ISO 8601 compact
            "yyyy-MM-dd'T'HH:mm:ss",            // ISO without timezone
            "dd MMM yyyy HH:mm:ss",             // Simple format
            "d MMM yyyy HH:mm:ss",              // Simple, single digit
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                let outputFormatter = DateFormatter()
                outputFormatter.dateFormat = "dd.MM.yy"
                return outputFormatter.string(from: date)
            }
        }

        // If parsing fails, try manual extraction
        // Pattern: Try to extract "dd MMM yyyy" from anywhere in the string
        if let dateMatch = dateString.range(of: "\\d{1,2}\\s+[A-Za-z]{3}\\s+\\d{4}", options: .regularExpression) {
            let extractedDate = String(dateString[dateMatch])
            // Try to parse this extracted date
            formatter.dateFormat = "d MMM yyyy"
            if let date = formatter.date(from: extractedDate) {
                let outputFormatter = DateFormatter()
                outputFormatter.dateFormat = "dd.MM.yy"
                return outputFormatter.string(from: date)
            }
        }

        // Ultimate fallback: Just show the first part before timezone
        print("⚠️ Failed to parse date: '\(dateString)'")
        var cleaned = dateString.replacingOccurrences(of: "\\s*[+-]\\d{4}.*$", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+\\d{2}:\\d{2}:\\d{2}.*$", with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func syncIconColor() -> Color {
        if accountManager.loadingProgress.contains("Failed") {
            return .red
        } else if accountManager.isLoadingEmails {
            return .blue
        } else {
            return .secondary
        }
    }
    
    private func getSelectedFolderName() -> String {
        guard let selectedFolderID = selectedFolderID,
              let folder = accountManager.allFolders.first(where: { $0.id == selectedFolderID }) else {
            return ""
        }
        return folder.name
    }
    
    private func shouldDisableSend() -> Bool {
        guard case .compose = detailMode else {
            return true
        }
        
        guard let draft = composeDraft else {
            return true
        }
        
        return !draft.isValid || EmailSendingManager.shared.isSending
    }
    
    private func extractEmailAddress(_ from: String) -> String {
        // Extract email from "Name <email@domain.com>" format
        if let emailRange = from.range(of: "<(.+?)>", options: .regularExpression) {
            let email = String(from[emailRange]).replacingOccurrences(of: "[<>]", with: "", options: .regularExpression)
            return email
        }
        return from
    }
    
    @ViewBuilder
    private func emailDetailView(email: IMAPEmail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                            Text(formatSenderName(email.from))
                                .textSelection(.enabled)
                        }
                        
                        HStack {
                            Text("Date:")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text(formatDate(email.date))
                                .textSelection(.enabled)
                        }
                        
                        if !email.from.isEmpty && email.from != formatSenderName(email.from) {
                            HStack {
                                Text("Email:")
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                Text(extractEmailAddress(email.from))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    if let attributedBody = email.attributedBody {
                        Text(AttributedString(attributedBody))
                            .textSelection(.enabled)
                    } else {
                        Text(email.body ?? "Loading...")
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                
                Spacer()
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .navigationTitle("Email")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    lastViewedEmail = email
                    detailMode = .compose(replyTo: email)
                }) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }
        }
    }
    
    private func handleEmailSelection(_ emailID: UUID?) {
        guard let emailID = emailID,
              let email = accountManager.allEmails.first(where: { $0.id == emailID }) else {
            detailMode = .empty
            return
        }
        
        guard let selectedFolderID = selectedFolderID,
              let folder = accountManager.allFolders.first(where: { $0.id == selectedFolderID }) else {
            showEmailDetail(email)
            return
        }
        
        if folder.isDraftsFolder {
            openDraft(email, folder: folder)
        } else {
            showEmailDetail(email)
        }
    }
    
    private func showEmailDetail(_ email: IMAPEmail) {
        lastViewedEmail = email
        detailMode = .emailDetail(email)
        
        if !email.isRead {
            Task {
                await accountManager.markAsRead(uid: email.uid)
            }
        }
    }
    
    private func openDraft(_ email: IMAPEmail, folder: IMAPFolder) {
        Task {
            guard let client = accountManager.getClient(for: folder.accountId) else {
                print("❌ Draft open failed: No client for account \(folder.accountId)")
                return
            }
            
            await MainActor.run {
                accountManager.suppressMerge = true
            }
            
            defer {
                Task { @MainActor in
                    accountManager.suppressMerge = false
                }
            }
            
            await client.fetchDraftBody(uid: email.uid)
            
            let draft: EmailDraft? = await MainActor.run {
                guard let clientEmail = client.emails.first(where: { $0.uid == email.uid }),
                      let fetchedBody = clientEmail.body else {
                    print("❌ Draft body fetch failed for UID \(email.uid)")
                    return nil
                }
                
                if let index = accountManager.allEmails.firstIndex(where: { $0.uid == email.uid }) {
                    accountManager.allEmails[index].body = fetchedBody
                } else {
                    print("⚠️ Draft UID \(email.uid) not found in allEmails")
                    return nil
                }
                
                guard let updatedEmail = accountManager.allEmails.first(where: { $0.uid == email.uid }) else {
                    print("❌ Draft lost after update")
                    return nil
                }
                
                return accountManager.parseDraftFromEmail(updatedEmail, accountId: folder.accountId)
            }
            
            if let draft = draft {
                await MainActor.run {
                    detailMode = .compose(replyTo: nil)
                    composeDraft = draft
                }
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
