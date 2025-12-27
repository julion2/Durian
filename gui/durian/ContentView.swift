//
//  ContentView.swift
//  Durian
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import Combine

enum DetailViewMode: Equatable {
    case notmuchEmailDetail(emailId: String)
    case empty
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var accountManager = AccountManager.shared
    @StateObject private var keymapsManager = KeymapsManager.shared
    @StateObject private var keymapHandler = KeymapHandler.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var syncManager = SyncManager.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var selectedTagID: String? = "inbox"
    @State private var cursorEmailId: String? = nil       // Highlighted email (cursor position)
    @State private var markedEmails: Set<String> = []     // Marked emails (selection for batch ops)
    @State private var detailMode: DetailViewMode = .empty
    @State private var showSearchPopup: Bool = false
    @State private var visualModeAnchor: String? = nil    // Anchor for visual mode range selection

    var body: some View {
        ZStack {
            notmuchView
            
            if showSearchPopup {
                searchPopupOverlay
            }
        }
    }
    
    // MARK: - Search Popup Overlay
    
    @ViewBuilder
    private var searchPopupOverlay: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    showSearchPopup = false
                }
            
            // Centered popup
            SearchPopupView(
                isPresented: $showSearchPopup,
                selectedEmailId: Binding(
                    get: { markedEmails.first },
                    set: { newId in
                        if let id = newId {
                            markedEmails = [id]
                        }
                    }
                ),
                onEmailSelected: { emailId in
                    // Open email in detail view
                    detailMode = .notmuchEmailDetail(emailId: emailId)
                }
            )
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Notmuch View
    
    @ViewBuilder
    private var notmuchView: some View {
        NavigationSplitView {
            // Sidebar: Profile Header + Tags + Network Status
            VStack(spacing: 0) {
                // Profile Header - just the name, switch via menubar
                Text(profileManager.currentProfile?.name ?? "All")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                
                List(selection: $selectedTagID) {
                    Section("Tags") {
                        ForEach(accountManager.mailFolders) { folder in
                            Label(folder.displayName, systemImage: folder.icon)
                                .tag(folder.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                
                // Network Status - only show when offline or just reconnected
                if !networkMonitor.isConnected {
                    Text("Offline")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                } else if networkMonitor.showReconnectedBanner {
                    Text("Back online")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("")
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
                    EmailListView(
                        emails: accountManager.mailMessages,
                        cursorId: $cursorEmailId,
                        selection: $markedEmails,
                        onEmailAppear: { email in
                            // Prefetch body when email becomes visible
                            switch email.bodyState {
                            case .notLoaded, .failed:
                                Task {
                                    await accountManager.fetchNotmuchEmailBody(id: email.id)
                                }
                            case .loading, .loaded:
                                break // Already loading or loaded
                            }
                        },
                        onTogglePin: { emailId in
                            Task {
                                await accountManager.toggleNotmuchPin(id: emailId)
                            }
                        },
                        onToggleRead: { emailId in
                            Task {
                                await accountManager.toggleNotmuchRead(id: emailId)
                            }
                        },
                        onDelete: { emailId in
                            Task {
                                await accountManager.deleteNotmuchMessage(id: emailId)
                                await MainActor.run {
                                    // Clear selection after delete
                                    markedEmails = []
                                    detailMode = .empty
                                }
                            }
                        }
                    )
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
            .navigationTitle("Durian")
            .navigationSubtitle(accountManager.selectedFolder)
            .toolbar {
                // Mitte: Compose + Email Aktionen
                ToolbarItemGroup(placement: .principal) {
                    Button(action: { openNewCompose() }) {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Message (Cmd+N)")
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(ConfigManager.shared.getAccounts().isEmpty)
                    
                    Button(action: { replyToSelected() }) {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .help("Reply (R)")
                    .disabled(markedEmails.isEmpty || !selectedEmailHasBody)
                    
                    Button(action: { replyAllToSelected() }) {
                        Image(systemName: "arrowshape.turn.up.left.2")
                    }
                    .help("Reply All (Shift+R)")
                    .disabled(markedEmails.isEmpty || !selectedEmailHasBody)
                    
                    Button(action: { forwardSelected() }) {
                        Image(systemName: "arrowshape.turn.up.right")
                    }
                    .help("Forward (F)")
                    .disabled(markedEmails.isEmpty || !selectedEmailHasBody)
                    
                    Button(action: deleteSelectedEmails) {
                        Image(systemName: "trash")
                    }
                    .help("Delete")
                    .disabled(markedEmails.isEmpty)
                    
                    Button(action: togglePin) {
                        Image(systemName: selectedEmailIsPinned ? "pin.fill" : "pin")
                    }
                    .help(selectedEmailIsPinned ? "Unpin (S)" : "Pin (S)")
                    .disabled(markedEmails.isEmpty)
                    
                    Button(action: toggleRead) {
                        Image(systemName: selectedEmailIsRead ? "envelope.open" : "envelope.badge")
                    }
                    .help(selectedEmailIsRead ? "Mark Unread (U)" : "Mark Read (U)")
                    .disabled(markedEmails.isEmpty)
                }
                
                // Rechts: Search & Sync
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: { showSearchPopup = true }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("/", modifiers: .command)
                    .help("Search (Cmd+/)")
                    
                    Button(action: {
                        Task {
                            await syncManager.quickSync()
                            await accountManager.reloadNotmuch()
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(syncManager.syncState == .syncing ? 360 : 0))
                            .animation(
                                syncManager.syncState == .syncing
                                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: syncManager.syncState
                            )
                            .foregroundColor(syncManager.syncState.color)
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Sync (Cmd+R)")
                    .disabled(syncManager.isSyncing)
                }
            }
        } detail: {
            // Detail View - always show cursor email, with badge if multi-selected
            if let emailId = cursorEmailId,
               let email = accountManager.mailMessages.first(where: { $0.id == emailId }) {
                ZStack(alignment: .bottomTrailing) {
                    notmuchEmailDetailView(email: email)
                    
                    // Selection badge when multiple emails marked
                    if markedEmails.count > 1 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("\(markedEmails.count) selected")
                        }
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                        .padding(16)
                    }
                }
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
            // Register all keymap handlers
            registerKeymapHandlers()
        }
        .onChange(of: selectedTagID) { tagId in
            if let tagId = tagId {
                Task {
                    await accountManager.selectNotmuchTag(tagId)
                }
            }
        }
        .onChange(of: markedEmails) { newSelection in
            // When selection changes externally (e.g., click), sync cursor
            if newSelection.count == 1, let emailId = newSelection.first {
                cursorEmailId = emailId
                handleNotmuchEmailSelection(emailId)
            }
        }
        // Intercept Ctrl+d/u before the sidebar List captures them
        .onKeyPress { press in
            // Ctrl+d for page down
            if press.key == KeyEquivalent("d") && press.modifiers.contains(.control) {
                let pageSize = 10
                if let current = currentEmailIndex() {
                    navigateToEmail(at: current + pageSize)
                } else {
                    navigateToEmail(at: 0)
                }
                return .handled
            }
            // Ctrl+u for page up
            if press.key == KeyEquivalent("u") && press.modifiers.contains(.control) {
                let pageSize = 10
                if let current = currentEmailIndex() {
                    navigateToEmail(at: current - pageSize)
                } else {
                    navigateToEmail(at: sortedEmailIds.count - 1)
                }
                return .handled
            }
            return .ignored
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
                    // From + Date (rechts)
                    HStack {
                        Text("From:")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(email.from)
                            .textSelection(.enabled)
                        Spacer()
                        Text(email.date)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    
                    // Cc (nur wenn vorhanden)
                    if let cc = email.cc, !cc.isEmpty {
                        HStack {
                            Text("Cc:")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text(cc)
                                .textSelection(.enabled)
                        }
                    }
                    
                    // Tags (nur wenn vorhanden)
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
                    EmailWebView(
                                        html: html,
                                        theme: SettingsManager.shared.settings.theme,
                                        loadRemoteImages: SettingsManager.shared.settings.loadRemoteImages
                                    )
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
            // Auto-load body if not loaded or previously failed
            switch email.bodyState {
            case .notLoaded, .failed:
                Task {
                    await accountManager.fetchNotmuchEmailBody(id: email.id)
                }
            case .loading, .loaded:
                break // Already loading or loaded
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
        
        // Auto-load body if not loaded or previously failed
        if let email = accountManager.mailMessages.first(where: { $0.id == emailId }) {
            switch email.bodyState {
            case .notLoaded, .failed:
                Task {
                    await accountManager.fetchNotmuchEmailBody(id: emailId)
                }
            case .loading, .loaded:
                break // Already loading or loaded
            }
            
            // Mark as read
            if !email.isRead {
                Task {
                    await accountManager.markNotmuchAsRead(id: emailId)
                }
            }
        }
    }
    
    // MARK: - Toolbar Helpers
    
    private var selectedEmailIsPinned: Bool {
        guard let emailId = markedEmails.first,
              let email = accountManager.mailMessages.first(where: { $0.id == emailId }) else {
            return false
        }
        return email.isPinned
    }
    
    private var selectedEmailIsRead: Bool {
        guard let emailId = markedEmails.first,
              let email = accountManager.mailMessages.first(where: { $0.id == emailId }) else {
            return true
        }
        return email.isRead
    }
    
    private var selectedEmailHasBody: Bool {
        guard let emailId = markedEmails.first,
              let email = accountManager.mailMessages.first(where: { $0.id == emailId }) else {
            return false
        }
        if case .loaded = email.bodyState {
            return true
        }
        return false
    }
    
    private var selectedEmail: MailMessage? {
        guard let emailId = markedEmails.first else { return nil }
        return accountManager.mailMessages.first(where: { $0.id == emailId })
    }
    
    private func deleteSelectedEmails() {
        guard !markedEmails.isEmpty else { return }
        Task {
            await accountManager.deleteMessages(ids: markedEmails)
            await MainActor.run {
                markedEmails = []
                visualModeAnchor = nil
                detailMode = .empty
                keymapHandler.engine.exitVisualMode()
            }
        }
    }
    
    private func togglePin() {
        guard let emailId = markedEmails.first else { return }
        Task { await accountManager.toggleNotmuchPin(id: emailId) }
    }
    
    private func toggleRead() {
        guard !markedEmails.isEmpty else { return }
        Task {
            await accountManager.toggleReadForMessages(ids: markedEmails)
            await MainActor.run {
                // Exit visual mode after batch action
                if keymapHandler.engine.isVisualMode {
                    keymapHandler.engine.exitVisualMode()
                    visualModeAnchor = nil
                }
            }
        }
    }
    
    // MARK: - Compose
    
    private func openNewCompose() {
        guard !ConfigManager.shared.getAccounts().isEmpty else { return }
        let draftId = DraftService.shared.createDraft()
        openWindow(value: draftId)
    }
    
    // MARK: - Reply/Forward Actions
    
    /// Get default from-account based on current profile
    private var defaultFromAccount: String? {
        // Get first account from current profile
        if let profile = profileManager.currentProfile,
           let accountName = profile.accounts.first,
           accountName != "*" {
            // Find matching account by name
            return ConfigManager.shared.getAccounts()
                .first(where: { $0.name == accountName })?.email
        }
        // Fallback to first configured account
        return ConfigManager.shared.getAccounts().first?.email
    }
    
    private func replyToSelected() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState,
              let fromAccount = defaultFromAccount else { return }
        
        let replyDraft = EmailDraft.createReply(from: email, fromAccount: fromAccount)
        let draftId = DraftService.shared.createDraft(with: replyDraft)
        openWindow(value: draftId)
    }
    
    private func replyAllToSelected() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState,
              let fromAccount = defaultFromAccount else { return }
        
        let replyDraft = EmailDraft.createReplyAll(from: email, fromAccount: fromAccount)
        let draftId = DraftService.shared.createDraft(with: replyDraft)
        openWindow(value: draftId)
    }
    
    private func forwardSelected() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState,
              let fromAccount = defaultFromAccount else { return }
        
        let forwardDraft = EmailDraft.createForward(from: email, fromAccount: fromAccount)
        let draftId = DraftService.shared.createDraft(with: forwardDraft)
        openWindow(value: draftId)
    }
    
    // MARK: - Navigation Helpers
    
    /// Get sorted email IDs (by timestamp, newest first)
    private var sortedEmailIds: [String] {
        accountManager.mailMessages
            .sorted { $0.timestamp > $1.timestamp }
            .map { $0.id }
    }
    
    /// Get current email index in sorted list (based on cursor position)
    private func currentEmailIndex() -> Int? {
        guard let currentId = cursorEmailId else { return nil }
        return sortedEmailIds.firstIndex(of: currentId)
    }
    
    /// Navigate to email at specific index (clamped to valid range)
    /// Updates cursor position and handles visual mode selection
    private func navigateToEmail(at index: Int) {
        guard !sortedEmailIds.isEmpty else { return }
        let clampedIndex = max(0, min(index, sortedEmailIds.count - 1))
        let targetId = sortedEmailIds[clampedIndex]
        
        // Always update cursor position
        cursorEmailId = targetId
        
        switch keymapHandler.engine.visualModeType {
        case .none:
            // Normal navigation: selection follows cursor
            markedEmails = [targetId]
            
        case .line:
            // Line mode: selection = all emails from anchor to cursor
            if let anchor = visualModeAnchor,
               let anchorIndex = sortedEmailIds.firstIndex(of: anchor) {
                let start = min(anchorIndex, clampedIndex)
                let end = max(anchorIndex, clampedIndex)
                markedEmails = Set(sortedEmailIds[start...end])
            } else {
                // No anchor yet, just add cursor to selection
                markedEmails.insert(targetId)
            }
            
        case .toggle:
            // Toggle mode: selection stays unchanged, only cursor moves
            break
        }
    }
    
    /// Get range of email IDs between two indices
    private func emailsInRange(from: Int, to: Int) -> Set<String> {
        let start = min(from, to)
        let end = max(from, to)
        let clampedStart = max(0, start)
        let clampedEnd = min(sortedEmailIds.count - 1, end)
        guard clampedStart <= clampedEnd else { return [] }
        return Set(sortedEmailIds[clampedStart...clampedEnd])
    }
    
    /// Register all keymap handlers
    private func registerKeymapHandlers() {
        // Navigation: j/k with count support (5j, 3k)
        // In visual mode, extends selection from anchor to cursor
        keymapHandler.registerHandler(for: .nextEmail) { [self] count in
            await MainActor.run {
                if let current = currentEmailIndex() {
                    navigateToEmail(at: current + count)
                } else if !sortedEmailIds.isEmpty {
                    navigateToEmail(at: 0)
                }
            }
        }
        
        keymapHandler.registerHandler(for: .prevEmail) { [self] count in
            await MainActor.run {
                if let current = currentEmailIndex() {
                    navigateToEmail(at: current - count)
                } else if !sortedEmailIds.isEmpty {
                    navigateToEmail(at: sortedEmailIds.count - 1)
                }
            }
        }
        
        // First/Last: gg, G
        keymapHandler.registerSimpleHandler(for: .firstEmail) { [self] in
            await MainActor.run {
                navigateToEmail(at: 0)
            }
        }
        
        keymapHandler.registerSimpleHandler(for: .lastEmail) { [self] in
            await MainActor.run {
                navigateToEmail(at: sortedEmailIds.count - 1)
            }
        }
        
        // Page navigation: Ctrl+d, Ctrl+u (10 emails per page)
        let pageSize = 10
        keymapHandler.registerHandler(for: .pageDown) { [self] count in
            await MainActor.run {
                if let current = currentEmailIndex() {
                    navigateToEmail(at: current + (pageSize * count))
                } else {
                    navigateToEmail(at: 0)
                }
            }
        }
        
        keymapHandler.registerHandler(for: .pageUp) { [self] count in
            await MainActor.run {
                if let current = currentEmailIndex() {
                    navigateToEmail(at: current - (pageSize * count))
                } else {
                    navigateToEmail(at: sortedEmailIds.count - 1)
                }
            }
        }
        
        // Search: /
        keymapHandler.registerSimpleHandler(for: .search) { [self] in
            await MainActor.run {
                showSearchPopup = true
            }
        }
        
        // Compose: c
        keymapHandler.registerSimpleHandler(for: .compose) { [self] in
            await MainActor.run {
                openNewCompose()
            }
        }
        
        // Reply: r
        keymapHandler.registerSimpleHandler(for: .reply) { [self] in
            await MainActor.run {
                replyToSelected()
            }
        }
        
        // Reply All: R (Shift+r)
        keymapHandler.registerSimpleHandler(for: .replyAll) { [self] in
            await MainActor.run {
                replyAllToSelected()
            }
        }
        
        // Forward: f
        keymapHandler.registerSimpleHandler(for: .forward) { [self] in
            await MainActor.run {
                forwardSelected()
            }
        }
        
        // View control: q - close detail or search popup (NOT escape - that's for visual mode)
        keymapHandler.registerSimpleHandler(for: .closeDetail) { [self] in
            await MainActor.run {
                if showSearchPopup {
                    showSearchPopup = false
                } else {
                    detailMode = .empty
                }
            }
        }
        
        // Toggle Pin: s
        keymapHandler.registerSimpleHandler(for: .toggleStar) { [self] in
            await MainActor.run {
                guard let emailId = markedEmails.first else { return }
                Task {
                    await accountManager.toggleNotmuchPin(id: emailId)
                }
            }
        }
        
        // Toggle Read: u - now works with multi-selection
        keymapHandler.registerSimpleHandler(for: .toggleRead) { [self] in
            await MainActor.run {
                toggleRead()
            }
        }
        
        // Delete: dd - works with multi-selection
        keymapHandler.registerSimpleHandler(for: .deleteEmail) { [self] in
            await MainActor.run {
                deleteSelectedEmails()
            }
        }
        
        // ═══════════════════════════════════════════════════════════
        // VISUAL MODE HANDLERS
        // ═══════════════════════════════════════════════════════════
        
        // v - Enter LINE visual mode (range selection: anchor to cursor)
        keymapHandler.registerSimpleHandler(for: .enterVisualMode) { [self] in
            await MainActor.run {
                guard keymapHandler.engine.visualModeType == .none else { return }
                keymapHandler.engine.enterVisualMode(.line)
                // Set anchor to current cursor position
                visualModeAnchor = cursorEmailId
                print("VISUAL: Entered LINE mode, anchor: \(visualModeAnchor ?? "nil")")
            }
        }
        
        // V (Shift+v) - Enter TOGGLE visual mode (individual selection with Space)
        keymapHandler.registerSimpleHandler(for: .enterToggleMode) { [self] in
            await MainActor.run {
                guard keymapHandler.engine.visualModeType == .none else { return }
                keymapHandler.engine.enterVisualMode(.toggle)
                // Mark current email initially
                if let currentId = cursorEmailId {
                    markedEmails = [currentId]
                }
                print("VISUAL: Entered TOGGLE mode, initial mark: \(cursorEmailId ?? "nil")")
            }
        }
        
        // Space - Toggle selection (only in TOGGLE mode)
        keymapHandler.registerSimpleHandler(for: .toggleSelection) { [self] in
            await MainActor.run {
                // Only works in Toggle mode
                guard keymapHandler.engine.visualModeType == .toggle else { return }
                guard let currentId = cursorEmailId else { return }
                
                // Toggle mark on current cursor position
                if markedEmails.contains(currentId) {
                    // Unmark (but keep at least one)
                    if markedEmails.count > 1 {
                        markedEmails.remove(currentId)
                    }
                } else {
                    // Mark
                    markedEmails.insert(currentId)
                }
                
                // Move cursor to next email (mutt-style)
                if let current = currentEmailIndex(), current < sortedEmailIds.count - 1 {
                    cursorEmailId = sortedEmailIds[current + 1]
                    // Selection stays unchanged (toggle mode)
                }
            }
        }
        
        // Escape - Exit visual mode (clears selection, keeps cursor)
        keymapHandler.registerSimpleHandler(for: .exitVisualMode) { [self] in
            await MainActor.run {
                if keymapHandler.engine.visualModeType != .none {
                    keymapHandler.engine.exitVisualMode()
                    // Clear all marks, keep only cursor
                    if let cursor = cursorEmailId {
                        markedEmails = [cursor]
                    }
                    visualModeAnchor = nil
                    print("VISUAL: Exited visual mode")
                } else if showSearchPopup {
                    showSearchPopup = false
                } else {
                    detailMode = .empty
                }
            }
        }
        
        print("KEYMAPS: All handlers registered")
    }
    
}
