//
//  IncomingAttachmentViews.swift
//  colonSend
//
//  Attachment display components for incoming emails
//

import SwiftUI
import QuickLook

struct IncomingAttachmentListView: View {
    let attachments: [IncomingAttachmentMetadata]
    let emailUID: UInt32
    let client: IMAPClient
    
    @StateObject private var manager = AttachmentManager.shared
    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
    
    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        IncomingAttachmentChip(
                            attachment: attachment,
                            emailUID: emailUID,
                            client: client,
                            downloadState: manager.downloadStates[attachment.id] ?? .notDownloaded,
                            onDownload: {
                                Task {
                                    await manager.saveAttachment(attachment, emailUID: emailUID, client: client)
                                }
                            },
                            onPreview: {
                                Task {
                                    do {
                                        let url = try await manager.previewAttachment(attachment, emailUID: emailUID, client: client)
                                        quickLookURL = url
                                        showQuickLook = true
                                    } catch {
                                        print("ERROR: Failed to preview attachment: \(error)")
                                    }
                                }
                            },
                            onOpen: {
                                Task {
                                    await manager.openAttachment(attachment, emailUID: emailUID, client: client)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .quickLookPreview($quickLookURL)
        }
    }
}

struct IncomingAttachmentChip: View {
    let attachment: IncomingAttachmentMetadata
    let emailUID: UInt32
    let client: IMAPClient
    let downloadState: AttachmentDownloadState
    let onDownload: () -> Void
    let onPreview: () -> Void
    let onOpen: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            // Icon
            Image(systemName: attachment.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // Filename and size
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(attachment.sizeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // Download state indicator
            Group {
                switch downloadState {
                case .notDownloaded:
                    HStack(spacing: 4) {
                        Button(action: onPreview) {
                            Image(systemName: "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Preview attachment")
                        
                        Button(action: onDownload) {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Download attachment")
                    }
                    .foregroundStyle(.secondary)
                    
                case .downloading(let progress):
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                case .downloaded:
                    HStack(spacing: 4) {
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.forward.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Open attachment")
                        
                        Button(action: onPreview) {
                            Image(systemName: "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Preview attachment")
                    }
                    
                case .failed(let error):
                    Button(action: onDownload) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Failed: \(error). Tap to retry.")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click to preview
            onPreview()
        }
    }
}

//#Preview("Attachment List") {
//    // Preview disabled - requires IMAPClient instance
//}
