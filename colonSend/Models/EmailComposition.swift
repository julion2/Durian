//
//  EmailComposition.swift
//  colonSend
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
    var body: String
    var isHTML: Bool
    var inReplyTo: String?
    var references: String?
    var createdAt: Date
    var modifiedAt: Date
    
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
        references: String? = nil
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
}

struct EmailAttachment: Identifiable, Codable {
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

class DraftManager {
    static let shared = DraftManager()
    
    private let draftsDirectory: URL
    
    private init() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        draftsDirectory = homeURL.appendingPathComponent(".config/colonSend/drafts")
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
