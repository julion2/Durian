//
//  BannerMessage.swift
//  Durian
//
//  Banner message model for toast/banner display
//

import Foundation
import SwiftUI

// MARK: - Severity

enum BannerSeverity {
    case info       // Gray, auto-dismiss after 5s
    case success    // Green, auto-dismiss after 5s
    case warning    // Orange, auto-dismiss after 5s
    case critical   // Red, stays until dismissed

    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Banner Action

struct BannerAction: Identifiable {
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

// MARK: - Banner Message

struct BannerMessage: Identifiable {
    let id = UUID()
    let title: String
    var message: String
    let severity: BannerSeverity
    let actions: [BannerAction]
    let onTap: (() -> Void)?

    init(title: String, message: String, severity: BannerSeverity, actions: [BannerAction] = [], onTap: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.severity = severity
        self.actions = actions
        self.onTap = onTap
    }
}

// MARK: - EmailSendingError Mapping

extension EmailSendingError {
    var bannerMessage: BannerMessage {
        switch self {
        case .noSMTPConfiguration:
            return BannerMessage(
                title: "SMTP nicht konfiguriert",
                message: "Kein SMTP-Server für diesen Account konfiguriert.",
                severity: .critical
            )
        case .authenticationFailed:
            return BannerMessage(
                title: "SMTP Authentifizierung fehlgeschlagen",
                message: "Benutzername oder Passwort falsch.",
                severity: .critical
            )
        case .connectionFailed:
            return BannerMessage(
                title: "SMTP Server nicht erreichbar",
                message: "Verbindung zum SMTP-Server fehlgeschlagen.",
                severity: .critical
            )
        case .sendFailed(let msg):
            return BannerMessage(
                title: "Senden fehlgeschlagen",
                message: msg,
                severity: .critical
            )
        case .invalidRecipients:
            return BannerMessage(
                title: "Keine Empfänger angegeben",
                message: "Bitte mindestens einen Empfänger eingeben.",
                severity: .critical
            )
        case .invalidEmailFormat(let emails):
            return BannerMessage(
                title: "Ungültige E-Mail-Adressen",
                message: emails.joined(separator: ", "),
                severity: .critical
            )
        }
    }
}
