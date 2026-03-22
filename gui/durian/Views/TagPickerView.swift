//
//  TagPickerView.swift
//  Durian
//
//  Raycast-style tag picker popup for toggling tags on emails
//

import SwiftUI

enum TagPickerItem: Hashable {
    case existing(String)
    case create(String)
}

struct TagPickerView: View {
    @Binding var isPresented: Bool
    let currentTags: [String]
    let allTags: [String]
    let onToggleTag: (String, Bool) -> Void

    @State private var filterText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isTextFieldFocused: Bool

    /// Fixed glass height — keeps sampling region constant to prevent color shift on resize
    private let maxGlassHeight: CGFloat = 480

    /// Display items: existing tags (filtered) + optional "create new" entry
    private var displayItems: [TagPickerItem] {
        let filtered: [TagPickerItem]
        if filterText.isEmpty {
            filtered = allTags.map { .existing($0) }
        } else {
            let query = filterText.lowercased()
            filtered = allTags
                .filter { $0.lowercased().contains(query) }
                .map { .existing($0) }
        }

        let trimmed = filterText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && !allTags.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            return filtered + [.create(trimmed)]
        }
        return filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter Input
            filterInputView

            Divider()
                .opacity(0.3)

            if displayItems.isEmpty {
                noResultsView
            } else {
                tagListView
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: filterText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < displayItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress { press in
            if press.modifiers.contains(.control) {
                switch press.key {
                case "j", KeyEquivalent("n"):
                    if selectedIndex < displayItems.count - 1 { selectedIndex += 1 }
                    return .handled
                case "k", KeyEquivalent("p"):
                    if selectedIndex > 0 { selectedIndex -= 1 }
                    return .handled
                default: break
                }
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            toggleSelectedTag()
            filterText = ""
            return .handled
        }
    }

    // MARK: - Subviews

    private var filterInputView: some View {
        HStack(spacing: 14) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .font(.title2)
                .fontWeight(.medium)

            TextField("Filter tags...", text: $filterText)
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
            Image(systemName: "tag")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No matching tags")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var tagListView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayItems.enumerated()), id: \.element) { index, item in
                            Group {
                                switch item {
                                case .existing(let tag):
                                    TagPickerRow(
                                        tag: tag,
                                        isActive: currentTags.contains(tag),
                                        isSelected: index == selectedIndex
                                    )
                                case .create(let tagName):
                                    TagPickerCreateRow(
                                        tagName: tagName,
                                        isSelected: index == selectedIndex
                                    )
                                }
                            }
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                toggleSelectedTag()
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            Divider()
                .opacity(0.3)

            // Footer with keyboard hints
            HStack {
                Text("\(displayItems.count) tag\(displayItems.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                HStack(spacing: 12) {
                    Text("↑↓ Navigate")
                    Text("↵ Toggle")
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

    private func toggleSelectedTag() {
        guard selectedIndex < displayItems.count else { return }

        switch displayItems[selectedIndex] {
        case .existing(let tag):
            let isAdding = !currentTags.contains(tag)
            onToggleTag(tag, isAdding)
        case .create(let tag):
            onToggleTag(tag, true)
        }
    }

    private func close() {
        filterText = ""
        isPresented = false
    }
}

// MARK: - Tag Picker Row

struct TagPickerRow: View {
    let tag: String
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .font(.body)

            Text(tag)
                .font(.body)
                .foregroundStyle(isActive ? .primary : .secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Create New Tag Row

struct TagPickerCreateRow: View {
    let tagName: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .foregroundStyle(Color.accentColor)
                .font(.body)

            Text("Create \"\(tagName)\"")
                .font(.body)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
