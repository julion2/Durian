//
//  MailBackendProtocol.swift
//  colonSend
//
//  Abstract protocol for mail backends (notmuch)
//

import Foundation
import Combine
import AppKit

// MARK: - Email Body State

enum EmailBodyState: Equatable, Hashable {
    case notLoaded
    case loading
    case loaded(body: String, attributedBody: NSAttributedString?)
    case failed(message: String)
    
    var displayBody: String {
        switch self {
        case .notLoaded:
            return "Tap to load email content"
        case .loading:
            return "Loading..."
        case .loaded(let body, _):
            return body.isEmpty ? "No content available" : body
        case .failed(let message):
            return "Failed to load: \(message)"
        }
    }
    
    var attributedBody: NSAttributedString? {
        switch self {
        case .loaded(_, let attributed):
            return attributed
        default:
            return nil
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .notLoaded:
            hasher.combine(0)
        case .loading:
            hasher.combine(1)
        case .loaded(let body, _):
            hasher.combine(2)
            hasher.combine(body)
        case .failed(let message):
            hasher.combine(3)
            hasher.combine(message)
        }
    }
    
    static func == (lhs: EmailBodyState, rhs: EmailBodyState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.loading, .loading):
            return true
        case (.loaded(let lBody, _), .loaded(let rBody, _)):
            return lBody == rBody
        case (.failed(let lMsg), .failed(let rMsg)):
            return lMsg == rMsg
        default:
            return false
        }
    }
}

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
    
    /// Create from profile folder config (name, displayName, icon)
    init(name: String, displayName: String, icon: String) {
        self.id = "folder:\(name)"
        self.name = name
        self.displayName = displayName
        self.icon = icon
        self.accountId = "notmuch"
        
        switch name.lowercased() {
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

/// Unified email model for notmuch
struct MailMessage: Identifiable, Hashable {
    let id: String  // thread_id for notmuch
    let subject: String
    let from: String
    let to: String?
    let date: String
    let timestamp: Int  // Unix timestamp for grouping
    let tags: String?
    var body: String?
    var htmlBody: String?  // HTML version of body (for WebView rendering)
    var attributedBody: NSAttributedString?
    var isRead: Bool
    var isPinned: Bool
    var hasAttachment: Bool
    var bodyState: EmailBodyState
    var incomingAttachments: [IncomingAttachmentMetadata]
    
    /// Create from notmuch mail
    init(threadId: String, subject: String, from: String, date: String, timestamp: Int, tags: String) {
        self.id = threadId
        self.subject = subject
        self.from = from
        self.to = nil
        self.date = date
        self.timestamp = timestamp
        self.tags = tags
        self.body = nil
        self.htmlBody = nil
        self.attributedBody = nil
        self.isRead = !tags.contains("unread")
        self.isPinned = tags.contains("flagged")
        self.hasAttachment = tags.contains("attachment")
        self.bodyState = .notLoaded
        self.incomingAttachments = []
    }
    
    /// Body preview for list view (first ~100 chars, stripped of HTML)
    var bodyPreview: String? {
        switch bodyState {
        case .loaded(let body, _):
            guard !body.isEmpty else { return nil }
            // Strip HTML tags and get first 150 chars
            let stripped = body
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(stripped.prefix(150))
        default:
            return nil
        }
    }
    
    // Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(subject)
        hasher.combine(from)
        hasher.combine(date)
        hasher.combine(body)
        hasher.combine(isRead)
        hasher.combine(isPinned)
        hasher.combine(bodyState)
    }
    
    static func == (lhs: MailMessage, rhs: MailMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.subject == rhs.subject &&
        lhs.from == rhs.from &&
        lhs.date == rhs.date &&
        lhs.body == rhs.body &&
        lhs.isRead == rhs.isRead &&
        lhs.isPinned == rhs.isPinned &&
        lhs.bodyState == rhs.bodyState
    }
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
