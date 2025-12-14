//
//  EmailRowView.swift
//  colonSend
//
//  Single email row for the list view (Canary Mail inspired)
//

import SwiftUI

struct EmailRowView: View {
    let email: MailMessage
    var isSelected: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread indicator
            Circle()
                .fill(email.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            // Avatar
            AvatarView(name: email.from, size: 32)
            
            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: Sender + Date
                HStack {
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
                
                // Row 2: Subject + Attachment icon
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
                
                // Row 3: Body preview (if loaded)
                if let preview = email.bodyPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(2)
                }
                
                // Row 4: Tags (small, tertiary)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
    }
    
    /// Extract display name from "Name <email>" format
    private var senderName: String {
        let from = email.from
        if let range = from.range(of: "<") {
            let namePart = String(from[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !namePart.isEmpty {
                return namePart
            }
        }
        return from
    }
}

#Preview {
    List {
        EmailRowView(email: MailMessage(
            threadId: "1",
            subject: "Julian Schenker, here are your monthly goal updates...",
            from: "Atlassian Home <notifications@atlassian.com>",
            date: "8 Sep",
            timestamp: 1725782400,
            tags: "inbox"
        ), isSelected: true)
        
        EmailRowView(email: MailMessage(
            threadId: "2",
            subject: "Receipt for your Lime ride",
            from: "Lime Receipts <receipts@li.me>",
            date: "7 Sep",
            timestamp: 1725696000,
            tags: "inbox, attachment"
        ), isSelected: false)
    }
}
