//
//  TagChips.swift
//  photos analyze
//

import SwiftUI

/// Lays out subviews left-to-right, wrapping onto new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > maxWidth {
                let nextY = row.y + row.height + spacing
                rows.append(Row(y: nextY))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// A titled group of tag chips that can be removed (✕) and added to, with
/// autocomplete suggestions. Tapping a chip's title calls `onSelect`.
struct EditableTagGroup: View {
    let title: String
    var systemImage = "tag"
    let tags: [String]
    let tint: Color
    /// Tags offered as autocomplete suggestions while typing.
    var suggestions: [String] = []
    var emptyMessage = "Nothing yet — add the first one below."
    /// Hide the "Add a tag" field (for tags that only come from elsewhere).
    var allowsAdding = true
    var onSelect: (String) -> Void = { _ in }
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void

    @State private var newTag = ""

    /// Suggestions not already applied, filtered by what has been typed so far.
    private var matchingSuggestions: [String] {
        let applied = Set(tags.map { $0.lowercased() })
        return suggestions
            .filter { !applied.contains($0.lowercased()) }
            .filter { newTag.isEmpty || $0.localizedCaseInsensitiveContains(newTag) }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, systemImage: systemImage, tint: tint)

            if tags.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Button(tag) { onSelect(tag) }
                                .buttonStyle(.plain)
                                .help("Show all photos tagged “\(tag)”")
                            Button("Remove \(tag)", systemImage: "xmark") {
                                withAnimation(.snappy) { onRemove(tag) }
                            }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .help("Remove this tag")
                        }
                        .font(.callout)
                        .padding(.leading, 10)
                        .padding(.trailing, 7)
                        .padding(.vertical, 4)
                        .chipStyle(tint: tint)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }

            if allowsAdding {
            HStack(spacing: 6) {
                TextField("Add a tag…", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(commit)
                    .textInputSuggestions {
                        ForEach(matchingSuggestions, id: \.self) { suggestion in
                            Text(suggestion)
                                .textInputCompletion(suggestion)
                        }
                    }
                Button("Add", systemImage: "plus", action: commit)
                    .labelStyle(.iconOnly)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            }
        }
    }

    private func commit() {
        withAnimation(.snappy) { onAdd(newTag) }
        newTag = ""
    }
}

/// A titled group of tag chips. Tapping a chip calls `onSelect`.
struct TagGroup: View {
    let title: String
    var systemImage = "tag"
    let tags: [String]
    let tint: Color
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, systemImage: systemImage, tint: tint)
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { onSelect(tag) }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .chipStyle(tint: tint)
                            .help("Show all photos tagged “\(tag)”")
                    }
                }
            }
        }
    }
}

/// Tinted capsule background for tag chips that brightens under the pointer.
private struct ChipStyle: ViewModifier {
    let tint: Color
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(tint.opacity(isHovering ? 0.28 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
    }
}

private extension View {
    func chipStyle(tint: Color) -> some View { modifier(ChipStyle(tint: tint)) }
}
