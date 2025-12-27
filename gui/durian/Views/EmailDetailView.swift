//
//  EmailDetailView.swift
//  Durian
//
//  Modern email detail view with card layout, quote collapsing, and inline actions
//  Based on Figma design
//

import SwiftUI

struct EmailDetailView: View {
    let email: MailMessage
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void
    let onLoadBody: () -> Void
    
    // MARK: - State
    
    @State private var isDetailsExpanded: Bool = false
    @State private var isQuotedExpanded: Bool = false
    @State private var webViewHeight: CGFloat = 100
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                bodyCard
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
            isQuotedExpanded = false
            webViewHeight = 100
        }
    }
    
    // MARK: - Header Section
    
    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(email.subject)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Color.Detail.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 32)
            
            Divider()
                .background(Color.Detail.border)
        }
    }
    
    // MARK: - Body Card
    
    @ViewBuilder
    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            senderRow
            
            if isDetailsExpanded {
                expandedDetails
            }
            
            bodyContent
            
            actionFooter
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(Color.white)
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 32)
    }
    
    // MARK: - Sender Row
    
    @ViewBuilder
    private var senderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: email.from, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(extractName(from: email.from))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.Detail.textPrimary)
                
                // "To: X" with chevron
                HStack(spacing: 4) {
                    Text("To: \(formatRecipients(email.to))")
                        .font(.system(size: 14))
                        .foregroundColor(Color.Detail.textSecondary)
                        .lineLimit(1)
                    
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
            
            Spacer()
            
            Text(formatDate(email.date))
                .font(.system(size: 14))
                .foregroundColor(Color.Detail.textTertiary)
        }
    }
    
    // MARK: - Expanded Details
    
    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            // From (full email)
            if email.from.contains("<") || email.from.contains("@") {
                detailRow(label: "From", value: email.from)
            }
            
            // To (full)
            if let to = email.to, !to.isEmpty {
                detailRow(label: "To", value: to)
            }
            
            // Cc
            if let cc = email.cc, !cc.isEmpty {
                detailRow(label: "Cc", value: cc)
            }
            
            // Tags
            if let tags = email.tags, !tags.isEmpty {
                detailRow(label: "Tags", value: tags)
            }
            
            // Message-ID (for debugging/power users)
            if let messageId = email.messageId {
                detailRow(label: "Message-ID", value: messageId)
            }
        }
        .padding(.leading, 52) // Align with text after avatar (40 + 12)
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
    
    // MARK: - Body Content
    
    @ViewBuilder
    private var bodyContent: some View {
        switch email.bodyState {
        case .notLoaded:
            Text("Click to load")
                .foregroundColor(Color.Detail.textTertiary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onLoadBody()
                }
            
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading...")
                    .foregroundColor(Color.Detail.textTertiary)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
            
        case .loaded(let body, _):
            loadedBodyContent(body: body)
            
        case .failed(let message):
            Text("Failed: \(message)")
                .foregroundColor(.red)
                .padding(.vertical, 20)
        }
    }
    
    @ViewBuilder
    private func loadedBodyContent(body: String) -> some View {
        let (primary, quoted) = splitQuotedContent(body)
        
        VStack(alignment: .leading, spacing: 12) {
            // Primary content (always visible)
            if let html = email.htmlBody, !html.isEmpty {
                // HTML emails: show WebView sized to content
                NonScrollingWebView(
                    html: html,
                    theme: SettingsManager.shared.settings.theme,
                    loadRemoteImages: SettingsManager.shared.settings.loadRemoteImages,
                    contentHeight: $webViewHeight
                )
                .frame(height: max(webViewHeight, 50))
            } else {
                // Plain text: show primary part
                Text(makeLinksClickable(primary))
                    .font(.system(size: 16))
                    .foregroundColor(Color.Detail.textBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Quoted content (collapsed by default)
                if let quoted = quoted, !quoted.isEmpty {
                    quotedContentSection(quoted: quoted)
                }
            }
        }
    }
    
    // MARK: - Quoted Content Section
    
    @ViewBuilder
    private func quotedContentSection(quoted: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toggle button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isQuotedExpanded.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isQuotedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                    Text(isQuotedExpanded ? "Hide quoted content" : "Show quoted content")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(Color.Detail.linkBlue)
            }
            .buttonStyle(.plain)
            
            // Quoted text (when expanded)
            if isQuotedExpanded {
                Text(makeLinksClickable(quoted))
                    .font(.system(size: 14))
                    .foregroundColor(Color.Detail.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(
                        Rectangle()
                            .fill(Color.Detail.border)
                            .frame(width: 3),
                        alignment: .leading
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }
    
    // MARK: - Action Footer
    
    @ViewBuilder
    private var actionFooter: some View {
        HStack {
            Spacer()
            
            HStack(spacing: 8) {
                // Reply button
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 16))
                        .foregroundColor(Color.Detail.textTertiary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help("Reply")
                
                // React button (placeholder, disabled)
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
    
    /// Split body into primary message and quoted content
    private func splitQuotedContent(_ body: String) -> (primary: String, quoted: String?) {
        let lines = body.components(separatedBy: .newlines)
        var primaryLines: [String] = []
        var quotedLines: [String] = []
        var inQuotedSection = false
        
        for (index, line) in lines.enumerated() {
            // Check for quote markers
            if !inQuotedSection {
                // "On ... wrote:" pattern
                if line.matches(pattern: "^On .+ wrote:$") {
                    inQuotedSection = true
                    quotedLines.append(line)
                    continue
                }
                
                // "---------- Forwarded message ----------"
                if line.contains("---------- Forwarded message ----------") ||
                   line.contains("----- Original Message -----") {
                    inQuotedSection = true
                    quotedLines.append(line)
                    continue
                }
                
                // Outlook style: "From: ... Sent: ..."
                if line.matches(pattern: "^From: .+") && index + 1 < lines.count &&
                   lines[index + 1].matches(pattern: "^Sent: .+") {
                    inQuotedSection = true
                    quotedLines.append(line)
                    continue
                }
                
                // Line starting with ">" (classic quoting)
                if line.hasPrefix(">") {
                    // Check if this is start of a quoted block (multiple lines)
                    let remainingLines = lines.dropFirst(index)
                    let quotedCount = remainingLines.prefix(3).filter { $0.hasPrefix(">") }.count
                    if quotedCount >= 2 {
                        inQuotedSection = true
                        quotedLines.append(line)
                        continue
                    }
                }
                
                primaryLines.append(line)
            } else {
                quotedLines.append(line)
            }
        }
        
        let primary = primaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = quotedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (primary, quoted.isEmpty ? nil : quoted)
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
