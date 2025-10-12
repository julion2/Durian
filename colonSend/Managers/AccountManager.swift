//
//  AccountManager.swift
//  colonSend
//
//  Manages multiple IMAP accounts and aggregates their data
//

import Foundation
import Combine

@MainActor
class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var accounts: [MailAccount] = []
    @Published var imapClients: [String: IMAPClient] = [:]
    @Published var allFolders: [IMAPFolder] = []
    @Published var allEmails: [IMAPEmail] = []
    @Published var selectedAccount: String?
    @Published var isLoadingEmails = false
    @Published var loadingProgress = ""
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        loadAccounts()
    }
    
    private func loadAccounts() {
        accounts = ConfigManager.shared.accounts
        print("🔧 Loaded \(accounts.count) accounts")
    }
    
    func connectToAllAccounts() async {
        print("🔧 Connecting to \(accounts.count) accounts...")
        
        for account in accounts {
            let client = IMAPClient()
            imapClients[account.email] = client
            
            // Subscribe to client changes
            client.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
                self?.updateAggregatedData()
            }.store(in: &cancellables)
            
            Task {
                await client.connect(account: account)
                await updateAggregatedData()
            }
        }
    }
    
    private func mergeEmailsPreservingBodies(freshEmails: [IMAPEmail]) {
        print("🔄 Merging \(freshEmails.count) fresh emails with \(allEmails.count) existing emails, preserving bodies...")

        // If freshEmails is empty, it means the folder is actually empty
        // We should clear allEmails to reflect this
        // (The race condition is now prevented by clearing allEmails in selectFolder)
        if freshEmails.isEmpty {
            print("📭 Fresh emails is empty - folder is empty, clearing allEmails")
            allEmails.removeAll()
            return
        }

        // Create a dictionary of existing emails by UID for quick lookup
        var existingByUID: [UInt32: IMAPEmail] = [:]
        for email in allEmails {
            existingByUID[email.uid] = email
        }

        // Merge fresh emails with existing ones
        var merged: [IMAPEmail] = []
        for freshEmail in freshEmails {
            if let existing = existingByUID[freshEmail.uid],
               existing.body != nil && existing.body != "Loading..." {
                // Preserve the existing body that we already loaded
                var updated = freshEmail
                updated.body = existing.body
                updated.attributedBody = existing.attributedBody
                merged.append(updated)
                print("🔄 Preserved body for UID \(freshEmail.uid)")
            } else {
                // New email or no body yet
                merged.append(freshEmail)
            }
        }

        allEmails = merged
        print("✅ Merge complete: now have \(allEmails.count) emails")
    }

    private func updateAggregatedData() {
        // Aggregate all folders from all clients
        allFolders = imapClients.values.flatMap { $0.folders }

        // Aggregate emails ONLY from the explicitly selected account
        // Don't use fallback to avoid showing wrong emails during folder switch
        if let selectedAccount = selectedAccount,
           let client = imapClients[selectedAccount] {
            print("📧 updateAggregatedData: Using emails from selected account '\(selectedAccount)' (\(client.emails.count) emails)")
            mergeEmailsPreservingBodies(freshEmails: client.emails)
            isLoadingEmails = client.isLoadingEmails
            loadingProgress = client.loadingProgress
        } else {
            // No account selected - clear emails instead of showing random account's emails
            if selectedAccount != nil {
                print("⚠️ updateAggregatedData: selectedAccount '\(selectedAccount!)' has no client")
            } else {
                print("⚠️ updateAggregatedData: No account selected yet")
            }
            // Don't modify allEmails if no proper account is selected
            // This prevents race condition showing wrong emails
        }
    }
    
    func selectFolder(_ folderName: String, accountId: String) async {
        print("📂 AccountManager: Selecting folder '\(folderName)' for account '\(accountId)'")

        // CRITICAL: Clear emails immediately to prevent race condition
        // If we don't do this, objectWillChange from the client might show old emails
        allEmails.removeAll()
        selectedAccount = accountId

        guard let client = imapClients[accountId] else {
            print("❌ No IMAP client found for account: \(accountId)")
            return
        }

        await client.selectFolder(folderName)
        await updateAggregatedData()
    }
    
    func getClient(for accountId: String) -> IMAPClient? {
        return imapClients[accountId]
    }
    
    func reloadCurrentFolder() async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for reload")
            return
        }
        
        await client.reloadCurrentFolder()
        await updateAggregatedData()
    }
    
    func markAsRead(uid: UInt32) async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for mark as read")
            return
        }
        
        await client.markAsRead(uid: uid)
        await updateAggregatedData()
    }
    
    func toggleReadStatus(uid: UInt32) async {
        guard let selectedAccount = selectedAccount,
              let client = imapClients[selectedAccount] else {
            print("❌ No selected account or client for toggle read")
            return
        }
        
        await client.toggleReadStatus(uid: uid)
        await updateAggregatedData()
    }
}
