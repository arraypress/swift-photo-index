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

extension Ranking {

    /// Relevance when the query was also embedded.
    ///
    /// Words found literally — on the pixels, spoken, a named person, a
    /// place, the file's name — rank above every match by meaning (+1;
    /// cosines here stay well under 0.5), so "ERROR 517" still puts the
    /// screenshot that says it first. Inside each tier the semantic
    /// similarity orders, and the text score breaks near-ties: squashed to
    /// under 0.02 so a guessed label cannot outvote what the picture looks like.
    static func blended(textScore: Double?, literal: Bool, similarity: Float?) -> Double {
        var score = Double(similarity ?? 0)
        if let textScore { score += 0.02 * textScore / (textScore + 1) }
        if literal { score += 1 }
        return score
    }

    /// The text score of a file whose name holds every query word: about a
    /// solid bm25 hit, so on the text-only path it ranks with the OCR hits.
    static let fileNameScore = 2.0
}

/// Which fields matched, worked out from the stored text itself.
enum Provenance {

    /// The fields holding a query token as a whole word.
    ///
    /// A field counts when it contains at least one query token — the FTS
    /// match already guaranteed the conjunction across fields; this reports
    /// where the words actually sit. Whole words, as FTS5 itself matches:
    /// "cat" inside "education" is not evidence of a cat, and once meaning
    /// joins the ranking a false "ocr" would lift the wrong picture to the top.
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
            let words = Set(FTSQuery.tokens(text))
            if tokens.contains(where: words.contains) {
                matched.append(field)
            }
        }
        return matched
    }

    /// Whether every query token sits, as a whole word, in at least one of
    /// the literal texts — OCR, speech, people, place, file name. A query
    /// whose "dog" only came from a guessed label is not literal, even when
    /// its "on" and "a" were read off a sign in the background.
    static func coversLiterally(tokens: [String], texts: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let words = Set(texts.flatMap(FTSQuery.tokens))
        return tokens.allSatisfy(words.contains)
    }

    /// A folder asset's file name without its extension; empty for a Photos asset.
    static func fileName(of asset: IndexedAsset) -> String {
        asset.source == .folder ? fileName(ofLocator: asset.locator) : ""
    }

    static func fileName(ofLocator locator: String) -> String {
        ((locator as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Whether a file's name holds every query token as a whole word.
    static func fileNameHolds(tokens: [String], locator: String) -> Bool {
        coversLiterally(tokens: tokens, texts: [fileName(ofLocator: locator)])
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
