//
//  EmailComposeView.swift
//  Durian
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
    @Binding var showingFilePicker: Bool
    @Binding var currentDraft: EmailDraft?
    let onDismiss: () -> Void
    
    @State private var draft: EmailDraft
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var autoSaveCancellable: AnyCancellable?
    @State private var selectedSignature: String?
    @State private var selectedAttachmentIndex: Int? = nil
    @State private var keyMonitor: Any?
    @State private var showCcBcc: Bool = false
    
    private let signatures: [String: String]
    private let maxAttachmentSize: Int64 = 25_000_000
    private let maxTotalSize: Int64 = 50_000_000
    private let maxAttachments: Int = 10
    
    // MARK: - Colors
    
    private let labelColor = Color(hex: "#4a5565")
    private let placeholderColor = Color(hex: "#717182")
    private let textColor = Color(hex: "#0a0a0a")
    
    init(accounts: [MailAccount], existingDraft: EmailDraft? = nil, triggerSend: Binding<Bool>, showingFilePicker: Binding<Bool>, currentDraft: Binding<EmailDraft?>, onDismiss: @escaping () -> Void) {
        self.accounts = accounts
        self.existingDraft = existingDraft
        self._triggerSend = triggerSend
        self._showingFilePicker = showingFilePicker
        self._currentDraft = currentDraft
        self.onDismiss = onDismiss
        self.signatures = ConfigManager.shared.getSignatures()
        
        let defaultAccount = accounts.first?.email ?? ""
        
        if let existing = existingDraft {
            _draft = State(initialValue: existing)
            _selectedSignature = State(initialValue: nil)
            // Auto-expand Cc/Bcc if draft has values
            _showCcBcc = State(initialValue: !existing.cc.isEmpty || !existing.bcc.isEmpty)
        } else {
            _draft = State(initialValue: EmailDraft(from: defaultAccount))
            
            let account = accounts.first { $0.email == defaultAccount }
            _selectedSignature = State(initialValue: account?.defaultSignature)
            _showCcBcc = State(initialValue: false)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Form Area
            formSection
            
            // Formatting Toolbar
            FormattingToolbar()
            
            // Message Editor
            messageEditor
            
            // Attachments (if any)
            if !draft.attachments.isEmpty {
                attachmentsScrollView
            }
            
            // Bottom Status Bar
            statusBar
        }
        .navigationTitle("")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: triggerSend) { oldValue, newValue in
            if newValue {
                sendEmail()
                triggerSend = false
            }
        }
        .onChange(of: draft) { oldValue, newDraft in
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
    
    // MARK: - Form Section
    
    private var formSection: some View {
        VStack(spacing: 0) {
            // To Row
            toRow
            
            // Cc/Bcc Rows (expandable)
            if showCcBcc {
                ccRow
                bccRow
            }
            
            // From Row
            fromRow
            
            // Subject Row
            subjectRow
            
            Divider()
                .padding(.horizontal, 24)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    // MARK: - To Row
    
    private var toRow: some View {
        HStack(spacing: 12) {
            Text("To:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(labelColor)
                .frame(width: 50, alignment: .leading)
            
            TextField("", text: toBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(textColor)
            
            // Expand Cc/Bcc Button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCcBcc.toggle()
                }
            }) {
                Image(systemName: showCcBcc ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(labelColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showCcBcc ? "Hide Cc/Bcc" : "Show Cc/Bcc")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
    
    // MARK: - Cc Row
    
    private var ccRow: some View {
        HStack(spacing: 12) {
            Text("Cc:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(labelColor)
                .frame(width: 50, alignment: .leading)
            
            TextField("", text: ccBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(textColor)
            
            // Spacer to align with To row
            Color.clear
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    // MARK: - Bcc Row
    
    private var bccRow: some View {
        HStack(spacing: 12) {
            Text("Bcc:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(labelColor)
                .frame(width: 50, alignment: .leading)
            
            TextField("", text: bccBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(textColor)
            
            // Spacer to align with To row
            Color.clear
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    // MARK: - From Row
    
    private var fromRow: some View {
        HStack(spacing: 12) {
            Text("From:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(labelColor)
                .frame(width: 50, alignment: .leading)
            
            // Account Menu
            Menu {
                ForEach(accounts, id: \.email) { account in
                    Button(action: {
                        draft.from = account.email
                        if let defaultSig = account.defaultSignature {
                            selectedSignature = defaultSig
                        }
                        scheduleAutoSave()
                    }) {
                        HStack {
                            Text(account.name)
                            if account.email == draft.from {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentAccountName)
                        .font(.system(size: 14))
                        .foregroundColor(textColor)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(labelColor)
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Signature Button
            if !signatures.isEmpty {
                Menu {
                    Button(action: { selectedSignature = nil }) {
                        HStack {
                            Text("None")
                            if selectedSignature == nil {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    
                    Divider()
                    
                    ForEach(signatures.keys.sorted(), id: \.self) { key in
                        Button(action: {
                            selectedSignature = key
                            updateBodyWithSignature()
                        }) {
                            HStack {
                                Text(key.capitalized)
                                if selectedSignature == key {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "signature")
                        .font(.system(size: 14))
                        .foregroundColor(labelColor)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Select Signature")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
    
    private var currentAccountName: String {
        accounts.first(where: { $0.email == draft.from })?.name ?? draft.from
    }
    
    // MARK: - Subject Row
    
    private var subjectRow: some View {
        ZStack(alignment: .leading) {
            if draft.subject.isEmpty {
                Text("Subject")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(placeholderColor)
            }
            
            TextField("", text: $draft.subject)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(textColor)
                .onChange(of: draft.subject) {
                    scheduleAutoSave()
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
    
    // MARK: - Message Editor
    
    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder
            if draft.body.isEmpty {
                Text("Message")
                    .font(.system(size: 14))
                    .foregroundColor(placeholderColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            
            // Text Editor
            TextEditor(text: $draft.body)
                .font(.system(size: 14))
                .foregroundColor(textColor)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onChange(of: draft.body) {
                    scheduleAutoSave()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .cornerRadius(8)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
    
    // MARK: - Attachments
    
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
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
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
        .padding(.horizontal, 24)
        .frame(height: 36)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Bindings
    
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
    
    private var bccBinding: Binding<String> {
        Binding(
            get: { draft.bcc.joined(separator: ", ") },
            set: { newValue in
                draft.bcc = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                scheduleAutoSave()
            }
        )
    }
    
    // MARK: - Signature Handling
    
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
    
    // MARK: - Auto-Save
    
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
    
    // MARK: - Send Email
    
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
    
    // MARK: - File Handling
    
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
    
    // MARK: - Key Monitor (for QuickLook)
    
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

// MARK: - Attachment Chip

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
        @State private var showingFilePicker = false
        @State private var draft: EmailDraft? = nil
        
        var body: some View {
            EmailComposeView(
                accounts: [
                    MailAccount(
                        name: "Test Account",
                        email: "test@example.com",
                        defaultSignature: nil
                    )
                ],
                existingDraft: nil,
                triggerSend: $triggerSend,
                showingFilePicker: $showingFilePicker,
                currentDraft: $draft,
                onDismiss: {}
            )
        }
    }
    
    return PreviewWrapper()
        .frame(width: 700, height: 600)
}
