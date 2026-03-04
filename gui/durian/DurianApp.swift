//
//  DurianApp.swift
//  Durian
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import UserNotifications

// MARK: - Notification Delegate

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Handle notification click — route to the email thread
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let threadId = userInfo["threadId"] as? String {
            print("NOTIFICATIONS: Clicked notification for thread \(threadId)")
            Task { @MainActor in
                AccountManager.shared.selectEmail(threadId: threadId)
            }
        }
        completionHandler()
    }

    /// Show notifications even when app is in foreground (needed for testing)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - App

@main
struct DurianApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var accountManager = AccountManager.shared

    private static let notificationDelegate = NotificationDelegate()

    init() {
        // Setup sync manager (creates script + launchd agent if needed)
        SyncManager.shared.setup()

        // Set notification delegate before requesting permission
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate

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
            
            // Profile Menu
            CommandMenu("Profiles") {
                ForEach(Array(profileManager.profiles.enumerated()), id: \.element.id) { index, profile in
                    Button(action: {
                        Task {
                            await accountManager.switchProfile(profile)
                        }
                    }) {
                        HStack {
                            if profile == profileManager.currentProfile {
                                Image(systemName: "checkmark")
                            }
                            Text(profile.name)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
        
        // Compose Window - supports multiple windows via UUID
        WindowGroup("New Message", for: UUID.self) { $draftId in
            if let draftId = draftId {
                ComposeWindow(draftId: draftId)
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
