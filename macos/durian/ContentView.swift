//
//  ContentView.swift
//  Durian
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import Combine

// MARK: - Popup Navigation Notifications

extension Notification.Name {
    static let popupSelectNext = Notification.Name("popupSelectNext")
    static let popupSelectPrev = Notification.Name("popupSelectPrev")
    static let threadScrollDown = Notification.Name("threadScrollDown")
    static let threadScrollUp = Notification.Name("threadScrollUp")
    static let threadScrollToTop = Notification.Name("threadScrollToTop")
    static let threadScrollToBottom = Notification.Name("threadScrollToBottom")
}

enum DetailViewMode: Equatable {
    case emailDetail(emailId: String)
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
    @StateObject private var bannerManager = BannerManager.shared
    @State private var selectedTagID: String? = "inbox"
    @State private var cursorEmailId: String? = nil       // Highlighted email (cursor position)
    @State private var markedEmails: Set<String> = []     // Marked emails (selection for batch ops)
    @State private var detailMode: DetailViewMode = .empty
    @State private var showSearchPopup: Bool = false
    @State private var showTagPicker: Bool = false
    @State private var allTags: [String] = []
    @State private var visualModeAnchor: String? = nil    // Anchor for visual mode range selection
    @State private var isSearchMode = false
    @State private var bodyFetchTask: Task<Void, Never>?
    @State private var searchResults: [MailMessage] = []
    @State private var lastSearchQuery = ""
    @State private var focusedMessageIndex: Int = 0
    @State private var isThreadFocused: Bool = false

    var body: some View {
        ZStack {
            emailView
            
            if showSearchPopup {
                searchPopupOverlay
            }

            if showTagPicker {
                tagPickerOverlay
            }

            // Banner Overlay (bottom-right toast)
            if let banner = bannerManager.currentBanner {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        BannerView(banner: banner) {
                            bannerManager.dismiss()
                        }
                        .frame(maxWidth: 400)
                    }
                }
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: bannerManager.currentBanner?.id)
                .zIndex(100)
            }
        }
        .onChange(of: accountManager.pendingNotificationThreadId) { _, threadId in
            guard let threadId = threadId else { return }
            accountManager.pendingNotificationThreadId = nil
            cursorEmailId = threadId
            markedEmails = [threadId]
            handleEmailSelection(threadId)
        }
        .tint(profileManager.resolvedAccentColor)
    }

    // MARK: - Search Popup Overlay
    
    @ViewBuilder
    private var searchPopupOverlay: some View {
        ZStack {
            // Subtle dimming to normalize glass effect background
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    showSearchPopup = false
                }

            // Top-aligned popup
            VStack {
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
                    initialQuery: isSearchMode ? lastSearchQuery : "",
                    onResultsActivated: { query, results, selectedId in
                        isSearchMode = true
                        searchResults = results
                        lastSearchQuery = query
                        cursorEmailId = selectedId
                        markedEmails = [selectedId]
                        handleEmailSelection(selectedId)
                    }
                )
                .padding(.top, 80)

                Spacer()
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Tag Picker Overlay

    @ViewBuilder
    private var tagPickerOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    showTagPicker = false
                }

            VStack {
                TagPickerView(
                    isPresented: $showTagPicker,
                    currentTags: currentEmailTags,
                    allTags: allTags,
                    onToggleTag: { tag, isAdding in
                        let ids = markedEmails
                        guard !ids.isEmpty else { return }
                        // Optimistically add new tag to allTags so the UI updates instantly
                        if isAdding && !allTags.contains(tag) {
                            allTags.append(tag)
                            allTags.sort()
                        }
                        // Optimistically update search results so tag pills refresh immediately
                        if isSearchMode {
                            for emailId in ids {
                                if let idx = searchResults.firstIndex(where: { $0.id == emailId }) {
                                    var currentTags = (searchResults[idx].tags ?? "")
                                        .split(separator: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                    if isAdding {
                                        if !currentTags.contains(tag) { currentTags.append(tag) }
                                    } else {
                                        currentTags.removeAll { $0 == tag }
                                    }
                                    searchResults[idx].tags = currentTags.joined(separator: ",")
                                    let tagSet = Set(currentTags)
                                    searchResults[idx].isRead = !tagSet.contains("unread")
                                    searchResults[idx].isPinned = tagSet.contains("flagged")
                                    searchResults[idx].hasAttachment = tagSet.contains("attachment")
                                }
                            }
                        }
                        Task {
                            for id in ids {
                                if isAdding {
                                    await accountManager.modifyTagsWithoutSync(id: id, add: [tag], remove: [])
                                } else {
                                    await accountManager.modifyTagsWithoutSync(id: id, add: [], remove: [tag])
                                }
                            }
                            await accountManager.syncAndRefresh()
                            allTags = await accountManager.fetchAllTags()
                        }
                    }
                )
                .padding(.top, 80)

                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    /// Tags on the currently focused email
    private var currentEmailTags: [String] {
        guard let emailId = cursorEmailId,
              let email = accountManager.mailMessages.first(where: { $0.id == emailId })
                          ?? searchResults.first(where: { $0.id == emailId }),
              let tagsString = email.tags else { return [] }
        return tagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Email View
    
    @ViewBuilder
    private var emailView: some View {
        NavigationSplitView {
            SidebarView(
                selectedTagID: $selectedTagID,
                accountManager: accountManager,
                profileManager: profileManager
            )
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
                
                if !displayEmails.isEmpty {
                    EmailListView(
                        emails: displayEmails,
                        emailListGeneration: accountManager.emailListGeneration,
                        cursorId: $cursorEmailId,
                        selection: $markedEmails,
                        onEmailAppear: { email in
                            // Only prefetch body for currently selected email (avoids request storm on scroll)
                            guard email.id == cursorEmailId else { return }
                            switch email.bodyState {
                            case .notLoaded, .failed:
                                Task {
                                    await accountManager.fetchEmailBody(id: email.id)
                                }
                            case .loading, .loaded:
                                break
                            }
                        },
                        onTogglePin: { emailId in
                            Task {
                                await accountManager.togglePin(id: emailId)
                            }
                        },
                        onToggleRead: { emailId in
                            Task {
                                await accountManager.toggleRead(id: emailId)
                            }
                        },
                        onDelete: { emailId in
                            Task {
                                await accountManager.deleteMessage(id: emailId)
                                await MainActor.run {
                                    // Clear selection after delete
                                    markedEmails = []
                                    detailMode = .empty
                                }
                            }
                        }
                    )
                } else if !isSearchMode && accountManager.isLoadingEmails {
                    VStack {
                        ProgressView()
                        Text(accountManager.loadingProgress)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                } else {
                    Text(isSearchMode ? "No results" : "No emails")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                }
            }
            .navigationTitle("Durian")
            .navigationSubtitle(isSearchMode ? "Search: \(lastSearchQuery)" : accountManager.selectedFolder)
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
                            await accountManager.reloadEmail()
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
               let email = accountManager.mailMessages.first(where: { $0.id == emailId })
                            ?? searchResults.first(where: { $0.id == emailId }) {
                ZStack(alignment: .bottomTrailing) {
                    EmailDetailView(
                        email: email,
                        onReply: replyToSelected,
                        onReplyAll: replyAllToSelected,
                        onForward: forwardSelected,
                        onLoadBody: {
                            Task {
                                await accountManager.fetchEmailBody(id: email.id)
                            }
                        },
                        onEditDraft: email.isDraft ? editSelectedDraft : nil,
                        currentFolder: accountManager.selectedFolder,
                        onAddTag: { tag in
                            Task { await accountManager.addTag(id: email.id, tag: tag) }
                        },
                        onRemoveTag: { tag in
                            Task { await accountManager.removeTag(id: email.id, tag: tag) }
                        },
                        focusedMessageIndex: $focusedMessageIndex,
                        isThreadFocused: isThreadFocused
                    )
                    .id(email.id)  // Force new View instance on email change to reset @State
                    
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
                        .background(profileManager.resolvedAccentColor)
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
        .onChange(of: selectedTagID) { _, tagId in
            if let tagId = tagId {
                isSearchMode = false
                searchResults = []
                lastSearchQuery = ""
                Task {
                    await accountManager.selectTag(tagId)
                }
            }
        }
        .onChange(of: markedEmails) { _, newSelection in
            // When selection changes externally (e.g., click), sync cursor
            if newSelection.count == 1, let emailId = newSelection.first {
                cursorEmailId = emailId
                handleEmailSelection(emailId)
            }
        }
        .onChange(of: showSearchPopup) { _, isShowing in
            keymapHandler.engine.setContext(isShowing ? .search : .list)
        }
        .onChange(of: showTagPicker) { _, isShowing in
            keymapHandler.engine.setContext(isShowing ? .tagPicker : .list)
        }
        .onChange(of: accountManager.mailMessages) { _, newMessages in
            // Sync updated emails (e.g. body loaded) into search results
            // Preserve original date (search returns relative dates, thread fetch returns RFC dates)
            guard isSearchMode else { return }
            for i in searchResults.indices {
                if let updated = newMessages.first(where: { $0.id == searchResults[i].id }) {
                    let originalDate = searchResults[i].date
                    searchResults[i] = updated
                    searchResults[i].date = originalDate
                }
            }
        }
        // Intercept Escape/Ctrl+d/u before the sidebar List captures them
        .onKeyPress { press in
            // Escape to exit search mode (sequence engine doesn't dispatch Escape to handlers)
            if press.key == .escape && isSearchMode && !showSearchPopup && !showTagPicker {
                isSearchMode = false
                searchResults = []
                lastSearchQuery = ""
                return .handled
            }
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
    
    /// Number of thread messages for the currently focused email
    private var currentThreadMessageCount: Int {
        guard let emailId = cursorEmailId,
              let email = accountManager.mailMessages.first(where: { $0.id == emailId })
                          ?? searchResults.first(where: { $0.id == emailId }),
              let messages = email.threadMessages else { return 1 }
        return max(messages.count, 1)
    }

    // MARK: - Display Emails (Search Mode vs Normal)

    private var displayEmails: [MailMessage] {
        isSearchMode ? searchResults : accountManager.mailMessages
    }

    // MARK: - Helper Methods
    
    private func handleEmailSelection(_ emailId: String) {
        detailMode = .emailDetail(emailId: emailId)

        // Debounce body fetch — cancel previous request during rapid j/k navigation
        bodyFetchTask?.cancel()
        bodyFetchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            if let email = displayEmails.first(where: { $0.id == emailId }) {
                switch email.bodyState {
                case .notLoaded, .failed:
                    await accountManager.fetchEmailBody(id: emailId)
                case .loading, .loaded:
                    break
                }
                if !email.isRead {
                    await accountManager.markAsRead(id: emailId)
                }
            } else {
                await accountManager.fetchEmailBody(id: emailId)
            }
        }
    }
    
    // MARK: - Toolbar Helpers
    
    private var selectedEmailIsPinned: Bool {
        guard let emailId = markedEmails.first,
              let email = displayEmails.first(where: { $0.id == emailId }) else {
            return false
        }
        return email.isPinned
    }

    private var selectedEmailIsRead: Bool {
        guard let emailId = markedEmails.first,
              let email = displayEmails.first(where: { $0.id == emailId }) else {
            return true
        }
        return email.isRead
    }

    private var selectedEmailHasBody: Bool {
        guard let emailId = markedEmails.first,
              let email = displayEmails.first(where: { $0.id == emailId }) else {
            return false
        }
        if case .loaded = email.bodyState {
            return true
        }
        return false
    }

    private var selectedEmail: MailMessage? {
        guard let emailId = markedEmails.first else { return nil }
        return displayEmails.first(where: { $0.id == emailId })
    }
    
    private func deleteSelectedEmails() {
        guard !markedEmails.isEmpty else { return }
        let ids = markedEmails
        let next = nextEmailId(after: ids)
        accountManager.removeLocally(ids: ids)
        visualModeAnchor = nil
        keymapHandler.engine.exitVisualMode()
        advanceCursor(to: next)
        Task { @MainActor in
            await accountManager.deleteMessages(ids: ids)
            await accountManager.refreshFolderCounts()
        }
    }

    private func togglePin() {
        guard let emailId = markedEmails.first else { return }
        if keymapHandler.engine.isVisualMode {
            keymapHandler.engine.exitVisualMode()
            visualModeAnchor = nil
            markedEmails = [emailId]
        }
        Task { await accountManager.togglePin(id: emailId) }
    }

    private func toggleRead() {
        guard !markedEmails.isEmpty else { return }
        Task {
            await accountManager.toggleReadForMessages(ids: markedEmails)
            await accountManager.refreshFolderCounts()
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
        let draftId = DraftService.shared.createDraft(from: defaultFromAccount)
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
                .first(where: { $0.name.caseInsensitiveCompare(accountName) == .orderedSame })?.email
        }
        // Fallback to first configured account
        return ConfigManager.shared.getAccounts().first?.email
    }
    
    private func replyToSelected() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState,
              let fromAccount = defaultFromAccount else { return }

        Task {
            let original = await fetchOriginalReplyBody(for: email, fromAccount: fromAccount)
            let replyDraft = EmailDraft.createReply(from: email, fromAccount: fromAccount, originalBody: original)
            let draftId = DraftService.shared.createDraft(with: replyDraft)
            openWindow(value: draftId)
        }
    }

    private func replyAllToSelected() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState,
              let fromAccount = defaultFromAccount else { return }

        Task {
            let original = await fetchOriginalReplyBody(for: email, fromAccount: fromAccount)
            let replyDraft = EmailDraft.createReplyAll(from: email, fromAccount: fromAccount, originalBody: original)
            let draftId = DraftService.shared.createDraft(with: replyDraft)
            openWindow(value: draftId)
        }
    }

    /// Fetch unstripped body for the reply target message (lazy-loaded on reply action)
    private func fetchOriginalReplyBody(for email: MailMessage, fromAccount: String) async -> (body: String, html: String?)? {
        guard let targetId = EmailDraft.replyTargetMessageId(for: email, fromAccount: fromAccount),
              let backend = AccountManager.shared.emailBackend else { return nil }
        guard let response = await backend.fetchOriginalBody(messageId: targetId) else { return nil }
        return (body: response.body, html: response.html)
    }
    
    private func forwardSelected() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState,
              let fromAccount = defaultFromAccount else { return }

        Task {
            var forwardDraft = EmailDraft.createForward(from: email, fromAccount: fromAccount)

            // Copy attachments from the original message(s) into the forward draft.
            // Requires the email backend to fetch attachment bytes via IMAP.
            if let backend = AccountManager.shared.emailBackend {
                let result = await EmailDraft.collectForwardAttachments(from: email, backend: backend)
                forwardDraft.attachments = result.attachments

                if !result.skipped.isEmpty {
                    let msg = "Some attachments were skipped: " + result.skipped.joined(separator: ", ")
                    BannerManager.shared.showWarning(title: "Forward Attachments", message: msg)
                }
            }

            let draftId = DraftService.shared.createDraft(with: forwardDraft)
            openWindow(value: draftId)
        }
    }

    private func editSelectedDraft() {
        guard let email = selectedEmail,
              case .loaded = email.bodyState else { return }
        let draft = EmailDraft.createFromDraft(message: email)
        let draftId = DraftService.shared.createDraft(with: draft)
        openWindow(value: draftId)
    }
    
    // MARK: - Navigation Helpers
    
    /// Advance cursor and selection to the given email, or clear if nil.
    private func advanceCursor(to emailId: String?) {
        if let emailId = emailId {
            cursorEmailId = emailId
            markedEmails = [emailId]
            detailMode = .emailDetail(emailId: emailId)
        } else {
            cursorEmailId = nil
            markedEmails = []
            detailMode = .empty
        }
    }

    /// Compute the next email to select after removing the given IDs from the list.
    /// Picks the email just below the lowest removed index, or the one above if at the end.
    private func nextEmailId(after removedIds: Set<String>) -> String? {
        let ids = sortedEmailIds
        guard let firstRemovedIndex = ids.firstIndex(where: { removedIds.contains($0) }) else { return nil }
        // Try the email just after the last contiguous removed item
        var nextIndex = firstRemovedIndex
        while nextIndex < ids.count && removedIds.contains(ids[nextIndex]) {
            nextIndex += 1
        }
        if nextIndex < ids.count { return ids[nextIndex] }
        // All removed items were at the end — pick the one above
        let prevIndex = firstRemovedIndex - 1
        return prevIndex >= 0 ? ids[prevIndex] : nil
    }

    /// Get sorted email IDs matching visual order (pinned first, then by timestamp)
    private var sortedEmailIds: [String] {
        let pinned = displayEmails.filter { $0.isPinned }.sorted { $0.timestamp > $1.timestamp }
        let unpinned = displayEmails.filter { !$0.isPinned }.sorted { $0.timestamp > $1.timestamp }
        return (pinned + unpinned).map { $0.id }
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
        
        // Tag Picker: t
        keymapHandler.registerSimpleHandler(for: .tagPicker) { [self] in
            await MainActor.run {
                guard !markedEmails.isEmpty else { return }
                showTagPicker = true
                Task { allTags = await accountManager.fetchAllTags() }
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
        
        // View control: q - close detail, search popup, or tag picker (NOT escape - that's for visual mode)
        keymapHandler.registerSimpleHandler(for: .closeDetail) { [self] in
            await MainActor.run {
                if showSearchPopup {
                    showSearchPopup = false
                } else if showTagPicker {
                    showTagPicker = false
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
                    await accountManager.togglePin(id: emailId)
                }
            }
        }
        
        // Toggle Read: u - now works with multi-selection
        keymapHandler.registerSimpleHandler(for: .toggleRead) { [self] in
            await MainActor.run {
                toggleRead()
            }
        }
        
        // Archive: a - add archive tag and remove inbox tag (works with multi-selection)
        keymapHandler.registerSimpleHandler(for: .archiveEmail) { [self] in
            let ids = await MainActor.run { () -> Set<String> in
                let ids = markedEmails
                guard !ids.isEmpty else { return [] }
                let next = nextEmailId(after: ids)
                visualModeAnchor = nil
                keymapHandler.engine.exitVisualMode()
                accountManager.removeLocally(ids: ids)
                advanceCursor(to: next)
                return ids
            }
            for id in ids {
                await accountManager.modifyTagsWithoutSync(id: id, add: ["archive"], remove: ["inbox"])
            }
            await accountManager.syncAndRefresh()
        }

        // Delete: dd - works with multi-selection
        keymapHandler.registerSimpleHandler(for: .deleteEmail) { [self] in
            let ids = await MainActor.run { () -> Set<String> in
                guard !markedEmails.isEmpty else { return [] }
                let ids = markedEmails
                let next = nextEmailId(after: ids)
                accountManager.removeLocally(ids: ids)
                visualModeAnchor = nil
                keymapHandler.engine.exitVisualMode()
                advanceCursor(to: next)
                return ids
            }
            await accountManager.deleteMessagesWithoutSync(ids: ids)
            await accountManager.syncAndRefresh()
        }
        
        // ═══════════════════════════════════════════════════════════
        // FOLDER NAVIGATION HANDLERS
        // ═══════════════════════════════════════════════════════════

        // gi - Go to Inbox
        keymapHandler.registerSimpleHandler(for: .goInbox) { [self] in
            await MainActor.run { selectedTagID = "inbox" }
        }

        // gs - Go to Sent
        keymapHandler.registerSimpleHandler(for: .goSent) { [self] in
            await MainActor.run { selectedTagID = "sent" }
        }

        // gd - Go to Drafts
        keymapHandler.registerSimpleHandler(for: .goDrafts) { [self] in
            await MainActor.run { selectedTagID = "drafts" }
        }

        // ga - Go to Archive
        keymapHandler.registerSimpleHandler(for: .goArchive) { [self] in
            await MainActor.run { selectedTagID = "archive" }
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
                Log.debug("VISUAL", "Entered LINE mode, anchor: \(visualModeAnchor ?? "nil")")
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
                Log.debug("VISUAL", "Entered TOGGLE mode, initial mark: \(cursorEmailId ?? "nil")")
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
                // Always clean up visual mode state (engine may have already exited)
                if visualModeAnchor != nil || keymapHandler.engine.visualModeType != .none {
                    keymapHandler.engine.exitVisualMode()
                    if let cursor = cursorEmailId {
                        markedEmails = [cursor]
                    }
                    visualModeAnchor = nil
                    Log.debug("VISUAL", "Exited visual mode")
                } else if showTagPicker {
                    showTagPicker = false
                } else if showSearchPopup {
                    showSearchPopup = false
                } else if isSearchMode {
                    isSearchMode = false
                    searchResults = []
                    lastSearchQuery = ""
                } else {
                    detailMode = .empty
                }
            }
        }

        // ═══════════════════════════════════════════════════════════
        // THREAD CONTEXT HANDLERS
        // ═══════════════════════════════════════════════════════════

        // l - Enter thread view
        keymapHandler.registerSimpleHandler(for: .enterThread) { [self] in
            await MainActor.run {
                guard cursorEmailId != nil else { return }
                focusedMessageIndex = 0
                isThreadFocused = true
                keymapHandler.engine.setContext(.thread)
            }
        }

        // j/k in thread - scroll (supports count: 3j = scroll 3x)
        keymapHandler.registerHandler(for: .scrollDown, context: .thread) { count in
            for _ in 0..<count {
                NotificationCenter.default.post(name: .threadScrollDown, object: nil)
            }
        }

        keymapHandler.registerHandler(for: .scrollUp, context: .thread) { count in
            for _ in 0..<count {
                NotificationCenter.default.post(name: .threadScrollUp, object: nil)
            }
        }

        // Ctrl+d/u in thread - half-page scroll
        keymapHandler.registerHandler(for: .pageDown, context: .thread) { count in
            let steps = 5 * count
            for _ in 0..<steps {
                NotificationCenter.default.post(name: .threadScrollDown, object: nil)
            }
        }

        keymapHandler.registerHandler(for: .pageUp, context: .thread) { count in
            let steps = 5 * count
            for _ in 0..<steps {
                NotificationCenter.default.post(name: .threadScrollUp, object: nil)
            }
        }

        // n/N in thread - navigate messages (supports count: 3n = jump 3)
        keymapHandler.registerHandler(for: .nextMessage, context: .thread) { [self] count in
            await MainActor.run {
                let max = currentThreadMessageCount - 1
                focusedMessageIndex = min(focusedMessageIndex + count, max)
            }
        }

        keymapHandler.registerHandler(for: .prevMessage, context: .thread) { [self] count in
            await MainActor.run {
                guard focusedMessageIndex > 0 else { return }
                focusedMessageIndex = max(focusedMessageIndex - count, 0)
            }
        }

        // gg/G in thread - first/last message
        keymapHandler.registerSimpleHandler(for: .firstEmail, context: .thread) { [self] in
            await MainActor.run {
                guard focusedMessageIndex > 0 else { return }
                focusedMessageIndex = 0
            }
        }

        keymapHandler.registerSimpleHandler(for: .lastEmail, context: .thread) { [self] in
            await MainActor.run {
                let last = max(currentThreadMessageCount - 1, 0)
                if focusedMessageIndex == last {
                    NotificationCenter.default.post(name: .threadScrollToBottom, object: nil)
                }
                focusedMessageIndex = last
            }
        }

        // h/Escape in thread - back to list
        keymapHandler.registerSimpleHandler(for: .closeDetail, context: .thread) { [self] in
            await MainActor.run {
                isThreadFocused = false
                keymapHandler.engine.setContext(.list)
            }
        }

        // r in thread - reply
        keymapHandler.registerSimpleHandler(for: .reply, context: .thread) { [self] in
            await MainActor.run {
                replyToSelected()
            }
        }

        // ═══════════════════════════════════════════════════════════
        // POPUP CONTEXT HANDLERS (search, tag picker)
        // ═══════════════════════════════════════════════════════════

        for ctx in [KeymapContext.search, KeymapContext.tagPicker] {
            keymapHandler.registerSimpleHandler(for: .selectNext, context: ctx) {
                NotificationCenter.default.post(name: .popupSelectNext, object: nil)
            }
            keymapHandler.registerSimpleHandler(for: .selectPrev, context: ctx) {
                NotificationCenter.default.post(name: .popupSelectPrev, object: nil)
            }
            keymapHandler.registerSimpleHandler(for: .closePopup, context: ctx) { [self] in
                await MainActor.run {
                    showSearchPopup = false
                    showTagPicker = false
                }
            }
        }

        Log.debug("KEYMAPS", "All handlers registered")
    }
    
}
