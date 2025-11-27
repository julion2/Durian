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
    case emailDetail(emailUID: UInt32, accountId: String)
    case compose(replyTo: IMAPEmail?, forward: IMAPEmail?)
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
    @State private var draftLoadingTask: Task<Void, Never>?

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
                            
                            HStack(spacing: 4) {
                                Text(email.subject)
                                    .font(.callout)
                                    .fontWeight(email.isRead ? .regular : .semibold)
                                
                                if !email.incomingAttachments.isEmpty {
                                    Image(systemName: "paperclip")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
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
                        detailMode = .compose(replyTo: nil, forward: nil)
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
            case .emailDetail(let emailUID, let accountId):
                if let email = accountManager.allEmails.first(where: { $0.uid == emailUID }) {
                    emailDetailView(email: email, accountId: accountId)
                        // FIX: Force view refresh when email's hash changes (includes bodyState)
                        .id(email.hashValue)
                } else {
                    VStack {
                        Text("Email not found")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
            case .compose(let replyTo, let forward):
                EmailComposeView(
                    accounts: accountManager.accounts,
                    replyTo: replyTo,
                    forward: forward,
                    existingDraft: composeDraft,
                    triggerSend: $triggerSend,
                    currentDraft: $composeDraft,
                    onDismiss: {
                        if let lastEmail = lastViewedEmail {
                            detailMode = .emailDetail(emailUID: lastEmail.uid, accountId: lastViewedEmail?.from ?? "")
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
    private func emailDetailView(email: IMAPEmail, accountId: String) -> some View {
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
                
                if !email.incomingAttachments.isEmpty {
                    if let client = accountManager.getClient(for: accountId) {
                        IncomingAttachmentListView(
                            attachments: email.incomingAttachments,
                            emailUID: email.uid,
                            client: client
                        )
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    // Use bodyState for more reliable state management
                    if let attributedBody = email.bodyState.attributedBody {
                        Text(AttributedString(attributedBody))
                            .textSelection(.enabled)
                    } else {
                        Text(email.bodyState.displayBody)
                            .font(.body)
                            .textSelection(.enabled)
                            .foregroundColor(email.bodyState == .loading ? .secondary : .primary)
                    }
                }
                .onAppear {
                    // Trigger body loading if not yet loaded
                    if case .notLoaded = email.bodyState {
                        Task {
                            if let client = accountManager.getClient(for: accountId) {
                                print("📧 UI: Email body not loaded, triggering fetch for UID \(email.uid)")
                                await client.fetchEmailBody(uid: email.uid)
                            }
                        }
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
                    detailMode = .compose(replyTo: email, forward: nil)
                }) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }
            
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    lastViewedEmail = email
                    detailMode = .compose(replyTo: nil, forward: email)
                }) {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
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
        // Use accountManager.selectedAccount to get the current account
        let accountId = accountManager.selectedAccount ?? ""
        detailMode = .emailDetail(emailUID: email.uid, accountId: accountId)
        
        if !email.isRead {
            Task {
                await accountManager.markAsRead(uid: email.uid)
            }
        }
    }
    
    private func openDraft(_ email: IMAPEmail, folder: IMAPFolder) {
        draftLoadingTask?.cancel()
        
        let targetUID = email.uid
        let targetSubject = email.subject
        
        print("DRAFT_LOAD: Starting load for UID=\(targetUID) Subject=\(targetSubject)")
        
        draftLoadingTask = Task { @MainActor in
            guard let client = accountManager.getClient(for: folder.accountId) else {
                print("❌ Draft open failed: No client for account \(folder.accountId)")
                return
            }
            
            accountManager.suppressMerge = true
            
            defer {
                accountManager.suppressMerge = false
            }
            
            await client.fetchDraftBody(uid: email.uid)
            
            guard !Task.isCancelled else {
                print("DRAFT_LOAD: Task cancelled for UID=\(targetUID)")
                return
            }
            
            guard let clientEmail = client.emails.first(where: { $0.uid == targetUID }) else {
                print("❌ Draft email not found for UID=\(targetUID)")
                return
            }
            
            let fetchedBody = clientEmail.rawBody ?? clientEmail.body
            
            guard let fetchedBody = fetchedBody else {
                print("❌ Draft body fetch failed for UID=\(targetUID)")
                return
            }
            
            print("DRAFT_LOAD: Fetched body length=\(fetchedBody.count) (rawBody=\(clientEmail.rawBody != nil))")
            
            var emailCopy = email
            emailCopy.body = fetchedBody
            emailCopy.rawBody = fetchedBody
            emailCopy.attachments = clientEmail.attachments
            
            let draft = accountManager.parseDraftFromEmail(emailCopy, accountId: folder.accountId)
            
            guard !Task.isCancelled else {
                print("DRAFT_LOAD: Task cancelled before showing draft UID=\(targetUID)")
                return
            }
            
            guard let draft = draft else {
                print("❌ Draft parsing failed for UID=\(targetUID)")
                return
            }
            
            print("DRAFT_LOAD: Successfully loaded draft UID=\(targetUID) attachments=\(draft.attachments.count)")
            
            detailMode = .compose(replyTo: nil, forward: nil)
            composeDraft = draft
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
        name = "Ethereal Test"
        email = "test@ethereal.email"

        [accounts.imap]
        host = "imap.ethereal.email"
        port = 143
        ssl = false

        [accounts.smtp]
        host = "smtp.ethereal.email"
        port = 587
        ssl = false

        [accounts.auth]
        username = "test"
        password_keychain = "ethereal-test"

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
        guard var currentConfig = self.config else { return }
        
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
