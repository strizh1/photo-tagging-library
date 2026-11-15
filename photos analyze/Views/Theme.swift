//
//  Theme.swift
//  photos analyze
//

import SwiftUI

/// Shared colors, symbols and copy that give the app a consistent personality.
enum Theme {
    /// Tint for each tag category, used in the sidebar, chips and detail sections.
    static let shotTint = Color.orange
    static let contentTint = Color.blue
    static let exifTint = Color.green
    static let folderTint = Color.indigo

    static let cardRadius: CGFloat = 12

    /// An SF Symbol that represents a shot-type tag, so lists read at a glance.
    static func symbol(forShotTag tag: String) -> String {
        switch tag.lowercased() {
        case "selfie", "group selfie": "person.crop.circle"
        case "portrait", "portrait mode": "person.crop.rectangle"
        case "group photo": "person.3"
        case "street": "figure.walk"
        case "close-up", "macro": "camera.macro"
        case "landscape": "mountain.2"
        case "cityscape", "architecture": "building.2"
        case "food": "fork.knife"
        case "animal": "pawprint"
        case "sunset / sunrise": "sunset"
        case "aerial / drone": "airplane"
        case "ultra-wide", "wide angle": "arrow.left.and.right"
        case "telephoto", "super telephoto": "scope"
        case "standard lens": "camera"
        case "shallow depth of field": "camera.aperture"
        case "long exposure": "timer"
        case "fast shutter / action": "bolt"
        case "night / low light": "moon.stars"
        case "flash": "bolt.badge.automatic"
        case "panorama": "pano"
        case "square": "square"
        case "horizontal": "rectangle"
        case "vertical": "rectangle.portrait"
        case "screenshot": "iphone"
        case "document", "contains text": "doc.text"
        case "high quality": "star"
        case "low quality": "star.slash"
        default: "camera.aperture"
        }
    }

    static let aiTint = Color.purple

    /// An SF Symbol for an AI edit label from `AIEditDetector`.
    static func symbol(forAIEdit label: String) -> String {
        switch label {
        case "AI-generated image": "wand.and.sparkles"
        case "Generative AI edit": "sparkles.rectangle.stack"
        case "Super Resolution": "arrow.up.left.and.arrow.down.right"
        case "AI Denoise": "aqi.low"
        case "Raw Details": "circle.grid.cross"
        case "Object removal": "eraser"
        case "Lens Blur": "camera.filters"
        case "AI masks": "person.and.background.dotted"
        default: "sparkles"
        }
    }
}

/// A friendly verdict for Vision's aesthetics score (-1...1), also used as a sidebar filter.
enum QualityVerdict: String, CaseIterable, Hashable {
    case galleryWorthy = "Gallery-worthy"
    case lookingGood = "Looking good"
    case solid = "Solid snapshot"
    case happyAccident = "Happy accident"

    nonisolated init(score: Double) {
        self = switch score {
        case 0.5...: .galleryWorthy
        case 0.15..<0.5: .lookingGood
        case -0.2..<0.15: .solid
        default: .happyAccident
        }
    }

    /// Display name; the user can rename verdicts (see `QualityNames`).
    var title: String { QualityNames.shared.name(for: self) }

    var symbol: String {
        switch self {
        case .galleryWorthy: "sparkles"
        case .lookingGood: "hand.thumbsup.fill"
        case .solid: "camera.fill"
        case .happyAccident: "face.smiling"
        }
    }

    var tint: Color {
        switch self {
        case .galleryWorthy: .pink
        case .lookingGood: .orange
        case .solid: .blue
        case .happyAccident: .gray
        }
    }
}

/// A rounded, softly filled container used to group content in the detail view.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// A section heading with a tinted SF Symbol, in the style of the Photos info panel.
struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.headline)
    }
}

/// Custom names for quality verdicts, chosen by the user. Stored in UserDefaults and
/// observable so renamed verdicts update everywhere immediately.
@Observable
final class QualityNames {
    static let shared = QualityNames()
    private static let defaultsKey = "qualityNames"

    /// Verdict raw value → custom name.
    private(set) var custom: [String: String]

    private init() {
        custom = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func name(for verdict: QualityVerdict) -> String {
        custom[verdict.rawValue] ?? verdict.rawValue
    }

    /// Renames a verdict; an empty name or the original name restores the default.
    func rename(_ verdict: QualityVerdict, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        custom[verdict.rawValue] = (trimmed.isEmpty || trimmed == verdict.rawValue) ? nil : trimmed
        UserDefaults.standard.set(custom, forKey: Self.defaultsKey)
    }
}
