//
//  ComposeWindow.swift
//  Durian
//
//  Standalone window wrapper for ComposeForm
//

import SwiftUI

/// Wrapper view for the compose window
struct ComposeWindow: View {
    let draftId: UUID
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftService = DraftService.shared
    @StateObject private var sendingManager = EmailSendingManager.shared
    
    @State private var triggerSend: Bool = false
    @State private var showSaveError: Bool = false
    @State private var saveErrorMessage: String = ""
    @State private var isSaving: Bool = false
    @State private var showingFilePicker: Bool = false
    
    var body: some View {
        let accounts = ConfigManager.shared.getAccounts()
        
        if accounts.isEmpty {
            noAccountsView
        } else if let draft = draftService.getDraft(id: draftId) {
            composeView(draft: draft, accounts: accounts)
        } else {
            // Draft not found - might have been discarded
            ContentUnavailableView("Draft Not Found", systemImage: "doc.questionmark")
                .onAppear { dismiss() }
        }
    }
    
    // MARK: - Subviews
    
    private var noAccountsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No accounts configured")
                .font(.title2)
            Text("Add an account in config.toml to send emails")
                .foregroundStyle(.secondary)
            Button("Close") {
                dismiss()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func composeView(draft: EmailDraft, accounts: [MailAccount]) -> some View {
        ComposeForm(
            accounts: accounts,
            existingDraft: draft,
            triggerSend: $triggerSend,
            showingFilePicker: $showingFilePicker,
            currentDraft: Binding(
                get: { draftService.getDraft(id: draftId) },
                set: { newDraft in
                    if let newDraft = newDraft {
                        draftService.updateDraft(id: draftId, draft: newDraft)
                    }
                }
            ),
            onDismiss: { handleDismiss() }
        )
        .toolbar {
            // Saving indicator (left)
            ToolbarItem(placement: .cancellationAction) {
                if isSaving || draftService.savingDrafts.contains(draftId) {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            
            // Action icons (right)
            ToolbarItemGroup(placement: .primaryAction) {
                // AI / Sparkles
                Button(action: {}) {
                    Image(systemName: "sparkles")
                }
                .disabled(true)
                .help("AI Assist (Coming Soon)")
                
                // Attachment
                Button(action: {
                    showingFilePicker = true
                }) {
                    Image(systemName: "paperclip")
                }
                .help("Add Attachment")
                
                // Link
                Button(action: {}) {
                    Image(systemName: "link")
                }
                .disabled(true)
                .help("Insert Link (Coming Soon)")
                
                // Text format
                Button(action: {}) {
                    Image(systemName: "textformat")
                }
                .disabled(true)
                .help("Text Formatting (Coming Soon)")
                
                // More options
                Menu {
                    Button(action: {}) {
                        Label("Show Original", systemImage: "doc.plaintext")
                    }
                    .disabled(draftService.getDraft(id: draftId)?.inReplyTo == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help("More Options")
                
                // Send
                Button(action: {
                    triggerSend = true
                }) {
                    Image(systemName: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    draftService.getDraft(id: draftId)?.to.isEmpty ?? true
                    || sendingManager.isSending
                )
                .help("Send (⌘Return)")
            }
        }
        .onChange(of: triggerSend) { oldValue, newValue in
            if newValue {
                handleSend()
                triggerSend = false
            }
        }
        .alert("Save Error", isPresented: $showSaveError) {
            Button("Retry") {
                handleDismiss()
            }
            Button("Discard") {
                draftService.discard(id: draftId)
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
    }
    
    // MARK: - Actions
    
    private func handleDismiss() {
        isSaving = true
        
        Task {
            do {
                _ = try await draftService.saveToServer(id: draftId)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = error.localizedDescription
                    showSaveError = true
                }
            }
        }
    }
    
    private func handleSend() {
        guard let draft = draftService.getDraft(id: draftId) else { return }
        
        Task {
            do {
                try await sendingManager.send(draft: draft, fromAccount: draft.from)
                
                // Delete the draft from IMAP after successful send
                await draftService.deleteAfterSend(id: draftId)
                
                await MainActor.run {
                    dismiss()
                }
            } catch {
                // Error is handled by EmailSendingManager
                print("COMPOSE: Send failed - \(error)")
            }
        }
    }
}

#Preview {
    ComposeWindow(draftId: UUID())
        .frame(width: 700, height: 600)
}
