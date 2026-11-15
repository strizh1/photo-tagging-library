//
//  ContentView.swift
//  photos analyze
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all
    case folder(String)
    case tag(String)
    case quality(QualityVerdict)
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScannedFolder.addedAt) private var folders: [ScannedFolder]
    @Query(sort: \PhotoRecord.path) private var photos: [PhotoRecord]

    @State private var scanner = LibraryScanner()
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var selectedPhotoID: PersistentIdentifier?
    @State private var searchText = ""
    @State private var isImporting = false
    @State private var infoMessage: String?
    @State private var similarGroups: [SimilarTags.Group]?
    @State private var isAddingTagToShown = false
    @State private var photoToTrash: PhotoRecord?
    @State private var claudePlan: ClaudePlanItem?
    @State private var liveSync: LiveTagSync?

    var body: some View {
        let visiblePhotos = filteredPhotos
        NavigationSplitView {
            SidebarView(
                folders: folders,
                photos: photos,
                selection: $sidebarSelection,
                onRemove: { scanner.removeFolder($0, context: modelContext) },
                onMerge: { source, target, isRename in
                    let changed = scanner.mergeTag(source, into: target, photos: photos, context: modelContext)
                    if sidebarSelection == .tag(source) {
                        sidebarSelection = .tag(target)
                    }
                    if !isRename {
                        infoMessage = "Merged “\(source)” into “\(target)” on \(changed == 1 ? "1 photo" : "\(changed) photos")."
                    }
                },
                onDelete: { tag in
                    scanner.deleteTag(tag, photos: photos, context: modelContext)
                    if sidebarSelection == .tag(tag) { sidebarSelection = .all }
                }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            PhotoGridView(photos: visiblePhotos, selection: $selectedPhotoID, onTrash: { photoToTrash = $0 })
                .navigationTitle(title)
                .navigationSubtitle(Text("^[\(visiblePhotos.count) photo](inflect: true)"))
                .searchable(text: $searchText, prompt: "Try “dog”, “sunset” or “Canon”")
                .overlay {
                    if photos.isEmpty && !scanner.isScanning {
                        ContentUnavailableView {
                            Label {
                                Text("Let’s Meet Your Photos")
                            } icon: {
                                Image(systemName: "photo.stack")
                                    .foregroundStyle(.tint)
                                    .symbolEffect(.bounce, options: .repeat(.periodic(delay: 3)))
                            }
                        } description: {
                            Text("Point me at a folder and I’ll sort out the portraits, sunsets and pets — subfolders included. Everything stays on your Mac.")
                        } actions: {
                            Button("Choose a Folder…", systemImage: "folder.badge.plus") { isImporting = true }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                        }
                    } else if visiblePhotos.isEmpty && !photos.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if scanner.isScanning {
                        ScanProgressBar(scanner: scanner)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.smooth, value: scanner.isScanning)
                .navigationSplitViewColumnWidth(min: 360, ideal: 600)
        } detail: {
            if let photo = photos.first(where: { $0.persistentModelID == selectedPhotoID }) {
                PhotoDetailView(
                    photo: photo,
                    knownContentTags: knownContentTags,
                    knownUserTags: Array(Set(photos.flatMap(\.userTags))).sorted(),
                    onSelectTag: { tag in sidebarSelection = .tag(tag) },
                    onTrash: { photoToTrash = photo }
                )
            } else {
                ContentUnavailableView(
                    "Pick a Photo",
                    systemImage: "hand.point.left",
                    description: Text("Choose any photo to see what’s in it, how it was shot and the camera behind it.")
                )
            }
        }
        .toolbar { toolbarContent(visiblePhotos: visiblePhotos) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { scanner.addFolder(url, context: modelContext) }
            case .failure(let error):
                scanner.lastError = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { scanner.lastError != nil },
            set: { if !$0 { scanner.lastError = nil } }
        )) {
            Button("OK") { scanner.lastError = nil }
        } message: {
            Text(scanner.lastError ?? "")
        }
        .alert(infoMessage ?? "", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK") { infoMessage = nil }
        }
        .task {
            scanner.restoreAccess(to: folders)
            // Claude tags from before they were sorted into shot / content.
            if photos.contains(where: { !$0.claudeTags.isEmpty }) {
                let sorter = TagSorter(library: photos)
                for photo in photos { photo.sortLegacyClaudeTags(using: { sorter.kind(for: $0) }) }
                try? modelContext.save()
            }
            // Clean up photos deleted outside the app since last time (safely: see
            // `removeMissingPhotos`).
            scanner.removeMissingPhotos(folders: folders, photos: photos, context: modelContext)
            // Add implied tags (Surfing → Watersport) to photos analyzed before they existed.
            scanner.refreshDerivedTags(photos: photos, context: modelContext)
            // Keep photo-tags.json in each folder in sync, both ways.
            if liveSync == nil {
                liveSync = LiveTagSync(context: modelContext, scanner: scanner)
                liveSync?.start()
            }
        }
        .confirmationDialog(
            "Move “\(photoToTrash?.displayName ?? "")” to the Trash?",
            isPresented: Binding(get: { photoToTrash != nil }, set: { if !$0 { photoToTrash = nil } }),
            presenting: photoToTrash
        ) { photo in
            Button(photo.variantPaths.isEmpty ? "Move to Trash" : "Move \(photo.allURLs.count) Files to Trash", role: .destructive) {
                if selectedPhotoID == photo.persistentModelID { selectedPhotoID = nil }
                scanner.moveToTrash(photo, context: modelContext)
            }
        } message: { photo in
            Text("\(photo.allURLs.map(\.lastPathComponent).joined(separator: ", ")) will be moved to the Trash, where you can restore it. Its tags, rating and edits in this app are removed and can’t be restored.")
        }
        .alert(
            "\(scanner.pendingMissing.count) photos are no longer on disk",
            isPresented: Binding(get: { !scanner.pendingMissing.isEmpty }, set: { _ in })
        ) {
            Button("Remove from Library", role: .destructive) {
                if let selected = selectedPhotoID, scanner.pendingMissing.contains(where: { $0.persistentModelID == selected }) {
                    selectedPhotoID = nil
                }
                scanner.confirmRemovingMissing(context: modelContext)
            }
            Button("Keep for Now", role: .cancel) { scanner.pendingMissing = [] }
        } message: {
            Text("Their files were deleted or moved outside the app. Removing them deletes their tags and ratings from the library. Nothing on disk is changed. If they’re on a drive that’s being reconnected or files you’re moving back, choose Keep for Now.")
        }
        .sheet(item: Binding(
            get: { similarGroups.map { SimilarSheetItem(groups: $0) } },
            set: { if $0 == nil { similarGroups = nil } }
        )) { item in
            SimilarTagsSheet(groups: item.groups) { chosen in
                let count = scanner.mergeSimilarTags(chosen, photos: photos, context: modelContext)
                infoMessage = "Merged \(count) similar tags."
            }
        }
        .sheet(item: $claudePlan) { item in
            ClaudeChangesSheet(plan: item.plan) { mergeIDs, deleteIDs, addTags, removeTags in
                item.plan.apply(mergeIDs: mergeIDs, deleteIDs: deleteIDs, addTags: addTags, removeTags: removeTags,
                                scanner: scanner, photos: photos, context: modelContext)
            }
        }
        .sheet(isPresented: $isAddingTagToShown) {
            RenameSheet(
                title: "Add a Tag to \(visiblePhotos.count) Photos",
                currentName: "",
                note: "Adds one of your own tags to every photo currently shown. My Tags are never changed by rescans.",
                actionTitle: "Add Tag",
                onRename: { tag in
                    for photo in visiblePhotos { photo.addUserTag(tag) }
                    try? modelContext.save()
                }
            )
        }
    }

    // MARK: Filtering

    private var filteredPhotos: [PhotoRecord] {
        photos.filter { photo in
            let matchesSidebar: Bool = switch sidebarSelection {
            case .all, nil: true
            case .folder(let path): photo.path.hasPrefix(path + "/")
            case .tag(let tag): photo.allTags.contains(tag)
            case .quality(let verdict): photo.quality == verdict
            }
            return matchesSidebar && photo.matches(search: searchText)
        }
    }

    /// Every distinct content tag in the library, for autocomplete while editing.
    private var knownContentTags: [String] {
        Array(Set(photos.flatMap(\.contentTags))).sorted()
    }

    private var title: String {
        switch sidebarSelection {
        case .all, nil: "All Photos"
        case .folder(let path): URL(fileURLWithPath: path).lastPathComponent
        case .tag(let tag): tag
        case .quality(let verdict): verdict.title
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(visiblePhotos: [PhotoRecord]) -> some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Folder", systemImage: "folder.badge.plus") { isImporting = true }
                .help("Choose a folder to analyze (subfolders included)")

            Menu("Rescan", systemImage: "arrow.clockwise") {
                Button("Analyze New & Changed Photos") {
                    scanner.scan(folders, context: modelContext)
                }
                Button("Re-analyze Everything") {
                    scanner.scan(folders, context: modelContext, force: true)
                }
            }
            .disabled(folders.isEmpty || scanner.isScanning)

            Toggle(isOn: $scanner.useAI) {
                Label("AI Captions", systemImage: "apple.intelligence")
            }
            .disabled(!SceneDescriber.isAvailable || scanner.isScanning)
            .help(SceneDescriber.unavailableReason
                  ?? "Use the on-device Apple Intelligence model to caption photos and add extra tags (slower)")

            Menu("Tags", systemImage: "tag") {
                Button("Add My Tag to \(visiblePhotos.count == 1 ? "1 Shown Photo" : "\(visiblePhotos.count) Shown Photos")…", systemImage: "tag.fill") {
                    isAddingTagToShown = true
                }
                .disabled(visiblePhotos.isEmpty)
                Button("Merge Similar Tags…", systemImage: "arrow.triangle.merge") {
                    similarGroups = SimilarTags.groups(in: LibraryScanner.tagCounts(photos))
                }
            }
            .disabled(photos.isEmpty || scanner.isScanning)

            Menu("Import & Export", systemImage: "square.and.arrow.up.on.square") {
                Button("Export \(visiblePhotos.count == 1 ? "1 Photo" : "\(visiblePhotos.count) Photos") for Claude…", systemImage: "sparkles") {
                    exportForClaude(visiblePhotos)
                }
                .disabled(visiblePhotos.isEmpty)
                Button("Import Claude’s Changes…", systemImage: "sparkles.rectangle.stack") { importClaudeChanges() }
                    .disabled(photos.isEmpty)
                Divider()
                Button("Import Tags from JSON…", systemImage: "square.and.arrow.down") { importJSON() }
                    .disabled(photos.isEmpty)
                Divider()
                Button("Export Tags as JSON…") { exportJSON(visiblePhotos) }
                    .disabled(visiblePhotos.isEmpty)
                Button("Write Tags to Finder") {
                    let count = scanner.writeFinderTags(for: visiblePhotos)
                    infoMessage = "Wrote Finder tags to \(count) photos."
                }
                .disabled(visiblePhotos.isEmpty)
            }
            .disabled(scanner.isScanning)
        }
    }

    private func exportForClaude(_ records: [PhotoRecord]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the folder for Claude (photos’ tags, previews and instructions)"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        scanner.exportForClaude(records, into: parent) { folder in
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            infoMessage = "Exported to “\(folder.lastPathComponent)”. In Claude Code, open that folder and ask Claude to follow README_FOR_CLAUDE.md. Then use Import Claude’s Changes."
        }
    }

    private func importClaudeChanges() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Review Changes"
        panel.message = "Choose the “Photos for Claude” folder that Claude wrote changes.json into"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            claudePlan = ClaudePlanItem(plan: try ClaudePlan(folder: folder, photos: photos))
        } catch CocoaError.fileReadNoSuchFile {
            scanner.lastError = "There’s no changes.json in “\(folder.lastPathComponent)” yet. Ask Claude to write it there first."
        } catch {
            scanner.lastError = "Couldn’t read Claude’s changes: \(error.localizedDescription)"
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a JSON file exported from this app"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try scanner.importJSON(Data(contentsOf: url), photos: photos, context: modelContext)
            infoMessage = "Imported tags for \(result.updated) photos."
                + (result.unmatched > 0 ? " \(result.unmatched) entries didn’t match any photo in the library." : "")
        } catch {
            scanner.lastError = "Couldn’t import “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    private func exportJSON(_ records: [PhotoRecord]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "photo-tags.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryScanner.exportJSON(records).write(to: url)
        } catch {
            scanner.lastError = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let folders: [ScannedFolder]
    let photos: [PhotoRecord]
    @Binding var selection: SidebarItem?
    var onRemove: (ScannedFolder) -> Void
    /// Renames (`isRename`) or merges a tag on every photo.
    var onMerge: (_ source: String, _ target: String, _ isRename: Bool) -> Void
    var onDelete: (String) -> Void

    @State private var tagToDelete: String?
    @State private var folderToRemove: ScannedFolder?

    @State private var sheet: SidebarSheet?

    private enum SidebarSheet: Identifiable {
        case merge(String)
        case renameTag(String)
        case renameQuality(QualityVerdict)

        var id: String {
            switch self {
            case .merge(let tag): "merge-\(tag)"
            case .renameTag(let tag): "rename-\(tag)"
            case .renameQuality(let verdict): "quality-\(verdict.rawValue)"
            }
        }
    }

    var body: some View {
        let shotCounts = counts(\.shotTags)
        let contentCounts = counts(\.contentTags)
        let exifCounts = counts(\.exifTags)
        let aiCounts = counts(\.aiEdits)
        let userCounts = counts(\.userTags)
        let qualityCounts = qualityCounts()

        List(selection: $selection) {
            Label("All Photos", systemImage: "photo.on.rectangle.angled")
                .badge(photos.count)
                .tag(SidebarItem.all)

            Section("Folders") {
                ForEach(folders) { folder in
                    OutlineGroup(folderTree(for: folder), children: \.children) { node in
                        row(node.name, systemImage: node.path == folder.path ? "folder.fill" : "folder", tint: Theme.folderTint)
                            .badge(node.count)
                            .tag(SidebarItem.folder(node.path))
                            .help(node.path)
                            .contextMenu {
                                Button("Show in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.path)
                                }
                                if node.path == folder.path {
                                    Divider()
                                    Button("Remove Folder…", role: .destructive) { folderToRemove = folder }
                                }
                            }
                    }
                }
            }
            tagSection("My Tags", tint: .accentColor, counts: userCounts) { _ in "tag.fill" }
            if !qualityCounts.isEmpty {
                Section("Quality") {
                    ForEach(qualityCounts, id: \.verdict) { item in
                        row(item.verdict.title, systemImage: item.verdict.symbol, tint: item.verdict.tint)
                            .badge(item.count)
                            .tag(SidebarItem.quality(item.verdict))
                            .contextMenu {
                                Button("Rename “\(item.verdict.title)”…", systemImage: "pencil") {
                                    sheet = .renameQuality(item.verdict)
                                }
                                if item.verdict.title != item.verdict.rawValue {
                                    Button("Restore Original Name", systemImage: "arrow.uturn.backward") {
                                        QualityNames.shared.rename(item.verdict, to: "")
                                    }
                                }
                            }
                    }
                }
            }
            tagSection("Made with AI", tint: Theme.aiTint, counts: aiCounts) {
                Theme.symbol(forAIEdit: $0)
            }
            tagSection("Type of Shot", tint: Theme.shotTint, counts: shotCounts) {
                Theme.symbol(forShotTag: $0)
            }
            tagSection("In the Shot", tint: Theme.contentTint, counts: contentCounts) { _ in "eye" }
            tagSection("Camera & Date", tint: Theme.exifTint, counts: exifCounts) { _ in "camera" }
        }
        .confirmationDialog(
            "Remove “\(folderToRemove?.name ?? "")” from the library?",
            isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } })
        ) {
            Button("Remove Folder", role: .destructive) {
                if let folderToRemove { onRemove(folderToRemove) }
            }
        } message: {
            Text("The app forgets this folder and all tags, ratings and edits for its photos. Your files stay where they are.")
        }
        .confirmationDialog(
            "Delete “\(tagToDelete ?? "")” from all photos?",
            isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } })
        ) {
            Button("Delete Tag", role: .destructive) {
                if let tagToDelete { onDelete(tagToDelete) }
            }
        } message: {
            Text("It’s removed in this app only and won’t be added back by future scans. You can undo that in Settings.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .merge(let tag):
                MergeTagSheet(
                    source: tag,
                    existingTags: (userCounts + shotCounts + contentCounts + exifCounts + aiCounts).map(\.tag),
                    affectedCount: photos.filter { $0.allTags.contains(tag) }.count,
                    onMerge: { target in onMerge(tag, target, false) }
                )
            case .renameTag(let tag):
                RenameSheet(
                    title: "Rename “\(tag)”",
                    currentName: tag,
                    note: "Renames the tag on every photo, in this app only — your files aren’t changed. Future scans use the new name too. If the name already exists, the tags are merged.",
                    onRename: { newName in onMerge(tag, newName, true) }
                )
            case .renameQuality(let verdict):
                RenameSheet(
                    title: "Rename “\(verdict.title)”",
                    currentName: verdict.title,
                    note: "Changes how this quality rating is labeled throughout the app. Leave it empty to restore “\(verdict.rawValue)”.",
                    onRename: { newName in QualityNames.shared.rename(verdict, to: newName) }
                )
            }
        }
    }

    /// A sidebar row whose icon keeps its category color instead of the accent color.
    private func row(_ title: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func tagSection(
        _ title: String,
        tint: Color,
        counts: [(tag: String, count: Int)],
        icon: @escaping (String) -> String
    ) -> some View {
        if !counts.isEmpty {
            Section(title) {
                ForEach(counts, id: \.tag) { item in
                    row(item.tag, systemImage: icon(item.tag), tint: tint)
                        .badge(item.count)
                        .tag(SidebarItem.tag(item.tag))
                        .contextMenu {
                            Button("Rename “\(item.tag)”…", systemImage: "pencil") {
                                sheet = .renameTag(item.tag)
                            }
                            Button("Merge “\(item.tag)” Into…", systemImage: "arrow.triangle.merge") {
                                sheet = .merge(item.tag)
                            }
                            Divider()
                            Button("Delete “\(item.tag)”…", systemImage: "trash", role: .destructive) {
                                tagToDelete = item.tag
                            }
                        }
                }
            }
        }
    }

    /// The folder and its subfolders that contain photos, with recursive photo counts.
    private func folderTree(for folder: ScannedFolder) -> FolderNode {
        let root = folder.path
        var direct: [String: Int] = [:]
        for photo in photos where photo.rootFolderPath == root {
            direct[(photo.path as NSString).deletingLastPathComponent, default: 0] += 1
        }
        var totals: [String: Int] = [:]
        var childrenOf: [String: Set<String>] = [:]
        for (directory, count) in direct {
            var current = directory
            while true {
                totals[current, default: 0] += count
                guard current != root, current.hasPrefix(root + "/") else { break }
                let parent = (current as NSString).deletingLastPathComponent
                childrenOf[parent, default: []].insert(current)
                current = parent
            }
        }
        func node(_ path: String) -> FolderNode {
            let children = (childrenOf[path] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map(node)
            return FolderNode(
                path: path,
                name: path == root ? folder.name : (path as NSString).lastPathComponent,
                count: totals[path] ?? 0,
                children: children.isEmpty ? nil : children
            )
        }
        return node(root)
    }

    /// How many photos fall under each quality verdict, best first, skipping empty ones.
    private func qualityCounts() -> [(verdict: QualityVerdict, count: Int)] {
        var counts: [QualityVerdict: Int] = [:]
        for verdict in photos.compactMap(\.quality) {
            counts[verdict, default: 0] += 1
        }
        return QualityVerdict.allCases.compactMap { verdict in
            counts[verdict].map { (verdict: verdict, count: $0) }
        }
    }

    /// Tag frequencies for one tag category, most common first.
    private func counts(_ keyPath: KeyPath<PhotoRecord, [String]>) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for photo in photos {
            for tag in photo[keyPath: keyPath] { counts[tag, default: 0] += 1 }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}

private struct ClaudePlanItem: Identifiable {
    let id = UUID()
    let plan: ClaudePlan
}

private struct SimilarSheetItem: Identifiable {
    let groups: [SimilarTags.Group]
    var id: String { "similar:" + groups.map(\.id).joined(separator: "|") }
}

private struct FolderNode: Identifiable, Hashable {
    let path: String
    let name: String
    let count: Int
    /// nil for folders without subfolders, so the outline shows no disclosure arrow.
    let children: [FolderNode]?

    var id: String { path }
}

// MARK: - Grid

private struct PhotoGridView: View {
    let photos: [PhotoRecord]
    @Binding var selection: PersistentIdentifier?
    var onTrash: (PhotoRecord) -> Void

    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(photos) { photo in
                    PhotoCell(photo: photo, isSelected: photo.persistentModelID == selection)
                        // Double-click opens the full-size viewer; the single click selects
                        // immediately rather than waiting to rule out a double-click.
                        .contextMenu {
                            Button("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                                openWindow(id: "viewer", value: ViewerItem(photo: photo))
                            }
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting(photo.allURLs)
                            }
                            Divider()
                            Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                                onTrash(photo)
                            }
                        }
                        .onTapGesture(count: 2) {
                            openWindow(id: "viewer", value: ViewerItem(photo: photo))
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            withAnimation(.snappy) { selection = photo.persistentModelID }
                        })
                }
            }
            .padding(16)
        }
    }
}

private struct PhotoCell: View {
    let photo: PhotoRecord
    let isSelected: Bool

    @State private var isHovering = false

    private var isRaised: Bool { isHovering || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ThumbnailView(url: photo.url) }
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                .overlay(alignment: .bottomLeading) {
                    // Badges only appear on the raised cell, which keeps the
                    // number of glass effects on screen small.
                    if isRaised {
                        badges
                            .padding(6)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                }
                .shadow(color: .black.opacity(isRaised ? 0.22 : 0.08), radius: isRaised ? 10 : 3, y: isRaised ? 6 : 1)
                .scaleEffect(isHovering ? 1.03 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(photo.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !photo.variantPaths.isEmpty {
                        Text(photo.formats.joined(separator: "+"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                            .layoutPriority(-1)
                            .help(photo.allURLs.map(\.lastPathComponent).joined(separator: ", "))
                    }
                }
                subtitle
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) { isHovering = hovering }
        }
    }

    /// Leads with the main shot type (with its symbol), then a couple of subjects.
    private var subtitle: Text {
        let subjects = photo.contentTags.prefix(2).joined(separator: " · ")
        guard let shot = photo.shotTags.first else { return Text(subjects) }
        let lead = Text("\(Image(systemName: Theme.symbol(forShotTag: shot))) \(shot)")
            .foregroundStyle(Theme.shotTint)
        return subjects.isEmpty ? lead : Text("\(lead) · \(subjects)")
    }

    private var badges: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                if photo.faceCount > 0 {
                    Label("\(photo.faceCount)", systemImage: "person.fill")
                        .badgeStyle()
                }
                if photo.caption != nil {
                    Label("AI caption", systemImage: "sparkles")
                        .labelStyle(.iconOnly)
                        .badgeStyle()
                }
                if !photo.aiEdits.isEmpty {
                    Label("Made or edited with AI", systemImage: "wand.and.sparkles")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.aiTint)
                        .badgeStyle()
                }
                if photo.quality == .galleryWorthy {
                    Label("Gallery-worthy", systemImage: "star.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.yellow)
                        .badgeStyle()
                }
            }
        }
    }
}

private extension View {
    func badgeStyle() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect()
    }
}

// MARK: - Progress

private struct ScanProgressBar: View {
    let scanner: LibraryScanner

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.breathe)

            VStack(alignment: .leading, spacing: 5) {
                Text(scanner.statusMessage ?? "Taking a good look…")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                ProgressView(value: scanner.progress)
                Text("\(scanner.processed) of \(scanner.total) · \(scanner.progress.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: 340)

            Button("Stop", systemImage: "stop.fill") { scanner.cancel() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(in: .rect(cornerRadius: 22))
        .padding(14)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [PhotoRecord.self, ScannedFolder.self], inMemory: true)
}
