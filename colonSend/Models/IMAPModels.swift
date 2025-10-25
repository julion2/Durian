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
    
    // Hashable conformance - exclude NSAttributedString from hash
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
        hasher.combine(subject)
        hasher.combine(from)
        hasher.combine(date)
        hasher.combine(body)
        hasher.combine(isRead)
    }
    
    // Equatable conformance - exclude NSAttributedString from equality
    static func == (lhs: IMAPEmail, rhs: IMAPEmail) -> Bool {
        return lhs.id == rhs.id &&
               lhs.uid == rhs.uid &&
               lhs.subject == rhs.subject &&
               lhs.from == rhs.from &&
               lhs.date == rhs.date &&
               lhs.body == rhs.body &&
               lhs.isRead == rhs.isRead
    }
}

// MARK: - Error Types

enum IMAPError: Error {
    case noConnection
    case authenticationFailed
    case connectionFailed
    case commandTimeout
    case invalidResponse
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
