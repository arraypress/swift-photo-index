//
//  IndexReport.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What one indexing run did.
public struct IndexReport: Sendable, Codable {
    public var added: Int = 0
    public var updated: Int = 0
    public var removed: Int = 0
    public var unchanged: Int = 0
    public var transcribed: Int = 0
    /// Assets given a semantic vector this run, new or backfilled.
    public var embedded: Int = 0
    /// Locator → message, for assets that failed without sinking the run.
    public var failures: [String: String] = [:]
    /// Wall seconds spent, whole run.
    public var seconds: Double = 0

    public init() {}

    /// Assets actually processed this run.
    public var processed: Int { added + updated }
}

/// What the index currently holds.
public struct IndexStatus: Sendable, Codable {
    public let assetCounts: [String: Int]        // kind → count
    public let sourceCounts: [String: Int]       // source → count
    public let labelled: Int
    public let withPrints: Int
    /// Assets carrying a semantic vector (any model).
    public let withEmbeddings: Int
    public let withTranscripts: Int
    public let faces: Int
    public let clusters: Int
    public let namedClusters: Int
    public let databaseBytes: Int64
    public let databasePath: String

    public init(
        assetCounts: [String: Int], sourceCounts: [String: Int], labelled: Int,
        withPrints: Int, withEmbeddings: Int = 0, withTranscripts: Int, faces: Int, clusters: Int,
        namedClusters: Int, databaseBytes: Int64, databasePath: String
    ) {
        self.assetCounts = assetCounts
        self.sourceCounts = sourceCounts
        self.labelled = labelled
        self.withPrints = withPrints
        self.withEmbeddings = withEmbeddings
        self.withTranscripts = withTranscripts
        self.faces = faces
        self.clusters = clusters
        self.namedClusters = namedClusters
        self.databaseBytes = databaseBytes
        self.databasePath = databasePath
    }
}
