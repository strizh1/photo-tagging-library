//
//  ClaudeHandoff.swift
//  photos analyze
//

import Foundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers

/// Lets Claude (Claude Code or the Claude app) review the library without any API:
/// the app exports a folder with `library.json`, JPEG previews and instructions, Claude
/// writes `changes.json` into it, and the app imports that after the user reviews it.
///
/// The app — not Claude — enforces the rules: merges and renames apply everywhere, but
/// deleting or removing a tag never touches photos where the user added it.
enum ClaudeHandoff {
    static let libraryFileName = "library.json"
    static let changesFileName = "changes.json"
    static let readmeFileName = "README_FOR_CLAUDE.md"
    static let previewsFolderName = "previews"
    /// Claude downsizes larger images anyway, so bigger previews only cost more usage.
    nonisolated static let previewMaxPixelSize = 1568

    // MARK: Export format

    struct LibraryFile: Codable {
        var instructions = "Read README_FOR_CLAUDE.md first. Write your changes to changes.json in this folder."
        var exportedAt: Date
        var tags: [TagInfo]
        var photos: [PhotoInfo]
    }

    struct TagInfo: Codable {
        let name: String
        /// Any of: myTags, typeOfShot, inTheShot, cameraAndDate, aiEdits.
        let categories: [String]
        let photoCount: Int
        /// On how many photos the user added this tag themselves (those are protected).
        let userAddedOnPhotos: Int
    }

    struct PhotoInfo: Codable {
        let id: String
        let preview: String?
        let fileName: String
        let folder: String
        let path: String
        let otherFiles: [String]
        /// Tags the user added by hand. Can be merged/renamed, never removed.
        let userAddedTags: [String]
        let myTags: [String]
        let typeOfShot: [String]
        let inTheShot: [String]
        let cameraAndDate: [String]
        let aiEdits: [String]
        let caption: String?
        let quality: String?
        let recognizedText: String?
    }

    // MARK: Changes format (written by Claude)

    struct Changes: Decodable {
        struct Merge: Decodable {
            let from: String
            let to: String
            let reason: String?
        }

        /// Accepts either `"Blurry"` or `{"tag": "Blurry", "reason": "…"}`.
        struct Delete: Decodable {
            let tag: String
            let reason: String?

            init(from decoder: Decoder) throws {
                if let tag = try? decoder.singleValueContainer().decode(String.self) {
                    self.tag = tag
                    reason = nil
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    tag = try container.decode(String.self, forKey: .tag)
                    reason = try container.decodeIfPresent(String.self, forKey: .reason)
                }
            }

            private enum CodingKeys: String, CodingKey { case tag, reason }
        }

        /// Accepts either `"Sunset"` or `{"tag": "Sunset", "category": "inTheShot"}`.
        struct AddedTag: Decodable {
            let tag: String
            /// "typeOfShot" or "inTheShot"; nil lets the app decide.
            let category: String?

            init(from decoder: Decoder) throws {
                if let tag = try? decoder.singleValueContainer().decode(String.self) {
                    self.tag = tag
                    category = nil
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    tag = try container.decode(String.self, forKey: .tag)
                    category = try container.decodeIfPresent(String.self, forKey: .category)
                }
            }

            private enum CodingKeys: String, CodingKey { case tag, category }
        }

        struct PhotoChange: Decodable {
            let id: String
            let add: [AddedTag]?
            let remove: [String]?
        }

        let summary: String?
        let merges: [Merge]?
        let deletes: [Delete]?
        let photos: [PhotoChange]?
    }

    // MARK: Building the export

    /// Builds `library.json` contents and the list of previews to render.
    @MainActor
    static func makeLibraryFile(for photos: [PhotoRecord]) -> (file: LibraryFile, previews: [(id: String, source: URL)]) {
        var categories: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        var userAdded: [String: Int] = [:]
        func note(_ tags: [String], _ category: String) {
            for tag in tags { categories[tag, default: []].insert(category) }
        }

        var infos: [PhotoInfo] = []
        var previews: [(id: String, source: URL)] = []
        for (index, photo) in photos.enumerated() {
            let id = String(format: "p%05d", index + 1)
            note(photo.userTags, "myTags")
            note(photo.shotTags, "typeOfShot")
            note(photo.contentTags, "inTheShot")
            note(photo.exifTags, "cameraAndDate")
            note(photo.aiEdits, "aiEdits")
            for tag in Set(photo.allTags) { counts[tag, default: 0] += 1 }
            for tag in Set(photo.userAddedTags) { userAdded[tag, default: 0] += 1 }

            let preview = "\(previewsFolderName)/\(id).jpg"
            previews.append((id, photo.url))
            infos.append(PhotoInfo(
                id: id,
                preview: preview,
                fileName: photo.fileName,
                folder: URL(fileURLWithPath: photo.path).deletingLastPathComponent().lastPathComponent,
                path: photo.path,
                otherFiles: photo.variantPaths.map { URL(fileURLWithPath: $0).lastPathComponent },
                userAddedTags: photo.userAddedTags,
                myTags: photo.userTags,
                typeOfShot: photo.shotTags,
                inTheShot: photo.contentTags,
                cameraAndDate: photo.exifTags,
                aiEdits: photo.aiEdits,
                caption: photo.caption,
                quality: photo.quality?.title,
                recognizedText: photo.recognizedText.map { String($0.prefix(300)) }
            ))
        }

        let tags = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { tag in
            TagInfo(name: tag, categories: (categories[tag] ?? []).sorted(), photoCount: counts[tag] ?? 0,
                    userAddedOnPhotos: userAdded[tag] ?? 0)
        }
        return (LibraryFile(exportedAt: .now, tags: tags, photos: infos), previews)
    }

    /// Renders one downsized JPEG preview (also converts HEIC / RAW, which Claude can't read).
    @concurrent
    nonisolated static func writePreview(of source: URL, to destination: URL) async -> Bool {
        guard let image = ImageDecoder.sdrImage(url: source, maxPixelSize: previewMaxPixelSize),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(output)
    }

    // MARK: Instructions for Claude

    static let readme = """
    # Photo library handoff for Claude

    This folder was exported by the user's Mac photo-tagging app ("photos analyze").
    Your job: help tidy and improve the tags, then write **`changes.json`** in this folder.
    The user reviews every change in the app before it's applied.

    ## What's here
    - `library.json`: every tag (with categories and counts) and every photo with its tags.
    - `previews/`: one JPEG per photo, named by photo id (`p00001.jpg` …). Look at these to judge what's actually in the photos.

    Tag categories: `myTags` (user's own), `typeOfShot` (how it was shot: Portrait, Macro,
    Long exposure, Aerial…), `inTheShot` (what's in it: Dog, Beach, Eiffel Tower…),
    `cameraAndDate`, `aiEdits` (AI editing detected in metadata).

    ## What you can do
    1. **Merge / rename tags**: duplicates, near-duplicates, inconsistent naming
       ("Jet planes" → "Planes", "puppy" → "Dog"). Renaming is a merge into a new name.
       This applies to every photo, including tags the user added.
    2. **Delete tags** that are useless or wrong across the library (e.g. vague labels).
    3. **Per photo: add tags** you can see in the preview, and **remove wrong tags**.
       Give every added tag a `category`: `typeOfShot` for how the photo was taken
       (shot type, framing, lens, light, technique) or `inTheShot` for what it shows
       (subjects, objects, places, activities, scenery).

    ## Rules (the app enforces these too)
    - **Never remove tags the user added.** Each photo lists them in `userAddedTags`, and each
      tag has `userAddedOnPhotos`. Deleting such a tag only removes it from photos where it was
      added automatically; the user's own copies are kept. Merging/renaming them is fine.
    - Use existing tag names where they fit, in the same style (Title case, short, singular
      unless plural is natural).
    - Don't add tags for camera data, dates or quality; the app handles those.
    - Be conservative: when unsure, leave it out. Prefer a few good changes over many guesses.
    - For large libraries, work through the previews in batches; you can write `changes.json`
      once at the end.

    ## changes.json format
    ```json
    {
      "summary": "One or two sentences on what you changed and why.",
      "merges": [
        { "from": "Jet planes", "to": "Planes", "reason": "same subject" }
      ],
      "deletes": [
        { "tag": "Blurry", "reason": "not a subject" }
      ],
      "photos": [
        { "id": "p00001",
          "add": [
            { "tag": "Beach", "category": "inTheShot" },
            { "tag": "Golden hour", "category": "typeOfShot" }
          ],
          "remove": ["Indoor"] }
      ]
    }
    ```
    All sections are optional. Tag names in `from`, `deletes` and `remove` must match existing
    tags (case doesn't matter). Photo ids must come from `library.json`. Names in `add` should
    use the final names after your merges.
    """
}

/// Claude's changes checked against the current library, ready for review.
struct ClaudePlan {
    struct MergeItem: Identifiable {
        let from: String
        let to: String
        let photoCount: Int
        let reason: String?
        var id: String { "merge:" + from.lowercased() }
    }

    struct DeleteItem: Identifiable {
        let tag: String
        let removableCount: Int
        /// Photos where the user added the tag; they keep it.
        let protectedCount: Int
        let reason: String?
        var id: String { "delete:" + tag.lowercased() }
    }

    struct PhotoItem {
        let photo: PhotoRecord
        let add: [(tag: String, kind: PhotoRecord.EditableTagKind)]
        let remove: [String]
    }

    var summary: String?
    var merges: [MergeItem] = []
    var deletes: [DeleteItem] = []
    var photoChanges: [PhotoItem] = []
    /// Requested per-photo removals refused because the user added the tag.
    var protectedRemovals = 0
    /// Human-readable notes about parts of the file that were ignored.
    var skipped: [String] = []

    var addCount: Int { photoChanges.reduce(0) { $0 + $1.add.count } }
    var addShotCount: Int { photoChanges.reduce(0) { $0 + $1.add.filter { $0.kind == .shot }.count } }
    var removeCount: Int { photoChanges.reduce(0) { $0 + $1.remove.count } }
    var isEmpty: Bool { merges.isEmpty && deletes.isEmpty && addCount == 0 && removeCount == 0 }

    /// Reads `changes.json` and `library.json` from a handoff folder and checks every
    /// change against the current library.
    @MainActor
    init(folder: URL, photos: [PhotoRecord]) throws {
        let changes = try JSONDecoder().decode(
            ClaudeHandoff.Changes.self,
            from: Data(contentsOf: folder.appendingPathComponent(ClaudeHandoff.changesFileName))
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(
            ClaudeHandoff.LibraryFile.self,
            from: Data(contentsOf: folder.appendingPathComponent(ClaudeHandoff.libraryFileName))
        )
        summary = changes.summary

        let photosByPath = Dictionary(photos.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let photoForID = Dictionary(library.photos.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
            .compactMapValues { photosByPath[$0] }

        /// The library's spelling of a tag, matched case-insensitively.
        var spelling: [String: String] = [:]
        for photo in photos {
            for tag in photo.allTags where spelling[tag.lowercased()] == nil { spelling[tag.lowercased()] = tag }
        }
        func existing(_ tag: String) -> String? {
            spelling[tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }

        var seen = Set<String>()
        for merge in changes.merges ?? [] {
            let target = merge.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let source = existing(merge.from) else {
                skipped.append("Merge of “\(merge.from)”: no such tag.")
                continue
            }
            guard !target.isEmpty, source.caseInsensitiveCompare(target) != .orderedSame,
                  seen.insert(source.lowercased()).inserted
            else { continue }
            let count = photos.filter { $0.allTags.contains { $0.caseInsensitiveCompare(source) == .orderedSame } }.count
            merges.append(MergeItem(from: source, to: target, photoCount: count, reason: merge.reason))
        }

        for delete in changes.deletes ?? [] {
            guard let tag = existing(delete.tag) else {
                skipped.append("Delete of “\(delete.tag)”: no such tag.")
                continue
            }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            let tagged = photos.filter { $0.allTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            let protected = tagged.filter { $0.isUserAdded(tag) }.count
            deletes.append(DeleteItem(tag: tag, removableCount: tagged.count - protected,
                                      protectedCount: protected, reason: delete.reason))
        }

        let sorter = TagSorter(library: photos)
        var unknownIDs = 0
        for change in changes.photos ?? [] {
            guard let photo = photoForID[change.id] else {
                unknownIDs += 1
                continue
            }
            // Reuse the library's spelling of known tags ("sky" → "Sky") and sort each
            // tag into "Type of shot" or "In the shot".
            let add = (change.add ?? [])
                .map { item in
                    let tag = existing(item.tag) ?? item.tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (tag: tag, kind: sorter.kind(for: tag, suggested: item.category))
                }
                .filter { item in !item.tag.isEmpty && !photo.allTags.contains { $0.caseInsensitiveCompare(item.tag) == .orderedSame } }
            var remove: [String] = []
            for tag in change.remove ?? [] {
                guard let match = photo.allTags.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                if photo.isUserAdded(match) {
                    protectedRemovals += 1
                } else {
                    remove.append(match)
                }
            }
            if !add.isEmpty || !remove.isEmpty {
                photoChanges.append(PhotoItem(photo: photo, add: add, remove: remove))
            }
        }
        if unknownIDs > 0 {
            skipped.append("\(unknownIDs) photo changes refer to photos that aren’t in the library anymore.")
        }
    }

    /// Applies the chosen parts. Merges first, so added tags can use the merged names.
    @MainActor
    func apply(
        mergeIDs: Set<String>,
        deleteIDs: Set<String>,
        addTags: Bool,
        removeTags: Bool,
        scanner: LibraryScanner,
        photos: [PhotoRecord],
        context: ModelContext
    ) {
        let chosenMerges = merges.filter { mergeIDs.contains($0.id) }
        for merge in chosenMerges {
            scanner.mergeTag(merge.from, into: merge.to, photos: photos, context: context)
        }
        for delete in deletes where deleteIDs.contains(delete.id) {
            scanner.deleteTag(delete.tag, photos: photos, context: context, keepingUserAdded: true)
        }
        let mergeMap = Dictionary(chosenMerges.map { ($0.from.lowercased(), $0.to) }, uniquingKeysWith: { _, last in last })
        for change in photoChanges {
            if addTags {
                for item in change.add {
                    let tag = mergeMap[item.tag.lowercased()] ?? item.tag
                    change.photo.addClaudeTag(tag, as: item.kind)
                }
            }
            if removeTags {
                for tag in TagMerges.apply(mergeMap, to: change.remove) { change.photo.removeAutomaticTag(tag) }
            }
        }
        try? context.save()
    }
}

/// Decides whether a tag belongs in "Type of shot" or "In the shot".
struct TagSorter {
    private let shotTags: Set<String>
    private let contentTags: Set<String>

    /// Phrases that describe how a photo was taken rather than what it shows; matched
    /// as whole words anywhere in the tag ("Golden hour portrait").
    private static let shotPhrases = [
        "portrait", "selfie", "landscape", "cityscape", "close up", "closeup", "macro", "aerial", "drone shot",
        "panorama", "panoramic", "wide angle", "ultra wide", "telephoto", "long exposure", "low light",
        "silhouette", "bokeh", "depth of field", "black and white", "monochrome", "golden hour", "blue hour",
        "candid", "motion blur", "flat lay", "top down", "low angle", "high angle", "bird s eye",
        "symmetry", "minimalist", "backlit", "hdr", "double exposure", "fisheye", "tilt shift",
        "street photography", "lens flare", "point of view", "pov",
    ]
    /// Ambiguous words that only count when they're the whole tag ("Square" yes, "Times Square" no).
    private static let shotWords: Set<String> = [
        "night", "action", "square", "vertical", "horizontal", "flash", "reflection", "snapshot", "screenshot",
    ]

    /// Uses the library's existing tags to learn where each tag already lives.
    init(library photos: [PhotoRecord]) {
        shotTags = Set(photos.flatMap(\.shotTags).map { $0.lowercased() })
            .union(ShotClassifier.allShotTypes.map { $0.lowercased() })
        contentTags = Set(photos.flatMap(\.contentTags).map { $0.lowercased() })
    }

    /// `suggested` is Claude's category ("typeOfShot" / "inTheShot"), if it gave one.
    func kind(for tag: String, suggested: String? = nil) -> PhotoRecord.EditableTagKind {
        switch suggested?.lowercased().filter(\.isLetter) {
        case "typeofshot", "shot", "shottype": return .shot
        case "intheshot", "content", "subject", "subjects": return .content
        default: break
        }
        let lowered = tag.lowercased()
        if shotTags.contains(lowered) { return .shot }
        if contentTags.contains(lowered) { return .content }
        // Compare whole words: punctuation and hyphens become spaces.
        let words = " " + lowered.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ") + " "
        if Self.shotWords.contains(words.trimmingCharacters(in: .whitespaces)) { return .shot }
        return Self.shotPhrases.contains { words.contains(" \($0) ") } ? .shot : .content
    }
}
