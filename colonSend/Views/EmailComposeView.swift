//
//  EmailComposeView.swift
//  colonSend
//
//  Email composition interface
//

import SwiftUI
import Combine

struct EmailComposeView: View {
    @StateObject private var sendingManager = EmailSendingManager.shared
    
    let accounts: [MailAccount]
    let replyTo: IMAPEmail?
    let existingDraft: EmailDraft?
    @Binding var triggerSend: Bool
    @Binding var currentDraft: EmailDraft?
    let onDismiss: () -> Void
    
    @State private var draft: EmailDraft
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var autoSaveCancellable: AnyCancellable?
    @State private var selectedSignature: String?
    
    private let signatures: [String: String]
    
    init(accounts: [MailAccount], replyTo: IMAPEmail? = nil, existingDraft: EmailDraft? = nil, triggerSend: Binding<Bool>, currentDraft: Binding<EmailDraft?>, onDismiss: @escaping () -> Void) {
        self.accounts = accounts
        self.replyTo = replyTo
        self.existingDraft = existingDraft
        self._triggerSend = triggerSend
        self._currentDraft = currentDraft
        self.onDismiss = onDismiss
        self.signatures = ConfigManager.shared.getSignatures()
        
        let defaultAccount = accounts.first?.email ?? ""
        
        if let existing = existingDraft {
            _draft = State(initialValue: existing)
            _selectedSignature = State(initialValue: nil)
        } else if let email = replyTo {
            let toAddress = Self.extractEmailAddress(from: email.from)
            let replySubject = email.subject.hasPrefix("Re:") ? email.subject : "Re: \(email.subject)"
            let quotedBody = "\n\n---\nOn \(email.date), \(email.from) wrote:\n> \(email.body ?? "")"
            
            _draft = State(initialValue: EmailDraft(
                from: defaultAccount,
                to: [toAddress],
                subject: replySubject,
                body: quotedBody,
                inReplyTo: String(email.uid)
            ))
            
            let account = accounts.first { $0.email == defaultAccount }
            _selectedSignature = State(initialValue: account?.defaultSignature)
        } else {
            _draft = State(initialValue: EmailDraft(from: defaultAccount))
            
            let account = accounts.first { $0.email == defaultAccount }
            _selectedSignature = State(initialValue: account?.defaultSignature)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("From:")
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $draft.from) {
                        ForEach(accounts, id: \.email) { account in
                            Text(account.name).tag(account.email)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.accentColor)
                    .onChange(of: draft.from) { newAccount in
                        if let account = accounts.first(where: { $0.email == newAccount }) {
                            selectedSignature = account.defaultSignature
                        }
                        scheduleAutoSave()
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.6))
                        .frame(height: 1)
                        .padding(.leading, 76)
                        .padding(.trailing, 16)
                }
                
                HStack(spacing: 8) {
                    Text("To:")
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("", text: toBinding)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.6))
                        .frame(height: 1)
                        .padding(.leading, 76)
                        .padding(.trailing, 16)
                }
                
                HStack(spacing: 8) {
                    Text("Cc:")
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("", text: ccBinding)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.6))
                        .frame(height: 1)
                        .padding(.leading, 76)
                        .padding(.trailing, 16)
                }
                
                HStack(spacing: 8) {
                    Text("Subject:")
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(.secondary)
                    TextField("", text: $draft.subject)
                        .textFieldStyle(.plain)
                    
                    if !signatures.isEmpty {
                        Text("Signature:")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $selectedSignature) {
                            Text("None").tag(nil as String?)
                            ForEach(signatures.keys.sorted(), id: \.self) { key in
                                Text(key.capitalized).tag(key as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(.accentColor)
                        .onChange(of: selectedSignature) { _ in
                            updateBodyWithSignature()
                        }
                    }
                }
                .onChange(of: draft.subject) { _ in
                    scheduleAutoSave()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.6))
                        .frame(height: 1)
                        .padding(.leading, 76)
                        .padding(.trailing, 16)
                }
                
                TextEditor(text: $draft.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .onChange(of: draft.body) { _ in
                        scheduleAutoSave()
                    }
            }
            
            Divider()
            
            HStack {
                if sendingManager.isSending {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(sendingManager.sendingProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .frame(height: 40)
        }
        .navigationTitle(replyTo != nil ? "Reply" : "New Message")
        .alert("Send Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: triggerSend) { newValue in
            if newValue {
                sendEmail()
                triggerSend = false
            }
        }
        .onChange(of: draft) { newDraft in
            currentDraft = newDraft
        }
        .onAppear {
            currentDraft = draft
            updateBodyWithSignature()
        }
        .onDisappear {
            autoSaveCancellable?.cancel()
            
            print("COMPOSE: View disappearing - saving draft to server")
            Task {
                await saveDraftToServer()
            }
            
            currentDraft = nil
        }
    }
    
    private var toBinding: Binding<String> {
        Binding(
            get: { draft.to.joined(separator: ", ") },
            set: { newValue in
                draft.to = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                scheduleAutoSave()
            }
        )
    }
    
    private var ccBinding: Binding<String> {
        Binding(
            get: { draft.cc.joined(separator: ", ") },
            set: { newValue in
                draft.cc = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                scheduleAutoSave()
            }
        )
    }
    
    private func updateBodyWithSignature() {
        let bodyWithoutSignature = removeExistingSignature(from: draft.body)
        
        if let signatureKey = selectedSignature,
           let signatureText = signatures[signatureKey],
           !signatureText.isEmpty {
            draft.body = bodyWithoutSignature + "\n\n" + signatureText
        } else {
            draft.body = bodyWithoutSignature
        }
    }
    
    private func removeExistingSignature(from body: String) -> String {
        for sigKey in signatures.keys {
            if let sigText = signatures[sigKey],
               let range = body.range(of: "\n\n" + sigText, options: .backwards) {
                return String(body[..<range.lowerBound])
            }
        }
        return body
    }
    
    private func scheduleAutoSave() {
        autoSaveCancellable?.cancel()
        
        autoSaveCancellable = Just(())
            .delay(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { _ in
                var updatedDraft = draft
                updatedDraft.updateModifiedDate()
                
                print("DRAFTING: Auto-saving draft locally only")
                DraftManager.shared.saveDraft(updatedDraft)
            }
    }
    
    private func saveDraftToServer() async {
        var updatedDraft = draft
        updatedDraft.updateModifiedDate()
        
        print("DRAFTING: Saving draft to local storage")
        DraftManager.shared.saveDraft(updatedDraft)
        
        print("DRAFTING: Saving draft to IMAP server for account: \(updatedDraft.from)")
        
        do {
            if let oldUID = draft.uid, let accountId = draft.accountId {
                print("DRAFTING: Deleting old server draft UID: \(oldUID)")
                try? await AccountManager.shared.deleteDraftFromIMAP(uid: oldUID, accountId: accountId)
            }
            
            let uid = try await AccountManager.shared.saveDraftToIMAP(draft: updatedDraft, accountId: updatedDraft.from)
            
            if let uid = uid {
                print("DRAFTING: Server save successful - UID: \(uid)")
                draft.uid = uid
                draft.accountId = updatedDraft.from
            }
        } catch {
            print("DRAFTING: Server save failed (local copy preserved) - \(error)")
        }
    }
    
    private func sendEmail() {
        Task {
            do {
                print("COMPOSE: Sending email")
                try await sendingManager.send(draft: draft, fromAccount: draft.from)
                
                print("COMPOSE: Deleting local draft")
                DraftManager.shared.deleteDraft(id: draft.id)
                
                print("COMPOSE: Email sent successfully, dismissing")
                onDismiss()
            } catch {
                print("COMPOSE: Send failed - \(error)")
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
    
    private static func extractEmailAddress(from: String) -> String {
        if let emailRange = from.range(of: "<(.+?)>", options: .regularExpression) {
            let email = String(from[emailRange]).replacingOccurrences(of: "[<>]", with: "", options: .regularExpression)
            return email
        }
        return from
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var triggerSend = false
        @State private var draft: EmailDraft? = nil
        
        var body: some View {
            EmailComposeView(
                accounts: [
                    MailAccount(
                        name: "Test Account",
                        email: "test@example.com",
                        imap: ServerConfig(host: "imap.example.com", port: 993, ssl: true),
                        smtp: ServerConfig(host: "smtp.example.com", port: 587, ssl: false),
                        auth: AuthConfig(username: "test", passwordKeychain: "test-keychain"),
                        defaultSignature: nil
                    )
                ],
                replyTo: nil,
                existingDraft: nil,
                triggerSend: $triggerSend,
                currentDraft: $draft,
                onDismiss: {}
            )
        }
    }
    
    return PreviewWrapper()
}
