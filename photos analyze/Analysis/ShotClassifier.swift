//
//  ShotClassifier.swift
//  photos analyze
//

import Foundation

/// A small rule-based "model" that infers the type of shot by combining
/// camera metadata (focal length, shutter, depth data…) with Vision findings
/// (faces, labels, utility score…).
nonisolated enum ShotClassifier {

    /// Every shot type the classifier can produce, offered as suggestions when editing.
    static let allShotTypes = [
        "Selfie", "Group selfie", "Portrait", "Portrait mode", "Group photo", "Street", "Close-up",
        "Landscape", "Cityscape", "Architecture", "Food", "Animal", "Sunset / sunrise", "Aerial / drone",
        "Ultra-wide", "Wide angle", "Standard lens", "Telephoto", "Super telephoto", "Macro",
        "Shallow depth of field", "Long exposure", "Fast shutter / action", "Night / low light", "Flash",
        "Panorama", "Square", "Horizontal", "Vertical", "Screenshot", "Document", "Contains text",
        "High quality", "Low quality",
    ]

    static func shotTags(exif: ExifInfo, vision: VisionFindings) -> [String] {
        var tags: [String] = []
        func add(_ tag: String) { if !tags.contains(tag) { tags.append(tag) } }

        let isScreenshot = (exif.userComment ?? "").localizedCaseInsensitiveContains("screenshot")
            || (exif.cameraMake == nil && exif.exposureTime == nil && exif.fileType == "PNG")

        // MARK: Non-photographic images
        if isScreenshot { add("Screenshot") }
        if vision.isUtility && vision.recognizedText.count >= 5 && !isScreenshot { add("Document") }

        // MARK: People
        let faces = vision.faceCount
        if exif.isFrontCamera && faces >= 1 {
            add(faces >= 3 ? "Group selfie" : "Selfie")
        } else if faces >= 3 || vision.humanCount >= 4 {
            add("Group photo")
        } else if faces >= 1 && (exif.hasDepthData || exif.sceneCaptureType == 2 || vision.largestFaceArea > 0.03) {
            add("Portrait")
        } else if faces <= 2 && (1...2).contains(vision.humanCount) && vision.largestHumanArea >= 0.12
                    && vision.confidence("people", "adult", "child", "teen", "baby") >= 0.5 {
            // A prominent person with no visible face (turned away, sunglasses, hat).
            add("Portrait")
        } else if faces == 0 && vision.humanCount >= 1 && vision.hasLabel("street", "road", "city", "crowd") {
            add("Street")
        }
        if exif.hasDepthData { add("Portrait mode") }
        if vision.largestFaceArea > 0.2 { add("Close-up") }

        // MARK: Scene type
        // A landscape needs land or water in an open view. Sky alone (planes, the moon,
        // clouds) or a forest interior isn't one, and neither is a shot of a person or animal.
        let landform = vision.confidence(
            "land", "hill", "mountain", "beach", "desert", "field", "rice_field", "sand_dune", "ocean", "lake",
            "cliff", "canyon", "volcano", "glacier", "shore", "island", "wetland", "valley"
        ) >= 0.3
        let openView = vision.confidence("sky", "blue_sky", "cloudy", "sunset_sunrise", "night_sky") >= 0.3
        let hasSubject = vision.largestHumanArea >= 0.05 || vision.confidence("people", "adult", "child") >= 0.5
            || vision.confidence("animal", "bird") >= 0.5
        if faces == 0 && !hasSubject && (exif.sceneCaptureType == 1 || (landform && openView)) { add("Landscape") }
        if vision.hasLabel("cityscape", "skyscraper") { add("Cityscape") }
        if vision.hasLabel("architecture", "building", "bridge", "church", "tower") && faces == 0 { add("Architecture") }
        if vision.hasLabel("food", "dish", "dessert", "baked_goods", "meal") { add("Food") }
        if !vision.animals.isEmpty || vision.hasLabel("animal", "dog", "cat", "bird") { add("Animal") }
        if vision.confidence("sunset_sunrise") >= 0.25 { add("Sunset / sunrise") }
        if (exif.cameraMake ?? "").localizedCaseInsensitiveContains("DJI") { add("Aerial / drone") }

        // MARK: Lens / framing (35 mm equivalent focal length)
        if let f = exif.focalLength35mm, f > 0 {
            switch f {
            case ..<20: add("Ultra-wide")
            case 20..<35: add("Wide angle")
            case 35..<70: add("Standard lens")
            case 70..<200: add("Telephoto")
            default: add("Super telephoto")
            }
        }
        if (exif.lensModel ?? "").localizedCaseInsensitiveContains("macro") { add("Macro") }
        if let a = exif.aperture, a <= 2.0, !exif.isPhone, (exif.focalLength35mm ?? 50) >= 35 {
            add("Shallow depth of field")
        }

        // MARK: Exposure
        if let t = exif.exposureTime {
            if t >= 1 { add("Long exposure") }
            // A fast shutter only matters when something is moving; on a bright static
            // scene it's just the camera's exposure choice.
            let movingSubject = !vision.animals.isEmpty || vision.humanCount > 0
                || vision.confidence("animal", "bird", "sport", "watersport", "surfing", "windsurfing", "kayak",
                                     "motorsport", "aircraft", "boat") >= 0.3
                || vision.confidence("vehicle", "car", "bicycle", "motorcycle", "train") >= 0.7
            if t <= 1.0 / 1000 && movingSubject { add("Fast shutter / action") }
        }
        let lowLightLabels = vision.hasLabel("night_sky", "night", "fireworks")
        if exif.sceneCaptureType == 3 || lowLightLabels
            || ((exif.iso ?? 0) >= 1600 && (exif.exposureTime ?? 0) >= 1.0 / 30) {
            add("Night / low light")
        }
        if exif.flashFired == true { add("Flash") }

        // MARK: Shape
        if let ratio = exif.aspectRatio {
            if ratio >= 2.2 || ratio <= 1 / 2.2 { add("Panorama") }
            else if abs(ratio - 1) < 0.02 { add("Square") }
            else { add(ratio > 1 ? "Horizontal" : "Vertical") }
        }

        // MARK: Quality
        if let score = vision.aestheticScore, !isScreenshot {
            if score >= 0.5 { add("High quality") }
            else if score <= -0.3 && !vision.isUtility { add("Low quality") }
        }
        // Only text that's a real part of the picture (a sign, a page), not a speck.
        let characters = vision.recognizedText.reduce(0) { $0 + $1.count }
        if !isScreenshot && vision.textArea >= 0.02 && characters >= 12 { add("Contains text") }

        return tags
    }

    /// Tags derived from metadata only: camera, lens, date, location, format.
    static func exifTags(exif: ExifInfo) -> [String] {
        var tags: [String] = []
        if let camera = exif.cameraName { tags.append(camera) }
        if let lens = exif.lensModel, !lens.isEmpty { tags.append(lens) }
        if let date = exif.dateTaken {
            // Year, month and time of day as they were where the photo was taken.
            var calendar = Calendar.current
            calendar.timeZone = exif.timeZone
            tags.append(String(calendar.component(.year, from: date)))
            var monthStyle = Date.FormatStyle.dateTime.month(.wide)
            monthStyle.timeZone = exif.timeZone
            tags.append(date.formatted(monthStyle))
            switch calendar.component(.hour, from: date) {
            case 5..<12: tags.append("Morning")
            case 12..<17: tags.append("Afternoon")
            case 17..<21: tags.append("Evening")
            default: tags.append("Night time")
            }
        }
        if exif.latitude != nil { tags.append("Geotagged") }
        if let type = exif.fileType { tags.append(type) }
        let software = (exif.software ?? "").lowercased()
        if ["lightroom", "photoshop", "snapseed", "vsco", "capture one", "darktable", "affinity"].contains(where: software.contains) {
            tags.append("Edited")
        }
        return tags
    }

    /// Content tags from Vision labels and detections, cleaned up by `TagTaxonomy`.
    /// `suppressed` holds tags the user keeps removing (see `TagFeedback`).
    static func contentTags(vision: VisionFindings, merges: [String: String] = [:], suppressed: Set<String> = []) -> [String] {
        // Objects only count when Vision is fairly sure (see `minimumConfidence`).
        var raw = vision.labels
            .filter { $0.confidence >= TagTaxonomy.minimumConfidence(for: $0.name) }
            .map(\.name)
        raw += vision.animals
        if vision.faceCount > 0 || vision.humanCount > 0 { raw.append("people") }
        return TagTaxonomy.clean(raw, merges: merges, suppressed: suppressed)
    }

    static func prettify(_ identifier: String) -> String {
        let words = identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
