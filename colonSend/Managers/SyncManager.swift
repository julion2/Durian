//
//  SyncManager.swift
//  colonSend
//
//  Manages email synchronization via mbsync + notmuch
//  Uses launchd to avoid fork() crashes in macOS apps
//

import Foundation
import Combine

@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    // MARK: - Published State
    @Published var isSyncing = false
    @Published var lastSyncTime: Date?
    @Published var syncStatus: String = ""
    
    // MARK: - Paths
    private let scriptDir: URL
    private let scriptPath: URL
    private let plistPath: URL
    private let completionFile = "/tmp/colonSend-sync-complete"
    private let launchdLabel = "com.colonSend.mbsync"
    
    // MARK: - Timer
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
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
        
        // Start timer based on config
        startTimer()
        
        // Listen for settings changes to update timer
        SettingsManager.shared.$settings
            .dropFirst()
            .sink { [weak self] settings in
                self?.restartTimer(interval: settings.autoFetchInterval)
            }
            .store(in: &cancellables)
        
        print("SYNC: Setup complete")
    }
    
    // MARK: - Timer Management
    
    func startTimer() {
        let settings = SettingsManager.shared.settings
        guard settings.autoFetchEnabled else {
            print("SYNC: Auto-fetch disabled, not starting timer")
            return
        }
        
        let interval = settings.autoFetchInterval
        print("SYNC: Starting sync timer with interval \(interval)s")
        
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sync()
            }
        }
    }
    
    func stopTimer() {
        print("SYNC: Stopping sync timer")
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func restartTimer(interval: TimeInterval) {
        print("SYNC: Restarting timer with new interval \(interval)s")
        stopTimer()
        if SettingsManager.shared.settings.autoFetchEnabled {
            startTimer()
        }
    }
    
    // MARK: - Sync Execution
    
    /// Trigger a sync (called by timer or manually via Cmd+R)
    func sync() async -> Bool {
        guard !isSyncing else {
            print("SYNC: Already syncing, skipping")
            return false
        }
        
        isSyncing = true
        syncStatus = "Syncing from server..."
        
        defer {
            isSyncing = false
        }
        
        // 1. Remove completion file
        try? FileManager.default.removeItem(atPath: completionFile)
        
        // 2. Trigger mbsync via launchctl
        print("SYNC: Triggering mbsync via launchctl")
        let launchResult = await runShellCommand("launchctl start \(launchdLabel)")
        
        if !launchResult.success {
            print("SYNC: launchctl start failed - \(launchResult.error ?? "unknown error")")
            
            // Maybe agent isn't loaded? Try to load it
            if launchResult.error?.contains("No such process") == true || 
               launchResult.error?.contains("Could not find") == true {
                print("SYNC: Agent not loaded, attempting to load...")
                let loadResult = await runShellCommand("launchctl load \"\(plistPath.path)\"")
                if loadResult.success {
                    // Retry start
                    let retryResult = await runShellCommand("launchctl start \(launchdLabel)")
                    if !retryResult.success {
                        syncStatus = "Sync failed - launchd error"
                        return false
                    }
                } else {
                    syncStatus = "Sync failed - couldn't load agent"
                    return false
                }
            } else {
                syncStatus = "Sync failed"
                return false
            }
        }
        
        // 3. Poll for completion (max 60 seconds)
        print("SYNC: Waiting for mbsync to complete...")
        let completed = await waitForCompletion(timeout: 60)
        
        if !completed {
            print("SYNC: Timeout waiting for mbsync")
            syncStatus = "Sync timeout"
            return false
        }
        
        // 4. Check exit code from completion file
        if let exitCodeStr = try? String(contentsOfFile: completionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let exitCode = Int(exitCodeStr) {
            if exitCode != 0 {
                print("SYNC: mbsync exited with code \(exitCode)")
                syncStatus = "Sync failed (exit \(exitCode))"
                return false
            }
        }
        
        // 5. Run notmuch new
        syncStatus = "Indexing new mail..."
        print("SYNC: Running notmuch new")
        let notmuchResult = await runShellCommand("notmuch new")
        
        if !notmuchResult.success {
            print("SYNC: notmuch new failed")
            syncStatus = "Indexing failed"
            return false
        }
        
        // Success!
        lastSyncTime = Date()
        syncStatus = "Synced"
        print("SYNC: Sync completed successfully")
        return true
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
        
        // Create/update script
        let scriptContent = """
        #!/bin/bash
        # colonSend mail sync script
        # Auto-generated - do not edit
        
        COMPLETION_FILE="/tmp/colonSend-sync-complete"
        
        # Remove old completion file
        rm -f "$COMPLETION_FILE"
        
        # Run mbsync
        /opt/homebrew/bin/mbsync -a
        EXIT_CODE=$?
        
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
    
    /// Run a shell command via /bin/bash -c
    /// This is more robust than calling executables directly as bash handles PATH resolution
    private func runShellCommand(_ command: String) async -> CommandResult {
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
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8)
                    let error = String(data: errorData, encoding: .utf8)
                    
                    let success = process.terminationStatus == 0
                    continuation.resume(returning: CommandResult(success: success, output: output, error: error))
                } catch {
                    continuation.resume(returning: CommandResult(success: false, output: nil, error: error.localizedDescription))
                }
            }
        }
    }
}
