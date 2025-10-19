//
//  SMTPClient.swift
//  colonSend
//
//  SMTP client using command-line sendmail as fallback
//

import Foundation

class SMTPClient {
    private let account: MailAccount
    
    init(account: MailAccount) {
        self.account = account
    }
    
    func connect() async throws {
        print("SMTP: Connection check for \(account.smtp.host)")
    }
    
    func send(draft: EmailDraft) async throws {
        guard draft.hasRecipients else {
            throw EmailSendingError.invalidRecipients
        }
        
        guard let passwordKeychain = account.auth.passwordKeychain else {
            throw EmailSendingError.noSMTPConfiguration
        }
        
        guard let password = KeychainHelper.retrievePassword(
            service: passwordKeychain,
            account: account.auth.username
        ) else {
            throw EmailSendingError.authenticationFailed
        }
        
        print("SMTP: Sending via curl SMTP client")
        print("SMTP:   Server: \(account.smtp.host):\(account.smtp.port)")
        print("SMTP:   From: \(draft.from)")
        print("SMTP:   To: \(draft.to.joined(separator: ", "))")
        print("SMTP:   Subject: \(draft.subject)")
        
        try await sendViaCurl(draft: draft, password: password)
    }
    
    func disconnect() async {
        print("SMTP: Disconnect (no-op)")
    }
    
    private func sendViaCurl(draft: EmailDraft, password: String) async throws {
        let emailContent = buildEmailContent(draft: draft)
        
        let tmpFile = "/tmp/colonSend_email_\(UUID().uuidString).txt"
        try emailContent.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(atPath: tmpFile)
        }
        
        let smtpURL: String
        if account.smtp.port == 465 {
            smtpURL = "smtps://\(account.smtp.host):465"
        } else {
            smtpURL = "smtp://\(account.smtp.host):587"
        }
        
        let recipients = draft.to.map { "--mail-rcpt '\($0)'" }.joined(separator: " ")
        
        let command = """
        curl --url '\(smtpURL)' \
             --ssl-reqd \
             --mail-from '\(draft.from)' \
             \(recipients) \
             --upload-file '\(tmpFile)' \
             --user '\(account.auth.username):\(password)' \
             --verbose
        """
        
        print("SMTP: Executing curl command...")
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "--url", smtpURL,
            "--ssl-reqd",
            "--mail-from", draft.from,
        ]
        
        for recipient in draft.to {
            task.arguments?.append("--mail-rcpt")
            task.arguments?.append(recipient)
        }
        
        for cc in draft.cc {
            task.arguments?.append("--mail-rcpt")
            task.arguments?.append(cc)
        }
        
        task.arguments?.append(contentsOf: [
            "--upload-file", tmpFile,
            "--user", "\(account.auth.username):\(password)"
        ])
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if task.terminationStatus == 0 {
                print("SMTP: Email sent successfully via curl!")
            } else {
                print("SMTP: curl failed with status \(task.terminationStatus)")
                print("SMTP: Error output:\n\(errorOutput)")
                throw EmailSendingError.sendFailed("curl exit code \(task.terminationStatus)")
            }
        } catch {
            print("SMTP: Failed to execute curl: \(error)")
            throw EmailSendingError.sendFailed(error.localizedDescription)
        }
    }
    
    private func buildEmailContent(draft: EmailDraft) -> String {
        var email = ""
        
        email += "From: \(draft.from)\r\n"
        email += "To: \(draft.to.joined(separator: ", "))\r\n"
        
        if !draft.cc.isEmpty {
            email += "Cc: \(draft.cc.joined(separator: ", "))\r\n"
        }
        
        email += "Subject: \(draft.subject)\r\n"
        email += "Date: \(formatDate(Date()))\r\n"
        email += "MIME-Version: 1.0\r\n"
        email += "Content-Type: text/plain; charset=UTF-8\r\n"
        email += "\r\n"
        email += draft.body
        
        return email
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
