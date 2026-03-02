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
    /// Create a reply draft from a mail message
    /// - Parameters:
    ///   - message: The original message to reply to
    ///   - fromAccount: The email address to send from
    /// - Returns: A new EmailDraft configured as a reply
    static func createReply(from message: MailMessage, fromAccount: String) -> EmailDraft {
        // Use message.from (updated from thread headers after body load).
        // Fallback to threadMessages if from has no email (e.g. cache restored without headers).
        var replyTo = message.from
        if !replyTo.contains("@") {
            if let threadFrom = message.threadMessages?.last?.from, threadFrom.contains("@") {
                replyTo = threadFrom
            }
        }
        
        // Build subject with Re: prefix (avoid Re: Re: Re:)
        let subject = message.subject.hasPrefix("Re:") 
            ? message.subject 
            : "Re: \(message.subject)"
        
        // Build references chain
        var references = message.references ?? ""
        if let messageId = message.messageId, !messageId.isEmpty {
            if !references.isEmpty {
                references += " "
            }
            references += messageId
        }
        
        // Check if original was HTML
        let hasHTML = message.htmlBody != nil && !message.htmlBody!.isEmpty
        
        // Quote the original body (use HTML if available)
        let quotedBody = hasHTML
            ? quoteBodyHTML(message.htmlBody!, from: message.from, date: message.date)
            : quoteBody(message.body ?? "", from: message.from, date: message.date)
        
        return EmailDraft(
            from: fromAccount,
            to: [replyTo],
            subject: subject,
            body: "",  // User writes here
            inReplyTo: message.messageId,
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
    static func createReplyAll(from message: MailMessage, fromAccount: String) -> EmailDraft {
        var draft = createReply(from: message, fromAccount: fromAccount)

        // Add original To and CC recipients to CC (excluding self)
        var ccRecipients: [String] = []

        // Add original To recipients (except sender and self)
        if let originalTo = message.to {
            let toAddresses = parseEmailList(originalTo)
            let senderEmail = extractEmail(from: draft.to.first ?? message.from).lowercased()
            for address in toAddresses {
                let emailOnly = extractEmail(from: address).lowercased()
                if emailOnly != fromAccount.lowercased() && emailOnly != senderEmail {
                    ccRecipients.append(address)
                }
            }
        }

        // Add original CC recipients (except self)
        if let originalCC = message.cc {
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
                print("Created drafts directory at: \(draftsDirectory.path)")
            } catch {
                print("Failed to create drafts directory: \(error)")
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
            print("Draft saved: \(fileURL.lastPathComponent)")
        } catch {
            print("Failed to save draft: \(error)")
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
            print("Failed to load draft: \(error)")
            return nil
        }
    }
    
    func deleteDraft(id: UUID) {
        let fileURL = draftsDirectory.appendingPathComponent("\(id.uuidString).json")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            print("Draft deleted: \(fileURL.lastPathComponent)")
        } catch {
            print("Failed to delete draft: \(error)")
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
                print("Failed to load draft from \(fileURL.lastPathComponent): \(error)")
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
