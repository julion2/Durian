//
//  SyncManager.swift
//  Durian
//
//  Manages email synchronization via durian CLI
//

import Foundation
import Combine
import SwiftUI

// MARK: - Sync State

enum SyncState: Equatable {
    case idle
    case syncing           // Rotating icon - sync in progress
    case success           // Green - sync completed
    case failed(String)    // Red - sync failed
    
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .syncing: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }
    
    var shouldNotify: Bool {
        switch self {
        case .failed: return true
        default: return false
        }
    }
    
    var statusText: String {
        switch self {
        case .idle: return ""
        case .syncing: return "Syncing..."
        case .success: return "Synced"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

// MARK: - Sync Manager

@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    // MARK: - Published State
    @Published var syncState: SyncState = .idle
    @Published var lastSyncTime: Date?
    
    // MARK: - Sync Lock (prevents multiple concurrent syncs)
    private var syncLock = false
    
    /// True if a sync is currently in progress
    var isSyncing: Bool { syncLock }
    
    // MARK: - Paths
    private let durianPath: String
    
    // MARK: - Timers
    private var quickSyncTimer: Timer?
    private var fullSyncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Initial path resolution, will be refreshed in runDurianSync if needed
        durianPath = FileManager.default.resolveDurianPath() ?? ""
    }
    
    // MARK: - Setup (call on app start)
    
    func setup() {
        print("SYNC: Setting up SyncManager...")
        print("SYNC: Config - guiAutoSync=\(SettingsManager.shared.guiAutoSync), autoFetchInterval=\(SettingsManager.shared.autoFetchInterval)s, fullSyncInterval=\(SettingsManager.shared.fullSyncInterval)s")
        
        // Start timers based on config (if online)
        if NetworkMonitor.shared.isConnected {
            startQuickSyncTimer()
            startFullSyncTimer()
        } else {
            print("SYNC: Offline at startup, timers not started")
        }
        
        // React to network changes
        NetworkMonitor.shared.$isConnected
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                Task { @MainActor in
                    if isConnected {
                        print("SYNC: Back online, restarting timers and syncing")
                        BannerManager.shared.showSuccess(title: "Back Online", message: "Connection restored. Syncing now...")
                        self?.restartTimers()
                        await self?.quickSync()
                    } else {
                        print("SYNC: Went offline, stopping timers")
                        BannerManager.shared.showWarning(title: "Offline", message: "No network connection. Sync paused.")
                        self?.stopTimers()
                    }
                }
            }
            .store(in: &cancellables)
        
        print("SYNC: Setup complete")
    }
    
    // MARK: - Timer Management
    
    func startQuickSyncTimer() {
        guard SettingsManager.shared.guiAutoSync else {
            print("SYNC: GUI auto-sync disabled, not starting quick sync timer")
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            print("SYNC: Offline, not starting quick sync timer")
            return
        }
        
        let interval = SettingsManager.shared.autoFetchInterval
        print("SYNC: Starting quick sync timer with interval \(interval)s")
        
        quickSyncTimer?.invalidate()
        quickSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard !self.syncLock else {
                    print("SYNC: Quick sync timer skipped - sync already in progress")
                    return
                }
                guard NetworkMonitor.shared.isConnected else {
                    print("SYNC: Quick sync timer skipped - offline")
                    return
                }
                await self.quickSync()
            }
        }
    }
    
    func startFullSyncTimer() {
        guard SettingsManager.shared.guiAutoSync else {
            print("SYNC: GUI auto-sync disabled, not starting full sync timer")
            return
        }
        guard NetworkMonitor.shared.isConnected else {
            print("SYNC: Offline, not starting full sync timer")
            return
        }
        
        let interval = SettingsManager.shared.fullSyncInterval
        print("SYNC: Starting full sync timer with interval \(interval)s (\(interval/3600)h)")
        
        fullSyncTimer?.invalidate()
        fullSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard !self.syncLock else {
                    print("SYNC: Full sync timer skipped - sync already in progress")
                    return
                }
                guard NetworkMonitor.shared.isConnected else {
                    print("SYNC: Full sync timer skipped - offline")
                    return
                }
                await self.fullSync()
            }
        }
    }
    
    func stopTimers() {
        print("SYNC: Stopping all sync timers")
        quickSyncTimer?.invalidate()
        quickSyncTimer = nil
        fullSyncTimer?.invalidate()
        fullSyncTimer = nil
    }
    
    func restartTimers() {
        print("SYNC: Restarting timers with new settings")
        stopTimers()
        if SettingsManager.shared.guiAutoSync {
            startQuickSyncTimer()
            startFullSyncTimer()
        }
    }
    
    // MARK: - Quick Sync (Cmd+R)
    
    /// Quick sync - syncs current profile's INBOX only
    @discardableResult
    func quickSync() async -> Bool {
        guard !syncLock else {
            print("SYNC: Quick sync - already syncing, skipping")
            return false
        }
        
        syncLock = true
        defer { syncLock = false }
        
        // Get current profile for targeted sync
        guard let currentProfile = ProfileManager.shared.currentProfile else {
            print("SYNC: Quick sync - no current profile, skipping")
            return false
        }

        // Use account name for single-account profiles, sync all for multi/wildcard.
        // Profile accounts are maildir path names — only pass to sync if there's
        // a matching CLI account (by name, case-insensitive). Otherwise sync all.
        let knownAccountNames = Set(ConfigManager.shared.getAccounts().map { $0.name.lowercased() })
        let accountName: String?
        if !currentProfile.isAll && currentProfile.accounts.count == 1,
           let profileAccount = currentProfile.accounts.first,
           knownAccountNames.contains(profileAccount.lowercased()) {
            accountName = profileAccount
        } else {
            accountName = nil
        }
        print("SYNC: Quick sync starting for \(accountName ?? "all") INBOX")
        syncState = .syncing

        let success = await runDurianSync(account: accountName, mailbox: "INBOX", timeout: 60)
        
        if success {
            print("SYNC: Quick sync completed successfully")
            syncState = .success
            lastSyncTime = Date()
            
            // Reload email list to show new messages
            await reloadEmailList()
            
            // After 3 seconds, go back to idle
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if case .success = self.syncState {
                    self.syncState = .idle
                }
            }
        } else {
            print("SYNC: Quick sync failed")
            syncState = .failed("sync error")
            if !NetworkMonitor.shared.isConnected {
                BannerManager.shared.showWarning(title: "Offline", message: "Sync skipped — no network connection.")
            } else {
                BannerManager.shared.showWarning(title: "Sync Failed", message: "Could not sync emails. Will retry automatically.")
            }
        }
        
        return success
    }
    
    // MARK: - Full Sync (Cmd+Shift+R or timer)
    
    /// Full sync - syncs all accounts with longer timeout
    @discardableResult
    func fullSync() async -> Bool {
        guard !syncLock else {
            print("SYNC: Full sync - already syncing, skipping")
            return false
        }
        
        syncLock = true
        defer { syncLock = false }
        
        print("SYNC: Full sync starting (all accounts)")
        // No UI feedback for full sync (runs in background)
        
        let success = await runDurianSync(account: nil, mailbox: nil, timeout: 300)
        
        if success {
            print("SYNC: Full sync completed successfully")
            lastSyncTime = Date()
            
            // Reload email list to show new messages
            await reloadEmailList()
        } else {
            print("SYNC: Full sync failed")
            if !NetworkMonitor.shared.isConnected {
                BannerManager.shared.showWarning(title: "Offline", message: "Background sync skipped — no network connection.")
            } else {
                BannerManager.shared.showWarning(title: "Full Sync Failed", message: "Background sync encountered an error.")
            }
        }
        
        return success
    }
    
    // MARK: - Core Sync Logic
    
    /// Run durian sync with optional account and mailbox targeting
    /// - Parameters:
    ///   - account: Specific account name to sync (nil = all accounts)
    ///   - mailbox: Specific mailbox to sync (nil = all mailboxes)
    ///   - timeout: Command timeout in seconds
    private func runDurianSync(account: String?, mailbox: String?, timeout: TimeInterval) async -> Bool {
        guard let resolvedPath = FileManager.default.resolveDurianPath() else {
            print("SYNC: durian CLI not found in ~/.local/bin or /usr/local/bin")
            BannerManager.shared.showCritical(title: "Durian CLI Not Found", message: "Install durian to sync emails.")
            return false
        }
        
        // Build command args: sync [account] [mailbox]
        var args = ["sync"]
        if let account = account {
            args.append(account)
            if let mailbox = mailbox {
                args.append(mailbox)
            }
        }
        
        print("SYNC: Running \(resolvedPath) \(args.joined(separator: " ")) (timeout: \(Int(timeout))s)")
        let result = await runCommand(resolvedPath, args: args, timeout: timeout)
        
        if result.success {
            print("SYNC: durian sync completed successfully")
            if let output = result.output, !output.isEmpty {
                print("SYNC: Output: \(output.prefix(500))")
            }
        } else {
            print("SYNC: durian sync failed")
            if let error = result.error, !error.isEmpty {
                print("SYNC: Error: \(error)")
            }
        }
        
        return result.success
    }
    
    /// Reload the email list after sync to show new messages
    private func reloadEmailList() async {
        // Get the current backend and refresh the email list
        if let backend = AccountManager.shared.notmuchBackend {
            print("SYNC: Reloading email list")
            await backend.reload()
        }
    }
    
    // MARK: - Command Execution
    
    private struct CommandResult {
        let success: Bool
        let output: String?
        let error: String?
    }
    
    /// Run a command directly with timeout
    private func runCommand(_ path: String, args: [String], timeout: TimeInterval) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                
                // Set up environment with Homebrew paths
                var env = ProcessInfo.processInfo.environment
                let homebrewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
                if let existingPath = env["PATH"] {
                    env["PATH"] = "\(homebrewPaths):\(existingPath)"
                } else {
                    env["PATH"] = "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = env
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                // Set up timeout
                var timeoutWorkItem: DispatchWorkItem?
                var didTimeout = false
                
                timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        print("SYNC: Command timed out after \(timeout)s, terminating process")
                        didTimeout = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem!)
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    // Cancel timeout timer if process completed
                    timeoutWorkItem?.cancel()
                    
                    if didTimeout {
                        continuation.resume(returning: CommandResult(
                            success: false,
                            output: nil,
                            error: "Command timed out after \(Int(timeout)) seconds"
                        ))
                        return
                    }
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8)
                    let error = String(data: errorData, encoding: .utf8)
                    
                    let success = process.terminationStatus == 0
                    continuation.resume(returning: CommandResult(success: success, output: output, error: error))
                } catch {
                    timeoutWorkItem?.cancel()
                    continuation.resume(returning: CommandResult(success: false, output: nil, error: error.localizedDescription))
                }
            }
        }
    }
}
