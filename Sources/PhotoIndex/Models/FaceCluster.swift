//
//  FaceCluster.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One group of faces the index believes are the same person.
///
/// EXPERIMENTAL by design: the grouping clusters feature prints of face crops,
/// which is a stand-in for a real face embedding — Apple ships no public
/// face-recognition API. It groups the obvious cases and will split a person
/// across haircuts and decades; naming a cluster names those sightings, not
/// the person everywhere.
public struct FaceCluster: Sendable, Equatable, Codable {

    /// The index's stable cluster id.
    public let id: Int64

    /// The name a user gave it, if any.
    public let name: String?

    /// How many faces sit in it.
    public let faceCount: Int

    /// How many assets those faces appear in.
    public let assetCount: Int

    /// One asset the cluster appears in, for a human to check who it is.
    public let sampleLocator: String?

    public init(id: Int64, name: String?, faceCount: Int, assetCount: Int, sampleLocator: String?) {
        self.id = id
        self.name = name
        self.faceCount = faceCount
        self.assetCount = assetCount
        self.sampleLocator = sampleLocator
    }
}
