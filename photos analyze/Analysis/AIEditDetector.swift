//
//  AIEditDetector.swift
//  photos analyze
//

import Foundation
import ImageIO

/// Finds traces of AI generation or AI-assisted editing in an image's metadata.
///
/// Looks at three places, all written by the editing apps themselves:
/// - The embedded XMP packet (IPTC `DigitalSourceType`, Lightroom / Camera Raw `crs:` settings,
///   `CreatorTool` and history entries).
/// - A Lightroom-style `.xmp` sidecar next to the file (edits to RAW files live there).
/// - The first few megabytes of the file, which hold C2PA Content Credentials manifests
///   and PNG text chunks written by image generators.
///
/// This only reports what the metadata declares; edits that left no metadata behind
/// can't be detected.
nonisolated enum AIEditDetector {

    /// Exact (case-sensitive) markers searched for in metadata bytes.
    private static let markers: [(pattern: String, label: String)] = [
        // IPTC Digital Source Type, also used inside C2PA manifests (Photoshop, Lightroom,
        // Apple Clean Up, Google Magic Editor, Samsung Galaxy AI…).
        ("digitalsourcetype/trainedAlgorithmicMedia", "AI-generated image"),
        ("compositeWithTrainedAlgorithmicMedia", "Generative AI edit"),
        ("compositeSynthetic", "Generative AI edit"),
        // Lightroom / Camera Raw "Enhance" (written as crs:Enhance…).
        ("EnhanceSuperResolution", "Super Resolution"),
        ("EnhanceDenoise", "AI Denoise"),
        ("EnhanceDetails", "Raw Details"),
        // Lightroom / Camera Raw tools.
        ("RetouchAreas", "Object removal"),
        ("LensBlur", "Lens Blur"),
        ("MaskSubType", "AI masks"),
        // Generator parameters stored in PNG text chunks.
        ("Negative prompt:", "AI-generated image"),
        ("\"class_type\"", "AI-generated image"),
    ]

    /// Lowercased tool names searched for in the Software tag and XMP history.
    private static let tools: [(pattern: String, label: String)] = [
        ("firefly", "Adobe Firefly"),
        ("topaz photo ai", "Topaz Photo AI"),
        ("gigapixel", "Topaz Gigapixel"),
        ("topaz denoise", "Topaz DeNoise AI"),
        ("topaz sharpen", "Topaz Sharpen AI"),
        ("luminar", "Luminar"),
        ("remini", "Remini"),
        ("deepprime", "DxO DeepPRIME"),
        ("pureraw", "DxO PureRAW"),
        ("midjourney", "Midjourney"),
        ("dall-e", "DALL·E"),
        ("dall·e", "DALL·E"),
        ("stable diffusion", "Stable Diffusion"),
        ("comfyui", "ComfyUI"),
    ]

    private static let headLength = 4 * 1024 * 1024

    /// Labels for every AI edit found in any of `urls` (a photo and its variants).
    static func detect(in urls: [URL]) -> [String] {
        var found: [String] = []
        func add(_ label: String) {
            if !found.contains(label) { found.append(label) }
        }

        for url in urls {
            var haystack = head(of: url)
            var toolText = ""

            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
                   let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data? {
                    haystack.append(xmp)
                    toolText += String(decoding: xmp, as: UTF8.self)
                }
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
                    toolText += "\n" + software
                }
            }
            for sidecar in sidecars(for: url) {
                haystack.append(sidecar)
                toolText += String(decoding: sidecar, as: UTF8.self)
            }

            for marker in markers where haystack.range(of: Data(marker.pattern.utf8)) != nil {
                add(marker.label)
            }
            let lowered = toolText.lowercased()
            for tool in tools where lowered.contains(tool.pattern) {
                add(tool.label)
            }
        }

        // A fully generated image is more specific than "edited with generative AI".
        if found.contains("AI-generated image") {
            found.removeAll { $0 == "Generative AI edit" }
        }
        return found
    }

    /// The first few megabytes of the file, where C2PA manifests and PNG text chunks live.
    private static func head(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: headLength)) ?? Data()
    }

    /// Sidecar XMP files: `IMG_1.xmp` (Lightroom, Bridge) and `IMG_1.CR3.xmp` (darktable and others).
    private static func sidecars(for url: URL) -> [Data] {
        let candidates = [
            url.deletingPathExtension().appendingPathExtension("xmp"),
            url.deletingPathExtension().appendingPathExtension("XMP"),
            url.appendingPathExtension("xmp"),
        ]
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.path.lowercased()).inserted else { return nil }
            return try? Data(contentsOf: candidate)
        }
    }
}
