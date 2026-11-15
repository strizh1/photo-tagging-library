//
//  MergeTagSheet.swift
//  photos analyze
//

import SwiftUI

/// Asks which tag `source` should be merged into, suggesting similar existing tags.
struct MergeTagSheet: View {
    let source: String
    /// Every shot and content tag in the library.
    let existingTags: [String]
    let affectedCount: Int
    var onMerge: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target = ""

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canMerge: Bool {
        !trimmedTarget.isEmpty && trimmedTarget.caseInsensitiveCompare(source) != .orderedSame
    }

    private var candidates: [String] {
        existingTags.filter { $0.caseInsensitiveCompare(source) != .orderedSame }
    }

    /// Tags that look related to `source`: one contains the other, or they share a word
    /// ("Jet planes" ↔ "Planes").
    private var similar: [String] {
        let sourceWords = Set(words(source))
        return candidates
            .filter { tag in
                tag.localizedCaseInsensitiveContains(source) || source.localizedCaseInsensitiveContains(tag)
                    || !sourceWords.isDisjoint(with: words(tag))
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Merge “\(source)” into…")
            } icon: {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.tint)
            }
            .font(.title3.bold())

            TextField("Tag name", text: $target)
                .textFieldStyle(.roundedBorder)
                .onSubmit(merge)
                .textInputSuggestions {
                    ForEach(candidates.filter { target.isEmpty || $0.localizedCaseInsensitiveContains(target) }.prefix(12), id: \.self) { tag in
                        Text(tag).textInputCompletion(tag)
                    }
                }

            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Similar tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout {
                        ForEach(similar, id: \.self) { tag in
                            Button(tag) { target = tag }
                                .buttonStyle(.plain)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    trimmedTarget == tag ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.fill.tertiary),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }

            Text("^[\(affectedCount) photo](inflect: true) will be retagged. Future scans will merge “\(source)” automatically — you can undo that in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge", action: merge)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMerge)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func merge() {
        guard canMerge else { return }
        onMerge(trimmedTarget)
        dismiss()
    }

    private func words(_ tag: String) -> [String] {
        tag.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word in
            // Treat simple plurals as the same word ("plane" / "planes").
            word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
        }
    }
}

/// Settings pane listing remembered merges, so they can be undone.
struct MergedTagsSettings: View {
    @AppStorage(TagMerges.defaultsKey) private var mergesData = Data()
    @AppStorage(LiveTagSync.enabledKey) private var liveSync = true

    private var merges: [(source: String, target: String)] {
        let decoded = (try? JSONDecoder().decode([String: String].self, from: mergesData)) ?? [:]
        return decoded.map { (source: $0.key, target: $0.value) }.sorted { $0.source < $1.source }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Keep a live photo-tags.json in each folder", isOn: $liveSync)
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Lets Claude Code (or any tool) read and edit tags while the app is open. Changes sync both ways within a few seconds. Tags you added can’t be removed through the file. A CLAUDE.md with instructions is added unless the folder already has one. Turning this off stops syncing but leaves the files in place.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if merges.isEmpty {
                    Text("Nothing here yet. Right-click a tag in the sidebar to rename, merge or delete it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(merges, id: \.source) { merge in
                        HStack {
                            Text(merge.source)
                            Image(systemName: merge.target.isEmpty ? "trash" : "arrow.right")
                                .foregroundStyle(.secondary)
                            Text(merge.target.isEmpty ? "Deleted" : merge.target)
                                .bold()
                            Spacer()
                            Button("Stop Merging", systemImage: "xmark.circle.fill") {
                                TagMerges.remove(source: merge.source)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Stop applying this in future scans")
                        }
                    }
                }
            } header: {
                Text("Renamed, Merged & Deleted Tags")
            } footer: {
                Text("Removing an entry only affects future scans. Photos keep the new name until you re-analyze them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }
}

/// Asks for a new name for a tag or quality verdict.
struct RenameSheet: View {
    let title: String
    let currentName: String
    let note: String
    var actionTitle = "Rename"
    var onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "pencil")
                    .foregroundStyle(.tint)
            }
            .font(.title3.bold())

            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: rename)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed == currentName)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { name = currentName }
    }

    private func rename() {
        guard !trimmed.isEmpty, trimmed != currentName else { return }
        onRename(trimmed)
        dismiss()
    }
}

/// Reviews groups of near-identical tags before merging them.
struct SimilarTagsSheet: View {
    let groups: [SimilarTags.Group]
    var onMerge: ([SimilarTags.Group]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<String> = []
    @AppStorage(LibraryScanner.autoMergeKey) private var autoMerge = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Merge Similar Tags")
            } icon: {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.tint)
            }
            .font(.title3.bold())

            if groups.isEmpty {
                ContentUnavailableView(
                    "All Tidy",
                    systemImage: "checkmark.seal",
                    description: Text("No tags that differ only in case, plurals or punctuation.")
                )
                .frame(height: 180)
            } else {
                Text("These tags look like the same thing spelled differently. Each group merges into the most used spelling.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(groups) { group in
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(group.id) },
                            set: { if $0 { excluded.remove(group.id) } else { excluded.insert(group.id) } }
                        )) {
                            HStack(spacing: 6) {
                                Text(group.sources.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.tertiary)
                                Text(group.target)
                                    .bold()
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 320)
            }

            Toggle("Merge similar tags automatically after every scan", isOn: $autoMerge)

            HStack {
                Spacer()
                Button(groups.isEmpty ? "Done" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !groups.isEmpty {
                    Button("Merge") {
                        onMerge(groups.filter { !excluded.contains($0.id) })
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(excluded.count == groups.count)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
