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
        quotedIsHTML: Bool = false
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
        case .connectionFailed:
            return "Failed to connect to SMTP server"
        }
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
        // Extract sender email from "Name <email>" format
        let replyTo = extractEmail(from: message.from)
        
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
            let toEmails = parseEmailList(originalTo)
            for email in toEmails {
                let normalized = extractEmail(from: email).lowercased()
                if normalized != fromAccount.lowercased() && 
                   normalized != extractEmail(from: message.from).lowercased() {
                    ccRecipients.append(email)
                }
            }
        }
        
        // Add original CC recipients (except self)
        if let originalCC = message.cc {
            let ccEmails = parseEmailList(originalCC)
            for email in ccEmails {
                let normalized = extractEmail(from: email).lowercased()
                if normalized != fromAccount.lowercased() {
                    ccRecipients.append(email)
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
    
    /// Extract email address from "Name <email>" format
    private static func extractEmail(from address: String) -> String {
        if let start = address.firstIndex(of: "<"),
           let end = address.firstIndex(of: ">") {
            return String(address[address.index(after: start)..<end])
        }
        return address.trimmingCharacters(in: .whitespaces)
    }
    
    /// Parse comma-separated email list
    private static func parseEmailList(_ list: String) -> [String] {
        return list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(draft)
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
            let draft = try decoder.decode(EmailDraft.self, from: data)
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
}
