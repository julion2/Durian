//
//  FolderPickerView.swift
//  Durian
//
//  Raycast-style folder picker popup for quick folder switching
//

import SwiftUI

struct FolderPickerView: View {
    @Binding var isPresented: Bool
    let folders: [MailFolder]
    let unreadCounts: [String: Int]
    let currentFolder: String
    let onSelect: (String) -> Void

    @State private var filterText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isTextFieldFocused: Bool

    private let maxGlassHeight: CGFloat = 480

    private var displayFolders: [MailFolder] {
        let nonSection = folders.filter { !$0.isSection }
        if filterText.isEmpty { return nonSection }
        let query = filterText.lowercased()
        return nonSection.filter { $0.displayName.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterInputView

            Divider()
                .opacity(0.3)

            if displayFolders.isEmpty {
                noResultsView
            } else {
                folderListView
            }
        }
        .frame(width: 480)
        .background(alignment: .top) {
            Color.clear
                .frame(width: 480, height: maxGlassHeight)
                .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)), in: .rect(cornerRadius: 16))
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 32, y: 16)
        .onAppear {
            // Pre-select current folder
            if let idx = displayFolders.firstIndex(where: { $0.name == currentFolder }) {
                selectedIndex = idx
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextFieldFocused = true
            }
        }

        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < displayFolders.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .popupSelectNext)) { _ in
            if selectedIndex < displayFolders.count - 1 { selectedIndex += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popupSelectPrev)) { _ in
            if selectedIndex > 0 { selectedIndex -= 1 }
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            selectFolder()
            return .handled
        }
        .onChange(of: filterText) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Subviews

    private var filterInputView: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.title2)
                .fontWeight(.medium)

            TextField("Go to folder...", text: $filterText)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($isTextFieldFocused)

            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var noResultsView: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No matching folders")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var folderListView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(displayFolders.enumerated()), id: \.element.id) { index, folder in
                        FolderPickerRow(
                            folder: folder,
                            position: index + 1,
                            unreadCount: unreadCounts[folder.name] ?? 0,
                            isCurrent: folder.name == currentFolder,
                            isSelected: index == selectedIndex
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            selectFolder()
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider()
                .opacity(0.3)

            HStack {
                Text("\(displayFolders.count) folder\(displayFolders.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                HStack(spacing: 12) {
                    Text("↑↓ Navigate")
                    Text("↵ Select")
                    Text("⎋ Close")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Actions

    private func selectFolder() {
        guard selectedIndex < displayFolders.count else { return }
        onSelect(displayFolders[selectedIndex].name)
        close()
    }

    private func close() {
        filterText = ""
        isPresented = false
    }
}

// MARK: - Folder Picker Row

private struct FolderPickerRow: View {
    let folder: MailFolder
    let position: Int
    let unreadCount: Int
    let isCurrent: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let icon = folder.icon {
                Image(systemName: icon)
                    .foregroundStyle(isCurrent ? ProfileManager.shared.resolvedAccentColor : .secondary)
                    .font(.body)
                    .frame(width: 20, alignment: .center)
            }

            Text(folder.displayName)
                .font(.body)
                .foregroundStyle(isCurrent ? .primary : .secondary)

            Spacer()

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            if position <= 9 {
                Text("g\(position)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? ProfileManager.shared.resolvedAccentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
