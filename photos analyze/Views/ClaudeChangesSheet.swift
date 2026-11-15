//
//  ClaudeChangesSheet.swift
//  photos analyze
//

import SwiftUI

/// Shows Claude's proposed changes so the user can pick what to apply.
struct ClaudeChangesSheet: View {
    let plan: ClaudePlan
    var onApply: (_ mergeIDs: Set<String>, _ deleteIDs: Set<String>, _ addTags: Bool, _ removeTags: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<String> = []
    @State private var addTags = true
    @State private var removeTags = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Review Claude’s Changes")
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
            }
            .font(.title3.bold())

            if let summary = plan.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.isEmpty {
                ContentUnavailableView(
                    "Nothing to Apply",
                    systemImage: "checkmark.seal",
                    description: Text("Claude’s file has no changes that apply to the current library.")
                )
                .frame(height: 160)
            } else {
                List {
                    if !plan.merges.isEmpty {
                        Section("Merge & rename (\(plan.merges.count))") {
                            ForEach(plan.merges) { item in
                                toggle(item.id) {
                                    HStack(spacing: 6) {
                                        Text(item.from)
                                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                        Text(item.to).bold()
                                        Text("· ^[\(item.photoCount) photo](inflect: true)").foregroundStyle(.secondary)
                                    }
                                    reason(item.reason)
                                }
                            }
                        }
                    }
                    if !plan.deletes.isEmpty {
                        Section("Delete tags (\(plan.deletes.count))") {
                            ForEach(plan.deletes) { item in
                                toggle(item.id) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash").foregroundStyle(.red)
                                        Text(item.tag)
                                        Text("· removed from ^[\(item.removableCount) photo](inflect: true)").foregroundStyle(.secondary)
                                    }
                                    if item.protectedCount > 0 {
                                        Label("Kept on ^[\(item.protectedCount) photo](inflect: true) where you added it", systemImage: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                    reason(item.reason)
                                }
                            }
                        }
                    }
                    if plan.addCount > 0 || plan.removeCount > 0 {
                        Section("Photo tags") {
                            if plan.addCount > 0 {
                                Toggle(isOn: $addTags) {
                                    Text("Add ^[\(plan.addCount) tag](inflect: true) Claude saw in the photos")
                                    Text("\(plan.addShotCount) to Type of shot, \(plan.addCount - plan.addShotCount) to In the shot.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if plan.removeCount > 0 {
                                Toggle(isOn: $removeTags) {
                                    Text("Remove ^[\(plan.removeCount) wrong tag](inflect: true) from photos")
                                    Text("Only automatic tags; tags you added are never removed.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 420)
            }

            if plan.protectedRemovals > 0 || !plan.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if plan.protectedRemovals > 0 {
                        Label("Ignored ^[\(plan.protectedRemovals) request](inflect: true) to remove tags you added.", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    }
                    // Notes can repeat (two merges of the same missing tag), so identify them by position.
                    ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            HStack {
                Spacer()
                Button(plan.isEmpty ? "Done" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !plan.isEmpty {
                    Button("Apply Changes") {
                        onApply(
                            Set(plan.merges.map(\.id)).subtracting(excluded),
                            Set(plan.deletes.map(\.id)).subtracting(excluded),
                            addTags,
                            removeTags
                        )
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func toggle(_ id: String, @ViewBuilder label: () -> some View) -> some View {
        Toggle(isOn: Binding(
            get: { !excluded.contains(id) },
            set: { if $0 { excluded.remove(id) } else { excluded.insert(id) } }
        )) {
            VStack(alignment: .leading, spacing: 2) { label() }
        }
    }

    @ViewBuilder
    private func reason(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
