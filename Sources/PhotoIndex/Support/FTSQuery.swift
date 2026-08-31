//
//  FTSQuery.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Turning what somebody typed into an FTS5 MATCH expression — pure, and
//  tested to the character, because FTS5's query language treats quotes,
//  hyphens and columns specially and a crash on `search "who's-there?"` is
//  the classic bug in tools like this.
//

import Foundation

enum FTSQuery {

    /// The words of a query: lowercased runs of letters and digits, any
    /// script. Punctuation separates; it never survives into a token, which
    /// is what makes the MATCH expression safe to build.
    static func tokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The MATCH expression for a set of tokens: each quoted (FTS5 phrase
    /// syntax, immune to its operators), joined as an implicit AND. Nil when
    /// there is nothing to match.
    static func matchExpression(_ tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }
}

/// What a query means once people are taken into account.
struct QueryPlan: Equatable {

    /// Named clusters the query refers to; results must contain these people.
    let personClusters: [Int64]

    /// The tokens left for full-text matching once names are consumed.
    let ftsTokens: [String]

    /// Splits a query into person filters and text tokens.
    ///
    /// A cluster name matches as a consecutive run of query tokens, longest
    /// names first, so "jane smith beach" with a cluster named "Jane Smith"
    /// becomes that person plus the token `beach` — and a query that is ONLY
    /// names becomes a pure person filter.
    static func plan(query: String, namedClusters: [(id: Int64, name: String)]) -> QueryPlan {
        var tokens: [String?] = FTSQuery.tokens(query)
        var people: [Int64] = []

        let byLength = namedClusters
            .map { (id: $0.id, name: FTSQuery.tokens($0.name)) }
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.count > $1.name.count }

        for cluster in byLength {
            let n = cluster.name.count
            guard tokens.count >= n else { continue }
            var start = 0
            while start + n <= tokens.count {
                let window = tokens[start..<(start + n)]
                if window.compactMap({ $0 }).count == n,
                   Array(window.compactMap { $0 }) == cluster.name {
                    people.append(cluster.id)
                    for i in start..<(start + n) { tokens[i] = nil }
                    // One mention is a filter; a second adds nothing.
                    break
                }
                start += 1
            }
        }

        return QueryPlan(personClusters: people, ftsTokens: tokens.compactMap { $0 })
    }
}
