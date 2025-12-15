//
//  SyncManager.swift
//  colonSend
//
//  Manages email synchronization via mbsync + notmuch
//  Uses launchd to avoid fork() crashes in macOS apps
//

import Foundation
import Combine
import SwiftUI
import UserNotifications

// MARK: - Sync State

enum SyncState: Equatable {
    case idle
    case syncing           // Rotating icon - sync in progress
    case success           // 🟢 Green - all accounts synced
    case partial(Int)      // 🟠 Orange - some accounts failed (exit code)
    case failed(String)    // 🔴 Red - complete failure
    
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .syncing: return .secondary  // No color during animation
        case .success: return .green
        case .partial: return .orange
        case .failed: return .red
        }
    }
    
    var shouldNotify: Bool {
        switch self {
        case .partial, .failed: return true
        default: return false
        }
    }
    
    var statusText: String {
        switch self {
        case .idle: return ""
        case .syncing: return "Syncing..."
        case .success: return "Synced"
        case .partial(let code): return "Partial sync (exit \(code))"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
    
    /// Check if two states are the same "type" for notification deduplication
    var notificationKey: String {
        switch self {
        case .idle: return "idle"
        case .syncing: return "syncing"
        case .success: return "success"
        case .partial: return "partial"
        case .failed: return "failed"
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
    
    // MARK: - Notification Deduplication
    private var lastNotifiedStateKey: String? = nil
    
    // MARK: - Paths
    private let scriptDir: URL
    private let scriptPath: URL
    private let plistPath: URL
    private let completionFile = "/tmp/colonSend-sync-complete"
    private let launchdLabel = "com.colonSend.mbsync"
    
    // MARK: - Timers
    private var quickSyncTimer: Timer?
    private var fullSyncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Full Sync Lock (separate from quick sync)
    private var isFullSyncing = false
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        scriptDir = home.appendingPathComponent(".local/bin")
        scriptPath = scriptDir.appendingPathComponent("colonSend-sync.sh")
        plistPath = home.appendingPathComponent("Library/LaunchAgents/com.colonSend.mbsync.plist")
    }
    
    // MARK: - Setup (call on app start)
    
    func setup() {
        print("SYNC: Setting up SyncManager...")
        
        // Ensure script and launchd agent exist
        ensureScriptExists()
        ensureLaunchdAgentExists()
        
        // Start timers based on config
        startQuickSyncTimer()
        startFullSyncTimer()
        
        // Listen for settings changes to update timers
        SettingsManager.shared.$settings
            .dropFirst()
            .sink { [weak self] settings in
                self?.restartTimers()
            }
            .store(in: &cancellables)
        
        print("SYNC: Setup complete")
    }
    
    // MARK: - Timer Management
    
    func startQuickSyncTimer() {
        let settings = SettingsManager.shared.settings
        guard settings.autoFetchEnabled else {
            print("SYNC: Auto-fetch disabled, not starting quick sync timer")
            return
        }
        
        let interval = settings.autoFetchInterval
        print("SYNC: Starting quick sync timer with interval \(interval)s")
        
        quickSyncTimer?.invalidate()
        quickSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Skip if sync already in progress
            guard !self.syncLock && !self.isFullSyncing else {
                print("SYNC: Quick sync timer skipped - sync already in progress")
                return
            }
            
            Task { @MainActor in
                await self.quickSync()
            }
        }
    }
    
    func startFullSyncTimer() {
        let settings = SettingsManager.shared.settings
        guard settings.autoFetchEnabled else {
            print("SYNC: Auto-fetch disabled, not starting full sync timer")
            return
        }
        
        let interval = settings.fullSyncInterval
        print("SYNC: Starting full sync timer with interval \(interval)s (\(interval/3600)h)")
        
        fullSyncTimer?.invalidate()
        fullSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Skip if sync already in progress
            guard !self.syncLock && !self.isFullSyncing else {
                print("SYNC: Full sync timer skipped - sync already in progress")
                return
            }
            
            Task { @MainActor in
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
        if SettingsManager.shared.settings.autoFetchEnabled {
            startQuickSyncTimer()
            startFullSyncTimer()
        }
    }
    
    // MARK: - Quick Sync (configured channels, 60s timeout, UI feedback)
    
    /// Quick sync - syncs only configured channels (Cmd+R)
    func quickSync() async -> Bool {
        // Use syncLock to prevent concurrent syncs
        guard !syncLock && !isFullSyncing else {
            print("SYNC: Quick sync - already syncing, skipping")
            return false
        }
        
        syncLock = true
        defer { syncLock = false }
        
        let channels = SettingsManager.shared.settings.mbsyncChannels
        let channelsStr = channels.isEmpty ? "-a" : channels.joined(separator: " ")
        print("SYNC: Quick sync starting - channels: \(channelsStr)")
        
        syncState = .syncing  // Rotating icon
        
        // Run sync with channels
        let success = await runMbsync(channels: channels, timeout: 60, isQuickSync: true)
        
        if success {
            print("SYNC: Quick sync completed successfully")
        } else {
            print("SYNC: Quick sync finished with issues")
        }
        
        return success
    }
    
    // MARK: - Full Sync (all channels, 360s timeout, background, only fail notification)
    
    /// Full sync - syncs all channels (Cmd+Shift+R or timer every 2h)
    func fullSync() async -> Bool {
        // Use separate lock for full sync
        guard !syncLock && !isFullSyncing else {
            print("SYNC: Full sync - already syncing, skipping")
            return false
        }
        
        isFullSyncing = true
        defer { isFullSyncing = false }
        
        print("SYNC: Full sync starting - mbsync -a")
        print("SYNC: Full sync - timeout: 360s")
        
        // No UI feedback for full sync (runs in background)
        // Only notify on complete failure
        
        // Run sync with all channels (empty = -a)
        let success = await runMbsync(channels: [], timeout: 360, isQuickSync: false)
        
        if success {
            print("SYNC: Full sync completed successfully")
        } else {
            print("SYNC: Full sync finished with issues")
        }
        
        return success
    }
    
    // MARK: - Core Sync Logic
    
    /// Run mbsync with specified channels via launchd (for keychain access)
    /// - Parameters:
    ///   - channels: Array of channel names (empty = mbsync -a)
    ///   - timeout: Timeout in seconds
    ///   - isQuickSync: If true, shows UI feedback and all notifications. If false, only notifies on failure.
    private func runMbsync(channels: [String], timeout: TimeInterval, isQuickSync: Bool) async -> Bool {
        let channelsFile = "/tmp/colonSend-sync-channels"
        
        // 1. Write channels to file (empty string for full sync = -a)
        let channelContent = channels.joined(separator: " ")
        do {
            try channelContent.write(toFile: channelsFile, atomically: true, encoding: .utf8)
            print("SYNC: Wrote channels to file: '\(channelContent.isEmpty ? "-a (full)" : channelContent)'")
        } catch {
            print("SYNC: Failed to write channels file: \(error)")
            if isQuickSync {
                updateState(.failed("setup error"), notify: true, title: "Sync Failed", body: "Could not prepare sync")
            } else {
                sendNotification(title: "Full Sync Failed", body: "Could not prepare sync")
            }
            return false
        }
        
        // 2. Remove old completion file
        try? FileManager.default.removeItem(atPath: completionFile)
        
        // 3. Trigger launchd (runs outside sandbox with keychain access!)
        print("SYNC: Triggering launchd agent: \(launchdLabel)")
        let startResult = await runShellCommand("launchctl start \(launchdLabel)")
        
        if !startResult.success {
            print("SYNC: Failed to start launchd agent: \(startResult.error ?? "unknown")")
            // Cleanup channels file
            try? FileManager.default.removeItem(atPath: channelsFile)
            if isQuickSync {
                updateState(.failed("launchd error"), notify: true, title: "Sync Failed", body: "Could not start sync agent")
            } else {
                sendNotification(title: "Full Sync Failed", body: "Could not start sync agent")
            }
            return false
        }
        
        // 4. Wait for completion with timeout
        print("SYNC: Waiting for completion (timeout: \(Int(timeout))s)")
        let completed = await waitForCompletion(timeout: timeout)
        
        if !completed {
            // Timeout - try to stop the job
            print("SYNC: Timeout reached after \(Int(timeout))s, stopping launchd agent")
            let _ = await runShellCommand("launchctl stop \(launchdLabel)")
            // Cleanup channels file (script might not have run)
            try? FileManager.default.removeItem(atPath: channelsFile)
            
            if isQuickSync {
                updateState(.failed("sync timed out"), notify: true, title: "Sync Timed Out", body: "mbsync did not complete within \(Int(timeout))s")
            } else {
                sendNotification(title: "Full Sync Timed Out", body: "mbsync did not complete within \(Int(timeout))s")
            }
            return false
        }
        
        // 5. Check exit code from completion file
        var isPartialSync = false
        if let exitCodeStr = try? String(contentsOfFile: completionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let exitCode = Int(exitCodeStr) {
            if exitCode != 0 {
                print("SYNC: mbsync exited with code \(exitCode) - partial sync may have occurred")
                isPartialSync = true
                if isQuickSync {
                    updateState(.partial(exitCode), notify: true, title: "Sync Warning", body: "Some email accounts failed to sync")
                }
                // Full sync: don't notify on partial (only on complete failure)
            } else {
                print("SYNC: mbsync completed successfully")
            }
        }
        
        // 6. Run notmuch new (always, even after partial sync)
        print("SYNC: Running notmuch new")
        let notmuchResult = await runShellCommand("notmuch new", timeout: 30)
        
        if !notmuchResult.success {
            print("SYNC: notmuch new failed: \(notmuchResult.error ?? "unknown")")
            if isQuickSync {
                updateState(.failed("indexing failed"), notify: true, title: "Sync Failed", body: "Email indexing failed")
            } else {
                sendNotification(title: "Full Sync Failed", body: "Email indexing failed")
            }
            return false
        }
        
        // 7. Final state
        lastSyncTime = Date()
        
        if isQuickSync {
            if isPartialSync {
                // Keep orange state - already set above
                print("SYNC: Quick sync - partial completion")
            } else {
                syncState = .success
                print("SYNC: Quick sync - success")
                
                // Reset notification state on success (so next error will notify again)
                lastNotifiedStateKey = nil
                
                // After 3 seconds, go back to idle
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if case .success = self.syncState {
                        self.syncState = .idle
                    }
                }
            }
        }
        
        return true
    }
    
    /// Update state and optionally send notification (with deduplication)
    private func updateState(_ newState: SyncState, notify: Bool, title: String, body: String) {
        syncState = newState
        
        // Only notify if this is a new state type (avoid spam for repeated partial syncs)
        if notify && newState.shouldNotify {
            let stateKey = newState.notificationKey
            if lastNotifiedStateKey != stateKey {
                sendNotification(title: title, body: body)
                lastNotifiedStateKey = stateKey
            } else {
                print("SYNC: Skipping duplicate notification for state '\(stateKey)'")
            }
        }
    }
    
    // MARK: - Notifications
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("SYNC: Failed to send notification: \(error)")
            }
        }
    }
    
    /// Wait for completion file to appear
    private func waitForCompletion(timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        let pollInterval: UInt64 = 500_000_000 // 500ms in nanoseconds
        
        while Date().timeIntervalSince(startTime) < timeout {
            if FileManager.default.fileExists(atPath: completionFile) {
                return true
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        
        return false
    }
    
    // MARK: - Script & Launchd Setup
    
    private func ensureScriptExists() {
        // Create directory if needed
        if !FileManager.default.fileExists(atPath: scriptDir.path) {
            do {
                try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
                print("SYNC: Created \(scriptDir.path)")
            } catch {
                print("SYNC: Failed to create script directory: \(error)")
                return
            }
        }
        
        // Create/update script - reads channels from file (for launchd compatibility)
        let scriptContent = """
        #!/bin/bash
        # colonSend mail sync script
        # Auto-generated - do not edit
        #
        # Reads channels from /tmp/colonSend-sync-channels
        # If file is empty or missing, runs mbsync -a (full sync)
        
        CHANNELS_FILE="/tmp/colonSend-sync-channels"
        COMPLETION_FILE="/tmp/colonSend-sync-complete"
        
        # Remove old completion file
        rm -f "$COMPLETION_FILE"
        
        # Read channels from file, or use -a if empty/missing
        if [ -f "$CHANNELS_FILE" ] && [ -s "$CHANNELS_FILE" ]; then
            CHANNELS=$(cat "$CHANNELS_FILE")
            echo "Running: mbsync $CHANNELS"
            /opt/homebrew/bin/mbsync $CHANNELS
        else
            echo "Running: mbsync -a"
            /opt/homebrew/bin/mbsync -a
        fi
        EXIT_CODE=$?
        
        # Cleanup channels file
        rm -f "$CHANNELS_FILE"
        
        # Write exit code to completion file
        echo $EXIT_CODE > "$COMPLETION_FILE"
        
        exit $EXIT_CODE
        """
        
        do {
            try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
            
            // Make executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            print("SYNC: Created/updated sync script at \(scriptPath.path)")
        } catch {
            print("SYNC: Failed to create sync script: \(error)")
        }
    }
    
    private func ensureLaunchdAgentExists() {
        // Create LaunchAgents directory if needed
        let launchAgentsDir = plistPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: launchAgentsDir.path) {
            do {
                try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
                print("SYNC: Created \(launchAgentsDir.path)")
            } catch {
                print("SYNC: Failed to create LaunchAgents directory: \(error)")
                return
            }
        }
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchdLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(scriptPath.path)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
                <key>HOME</key>
                <string>\(FileManager.default.homeDirectoryForCurrentUser.path)</string>
            </dict>
            <key>StandardOutPath</key>
            <string>/tmp/colonSend-mbsync.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/colonSend-mbsync-error.log</string>
        </dict>
        </plist>
        """
        
        let needsUpdate: Bool
        if FileManager.default.fileExists(atPath: plistPath.path) {
            // Check if content changed
            let existingContent = try? String(contentsOf: plistPath, encoding: .utf8)
            needsUpdate = existingContent != plistContent
        } else {
            needsUpdate = true
        }
        
        // Run async setup in a task
        Task {
            if needsUpdate {
                do {
                    // Unload old agent if exists
                    let _ = await runShellCommand("launchctl unload \"\(plistPath.path)\"")
                    
                    // Write new plist
                    try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
                    print("SYNC: Created/updated launchd plist at \(plistPath.path)")
                    
                    // Load agent
                    let loadResult = await runShellCommand("launchctl load \"\(plistPath.path)\"")
                    if loadResult.success {
                        print("SYNC: Loaded launchd agent")
                    } else {
                        print("SYNC: Failed to load launchd agent: \(loadResult.error ?? "unknown")")
                    }
                } catch {
                    print("SYNC: Failed to create launchd plist: \(error)")
                }
            } else {
                print("SYNC: launchd plist already up to date")
                
                // Make sure it's loaded
                let listResult = await runShellCommand("launchctl list \(launchdLabel)")
                if !listResult.success {
                    let _ = await runShellCommand("launchctl load \"\(plistPath.path)\"")
                }
            }
        }
    }
    
    // MARK: - Command Execution
    
    private struct CommandResult {
        let success: Bool
        let output: String?
        let error: String?
    }
    
    /// Run a shell command via /bin/bash -c with optional timeout
    /// This is more robust than calling executables directly as bash handles PATH resolution
    private func runShellCommand(_ command: String, timeout: TimeInterval? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", command]
                
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
                
                // Set up timeout if specified
                var timeoutWorkItem: DispatchWorkItem?
                var didTimeout = false
                
                if let timeout = timeout {
                    timeoutWorkItem = DispatchWorkItem {
                        if process.isRunning {
                            print("SYNC: Command timed out after \(timeout)s, terminating process")
                            didTimeout = true
                            process.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem!)
                }
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    // Cancel timeout timer if process completed
                    timeoutWorkItem?.cancel()
                    
                    // Check if we timed out
                    if didTimeout {
                        continuation.resume(returning: CommandResult(
                            success: false,
                            output: nil,
                            error: "Command timed out after \(Int(timeout ?? 0)) seconds"
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
