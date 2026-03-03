//
//  UserFacingError.swift
//  Durian
//
//  User-facing error model for toast/banner display
//

import Foundation
import SwiftUI

// MARK: - Severity

enum ErrorSeverity {
    case warning    // Orange, auto-dismiss after 5s
    case critical   // Red, stays until dismissed

    var color: Color {
        switch self {
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var icon: String {
        switch self {
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Error Action

struct ErrorAction: Identifiable {
    let id = UUID()
    let label: String
    let role: ButtonRole?
    let handler: () -> Void

    init(_ label: String, role: ButtonRole? = nil, handler: @escaping () -> Void) {
        self.label = label
        self.role = role
        self.handler = handler
    }
}

// MARK: - User-Facing Error

struct UserFacingError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let severity: ErrorSeverity
    let actions: [ErrorAction]

    init(title: String, message: String, severity: ErrorSeverity, actions: [ErrorAction] = []) {
        self.title = title
        self.message = message
        self.severity = severity
        self.actions = actions
    }
}

// MARK: - EmailSendingError Mapping

extension EmailSendingError {
    var userFacingError: UserFacingError {
        switch self {
        case .noSMTPConfiguration:
            return UserFacingError(
                title: "SMTP nicht konfiguriert",
                message: "Kein SMTP-Server für diesen Account konfiguriert.",
                severity: .critical
            )
        case .authenticationFailed:
            return UserFacingError(
                title: "SMTP Authentifizierung fehlgeschlagen",
                message: "Benutzername oder Passwort falsch.",
                severity: .critical
            )
        case .connectionFailed:
            return UserFacingError(
                title: "SMTP Server nicht erreichbar",
                message: "Verbindung zum SMTP-Server fehlgeschlagen.",
                severity: .critical
            )
        case .sendFailed(let msg):
            return UserFacingError(
                title: "Senden fehlgeschlagen",
                message: msg,
                severity: .critical
            )
        case .invalidRecipients:
            return UserFacingError(
                title: "Keine Empfänger angegeben",
                message: "Bitte mindestens einen Empfänger eingeben.",
                severity: .critical
            )
        case .invalidEmailFormat(let emails):
            return UserFacingError(
                title: "Ungültige E-Mail-Adressen",
                message: emails.joined(separator: ", "),
                severity: .critical
            )
        }
    }
}
