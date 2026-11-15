//
//  LibraryTests.swift
//  photos analyzeTests
//

import Foundation
import SwiftData
import Testing
@testable import photos_analyze

// These tests never write the app's real settings: nothing here calls `TagMerges.add`,
// `LibraryScanner.mergeTag` / `deleteTag` or `QualityNames.rename`, and SwiftData runs in memory.

// MARK: - Helpers

private func makeResult(
    content: [String] = [], shot: [String] = [], exifTags: [String] = [], path: String? = nil
) -> AnalysisResult {
    AnalysisResult(
        url: URL(fileURLWithPath: path ?? "/tmp/photos-analyze-tests/\(UUID().uuidString).jpg"),
        fileModifiedAt: nil, exif: ExifInfo(), contentTags: content, shotTags: shot, exifTags: exifTags,
        caption: nil, recognizedText: nil, aestheticScore: nil, faceCount: 0, variants: [], aiEdits: []
    )
}

private func makePhoto(content: [String] = [], shot: [String] = [], path: String? = nil) -> PhotoRecord {
    let photo = PhotoRecord(result: makeResult(content: content, shot: shot, path: path), rootFolderPath: "/tmp/photos-analyze-tests")
    photo.refreshDerivedTags(merges: [:])
    return photo
}

private func lowercased(_ tags: [String]) -> [String] { tags.map { $0.lowercased() } }

// MARK: - TagMerges and SimilarTags

struct TagMergesTests {

    @Test func appliesMergesAndDeletions() {
        let merges = ["cars": "Car", "blurry": ""]
        #expect(TagMerges.apply(merges, to: ["Cars", "Blurry", "Sky"]) == ["Car", "Sky"])
    }

    @Test func removesDuplicatesCreatedByMerges() {
        #expect(TagMerges.apply(["cars": "Car"], to: ["Car", "cars"]) == ["Car"])
    }

    @Test func similarTagsGroupPluralsCaseAndHyphens() {
        let groups = SimilarTags.groups(in: ["Jet plane": 5, "jet planes": 2, "Jet-planes": 1, "Sky": 9])
        #expect(groups.count == 1)
        #expect(groups.first?.target == "Jet plane")
        #expect(Set(groups.first?.sources ?? []) == ["jet planes", "Jet-planes"])
    }

    @Test(arguments: [("berries", "berry"), ("boxes", "box"), ("glasses", "glasses"), ("bus", "bus"), ("planes", "plane")])
    func singularization(word: String, expected: String) {
        #expect(SimilarTags.normalized(word) == expected)
    }
}

// MARK: - PhotoRecord editing rules

struct PhotoRecordTests {

    @Test func manualAddAndRemove() {
        let photo = makePhoto(content: ["Beach", "Sky"])
        photo.addTag("Sunset / sunrise", to: .content)
        photo.removeTag("Sky", from: .content)
        photo.refreshDerivedTags(merges: [:])
        #expect(photo.contentTags.contains("Sunset / sunrise"))
        #expect(!photo.contentTags.contains("Sky"))
        #expect(photo.isUserAdded("Sunset / sunrise"))
    }

    @Test func removedTagStaysRemovedAfterReanalysis() {
        let photo = makePhoto(content: ["Beach", "Fork"])
        photo.removeTag("Fork", from: .content)
        photo.apply(makeResult(content: ["Beach", "Fork", "Sky"], path: photo.path), merges: [:])
        photo.refreshDerivedTags(merges: [:])
        #expect(!photo.contentTags.contains("Fork"))
    }

    @Test func reanalysisAppliesMergesAndDeletions() {
        let photo = makePhoto(content: ["Beach"])
        let merges = ["cars": "Car", "fork": ""]
        photo.apply(makeResult(content: ["Cars", "Fork"], path: photo.path), merges: merges)
        photo.refreshDerivedTags(merges: merges)
        #expect(photo.contentTags.contains("Car"))
        #expect(!lowercased(photo.contentTags).contains("fork"))
    }

    @Test func mergeTagRenamesEverywhereIncludingUserTags() {
        let photo = makePhoto(content: ["Cars"])
        photo.addUserTag("Cars")
        photo.addTag("Cars", to: .shot)
        #expect(photo.mergeTag("Cars", into: "Car"))
        #expect(photo.userTags == ["Car"])
        #expect(photo.contentTags.contains("Car") && !photo.contentTags.contains("Cars"))
        #expect(photo.shotTags.contains("Car"))
    }

    @Test func automaticRemovalNeverTouchesUserAddedTags() {
        let photo = makePhoto(content: ["Beach"])
        photo.addTag("Dog", to: .content)
        #expect(!photo.removeAutomaticTag("Dog"))
        #expect(photo.contentTags.contains("Dog"))
        #expect(photo.removeAutomaticTag("Beach"))
        #expect(!photo.contentTags.contains("Beach"))
        // A rescan doesn't bring the removed automatic tag back.
        photo.apply(makeResult(content: ["Beach"], path: photo.path), merges: [:])
        photo.refreshDerivedTags(merges: [:])
        #expect(!photo.contentTags.contains("Beach"))
    }

    @Test func claudeCantAddDeletedTagsAndUsesMergedNames() {
        let photo = makePhoto(content: ["Beach"])
        let merges = ["fork": "", "cars": "Car"]
        #expect(!photo.addClaudeTag("Fork", as: .content, merges: merges))
        #expect(photo.addClaudeTag("Cars", as: .content, merges: merges))
        #expect(photo.contentTags.contains("Car"))
        #expect(!photo.contentTags.contains("Fork"))
    }

    @Test func noDuplicateTagsWhenSourcesOverlap() {
        let photo = makePhoto(content: ["Animals", "Dog"])
        photo.addClaudeTag("Animals", as: .content, merges: [:]) // already present: refused
        _ = photo.mergeTag("Dog", into: "Animals")
        photo.refreshDerivedTags(merges: [:])
        #expect(photo.contentTags.filter { $0 == "Animals" }.count == 1)
    }

    @Test func userAddedTagsHaveNoDuplicates() {
        let photo = makePhoto()
        photo.addTag("Animals", to: .shot)
        photo.addTag("Animals", to: .content)
        #expect(photo.userAddedTags == ["Animals"])
    }

    @Test func resetDiscardsManualEdits() {
        let photo = makePhoto(content: ["Beach", "Sky"])
        photo.removeTag("Sky", from: .content)
        photo.addTag("Dog", to: .content)
        photo.resetManualEdits()
        photo.refreshDerivedTags(merges: [:])
        #expect(photo.contentTags == ["Beach", "Sky"])
        #expect(!photo.hasManualEdits)
    }

    @Test func impliedTagRemovedByClaudeStaysRemoved() {
        let photo = makePhoto(content: ["Surfing"])
        #expect(photo.contentTags.contains("Watersport"))
        #expect(photo.removeAutomaticTag("Watersport"))
        photo.refreshDerivedTags(merges: [:])
        #expect(!photo.contentTags.contains("Watersport"))
    }

    @Test func importTagsMakesTagsMatch() {
        let photo = makePhoto(content: ["Beach", "Sky"], shot: ["Landscape"])
        photo.importTags(shot: ["Landscape", "Wide angle"], content: ["Beach"], user: ["Trip"])
        photo.refreshDerivedTags(merges: [:])
        #expect(photo.shotTags == ["Landscape", "Wide angle"])
        #expect(photo.contentTags == ["Beach"])
        #expect(photo.userTags == ["Trip"])
    }
}

// MARK: - Shot classification rules

struct ShotClassifierTests {

    private func vision(_ labels: [String: Float], humans: Int = 0, humanArea: Double = 0, text: [String] = [], textArea: Double = 0) -> VisionFindings {
        var findings = VisionFindings()
        findings.allLabels = labels
        findings.labels = labels.map { (name: $0.key, confidence: $0.value) }.sorted { $0.confidence > $1.confidence }
        findings.humanCount = humans
        findings.largestHumanArea = humanArea
        findings.recognizedText = text
        findings.textArea = textArea
        return findings
    }

    private func exif(exposure: Double? = nil) -> ExifInfo {
        var info = ExifInfo()
        info.exposureTime = exposure
        info.cameraMake = "Canon"
        return info
    }

    @Test func fastShutterNeedsAMovingSubject() {
        let staticScene = vision(["outdoor": 0.9, "sky": 0.9, "hill": 0.8, "land": 0.8])
        #expect(!ShotClassifier.shotTags(exif: exif(exposure: 1.0 / 2000), vision: staticScene).contains("Fast shutter / action"))
        let horse = vision(["outdoor": 0.9, "animal": 0.7, "horse": 0.7])
        #expect(ShotClassifier.shotTags(exif: exif(exposure: 1.0 / 2000), vision: horse).contains("Fast shutter / action"))
    }

    @Test func skyAloneIsNotALandscape() {
        let plane = vision(["outdoor": 0.9, "sky": 0.9, "cloudy": 0.8, "airplane": 0.4])
        #expect(!ShotClassifier.shotTags(exif: exif(), vision: plane).contains("Landscape"))
        let hills = vision(["outdoor": 0.9, "sky": 0.9, "land": 0.8, "hill": 0.8])
        #expect(ShotClassifier.shotTags(exif: exif(), vision: hills).contains("Landscape"))
    }

    @Test func personAsSubjectIsNotALandscape() {
        let person = vision(["outdoor": 0.9, "sky": 0.9, "land": 0.8, "people": 0.9, "adult": 0.9], humans: 1, humanArea: 0.3)
        let tags = ShotClassifier.shotTags(exif: exif(), vision: person)
        #expect(!tags.contains("Landscape"))
        #expect(tags.contains("Portrait"))
    }

    @Test func tinyTextDoesntCount() {
        let speck = vision(["outdoor": 0.9], text: ["EXIT"], textArea: 0.001)
        #expect(!ShotClassifier.shotTags(exif: exif(), vision: speck).contains("Contains text"))
        let sign = vision(["outdoor": 0.9], text: ["Welcome to Ouro Preto", "Est. 1711"], textArea: 0.08)
        #expect(ShotClassifier.shotTags(exif: exif(), vision: sign).contains("Contains text"))
    }

    @Test func weakObjectLabelsAreDropped() {
        let findings = vision(["outdoor": 0.9, "beach": 0.8, "fork": 0.3, "fence": 0.5, "sunglasses": 0.3])
        let tags = ShotClassifier.contentTags(vision: findings)
        #expect(tags.contains("Beach"))
        #expect(tags.contains("Sunglasses"))
        #expect(!tags.contains("Fence"))
        #expect(!lowercased(tags).contains("fork"))
    }

    @Test func dateTagsUseThePhotosTimeZone() {
        var info = ExifInfo()
        // 2025-02-23 18:30 in Moscow (UTC+3) = 15:30 UTC.
        info.dateTaken = Date(timeIntervalSince1970: 1_740_324_600)
        info.utcOffsetSeconds = 3 * 3600
        #expect(ShotClassifier.exifTags(exif: info).contains("Evening"))
        info.utcOffsetSeconds = -3 * 3600 // same instant in São Paulo: 12:30
        #expect(ShotClassifier.exifTags(exif: info).contains("Afternoon"))
    }

    @Test(arguments: [("+03:00", 10800), ("-03:00", -10800), ("+0530", 19800), ("garbage", nil), ("+3", nil)])
    func parsesUTCOffsets(text: String, seconds: Int?) {
        #expect(ExifReader.parseOffset(text) == seconds)
    }
}

// MARK: - Tag sorting, JSON round trip and live sync

@MainActor
struct LibraryIntegrationTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: PhotoRecord.self, ScannedFolder.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func tagSorterPicksCategories() {
        let sorter = TagSorter(library: [])
        #expect(sorter.kind(for: "Golden hour") == .shot)
        #expect(sorter.kind(for: "Long exposure") == .shot)
        #expect(sorter.kind(for: "Times Square") == .content)
        #expect(sorter.kind(for: "Dog") == .content)
        #expect(sorter.kind(for: "Dog", suggested: "typeOfShot") == .shot)
    }

    @Test func jsonExportImportRoundTrip() throws {
        // The container must outlive its context, or SwiftData traps.
        let store = try container()
        let context = store.mainContext
        let original = makePhoto(content: ["Beach", "Sky"], path: "/tmp/photos-analyze-tests/a.jpg")
        context.insert(original)
        original.addUserTag("Trip")
        original.removeTag("Sky", from: .content)
        let data = try LibraryScanner.exportJSON([original])

        let copy = makePhoto(content: ["Beach", "Sky"], path: "/tmp/photos-analyze-tests/a.jpg")
        let freshStore = try container()
        let fresh = freshStore.mainContext
        fresh.insert(copy)
        let result = try LibraryScanner().importJSON(data, photos: [copy], context: fresh)
        #expect(result.updated == 1 && result.unmatched == 0)
        #expect(copy.userTags == ["Trip"])
        #expect(!copy.contentTags.contains("Sky"))
    }

    @Test func liveSyncAppliesEditsButProtectsUserTags() throws {
        let store = try container()
        let context = store.mainContext
        let root = "/tmp/photos-analyze-tests"
        let photo = makePhoto(content: ["Beach", "Fork"], path: "\(root)/b.jpg")
        context.insert(photo)
        photo.addTag("Dog", to: .content)

        let base = LiveTagSync.makeFile(for: [photo], rootPath: root)
        var edited = base
        // Claude removes Fork and Dog (user-added) and adds Sunset.
        edited.photos[0].inTheShot = (edited.photos[0].inTheShot ?? []).filter { $0 != "Fork" && $0 != "Dog" } + ["Ocean"]
        LiveTagSync.apply(edited: edited, base: base, rootPath: root, photos: [photo], allPhotos: [photo],
                          scanner: LibraryScanner(), context: context)
        photo.refreshDerivedTags(merges: [:])
        #expect(!photo.contentTags.contains("Fork"))
        #expect(photo.contentTags.contains("Dog"))
        #expect(photo.contentTags.contains("Ocean"))
    }
}
