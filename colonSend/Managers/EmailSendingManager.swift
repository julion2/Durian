//
//  EmailSendingManager.swift
//  colonSend
//
//  Manages email sending across multiple accounts
//

import Foundation
import Combine

@MainActor
class EmailSendingManager: ObservableObject {
    static let shared = EmailSendingManager()
    
    @Published var isSending = false
    @Published var sendingProgress = ""
    @Published var lastError: EmailSendingError?
    
    private var smtpClients: [String: SMTPClient] = [:]
    
    private init() {}
    
    func prepareSMTP(for account: MailAccount) {
        if smtpClients[account.email] == nil {
            smtpClients[account.email] = SMTPClient(account: account)
        }
    }
    
    func send(draft: EmailDraft, fromAccount accountEmail: String) async throws {
        isSending = true
        sendingProgress = "Connecting to SMTP server..."
        lastError = nil
        
        defer {
            isSending = false
            sendingProgress = ""
        }
        
        guard let account = ConfigManager.shared.accounts.first(where: { $0.email == accountEmail }) else {
            let error = EmailSendingError.noSMTPConfiguration
            lastError = error
            throw error
        }
        
        prepareSMTP(for: account)
        guard let client = smtpClients[accountEmail] else {
            let error = EmailSendingError.noSMTPConfiguration
            lastError = error
            throw error
        }
        
        do {
            try await client.connect()
            
            sendingProgress = "Sending email..."
            try await client.send(draft: draft)
            
            sendingProgress = "Email sent successfully"
            await client.disconnect()
            
            DraftManager.shared.deleteDraft(id: draft.id)
            
        } catch let error as EmailSendingError {
            lastError = error
            throw error
        } catch {
            let sendError = EmailSendingError.sendFailed(error.localizedDescription)
            lastError = sendError
            throw sendError
        }
    }
}
