//
//  MailBackendProtocol.swift
//  Durian
//
//  Abstract protocol for mail backends (notmuch)
//

import Foundation
import Combine

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
