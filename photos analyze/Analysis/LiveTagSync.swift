//
//  LiveTagSync.swift
//  photos analyze
//

import Foundation
import SwiftData

/// Keeps a `photo-tags.json` in every added folder in sync with the library, both ways,
/// so Claude Code (or anything else) can read and edit tags while the app is open.
///
/// - App → file: rewritten about a second after any change is saved, only if it differs.
/// - File → app: polled every couple of seconds. Edits are found by comparing the file
///   with the version the app last wrote (the "base"), so only what the editor actually
///   changed is applied — never stale data from an old copy of the file.
///
/// Protections: tags the user added are never removed; My Tags, camera data and AI-edit
/// tags are read-only; photos missing from the file are left alone.
@MainActor
final class LiveTagSync {
    static let fileName = "photo-tags.json"
    static let claudeFileName = "CLAUDE.md"
    /// Settings key; on by default.
    static let enabledKey = "liveTagSync"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let context: ModelContext
    private let scanner: LibraryScanner
    private var writeTask: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    /// Modification date of each folder's file when it was last read or written.
    private var lastSeen: [String: Date] = [:]

    init(context: ModelContext, scanner: LibraryScanner) {
        self.context = context
        self.scanner = scanner
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                self?.scheduleWrite()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.readEdits()
                try? await Task.sleep(for: .seconds(2))
            }
        })
    }

    // MARK: App → file

    func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.writeAll()
        }
    }

    private func writeAll() {
        guard Self.isEnabled else { return }
        // Mid-scan the library changes constantly; write once the scan is done.
        guard !scanner.isScanning else { return scheduleWrite() }
        let folders = (try? context.fetch(FetchDescriptor<ScannedFolder>())) ?? []
        let photos = (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
        let byRoot = Dictionary(grouping: photos, by: \.rootFolderPath)
        for folder in folders {
            guard let root = scanner.reachableURL(for: folder) else { continue }
            let fileURL = root.appendingPathComponent(Self.fileName)
            // Never overwrite edits that haven't been read yet, including a file edited while
            // the app was closed (nothing seen yet): `readEdits` reads it first.
            if let date = modificationDate(fileURL), date > (lastSeen[folder.path] ?? .distantPast) { continue }
            let data = Self.encode(Self.makeFile(for: byRoot[folder.path] ?? [], rootPath: folder.path))
            if (try? Data(contentsOf: fileURL)) != data {
                do {
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    continue
                }
            }
            saveBase(data, for: folder.path)
            lastSeen[folder.path] = modificationDate(fileURL)
            writeClaudeInstructions(in: root)
        }
    }

    /// Adds CLAUDE.md (read automatically by Claude Code) unless the folder already has
    /// one the user wrote; ours is recognised by its first line and kept up to date.
    private func writeClaudeInstructions(in root: URL) {
        let url = root.appendingPathComponent(Self.claudeFileName)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            guard existing.hasPrefix(Self.claudeMarker), existing != Self.claudeInstructions else { return }
        }
        try? Self.claudeInstructions.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: File → app

    private func readEdits() {
        guard Self.isEnabled, !scanner.isScanning else { return }
        let folders = (try? context.fetch(FetchDescriptor<ScannedFolder>())) ?? []
        var changed = false
        for folder in folders {
            guard let root = scanner.reachableURL(for: folder) else { continue }
            let fileURL = root.appendingPathComponent(Self.fileName)
            guard let date = modificationDate(fileURL) else {
                changed = true // no file yet (or it was deleted): create it
                continue
            }
            guard date != lastSeen[folder.path] else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let edited = try? JSONDecoder().decode(LiveFile.self, from: data) else {
                // Mid-edit or invalid JSON: try again when it changes.
                lastSeen[folder.path] = date
                continue
            }
            lastSeen[folder.path] = date
            guard let baseData = loadBase(for: folder.path), baseData != data,
                  let base = try? JSONDecoder().decode(LiveFile.self, from: baseData)
            else {
                // No base yet (first run) or nothing changed: just (re)write our version.
                changed = true
                continue
            }
            let photos = (try? context.fetch(FetchDescriptor<PhotoRecord>())) ?? []
            Self.apply(edited: edited, base: base, rootPath: folder.path,
                       photos: photos.filter { $0.rootFolderPath == folder.path },
                       allPhotos: photos, scanner: scanner, context: context)
            changed = true
        }
        if changed {
            try? context.save()
            // Write back right away so refused edits reappear and requests are cleared.
            writeAll()
        }
    }

    /// Applies what changed between `base` (last written by the app) and `edited`.
    static func apply(
        edited: LiveFile, base: LiveFile, rootPath: String, photos: [PhotoRecord],
        allPhotos: [PhotoRecord], scanner: LibraryScanner, context: ModelContext
    ) {
        // Library-wide requests first, so per-photo tags can use the new names.
        var renamed: [String: String] = [:]
        for merge in edited.requests?.merges ?? [] {
            let to = merge.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !to.isEmpty, allPhotos.contains(where: { $0.allTags.contains { $0.caseInsensitiveCompare(merge.from) == .orderedSame } }),
                  let from = allPhotos.lazy.flatMap(\.allTags).first(where: { $0.caseInsensitiveCompare(merge.from) == .orderedSame })
            else { continue }
            scanner.mergeTag(from, into: to, photos: allPhotos, context: context)
            renamed[from.lowercased()] = to
        }
        for tag in edited.requests?.deletes ?? [] {
            guard let match = allPhotos.lazy.flatMap(\.allTags).first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
            else { continue }
            scanner.deleteTag(match, photos: allPhotos, context: context, keepingUserAdded: true)
        }

        let baseByPath = Dictionary(base.photos.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let photoByPath = Dictionary(photos.map { (relativePath($0.path, root: rootPath), $0) },
                                     uniquingKeysWith: { first, _ in first })
        for entry in edited.photos {
            guard let old = baseByPath[entry.path], let photo = photoByPath[entry.path] else { continue }
            let rename: (String) -> String = { renamed[$0.lowercased()] ?? $0 }
            let changes: [(PhotoRecord.EditableTagKind, [String]?, [String]?)] = [
                (.shot, old.typeOfShot, entry.typeOfShot),
                (.content, old.inTheShot, entry.inTheShot),
            ]
            // Removals first so a tag can move between "Type of shot" and "In the shot".
            for (_, before, after) in changes {
                guard let before, let after else { continue }
                for tag in difference(before, after) { photo.removeAutomaticTag(rename(tag)) }
            }
            for (kind, before, after) in changes {
                guard let before, let after else { continue }
                for tag in difference(after, before) { photo.addClaudeTag(rename(tag), as: kind) }
            }
            // Quality: only when the user hasn't rated the photo themselves.
            if let quality = entry.quality, quality != old.quality, photo.manualQuality == nil,
               let verdict = QualityVerdict.allCases.first(where: {
                   $0.title.caseInsensitiveCompare(quality) == .orderedSame
                       || $0.rawValue.caseInsensitiveCompare(quality) == .orderedSame
               }) {
                photo.setQuality(verdict)
            }
        }
    }

    /// Tags in `a` that aren't in `b`, case-insensitively.
    private static func difference(_ a: [String], _ b: [String]) -> [String] {
        a.filter { tag in !b.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    private static func relativePath(_ path: String, root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    // MARK: File format

    struct LiveFile: Codable {
        struct Merge: Codable {
            var from: String
            var to: String
        }

        struct Requests: Codable {
            var merges: [Merge]?
            var deletes: [String]?
        }

        struct Entry: Codable {
            var path: String
            var otherFiles: [String]?
            /// Tags the user added by hand (protected).
            var userAdded: [String]?
            var myTags: [String]?
            var typeOfShot: [String]?
            var inTheShot: [String]?
            var cameraAndDate: [String]?
            var aiEdits: [String]?
            var quality: String?
            var caption: String?
        }

        var about: String?
        var requests: Requests?
        var photos: [Entry]
    }

    static func makeFile(for photos: [PhotoRecord], rootPath: String) -> LiveFile {
        let entries = photos
            .map { photo in
                LiveFile.Entry(
                    path: relativePath(photo.path, root: rootPath),
                    otherFiles: photo.variantPaths.isEmpty ? nil : photo.variantPaths.map { URL(fileURLWithPath: $0).lastPathComponent },
                    userAdded: photo.userAddedTags,
                    myTags: photo.userTags,
                    typeOfShot: photo.shotTags,
                    inTheShot: photo.contentTags,
                    cameraAndDate: photo.exifTags,
                    aiEdits: photo.aiEdits.isEmpty ? nil : photo.aiEdits,
                    quality: photo.quality?.title,
                    caption: photo.caption
                )
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return LiveFile(
            about: "Live tag data from the “photos analyze” app. Read CLAUDE.md in this folder before editing.",
            requests: LiveFile.Requests(merges: [], deletes: []),
            photos: entries
        )
    }

    static func encode(_ file: LiveFile) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(file)) ?? Data()
    }

    // MARK: Base copies (in the app's own container)

    private func baseURL(for rootPath: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("LiveTagSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = rootPath.replacingOccurrences(of: "/", with: "%") + ".json"
        return folder.appendingPathComponent(name)
    }

    private func saveBase(_ data: Data, for rootPath: String) {
        guard let url = baseURL(for: rootPath) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadBase(for rootPath: String) -> Data? {
        baseURL(for: rootPath).flatMap { try? Data(contentsOf: $0) }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Instructions

    private static let claudeMarker = "<!-- written by the photos analyze app -->"

    static let claudeInstructions = """
    \(claudeMarker)
    # Photo tags in this folder

    `photo-tags.json` holds the tags of every photo in this folder (and subfolders), kept
    in sync **live** by the user's Mac app "photos analyze" while it's open. Edit that file
    to change tags; the app applies your edits within a few seconds and then rewrites the
    file, so re-read it before each new edit.

    You can look at the photos themselves (paths are relative to this folder). HEIC and
    RAW files may need converting first, e.g. `sips -s format jpeg -Z 1568 IMG.HEIC --out /tmp/IMG.jpg`.

    ## What you can change
    - **`typeOfShot`** (how it was shot: Portrait, Macro, Long exposure, Golden hour…) and
      **`inTheShot`** (what it shows: Dog, Beach, Eiffel Tower…): add, remove, or move tags
      between the two. Reuse existing tag names and their spelling where they fit.
    - **`quality`**: one of "Gallery-worthy", "Looking good", "Solid snapshot", "Happy accident"
      (or the user's renamed versions). Ignored if the user rated the photo themselves.
    - **`requests`**, for library-wide changes; the app clears them once applied:
      - `"merges": [{"from": "Jet planes", "to": "Planes"}]` merges or renames a tag everywhere
        (also renames tags the user added; that's allowed).
      - `"deletes": ["Blurry"]` deletes a tag everywhere, except where the user added it.

    ## Rules (the app enforces them)
    - **Never remove tags listed in a photo's `userAdded`.** The app refuses such removals and
      puts the tag back.
    - `myTags`, `cameraAndDate`, `aiEdits`, `caption`, `path` and `otherFiles` are read-only.
    - Don't remove photo entries; removing an entry does nothing.
    - Keep the file valid JSON. Be conservative: fewer, accurate tags beat many guesses.
    """
}
