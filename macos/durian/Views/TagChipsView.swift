//
//  TagChipsView.swift
//  Durian
//
//  Reusable tag chips view with add/remove support
//

import SwiftUI

struct TagChipsView: View {
    let tags: [String]
    let onRemoveTag: (String) -> Void
    let onAddTag: (String) -> Void

    @State private var isAddingTag = false
    @State private var newTagText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                tagChip(tag)
            }
            addButton
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)

            Button {
                onRemoveTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ProfileManager.shared.resolvedAccentColor.opacity(0.75))
        .cornerRadius(4)
    }

    @ViewBuilder
    private var addButton: some View {
        if isAddingTag {
            TextField("tag", text: $newTagText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isTextFieldFocused)
                .frame(width: 80)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ProfileManager.shared.resolvedAccentColor, lineWidth: 1.5)
                )
                .cornerRadius(6)
                .onSubmit {
                    let tag = newTagText.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty {
                        onAddTag(tag)
                    }
                    newTagText = ""
                    isAddingTag = false
                }
                .onExitCommand {
                    newTagText = ""
                    isAddingTag = false
                }
                .onAppear {
                    isTextFieldFocused = true
                }
        } else {
            Button {
                isAddingTag = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.Detail.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add tag")
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(4)
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.origins.count else { break }
            let origin = CGPoint(
                x: bounds.minX + result.origins[index].x,
                y: bounds.minY + result.origins[index].y
            )
            subview.place(at: origin, anchor: .topLeading, proposal: .unspecified)
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var origins: [CGPoint]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return ArrangeResult(
            size: CGSize(width: maxWidth, height: y + rowHeight),
            origins: origins
        )
    }
}
