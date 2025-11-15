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
                .padding(.vertical, 4)
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
        HStack(spacing: 8) {
            // Icon
            Image(systemName: attachment.icon)
                .font(.body)
                .foregroundStyle(.secondary)
            
            // Filename and size
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(attachment.sizeFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Download state indicator
            Group {
                switch downloadState {
                case .notDownloaded:
                    HStack(spacing: 6) {
                        Button(action: onPreview) {
                            Image(systemName: "eye")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .help("Preview attachment")
                        
                        Button(action: onDownload) {
                            Image(systemName: "arrow.down.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .help("Download attachment")
                    }
                    .foregroundStyle(.secondary)
                    
                case .downloading(let progress):
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                case .downloaded:
                    HStack(spacing: 6) {
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.forward.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Open attachment")
                        
                        Button(action: onPreview) {
                            Image(systemName: "eye")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .help("Preview attachment")
                    }
                    
                case .failed(let error):
                    Button(action: onDownload) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Failed: \(error). Tap to retry.")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(10)
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
