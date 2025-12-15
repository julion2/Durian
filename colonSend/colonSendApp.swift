//
//  colonSendApp.swift
//  colonSend
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI

@main
struct colonSendApp: App {
    
    init() {
        // Setup sync manager (creates script + launchd agent if needed)
        SyncManager.shared.setup()
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
            }
        }
    }
    
    private func openConfig() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let configURL = homeURL.appendingPathComponent(".config/colonSend/config.toml")
        
        NSWorkspace.shared.open(configURL)
    }
}
