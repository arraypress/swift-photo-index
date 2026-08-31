//
//  Clustering.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Greedy threshold clustering over face embeddings — the whole identity
//  feature, alone and testable on synthetic vectors. Deliberately simple:
//  faces arrive incrementally as indexing runs, cluster ids must stay stable
//  (names hang off them), and a person's cluster should absorb a new face
//  without re-clustering the world. Greedy nearest-centroid does exactly
//  that, and its failure mode — splitting one person into two clusters —
//  is visible and nameable rather than silently wrong.
//

import Foundation

/// One cluster as the assigner sees it: id, running centroid, member count.
struct ClusterSeed {
    let id: Int64
    var centroid: [Float]
    var count: Int
}

enum Clustering {

    /// The join distance for face-crop feature prints. Measured on real
    /// portraits: the same person ranges 0.19–0.59 (flipped copies, and the
    /// same model across two different shoots at 0.188); different people
    /// never came closer than 1.1. 0.8 sits in the gap, erring toward
    /// splitting a person rather than merging two.
    static let defaultThreshold: Float = 0.8

    /// The index of the nearest cluster within `threshold`, or nil when the
    /// embedding belongs in a cluster of its own.
    static func nearestIndex(
        _ embedding: [Float], in clusters: [ClusterSeed], threshold: Float
    ) -> Int? {
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, cluster) in clusters.enumerated()
        where cluster.centroid.count == embedding.count {
            let distance = Vectors.euclidean(embedding, cluster.centroid)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let index = bestIndex, bestDistance <= threshold else { return nil }
        return index
    }

    /// Folds an embedding into a cluster's running mean.
    static func absorb(_ embedding: [Float], into cluster: inout ClusterSeed) {
        let n = Float(cluster.count)
        guard cluster.centroid.count == embedding.count, n > 0 else {
            cluster.centroid = embedding
            cluster.count = 1
            return
        }
        for i in cluster.centroid.indices {
            cluster.centroid[i] = (cluster.centroid[i] * n + embedding[i]) / (n + 1)
        }
        cluster.count += 1
    }
}
