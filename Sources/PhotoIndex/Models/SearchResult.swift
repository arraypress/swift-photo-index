//
//  SearchResult.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One search hit: the asset, how strongly it matched, and where the match
/// came from — an agent acting on a result needs to know whether the word was
/// on screen, spoken, or a guess about the scene.
public struct SearchResult: Sendable, Equatable, Codable {

    /// Which indexed field a query matched in.
    public enum MatchedField: String, Sendable, Codable, CaseIterable {
        case ocr
        case labels
        case transcript
        case people
        case place
    }

    public let asset: IndexedAsset

    /// Merged relevance, higher is better. Comparable within one query only.
    public let score: Double

    /// The fields the query matched in, in the order of ``MatchedField``.
    public let matched: [MatchedField]

    /// A short excerpt of the matched text, where there is one.
    public let snippet: String?

    public init(asset: IndexedAsset, score: Double, matched: [MatchedField], snippet: String? = nil) {
        self.asset = asset
        self.score = score
        self.matched = matched
        self.snippet = snippet
    }
}
