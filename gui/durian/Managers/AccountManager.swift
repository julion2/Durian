//
//  AccountManager.swift
//  Durian
//
//  Manages notmuch backend for email access
//

import Foundation
import Combine

@MainActor
class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    // MARK: - Notmuch Properties
    @Published var notmuchBackend: NotmuchBackend?
    @Published var mailMessages: [MailMessage] = []    // Messages
    @Published var selectedFolder: String = "inbox"
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""
    
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
        await backend.markAsRead(id: id)
        syncFromNotmuch()
    }
    
    func toggleNotmuchReadStatus(id: String) async {
        guard let backend = notmuchBackend else { return }
        if let email = mailMessages.first(where: { $0.id == id }) {
            if email.isRead {
                await backend.markAsUnread(id: id)
            } else {
                await backend.markAsRead(id: id)
            }
        }
        syncFromNotmuch()
    }
    
    func deleteNotmuchMessage(id: String) async {
        guard let backend = notmuchBackend else { return }
        try? await backend.deleteMessage(id: id)
        syncFromNotmuch()
    }
    
    func toggleNotmuchPin(id: String) async {
        guard let backend = notmuchBackend else { return }
        await backend.togglePin(id: id)
        syncFromNotmuch()
    }
    
    func toggleNotmuchRead(id: String) async {
        guard let backend = notmuchBackend else { return }
        await backend.toggleRead(id: id)
        syncFromNotmuch()
    }
    
    // MARK: - Batch Operations (Multi-Selection)
    
    func deleteMessages(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        for id in ids {
            try? await backend.deleteMessage(id: id)
        }
        syncFromNotmuch()
    }
    
    func toggleReadForMessages(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        for id in ids {
            await backend.toggleRead(id: id)
        }
        syncFromNotmuch()
    }
    
    func markMessagesAsRead(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        for id in ids {
            await backend.markAsRead(id: id)
        }
        syncFromNotmuch()
    }
    
    func markMessagesAsUnread(ids: Set<String>) async {
        guard let backend = notmuchBackend else { return }
        for id in ids {
            await backend.markAsUnread(id: id)
        }
        syncFromNotmuch()
    }
    
    // MARK: - Full Reload (mbsync via launchd + notmuch new)
    
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
