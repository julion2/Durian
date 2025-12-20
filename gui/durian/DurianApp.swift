//
//  DurianApp.swift
//  Durian
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import UserNotifications

@main
struct DurianApp: App {
    @Environment(\.openWindow) private var openWindow
    
    init() {
        // Setup sync manager (creates script + launchd agent if needed)
        SyncManager.shared.setup()
        
        // Request notification permission for sync warnings/errors
        requestNotificationPermission()
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("NOTIFICATIONS: Permission granted")
            } else if let error = error {
                print("NOTIFICATIONS: Permission error - \(error.localizedDescription)")
            } else {
                print("NOTIFICATIONS: Permission denied")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    openConfig()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandGroup(after: .newItem) {
                Button("Reload Keymaps") {
                    KeymapsManager.shared.reloadKeymaps()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                
                Button("Reload Config") {
                    SettingsManager.shared.reloadSettings()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Full Sync") {
                    Task {
                        await SyncManager.shared.fullSync()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        
        // Compose Window - supports multiple windows via UUID
        WindowGroup("New Message", for: UUID.self) { $draftId in
            if let draftId = draftId {
                ComposeWindowView(draftId: draftId)
            }
        }
        .defaultSize(width: 650, height: 550)
    }
    
    private func openConfig() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let configURL = homeURL.appendingPathComponent(".config/durian/config.toml")
        
        NSWorkspace.shared.open(configURL)
    }
}
