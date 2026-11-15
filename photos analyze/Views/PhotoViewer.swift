//
//  PhotoViewer.swift
//  photos analyze
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What the viewer window shows: one photo and all of its files.
struct ViewerItem: Codable, Hashable {
    let title: String
    let paths: [String]

    init(photo: PhotoRecord) {
        title = photo.displayName
        paths = photo.allURLs.map(\.path)
    }
}

nonisolated enum FullImageLoader {
    /// Decodes the whole image at full resolution, orientation-corrected, keeping its
    /// color space and HDR (gain map) data so it can be shown at full quality.
    @concurrent
    static func load(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The highest-quality file of a photo: most pixels first (e.g. a Super Resolution
    /// export beats its RAW), then RAW / lossless formats over lossy ones.
    @concurrent
    static func bestQuality(_ urls: [URL]) async -> URL? {
        urls.max { quality(of: $0) < quality(of: $1) }
    }

    private static func quality(of url: URL) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (0, 0) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? .data
        let formatRank = switch true {
        case type.conforms(to: .rawImage): 4
        case type.conforms(to: .tiff), type.conforms(to: .png): 3
        case type.conforms(to: .heic), type.conforms(to: .heif): 2
        case type.conforms(to: .jpeg): 1
        default: 0
        }
        return (width * height, formatRank)
    }
}

/// A window showing a photo at full resolution, zoomable with pinch or ⌘+/⌘−.
struct PhotoViewer: View {
    let item: ViewerItem

    @State private var selectedPath: String?
    @State private var image: CGImage?
    @State private var isLoading = true

    private var urls: [URL] { item.paths.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImageView(image: image)
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView("Loading full resolution…")
                    .foregroundStyle(.white)
            } else {
                ContentUnavailableView("Couldn’t Open This Image", systemImage: "photo.badge.exclamationmark")
            }
        }
        .frame(minWidth: 500, minHeight: 350)
        .navigationTitle(item.title)
        .navigationSubtitle(selectedPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        .toolbar {
            if urls.count > 1 {
                ToolbarItem {
                    Picker("Version", selection: $selectedPath) {
                        ForEach(urls, id: \.path) { url in
                            Text(url.pathExtension.uppercased()).tag(Optional(url.path))
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Switch between this photo’s files")
                }
            }
            if let selectedPath {
                ToolbarItem {
                    Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: selectedPath))
                    }
                }
            }
        }
        .task {
            selectedPath = await FullImageLoader.bestQuality(urls)?.path
        }
        .task(id: selectedPath) {
            guard let selectedPath else { return }
            isLoading = true
            image = await FullImageLoader.load(URL(fileURLWithPath: selectedPath))
            isLoading = false
        }
    }
}

/// An AppKit scroll view that shows the image fit-to-window and supports pinch zoom,
/// scrolling and double-click to toggle between fit and actual pixels.
private struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.allowsMagnification = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView = CenteringClipView()
        scrollView.maxMagnification = 8

        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.preferredImageDynamicRange = .high
        scrollView.documentView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomingScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView,
              scrollView.currentImage !== image
        else { return }
        scrollView.currentImage = image
        // One image pixel per screen pixel at 100 % magnification.
        let scale = scrollView.window?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.frame = NSRect(origin: .zero, size: size)
        DispatchQueue.main.async { scrollView.zoomToFit() }
    }
}

private final class ZoomingScrollView: NSScrollView {
    var currentImage: CGImage?

    func zoomToFit() {
        guard let documentView, documentView.frame.width > 0 else { return }
        let fit = min(bounds.width / documentView.frame.width, bounds.height / documentView.frame.height, 1)
        minMagnification = fit
        magnification = fit
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasFit = magnification <= minMagnification + 0.001
        super.setFrameSize(newSize)
        if wasFit { zoomToFit() }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if magnification <= minMagnification + 0.001 {
            setMagnification(1, centeredAt: point)
        } else {
            zoomToFit()
        }
    }
}

/// Keeps the document centered when it's smaller than the visible area.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if rect.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}
