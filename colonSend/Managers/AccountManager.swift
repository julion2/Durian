//
//  AccountManager.swift
//  colonSend
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
    
    // MARK: - Full Reload (mbsync + notmuch new)
    
    func reloadNotmuch() async {
        guard let backend = notmuchBackend else { return }
        
        // Set PATH for Homebrew binaries
        var environment = ProcessInfo.processInfo.environment
        let homebrewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        if let existingPath = environment["PATH"] {
            environment["PATH"] = "\(homebrewPaths):\(existingPath)"
        } else {
            environment["PATH"] = "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        
        isLoadingEmails = true
        
        // 1. Sync from server via mbsync (60s timeout)
        loadingProgress = "Syncing from server..."
        print("NOTMUCH Reload: Running mbsync -a")
        
        let mbsyncSuccess = await runProcess(
            path: "/opt/homebrew/bin/mbsync",
            arguments: ["-a"],
            environment: environment,
            timeout: 60
        )
        
        if !mbsyncSuccess {
            loadingProgress = "Sync failed - try again"
            print("NOTMUCH Reload: mbsync failed or timed out")
            // Still continue to reload local data
        }
        
        // 2. Index new mail via notmuch new (30s timeout)
        loadingProgress = "Indexing new mail..."
        print("NOTMUCH Reload: Running notmuch new")
        
        let notmuchSuccess = await runProcess(
            path: "/opt/homebrew/bin/notmuch",
            arguments: ["new"],
            environment: environment,
            timeout: 30
        )
        
        if !notmuchSuccess {
            loadingProgress = "Indexing failed"
            print("NOTMUCH Reload: notmuch new failed or timed out")
            isLoadingEmails = false
            return
        }
        
        // 3. Reload from notmuch
        loadingProgress = "Loading..."
        print("NOTMUCH Reload: Reloading from notmuch")
        await backend.reload()
        syncFromNotmuch()
    }
    
    /// Run a process with timeout, returns true if successful
    private func runProcess(path: String, arguments: [String], environment: [String: String], timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = environment
                
                do {
                    try process.run()
                } catch {
                    print("NOTMUCH Reload: Failed to start \(path): \(error)")
                    continuation.resume(returning: false)
                    return
                }
                
                // Wait with timeout
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                
                if process.isRunning {
                    print("NOTMUCH Reload: \(path) timed out after \(timeout)s, terminating")
                    process.terminate()
                    continuation.resume(returning: false)
                } else {
                    let success = process.terminationStatus == 0
                    print("NOTMUCH Reload: \(path) finished with status \(process.terminationStatus)")
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
