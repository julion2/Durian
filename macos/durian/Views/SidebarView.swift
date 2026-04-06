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
import AppKit

struct SidebarView: View {
    @Binding var selectedTagID: String?
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var profileManager: ProfileManager

    @FocusState private var isFocused: Bool

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
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveSelection(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(offset: 1)
            return .handled
        }
    }

    private func moveSelection(offset: Int) {
        let folders = accountManager.mailFolders
        guard !folders.isEmpty else { return }
        let currentIndex = folders.firstIndex { $0.name == selectedTagID } ?? -1
        let newIndex = (currentIndex + offset).clamped(to: 0...(folders.count - 1))
        selectedTagID = folders[newIndex].name
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
                Image(systemName: folder.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 20, alignment: .center)

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

// MARK: - Visual Effect (native sidebar material)

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - Helpers

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
