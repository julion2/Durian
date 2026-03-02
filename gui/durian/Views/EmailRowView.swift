import SwiftUI

struct EmailRowView: View {
    let email: MailMessage
    var isSelected: Bool = false
    var isFirstInGroup: Bool = true   // First in contiguous selection group (top corners rounded)
    var isLastInGroup: Bool = true    // Last in contiguous selection group (bottom corners rounded)
    var currentFolder: String = AccountManager.shared.selectedFolder
    
    // Context menu callbacks
    var onTogglePin: (() -> Void)?
    var onToggleRead: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: counterparties.first?.name ?? email.from,
                       email: counterparties.first?.email ?? email.from,
                       size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !email.isRead {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                    }
                    
                    if email.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    
                    Text(senderName)
                        .font(.headline)
                        .fontWeight(email.isRead ? .regular : .bold)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                    Spacer()
                    Text(email.date)
                        .font(.callout)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }

                HStack(spacing: 4) {
                    Text(email.subject.isEmpty ? "(No Subject)" : email.subject)
                        .font(.callout)
                        .fontWeight(email.isRead ? .regular : .semibold)
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .primary)
                        .lineLimit(1)
                    Spacer()
                    if email.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                    }
                }

                if let preview = email.bodyPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(2)
                }

                if !visibleTags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(visibleTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (isSelected ? Color.white.opacity(0.15) : Color.gray.opacity(0.15)),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: isFirstInGroup ? 6 : 0,
                bottomLeadingRadius: isLastInGroup ? 6 : 0,
                bottomTrailingRadius: isLastInGroup ? 6 : 0,
                topTrailingRadius: isFirstInGroup ? 6 : 0
            )
            .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 8)
        .contextMenu {
            Button(action: { onTogglePin?() }) {
                Label(email.isPinned ? "Unpin" : "Pin", systemImage: email.isPinned ? "pin.slash" : "pin")
            }
            
            Button(action: { onToggleRead?() }) {
                Label(email.isRead ? "Mark as Unread" : "Mark as Read", 
                      systemImage: email.isRead ? "envelope.badge" : "envelope.open")
            }
            
            Divider()
            
            Button(action: {}) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .disabled(true)
            
            Button(action: {}) {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .disabled(true)
            
            Divider()
            
            Button(action: {}) {
                Label("Tags...", systemImage: "tag")
            }
            .disabled(true)
            
            Divider()
            
            Button(role: .destructive, action: { onDelete?() }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Tags already represented by icons or implied by the current view
    private static let hiddenTags: Set<String> = ["unread", "flagged", "attachment"]

    private var visibleTags: [String] {
        guard let tags = email.tags, !tags.isEmpty else { return [] }
        return tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !Self.hiddenTags.contains($0) && $0 != currentFolder }
    }

    // MARK: - Counterparty resolution

    private struct Participant: Hashable {
        let name: String
        let email: String  // may equal name if no email available
    }

    private static let ownEmails: Set<String> = {
        Set(ConfigManager.shared.getAccounts().map { $0.email.lowercased() })
    }()

    private static let ownNames: Set<String> = {
        Set(ConfigManager.shared.getAccounts().map {
            $0.name.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        })
    }()

    private static func isOwn(_ address: String) -> Bool {
        let email = extractEmail(from: address).lowercased()
        if ownEmails.contains(email) { return true }
        let name = extractName(from: address).lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return ownNames.contains(name)
    }

    private static func extractName(from address: String) -> String {
        if let range = address.range(of: "<") {
            let name = String(address[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return address.trimmingCharacters(in: .whitespaces)
    }

    private static func extractEmail(from address: String) -> String {
        if let start = address.range(of: "<"), let end = address.range(of: ">") {
            return String(address[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return address.trimmingCharacters(in: .whitespaces)
    }

    private static func parseAddressList(_ raw: String) -> [String] {
        raw.components(separatedBy: ",").compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// All non-own participants from thread messages (from + cc), deduplicated, ordered.
    private var counterparties: [Participant] {
        // When thread messages are loaded, use real from/to/cc fields
        if let messages = email.threadMessages, !messages.isEmpty {
            var seen = Set<String>()
            var result: [Participant] = []
            for msg in messages {
                let addresses = [msg.from] + Self.parseAddressList(msg.to ?? "")
                    + Self.parseAddressList(msg.cc ?? "")
                for addr in addresses {
                    guard !Self.isOwn(addr) else { continue }
                    let email = Self.extractEmail(from: addr).lowercased()
                    let key = email.contains("@") ? email : Self.extractName(from: addr).lowercased()
                    if seen.insert(key).inserted {
                        result.append(Participant(
                            name: Self.extractName(from: addr),
                            email: addr
                        ))
                    }
                }
            }
            if !result.isEmpty { return result }
        }

        // Fallback: parse notmuch authors string (before thread load)
        let raw = email.from
        // If it's a single "Name <email>" address, handle directly
        if raw.contains("<") {
            let p = Participant(name: Self.extractName(from: raw), email: raw)
            return Self.isOwn(raw) ? [p] : [p]  // no filtering for single address
        }
        // Split by comma and pipe (notmuch separators), normalize whitespace
        var authors: [String] = []
        for segment in raw.components(separatedBy: ",") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let pipeRange = trimmed.range(of: "|"),
               pipeRange.lowerBound > trimmed.startIndex,
               trimmed[trimmed.index(before: pipeRange.lowerBound)] != " " {
                let before = String(trimmed[..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(trimmed[trimmed.index(after: pipeRange.lowerBound)...]).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { authors.append(before) }
                if !after.isEmpty { authors.append(after) }
            } else {
                authors.append(trimmed)
            }
        }
        let others = authors.filter { !Self.isOwn($0) }
        let final = others.isEmpty ? authors : others
        return final.map { Participant(name: Self.extractName(from: $0), email: $0) }
    }

    private var senderName: String {
        let names = counterparties.map(\.name)
        return names.isEmpty ? Self.extractName(from: email.from) : names.joined(separator: ", ")
    }
}
