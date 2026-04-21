//
//  SidebarView.swift
//  Durian
//
//  Custom sidebar that respects per-profile accent color.
//  macOS's native List(.sidebar) selection uses NSColor.controlAccentColor
//  which SwiftUI's .tint() cannot override. This view reproduces the
//  native look (vibrancy, pill selection, hover, keyboard nav) while
//  giving us full control over the accent color.
//

import SwiftUI

struct SidebarView: View {
    @Binding var selectedTagID: String?
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var profileManager: ProfileManager

    var body: some View {
        VStack(spacing: 0) {
            // Profile Header
            Text(profileManager.currentProfile?.name ?? "All")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            // Tag list
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Section header
                    Text("Tags")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 4)

                    // Rows
                    ForEach(accountManager.mailFolders) { folder in
                        SidebarRow(
                            folder: folder,
                            unreadCount: accountManager.folderUnreadCounts[folder.name] ?? 0,
                            isSelected: selectedTagID == folder.name,
                            accentColor: profileManager.resolvedAccentColor
                        ) {
                            selectedTagID = folder.name
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Row

private struct SidebarRow: View {
    let folder: MailFolder
    let unreadCount: Int
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = folder.icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .frame(width: 20, alignment: .center)
                }

                Text(folder.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Spacer()

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 12))
                        .fontWeight(.medium)
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }

    private var backgroundFill: Color {
        if isSelected {
            return accentColor
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}

