//
//  EmailDetailView.swift
//  Durian
//
//  Modern email detail view with chat-style cards for reply threads
//  Uses ThreadMessage data from CLI instead of HTML parsing
//

import SwiftUI

// MARK: - Email Detail View

struct EmailDetailView: View {
    let email: MailMessage
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onLoadBody: () -> Void
    
    // MARK: - State
    
    @State private var isDetailsExpanded: Bool = false
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
        .onChange(of: email.id) { _ in
            isDetailsExpanded = false
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
                        isDetailsExpanded: index == 0 ? $isDetailsExpanded : .constant(false),
                        showExpandableDetails: index == 0,
                        email: email,
                        contentHeight: bindingForMessageId(message.id),
                        onReply: onReply,
                        onReplyAll: onReplyAll,
                        onForward: onForward
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
                AvatarView(name: email.from, size: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(extractName(from: email.from))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.Detail.textPrimary)
                    
                    Text("Details")
                        .font(.system(size: 14))
                        .foregroundColor(Color.Detail.textSecondary)
                }
                
                Spacer()
                
                Text(email.date)
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
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1)
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
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1)
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
            .background(Color.white)
            .cornerRadius(10)
            .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 32)
    }
    
    // MARK: - Header Section
    
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
        }
    }
    
    // MARK: - Action Footer
    
    @ViewBuilder
    private var actionFooter: some View {
        HStack {
            Spacer()
            
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
        .padding(.top, 8)
    }
    
    // MARK: - Helper Methods
    
    /// Extract display name from email format
    /// "Julian Schenker <julian@example.com>" -> "Julian Schenker"
    private func extractName(from: String) -> String {
        if let range = from.range(of: "<") {
            let namePart = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !namePart.isEmpty {
                return namePart
            }
        }
        if from.contains("@") {
            if let atIndex = from.firstIndex(of: "@") {
                return String(from[..<atIndex])
            }
        }
        return from
    }
}

// MARK: - Thread Message Card View

/// A single message card in the thread view - uses ThreadMessage from CLI
struct ThreadMessageCardView: View {
    let message: ThreadMessage
    let isFirst: Bool
    let isLast: Bool
    @Binding var isDetailsExpanded: Bool
    let showExpandableDetails: Bool
    let email: MailMessage  // Parent email for expanded details
    @Binding var contentHeight: CGFloat
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            senderRow
            
            if showExpandableDetails && isDetailsExpanded {
                expandedDetails
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
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 32)
        .padding(.top, isFirst ? 24 : 0)
        .padding(.bottom, isLast ? 32 : 16)
    }
    
    // MARK: - Sender Row
    
    @ViewBuilder
    private var senderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: message.from, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(extractName(from: message.from))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.Detail.textPrimary)
                
                // Expandable details chevron only on first card
                if showExpandableDetails {
                    HStack(spacing: 4) {
                        Text("Details")
                            .font(.system(size: 14))
                            .foregroundColor(Color.Detail.textSecondary)
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.Detail.textSecondary)
                            .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isDetailsExpanded)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDetailsExpanded.toggle()
                        }
                    }
                }
            }
            
            Spacer()
            
            Text(message.date)
                .font(.system(size: 14))
                .foregroundColor(Color.Detail.textTertiary)
                .lineLimit(1)
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
                .frame(width: 70, alignment: .trailing)
            
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
        .padding(.top, 8)
    }
    
    // MARK: - Helper Methods
    
    private func extractName(from: String) -> String {
        if let range = from.range(of: "<") {
            let namePart = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !namePart.isEmpty {
                return namePart
            }
        }
        if from.contains("@") {
            if let atIndex = from.firstIndex(of: "@") {
                return String(from[..<atIndex])
            }
        }
        return from
    }
}
