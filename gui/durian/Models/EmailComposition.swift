//
//  EmailComposition.swift
//  Durian
//
//  Email composition and draft models
//

import Foundation

struct EmailDraft: Identifiable, Codable, Equatable {
    let id: UUID
    var from: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String  // User's editable text
    var isHTML: Bool
    var inReplyTo: String?
    var references: String?
    var createdAt: Date
    var modifiedAt: Date
    var uid: UInt32?
    var accountId: String?
    var attachments: [EmailAttachment] = []
    
    /// IMAP Message-ID (set after saving to server)
    var messageId: String?
    
    /// Quoted/forwarded content (read-only, shown as preview)
    var quotedContent: String?
    /// Whether quotedContent is HTML
    var quotedIsHTML: Bool = false

    /// HTML signature (kept separate from body, combined at send time)
    var htmlSignature: String?

    /// HTML body from the rich text editor (formatted user content, excluding signature)
    var htmlBody: String?

    init(
        id: UUID = UUID(),
        from: String,
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = "",
        isHTML: Bool = false,
        inReplyTo: String? = nil,
        references: String? = nil,
        messageId: String? = nil,
        quotedContent: String? = nil,
        quotedIsHTML: Bool = false,
        htmlSignature: String? = nil,
        htmlBody: String? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.isHTML = isHTML
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageId = messageId
        self.quotedContent = quotedContent
        self.quotedIsHTML = quotedIsHTML
        self.htmlSignature = htmlSignature
        self.htmlBody = htmlBody
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
    
    mutating func updateModifiedDate() {
        modifiedAt = Date()
    }
    
    var hasRecipients: Bool {
        return !to.isEmpty || !cc.isEmpty || !bcc.isEmpty
    }
    
    var isValid: Bool {
        return hasRecipients && !subject.isEmpty
    }
    
    /// Whether the user has typed any actual content (excludes signature, quoted content).
    /// Subject-only changes are intentionally not counted — subject-only replies aren't a real use case.
    var hasUserContent: Bool {
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let html = htmlBody {
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var hasAttachments: Bool {
        return !attachments.isEmpty
    }
    
    var totalAttachmentSize: Int64 {
        attachments.reduce(0) { $0 + Int64($1.data.count) }
    }
}

struct EmailAttachment: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data
    
    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
    
    var size: Int64 {
        Int64(data.count)
    }
    
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum EmailSendingError: Error, LocalizedError {
    case noSMTPConfiguration
    case authenticationFailed
    case sendFailed(String)
    case invalidRecipients
    case invalidEmailFormat([String])
    case connectionFailed
    
    var errorDescription: String? {
        switch self {
        case .noSMTPConfiguration:
            return "SMTP server not configured for this account"
        case .authenticationFailed:
            return "Failed to authenticate with SMTP server"
        case .sendFailed(let message):
            return "Failed to send email: \(message)"
        case .invalidRecipients:
            return "Please provide at least one recipient"
        case .invalidEmailFormat(let emails):
            return "Invalid email addresses: \(emails.joined(separator: ", "))"
        case .connectionFailed:
            return "Failed to connect to SMTP server"
        }
    }
    
    /// Returns the list of invalid emails if this is an invalidEmailFormat error
    var invalidEmails: [String]? {
        if case .invalidEmailFormat(let emails) = self {
            return emails
        }
        return nil
    }
}

// MARK: - Email Helper

enum EmailHelper {
    /// Simple email validation — handles both bare emails and "Name <email>" format
    static func isValidEmail(_ input: String) -> Bool {
        let email = cleanEmail(input)
        guard let atIndex = email.firstIndex(of: "@") else { return false }
        let afterAt = email[email.index(after: atIndex)...]
        return afterAt.contains(".") && !afterAt.hasPrefix(".") && !afterAt.hasSuffix(".")
    }
    
    /// Clean email address - extract from "Name <email>" format if needed
    static func cleanEmail(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        
        // Standard format: "Name <email>"
        if let start = trimmed.firstIndex(of: "<"),
           let end = trimmed.firstIndex(of: ">"),
           start < end {
            let email = String(trimmed[trimmed.index(after: start)..<end])
            if email.contains("@") {
                return email.trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Malformed: "<Name> email" - get last word with @
        let parts = trimmed.components(separatedBy: .whitespaces)
        if let lastPart = parts.last, lastPart.contains("@") {
            return lastPart
        }
        
        return trimmed
    }
    
    /// Validate all recipients and return list of invalid emails
    static func validateRecipients(_ recipients: [String]) -> [String] {
        return recipients.filter { !isValidEmail($0) }
    }
}

// MARK: - Reply/Forward Helpers

extension EmailDraft {
    /// Create a draft for editing an existing draft message
    static func createFromDraft(message: MailMessage) -> EmailDraft {
        let toAddresses = message.to.map { parseEmailList($0) } ?? []
        let ccAddresses = message.cc.map { parseEmailList($0) } ?? []

        return EmailDraft(
            from: message.from,
            to: toAddresses,
            cc: ccAddresses,
            subject: message.subject,
            body: message.body ?? "",
            isHTML: message.htmlBody != nil && !(message.htmlBody?.isEmpty ?? true),
            messageId: message.messageId,
            htmlBody: message.htmlBody
        )
    }

    /// Returns the message ID of the message that should be quoted in a reply.
    /// Used to lazy-load the original (unstripped) body before creating the draft.
    static func replyTargetMessageId(for message: MailMessage, fromAccount: String) -> String? {
        return findReplyTarget(message: message, fromAccount: fromAccount).bodySourceId
    }

    /// Create a reply draft from a mail message
    /// - Parameters:
    ///   - message: The original message to reply to
    ///   - fromAccount: The email address to send from
    ///   - originalBody: Optional unstripped body fetched via lazy-loading (text, html).
    ///     When provided, used for quoting instead of the stripped thread body.
    /// - Returns: A new EmailDraft configured as a reply
    static func createReply(from message: MailMessage, fromAccount: String,
                            originalBody: (body: String, html: String?)? = nil) -> EmailDraft {
        let target = findReplyTarget(message: message, fromAccount: fromAccount)

        // Fallback if target.from has no email (e.g. cache restored without headers)
        var replyTo = target.from
        if !replyTo.contains("@") {
            if let threadFrom = message.threadMessages?.last?.from, threadFrom.contains("@") {
                replyTo = threadFrom
            }
        }

        // Build subject with Re: prefix (avoid Re: Re: Re:)
        let subject = message.subject.hasPrefix("Re:")
            ? message.subject
            : "Re: \(message.subject)"

        // Build references chain from target message
        var references = target.references ?? ""
        if let messageId = target.messageId, !messageId.isEmpty {
            if !references.isEmpty {
                references += " "
            }
            references += messageId
        }

        // Use original (unstripped) body for quoting if available, otherwise fall back to stripped
        let quoteBody = originalBody?.body ?? target.body
        let quoteHTML = originalBody?.html ?? target.html
        let hasHTML = quoteHTML != nil && !quoteHTML!.isEmpty

        // Quote the target body (use HTML if available)
        let quotedBody = hasHTML
            ? quoteBodyHTML(quoteHTML!, from: target.from, date: target.date)
            : Self.quoteBody(quoteBody ?? "", from: target.from, date: target.date)

        return EmailDraft(
            from: fromAccount,
            to: [replyTo],
            subject: subject,
            body: "",  // User writes here
            inReplyTo: target.messageId,
            references: references.isEmpty ? nil : references,
            quotedContent: quotedBody,
            quotedIsHTML: hasHTML
        )
    }
    
    /// Create a reply-all draft from a mail message
    /// - Parameters:
    ///   - message: The original message to reply to
    ///   - fromAccount: The email address to send from
    /// - Returns: A new EmailDraft configured as a reply-all
    static func createReplyAll(from message: MailMessage, fromAccount: String,
                               originalBody: (body: String, html: String?)? = nil) -> EmailDraft {
        var draft = createReply(from: message, fromAccount: fromAccount, originalBody: originalBody)
        let target = findReplyTarget(message: message, fromAccount: fromAccount)

        // Build CC from the TARGET message's To/CC (not thread-level fields,
        // which may be from the user's own sent message)
        var ccRecipients: [String] = []

        // Add target's To recipients (except the reply-to sender and self)
        if let originalTo = target.to {
            let toAddresses = parseEmailList(originalTo)
            let senderEmail = extractEmail(from: draft.to.first ?? target.from).lowercased()
            for address in toAddresses {
                let emailOnly = extractEmail(from: address).lowercased()
                if emailOnly != fromAccount.lowercased() && emailOnly != senderEmail {
                    ccRecipients.append(address)
                }
            }
        }

        // Add target's CC recipients (except self)
        if let originalCC = target.cc {
            let ccAddresses = parseEmailList(originalCC)
            for address in ccAddresses {
                let emailOnly = extractEmail(from: address).lowercased()
                if emailOnly != fromAccount.lowercased() {
                    ccRecipients.append(address)
                }
            }
        }

        draft.cc = ccRecipients
        return draft
    }
    
    /// Create a forward draft from a mail message
    /// - Parameters:
    ///   - message: The original message to forward
    ///   - fromAccount: The email address to send from
    /// - Returns: A new EmailDraft configured as a forward
    static func createForward(from message: MailMessage, fromAccount: String) -> EmailDraft {
        // Build subject with Fwd: prefix
        let subject = message.subject.hasPrefix("Fwd:") 
            ? message.subject 
            : "Fwd: \(message.subject)"
        
        // Check if original was HTML
        let hasHTML = message.htmlBody != nil && !message.htmlBody!.isEmpty
        
        // Build forwarded message body (HTML or plain text)
        let forwardedBody = hasHTML 
            ? buildForwardBodyHTML(message) 
            : buildForwardBody(message)
        
        return EmailDraft(
            from: fromAccount,
            to: [],
            subject: subject,
            body: "",  // User writes here
            quotedContent: forwardedBody,
            quotedIsHTML: hasHTML
        )
    }
    
    // MARK: - Reply Target Resolution

    /// Fields needed to construct a reply from a specific thread message.
    private struct ReplyTarget {
        let bodySourceId: String?  // message ID for fetching original body
        let from: String
        let to: String?
        let cc: String?
        let date: String
        let body: String?
        let html: String?
        let messageId: String?
        let references: String?
    }

    /// Find the correct message to reply to in a thread.
    ///
    /// When the newest message in a thread was sent by the current user,
    /// replying to it would set To: to ourselves. This method finds the
    /// appropriate non-self message to reply to instead.
    private static func findReplyTarget(message: MailMessage, fromAccount: String) -> ReplyTarget {
        let accountEmail = fromAccount.lowercased()
        let newestFrom = extractEmail(from: message.from).lowercased()

        // Case 1: newest message is not from self — use as-is
        guard newestFrom == accountEmail else {
            return ReplyTarget(bodySourceId: message.threadMessages?.first?.id,
                               from: message.from, to: message.to, cc: message.cc,
                               date: message.date, body: message.body, html: message.htmlBody,
                               messageId: message.messageId, references: message.references)
        }

        // Case 2: newest is from self — find the most recent non-self message
        if let threads = message.threadMessages {
            for tm in threads {
                if extractEmail(from: tm.from).lowercased() != accountEmail {
                    return ReplyTarget(bodySourceId: tm.id,
                                       from: tm.from, to: tm.to, cc: tm.cc,
                                       date: tm.date, body: tm.body, html: tm.html,
                                       messageId: tm.message_id, references: tm.references)
                }
            }
        }

        // Case 3: all messages from self — reply to original recipients
        return ReplyTarget(bodySourceId: message.threadMessages?.first?.id,
                           from: message.to ?? message.from, to: message.to, cc: message.cc,
                           date: message.date, body: message.body, html: message.htmlBody,
                           messageId: message.messageId, references: message.references)
    }

    // MARK: - Private Helpers

    /// Extract email address from various formats:
    /// - "Name <email>" -> "email"
    /// - "<Name> email" -> "email"  (malformed but common)
    /// - "email" -> "email"
    private static func extractEmail(from address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        
        // Standard format: "Name <email>"
        if let start = trimmed.firstIndex(of: "<"),
           let end = trimmed.firstIndex(of: ">"),
           start < end {
            let email = String(trimmed[trimmed.index(after: start)..<end])
            // Validate it looks like an email
            if email.contains("@") {
                return email.trimmingCharacters(in: .whitespaces)
            }
        }
        
        // Malformed format: "<Name> email" - extract last word if it contains @
        let parts = trimmed.components(separatedBy: .whitespaces)
        if let lastPart = parts.last, lastPart.contains("@") {
            return lastPart
        }
        
        // Just return as-is (probably already an email)
        return trimmed
    }
    
    /// Format email address for display - extract clean email
    /// Handles various malformed formats and returns just the email
    private static func cleanEmailAddress(_ address: String) -> String {
        return extractEmail(from: address)
    }
    
    /// Parse comma-separated email list, handling commas in unquoted display names
    /// e.g. "van der Zee, Warden (EBV) <a@b.com>, c@d.com" → ["van der Zee, Warden (EBV) <a@b.com>", "c@d.com"]
    private static func parseEmailList(_ list: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuotes = false
        var inAngleBracket = false

        for char in list {
            switch char {
            case "\"":
                inQuotes.toggle()
                current.append(char)
            case "<":
                inAngleBracket = true
                current.append(char)
            case ">":
                inAngleBracket = false
                current.append(char)
            case ",":
                if inQuotes || inAngleBracket {
                    current.append(char)
                } else if current.contains("<") && current.contains(">") {
                    // Complete "Name <email>" address — comma is a separator
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { results.append(trimmed) }
                    current = ""
                } else if current.contains("@") {
                    // Plain email without angle brackets — comma is a separator
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { results.append(trimmed) }
                    current = ""
                } else {
                    // No complete address yet — comma is part of display name
                    current.append(char)
                }
            default:
                current.append(char)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { results.append(trimmed) }
        return results
    }
    
    /// Quote body text for reply (plain text)
    private static func quoteBody(_ body: String, from: String, date: String) -> String {
        var quoted = "On \(date), \(from) wrote:\n"
        
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            quoted += "> \(line)\n"
        }
        
        return quoted
    }
    
    /// Quote body HTML for reply (preserves formatting)
    private static func quoteBodyHTML(_ html: String, from: String, date: String) -> String {
        return """
        <div style="color: #555;">
        <p style="font-size: 12px; color: #888; margin-bottom: 8px;">On \(escapeHTML(date)), \(escapeHTML(from)) wrote:</p>
        <div style="border-left: 2px solid #ccc; padding-left: 10px; margin-left: 5px;">
        \(html)
        </div>
        </div>
        """
    }
    
    /// Build forwarded message body with original headers (plain text)
    private static func buildForwardBody(_ message: MailMessage) -> String {
        var body = "---------- Forwarded message ----------\n"
        body += "From: \(message.from)\n"
        if let to = message.to {
            body += "To: \(to)\n"
        }
        body += "Date: \(message.date)\n"
        body += "Subject: \(message.subject)\n"
        body += "\n"
        body += message.body ?? ""
        return body
    }
    
    /// Build forwarded message body with original headers (HTML)
    private static func buildForwardBodyHTML(_ message: MailMessage) -> String {
        var html = """
        <div style="color: #666;">
        <p style="font-size: 12px; color: #888; margin-bottom: 8px;">---------- Forwarded message ----------</p>
        <p style="font-size: 12px; margin-bottom: 8px;">
        <b>From:</b> \(escapeHTML(message.from))<br>
        """
        if let to = message.to {
            html += "<b>To:</b> \(escapeHTML(to))<br>"
        }
        html += """
        <b>Date:</b> \(escapeHTML(message.date))<br>
        <b>Subject:</b> \(escapeHTML(message.subject))
        </p>
        <hr style="border: none; border-top: 1px solid #ccc; margin: 8px 0;">
        \(message.htmlBody ?? message.body ?? "")
        </div>
        """
        return html
    }
    
    /// Escape HTML special characters
    private static func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

class DraftManager {
    static let shared = DraftManager()
    
    private let draftsDirectory: URL
    
    private init() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        draftsDirectory = homeURL.appendingPathComponent(".config/durian/drafts")
        createDraftsDirectoryIfNeeded()
    }
    
    private func createDraftsDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: draftsDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
                Log.debug("DRAFTING", "Created drafts directory at: \(draftsDirectory.path)")
            } catch {
                Log.error("DRAFTING", "Failed to create drafts directory: \(error)")
            }
        }
    }
    
    func saveDraft(_ draft: EmailDraft) {
        let fileURL = draftsDirectory.appendingPathComponent("\(draft.id.uuidString).json")

        var cleaned = draft
        cleaned.to = Self.filterValidAddresses(draft.to)
        cleaned.cc = Self.filterValidAddresses(draft.cc)
        cleaned.bcc = Self.filterValidAddresses(draft.bcc)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cleaned)
            try data.write(to: fileURL)
            Log.debug("DRAFTING", "Draft saved: \(fileURL.lastPathComponent)")
        } catch {
            Log.error("DRAFTING", "Failed to save draft: \(error)")
            Task { @MainActor in
                BannerManager.shared.showWarning(title: "Draft Not Saved", message: "Could not save draft to disk.")
            }
        }
    }
    
    func loadDraft(id: UUID) -> EmailDraft? {
        let fileURL = draftsDirectory.appendingPathComponent("\(id.uuidString).json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var draft = try decoder.decode(EmailDraft.self, from: data)
            draft.to = Self.filterValidAddresses(draft.to)
            draft.cc = Self.filterValidAddresses(draft.cc)
            draft.bcc = Self.filterValidAddresses(draft.bcc)
            return draft
        } catch {
            Log.error("DRAFTING", "Failed to load draft: \(error)")
            return nil
        }
    }
    
    func deleteDraft(id: UUID) {
        let fileURL = draftsDirectory.appendingPathComponent("\(id.uuidString).json")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            Log.debug("DRAFTING", "Draft deleted: \(fileURL.lastPathComponent)")
        } catch {
            Log.error("DRAFTING", "Failed to delete draft: \(error)")
        }
    }
    
    func loadAllDrafts() -> [EmailDraft] {
        var drafts: [EmailDraft] = []
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil) else {
            return drafts
        }
        
        for fileURL in files where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let draft = try decoder.decode(EmailDraft.self, from: data)
                drafts.append(draft)
            } catch {
                Log.error("DRAFTING", "Failed to load draft from \(fileURL.lastPathComponent): \(error)")
            }
        }
        
        return drafts.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Filter out addresses that don't contain a valid email (must have @)
    private static func filterValidAddresses(_ addresses: [String]) -> [String] {
        addresses.filter { addr in
            let trimmed = addr.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.contains("@")
        }
    }
}
