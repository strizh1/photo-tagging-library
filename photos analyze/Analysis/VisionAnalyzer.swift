//
//  VisionAnalyzer.swift
//  photos analyze
//

import Foundation
import Vision

/// Raw signals produced by Apple's on-device Vision models for a single image.
nonisolated struct VisionFindings: Sendable {
    /// Scene / object labels from the built-in image classifier, highest confidence first.
    var labels: [(name: String, confidence: Float)] = []
    /// Every label above a low confidence floor, including ones that fail the
    /// high-precision filter. Used by rules that weigh weaker evidence (e.g. sunsets).
    var allLabels: [String: Float] = [:]
    var faceCount = 0
    /// Area of the largest face as a fraction of the image (0...1).
    var largestFaceArea: Double = 0
    var humanCount = 0
    /// Area of the largest detected person (full body or upper body) as a fraction of the image.
    var largestHumanArea: Double = 0
    var animals: [String] = []
    var recognizedText: [String] = []
    /// Fraction of the image covered by recognized text, so tiny incidental text
    /// (a far-away sign, a T-shirt logo) doesn't count as "Contains text".
    var textArea: Double = 0
    /// Overall aesthetics score in -1...1, nil if unavailable.
    var aestheticScore: Float?
    /// Vision flags images like receipts, screenshots and documents as "utility" images.
    var isUtility = false

    func hasLabel(_ names: String...) -> Bool {
        labels.contains { names.contains($0.name) }
    }

    /// Highest raw confidence among `names` (0 if Vision didn't report any of them).
    func confidence(_ names: String...) -> Float {
        names.compactMap { allLabels[$0] }.max() ?? 0
    }
}

nonisolated enum VisionAnalyzer {

    /// Runs all Vision requests against one image. Individual request failures are
    /// tolerated so that one unsupported request doesn't discard the others.
    static func analyze(image: CGImage) async -> VisionFindings {
        var findings = VisionFindings()
        // The image is already orientation-corrected by `ImageDecoder`.
        let handler = ImageRequestHandler(image)

        if let observations = try? await handler.perform(ClassifyImageRequest()) {
            for observation in observations where observation.confidence > 0.05 {
                findings.allLabels[observation.identifier] = observation.confidence
            }
            findings.labels = observations
                // High-precision filter keeps only labels Vision is fairly sure about.
                .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) && $0.confidence > 0.2 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(24)
                .map { (name: $0.identifier, confidence: $0.confidence) }
        }

        if let faces = try? await handler.perform(DetectFaceRectanglesRequest()) {
            findings.faceCount = faces.count
            findings.largestFaceArea = faces
                .map { Double($0.boundingBox.width * $0.boundingBox.height) }
                .max() ?? 0
        }

        if let humans = try? await handler.perform(DetectHumanRectanglesRequest()) {
            findings.humanCount = humans.count
            findings.largestHumanArea = humans
                .map { Double($0.boundingBox.width * $0.boundingBox.height) }
                .max() ?? 0
        }

        if let animals = try? await handler.perform(RecognizeAnimalsRequest()) {
            findings.animals = Array(Set(animals.compactMap { $0.labels.first?.identifier.lowercased() }))
        }

        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        if let lines = try? await handler.perform(textRequest) {
            findings.recognizedText = lines.compactMap { $0.topCandidates(1).first?.string }
            findings.textArea = lines.reduce(0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        }

        if let aesthetics = try? await handler.perform(CalculateImageAestheticsScoresRequest()) {
            findings.aestheticScore = aesthetics.overallScore
            findings.isUtility = aesthetics.isUtility
        }

        return findings
    }
}
