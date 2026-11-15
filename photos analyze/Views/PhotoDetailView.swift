//
//  PhotoDetailView.swift
//  photos analyze
//

import SwiftUI
import AppKit
import SwiftData

struct PhotoDetailView: View {
    let photo: PhotoRecord
    /// Content tags used anywhere in the library, offered as autocomplete suggestions.
    var knownContentTags: [String] = []
    /// The user's own tags used anywhere in the library.
    var knownUserTags: [String] = []
    var onSelectTag: (String) -> Void = { _ in }
    var onTrash: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @State private var isChoosingFileToOpen = false

    var body: some View {
        let exif = photo.exif
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ThumbnailView(url: photo.url, maxPixelSize: 1600, contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 420)
                    .clipShape(.rect(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                    .overlay(alignment: .bottomTrailing) {
                        Button("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                            openWindow(id: "viewer", value: ViewerItem(photo: photo))
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .padding(10)
                        .help("View at full resolution (best-quality file)")
                    }
                    .onTapGesture {
                        openWindow(id: "viewer", value: ViewerItem(photo: photo))
                    }
                    .padding(.bottom, 4)

                header(exif)

                if !photo.aiEdits.isEmpty {
                    aiEditsCard
                }

                EditableTagGroup(
                    title: "My tags",
                    systemImage: "tag.fill",
                    tags: photo.userTags,
                    tint: .accentColor,
                    suggestions: knownUserTags,
                    emptyMessage: "Add your own tags — rescans never change them.",
                    onSelect: onSelectTag,
                    onAdd: { tag in edit { photo.addUserTag(tag) } },
                    onRemove: { tag in edit { photo.removeUserTag(tag) } }
                )
                .card()
                EditableTagGroup(
                    title: "Type of shot",
                    systemImage: "camera.aperture",
                    tags: photo.shotTags,
                    tint: Theme.shotTint,
                    suggestions: ShotClassifier.allShotTypes,
                    onSelect: onSelectTag,
                    onAdd: { tag in edit { photo.addTag(tag, to: .shot) } },
                    onRemove: { tag in edit { photo.removeTag(tag, from: .shot) } }
                )
                .card()
                EditableTagGroup(
                    title: "In the shot",
                    systemImage: "eye",
                    tags: photo.contentTags,
                    tint: Theme.contentTint,
                    suggestions: knownContentTags,
                    onSelect: onSelectTag,
                    onAdd: { tag in edit { photo.addTag(tag, to: .content) } },
                    onRemove: { tag in edit { photo.removeTag(tag, from: .content) } }
                )
                .card()
                if photo.hasManualEdits {
                    Button("Reset to Automatic Tags", systemImage: "arrow.uturn.backward") {
                        withAnimation(.snappy) { edit { photo.resetManualEdits() } }
                    }
                    .buttonStyle(.glass)
                    .help("Discard your tag edits for this photo")
                }

                cameraCard(exif)

                if !photo.exifTags.isEmpty {
                    TagGroup(
                        title: "Camera & date",
                        systemImage: "calendar",
                        tags: photo.exifTags,
                        tint: Theme.exifTint,
                        onSelect: onSelectTag
                    )
                    .card()
                }

                if let text = photo.recognizedText {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Spotted text", systemImage: "text.viewfinder", tint: .purple)
                        Text(text)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(12)
                    }
                    .card()
                }

                Label(photo.path, systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
    }

    // MARK: Header

    private func header(_ exif: ExifInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(photo.displayName)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                Spacer()
                qualityMenu
            }
            if !photo.variantPaths.isEmpty {
                formatsRow
            }
            if let caption = photo.caption {
                Label {
                    Text(caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "apple.intelligence")
                        .foregroundStyle(.tint)
                }
                .help("Caption written on-device by Apple Intelligence")
            }
            if photo.faceCount > 0 || exif.dateTaken != nil {
                HStack(spacing: 14) {
                    if let date = exif.dateTaken {
                        // Shown in the photo's own time zone, as the camera's clock read.
                        Label(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: exif.timeZone)),
                              systemImage: "calendar")
                    }
                    if photo.faceCount > 0 {
                        Label("^[\(photo.faceCount) face](inflect: true)", systemImage: "person.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            GlassEffectContainer {
                HStack {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(photo.allURLs)
                    }
                    Button(photo.variantPaths.isEmpty ? "Open" : "Open…", systemImage: "arrow.up.forward.app") {
                        if photo.variantPaths.isEmpty {
                            NSWorkspace.shared.open(photo.url)
                        } else {
                            isChoosingFileToOpen = true
                        }
                    }
                    Button("Move to Trash…", systemImage: "trash", role: .destructive, action: onTrash)
                        .labelStyle(.iconOnly)
                        .help("Move this photo’s files to the Trash")
                }
                .buttonStyle(.glass)
            }
            .padding(.top, 4)
            .confirmationDialog(
                "Which version of “\(photo.displayName)” do you want to open?",
                isPresented: $isChoosingFileToOpen
            ) {
                ForEach(photo.allURLs, id: \.self) { url in
                    Button("\(url.pathExtension.uppercased()) — \(url.lastPathComponent)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// The quality badge; clicking it lets you change the verdict.
    private var qualityMenu: some View {
        let verdict = photo.quality
        let tint = verdict?.tint ?? .secondary
        return Menu {
            Picker("Quality", selection: Binding(
                get: { photo.quality },
                set: { newValue in edit { photo.setQuality(newValue) } }
            )) {
                ForEach(QualityVerdict.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.symbol)
                        .tag(Optional(option))
                }
            }
            .pickerStyle(.inline)

            if photo.manualQuality != nil {
                Divider()
                Button(
                    photo.automaticQuality.map { "Use Automatic Rating (\($0.title))" } ?? "Clear Rating",
                    systemImage: "arrow.uturn.backward"
                ) {
                    edit { photo.setQuality(nil) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Label(verdict?.title ?? "Rate…", systemImage: verdict?.symbol ?? "star")
                if photo.manualQuality != nil {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(tint.opacity(0.15)).interactive())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(qualityHelp)
    }

    private var qualityHelp: String {
        let automatic = photo.aestheticScore.map {
            "Aesthetics score \($0.formatted(.number.precision(.fractionLength(2)))) (−1 to 1)."
        } ?? "No automatic score."
        return photo.manualQuality != nil
            ? "You rated this photo. \(automatic) Click to change."
            : "\(automatic) Click to change the rating."
    }

    /// The file formats this photo exists in; the first one is where the tags come from.
    private var formatsRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
            ForEach(Array(photo.formats.enumerated()), id: \.offset) { index, format in
                Text(format)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(index == 0 ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
            }
            Text("Tags come from the \(photo.formats.first ?? "") file")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: AI edits

    private var aiEditsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Made or edited with AI", systemImage: "wand.and.sparkles", tint: Theme.aiTint)
            FlowLayout {
                ForEach(photo.aiEdits, id: \.self) { label in
                    Button {
                        onSelectTag(label)
                    } label: {
                        Label(label, systemImage: Theme.symbol(forAIEdit: label))
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Theme.aiTint.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show all photos with “\(label)”")
                }
            }
            Text("Detected from the file’s metadata (XMP, sidecar files and Content Credentials). Edits that left no metadata can’t be detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: Camera

    @ViewBuilder
    private func cameraCard(_ exif: ExifInfo) -> some View {
        let specs: [(symbol: String, value: String, label: String)] = [
            exif.aperture.map { ("camera.aperture", "ƒ/\($0.formatted(.number.precision(.fractionLength(0...1))))", "Aperture") },
            exif.formattedExposure.map { ("timer", $0, "Shutter") },
            exif.iso.map { ("sun.max", "ISO \($0)", "Sensitivity") },
            exif.focalLength.map { focal in
                let mm = Int((exif.focalLength35mm ?? focal).rounded())
                return ("scope", "\(mm) mm", exif.focalLength35mm != nil ? "35 mm eq." : "Focal length")
            },
        ].compactMap { $0 }

        let size = exif.pixelWidth.flatMap { w in exif.pixelHeight.map { "\(w) × \($0)" } }
        let location = exif.latitude.flatMap { lat in
            exif.longitude.map { String(format: "%.5f, %.5f", lat, $0) }
        }
        let hasDetails = [exif.cameraName, exif.lensModel, size, exif.fileType, location, exif.software]
            .contains { $0?.isEmpty == false }

        if !specs.isEmpty || hasDetails {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: exif.cameraName ?? "Camera", systemImage: "camera.fill", tint: Theme.exifTint)
                if let lens = exif.lensModel {
                    Text(lens)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, -6)
                }

                if !specs.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(specs, id: \.label) { spec in
                            VStack(spacing: 3) {
                                Image(systemName: spec.symbol)
                                    .font(.body)
                                    .foregroundStyle(Theme.exifTint)
                                Text(spec.value)
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(spec.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
                        }
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Flash", exif.flashFired.map { $0 ? "Fired" : "Off" })
                    row("Size", size)
                    row("Format", exif.fileType)
                    row("Location", location)
                    row("Software", exif.software)
                }
                .font(.callout)
            }
            .card()
        }
    }

    /// Applies a tag edit and saves immediately so it isn't lost on quit.
    private func edit(_ change: () -> Void) {
        change()
        try? modelContext.save()
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }
}
