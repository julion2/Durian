//
//  EmailSendingManager.swift
//  Durian
//
//  Manages email sending via the outbox HTTP API
//

import Foundation
import Combine

@MainActor
class EmailSendingManager: ObservableObject {
    static let shared = EmailSendingManager()

    @Published var isSending = false
    @Published var sendingProgress = ""
    @Published var lastError: EmailSendingError?

    private init() {}

    /// Send email by enqueuing to the outbox via HTTP API.
    /// The background worker on the server handles actual SMTP delivery.
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

        isSending = true
        sendingProgress = "Preparing email..."
        lastError = nil

        defer {
            isSending = false
            sendingProgress = ""
        }

        // Build final body by combining user text, HTML signature, and quoted content
        var finalBody = draft.body
        var finalIsHTML = draft.isHTML

        if let htmlSig = draft.htmlSignature, !htmlSig.isEmpty {
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
                if let richHTML = draft.htmlBody, !richHTML.isEmpty {
                    let quotedHTML = Self.plainTextToHTML(quoted)
                    finalBody = "<div>\(richHTML)</div><br><br>\(quotedHTML)"
                    finalIsHTML = true
                } else {
                    finalBody = draft.body + "\n\n" + quoted
                }
            }
        } else if let richHTML = draft.htmlBody, !richHTML.isEmpty {
            finalBody = "<div>\(richHTML)</div>"
            finalIsHTML = true
        }

        // Build attachment payloads (base64-encoded)
        let attachmentPayloads = draft.attachments.map { att in
            OutboxAttachmentPayload(
                filename: att.filename,
                mime_type: att.mimeType,
                data_base64: att.data.base64EncodedString()
            )
        }

        // Build outbox payload
        let payload = OutboxPayload(
            from: accountEmail,
            to: draft.to,
            cc: draft.cc,
            bcc: draft.bcc,
            subject: draft.subject,
            body: finalBody,
            is_html: finalIsHTML,
            in_reply_to: draft.inReplyTo,
            references: draft.references,
            attachments: attachmentPayloads
        )

        // Enqueue via HTTP
        sendingProgress = "Queuing email..."
        Log.debug("EMAIL", "Enqueuing to outbox")
        Log.debug("EMAIL", "From: \(accountEmail)")
        Log.debug("EMAIL", "To: \(draft.to.joined(separator: ", "))")
        if !draft.cc.isEmpty {
            Log.debug("EMAIL", "CC: \(draft.cc.joined(separator: ", "))")
        }
        if !draft.bcc.isEmpty {
            Log.debug("EMAIL", "BCC: \(draft.bcc.joined(separator: ", "))")
        }
        Log.debug("EMAIL", "Subject: \(draft.subject)")
        if !draft.attachments.isEmpty {
            Log.debug("EMAIL", "Attachments: \(draft.attachments.count)")
        }

        guard let backend = AccountManager.shared.emailBackend else {
            let sendError = EmailSendingError.sendFailed("Mail server not connected")
            lastError = sendError
            BannerManager.shared.showCritical(title: "Cannot Send Email", message: "Mail server not connected.")
            throw sendError
        }

        let result = await backend.enqueueOutbox(payload)

        if result.ok {
            sendingProgress = "Email queued"
            Log.info("EMAIL", "Enqueued successfully (id=\(result.id ?? -1))")
            BannerManager.shared.showSuccess(title: "Email Queued", message: "Your email will be sent shortly.")

            // Update contact usage statistics
            let allRecipients = draft.to + draft.cc + draft.bcc
            updateContactUsage(for: allRecipients)

            // Refresh outbox count
            OutboxManager.shared.refresh()
        } else {
            let errorMessage = result.error ?? "Unknown error"
            Log.error("EMAIL", "Enqueue failed: \(errorMessage)")
            let sendError = EmailSendingError.sendFailed(errorMessage)
            lastError = sendError
            BannerManager.shared.showCritical(title: "Email Not Queued", message: errorMessage)
            throw sendError
        }
    }

    // MARK: - Contact Usage Tracking

    /// Update contact usage statistics for sent recipients
    private func updateContactUsage(for recipients: [String]) {
        guard !recipients.isEmpty else { return }

        let emails = recipients.map { extractEmail(from: $0) }
        ContactsManager.shared.incrementUsage(for: emails)
    }

    /// Extract email address from string (handles "Name <email>" format)
    private nonisolated func extractEmail(from address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)

        if let startIdx = trimmed.lastIndex(of: "<"),
           let endIdx = trimmed.lastIndex(of: ">"),
           startIdx < endIdx {
            let start = trimmed.index(after: startIdx)
            return String(trimmed[start..<endIdx]).trimmingCharacters(in: .whitespaces)
        }

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
}
