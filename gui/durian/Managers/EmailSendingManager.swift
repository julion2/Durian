//
//  EmailSendingManager.swift
//  Durian
//
//  Manages email sending via durian CLI
//

import Foundation
import Combine

@MainActor
class EmailSendingManager: ObservableObject {
    static let shared = EmailSendingManager()
    
    @Published var isSending = false
    @Published var sendingProgress = ""
    @Published var lastError: EmailSendingError?
    
    private let durianPath: String
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        durianPath = home.appendingPathComponent(".local/bin/durian").path
    }
    
    /// Send email using durian CLI
    /// - Parameters:
    ///   - draft: The email draft to send
    ///   - fromAccount: The account email to send from
    ///   - skipValidation: If true, skip email format validation (used when user confirms "Send Anyway")
    func send(draft: EmailDraft, fromAccount accountEmail: String, skipValidation: Bool = false) async throws {
        guard draft.hasRecipients else {
            let error = EmailSendingError.invalidRecipients
            lastError = error
            throw error
        }
        
        // Validate email formats (unless skipped)
        if !skipValidation {
            let allRecipients = draft.to + draft.cc + draft.bcc
            let invalidEmails = EmailHelper.validateRecipients(allRecipients)
            
            if !invalidEmails.isEmpty {
                let error = EmailSendingError.invalidEmailFormat(invalidEmails)
                lastError = error
                throw error
            }
        }
        
        guard FileManager.default.fileExists(atPath: durianPath) else {
            let error = EmailSendingError.sendFailed("durian CLI not found at \(durianPath)")
            lastError = error
            throw error
        }
        
        isSending = true
        sendingProgress = "Preparing email..."
        lastError = nil
        
        defer {
            isSending = false
            sendingProgress = ""
        }
        
        // Build durian send arguments
        var args = ["send",
            "--from", accountEmail,
            "--to", draft.to.joined(separator: ","),
            "--subject", draft.subject
        ]
        
        // CC recipients
        if !draft.cc.isEmpty {
            args.append("--cc")
            args.append(draft.cc.joined(separator: ","))
        }
        
        // BCC recipients
        if !draft.bcc.isEmpty {
            args.append("--bcc")
            args.append(draft.bcc.joined(separator: ","))
        }
        
        // Build final body by combining user text and quoted content
        var finalBody = draft.body
        var finalIsHTML = draft.isHTML
        
        if let quoted = draft.quotedContent, !quoted.isEmpty {
            if draft.quotedIsHTML {
                // Convert user text to HTML and combine with quoted HTML
                let userHTML = draft.body
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\n", with: "<br>")
                finalBody = "<div>\(userHTML)</div><br><br>\(quoted)"
                finalIsHTML = true
            } else {
                // Plain text: just concatenate
                finalBody = draft.body + "\n\n" + quoted
            }
        }
        
        // HTML flag
        if finalIsHTML {
            args.append("--html")
        }
        
        // Body as temp file (handles long bodies and special characters)
        let bodyFile = "/tmp/durian-email-body-\(UUID().uuidString).txt"
        do {
            try finalBody.write(toFile: bodyFile, atomically: true, encoding: .utf8)
        } catch {
            let sendError = EmailSendingError.sendFailed("Failed to write body file: \(error.localizedDescription)")
            lastError = sendError
            throw sendError
        }
        defer { try? FileManager.default.removeItem(atPath: bodyFile) }
        args.append(contentsOf: ["--body-file", bodyFile])
        
        // Attachments - write to temp files
        var tempAttachmentPaths: [String] = []
        for attachment in draft.attachments {
            let tempPath = "/tmp/durian-attach-\(UUID().uuidString)-\(attachment.filename)"
            do {
                try attachment.data.write(to: URL(fileURLWithPath: tempPath))
                tempAttachmentPaths.append(tempPath)
                args.append("--attach")
                args.append(tempPath)
            } catch {
                // Clean up any already-written temp files
                for path in tempAttachmentPaths {
                    try? FileManager.default.removeItem(atPath: path)
                }
                let sendError = EmailSendingError.sendFailed("Failed to write attachment: \(error.localizedDescription)")
                lastError = sendError
                throw sendError
            }
        }
        
        // Clean up temp attachments after sending
        defer {
            for path in tempAttachmentPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        
        // Execute durian send
        sendingProgress = "Sending email..."
        print("EMAIL: Executing durian send")
        print("EMAIL:   From: \(accountEmail)")
        print("EMAIL:   To: \(draft.to.joined(separator: ", "))")
        if !draft.cc.isEmpty {
            print("EMAIL:   CC: \(draft.cc.joined(separator: ", "))")
        }
        if !draft.bcc.isEmpty {
            print("EMAIL:   BCC: \(draft.bcc.joined(separator: ", "))")
        }
        print("EMAIL:   Subject: \(draft.subject)")
        if !draft.attachments.isEmpty {
            print("EMAIL:   Attachments: \(draft.attachments.count)")
        }
        
        let result = await runCommand(args: args, timeout: 120)
        
        if result.success {
            sendingProgress = "Email sent successfully"
            print("EMAIL: Sent successfully")
            
            // Update contact usage statistics
            let allRecipients = draft.to + draft.cc + draft.bcc
            updateContactUsage(for: allRecipients)
            
            // Note: Draft deletion is handled by the caller (ComposeWindow.handleSend)
        } else {
            let errorMessage = result.error ?? "Unknown error"
            print("EMAIL: Send failed: \(errorMessage)")
            let sendError = EmailSendingError.sendFailed(errorMessage)
            lastError = sendError
            throw sendError
        }
    }
    
    // MARK: - Contact Usage Tracking
    
    /// Update contact usage statistics for sent recipients
    private func updateContactUsage(for recipients: [String]) {
        guard !recipients.isEmpty else { return }
        
        // Run in background to not block UI
        Task.detached(priority: .utility) {
            for recipient in recipients {
                // Extract email from "Name <email>" format if needed
                let email = self.extractEmail(from: recipient)
                ContactsManager.shared.incrementUsage(for: email)
            }
            print("EMAIL: Updated usage for \(recipients.count) recipients")
        }
    }
    
    /// Extract email address from string (handles "Name <email>" format)
    private nonisolated func extractEmail(from address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        
        // Check for "Name <email>" format
        if let startIdx = trimmed.lastIndex(of: "<"),
           let endIdx = trimmed.lastIndex(of: ">"),
           startIdx < endIdx {
            let start = trimmed.index(after: startIdx)
            return String(trimmed[start..<endIdx]).trimmingCharacters(in: .whitespaces)
        }
        
        // Already just an email
        return trimmed
    }
    
    // MARK: - Command Execution
    
    private struct CommandResult {
        let success: Bool
        let output: String?
        let error: String?
    }
    
    private func runCommand(args: [String], timeout: TimeInterval) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.durianPath)
                process.arguments = args
                
                // Set up environment with Homebrew paths
                var env = ProcessInfo.processInfo.environment
                let homebrewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
                if let existingPath = env["PATH"] {
                    env["PATH"] = "\(homebrewPaths):\(existingPath)"
                } else {
                    env["PATH"] = "\(homebrewPaths):/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = env
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                // Set up timeout
                var timeoutWorkItem: DispatchWorkItem?
                var didTimeout = false
                
                timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        print("EMAIL: Command timed out after \(timeout)s, terminating process")
                        didTimeout = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem!)
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    // Cancel timeout timer if process completed
                    timeoutWorkItem?.cancel()
                    
                    if didTimeout {
                        continuation.resume(returning: CommandResult(
                            success: false,
                            output: nil,
                            error: "Send timed out after \(Int(timeout)) seconds"
                        ))
                        return
                    }
                    
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8)
                    let errorOutput = String(data: errorData, encoding: .utf8)
                    
                    let success = process.terminationStatus == 0
                    continuation.resume(returning: CommandResult(
                        success: success,
                        output: output,
                        error: success ? nil : (errorOutput?.isEmpty == false ? errorOutput : "Exit code \(process.terminationStatus)")
                    ))
                } catch {
                    timeoutWorkItem?.cancel()
                    continuation.resume(returning: CommandResult(
                        success: false,
                        output: nil,
                        error: error.localizedDescription
                    ))
                }
            }
        }
    }
}
