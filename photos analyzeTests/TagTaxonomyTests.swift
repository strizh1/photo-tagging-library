//
//  TagTaxonomyTests.swift
//  photos analyzeTests
//

import Foundation
import Testing
@testable import photos_analyze

/// Tests use explicit merge dictionaries, never the app's real `TagMerges` defaults.
struct TagTaxonomyTests {

    @Test func synonymsCollapseIntoOneTag() {
        let tags = TagTaxonomy.clean(["pole", "lamppost", "utility_pole", "automobile", "car"], merges: [:])
        #expect(tags == ["Pole", "Car"])
    }

    @Test func noiseLabelsAreDropped() {
        let tags = TagTaxonomy.clean(["structure", "machine", "red", "fork", "clothing", "beach"], merges: [:])
        #expect(tags == ["Beach"])
    }

    @Test func userDeletionOfRawNameWins() {
        // The user deleted "flower"; it must not come back as "Flowers".
        #expect(TagTaxonomy.canonical("flower", merges: ["flower": ""]) == nil)
        #expect(TagTaxonomy.canonical("blossom", merges: ["flower": ""]) == "Flowers")
    }

    @Test func userMergeAppliesAfterSynonyms() {
        let merges = ["surfing": "Surf"]
        #expect(TagTaxonomy.canonical("surfer", merges: merges) == "Surf")
        #expect(TagTaxonomy.canonical("surfing", merges: merges) == "Surf")
    }

    @Test func surfingImpliesWatersportAndSport() {
        let implied = TagTaxonomy.implied(by: ["Surfing"], merges: [:])
        #expect(implied.contains("Watersport"))
        #expect(implied.contains("Sport"))
        #expect(TagTaxonomy.implied(by: ["Surf"], merges: [:]).contains("Watersport"))
    }

    @Test func implicationsFollowUserMerges() {
        // Tags carrying the user's merged name still imply, and implied names are renamed.
        let implied = TagTaxonomy.implied(by: ["Surf"], merges: ["surfing": "Surf", "watersport": "Water sports"])
        #expect(implied.contains("Water sports"))
        #expect(!implied.contains("Watersport"))
    }

    @Test func deletedTagsAreNeverImplied() {
        let implied = TagTaxonomy.implied(by: ["Surfing"], merges: ["watersport": ""])
        #expect(!implied.contains { $0.caseInsensitiveCompare("Watersport") == .orderedSame })
    }

    @Test func impliedTagIsAddedButRespectsPhotoRemovals() {
        let photo = PhotoRecord(result: Self.result(content: ["Surfing", "Ocean"]), rootFolderPath: "/tmp")
        photo.refreshDerivedTags(merges: [:])
        #expect(photo.contentTags.contains("Watersport"))
        #expect(photo.contentTags.contains("Water body"))

        // The user removed "Watersport" from this photo: it must stay gone.
        photo.removedContentTags = ["Watersport"]
        photo.refreshDerivedTags(merges: [:])
        #expect(!photo.contentTags.contains("Watersport"))
    }

    @Test func userAddedTagsSurviveReanalysis() {
        let photo = PhotoRecord(result: Self.result(content: ["Beach"]), rootFolderPath: "/tmp")
        photo.addedContentTags = ["Sunset / sunrise"]
        photo.apply(Self.result(content: ["Sky"]), merges: [:])
        #expect(photo.contentTags.contains("Sunset / sunrise"))
    }

    @Test func userTagsAlsoTriggerImplications() {
        let photo = PhotoRecord(result: Self.result(content: ["Beach"]), rootFolderPath: "/tmp")
        photo.userTags = ["Kayak"]
        photo.refreshDerivedTags(merges: [:])
        #expect(photo.contentTags.contains("Watersport"))
    }

    private static func result(content: [String], shot: [String] = []) -> AnalysisResult {
        AnalysisResult(
            url: URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).jpg"), fileModifiedAt: nil, exif: ExifInfo(),
            contentTags: content, shotTags: shot, exifTags: [], caption: nil, recognizedText: nil,
            aestheticScore: nil, faceCount: 0, variants: [], aiEdits: []
        )
    }
}
