//
//  EmailComposeView.swift
//  colonSend
//
//  Email composition interface
//

import SwiftUI
import Combine

struct EmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sendingManager = EmailSendingManager.shared
    
    let accounts: [MailAccount]
    let replyTo: IMAPEmail?
    
    @State private var draft: EmailDraft
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var autoSaveCancellable: AnyCancellable?
    
    init(accounts: [MailAccount], replyTo: IMAPEmail? = nil) {
        self.accounts = accounts
        self.replyTo = replyTo
        
        let defaultAccount = accounts.first?.email ?? ""
        
        if let email = replyTo {
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
        } else {
            _draft = State(initialValue: EmailDraft(from: defaultAccount))
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("From:", selection: $draft.from) {
                    ForEach(accounts, id: \.email) { account in
                        Text(account.name).tag(account.email)
                    }
                }
                .onChange(of: draft.from) { _ in
                    scheduleAutoSave()
                }
                
                HStack {
                    Text("To:")
                        .frame(width: 60, alignment: .leading)
                    TextField("Recipients (comma-separated)", text: toBinding)
                        .textFieldStyle(.plain)
                }
                
                HStack {
                    Text("Cc:")
                        .frame(width: 60, alignment: .leading)
                    TextField("Optional", text: ccBinding)
                        .textFieldStyle(.plain)
                }
                
                HStack {
                    Text("Subject:")
                        .frame(width: 60, alignment: .leading)
                    TextField("Email subject", text: $draft.subject)
                        .textFieldStyle(.plain)
                }
                .onChange(of: draft.subject) { _ in
                    scheduleAutoSave()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Message:")
                        .font(.headline)
                    
                    TextEditor(text: $draft.body)
                        .font(.body)
                        .frame(minHeight: 200)
                        .border(Color.gray.opacity(0.2), width: 1)
                }
                .onChange(of: draft.body) { _ in
                    scheduleAutoSave()
                }
            }
            .padding()
            
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
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Button("Send") {
                    sendEmail()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid || sendingManager.isSending)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
        .alert("Send Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
        .onDisappear {
            autoSaveCancellable?.cancel()
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
    
    private func scheduleAutoSave() {
        autoSaveCancellable?.cancel()
        
        autoSaveCancellable = Just(())
            .delay(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { _ in
                var updatedDraft = draft
                updatedDraft.updateModifiedDate()
                DraftManager.shared.saveDraft(updatedDraft)
            }
    }
    
    private func sendEmail() {
        Task {
            do {
                try await sendingManager.send(draft: draft, fromAccount: draft.from)
                dismiss()
            } catch {
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
    EmailComposeView(
        accounts: [
            MailAccount(
                name: "Test Account",
                email: "test@example.com",
                imap: ServerConfig(host: "imap.example.com", port: 993, ssl: true),
                smtp: ServerConfig(host: "smtp.example.com", port: 587, ssl: false),
                auth: AuthConfig(username: "test", passwordKeychain: "test-keychain")
            )
        ],
        replyTo: nil
    )
}
