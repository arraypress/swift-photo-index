//
//  SearchEngine.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Questions against the index: text search (with people folded in),
//  similarity, and perceptual duplicates. The store answers SQL; the pure
//  functions in Support decide meaning; this file only wires them.
//

import CoreGraphics
import Foundation
import ImageIO

/// One similarity hit.
public struct SimilarResult: Sendable, Equatable, Codable {
    public let asset: IndexedAsset
    /// Euclidean distance between feature prints; smaller is more alike.
    public let distance: Float

    public init(asset: IndexedAsset, distance: Float) {
        self.asset = asset
        self.distance = distance
    }
}

/// Search over an index.
public struct SearchEngine {

    /// Feature-print distance at or below which two images count as the
    /// same shot. Measured on real photos: a flipped or edited export of a
    /// shot sits 0.14–0.45 from its original, different photos 1.1–1.2.
    /// 0.5 keeps every edit and no stranger — though two shots of the same
    /// subject in the same outfit measured 0.33, so a tight photo shoot can
    /// group; --threshold tightens it.
    public static let duplicateThreshold: Float = 0.5

    private let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    // MARK: - Text search

    /// Searches text, labels, places and named people in one query,
    /// optionally windowed by capture date — and by meaning, when the query's
    /// semantic vector is given (``SemanticEmbedder/embed(text:)``).
    ///
    /// - Parameters:
    ///   - queryVector: The query embedded by the semantic model. Nil keeps the
    ///     text-only ranking exactly as it was.
    ///   - minimumSimilarity: Pictures matching by meaning alone must reach this cosine.
    public func search(
        _ query: String, kind: MediaKind? = nil,
        from: Date? = nil, to: Date? = nil, limit: Int = 20,
        queryVector: [Float]? = nil,
        minimumSimilarity: Float = SemanticEmbedder.defaultMinimumSimilarity
    ) throws -> [SearchResult] {
        let named = try store.namedClusters()
        let plan = QueryPlan.plan(query: query, namedClusters: named)

        guard !plan.ftsTokens.isEmpty || !plan.personClusters.isEmpty else {
            throw PhotoIndexError.input("nothing to search for in: \(query)")
        }

        // A query that is only people: that person's assets, newest first.
        // Meaning has nothing to add to a name.
        guard let match = FTSQuery.matchExpression(plan.ftsTokens) else {
            return try store.assetsHavingClusters(plan.personClusters, kind: kind, limit: limit)
                .filter { Self.within($0.created, from: from, to: to) }
                .map { SearchResult(asset: $0, score: 1, matched: [.people]) }
        }

        struct Candidate {
            let asset: IndexedAsset
            var textScore: Double?
            var matched: [SearchResult.MatchedField] = []
            var snippet: String?
            /// Every query word was found literally (pixels, speech, place, name), not guessed.
            var literal = false
            var similarity: Float?
        }
        var candidates: [Int64: Candidate] = [:]
        let pool = max(64, limit * 4)

        func admissible(_ asset: IndexedAsset) throws -> Bool {
            if let kind, asset.kind != kind { return false }
            if !Self.within(asset.created, from: from, to: to) { return false }
            if !plan.personClusters.isEmpty {
                let present = try store.clusterIDs(forAssetID: asset.id)
                guard plan.personClusters.allSatisfy(present.contains) else { return false }
            }
            return true
        }

        for row in try store.ftsCandidates(match: match, limit: pool) {
            guard let asset = try store.asset(byID: row.assetID), try admissible(asset) else { continue }
            let labelConfidence = try store.matchedLabelConfidence(
                assetID: row.assetID, tokens: plan.ftsTokens)
            let score = Ranking.score(RankInput(
                bm25: row.bm25,
                matchedLabelConfidence: labelConfidence,
                personMatched: !plan.personClusters.isEmpty
            ))
            let matched = Provenance.fields(
                tokens: plan.ftsTokens, ocr: row.ocr, labels: row.labels,
                transcript: row.transcript, people: row.people, place: row.place)
            let snippet = Provenance.snippet(tokens: plan.ftsTokens, in: row.ocr)
                ?? Provenance.snippet(tokens: plan.ftsTokens, in: row.transcript)
            let literal = Provenance.coversLiterally(
                tokens: plan.ftsTokens,
                texts: [row.ocr, row.transcript, row.people, row.place, Provenance.fileName(of: asset)])
            candidates[row.assetID] = Candidate(asset: asset, textScore: score, matched: matched,
                                                snippet: snippet, literal: literal)
        }

        // The file's own name: every query word in it, as whole words —
        // "IMG_4021" answers "4021", a scan named "invoice 4021.pdf" answers both.
        let byName = try store.locatorCandidates(tokens: plan.ftsTokens)
            .filter { Provenance.fileNameHolds(tokens: plan.ftsTokens, locator: $0.locator) }
        for entry in byName.prefix(pool) {
            if candidates[entry.id] != nil {
                candidates[entry.id]?.matched.append(.filename)
                candidates[entry.id]?.textScore? += Ranking.fileNameScore
                candidates[entry.id]?.literal = true
                continue
            }
            guard let asset = try store.asset(byID: entry.id), try admissible(asset) else { continue }
            candidates[entry.id] = Candidate(asset: asset, textScore: Ranking.fileNameScore,
                                             matched: [.filename], literal: true)
        }

        guard let queryVector else {
            return candidates.values
                .map { SearchResult(asset: $0.asset, score: $0.textScore ?? 0, matched: $0.matched, snippet: $0.snippet) }
                .sorted { $0.score > $1.score }.prefix(limit).map { $0 }
        }

        // Meaning: every stored vector against the query; the best that clear
        // the bar (and the filters) join the text hits, which get theirs too.
        let scored = try store.similarities(to: queryVector, model: SemanticEmbedder.modelID)
            .map { (id: $0.assetID, similarity: $0.similarity) }
        var joined = 0
        for entry in scored.sorted(by: { $0.similarity > $1.similarity }) {
            if candidates[entry.id] != nil {
                candidates[entry.id]?.similarity = entry.similarity
                continue
            }
            guard entry.similarity >= minimumSimilarity, joined < pool,
                  let asset = try store.asset(byID: entry.id), try admissible(asset) else { continue }
            candidates[entry.id] = Candidate(asset: asset, similarity: entry.similarity)
            joined += 1
        }

        return candidates.values.map { candidate in
            var matched = candidate.matched
            if let similarity = candidate.similarity, similarity >= minimumSimilarity { matched.append(.meaning) }
            let score = Ranking.blended(textScore: candidate.textScore, literal: candidate.literal,
                                        similarity: candidate.similarity)
            return SearchResult(asset: candidate.asset, score: score, matched: matched,
                                snippet: candidate.snippet, similarity: candidate.similarity)
        }
        .sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Whether a capture date sits inside the asked window. A dateless
    /// asset only passes an unbounded one — "no date" must never satisfy
    /// "taken in August".
    private static func within(_ date: Date?, from: Date?, to: Date?) -> Bool {
        if from == nil && to == nil { return true }
        guard let date else { return false }
        if let from, date < from { return false }
        if let to, date > to { return false }
        return true
    }

    // MARK: - Similarity

    /// Assets most like the given one — an indexed locator, or any image
    /// file on disk.
    public func similar(to reference: String, limit: Int = 10) throws -> [SimilarResult] {
        let referencePrint: [Float]
        var excludeID: Int64?

        if let asset = try store.asset(byLocator: standardised(reference)),
           let stored = try store.print(forAssetID: asset.id) {
            referencePrint = stored
            excludeID = asset.id
        } else {
            let url = URL(fileURLWithPath: (reference as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PhotoIndexError.input("not in the index and not a file: \(reference)")
            }
            referencePrint = try Extractors.featurePrint(of: Self.decode(url))
        }

        return try store.allPrints()
            .filter { $0.assetID != excludeID }
            .map { (id: $0.assetID, distance: Vectors.euclidean(referencePrint, $0.floats)) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .compactMap { entry in
                try store.asset(byID: entry.id).map {
                    SimilarResult(asset: $0, distance: entry.distance)
                }
            }
    }

    /// Assets closest in meaning to the given one — an indexed locator, or any image file
    /// on disk (embedded with `embedder`).
    public func similarByMeaning(to reference: String, limit: Int = 10,
                                 embedder: SemanticEmbedder) async throws -> [SimilarResult] {
        let referenceVector: [Float]
        var excludeID: Int64?
        if let asset = try store.asset(byLocator: standardised(reference)),
           let stored = try store.embedding(forAssetID: asset.id, model: SemanticEmbedder.modelID) {
            referenceVector = stored
            excludeID = asset.id
        } else {
            let url = URL(fileURLWithPath: (reference as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PhotoIndexError.input("not in the index and not a file: \(reference)")
            }
            referenceVector = try await embedder.embed(image: Self.decode(url))
        }
        // Reported as a distance like the look-alike path: 1 − cosine.
        return try store.similarities(to: referenceVector, model: SemanticEmbedder.modelID)
            .filter { $0.assetID != excludeID }
            .map { (id: $0.assetID, distance: 1 - $0.similarity) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .compactMap { entry in
                try store.asset(byID: entry.id).map { SimilarResult(asset: $0, distance: entry.distance) }
            }
    }

    /// Groups of assets that look like the same shot.
    public func duplicateGroups(threshold: Float = SearchEngine.duplicateThreshold) throws -> [[IndexedAsset]] {
        let prints = try store.allPrints()
        var parent = Array(prints.indices)

        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }

        for i in prints.indices {
            for j in (i + 1)..<prints.count
            where Vectors.euclidean(prints[i].floats, prints[j].floats) <= threshold {
                parent[root(j)] = root(i)
            }
        }

        var groups: [Int: [Int64]] = [:]
        for i in prints.indices {
            groups[root(i), default: []].append(prints[i].assetID)
        }

        return try groups.values
            .filter { $0.count > 1 }
            .map { ids in try ids.compactMap { try store.asset(byID: $0) } }
            .sorted { ($0.first?.locator ?? "") < ($1.first?.locator ?? "") }
    }

    // MARK: - Details

    private func standardised(_ reference: String) -> String {
        guard reference.contains("/") else { return reference }
        return URL(fileURLWithPath: (reference as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }

    /// Decodes an image the same way ``FolderSource`` does, so a file
    /// compared from disk sees the pixels its indexed copy saw.
    private static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: FolderSource.maxPixelSize,
              ] as CFDictionary)
        else {
            throw PhotoIndexError.input("cannot decode image: \(url.path)")
        }
        return image
    }
}
