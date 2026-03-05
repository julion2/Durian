//
//  EmailDetailView.swift
//  Durian
//
//  Modern email detail view with chat-style cards for reply threads
//  Uses ThreadMessage data from CLI instead of HTML parsing
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

// MARK: - Email Detail View

struct EmailDetailView: View {
    let email: MailMessage
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onLoadBody: () -> Void
    var onEditDraft: (() -> Void)? = nil
    var currentFolder: String? = nil
    var onAddTag: ((String) -> Void)? = nil
    var onRemoveTag: ((String) -> Void)? = nil
    
    // MARK: - State
    
    @State private var messageHeights: [String: CGFloat] = [:]  // Use message ID as key
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                messageCards
            }
        }
        .overlayScrollbars()
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            // Auto-load body if not loaded
            switch email.bodyState {
            case .notLoaded, .failed:
                onLoadBody()
            case .loading, .loaded:
                break
            }
        }
        // Reset state when email changes
        .onChange(of: email.id) {
            messageHeights = [:]
        }
    }
    
    // MARK: - Message Cards (Chat-Style Thread View)
    
    @ViewBuilder
    private var messageCards: some View {
        switch email.bodyState {
        case .notLoaded:
            loadingCard(text: "Click to load") {
                onLoadBody()
            }
            
        case .loading:
            loadingCard(text: nil, action: nil)
            
        case .loaded:
            // Use thread messages from CLI if available
            if let messages = email.threadMessages, !messages.isEmpty {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    ThreadMessageCardView(
                        message: message,
                        isFirst: index == 0,
                        isLast: index == 0,  // Newest message (first) gets reply button
                        email: email,
                        contentHeight: bindingForMessageId(message.id),
                        onReply: onReply,
                        onReplyAll: onReplyAll,
                        onForward: onForward,
                        onEditDraft: onEditDraft
                    )
                }
            } else {
                // Fallback: single message with body/html directly from email
                singleMessageFallback
            }
            
        case .failed(let errorMessage):
            errorCard(message: errorMessage)
        }
    }
    
    @ViewBuilder
    private var singleMessageFallback: some View {
        // Use htmlBody if available, otherwise body
        let htmlContent = email.htmlBody ?? ""
        let textContent = email.body ?? ""
        
        VStack(alignment: .leading, spacing: 16) {
            // Sender row
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: email.from, email: email.from, size: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(extractName(from: email.from))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.Detail.textPrimary)
                    
                    Text("Details")
                        .font(.system(size: 14))
                        .foregroundColor(Color.Detail.textSecondary)
                }
                
                Spacer()
                
                Text(formatDate(email.date))
                    .font(.system(size: 14))
                    .foregroundColor(Color.Detail.textTertiary)
                    .lineLimit(1)
            }
            
            // Content
            if !htmlContent.isEmpty {
                NonScrollingWebView(
                    html: htmlContent,
                    theme: SettingsManager.shared.settings.theme,
                    loadRemoteImages: SettingsManager.shared.settings.loadRemoteImages,
                    emailId: email.id,
                    contentHeight: bindingForMessageId("fallback")
                )
                .frame(height: max(messageHeights["fallback"] ?? 100, 50))
            } else if !textContent.isEmpty {
                Text(textContent)
                    .font(.system(size: 14))
                    .foregroundColor(Color.Detail.textPrimary)
                    .textSelection(.enabled)
            }
            
            // Action footer
            actionFooter
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(Color.Detail.cardBackground)
        .cornerRadius(10)
        .shadow(color: Color.primary.opacity(0.1), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }
    
    private func bindingForMessageId(_ id: String) -> Binding<CGFloat> {
        Binding(
            get: { messageHeights[id] ?? 100 },
            set: { messageHeights[id] = $0 }
        )
    }
    
    @ViewBuilder
    private func loadingCard(text: String?, action: (() -> Void)?) -> some View {
        VStack {
            if let text = text {
                Text(text)
                    .foregroundColor(Color.Detail.textTertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        action?()
                    }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .foregroundColor(Color.Detail.textTertiary)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(Color.Detail.cardBackground)
        .cornerRadius(10)
        .shadow(color: Color.primary.opacity(0.1), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }
    
    @ViewBuilder
    private func errorCard(message: String) -> some View {
        Text("Failed: \(message)")
            .foregroundColor(.red)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color.Detail.cardBackground)
            .cornerRadius(10)
            .shadow(color: Color.primary.opacity(0.1), radius: 3, x: 0, y: 1)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 32)
    }
    
    // MARK: - Header Section
    
    private var parsedTags: [String] {
        (email.tags?.split(separator: ",").map(String.init) ?? [])
            .filter { $0 != currentFolder }
    }

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(email.subject)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color.Detail.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 8)

            if !parsedTags.isEmpty || onAddTag != nil {
                TagChipsView(
                    tags: parsedTags,
                    onRemoveTag: { tag in onRemoveTag?(tag) },
                    onAddTag: { tag in onAddTag?(tag) }
                )
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
            }
        }
    }
    
    // MARK: - Action Footer

    @ViewBuilder
    private var actionFooter: some View {
        HStack {
            Spacer()

            if email.isDraft, let onEditDraft = onEditDraft {
                Button(action: onEditDraft) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                        Text("Edit Draft")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Edit Draft")
            } else {
                HStack(spacing: 8) {
                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 16))
                            .foregroundColor(Color.Detail.textTertiary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help("Reply")

                    Button(action: {}) {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 16))
                            .foregroundColor(Color.Detail.textTertiary.opacity(0.5))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .help("React (coming soon)")
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helper Methods

    /// Extract display name from email format
    /// "Julian Schenker <julian@example.com>" -> "Julian Schenker"
    private func extractName(from: String) -> String {
        var name = from
        
        // Extract name before <email> part
        if let range = from.range(of: "<") {
            name = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        
        // Remove surrounding quotes
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        // If still empty, try to extract from email
        if name.isEmpty && from.contains("@") {
            if let atIndex = from.firstIndex(of: "@") {
                name = String(from[..<atIndex])
            }
        }
        
        return name.isEmpty ? from : name
    }
    
    /// Format RFC 2822 date string to readable format
    private func formatDate(_ dateString: String) -> String {
        // Parse RFC 2822 format: "Tue, 30 Dec 2025 17:20:47 +0100"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        
        guard let date = formatter.date(from: dateString) else {
            // Fallback: try without day name
            formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
            guard let date = formatter.date(from: dateString) else {
                return dateString // Return original if parsing fails
            }
            return formatRelativeDate(date)
        }
        
        return formatRelativeDate(date)
    }
    
    /// Format date as relative or absolute depending on age
    private func formatRelativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDateInToday(date) {
            // Today: show time only
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            // Yesterday
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "Gestern, \(formatter.string(from: date))"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
            // Within last week: show day name
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "EEEE, HH:mm"
            return formatter.string(from: date)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            // This year: show date without year
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "d. MMM, HH:mm"
            return formatter.string(from: date)
        } else {
            // Older: show full date
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "d. MMM yyyy, HH:mm"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Thread Message Card View

/// A single message card in the thread view - uses ThreadMessage from CLI
struct ThreadMessageCardView: View {
    let message: ThreadMessage
    let isFirst: Bool
    let isLast: Bool
    let email: MailMessage  // Parent email for expanded details
    @Binding var contentHeight: CGFloat
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    var onEditDraft: (() -> Void)? = nil

    // Each card manages its own expanded state
    @State private var isDetailsExpanded: Bool = false
    @State private var downloadStates: [Int: AttachmentDownloadState] = [:]
    @State private var selectedAttachmentId: Int? = nil
    @State private var spaceMonitor: AnyObject? = nil

    /// Non-inline attachments for this message
    private var displayAttachments: [AttachmentInfo] {
        (message.attachments ?? []).filter { $0.disposition != "inline" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            senderRow

            if isDetailsExpanded {
                expandedDetails
            }

            // Attachment bar
            if !displayAttachments.isEmpty {
                attachmentBar
            }

            // Content: prefer HTML, fallback to plain text
            if let html = message.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NonScrollingWebView(
                    html: html,
                    theme: SettingsManager.shared.settings.theme,
                    loadRemoteImages: SettingsManager.shared.settings.loadRemoteImages,
                    emailId: message.id,
                    contentHeight: $contentHeight
                )
                .frame(height: max(contentHeight, 50))
            } else if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(message.body)
                    .font(.system(size: 14))
                    .foregroundColor(Color.Detail.textPrimary)
                    .textSelection(.enabled)
            }

            // Action footer only on last (newest) card
            if isLast {
                actionFooter
            }
        }
        // Click anywhere outside attachment chips clears selection
        .onTapGesture { selectedAttachmentId = nil }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(Color.Detail.cardBackground)
        .cornerRadius(10)
        .shadow(color: Color.primary.opacity(0.1), radius: 3, x: 0, y: 1)
        .padding(.leading, isOwnMessage() ? 56 : 32)  // Indent own messages (24pt extra)
        .padding(.trailing, 32)
        .padding(.top, isFirst ? 24 : 0)
        .padding(.bottom, isLast ? 32 : 16)
    }
    
    // MARK: - Own Message Detection
    
    /// Check if message is from one of the configured accounts
    private func isOwnMessage() -> Bool {
        let fromEmail = extractEmail(from: message.from).lowercased()
        let ownEmails = ConfigManager.shared.getAccounts().map { $0.email.lowercased() }
        return ownEmails.contains(fromEmail)
    }
    
    /// Extract email address from "Name <email>" format
    private func extractEmail(from: String) -> String {
        if let start = from.range(of: "<"), let end = from.range(of: ">") {
            return String(from[start.upperBound..<end.lowerBound])
        }
        return from
    }
    
    // MARK: - Sender Row
    
    @ViewBuilder
    private var senderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: message.from, email: message.from, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(extractName(from: message.from))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.Detail.textPrimary)
                
                // To/Cc line with expand chevron
                recipientsRow
            }
            
            Spacer()
            
            Text(formatDate(message.date))
                .font(.system(size: 14))
                .foregroundColor(Color.Detail.textTertiary)
                .lineLimit(1)
        }
    }
    
    // MARK: - Recipients Row (To/Cc)
    
    @ViewBuilder
    private var recipientsRow: some View {
        HStack(spacing: 4) {
            // To recipients
            if let to = message.to, !to.isEmpty {
                Text("To:")
                    .foregroundColor(Color.Detail.textTertiary)
                Text(extractRecipientNames(to).joined(separator: ", "))
                    .foregroundColor(Color.Detail.textSecondary)
                    .lineLimit(1)
            }
            
            // Cc recipients (only if present)
            if let cc = message.cc, !cc.isEmpty {
                Text("Cc:")
                    .foregroundColor(Color.Detail.textTertiary)
                Text(extractRecipientNames(cc).joined(separator: ", "))
                    .foregroundColor(Color.Detail.textSecondary)
                    .lineLimit(1)
            }
            
            // Expand chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.Detail.textSecondary)
                .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isDetailsExpanded)
        }
        .font(.system(size: 14))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isDetailsExpanded.toggle()
            }
        }
    }
    
    /// Extract clean names from recipient list
    /// "\"Lisa Neumayer | kmpro\" <l@x.de>, \"Max Müller\" <m@x.de>" → ["Lisa Neumayer", "Max Müller"]
    private func extractRecipientNames(_ recipients: String) -> [String] {
        // Split by comma, but be careful with commas inside quotes
        let parts = recipients.components(separatedBy: ">,")
        
        return parts.compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            
            // Add back the ">" if it was removed by split (except for last part)
            let fullPart = trimmed.hasSuffix(">") ? trimmed : trimmed + ">"
            
            // Use extractName to get clean name
            let name = extractName(from: fullPart)
            
            // Remove "| domain" suffix if present
            if let pipeRange = name.range(of: " |") {
                return String(name[..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            
            return name.isEmpty ? nil : name
        }
    }
    
    // MARK: - Attachment Bar

    @ViewBuilder
    private var attachmentBar: some View {
        FlowLayout(spacing: 8) {
            ForEach(displayAttachments, id: \.partId) { attachment in
                attachmentChip(attachment)
            }
        }
        .onAppear { spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, selectedAttachmentId != nil else { return event }
            // Toggle: close if already showing, otherwise open preview
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.close()
            } else if let attachment = displayAttachments.first(where: { $0.partId == selectedAttachmentId }) {
                previewAttachment(attachment)
            }
            return nil
        } as AnyObject? }
        .onDisappear { if let monitor = spaceMonitor { NSEvent.removeMonitor(monitor); spaceMonitor = nil } }
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: AttachmentInfo) -> some View {
        let state = downloadStates[attachment.partId] ?? .notDownloaded
        let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
        let isFailed = if case .failed = state { true } else { false }
        let isDownloading = if case .downloading = state { true } else { false }
        let isSelected = selectedAttachmentId == attachment.partId

        HStack(spacing: 8) {
            // File type icon in rounded rect box
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isFailed ? Color.red.opacity(0.08) : Color(NSColor.separatorColor).opacity(0.3))
                    .frame(width: 28, height: 28)
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(nsImage: fileTypeIcon(for: attachment))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeLabel)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? Color.accentColor.opacity(0.8) : Color.Detail.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isFailed ? Color.red.opacity(0.12) :
            isSelected ? Color.accentColor.opacity(0.1) :
            Color(NSColor.controlBackgroundColor)
        )
        .foregroundColor(isFailed ? .red : isSelected ? Color.accentColor : Color.Detail.textSecondary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFailed ? Color.red.opacity(0.3) :
                    isSelected ? Color.accentColor.opacity(0.5) :
                    Color(NSColor.separatorColor).opacity(0.5),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDownloading else { return }
            selectedAttachmentId = isSelected ? nil : attachment.partId
        }
        .contextMenu {
            Button("Save to Downloads") {
                saveToDownloads(attachment)
            }
            Button("Save As...") {
                saveAttachment(attachment)
            }
        }
    }

    private func fileTypeIcon(for attachment: AttachmentInfo) -> NSImage {
        let utType = UTType(mimeType: attachment.contentType)
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
            ?? .data
        return NSWorkspace.shared.icon(for: utType)
    }

    private func previewAttachment(_ attachment: AttachmentInfo) {
        downloadStates[attachment.partId] = .downloading(progress: 0)

        Task {
            guard let data = await fetchAttachmentData(attachment) else { return }
            let emailAttachment = EmailAttachment(
                filename: attachment.filename,
                mimeType: attachment.contentType,
                data: data
            )
            QuickLookManager.shared.showPreview(for: [emailAttachment], startingAt: 0)
            downloadStates[attachment.partId] = .notDownloaded
        }
    }

    private func saveToDownloads(_ attachment: AttachmentInfo) {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let saveURL = downloadsURL.appendingPathComponent(attachment.filename)

        downloadStates[attachment.partId] = .downloading(progress: 0)

        Task {
            guard let data = await fetchAttachmentData(attachment) else { return }
            do {
                try data.write(to: saveURL)
                downloadStates[attachment.partId] = .downloaded(cachePath: saveURL.path)
                print("ATTACHMENT: Saved \(attachment.filename) to Downloads")
            } catch {
                downloadStates[attachment.partId] = .failed(error: error.localizedDescription)
                print("ATTACHMENT: Failed to write \(attachment.filename): \(error)")
                scheduleErrorClear(attachment.partId)
            }
        }
    }

    private func saveAttachment(_ attachment: AttachmentInfo) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        downloadStates[attachment.partId] = .downloading(progress: 0)

        Task {
            guard let data = await fetchAttachmentData(attachment) else { return }
            do {
                try data.write(to: saveURL)
                downloadStates[attachment.partId] = .downloaded(cachePath: saveURL.path)
                print("ATTACHMENT: Saved \(attachment.filename) to \(saveURL.path)")
            } catch {
                downloadStates[attachment.partId] = .failed(error: error.localizedDescription)
                print("ATTACHMENT: Failed to write \(attachment.filename): \(error)")
                scheduleErrorClear(attachment.partId)
            }
        }
    }

    private func fetchAttachmentData(_ attachment: AttachmentInfo) async -> Data? {
        guard let backend = AccountManager.shared.notmuchBackend else {
            downloadStates[attachment.partId] = .failed(error: "Not connected")
            scheduleErrorClear(attachment.partId)
            return nil
        }
        do {
            let (data, _) = try await backend.downloadAttachment(
                messageId: message.id,
                partId: attachment.partId
            )
            return data
        } catch {
            downloadStates[attachment.partId] = .failed(error: error.localizedDescription)
            print("ATTACHMENT: Download failed for \(attachment.filename): \(error)")
            scheduleErrorClear(attachment.partId)
            return nil
        }
    }

    private func scheduleErrorClear(_ partId: Int) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .failed = downloadStates[partId] {
                downloadStates[partId] = .notDownloaded
            }
        }
    }

    // MARK: - Expanded Details

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            // From (from message)
            if message.from.contains("<") || message.from.contains("@") {
                detailRow(label: "From", value: message.from)
            }
            
            // To (from message if available, else from parent email)
            if let to = message.to, !to.isEmpty {
                detailRow(label: "To", value: to)
            } else if let to = email.to, !to.isEmpty {
                detailRow(label: "To", value: to)
            }
            
            // Cc (from message if available, else from parent email)
            if let cc = message.cc, !cc.isEmpty {
                detailRow(label: "Cc", value: cc)
            } else if let cc = email.cc, !cc.isEmpty {
                detailRow(label: "Cc", value: cc)
            }
            
            // Tags (from message)
            if let tags = message.tags, !tags.isEmpty {
                detailRow(label: "Tags", value: tags.joined(separator: ", "))
            }
            
            // Message-ID (from message)
            detailRow(label: "Message-ID", value: message.id)
        }
        .padding(.leading, 52)
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .font(.system(size: 13))
                .foregroundColor(Color.Detail.textTertiary)
            
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Color.Detail.textSecondary)
                .textSelection(.enabled)
        }
    }
    
    // MARK: - Action Footer

    @ViewBuilder
    private var actionFooter: some View {
        HStack {
            Spacer()

            if email.isDraft, let onEditDraft = onEditDraft {
                Button(action: onEditDraft) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                        Text("Edit Draft")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Edit Draft")
            } else {
                HStack(spacing: 8) {
                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .font(.system(size: 16))
                            .foregroundColor(Color.Detail.textTertiary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help("Reply")

                    Button(action: {}) {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 16))
                            .foregroundColor(Color.Detail.textTertiary.opacity(0.5))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .help("React (coming soon)")
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helper Methods

    private func extractName(from: String) -> String {
        var name = from
        
        // Extract name before <email> part
        if let range = from.range(of: "<") {
            name = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        
        // Remove surrounding quotes
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        
        // If still empty, try to extract from email
        if name.isEmpty && from.contains("@") {
            if let atIndex = from.firstIndex(of: "@") {
                name = String(from[..<atIndex])
            }
        }
        
        return name.isEmpty ? from : name
    }
    
    /// Format RFC 2822 date string to readable format
    private func formatDate(_ dateString: String) -> String {
        // Parse RFC 2822 format: "Tue, 30 Dec 2025 17:20:47 +0100"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        
        guard let date = formatter.date(from: dateString) else {
            // Fallback: try without day name
            formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
            guard let date = formatter.date(from: dateString) else {
                return dateString // Return original if parsing fails
            }
            return formatRelativeDate(date)
        }
        
        return formatRelativeDate(date)
    }
    
    /// Format date as relative or absolute depending on age
    private func formatRelativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDateInToday(date) {
            // Today: show time only
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            // Yesterday
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "Gestern, \(formatter.string(from: date))"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
            // Within last week: show day name
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "EEEE, HH:mm"
            return formatter.string(from: date)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            // This year: show date without year
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "d. MMM, HH:mm"
            return formatter.string(from: date)
        } else {
            // Older: show full date
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "d. MMM yyyy, HH:mm"
            return formatter.string(from: date)
        }
    }
}
