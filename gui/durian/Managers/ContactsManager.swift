//
//  ContactsManager.swift
//  Durian
//
//  Manages contacts database for email autocomplete
//  Reads from SQLite DB created by CLI: ~/.config/durian/contacts.db
//

import Foundation
import SQLite3

// MARK: - Contact Model

struct Contact: Identifiable, Hashable {
    let id: String
    let email: String
    let name: String?
    var lastUsed: Date?
    var usageCount: Int
    let source: String
    let createdAt: Date
    
    /// Returns formatted display string: "Name <email>" or just "email"
    var displayString: String {
        if let name = name, !name.isEmpty {
            return "\(name) <\(email)>"
        }
        return email
    }
    
    /// Returns just the name or email if no name
    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return email
    }
}

// MARK: - Contacts Manager

class ContactsManager {
    static let shared = ContactsManager()
    
    private var db: OpaquePointer?
    private let dbPath: String
    private var isInitialized: Bool = false
    
    private init() {
        // Default path: ~/.config/durian/contacts.db
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        dbPath = homeDir.appendingPathComponent(".config/durian/contacts.db").path
        
        openDatabase()
    }
    
    deinit {
        closeDatabase()
    }
    
    // MARK: - Database Connection
    
    private func openDatabase() {
        // Check if DB file exists
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("CONTACTS: Database not found at \(dbPath)")
            print("CONTACTS: Run 'durian contacts import' to create the contacts database")
            return
        }
        
        // Open in read-only mode for GUI
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            print("CONTACTS: Opened database at \(dbPath)")
            isInitialized = true
        } else {
            print("CONTACTS_ERROR: Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    /// Reload database connection (call after CLI updates the DB)
    func reload() {
        closeDatabase()
        openDatabase()
    }
    
    // MARK: - Public API
    
    /// Check if contacts database is available
    var isAvailable: Bool {
        return isInitialized && db != nil
    }
    
    /// Search contacts by email or name prefix
    /// Results are ordered by usage_count DESC, last_used DESC
    func search(query: String, limit: Int = 10) -> [Contact] {
        guard isAvailable, !query.isEmpty else { return [] }
        
        let pattern = query.lowercased() + "%"
        let sql = """
            SELECT id, email, name, last_used, usage_count, source, created_at
            FROM contacts
            WHERE email LIKE ? OR LOWER(name) LIKE ?
            ORDER BY usage_count DESC, last_used DESC NULLS LAST
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("CONTACTS_ERROR: Failed to prepare search query")
            return []
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(limit))
        
        var contacts: [Contact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let contact = parseContact(from: statement) {
                contacts.append(contact)
            }
        }
        
        return contacts
    }
    
    /// Find contact by exact name match (case-insensitive)
    /// Used for avatar lookup when only author name is available (mail list view)
    /// Returns the most frequently used contact with that name
    func findByExactName(_ name: String) -> Contact? {
        guard isAvailable, !name.isEmpty else { return nil }
        
        let sql = """
            SELECT id, email, name, last_used, usage_count, source, created_at
            FROM contacts
            WHERE LOWER(name) = LOWER(?)
            ORDER BY usage_count DESC
            LIMIT 1
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("CONTACTS_ERROR: Failed to prepare findByExactName query")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(statement) == SQLITE_ROW {
            return parseContact(from: statement)
        }
        
        return nil
    }
    
    /// Get all contacts ordered by usage
    func list(limit: Int = 100) -> [Contact] {
        guard isAvailable else { return [] }
        
        let sql = """
            SELECT id, email, name, last_used, usage_count, source, created_at
            FROM contacts
            ORDER BY usage_count DESC, last_used DESC NULLS LAST
            LIMIT ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("CONTACTS_ERROR: Failed to prepare list query")
            return []
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_int(statement, 1, Int32(limit))
        
        var contacts: [Contact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let contact = parseContact(from: statement) {
                contacts.append(contact)
            }
        }
        
        return contacts
    }
    
    /// Get contact count
    func count() -> Int {
        guard isAvailable else { return 0 }
        
        let sql = "SELECT COUNT(*) FROM contacts"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }
    
    /// Increment usage count for an email (call after sending)
    /// Note: This opens the DB in write mode temporarily
    func incrementUsage(for email: String) {
        // Validate email before writing
        guard email.contains("@"), email.contains(".") else {
            print("CONTACTS: Skipping invalid email: \(email)")
            return
        }

        // Open in write mode
        var writeDb: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &writeDb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            print("CONTACTS_ERROR: Failed to open database for writing")
            return
        }
        defer { sqlite3_close(writeDb) }
        
        let sql = """
            UPDATE contacts
            SET usage_count = usage_count + 1, last_used = ?
            WHERE email = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writeDb, sql, -1, &statement, nil) == SQLITE_OK else {
            print("CONTACTS_ERROR: Failed to prepare update query")
            return
        }
        defer { sqlite3_finalize(statement) }
        
        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(statement, 1, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, email.lowercased(), -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(statement) == SQLITE_DONE {
            print("CONTACTS: Incremented usage for \(email)")
        }
    }
    
    /// Increment usage for multiple emails (batch operation)
    func incrementUsage(for emails: [String]) {
        for email in emails {
            incrementUsage(for: email)
        }
    }
    
    // MARK: - Private Helpers
    
    private func parseContact(from statement: OpaquePointer?) -> Contact? {
        guard let statement = statement else { return nil }
        
        guard let idPtr = sqlite3_column_text(statement, 0),
              let emailPtr = sqlite3_column_text(statement, 1) else {
            return nil
        }
        
        let id = String(cString: idPtr)
        let email = String(cString: emailPtr)
        
        var name: String? = nil
        if let namePtr = sqlite3_column_text(statement, 2) {
            name = String(cString: namePtr)
        }
        
        var lastUsed: Date? = nil
        if sqlite3_column_type(statement, 3) != SQLITE_NULL,
           let lastUsedPtr = sqlite3_column_text(statement, 3) {
            let lastUsedStr = String(cString: lastUsedPtr)
            lastUsed = parseDate(lastUsedStr)
        }
        
        let usageCount = Int(sqlite3_column_int(statement, 4))
        
        var source = "imported"
        if let sourcePtr = sqlite3_column_text(statement, 5) {
            source = String(cString: sourcePtr)
        }
        
        var createdAt = Date()
        if let createdAtPtr = sqlite3_column_text(statement, 6) {
            let createdAtStr = String(cString: createdAtPtr)
            createdAt = parseDate(createdAtStr) ?? Date()
        }
        
        return Contact(
            id: id,
            email: email,
            name: name,
            lastUsed: lastUsed,
            usageCount: usageCount,
            source: source,
            createdAt: createdAt
        )
    }
    
    private func parseDate(_ string: String) -> Date? {
        // Try ISO8601 format first
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: string) {
            return date
        }
        
        // Try without fractional seconds
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: string) {
            return date
        }
        
        // Try SQLite datetime format
        let sqliteFormatter = DateFormatter()
        sqliteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqliteFormatter.timeZone = TimeZone(identifier: "UTC")
        return sqliteFormatter.date(from: string)
    }
}

// MARK: - SQLITE_TRANSIENT helper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
