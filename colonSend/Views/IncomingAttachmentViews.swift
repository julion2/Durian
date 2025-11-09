//
//  IncomingAttachmentViews.swift
//  colonSend
//
//  Attachment display components for incoming emails
//

import SwiftUI

struct IncomingAttachmentListView: View {
    let attachments: [IncomingAttachmentMetadata]
    let onDownload: (IncomingAttachmentMetadata) -> Void
    let onPreview: (IncomingAttachmentMetadata) -> Void
    
    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attachments (\(attachments.count))")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            IncomingAttachmentChip(
                                attachment: attachment,
                                onDownload: { onDownload(attachment) },
                                onPreview: { onPreview(attachment) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct IncomingAttachmentChip: View {
    let attachment: IncomingAttachmentMetadata
    let onDownload: () -> Void
    let onPreview: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(attachment.sizeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Download attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(8)
    }
}

#Preview("Attachment List") {
    IncomingAttachmentListView(
        attachments: [
            IncomingAttachmentMetadata(
                section: "2",
                filename: "Proposal.pdf",
                mimeType: "application/pdf",
                sizeBytes: 2_300_000
            ),
            IncomingAttachmentMetadata(
                section: "3",
                filename: "Screenshot.png",
                mimeType: "image/png",
                sizeBytes: 458_000,
                disposition: .inline
            ),
            IncomingAttachmentMetadata(
                section: "4",
                filename: "Report.xlsx",
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                sizeBytes: 18_200_000
            )
        ],
        onDownload: { _ in },
        onPreview: { _ in }
    )
    .frame(width: 600)
}
