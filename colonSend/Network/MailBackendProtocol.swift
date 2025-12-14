//
//  MailBackendProtocol.swift
//  colonSend
//
//  Abstract protocol for mail backends (IMAP, notmuch, etc.)
//

import Foundation
import Combine
import AppKit

// MARK: - Mail Backend Protocol

/// Protocol defining the interface for mail backends.
/// Both IMAPClient and NotmuchBackend should conform to this.
@MainActor
protocol MailBackendProtocol: ObservableObject {
    // MARK: - Connection State
    var isConnected: Bool { get }
    var connectionStatus: String { get }
    
    // MARK: - Data
    var folders: [MailFolder] { get }
    var emails: [MailMessage] { get }
    var isLoadingEmails: Bool { get }
    var loadingProgress: String { get }
    
    // MARK: - Connection
    func connect() async
    func disconnect() async
    
    // MARK: - Folder/Tag Selection
    /// Select a folder (IMAP) or tag (notmuch) to view
    func selectFolder(_ name: String) async
    
    // MARK: - Email Operations
    func fetchEmailBody(id: String) async
    func markAsRead(id: String) async
    func markAsUnread(id: String) async
    func deleteMessage(id: String) async throws
    
    // MARK: - Reload
    func reload() async
}

// MARK: - Unified Models

/// Unified folder/tag model that works for both IMAP and notmuch
struct MailFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let icon: String
    let accountId: String
    let isSpecial: Bool  // true for inbox, sent, drafts, trash
    let specialType: SpecialFolderType?
    
    enum SpecialFolderType: String {
        case inbox, sent, drafts, trash, archive, junk
    }
    
    /// Create from IMAP folder
    init(from imapFolder: IMAPFolder) {
        self.id = imapFolder.id.uuidString
        self.name = imapFolder.name
        self.displayName = imapFolder.name
        self.icon = imapFolder.icon
        self.accountId = imapFolder.accountId
        
        if imapFolder.name.uppercased() == "INBOX" || imapFolder.attributes.contains("\\Inbox") {
            self.isSpecial = true
            self.specialType = .inbox
        } else if imapFolder.isDraftsFolder {
            self.isSpecial = true
            self.specialType = .drafts
        } else if imapFolder.isSentFolder {
            self.isSpecial = true
            self.specialType = .sent
        } else if imapFolder.attributes.contains("\\Trash") {
            self.isSpecial = true
            self.specialType = .trash
        } else if imapFolder.attributes.contains("\\Junk") {
            self.isSpecial = true
            self.specialType = .junk
        } else {
            self.isSpecial = false
            self.specialType = nil
        }
    }
    
    /// Create for notmuch tag
    init(tag: String, icon: String) {
        self.id = "tag:\(tag)"
        self.name = tag
        self.displayName = tag.capitalized
        self.icon = icon
        self.accountId = "notmuch"
        
        switch tag {
        case "inbox":
            self.isSpecial = true
            self.specialType = .inbox
        case "sent":
            self.isSpecial = true
            self.specialType = .sent
        case "draft", "drafts":
            self.isSpecial = true
            self.specialType = .drafts
        case "deleted", "trash":
            self.isSpecial = true
            self.specialType = .trash
        case "archive":
            self.isSpecial = true
            self.specialType = .archive
        default:
            self.isSpecial = false
            self.specialType = nil
        }
    }
}

/// Unified email model that works for both IMAP and notmuch
struct MailMessage: Identifiable, Hashable {
    let id: String  // thread_id for notmuch, UUID string for IMAP
    let uid: UInt32?  // Only for IMAP
    let file: String?  // Only for notmuch (path to mail file)
    let subject: String
    let from: String
    let to: String?
    let date: String
    let tags: String?  // Only for notmuch
    var body: String?
    var htmlBody: String?  // HTML version of body (for WebView rendering)
    var attributedBody: NSAttributedString?
    var isRead: Bool
    var hasAttachment: Bool
    var bodyState: EmailBodyState
    var incomingAttachments: [IncomingAttachmentMetadata]
    
    /// Create from IMAP email
    init(from email: IMAPEmail) {
        self.id = email.id.uuidString
        self.uid = email.uid
        self.file = nil
        self.subject = email.subject
        self.from = email.from
        self.to = nil
        self.date = email.date
        self.tags = nil
        self.body = email.body
        self.htmlBody = nil
        self.attributedBody = email.attributedBody
        self.isRead = email.isRead
        self.hasAttachment = !email.incomingAttachments.isEmpty
        self.bodyState = email.bodyState
        self.incomingAttachments = email.incomingAttachments
    }
    
    /// Create from notmuch mail
    init(threadId: String, subject: String, from: String, date: String, tags: String) {
        self.id = threadId
        self.uid = nil
        self.file = nil  // No longer needed - mailctl resolves file from thread_id
        self.subject = subject
        self.from = from
        self.to = nil
        self.date = date
        self.tags = tags
        self.body = nil
        self.htmlBody = nil
        self.attributedBody = nil
        self.isRead = !tags.contains("unread")
        self.hasAttachment = tags.contains("attachment")
        self.bodyState = .notLoaded
        self.incomingAttachments = []
    }
    
    // Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(subject)
        hasher.combine(from)
        hasher.combine(date)
        hasher.combine(body)
        hasher.combine(isRead)
        hasher.combine(bodyState)
    }
    
    static func == (lhs: MailMessage, rhs: MailMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.subject == rhs.subject &&
        lhs.from == rhs.from &&
        lhs.date == rhs.date &&
        lhs.body == rhs.body &&
        lhs.isRead == rhs.isRead &&
        lhs.bodyState == rhs.bodyState
    }
}

// MARK: - Backend Type Enum

enum MailBackendType {
    case imap
    case notmuch
}

// MARK: - Default Tags for Notmuch

extension MailFolder {
    static let defaultNotmuchTags: [MailFolder] = [
        MailFolder(tag: "inbox", icon: "tray"),
        MailFolder(tag: "unread", icon: "envelope.badge"),
        MailFolder(tag: "sent", icon: "paperplane"),
        MailFolder(tag: "archive", icon: "archivebox"),
        MailFolder(tag: "deleted", icon: "trash"),
        MailFolder(tag: "attachment", icon: "paperclip"),
        MailFolder(tag: "flagged", icon: "star"),
    ]
}
