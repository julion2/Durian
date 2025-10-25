//
//  MIMEBuilder.swift
//  colonSend
//
//  MIME message builder for emails with attachments
//

import Foundation

class MIMEBuilder {
    static func buildMessage(from draft: EmailDraft) -> String {
        var email = ""
        
        email += "From: \(draft.from)\r\n"
        email += "To: \(draft.to.joined(separator: ", "))\r\n"
        
        if !draft.cc.isEmpty {
            email += "Cc: \(draft.cc.joined(separator: ", "))\r\n"
        }
        
        if !draft.bcc.isEmpty {
            email += "Bcc: \(draft.bcc.joined(separator: ", "))\r\n"
        }
        
        email += "Subject: \(draft.subject)\r\n"
        email += "Date: \(formatDate(Date()))\r\n"
        email += "Message-ID: <\(draft.id.uuidString)@colonSend>\r\n"
        
        if let inReplyTo = draft.inReplyTo {
            email += "In-Reply-To: \(inReplyTo)\r\n"
        }
        
        if let references = draft.references {
            email += "References: \(references)\r\n"
        }
        
        email += "MIME-Version: 1.0\r\n"
        
        if draft.hasAttachments {
            let boundary = "colonSend_boundary_\(UUID().uuidString)"
            email += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n"
            email += "\r\n"
            
            email += "--\(boundary)\r\n"
            email += "Content-Type: text/plain; charset=UTF-8\r\n"
            email += "Content-Transfer-Encoding: 8bit\r\n"
            email += "\r\n"
            email += draft.body
            email += "\r\n"
            
            for attachment in draft.attachments {
                email += "--\(boundary)\r\n"
                email += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
                email += "Content-Transfer-Encoding: base64\r\n"
                email += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
                email += "\r\n"
                
                let base64 = attachment.data.base64EncodedString()
                let chunks = base64.chunked(into: 76)
                for chunk in chunks {
                    email += chunk + "\r\n"
                }
                email += "\r\n"
            }
            
            email += "--\(boundary)--\r\n"
            
        } else {
            email += "Content-Type: text/plain; charset=UTF-8\r\n"
            email += "Content-Transfer-Encoding: 8bit\r\n"
            email += "\r\n"
            email += draft.body
        }
        
        return email
    }
    
    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

extension String {
    func chunked(into size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }
    }
}
