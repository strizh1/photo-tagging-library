//
//  SceneDescriber.swift
//  photos analyze
//

import Foundation
import FoundationModels
import CoreGraphics

/// Structured description the on-device Apple Intelligence model produces for a photo.
@Generable
nonisolated struct SceneDescription {
    @Guide(description: "A single short sentence describing what is in the photo.")
    var caption: String

    @Guide(description: "The things this photo is about, most important first. Only list things that are large, in focus or clearly the point of the photo; skip small background objects.", .count(1...5))
    var subjects: [Subject]

    @Guide(description: "The setting or location type, e.g. beach, kitchen, city street, forest, office.")
    var setting: String

    @Guide(description: "The activity people are doing, e.g. surfing, hiking, kayaking. Empty if nobody is doing anything in particular.")
    var activity: String
}

@Generable
nonisolated struct Subject {
    @Guide(description: "A short lowercase tag of one or two words. A noun for a thing, not a color, material or piece of clothing.")
    var name: String

    @Guide(description: "How much it matters to the photo.")
    var prominence: Prominence
}

@Generable
nonisolated enum Prominence {
    /// What the photo is of.
    case mainSubject
    /// Large and clearly visible, but not the point of the photo.
    case prominent
    /// Small, partly hidden or in the background.
    case minorDetail
}

extension SceneDescription {
    /// Raw tags worth keeping: main and prominent subjects, the setting and the activity.
    nonisolated var tagCandidates: [String] {
        subjects.filter { $0.prominence != .minorDetail }.map(\.name) + [setting, activity]
    }
}

nonisolated enum SceneDescriber {

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in System Settings."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        }
    }

    /// Asks the on-device model to describe the image. Returns nil on any failure
    /// (guardrails, unsupported content, model busy) so analysis can continue.
    /// `vocabulary` lists tag names already used in the library, so the model reuses
    /// them ("Surfing") instead of inventing near-duplicates ("surf", "surfer").
    static func describe(image: CGImage, vocabulary: [String] = []) async -> SceneDescription? {
        let names = vocabulary.prefix(120).joined(separator: ", ")
        let vocabularyHint = names.isEmpty ? "" : """
             When one of these existing tags fits, use exactly that name instead of a synonym: \(names).
            """
        // A fresh session per image keeps the context window small.
        let session = LanguageModelSession(instructions: """
            You are a photo cataloguing assistant. You look at a photo and describe \
            its visible content accurately and concisely for search and tagging. \
            Tag only what a person would say the photo is of; fewer, accurate tags are \
            better than many. Never guess the identity of people.
            """ + vocabularyHint)
        do {
            let response = try await session.respond(generating: SceneDescription.self) {
                "Describe this photo and list tags for what is visible in it."
                Attachment(image)
            }
            return response.content
        } catch {
            return nil
        }
    }
}
