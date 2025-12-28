//
//  EmailDetailView.swift
//  Durian
//
//  Modern email detail view with chat-style cards for reply threads
//  Based on Figma design
//

import SwiftUI

// MARK: - Email Message Model

/// Represents a single message in a thread (extracted from quoted content)
struct EmailMessage: Identifiable, Equatable {
    let id: String  // Stable ID based on content hash
    let from: String
    let date: String
    let htmlContent: String
    
    init(from: String, date: String, htmlContent: String) {
        // Create stable ID from content - same content = same ID
        self.id = "\(from.hashValue)-\(date.hashValue)-\(htmlContent.hashValue)"
        self.from = from
        self.date = date
        self.htmlContent = htmlContent
    }
}

// MARK: - Email Detail View

struct EmailDetailView: View {
    let email: MailMessage
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onLoadBody: () -> Void
    
    // MARK: - State
    
    @State private var isDetailsExpanded: Bool = false
    @State private var messageHeights: [Int: CGFloat] = [:]  // Use index as key for stable IDs
    @State private var parsedMessages: [EmailMessage] = []
    
    private func parseAndCacheMessages() {
        if let html = email.htmlBody, !html.isEmpty {
            parsedMessages = splitIntoMessages(html)
        } else {
            // Plain text fallback: single message with empty HTML (will show nothing)
            parsedMessages = [EmailMessage(from: email.from, date: email.date, htmlContent: "")]
        }
    }
    
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
            parseAndCacheMessages()
        }
        .onAppear {
            // Initial parse
            if parsedMessages.isEmpty {
                parseAndCacheMessages()
            }
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
            ForEach(Array(parsedMessages.enumerated()), id: \.element.id) { index, message in
                MessageCardView(
                    message: message,
                    isFirst: index == 0,
                    isDetailsExpanded: index == 0 ? $isDetailsExpanded : .constant(false),
                    showExpandableDetails: index == 0,
                    email: email,
                    contentHeight: bindingForMessageIndex(index),
                    onReply: onReply,
                    onReplyAll: onReplyAll,
                    onForward: onForward
                )
            }
            
        case .failed(let errorMessage):
            errorCard(message: errorMessage)
        }
    }
    
    private func bindingForMessageIndex(_ index: Int) -> Binding<CGFloat> {
        Binding(
            get: { messageHeights[index] ?? 100 },
            set: { messageHeights[index] = $0 }
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
    

    
    // MARK: - Helper Methods
    
    /// Extract display name from email format
    /// "Julian Schenker <julian@example.com>" → "Julian Schenker"
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
    
    /// Format recipients for display
    private func formatRecipients(_ to: String?) -> String {
        guard let to = to, !to.isEmpty else {
            return "Unknown"
        }
        // Extract first recipient name
        let firstRecipient = to.components(separatedBy: ",").first ?? to
        return extractName(from: firstRecipient.trimmingCharacters(in: .whitespaces))
    }
    
    /// Format date for display (e.g., "18 Dec at 14:12")
    private func formatDate(_ dateString: String) -> String {
        // For now, return as-is. Could parse and reformat later.
        return dateString
    }
    
    /// Split HTML into individual messages for chat-style thread view
    /// Returns array of EmailMessage with newest first (primary message at index 0)
    private func splitIntoMessages(_ html: String) -> [EmailMessage] {
        var messages: [EmailMessage] = []
        var remainingHTML = html
        
        // First message is always from the email itself
        if let firstSplitIndex = findFirstQuoteSplit(in: remainingHTML) {
            let primaryContent = String(remainingHTML[..<firstSplitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Only add if content has actual text (not just HTML tags)
            if hasVisibleContent(primaryContent) {
                messages.append(EmailMessage(from: email.from, date: email.date, htmlContent: primaryContent))
            }
            remainingHTML = String(remainingHTML[firstSplitIndex...])
        } else {
            // No quotes found - single message
            messages.append(EmailMessage(from: email.from, date: email.date, htmlContent: html))
            return messages
        }
        
        // Parse remaining quoted messages (limit to 20 to prevent infinite loops)
        var iterations = 0
        while !remainingHTML.isEmpty && iterations < 20 {
            iterations += 1
            
            // Extract From and Date from quote header
            let (from, date) = extractQuoteHeader(from: remainingHTML)
            
            // Find next quote split or use rest of content
            if let nextSplit = findFirstQuoteSplit(in: remainingHTML, skipFirst: true) {
                let content = String(remainingHTML[..<nextSplit]).trimmingCharacters(in: .whitespacesAndNewlines)
                if hasVisibleContent(content) {
                    messages.append(EmailMessage(from: from, date: date, htmlContent: content))
                }
                remainingHTML = String(remainingHTML[nextSplit...])
            } else {
                // Last message
                let finalContent = remainingHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                if hasVisibleContent(finalContent) {
                    messages.append(EmailMessage(from: from, date: date, htmlContent: finalContent))
                }
                break
            }
        }
        
        // If no messages were created (all empty), return the original as single message
        if messages.isEmpty {
            messages.append(EmailMessage(from: email.from, date: email.date, htmlContent: html))
        }
        
        return messages
    }
    
    /// Check if HTML content has visible text (not just empty tags)
    private func hasVisibleContent(_ html: String) -> Bool {
        // Strip HTML tags and check if there's actual content
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.count > 10  // Need at least 10 chars of actual content
    }
    
    /// Find the first quote marker position in HTML
    private func findFirstQuoteSplit(in html: String, skipFirst: Bool = false) -> String.Index? {
        let searchStart: String.Index
        
        // If skipping first, move past initial content to avoid matching the current header
        if skipFirst {
            guard html.count > 100 else { return nil }
            searchStart = html.index(html.startIndex, offsetBy: 100)
        } else {
            searchStart = html.startIndex
        }
        
        // Quote patterns in order of priority: (pattern, needsContextCheck)
        let patterns: [(String, Bool)] = [
            (#"<div[^>]*class="[^"]*(gmail_quote|gmail_extra|yahoo_quoted|ms-outlook-mobile-reference-message)[^"]*"[^>]*>"#, false),
            ("<blockquote", false),
            (#"<div[^>]*style="[^"]*border-top:\s*solid[^"]*"[^>]*>"#, true),
            (#"<div[^>]*style="[^"]*border-style:\s*solid\s+none\s+none[^"]*"[^>]*>"#, true),
            ("<hr", true),
        ]
        
        // Find earliest match across all patterns
        var earliestMatch: String.Index? = nil
        
        for (pattern, needsContext) in patterns {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive], range: searchStart..<html.endIndex) {
                // Check context if needed
                if needsContext && !hasQuoteHeaderAfter(html, from: range.lowerBound) {
                    continue
                }
                
                // Track earliest match
                if earliestMatch == nil || range.lowerBound < earliestMatch! {
                    earliestMatch = range.lowerBound
                }
            }
        }
        
        return earliestMatch
    }
    
    /// Extract From and Date from quote header HTML
    private func extractQuoteHeader(from html: String) -> (from: String, date: String) {
        var extractedFrom = "Unknown"
        var extractedDate = ""
        
        // Look for "From:" or "Von:" pattern with email
        // Pattern: <b>From:</b> Name <email> or plain text
        let fromPatterns = [
            #"<b>(?:From|Von):\s*</b>\s*([^<]+(?:<[^>]+>[^<]*)?)"#,
            #"<span[^>]*>(?:From|Von):\s*</span>\s*([^<]+)"#,
            #">(?:From|Von):\s*</?\w*>?\s*([^<]+<[^>]+>)"#,
        ]
        
        for pattern in fromPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                extractedFrom = String(html[range])
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        
        // Look for "Date:", "Sent:", "Gesendet:", "Datum:" pattern
        let datePatterns = [
            #"<b>(?:Date|Sent|Gesendet|Datum):\s*</b>\s*([^<]+)"#,
            #"<span[^>]*>(?:Date|Sent|Gesendet|Datum):\s*</span>\s*([^<]+)"#,
            #">(?:Date|Sent|Gesendet|Datum):\s*([^<]+)<"#,
        ]
        
        for pattern in datePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                extractedDate = String(html[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        
        return (extractedFrom, extractedDate)
    }
    
    /// Check if quote header (From:/Von:) appears after a divider
    private func hasQuoteHeaderAfter(_ html: String, from index: String.Index) -> Bool {
        let searchRange = String(html[index...].prefix(1000))
        
        let headerPatterns = [
            #"<b>(From|Von):</b>"#,
            #"<span[^>]*>(From|Von):</span>"#,
            #">\s*(From|Von):\s*"#,
        ]
        
        for pattern in headerPatterns {
            if searchRange.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
    
    /// Convert URLs in text to clickable links
    private func makeLinksClickable(_ text: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        // HTTP/HTTPS URLs
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
        
        return attributedString
    }
}

// MARK: - String Extension for Regex Matching

private extension String {
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(self.startIndex..., in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}

// MARK: - Message Card View

/// A single message card in the thread view
struct MessageCardView: View {
    let message: EmailMessage
    let isFirst: Bool
    @Binding var isDetailsExpanded: Bool
    let showExpandableDetails: Bool
    let email: MailMessage
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
            
            // HTML Content (only render if not empty)
            if !message.htmlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NonScrollingWebView(
                    html: message.htmlContent,
                    theme: SettingsManager.shared.settings.theme,
                    loadRemoteImages: SettingsManager.shared.settings.loadRemoteImages,
                    contentHeight: $contentHeight
                )
                .frame(height: max(contentHeight, 50))
            }
            
            // Action footer only on first card
            if isFirst {
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
        .padding(.bottom, 16)
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
    
    // MARK: - Expanded Details (only for first card)
    
    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if email.from.contains("<") || email.from.contains("@") {
                detailRow(label: "From", value: email.from)
            }
            
            if let to = email.to, !to.isEmpty {
                detailRow(label: "To", value: to)
            }
            
            if let cc = email.cc, !cc.isEmpty {
                detailRow(label: "Cc", value: cc)
            }
            
            if let tags = email.tags, !tags.isEmpty {
                detailRow(label: "Tags", value: tags)
            }
            
            if let messageId = email.messageId {
                detailRow(label: "Message-ID", value: messageId)
            }
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
