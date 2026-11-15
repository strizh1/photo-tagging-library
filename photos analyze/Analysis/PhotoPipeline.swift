//
//  PhotoPipeline.swift
//  photos analyze
//

import Foundation
import UniformTypeIdentifiers

/// An image discovered on disk. Files in the same folder that share a name but
/// differ in extension (e.g. `IMG_1.CR3` + `IMG_1.JPG`) form one `ImageFile`:
/// `url` is the file that gets analyzed, `variants` are the others.
nonisolated struct ImageFile: Sendable {
    let url: URL
    var variants: [URL] = []
    /// Latest modification date across the file, its variants and any XMP sidecar,
    /// so editing any of them triggers re-analysis.
    let modifiedAt: Date?

    var allURLs: [URL] { [url] + variants }
}

/// The complete output of analyzing one image.
nonisolated struct AnalysisResult: Sendable {
    let url: URL
    let fileModifiedAt: Date?
    let exif: ExifInfo
    let contentTags: [String]
    let shotTags: [String]
    let exifTags: [String]
    let caption: String?
    let recognizedText: String?
    let aestheticScore: Double?
    let faceCount: Int
    let variants: [URL]
    let aiEdits: [String]
}

/// What the library has learned from the user, passed into every analysis.
nonisolated struct TaggingContext: Sendable {
    /// The user's renames, merges and deletions (`TagMerges`).
    var merges: [String: String] = [:]
    /// Lowercased tags the user keeps removing from photos (`TagFeedback`); never added automatically.
    var suppressed: Set<String> = []
    /// Tag names already in the library, most used first, for the language model to reuse.
    var vocabulary: [String] = []
}

nonisolated enum PhotoPipeline {

    /// Recursively lists every image file (HEIC, JPEG, PNG, RAW, …) under `folder`.
    @concurrent
    static func findImages(in folder: URL) async -> [ImageFile] {
        enumerateImages(in: folder)
    }

    private static func enumerateImages(in folder: URL) -> [ImageFile] {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        struct Found {
            let url: URL
            let type: UTType
            let modifiedAt: Date?
        }
        var groups: [String: [Found]] = [:]
        var sidecarDates: [String: Date] = [:]

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType
            else { continue }
            let key = groupKey(for: url)
            if url.pathExtension.lowercased() == "xmp" {
                // `IMG_1.xmp` and `IMG_1.CR3.xmp` both belong to the `IMG_1` group.
                let sidecarKey = groupKey(for: url.deletingPathExtension())
                for k in [key, sidecarKey] {
                    if let date = values.contentModificationDate {
                        sidecarDates[k] = max(sidecarDates[k] ?? date, date)
                    }
                }
                continue
            }
            guard type.conforms(to: .image), !type.conforms(to: .svg), !type.conforms(to: .ico) else { continue }
            groups[key, default: []].append(Found(url: url, type: type, modifiedAt: values.contentModificationDate))
        }

        let files = groups.map { key, members in
            let sorted = members.sorted {
                (rank($0.type), $0.url.lastPathComponent) < (rank($1.type), $1.url.lastPathComponent)
            }
            let dates = members.compactMap(\.modifiedAt) + [sidecarDates[key]].compactMap { $0 }
            return ImageFile(url: sorted[0].url, variants: sorted.dropFirst().map(\.url), modifiedAt: dates.max())
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// Folder path + file name without extension, case-insensitive.
    private static func groupKey(for url: URL) -> String {
        url.deletingPathExtension().path.lowercased()
    }

    /// Which file of a group gets analyzed: rendered images first (they reflect the
    /// final edit and decode quickly), RAW files last.
    private static func rank(_ type: UTType) -> Int {
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return 0 }
        if type.conforms(to: .jpeg) { return 1 }
        if type.conforms(to: .png) { return 2 }
        if type.conforms(to: .tiff) && !type.conforms(to: .rawImage) { return 3 }
        if type.conforms(to: .rawImage) { return 5 }
        return 4
    }

    /// Runs EXIF extraction, Vision analysis, shot classification and (optionally)
    /// the on-device language model for a single image, off the main actor.
    @concurrent
    static func analyze(_ file: ImageFile, useAI: Bool, context: TaggingContext = TaggingContext()) async -> AnalysisResult {
        let exif = ExifReader.read(url: file.url)
        // Decode once into a normalized 8-bit image shared by Vision and the language model.
        let image = ImageDecoder.sdrImage(url: file.url, maxPixelSize: 2048)
        let vision = if let image { await VisionAnalyzer.analyze(image: image) } else { VisionFindings() }

        var contentTags = ShotClassifier.contentTags(vision: vision, merges: context.merges, suppressed: context.suppressed)
        var caption: String?
        if useAI, let image, let description = await SceneDescriber.describe(image: image, vocabulary: context.vocabulary) {
            caption = description.caption
            // Cleaned together with the Vision tags so synonyms from the two sources
            // ("Surfing" and "surf") collapse into one tag.
            contentTags = TagTaxonomy.clean(contentTags + description.tagCandidates,
                                            merges: context.merges, suppressed: context.suppressed)
        }
        let shotTags = ShotClassifier.shotTags(exif: exif, vision: vision)
            .filter { !context.suppressed.contains($0.lowercased()) }
        // A tag already in "Type of shot" (Landscape, Cityscape…) isn't repeated in "In the shot".
        let shotKeys = Set(shotTags.map(SimilarTags.normalized))
        contentTags.removeAll { shotKeys.contains(SimilarTags.normalized($0)) }

        let text = vision.recognizedText.joined(separator: "\n")
        return AnalysisResult(
            url: file.url,
            fileModifiedAt: file.modifiedAt,
            exif: exif,
            contentTags: contentTags,
            shotTags: shotTags,
            exifTags: ShotClassifier.exifTags(exif: exif),
            caption: caption,
            recognizedText: text.isEmpty ? nil : text,
            aestheticScore: vision.aestheticScore.map(Double.init),
            faceCount: vision.faceCount,
            variants: file.variants,
            aiEdits: AIEditDetector.detect(in: file.allURLs)
        )
    }
}
