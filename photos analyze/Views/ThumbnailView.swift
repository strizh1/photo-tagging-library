//
//  ThumbnailView.swift
//  photos analyze
//

import SwiftUI
import ImageIO

nonisolated enum ThumbnailLoader {
    /// Decodes a downsampled, orientation-corrected 8-bit image off the main actor.
    @concurrent
    static func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        ImageDecoder.sdrImage(url: url, maxPixelSize: maxPixelSize)
    }
}

struct ThumbnailView: View {
    let url: URL
    var maxPixelSize = 400
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?
    /// Set once decoding finished, so a file that can't be decoded doesn't spin forever.
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if failed {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                                .help("This file can’t be previewed")
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        // Utility priority avoids a priority inversion with ImageIO's default-QoS decode queues.
        .task(id: url, priority: .utility) {
            failed = false
            image = await ThumbnailLoader.thumbnail(for: url, maxPixelSize: maxPixelSize)
            failed = image == nil
        }
    }
}
