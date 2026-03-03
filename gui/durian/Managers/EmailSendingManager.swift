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
        durianPath = FileManager.default.resolveDurianPath() ?? "\(NSHomeDirectory())/.local/bin/durian"
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
            BannerManager.shared.showCritical(title: "Cannot Send Email", message: "Durian CLI not found.")
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
            "--to", draft.to.map(Self.quoteAddressIfNeeded).joined(separator: ","),
            "--subject", draft.subject
        ]

        // CC recipients
        if !draft.cc.isEmpty {
            args.append("--cc")
            args.append(draft.cc.map(Self.quoteAddressIfNeeded).joined(separator: ","))
        }

        // BCC recipients
        if !draft.bcc.isEmpty {
            args.append("--bcc")
            args.append(draft.bcc.map(Self.quoteAddressIfNeeded).joined(separator: ","))
        }
        
        // Build final body by combining user text, HTML signature, and quoted content
        var finalBody = draft.body
        var finalIsHTML = draft.isHTML

        if let htmlSig = draft.htmlSignature, !htmlSig.isEmpty {
            // HTML signature — use rich HTML body if available, otherwise escape plain text
            let userHTML: String
            if let richHTML = draft.htmlBody, !richHTML.isEmpty {
                userHTML = richHTML
            } else {
                userHTML = draft.body
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }
            finalBody = "<div>\(userHTML)</div><br>\(htmlSig)"

            if let quoted = draft.quotedContent, !quoted.isEmpty {
                let quotedHTML = draft.quotedIsHTML ? quoted : Self.plainTextToHTML(quoted)
                finalBody += "<br><br>\(quotedHTML)"
            }

            finalIsHTML = true
        } else if let quoted = draft.quotedContent, !quoted.isEmpty {
            if draft.quotedIsHTML {
                // Use rich HTML body if available, otherwise escape plain text
                let userHTML: String
                if let richHTML = draft.htmlBody, !richHTML.isEmpty {
                    userHTML = richHTML
                } else {
                    userHTML = draft.body
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                        .replacingOccurrences(of: "\n", with: "<br>")
                }
                finalBody = "<div>\(userHTML)</div><br><br>\(quoted)"
                finalIsHTML = true
            } else {
                // Plain text quoted — check if user body has formatting
                if let richHTML = draft.htmlBody, !richHTML.isEmpty {
                    let quotedHTML = Self.plainTextToHTML(quoted)
                    finalBody = "<div>\(richHTML)</div><br><br>\(quotedHTML)"
                    finalIsHTML = true
                } else {
                    finalBody = draft.body + "\n\n" + quoted
                }
            }
        } else if let richHTML = draft.htmlBody, !richHTML.isEmpty {
            // No signature, no quoted content, but user used formatting
            finalBody = "<div>\(richHTML)</div>"
            finalIsHTML = true
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
        
        // Attachments - write to temp dir with original filename preserved
        let tempDir = "/tmp/durian-attach-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        var tempAttachmentPaths: [String] = []
        for attachment in draft.attachments {
            let tempPath = "\(tempDir)/\(attachment.filename)"
            do {
                try attachment.data.write(to: URL(fileURLWithPath: tempPath))
                tempAttachmentPaths.append(tempPath)
                args.append("--attach")
                args.append(tempPath)
            } catch {
                // Clean up temp directory
                try? FileManager.default.removeItem(atPath: tempDir)
                let sendError = EmailSendingError.sendFailed("Failed to write attachment: \(error.localizedDescription)")
                lastError = sendError
                throw sendError
            }
        }

        // Clean up temp directory after sending
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
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
            BannerManager.shared.showSuccess(title: "Sent Successfully", message: "Your email has been delivered.")
            
            // Update contact usage statistics
            let allRecipients = draft.to + draft.cc + draft.bcc
            updateContactUsage(for: allRecipients)
            
            // Note: Draft deletion is handled by the caller (ComposeWindow.handleSend)
        } else {
            let errorMessage = result.error ?? "Unknown error"
            print("EMAIL: Send failed: \(errorMessage)")
            let sendError = EmailSendingError.sendFailed(errorMessage)
            lastError = sendError
            BannerManager.shared.showCritical(title: "Email Not Sent", message: errorMessage)
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
    
    /// Quote the display name in an address if it contains a comma
    /// e.g. "van der Zee, Warden <a@b.com>" → "\"van der Zee, Warden\" <a@b.com>"
    private static func quoteAddressIfNeeded(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let angleBracketStart = trimmed.range(of: "<"),
              trimmed.hasSuffix(">") else {
            // Plain email, no display name
            return trimmed
        }

        let displayName = String(trimmed[..<angleBracketStart.lowerBound]).trimmingCharacters(in: .whitespaces)
        let emailPart = String(trimmed[angleBracketStart.lowerBound...])

        if displayName.contains(",") && !displayName.hasPrefix("\"") {
            return "\"\(displayName)\" \(emailPart)"
        }
        return trimmed
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
    
    /// Convert plain text to basic HTML (for combining plain text quoted content with HTML signature)
    private static func plainTextToHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<div style=\"font-family: -apple-system, monospace; font-size: 13px; color: #666; white-space: pre-wrap;\">\(escaped)</div>"
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
