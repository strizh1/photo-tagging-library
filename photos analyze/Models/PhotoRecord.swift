//
//  PhotoRecord.swift
//  photos analyze
//

import Foundation
import SwiftData

/// One analyzed image file and all of its generated tags.
@Model
final class PhotoRecord {
    @Attribute(.unique) var path: String
    var fileName: String
    /// Root folder the user picked (used to group and remove photos).
    var rootFolderPath: String
    var fileModifiedAt: Date?
    var analyzedAt: Date

    /// What is in the shot (Vision labels, animals, AI subjects/setting).
    var contentTags: [String]
    /// Type of shot (portrait, landscape, telephoto, night…).
    var shotTags: [String]
    /// Metadata tags (camera, lens, year, month, format…).
    var exifTags: [String]

    var caption: String?
    var recognizedText: String?
    var aestheticScore: Double?
    var faceCount: Int
    var dateTaken: Date?
    /// JSON-encoded `ExifInfo`. Stored as data to keep the SwiftData schema simple.
    var exifData: Data

    // Manual edits are stored separately from the automatic tags so they
    // survive re-analysis. `shotTags` / `contentTags` are always the result of
    // (automatic − removed) + added.
    var autoShotTags: [String] = []
    var autoContentTags: [String] = []
    var addedShotTags: [String] = []
    var removedShotTags: [String] = []
    var addedContentTags: [String] = []
    var removedContentTags: [String] = []

    /// Other files in the same folder with the same name but a different
    /// extension (e.g. the RAW next to a JPEG). Shown as one photo.
    var variantPaths: [String] = []
    /// AI generation / AI edits declared in the file's metadata (see `AIEditDetector`).
    var aiEdits: [String] = []
    /// Quality verdict picked by the user (`QualityVerdict` raw value). Overrides the
    /// automatic one and survives re-analysis.
    var manualQuality: String?
    /// The user's own tags ("My Tags"). Never touched by analysis or rescans.
    var userTags: [String] = []
    /// Tags added by Claude ("Import Claude's Changes"), shown as regular shot / content
    /// tags. Stored separately from the automatic ones so rescans don't drop them, and
    /// from the user's own so Claude may still tidy them later.
    var claudeShotTags: [String] = []
    var claudeContentTags: [String] = []
    /// Automatic tags removed by Claude / photo-tags.json. Filtered out of every rescan
    /// (unlike a plain removal), without counting as the user's own edit.
    var claudeRemovedTags: [String] = []
    /// Legacy: Claude tags from before they were sorted into shot / content.
    /// Moved by `sortLegacyClaudeTags` and then always empty.
    var claudeTags: [String] = []

    init(result: AnalysisResult, rootFolderPath: String, merges: [String: String] = [:]) {
        path = result.url.path
        fileName = result.url.lastPathComponent
        self.rootFolderPath = rootFolderPath
        fileModifiedAt = result.fileModifiedAt
        analyzedAt = .now
        contentTags = []
        shotTags = []
        exifTags = []
        faceCount = 0
        exifData = Data()
        apply(result, merges: merges)
    }

    /// Stores an analysis result. `merges` (see `TagMerges`) rewrites merged tags.
    func apply(_ result: AnalysisResult, merges: [String: String] = [:]) {
        fileModifiedAt = result.fileModifiedAt
        analyzedAt = .now
        // Categories the user edited by hand are left exactly as they are; only
        // untouched categories pick up the new automatic tags.
        if addedContentTags.isEmpty && removedContentTags.isEmpty {
            autoContentTags = TagMerges.apply(merges, to: result.contentTags)
        }
        if addedShotTags.isEmpty && removedShotTags.isEmpty {
            autoShotTags = TagMerges.apply(merges, to: result.shotTags)
        }
        recomputeTags()
        exifTags = TagMerges.apply(merges, to: result.exifTags).filter { !Self.containsTag(claudeRemovedTags, $0) }
        caption = result.caption
        recognizedText = result.recognizedText
        aestheticScore = result.aestheticScore
        faceCount = result.faceCount
        dateTaken = result.exif.dateTaken
        variantPaths = result.variants.map(\.path)
        aiEdits = TagMerges.apply(merges, to: result.aiEdits).filter { !Self.containsTag(claudeRemovedTags, $0) }
        exifData = (try? JSONEncoder().encode(result.exif)) ?? Data()
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// The analyzed file first, then its variants.
    var allURLs: [URL] { [url] + variantPaths.map { URL(fileURLWithPath: $0) } }

    /// File name without extension when the photo has variants, since it stands for several files.
    var displayName: String {
        variantPaths.isEmpty ? fileName : URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    /// Uppercased extensions of every file in the group, analyzed file first (e.g. ["JPG", "CR3"]).
    var formats: [String] {
        allURLs.map { $0.pathExtension.uppercased() }
    }

    // MARK: Tag editing

    enum EditableTagKind {
        case shot, content
    }

    var hasManualEdits: Bool {
        !(addedShotTags.isEmpty && removedShotTags.isEmpty && addedContentTags.isEmpty && removedContentTags.isEmpty)
    }

    func tags(_ kind: EditableTagKind) -> [String] {
        kind == .shot ? shotTags : contentTags
    }

    func addTag(_ rawTag: String, to kind: EditableTagKind) {
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        seedAutomaticTagsIfNeeded()
        claudeRemovedTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        switch kind {
        case .shot:
            removedShotTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if !Self.containsTag(addedShotTags, tag) { addedShotTags.append(tag) }
        case .content:
            removedContentTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if !Self.containsTag(addedContentTags, tag) { addedContentTags.append(tag) }
        }
        recomputeTags()
    }

    func removeTag(_ tag: String, from kind: EditableTagKind) {
        seedAutomaticTagsIfNeeded()
        switch kind {
        case .shot:
            addedShotTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if !Self.containsTag(removedShotTags, tag) { removedShotTags.append(tag) }
        case .content:
            addedContentTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if !Self.containsTag(removedContentTags, tag) { removedContentTags.append(tag) }
        }
        recomputeTags()
    }

    /// Replaces `source` with `target` (a rename or merge) in every tag category; an
    /// empty `target` deletes the tag. For
    /// shot and content tags both the automatic ones and manual edits change, so the
    /// merge isn't undone by "Reset". Returns whether the photo had the tag.
    @discardableResult
    func mergeTag(_ source: String, into target: String) -> Bool {
        guard Self.containsTag(allTags, source) else { return false }
        let merge = [source.lowercased(): target]
        exifTags = TagMerges.apply(merge, to: exifTags)
        aiEdits = TagMerges.apply(merge, to: aiEdits)
        userTags = TagMerges.apply(merge, to: userTags)
        claudeTags = TagMerges.apply(merge, to: claudeTags)
        claudeShotTags = TagMerges.apply(merge, to: claudeShotTags)
        claudeContentTags = TagMerges.apply(merge, to: claudeContentTags)
        claudeRemovedTags = TagMerges.apply(merge, to: claudeRemovedTags)
        guard Self.containsTag(shotTags + contentTags, source) else { return true }
        seedAutomaticTagsIfNeeded()
        autoShotTags = TagMerges.apply(merge, to: autoShotTags)
        autoContentTags = TagMerges.apply(merge, to: autoContentTags)
        addedShotTags = TagMerges.apply(merge, to: addedShotTags)
        addedContentTags = TagMerges.apply(merge, to: addedContentTags)
        // A removed source tag no longer exists, so forget it rather than hiding the target.
        // (Deleting a tag edits the automatic tags directly, so it doesn't count as a
        // manual edit that would freeze the category on rescans.)
        removedShotTags.removeAll { $0.caseInsensitiveCompare(source) == .orderedSame }
        removedContentTags.removeAll { $0.caseInsensitiveCompare(source) == .orderedSame }
        recomputeTags()
        return true
    }

    /// Discards all manual edits and goes back to the automatically generated tags.
    func resetManualEdits() {
        seedAutomaticTagsIfNeeded()
        addedShotTags = []
        removedShotTags = []
        addedContentTags = []
        removedContentTags = []
        claudeRemovedTags = []
        recomputeTags()
    }

    private func recomputeTags(merges: [String: String] = TagMerges.all) {
        let kept: (String) -> Bool = { !Self.containsTag(self.claudeRemovedTags, $0) }
        shotTags = Self.merge(auto: autoShotTags.filter(kept) + claudeShotTags, added: addedShotTags, removed: removedShotTags)
        contentTags = Self.merge(auto: autoContentTags.filter(kept) + claudeContentTags, added: addedContentTags, removed: removedContentTags)
        // Broader tags implied by the photo's tags (Surfing → Watersport → Sport), including
        // the user's own. Never one the user removed from this photo or deleted everywhere
        // (`implied` skips deletions and follows the user's merges).
        let blocked = removedShotTags + removedContentTags + claudeRemovedTags
        for tag in TagTaxonomy.implied(by: userTags + shotTags + contentTags, merges: merges)
        where !Self.containsTag(blocked, tag) && !Self.containsTag(shotTags + contentTags, tag) {
            contentTags.append(tag)
        }
    }

    /// Re-derives shot and content tags, e.g. after the tag vocabulary changed.
    func refreshDerivedTags(merges: [String: String]) {
        recomputeTags(merges: merges)
    }

    /// Records analyzed before editing existed have no stored automatic tags; treat
    /// their current tags as the automatic ones before the first edit.
    private func seedAutomaticTagsIfNeeded() {
        guard !hasManualEdits, autoShotTags.isEmpty, autoContentTags.isEmpty else { return }
        autoShotTags = shotTags
        autoContentTags = contentTags
    }

    /// (automatic − removed) + added, without case-insensitive duplicates (merges can map
    /// two automatic tags, or an automatic and a Claude tag, onto the same name).
    private static func merge(auto: [String], added: [String], removed: [String]) -> [String] {
        var result: [String] = []
        for tag in auto + added where !containsTag(result, tag) {
            if containsTag(removed, tag) && !containsTag(added, tag) { continue }
            result.append(tag)
        }
        return result
    }

    private static func containsTag(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    var exif: ExifInfo {
        (try? JSONDecoder().decode(ExifInfo.self, from: exifData)) ?? ExifInfo()
    }

    /// The verdict from Vision's aesthetics score, if there is one.
    var automaticQuality: QualityVerdict? {
        aestheticScore.map(QualityVerdict.init(score:))
    }

    /// The user's verdict if they set one, otherwise the automatic one.
    var quality: QualityVerdict? {
        manualQuality.flatMap(QualityVerdict.init(rawValue:)) ?? automaticQuality
    }

    /// Sets the user's verdict. Picking the automatic verdict (or nil) clears the override.
    func setQuality(_ verdict: QualityVerdict?) {
        manualQuality = (verdict == nil || verdict == automaticQuality) ? nil : verdict?.rawValue
    }

    var allTags: [String] { userTags + contentTags + shotTags + exifTags + aiEdits + claudeTags }

    // MARK: Protection of the user's own tags

    /// Tags the user added by hand: My Tags plus shot / content tags they added
    /// (including tags imported from JSON).
    var userAddedTags: [String] {
        var tags: [String] = []
        for tag in userTags + addedShotTags + addedContentTags where !Self.containsTag(tags, tag) {
            tags.append(tag)
        }
        return tags
    }

    func isUserAdded(_ tag: String) -> Bool {
        Self.containsTag(userAddedTags, tag)
    }

    /// Removes an automatically generated (or Claude-suggested) tag from this photo.
    /// Tags the user added are never removed. Unlike `removeTag`, this doesn't count as
    /// a manual edit, so rescans keep updating the category. Returns whether it changed.
    @discardableResult
    func removeAutomaticTag(_ tag: String) -> Bool {
        guard Self.containsTag(allTags, tag), !isUserAdded(tag) else { return false }
        seedAutomaticTagsIfNeeded()
        let matches: (String) -> Bool = { $0.caseInsensitiveCompare(tag) == .orderedSame }
        // Remembered so rescans (and tag implications) don't bring the automatic tag back.
        if Self.containsTag(autoShotTags + autoContentTags + exifTags + aiEdits + shotTags + contentTags, tag),
           !Self.containsTag(claudeRemovedTags, tag) {
            claudeRemovedTags.append(tag)
        }
        exifTags.removeAll(where: matches)
        aiEdits.removeAll(where: matches)
        claudeTags.removeAll(where: matches)
        claudeShotTags.removeAll(where: matches)
        claudeContentTags.removeAll(where: matches)
        recomputeTags()
        return true
    }

    /// Adds a Claude-suggested tag to "Type of shot" or "In the shot", unless the photo
    /// already has it in any category. Uses the user's merged name, and never adds a tag
    /// the user deleted from the library.
    @discardableResult
    func addClaudeTag(_ rawTag: String, as kind: EditableTagKind, merges: [String: String] = TagMerges.all) -> Bool {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = merges[trimmed.lowercased()] ?? trimmed
        guard !tag.isEmpty, !Self.containsTag(allTags, tag) else { return false }
        switch kind {
        case .shot: claudeShotTags.append(tag)
        case .content: claudeContentTags.append(tag)
        }
        recomputeTags()
        return true
    }

    /// Moves Claude tags saved before they were sorted into shot / content.
    func sortLegacyClaudeTags(using kind: (String) -> EditableTagKind) {
        guard !claudeTags.isEmpty else { return }
        let legacy = claudeTags
        claudeTags = []
        for tag in legacy where !Self.containsTag(shotTags + contentTags, tag) {
            switch kind(tag) {
            case .shot: claudeShotTags.append(tag)
            case .content: claudeContentTags.append(tag)
            }
        }
        recomputeTags()
    }

    // MARK: My Tags

    func addUserTag(_ rawTag: String) {
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !Self.containsTag(userTags, tag) else { return }
        userTags.append(tag)
    }

    func removeUserTag(_ tag: String) {
        userTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    // MARK: Import

    /// Makes the photo's tags match an imported set. Shot and content tags are stored
    /// as manual edits on top of the automatic ones, so later rescans keep them.
    func importTags(shot: [String]?, content: [String]?, user: [String]?) {
        seedAutomaticTagsIfNeeded()
        if let shot {
            addedShotTags = shot.filter { !Self.containsTag(autoShotTags, $0) }
            removedShotTags = autoShotTags.filter { !Self.containsTag(shot, $0) }
        }
        if let content {
            addedContentTags = content.filter { !Self.containsTag(autoContentTags, $0) }
            removedContentTags = autoContentTags.filter { !Self.containsTag(content, $0) }
        }
        if let user {
            userTags = []
            user.forEach(addUserTag)
        }
        recomputeTags()
    }

    func matches(search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let variantNames = variantPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        let haystack = ([fileName, caption ?? "", recognizedText ?? ""] + variantNames + allTags)
        return haystack.contains { $0.localizedCaseInsensitiveContains(search) }
    }
}

/// A folder the user granted access to. The security-scoped bookmark lets the
/// sandboxed app reopen it after relaunch for thumbnails and rescans.
@Model
final class ScannedFolder {
    @Attribute(.unique) var path: String
    var bookmark: Data
    var addedAt: Date
    var lastScannedAt: Date?

    init(path: String, bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
        self.addedAt = .now
    }

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
