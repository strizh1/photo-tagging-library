//
//  ExifReader.swift
//  photos analyze
//

import Foundation
import ImageIO

/// Metadata extracted from an image file's EXIF / TIFF / GPS dictionaries.
nonisolated struct ExifInfo: Codable, Sendable, Hashable {
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var software: String?
    var focalLength: Double?
    var focalLength35mm: Double?
    var aperture: Double?
    var exposureTime: Double?
    var iso: Int?
    var flashFired: Bool?
    /// EXIF SceneCaptureType: 0 standard, 1 landscape, 2 portrait, 3 night.
    var sceneCaptureType: Int?
    var dateTaken: Date?
    /// The photo's UTC offset in seconds when the file records it (EXIF OffsetTimeOriginal),
    /// so times of day are judged where the photo was taken, not where the Mac is.
    var utcOffsetSeconds: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var userComment: String?
    /// True when the file carries depth / disparity / portrait matte data (e.g. iPhone Portrait mode).
    var hasDepthData: Bool = false
    var fileType: String?

    /// Display-oriented aspect ratio (width / height).
    var aspectRatio: Double? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    var cameraName: String? {
        guard let model = cameraModel?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return cameraMake
        }
        // Many manufacturers already include the make in the model ("Canon EOS R5").
        if let make = cameraMake?.trimmingCharacters(in: .whitespaces), !make.isEmpty,
           !model.lowercased().contains(make.lowercased().components(separatedBy: " ").first ?? "") {
            return "\(make) \(model)"
        }
        return model
    }

    var isPhone: Bool {
        let make = (cameraMake ?? "").lowercased()
        let model = (cameraModel ?? "").lowercased()
        return model.contains("iphone") || model.contains("pixel") || model.hasPrefix("sm-")
            || ["apple", "google", "samsung", "xiaomi", "oneplus", "huawei"].contains(make)
    }

    /// The time zone the photo was taken in, or the Mac's current one if unknown.
    var timeZone: TimeZone {
        utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
    }

    var isFrontCamera: Bool {
        (lensModel ?? "").lowercased().contains("front")
    }

    var formattedExposure: String? {
        guard let t = exposureTime, t > 0 else { return nil }
        return t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))s"
    }
}

nonisolated enum ExifReader {

    static func read(url: URL) -> ExifInfo {
        var info = ExifInfo()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return info }
        info.fileType = (CGImageSourceGetType(source) as String?).map(shortTypeName)

        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return info
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        info.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
        info.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        info.software = tiff[kCGImagePropertyTIFFSoftware] as? String
        info.lensModel = (exif[kCGImagePropertyExifLensModel] as? String)
            ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String)

        info.focalLength = double(exif[kCGImagePropertyExifFocalLength])
        info.focalLength35mm = double(exif[kCGImagePropertyExifFocalLenIn35mmFilm])
        info.aperture = double(exif[kCGImagePropertyExifFNumber])
        info.exposureTime = double(exif[kCGImagePropertyExifExposureTime])
        info.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        if let flash = exif[kCGImagePropertyExifFlash] as? NSNumber {
            // Bit 0 of the EXIF Flash tag indicates whether the flash fired.
            info.flashFired = (flash.intValue & 0x1) == 1
        }
        info.sceneCaptureType = (exif[kCGImagePropertyExifSceneCaptureType] as? NSNumber)?.intValue
        info.userComment = exif[kCGImagePropertyExifUserComment] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        info.dateTaken = parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String, offset: offset)
        if info.dateTaken != nil { info.utcOffsetSeconds = offset.flatMap(parseOffset) }

        // Report dimensions as displayed, accounting for rotated orientations (5–8).
        var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        info.pixelWidth = width
        info.pixelHeight = height

        if let lat = double(gps[kCGImagePropertyGPSLatitude]),
           let lon = double(gps[kCGImagePropertyGPSLongitude]) {
            info.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            info.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            info.altitude = double(gps[kCGImagePropertyGPSAltitude])
        }

        let auxTypes = [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
        info.hasDepthData = auxTypes.contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }

        return info
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func parseDate(_ string: String?, offset: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: string + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }

    /// "+03:00" / "-0300" → seconds east of UTC.
    static func parseOffset(_ offset: String) -> Int? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 18, minutes < 60
        else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    private static func shortTypeName(_ uti: String) -> String {
        switch uti {
        case "public.heic", "public.heif": "HEIC"
        case "public.jpeg": "JPEG"
        case "public.png": "PNG"
        case "public.tiff": "TIFF"
        case _ where uti.contains("raw"): "RAW"
        default: uti.components(separatedBy: ".").last?.uppercased() ?? uti
        }
    }
}
