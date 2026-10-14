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
    /// `v` scaled to unit length; a zero vector stays zero.
    static func unit(_ v: [Float]) -> [Float] {
        var squared: Float = 0
        vDSP_svesq(v, 1, &squared, vDSP_Length(v.count))
        let norm = squared.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// The dot product: the cosine similarity of two unit vectors.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// The mean of unit vectors, made unit again: one vector for a video's frames.
    static func meanUnit(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(sum.count)) }
        return unit(sum)
    }

    /// A blob of packed float16 — half the bytes of float32, plenty for cosine ranking.
    static func halfData(from floats: [Float]) -> Data {
        let halves = floats.map { Float16($0) }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Cosines of one unit query against many float16 blobs, without
    /// materialising a [Float] per row: each blob is widened into one reused
    /// buffer (vImage) and dotted (vDSP). A blob of the wrong length scores 0.
    static func dots(_ query: [Float], halves blobs: [Data]) -> [Float] {
        var buffer = [Float](repeating: 0, count: query.count)
        let width = vImagePixelCount(query.count)
        return blobs.map { blob in
            guard blob.count == query.count * MemoryLayout<Float16>.size, !query.isEmpty else { return 0 }
            var result: Float = 0
            blob.withUnsafeBytes { raw in
                buffer.withUnsafeMutableBytes { out in
                    var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress), height: 1,
                                               width: width, rowBytes: raw.count)
                    var destination = vImage_Buffer(data: out.baseAddress, height: 1, width: width, rowBytes: out.count)
                    vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
                }
            }
            vDSP_dotpr(query, 1, buffer, 1, &result, vDSP_Length(query.count))
            return result
        }
    }

    /// The floats packed as float16 in a blob.
    static func floats(fromHalf data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float16>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)).map(Float.init) }
    }
}
