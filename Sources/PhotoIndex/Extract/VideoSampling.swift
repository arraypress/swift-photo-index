//
//  VideoSampling.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  A video, reduced to the frames worth looking at. Sampling evenly beats
//  chasing scene changes for indexing: the question is "what is in this
//  video", not "where are the cuts", and five looks across the timeline
//  answer it for a fraction of a decode.
//

import AVFoundation
import CoreGraphics
import Foundation

enum VideoSampling {

    /// How many frames extraction looks at, spread across the duration.
    static let frameCount = 5

    /// The sampled frames, with the duration they came from.
    static func frames(from url: URL) async throws -> (duration: Double, frames: [(time: Double, image: CGImage)]) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw PhotoIndexError.extraction("video has no duration: \(url.lastPathComponent)")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: FolderSource.maxPixelSize, height: FolderSource.maxPixelSize)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // Evenly spaced, at least a second apart: a two-second clip gets two
        // frames, not five copies of the same one.
        let count = max(1, min(frameCount, Int(duration) + 1))
        var frames: [(Double, CGImage)] = []
        for slot in 0..<count {
            let fraction = count == 1 ? 0.5 : Double(slot) / Double(count - 1)
            let seconds = min(duration * fraction, max(0, duration - 0.1))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                frames.append((result.actualTime.seconds, result.image))
            }
        }
        guard !frames.isEmpty else {
            throw PhotoIndexError.extraction("no frames could be decoded: \(url.lastPathComponent)")
        }
        return (duration, frames)
    }
}
