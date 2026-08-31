//
//  ExtractedContent.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  What the extractors produce for one asset — the shape only. The Vision
//  work that fills one of these lives in Extract/.
//

import Foundation

/// One scene or object label with its confidence.
public struct Label: Sendable, Equatable, Codable {
    public let name: String
    public let confidence: Double

    public init(name: String, confidence: Double) {
        self.name = name
        self.confidence = confidence
    }
}

/// One detected face: where it sits and what it looks like.
///
/// The rect is normalised to the image with a TOP-LEFT origin — the fleet's
/// convention. The embedding is a feature print of the face crop, which is a
/// poor man's face signature, not Photos-grade recognition; ``Clustering``
/// says what it is good for.
public struct DetectedFace: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let embedding: [Float]

    public init(x: Double, y: Double, width: Double, height: Double, embedding: [Float]) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.embedding = embedding
    }
}

/// Everything extraction found in one asset.
public struct ExtractedContent: Sendable {
    /// Recognised text, newline-joined in reading order.
    public var ocr: String
    /// Scene and object labels above the confidence floor.
    public var labels: [Label]
    /// The whole-image feature print, for similarity and perceptual dupes.
    public var featurePrint: [Float]?
    /// Detected faces with their crop embeddings.
    public var faces: [DetectedFace]
    /// The spoken words, when the audio pass ran.
    public var transcript: String?

    public init(
        ocr: String = "", labels: [Label] = [], featurePrint: [Float]? = nil,
        faces: [DetectedFace] = [], transcript: String? = nil
    ) {
        self.ocr = ocr
        self.labels = labels
        self.featurePrint = featurePrint
        self.faces = faces
        self.transcript = transcript
    }
}
