//
//  ImageDecoder.swift
//  photos analyze
//

import Foundation
import ImageIO
import CoreGraphics

nonisolated enum ImageDecoder {

    /// Decodes a downsampled, orientation-corrected, 8-bit sRGB image.
    ///
    /// Modern iPhone HEICs can be 10-bit / HDR. Feeding those straight into Vision's
    /// GPU pipeline can hit pixel-format mismatches (e.g. R16Unorm vs R10Unorm_X6),
    /// so analysis always works on a normalized 8-bit copy. Downsampling also makes
    /// analysis much faster and lighter on memory than decoding full-resolution files.
    static func sdrImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return normalizedTo8Bit(decoded)
    }

    /// Redraws the image into an 8-bit RGBA sRGB bitmap unless it already is one.
    private static func normalizedTo8Bit(_ image: CGImage) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if image.bitsPerComponent == 8, image.colorSpace?.name == CGColorSpace.sRGB {
            return image
        }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
