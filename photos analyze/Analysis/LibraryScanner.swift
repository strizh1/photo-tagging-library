//
//  LibraryScanner.swift
//  photos analyze
//

import Foundation
import SwiftData
import Observation

/// Drives folder scanning: finds images, analyzes them with bounded concurrency
/// and stores the results in SwiftData. Lives on the main actor; heavy work runs
/// in `PhotoPipeline`'s `@concurrent` functions.
@Observable
final class LibraryScanner {
    var isScanning = false
    var processed = 0
    var total = 0
    var statusMessage: String?
    var lastError: String?
    /// Photos whose files are gone, waiting for the user to confirm removal because
    /// there were too many to remove automatically.
    var pendingMissing: [PhotoRecord] = []
    var useAI = SceneDescriber.isAvailable

    private var scanTask: Task<Void, Never>?
    private var accessedFolders: [String: URL] = [:]

    var progress: Double { total == 0 ? 0 : Double(processed) / Double(total) }

    // MARK: Folder access

    /// Re-opens security-scoped access to previously added folders after relaunch.
    func restoreAccess(to folders: [ScannedFolder]) {
        for folder in folders where accessedFolders[folder.path] == nil {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
                  url.startAccessingSecurityScopedResource()
            else { continue }
            if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                folder.bookmark = fresh
            }
            accessedFolders[folder.path] = url
        }
    }

    /// Adds a folder chosen in the file importer and starts analyzing it.
    func addFolder(_ url: URL, context: ModelContext) {
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "Couldn't get access to “\(url.lastPathComponent)”."
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            let path = url.path
            let existing = try context.fetch(FetchDescriptor<ScannedFolder>(predicate: #Predicate { $0.path == path })).first
            let folder = existing ?? ScannedFolder(path: path, bookmark: bookmark)
            folder.bookmark = bookmark
            if existing == nil { context.insert(folder) }
            accessedFolders[path] = url
            try context.save()
            scan([folder], context: context)
        } catch {
            lastError = "Couldn't add folder: \(error.localizedDescription)"
        }
    }

    /// The folder's URL if it's currently accessible, otherwise nil.
    func reachableURL(for folder: ScannedFolder) -> URL? {
        guard let url = accessedFolders[folder.path] else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        else { return nil }
        return url
    }

    // MARK: Missing files

    /// Checks every photo in reachable folders for files that were deleted or moved
    /// outside the app, and removes their library entries (tags, ratings…).
    /// Photos in unreachable folders are never touched.
    func removeMissingPhotos(folders: [ScannedFolder], photos: [PhotoRecord], context: ModelContext) {
        guard !isScanning else { return }
        let reachableRoots = Set(folders.filter { reachableURL(for: $0) != nil }.map(\.path))
        let byRoot = Dictionary(grouping: photos.filter { reachableRoots.contains($0.rootFolderPath) }, by: \.rootFolderPath)
        for records in byRoot.values {
            var missing: [PhotoRecord] = []
            for record in records {
                let fileManager = FileManager.default
                // Forget variants that are gone (e.g. a deleted RAW next to a kept JPEG).
                let keptVariants = record.variantPaths.filter { fileManager.fileExists(atPath: $0) }
                if keptVariants != record.variantPaths { record.variantPaths = keptVariants }
                // If only the analyzed file is gone but a variant remains, keep the
                // photo; the next rescan analyzes the remaining file instead.
                if !fileManager.fileExists(atPath: record.path) && keptVariants.isEmpty {
                    missing.append(record)
                }
            }
            removeMissing(missing, outOf: records.count, context: context)
        }
        try? context.save()
    }

    /// Removes library entries for photos whose files are confirmed gone. Small numbers
    /// are removed right away; larger ones wait for the user's confirmation.
    private func removeMissing(_ candidates: [PhotoRecord], outOf total: Int, context: ModelContext) {
        // Re-check each file directly so a hiccup during enumeration can't remove anything.
        let missing = candidates.filter { record in
            !record.allURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard !missing.isEmpty else { return }
        let safeLimit = max(20, total / 10)
        if missing.count <= safeLimit {
            for record in missing { context.delete(record) }
        } else {
            let known = Set(pendingMissing.map(\.persistentModelID))
            pendingMissing += missing.filter { !known.contains($0.persistentModelID) }
        }
    }

    /// Called when the user confirms removing `pendingMissing`.
    func confirmRemovingMissing(context: ModelContext) {
        // Files could have come back (drive reconnected) since the prompt appeared.
        for record in pendingMissing where !record.allURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            context.delete(record)
        }
        pendingMissing = []
        try? context.save()
    }

    // MARK: Moving to Trash

    /// Moves every file of `photo` to the Trash (never deletes permanently) and removes
    /// it from the library. If a file can't be trashed, the photo stays in the library.
    func moveToTrash(_ photo: PhotoRecord, context: ModelContext) {
        var failures: [String] = []
        for url in photo.allURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            context.delete(photo)
        } else {
            let remaining = photo.allURLs.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
            if let first = remaining.first, first != photo.path {
                // The analyzed file went to the Trash; point the photo at what's left.
                photo.path = first
                photo.fileName = URL(fileURLWithPath: first).lastPathComponent
                photo.fileModifiedAt = nil // re-analyzed on the next rescan
            }
            photo.variantPaths = Array(remaining.dropFirst())
            lastError = "Couldn’t move everything to the Trash:\n" + failures.joined(separator: "\n")
        }
        try? context.save()
    }

    func removeFolder(_ folder: ScannedFolder, context: ModelContext) {
        let path = folder.path
        try? context.delete(model: PhotoRecord.self, where: #Predicate { $0.rootFolderPath == path })
        context.delete(folder)
        try? context.save()
        accessedFolders.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
    }

    // MARK: Scanning

    /// Analyzes new or modified images in `folders`. With `force`, re-analyzes everything.
    func scan(_ folders: [ScannedFolder], context: ModelContext, force: Bool = false) {
        guard !isScanning else { return }
        let useAI = self.useAI && SceneDescriber.isAvailable
        isScanning = true
        processed = 0
        total = 0
        lastError = nil

        // Batch analysis runs at utility QoS: ImageIO's decoders wait on internal
        // default-QoS queues, so running at user-initiated causes priority inversions.
        scanTask = Task(priority: .utility) {
            defer {
                try? context.save()
                isScanning = false
                statusMessage = nil
            }
            for folder in folders {
                guard !Task.isCancelled else { return }
                await scanFolder(folder, context: context, force: force, useAI: useAI)
            }
            let photos = (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
            if UserDefaults.standard.object(forKey: Self.autoMergeKey) as? Bool ?? true {
                mergeSimilarTags(SimilarTags.groups(in: Self.tagCounts(photos)), photos: photos, context: context)
            }
            refreshDerivedTags(photos: photos, context: context)
        }
    }

    func cancel() {
        scanTask?.cancel()
    }

    private func scanFolder(_ folder: ScannedFolder, context: ModelContext, force: Bool, useAI: Bool) async {
        // An unreachable folder (unplugged drive, lost permission) would look empty and
        // make every photo in it seem deleted, so skip it without touching anything.
        guard let rootURL = reachableURL(for: folder) else {
            lastError = "“\(folder.name)” isn’t available right now (is the drive connected?). It was skipped and nothing in it was changed."
            return
        }
        statusMessage = "Looking for images in \(folder.name)…"
        let files = await PhotoPipeline.findImages(in: rootURL)

        let rootPath = folder.path
        let existing = (try? context.fetch(FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.rootFolderPath == rootPath }))) ?? []
        var recordsByPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        // If a group's analyzed file changed (e.g. a JPEG now sits next to a RAW that
        // was analyzed before), move the existing record over so manual tag edits survive.
        for file in files where recordsByPath[file.url.path] == nil {
            guard let record = file.variants.lazy.compactMap({ recordsByPath[$0.path] }).first else { continue }
            recordsByPath.removeValue(forKey: record.path)
            record.path = file.url.path
            record.fileName = file.url.lastPathComponent
            record.fileModifiedAt = nil // forces re-analysis of the new file
            recordsByPath[record.path] = record
        }
        // Keep the variant list current even for photos that don't need re-analysis.
        for file in files {
            let variantPaths = file.variants.map(\.path)
            if let record = recordsByPath[file.url.path], record.variantPaths != variantPaths {
                record.variantPaths = variantPaths
            }
        }

        // Records whose file wasn't found: either it became a variant of another photo
        // (safe to drop, the file still exists) or it may have been deleted.
        let presentPaths = Set(files.map(\.url.path))
        let variantPaths = Set(files.flatMap { $0.variants.map(\.path) })
        var possiblyMissing: [PhotoRecord] = []
        for record in existing where !presentPaths.contains(record.path) {
            recordsByPath.removeValue(forKey: record.path)
            if variantPaths.contains(record.path) {
                context.delete(record)
            } else {
                possiblyMissing.append(record)
            }
        }
        removeMissing(possiblyMissing, outOf: existing.count, context: context)

        // Skip files that were already analyzed and haven't changed since.
        let pending = files.filter { file in
            guard !force, let record = recordsByPath[file.url.path] else { return true }
            return record.fileModifiedAt != file.modifiedAt
        }
        total += pending.count
        statusMessage = pending.isEmpty ? nil : "Analyzing \(folder.name)…"

        let merges = TagMerges.all
        let allPhotos = (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? existing
        let tagging = Self.taggingContext(photos: allPhotos, merges: merges)

        // The language model is the bottleneck when enabled, so use less parallelism.
        let maxConcurrent = useAI ? 2 : max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        await withTaskGroup(of: AnalysisResult.self) { group in
            var queue = pending.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let file = queue.next() else { break }
                group.addTask { await PhotoPipeline.analyze(file, useAI: useAI, context: tagging) }
            }
            while let result = await group.next() {
                if let record = recordsByPath[result.url.path] {
                    record.apply(result, merges: merges)
                } else {
                    let record = PhotoRecord(result: result, rootFolderPath: rootPath, merges: merges)
                    context.insert(record)
                    recordsByPath[record.path] = record
                }
                processed += 1
                if processed % 25 == 0 { try? context.save() }

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let file = queue.next() {
                    group.addTask { await PhotoPipeline.analyze(file, useAI: useAI, context: tagging) }
                }
            }
        }
        if !Task.isCancelled {
            folder.lastScannedAt = .now
        }
    }

    // MARK: Learning from the user

    /// What analysis should know about the user's tagging: their merges, the tags they
    /// keep removing, and the library's vocabulary.
    static func taggingContext(photos: [PhotoRecord], merges: [String: String]) -> TaggingContext {
        var removed: [String: Int] = [:]
        var kept: [String: Int] = [:]
        for photo in photos {
            for tag in Set((photo.removedShotTags + photo.removedContentTags + photo.claudeRemovedTags).map { $0.lowercased() }) {
                removed[tag, default: 0] += 1
            }
            for tag in Set((photo.shotTags + photo.contentTags).map { $0.lowercased() }) {
                kept[tag, default: 0] += 1
            }
        }
        // A tag removed from at least 3 photos, and from 3 times as many photos as it
        // was kept on, is one the user doesn't want generated. It can still be added by hand.
        let suppressed = Set(removed.filter { tag, count in
            count >= 3 && count >= 3 * (kept[tag] ?? 0)
        }.keys)

        var counts: [String: Int] = [:]
        for photo in photos {
            for tag in Set(photo.userTags + photo.contentTags) { counts[tag, default: 0] += 1 }
        }
        let vocabulary = counts.filter { !suppressed.contains($0.key.lowercased()) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        return TaggingContext(merges: merges, suppressed: suppressed, vocabulary: vocabulary)
    }

    /// Re-derives every photo's tags so implied tags (Surfing → Watersport) are current.
    func refreshDerivedTags(photos: [PhotoRecord], context: ModelContext) {
        let merges = TagMerges.all
        for photo in photos { photo.refreshDerivedTags(merges: merges) }
        try? context.save()
    }

    // MARK: Tag merging

    /// Merges `source` into `target` on every photo and remembers it for future scans.
    /// Returns the number of photos changed.
    @discardableResult
    func mergeTag(_ source: String, into target: String, photos: [PhotoRecord], context: ModelContext) -> Int {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, source.caseInsensitiveCompare(target) != .orderedSame else { return 0 }
        TagMerges.add(from: source, to: target)
        let changed = photos.filter { $0.mergeTag(source, into: target) }.count
        try? context.save()
        return changed
    }

    /// Removes `tag` from every photo and keeps future scans from adding it back.
    /// With `keepingUserAdded`, photos where the user added the tag keep it (used for
    /// changes suggested by Claude). Returns the number of photos changed.
    @discardableResult
    func deleteTag(_ tag: String, photos: [PhotoRecord], context: ModelContext, keepingUserAdded: Bool = false) -> Int {
        TagMerges.add(from: tag, to: "")
        let changed = photos
            .filter { !(keepingUserAdded && $0.isUserAdded(tag)) }
            .filter { $0.mergeTag(tag, into: "") }
            .count
        try? context.save()
        return changed
    }

    /// Settings key: merge very similar tags automatically after every scan (default on).
    static let autoMergeKey = "autoMergeSimilarTags"

    /// Applies `SimilarTags` groups as merges. Returns the number of tags merged away.
    @discardableResult
    func mergeSimilarTags(_ groups: [SimilarTags.Group], photos: [PhotoRecord], context: ModelContext) -> Int {
        var merged = 0
        for group in groups {
            for source in group.sources {
                mergeTag(source, into: group.target, photos: photos, context: context)
                merged += 1
            }
        }
        return merged
    }

    /// Number of photos per tag, across every tag category.
    static func tagCounts(_ photos: [PhotoRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for photo in photos {
            for tag in Set(photo.allTags) { counts[tag, default: 0] += 1 }
        }
        return counts
    }

    // MARK: Claude handoff

    /// Writes `library.json`, JPEG previews and instructions for Claude into a new
    /// subfolder of `parent`. Shows progress like a scan and can be stopped.
    func exportForClaude(_ photos: [PhotoRecord], into parent: URL, completion: @escaping (URL) -> Void) {
        guard !isScanning else { return }
        let (library, previews) = ClaudeHandoff.makeLibraryFile(for: photos)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let folder = parent.appendingPathComponent("Photos for Claude \(stamp)")
        let previewsFolder = folder.appendingPathComponent(ClaudeHandoff.previewsFolderName)
        do {
            try FileManager.default.createDirectory(at: previewsFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(library).write(to: folder.appendingPathComponent(ClaudeHandoff.libraryFileName))
            try ClaudeHandoff.readme.write(to: folder.appendingPathComponent(ClaudeHandoff.readmeFileName),
                                           atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn’t create the export folder: \(error.localizedDescription)"
            return
        }

        isScanning = true
        processed = 0
        total = previews.count
        statusMessage = "Making previews for Claude…"
        scanTask = Task(priority: .utility) {
            defer {
                isScanning = false
                statusMessage = nil
            }
            var failed = 0
            await withTaskGroup(of: Bool.self) { group in
                var queue = previews.makeIterator()
                for _ in 0..<4 {
                    guard let item = queue.next() else { break }
                    group.addTask { await ClaudeHandoff.writePreview(of: item.source, to: previewsFolder.appendingPathComponent("\(item.id).jpg")) }
                }
                while let ok = await group.next() {
                    processed += 1
                    if !ok { failed += 1 }
                    if Task.isCancelled { group.cancelAll(); continue }
                    if let item = queue.next() {
                        group.addTask { await ClaudeHandoff.writePreview(of: item.source, to: previewsFolder.appendingPathComponent("\(item.id).jpg")) }
                    }
                }
            }
            if failed > 0 {
                lastError = "\(failed) previews couldn’t be created; Claude will see those photos’ tags only."
            }
            if !Task.isCancelled { completion(folder) }
        }
    }

    // MARK: Export

    /// Writes content and shot-type tags to each file as Finder tags.
    func writeFinderTags(for records: [PhotoRecord]) -> Int {
        var written = 0
        for record in records {
            let tags = Array(Set(record.userTags + record.shotTags + record.contentTags)).sorted()
            do {
                // Tag every file of the photo (e.g. both the RAW and the JPEG).
                for url in record.allURLs {
                    try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
                }
                written += 1
            } catch {
                lastError = "Couldn't write tags to \(record.fileName): \(error.localizedDescription)"
            }
        }
        return written
    }

    /// One photo in an exported / imported JSON file. Everything except `path` is
    /// optional so older exports (and hand-written files) can be imported.
    struct JSONEntry: Codable {
        var path: String
        var variants: [String]?
        var aiEdits: [String]?
        var caption: String?
        var userTags: [String]?
        var claudeTags: [String]?
        var contentTags: [String]?
        var shotTags: [String]?
        var exifTags: [String]?
        var aestheticScore: Double?
        var quality: String?
        var recognizedText: String?
        var exif: ExifInfo?
    }

    static func exportJSON(_ records: [PhotoRecord]) throws -> Data {
        let entries = records.map {
            JSONEntry(path: $0.path, variants: $0.variantPaths, aiEdits: $0.aiEdits, caption: $0.caption,
                      userTags: $0.userTags, claudeTags: $0.claudeShotTags + $0.claudeContentTags, contentTags: $0.contentTags, shotTags: $0.shotTags,
                      exifTags: $0.exifTags, aestheticScore: $0.aestheticScore, quality: $0.quality?.rawValue,
                      recognizedText: $0.recognizedText, exif: $0.exif)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    /// Applies tags (My Tags, shot and content tags, quality) from an exported JSON file
    /// to matching photos. Photos are matched by full path, then by file name if that's
    /// unique, so files exported on another Mac or moved folders still match.
    /// Returns (photos updated, entries that matched no photo).
    func importJSON(_ data: Data, photos: [PhotoRecord], context: ModelContext) throws -> (updated: Int, unmatched: Int) {
        let entries = try JSONDecoder().decode([JSONEntry].self, from: data)
        let byPath = Dictionary(photos.flatMap { photo in photo.allURLs.map { ($0.path, photo) } },
                                uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(grouping: photos.flatMap { photo in
            photo.allURLs.map { ($0.lastPathComponent.lowercased(), photo) }
        }, by: \.0).compactMapValues { $0.count == 1 ? $0[0].1 : nil }

        var updated = 0
        var unmatched = 0
        for entry in entries {
            let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
            guard let photo = byPath[entry.path] ?? byName[name] else {
                unmatched += 1
                continue
            }
            photo.importTags(shot: entry.shotTags, content: entry.contentTags, user: entry.userTags)
            if let quality = entry.quality,
               let verdict = QualityVerdict.allCases.first(where: {
                   $0.rawValue.caseInsensitiveCompare(quality) == .orderedSame
                       || $0.title.caseInsensitiveCompare(quality) == .orderedSame
               }) {
                photo.setQuality(verdict)
            }
            updated += 1
        }
        try context.save()
        return (updated, unmatched)
    }
}
