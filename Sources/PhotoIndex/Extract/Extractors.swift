//
//  Extractors.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The Vision passes, each a function from a bitmap to plain values. They
//  know nothing about sources or the store; the indexer decides when to run
//  them and what to do with the answers.
//

import CoreGraphics
import Foundation
import Vision

enum Extractors {

    /// Labels below this confidence are noise, measured on the corpus; the
    /// top slice above it is plenty for search.
    static let labelFloor: Double = 0.25
    static let labelLimit = 12

    /// Recognised text, in reading order.
    static func ocr(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Scene and object labels above the floor, best first.
    static func labels(in image: CGImage) throws -> [Label] {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .filter { Double($0.confidence) >= labelFloor }
            .sorted { $0.confidence > $1.confidence }
            .prefix(labelLimit)
            .map { Label(name: $0.identifier, confidence: Double($0.confidence)) }
    }

    /// The whole-image feature print, as raw floats.
    static func featurePrint(of image: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else {
            throw PhotoIndexError.extraction("no feature print produced")
        }
        return Vectors.floats(from: observation.data)
    }

    /// Detected faces with crop embeddings.
    ///
    /// Identity here is a feature print of the face crop — a stand-in, not a
    /// real face embedding, because Apple ships no public recognition API.
    /// The crop takes a margin around the detector's tight box: hair and jaw
    /// carry most of what makes the print distinctive.
    static func faces(in image: CGImage) throws -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        var faces: [DetectedFace] = []
        for observation in request.results ?? [] {
            let box = observation.boundingBox
            guard let crop = faceCrop(from: image, boundingBox: box) else { continue }
            let embedding = try featurePrint(of: crop)
            // Vision's origin is bottom-left; the fleet reports top-left.
            faces.append(DetectedFace(
                x: box.origin.x,
                y: 1 - box.origin.y - box.height,
                width: box.width,
                height: box.height,
                embedding: embedding
            ))
        }
        return faces
    }

    /// The face's pixels with a 30% margin, clamped to the image.
    static func faceCrop(from image: CGImage, boundingBox box: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let w = box.width * width
        let h = box.height * height
        let margin = 0.3 * max(w, h)
        let rect = CGRect(
            x: box.origin.x * width - margin,
            y: (1 - box.origin.y - box.height) * height - margin,
            width: w + 2 * margin,
            height: h + 2 * margin
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty else { return nil }
        return image.cropping(to: rect.integral)
    }
}
