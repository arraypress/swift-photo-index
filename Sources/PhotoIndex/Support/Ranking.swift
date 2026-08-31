//
//  Ranking.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  How a hit's number is made, alone and testable. The inputs are plain
//  values so a test can pin the ordering without a database in sight.
//

import Foundation

/// The evidence one candidate brings to ranking.
struct RankInput: Equatable {
    /// FTS5's bm25() — more negative is better; 0 when no text matched.
    let bm25: Double
    /// The best confidence among labels the query matched, if any.
    let matchedLabelConfidence: Double?
    /// Whether a named person filter matched this asset.
    let personMatched: Bool
}

enum Ranking {

    /// Merged relevance, higher is better.
    ///
    /// Text relevance leads (bm25, negated into a positive), a matched label
    /// adds a fraction of its confidence — a strong "dog" should not outrank
    /// the word actually written in a screenshot — and a person filter adds a
    /// flat bonus for having survived it.
    static func score(_ input: RankInput) -> Double {
        var score = max(0, -input.bm25)
        if let confidence = input.matchedLabelConfidence {
            score += 0.4 * confidence
        }
        if input.personMatched {
            score += 0.5
        }
        return score
    }
}

/// Which fields matched, worked out from the stored text itself.
enum Provenance {

    /// The fields containing every-token evidence of the query.
    ///
    /// A field counts when it contains at least one query token — the FTS
    /// match already guaranteed the conjunction across fields; this reports
    /// where the words actually sit.
    static func fields(
        tokens: [String], ocr: String, labels: String, transcript: String, people: String,
        place: String
    ) -> [SearchResult.MatchedField] {
        guard !tokens.isEmpty else { return [] }
        var matched: [SearchResult.MatchedField] = []
        let haystacks: [(SearchResult.MatchedField, String)] = [
            (.ocr, ocr), (.labels, labels), (.transcript, transcript), (.people, people),
            (.place, place),
        ]
        for (field, text) in haystacks {
            let lowered = text.lowercased()
            if tokens.contains(where: { lowered.contains($0) }) {
                matched.append(field)
            }
        }
        return matched
    }

    /// A short excerpt around the first token hit in `text`, ellipsised at
    /// cut edges. Nil when no token appears.
    static func snippet(tokens: [String], in text: String, radius: Int = 40) -> String? {
        let lowered = text.lowercased()
        for token in tokens {
            guard let range = lowered.range(of: token) else { continue }
            let start = text.index(range.lowerBound, offsetBy: -radius,
                                   limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: radius,
                                 limitedBy: text.endIndex) ?? text.endIndex
            var excerpt = String(text[start..<end])
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if start > text.startIndex { excerpt = "…" + excerpt }
            if end < text.endIndex { excerpt += "…" }
            return excerpt
        }
        return nil
    }
}
