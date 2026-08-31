//
//  Vectors.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Float vectors in and out of blobs, and the two distances everything else
//  leans on. Accelerate does the arithmetic; this file's job is that nobody
//  else touches raw bytes.
//

import Accelerate
import Foundation

enum Vectors {

    /// The floats packed in a blob, little-endian float32 as Vision hands
    /// them over.
    static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// A blob of packed float32.
    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Euclidean (L2) distance.
    static func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var distanceSquared: Float = 0
        vDSP_distancesq(a, 1, b, 1, &distanceSquared, vDSP_Length(a.count))
        return distanceSquared.squareRoot()
    }

    /// Cosine distance: 0 for identical directions, 2 for opposite.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var aa: Float = 0
        var bb: Float = 0
        vDSP_svesq(a, 1, &aa, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &bb, vDSP_Length(b.count))
        let magnitude = (aa * bb).squareRoot()
        guard magnitude > 0 else { return .greatestFiniteMagnitude }
        return 1 - dot / magnitude
    }
}
