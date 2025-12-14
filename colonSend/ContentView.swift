//
//  ContentView.swift
//  colonSend
//
//  Created by Julian Schenker on 15.09.25.
//

import SwiftUI
import Combine

enum DetailViewMode: Equatable {
    case notmuchEmailDetail(emailId: String)
    case empty
}

struct ContentView: View {
    @StateObject private var accountManager = AccountManager.shared
    @StateObject private var keymapsManager = KeymapsManager.shared
    @StateObject private var keymapHandler = KeymapHandler.shared
    @StateObject private var profileManager = ProfileManager.shared
    @State private var selectedTagID: String? = "inbox"
    @State private var selectedNotmuchEmails: Set<String> = []
    @State private var detailMode: DetailViewMode = .empty

    var body: some View {
        notmuchView
    }
    
    // MARK: - Notmuch View
    
    @ViewBuilder
    private var notmuchView: some View {
        NavigationSplitView {
            // Sidebar: Tags + Profile Picker at bottom
            VStack(spacing: 0) {
                List(selection: $selectedTagID) {
                    Section("Tags") {
                        ForEach(accountManager.mailFolders) { folder in
                            Label(folder.displayName, systemImage: folder.icon)
                                .tag(folder.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                
                // Profile Picker - fixed at bottom
                if profileManager.profiles.count > 1 {
                    Picker("", selection: Binding(
                        get: { profileManager.currentProfile },
                        set: { newProfile in
                            if let profile = newProfile {
                                Task {
                                    await accountManager.switchProfile(profile)
                                }
                            }
                        }
                    )) {
                        ForEach(profileManager.profiles) { profile in
                            Text(profile.name).tag(profile as Profile?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("colonSend")
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
                
                if !accountManager.mailMessages.isEmpty {
                    EmailListView(
                        emails: accountManager.mailMessages,
                        selection: $selectedNotmuchEmails,
                        onEmailAppear: { email in
                            // Prefetch body when email becomes visible
                            if case .notLoaded = email.bodyState {
                                Task {
                                    await accountManager.fetchNotmuchEmailBody(id: email.id)
                                }
                            }
                        }
                    )
                } else if accountManager.isLoadingEmails {
                    VStack {
                        ProgressView()
                        Text(accountManager.loadingProgress)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                } else {
                    Text("No emails")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                }
            }
            .navigationTitle("colonSend")
            .navigationSubtitle(accountManager.selectedFolder)
            .toolbar {
                ToolbarItem {
                    Button(action: {
                        Task {
                            await accountManager.reloadNotmuch()
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        } detail: {
            // Detail View
            if case .notmuchEmailDetail(let emailId) = detailMode,
               let email = accountManager.mailMessages.first(where: { $0.id == emailId }) {
                notmuchEmailDetailView(email: email)
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
        }
        .onChange(of: selectedTagID) { tagId in
            if let tagId = tagId {
                Task {
                    await accountManager.selectNotmuchTag(tagId)
                }
            }
        }
        .onChange(of: selectedNotmuchEmails) { newSelection in
            if newSelection.count == 1, let emailId = newSelection.first {
                handleNotmuchEmailSelection(emailId)
            }
        }
    }
    
    // MARK: - Email Detail View
    
    @ViewBuilder
    private func notmuchEmailDetailView(email: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed Header
            VStack(alignment: .leading, spacing: 8) {
                Text(email.subject)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("From:")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(email.from)
                            .textSelection(.enabled)
                    }
                    
                    HStack {
                        Text("Date:")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(email.date)
                            .textSelection(.enabled)
                    }
                    
                    if let tags = email.tags {
                        HStack {
                            Text("Tags:")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text(tags)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
            .padding(20)
            .padding(.bottom, 12)
            
            Divider()
            
            // Body - WebView hat eigenes Scrolling, Text braucht ScrollView
            switch email.bodyState {
            case .notLoaded:
                ScrollView {
                    Text("Click to load")
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onTapGesture {
                    Task {
                        await accountManager.fetchNotmuchEmailBody(id: email.id)
                    }
                }
            case .loading:
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let body, _):
                if let html = email.htmlBody, !html.isEmpty {
                    // WebView hat eigenes Scrolling - keine ScrollView nötig
                    EmailWebView(
                                        html: html,
                                        theme: SettingsManager.shared.settings.theme,
                                        loadRemoteImages: SettingsManager.shared.settings.loadRemoteImages
                                    )
                } else {
                    // Text braucht ScrollView
                    ScrollView {
                        Text(makeLinksClickable(body))
                            .textSelection(.enabled)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .failed(let message):
                Text("Failed: \(message)")
                    .foregroundStyle(.red)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .navigationTitle("Email")
        .onAppear {
            // Auto-load body
            if case .notLoaded = email.bodyState {
                Task {
                    await accountManager.fetchNotmuchEmailBody(id: email.id)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func makeLinksClickable(_ text: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        // HTTP/HTTPS URLs - clickable, opens in browser
        let urlPattern = #"https?://[^\s<>\"'\]\)]+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            
            for match in matches {
                if let swiftRange = Range(match.range, in: text),
                   let attrRange = Range(swiftRange, in: attributedString) {
                    let urlString = String(text[swiftRange])
                    if let url = URL(string: urlString) {
                        attributedString[attrRange].link = url
                        attributedString[attrRange].foregroundColor = .blue
                        attributedString[attrRange].underlineStyle = .single
                    }
                }
            }
        }
        
        // Mailto links - just styled blue, not clickable (for now)
        let mailtoPattern = #"mailto:[^\s<>\"'\]\)]+"#
        if let regex = try? NSRegularExpression(pattern: mailtoPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            
            for match in matches {
                if let swiftRange = Range(match.range, in: text),
                   let attrRange = Range(swiftRange, in: attributedString) {
                    attributedString[attrRange].foregroundColor = .blue
                    attributedString[attrRange].underlineStyle = .single
                }
            }
        }
        
        return attributedString
    }
    
    private func handleNotmuchEmailSelection(_ emailId: String) {
        detailMode = .notmuchEmailDetail(emailId: emailId)
        
        // Auto-load body if not loaded
        if let email = accountManager.mailMessages.first(where: { $0.id == emailId }) {
            if case .notLoaded = email.bodyState {
                Task {
                    await accountManager.fetchNotmuchEmailBody(id: emailId)
                }
            }
            
            // Mark as read
            if !email.isRead {
                Task {
                    await accountManager.markNotmuchAsRead(id: emailId)
                }
            }
        }
    }
    
}

// MARK: - Key Sequence Indicator

/// Shows the current key sequence being typed (vim-style) and visual mode indicator
struct KeySequenceIndicator: View {
    @ObservedObject private var keymapHandler = KeymapHandler.shared
    
    var body: some View {
        HStack(spacing: 8) {
            // Visual Mode Indicator
            if keymapHandler.engine.isVisualMode {
                Text("-- VISUAL --")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.15))
                    )
            }
            
            // Key Sequence Indicator
            if !keymapHandler.currentSequence.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.caption)
                    Text(keymapHandler.currentSequence)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            }
        }
    }
}

#Preview {
    ContentView()
}
