//
//  AccountManager.swift
//  Durian
//
//  Manages notmuch backend for email access
//

import Foundation
import Combine
import AppKit

@MainActor
class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    // MARK: - Notmuch Properties
    @Published var notmuchBackend: NotmuchBackend?
    @Published var mailMessages: [MailMessage] = []    // Messages
    @Published var selectedFolder: String = "inbox"
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""

    /// Set by notification click handler; ContentView observes and navigates to this thread
    @Published var pendingNotificationThreadId: String?
    
    private var cancellables = Set<AnyCancellable>()
    
    /// Folders from current profile config
    var mailFolders: [MailFolder] {
        let profile = ProfileManager.shared.currentProfile
        let folders = profile?.folders ?? ProfileManager.defaultFolders
        
        return folders.map { folder in
            MailFolder(name: folder.name.lowercased(), displayName: folder.name, icon: folder.icon)
        }
    }
    
    private init() {
        setupNotmuchBackend()
    }
    
    // MARK: - Notmuch Setup
    
    private func setupNotmuchBackend() {
        print("NOTMUCH AccountManager: Setting up notmuch backend")
        notmuchBackend = NotmuchBackend()
        
        // Subscribe to backend changes
        notmuchBackend?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            self?.syncFromNotmuch()
        }.store(in: &cancellables)
    }
    
    private func syncFromNotmuch() {
        guard let backend = notmuchBackend else { return }
        // mailFolders is now a computed property from ProfileManager
        mailMessages = backend.emails
        isLoadingEmails = backend.isLoadingEmails
        loadingProgress = backend.loadingProgress
    }
    
    // MARK: - Connection
    
    func connectToAllAccounts() async {
        print("NOTMUCH AccountManager: Connecting to notmuch...")
        guard let backend = notmuchBackend else {
            print("NOTMUCH ERROR: Backend not initialized")
            return
        }
        await backend.connect()
        syncFromNotmuch()
    }
    
    // MARK: - Folder/Tag Selection
    
    func selectNotmuchTag(_ tag: String) async {
        guard let backend = notmuchBackend else { return }
        selectedFolder = tag
        mailMessages.removeAll()
        await backend.selectFolder(tag)
        syncFromNotmuch()
    }
    
    // MARK: - Profile Switching
    
    /// Switch to a different profile and reload the current tag/folder
    func switchProfile(_ profile: Profile) async {
        // Update ProfileManager
        ProfileManager.shared.currentProfile = profile
        print("NOTMUCH AccountManager: Switched to profile '\(profile.name)'")
        
        // Reload current folder with new profile filter
        await selectNotmuchTag(selectedFolder)
    }
    
    // MARK: - Email Operations
    
    func fetchNotmuchEmailBody(id: String) async {
        guard let backend = notmuchBackend else { return }
        await backend.fetchEmailBody(id: id)
        syncFromNotmuch()
    }
    
    func markNotmuchAsRead(id: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            try await backend.markAsRead(id: id)
        } catch {
            print("NOTMUCH: Failed to mark as read: \(error)")
        }
        syncFromNotmuch()
    }

    func toggleNotmuchReadStatus(id: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            if let email = mailMessages.first(where: { $0.id == id }) {
                if email.isRead {
                    try await backend.markAsUnread(id: id)
                } else {
                    try await backend.markAsRead(id: id)
                }
            }
        } catch {
            print("NOTMUCH: Failed to toggle read status: \(error)")
            BannerManager.shared.showWarning(title: "Read Status Failed", message: "Could not update read status.")
        }
        syncFromNotmuch()
    }

    func deleteNotmuchMessage(id: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            try await backend.deleteMessage(id: id)
        } catch {
            print("NOTMUCH: Failed to delete message: \(error)")
            BannerManager.shared.showWarning(title: "Delete Failed", message: "Could not delete message.")
        }
        syncFromNotmuch()
    }

    func addTag(id: String, tag: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            try await backend.addTag(id: id, tag: tag)
        } catch {
            print("NOTMUCH: Failed to add tag: \(error)")
            BannerManager.shared.showWarning(title: "Tag Failed", message: "Could not add tag '\(tag)'.")
        }
        syncFromNotmuch()
    }

    func removeTag(id: String, tag: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            try await backend.removeTag(id: id, tag: tag)
        } catch {
            print("NOTMUCH: Failed to remove tag: \(error)")
            BannerManager.shared.showWarning(title: "Tag Failed", message: "Could not remove tag '\(tag)'.")
        }
        syncFromNotmuch()
    }

    func fetchAllTags() async -> [String] {
        guard let backend = notmuchBackend else { return [] }
        return await backend.fetchAllTags()
    }

    func toggleNotmuchPin(id: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            try await backend.togglePin(id: id)
        } catch {
            print("NOTMUCH: Failed to toggle pin: \(error)")
            BannerManager.shared.showWarning(title: "Pin Failed", message: "Could not toggle pin.")
        }
        syncFromNotmuch()
    }

    func toggleNotmuchRead(id: String) async {
        guard let backend = notmuchBackend else { return }
        do {
            try await backend.toggleRead(id: id)
        } catch {
            print("NOTMUCH: Failed to toggle read: \(error)")
            BannerManager.shared.showWarning(title: "Read Status Failed", message: "Could not update read status.")
        }
        syncFromNotmuch()
    }

    // MARK: - Batch Operations (Multi-Selection)

    func deleteMessages(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        var failCount = 0
        for id in ids {
            do { try await backend.deleteMessage(id: id) }
            catch { failCount += 1; print("NOTMUCH: Failed to delete \(id): \(error)") }
        }
        if failCount > 0 {
            BannerManager.shared.showWarning(title: "Delete Failed", message: "Could not delete \(failCount) message(s).")
        }
        syncFromNotmuch()
    }

    func toggleReadForMessages(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        var failCount = 0
        for id in ids {
            do { try await backend.toggleRead(id: id) }
            catch { failCount += 1; print("NOTMUCH: Failed to toggle read \(id): \(error)") }
        }
        if failCount > 0 {
            BannerManager.shared.showWarning(title: "Read Status Failed", message: "Could not update \(failCount) message(s).")
        }
        syncFromNotmuch()
    }

    func markMessagesAsRead(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        var failCount = 0
        for id in ids {
            do { try await backend.markAsRead(id: id) }
            catch { failCount += 1; print("NOTMUCH: Failed to mark read \(id): \(error)") }
        }
        if failCount > 0 {
            BannerManager.shared.showWarning(title: "Read Status Failed", message: "Could not update \(failCount) message(s).")
        }
        syncFromNotmuch()
    }

    func markMessagesAsUnread(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        var failCount = 0
        for id in ids {
            do { try await backend.markAsUnread(id: id) }
            catch { failCount += 1; print("NOTMUCH: Failed to mark unread \(id): \(error)") }
        }
        if failCount > 0 {
            BannerManager.shared.showWarning(title: "Read Status Failed", message: "Could not update \(failCount) message(s).")
        }
        syncFromNotmuch()
    }
    
    // MARK: - Notification Navigation

    /// Select an email by thread ID (called when user clicks a notification)
    func selectEmail(threadId: String) {
        guard mailMessages.contains(where: { $0.id == threadId }) else {
            print("NOTMUCH: Notification thread \(threadId) not found in current list")
            return
        }
        pendingNotificationThreadId = threadId
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Full Reload
    
    func reloadNotmuch() async {
        guard let backend = notmuchBackend else { return }
        
        isLoadingEmails = true
        
        // Quick sync via SyncManager (configured channels + notmuch new)
        let success = await SyncManager.shared.quickSync()
        
        if !success {
            loadingProgress = SyncManager.shared.syncState.statusText
            isLoadingEmails = false
            return
        }
        
        // Reload from notmuch
        loadingProgress = "Loading..."
        print("NOTMUCH Reload: Reloading from notmuch")
        await backend.reload()
        syncFromNotmuch()
    }
}
