//
//  IMAPModels.swift
//  colonSend
//
//  Data models for IMAP client
//

import Foundation
import AppKit

// MARK: - Folder Model

struct IMAPFolder: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let attributes: [String]
    let separator: String
    let accountId: String
    
    var icon: String {
        if attributes.contains("\\Inbox") || name == "INBOX" {
            return "tray"
        } else if attributes.contains("\\Drafts") {
            return "doc"
        } else if attributes.contains("\\Sent") {
            return "paperplane"
        } else if attributes.contains("\\Junk") {
            return "xmark.bin"
        } else if attributes.contains("\\Trash") {
            return "trash"
        } else {
            return "folder"
        }
    }
    
    var isDraftsFolder: Bool {
        return attributes.contains("\\Drafts")
    }
    
    var isSentFolder: Bool {
        return attributes.contains("\\Sent")
    }
}

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

// MARK: - Email Model

struct IMAPEmail: Identifiable, Hashable {
    let id = UUID()
    let uid: UInt32
    let subject: String
    let from: String
    let date: String
    var body: String?
    var attributedBody: NSAttributedString?
    var rawBody: String?
    var isRead: Bool
    var attachments: [EmailAttachment] = []
    var incomingAttachments: [IncomingAttachmentMetadata] = []
    var bodyState: EmailBodyState = .notLoaded
    
    // Hashable conformance - exclude NSAttributedString from hash
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
        hasher.combine(subject)
        hasher.combine(from)
        hasher.combine(date)
        hasher.combine(body)
        hasher.combine(isRead)
        hasher.combine(attachments)
        hasher.combine(incomingAttachments)
        hasher.combine(bodyState)
    }
    
    static func == (lhs: IMAPEmail, rhs: IMAPEmail) -> Bool {
        return lhs.id == rhs.id &&
               lhs.uid == rhs.uid &&
               lhs.subject == rhs.subject &&
               lhs.from == rhs.from &&
               lhs.date == rhs.date &&
               lhs.body == rhs.body &&
               lhs.isRead == rhs.isRead &&
               lhs.attachments == rhs.attachments &&
               lhs.incomingAttachments == rhs.incomingAttachments &&
               lhs.bodyState == rhs.bodyState
    }
}

// MARK: - Error Types

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed(String)  // STABILITY FIX: Added message for better error reporting
    case commandTimeout
    case invalidResponse
    case invalidStateTransition(from: String, to: String)  // PHASE 3: State machine errors
    case unexpectedData(String)  // PHASE 3: Unexpected data in state
    case unexpectedResponse(String)  // STABILITY FIX: For buffer overflow handling
}

// MARK: - Pagination State

class PaginationState {
    var currentPage = 0
    var pageSize = 50
    var totalMessages = 0
    var isLoadingMore = false
    var hasMoreMessages: Bool {
        return (currentPage * pageSize) < totalMessages
    }
    
    func reset() {
        currentPage = 0
        totalMessages = 0
        isLoadingMore = false
    }
    
    func nextPage() {
        currentPage += 1
    }
}

// MARK: - Command Types

typealias CommandCompletion = (Result<String, Error>) -> Void

struct IMAPCommand {
    let tag: String
    let command: String
    let completion: CommandCompletion
    let timeout: TimeInterval
    
    init(tag: String, command: String, timeout: TimeInterval = 30.0, completion: @escaping CommandCompletion) {
        self.tag = tag
        self.command = command
        self.completion = completion
        self.timeout = timeout
    }
}

// MARK: - String Extension

extension String {
    func matches(pattern: String) -> Bool {
        return range(of: pattern, options: .regularExpression) != nil
    }
}
