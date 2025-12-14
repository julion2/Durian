//
//  EmailComposeView.swift
//  colonSend
//
//  Email composition interface
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

struct EmailComposeView: View {
    @StateObject private var sendingManager = EmailSendingManager.shared
    
    let accounts: [MailAccount]
    let existingDraft: EmailDraft?
    @Binding var triggerSend: Bool
    @Binding var currentDraft: EmailDraft?
    let onDismiss: () -> Void
    
    @State private var draft: EmailDraft
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var autoSaveCancellable: AnyCancellable?
    @State private var selectedSignature: String?
    @State private var showingFilePicker = false
    @State private var selectedAttachmentIndex: Int? = nil
    @State private var keyMonitor: Any?
    
    private let signatures: [String: String]
    private let maxAttachmentSize: Int64 = 25_000_000
    private let maxTotalSize: Int64 = 50_000_000
    private let maxAttachments: Int = 10
    
    init(accounts: [MailAccount], existingDraft: EmailDraft? = nil, triggerSend: Binding<Bool>, currentDraft: Binding<EmailDraft?>, onDismiss: @escaping () -> Void) {
        self.accounts = accounts
        self.existingDraft = existingDraft
        self._triggerSend = triggerSend
        self._currentDraft = currentDraft
        self.onDismiss = onDismiss
        self.signatures = ConfigManager.shared.getSignatures()
        
        let defaultAccount = accounts.first?.email ?? ""
        
        if let existing = existingDraft {
            _draft = State(initialValue: existing)
            _selectedSignature = State(initialValue: nil)
        } else {
            _draft = State(initialValue: EmailDraft(from: defaultAccount))
            
            let account = accounts.first { $0.email == defaultAccount }
            _selectedSignature = State(initialValue: account?.defaultSignature)
        }
    }
    
    private var attachmentsScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(draft.attachments.enumerated()), id: \.element.id) { index, attachment in
                    AttachmentChip(
                        filename: attachment.filename,
                        size: attachment.sizeFormatted,
                        isSelected: selectedAttachmentIndex == index,
                        onClick: {
                            selectedAttachmentIndex = index
                        },
                        onRemove: {
                            removeAttachment(id: attachment.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
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
            
            if !draft.attachments.isEmpty {
                attachmentsScrollView
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
        .navigationTitle(existingDraft != nil ? "Edit Draft" : "New Message")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    showingFilePicker = true
                }) {
                    Label("Attach", systemImage: "paperclip")
                }
                .disabled(draft.attachments.count >= maxAttachments)
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
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
            setupKeyMonitor()
        }
        .onDisappear {
            autoSaveCancellable?.cancel()
            removeKeyMonitor()
            
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
    
    private struct BodySections {
        var userContent: String
        var signature: String?
        var quotedContent: String
    }
    
    private func parseBodySections(_ body: String) -> BodySections {
        let quoteSeparators = [
            "---\nOn ",
            "---------- Forwarded message"
        ]
        
        var quotedContent = ""
        var contentBeforeQuote = body
        
        for separator in quoteSeparators {
            if let range = body.range(of: separator) {
                contentBeforeQuote = String(body[..<range.lowerBound])
                quotedContent = String(body[range.lowerBound...])
                break
            }
        }
        
        var userContent = contentBeforeQuote
        var existingSignature: String? = nil
        
        for (_, sigText) in signatures {
            if let sigRange = contentBeforeQuote.range(of: "\n\n" + sigText, options: .backwards) {
                userContent = String(contentBeforeQuote[..<sigRange.lowerBound])
                existingSignature = sigText
                break
            }
        }
        
        return BodySections(
            userContent: userContent,
            signature: existingSignature,
            quotedContent: quotedContent
        )
    }
    
    private func updateBodyWithSignature() {
        let sections = parseBodySections(draft.body)
        
        var newBody = sections.userContent
        
        if let signatureKey = selectedSignature,
           let signatureText = signatures[signatureKey],
           !signatureText.isEmpty {
            newBody += "\n\n" + signatureText
        }
        
        if !sections.quotedContent.isEmpty {
            newBody += "\n\n" + sections.quotedContent
        }
        
        draft.body = newBody
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
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    print("Failed to access file: \(url.lastPathComponent)")
                    continue
                }
                
                defer {
                    url.stopAccessingSecurityScopedResource()
                }
                
                do {
                    let data = try Data(contentsOf: url)
                    
                    guard canAddAttachment(size: Int64(data.count)) else {
                        continue
                    }
                    
                    let mimeType = getMimeType(for: url)
                    let attachment = EmailAttachment(
                        filename: url.lastPathComponent,
                        mimeType: mimeType,
                        data: data
                    )
                    
                    draft.attachments.append(attachment)
                    scheduleAutoSave()
                    
                } catch {
                    print("Failed to read file: \(error)")
                    showErrorMessage("Failed to attach: \(url.lastPathComponent)")
                }
            }
            
        case .failure(let error):
            print("File picker error: \(error)")
        }
    }
    
    private func canAddAttachment(size: Int64) -> Bool {
        guard draft.attachments.count < maxAttachments else {
            showErrorMessage("Maximum \(maxAttachments) attachments allowed")
            return false
        }
        
        guard size <= maxAttachmentSize else {
            showErrorMessage("File too large (max 25MB)")
            return false
        }
        
        guard draft.totalAttachmentSize + size <= maxTotalSize else {
            showErrorMessage("Total attachments too large (max 50MB)")
            return false
        }
        
        return true
    }
    
    private func getMimeType(for url: URL) -> String {
        if let uti = UTType(filenameExtension: url.pathExtension) {
            return uti.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
    
    private func removeAttachment(id: UUID) {
        draft.attachments.removeAll { $0.id == id }
        scheduleAutoSave()
    }
    
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
    
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 {
                if let index = self.selectedAttachmentIndex {
                    print("QUICKLOOK: Space pressed, opening preview for attachment \(index)")
                    QuickLookManager.shared.showPreview(for: self.draft.attachments, startingAt: index)
                    return nil
                }
            }
            return event
        }
    }
    
    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

struct AttachmentChip: View {
    let filename: String
    let size: String
    let isSelected: Bool
    let onClick: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.accentColor.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .cornerRadius(8)
        .onTapGesture {
            onClick()
        }
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
                existingDraft: nil,
                triggerSend: $triggerSend,
                currentDraft: $draft,
                onDismiss: {}
            )
        }
    }
    
    return PreviewWrapper()
}
