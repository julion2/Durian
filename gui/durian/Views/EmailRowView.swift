import SwiftUI

struct EmailRowView: View {
    let email: MailMessage
    var isSelected: Bool = false
    var isFirstInGroup: Bool = true   // First in contiguous selection group (top corners rounded)
    var isLastInGroup: Bool = true    // Last in contiguous selection group (bottom corners rounded)
    
    // Context menu callbacks
    var onTogglePin: (() -> Void)?
    var onToggleRead: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: email.from, email: email.from, size: 32)

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

                if let tags = email.tags, !tags.isEmpty {
                    Text(tags)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.5) : Color.gray.opacity(0.6))
                        .lineLimit(1)
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

    private var senderName: String {
        let from = email.from
        if let range = from.range(of: "<") {
            let namePart = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !namePart.isEmpty { return namePart }
        }
        return from
    }
}
