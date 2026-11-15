//
//  TagMerges.swift
//  photos analyze
//

import Foundation

/// Remembered tag renames, merges (e.g. "Jet planes" → "Planes") and deletions (target
/// ""). Applied to existing photos when made, and to every later analysis result so
/// renamed, merged or deleted tags don't come back.
nonisolated enum TagMerges {
    /// UserDefaults key; the value is JSON-encoded `[source (lowercased): target]`.
    static let defaultsKey = "tagMerges"

    static var all: [String: String] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let merges = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return merges
    }

    /// Records a merge and redirects earlier merges that pointed at `source`.
    static func add(from source: String, to target: String) {
        var merges = all
        let sourceKey = source.lowercased()
        for (key, value) in merges where value.caseInsensitiveCompare(source) == .orderedSame {
            merges[key] = target
        }
        merges[sourceKey] = target
        // A tag can't be merged into itself (e.g. after merging A → B, then B → A).
        merges = merges.filter { $0.key != $0.value.lowercased() }
        save(merges)
    }

    static func remove(source: String) {
        var merges = all
        merges.removeValue(forKey: source.lowercased())
        save(merges)
    }

    private static func save(_ merges: [String: String]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(merges), forKey: defaultsKey)
    }

    /// Replaces merged tags with their targets, drops deleted tags (empty target) and
    /// case-insensitive duplicates.
    static func apply(_ merges: [String: String], to tags: [String]) -> [String] {
        guard !merges.isEmpty else { return tags }
        var result: [String] = []
        for tag in tags {
            let mapped = merges[tag.lowercased()] ?? tag
            if !mapped.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(mapped) == .orderedSame }) {
                result.append(mapped)
            }
        }
        return result
    }
}

/// Finds tags that are almost certainly the same thing written differently.
nonisolated enum SimilarTags {
    /// A merge proposal: `sources` should become `target`.
    struct Group: Identifiable, Hashable {
        let target: String
        let sources: [String]
        var id: String { target }
    }

    /// Groups tags that differ only in case, plural/singular, hyphens, spaces or
    /// punctuation ("Jet plane", "jet planes", "Jet-planes"). Each group merges into its
    /// most used spelling. `counts` maps tag → number of photos.
    static func groups(in counts: [String: Int]) -> [Group] {
        var byKey: [String: [String]] = [:]
        for tag in counts.keys {
            let key = normalized(tag)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(tag)
        }
        return byKey.values
            .filter { $0.count > 1 }
            .map { tags in
                let sorted = tags.sorted {
                    let (a, b) = (counts[$0] ?? 0, counts[$1] ?? 0)
                    return a != b ? a > b : $0 < $1
                }
                return Group(target: sorted[0], sources: Array(sorted.dropFirst()))
            }
            .sorted { $0.target.localizedStandardCompare($1.target) == .orderedAscending }
    }

    /// Lowercased words with simple plurals removed, joined without separators.
    static func normalized(_ tag: String) -> String {
        tag.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { singular(String($0)) }
            .joined()
    }

    private static func singular(_ word: String) -> String {
        guard word.count > 3, word.last == "s", !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") else {
            return word
        }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }        // berries → berry
        for suffix in ["ches", "shes", "xes", "zes"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))                                       // boxes → box
        }
        // Words like "glasses" are left alone: "glasses" and "glass" are different things.
        if word.hasSuffix("sses") { return word }
        return String(word.dropLast())                                            // planes → plane
    }
}
