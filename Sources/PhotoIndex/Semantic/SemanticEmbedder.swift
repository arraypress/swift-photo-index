//
//  SemanticEmbedder.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Pictures and sentences in one space, so "a red car at the beach at sunset"
//  lands near the photo of one. Google's SigLIP 2 base/16 at 224 (Apache-2.0)
//  runs on Core AI from one asset with two entry points, `image` and `text`;
//  the tokenizer, the pixel preparation and the normalisation are here.
//
//  Not Sendable: Core AI's loaded functions are used from one task at a time,
//  which is how the indexer and a search use them.
//

import CoreAI
import CoreGraphics
import Foundation

/// SigLIP 2 image and text embeddings, unit length, cosine-comparable.
public final class SemanticEmbedder {

    /// The Core AI asset's folder name.
    public static let assetName = "pix-siglip2-base-224.aimodel"
    /// The tokenizer files and config beside it.
    public static let supportFolder = "pix-siglip2-support"
    /// Recorded with every stored vector, so a different model re-embeds rather than mixes.
    public static let modelID = "siglip2-base-patch16-224@75de2d5"
    /// Where the export is published, for a host that fetches it on first use.
    public static let repository = "arraypress/pix-siglip2-base-224"
    /// The published commit: a download is this exact export or nothing.
    public static let revision = "3e8b112ccb593677ab41cf5f795cb778b78457d4"
    /// The licence the published export carries (Google's, unchanged).
    public static let licence = "Apache-2.0"
    public static let dimension = 768
    public static let imageSize = 224
    public static let textLength = 64

    /// Below this cosine a picture is not shown for a query on meaning alone.
    ///
    /// Measured through this asset on 1,000 COCO val2017 pictures against
    /// their 5,003 captions (5 million pairs): true pairs sit at 0.101 (5th
    /// percentile) and 0.150 (median); 99% of wrong pairs sit below 0.087 and
    /// 99.9% below 0.135. 0.09 keeps 97.5% of true pairs and drops 99.1% of
    /// wrong ones. It is a floor against junk, not a verdict: in a big
    /// library some wrong pictures always clear it, ranked below the right ones.
    public static let defaultMinimumSimilarity: Float = 0.09

    public let tokenizer: GemmaTokenizer
    private let image: InferenceFunction
    private let text: InferenceFunction

    /// Loads the asset and the tokenizer from `folder` (the asset beside its support folder).
    public init(folder: URL) async throws(PhotoIndexError) {
        let asset = folder.appendingPathComponent(Self.assetName)
        let support = folder.appendingPathComponent(Self.supportFolder)
        guard FileManager.default.fileExists(atPath: asset.path) else {
            throw PhotoIndexError.model("no \(Self.assetName) in \(folder.path)")
        }
        tokenizer = try GemmaTokenizer(folder: support)
        let model: AIModel
        do {
            model = try await AIModel(contentsOf: asset, options: SpecializationOptions(preferredComputeUnitKind: .gpu))
        } catch {
            throw PhotoIndexError.model("could not load \(Self.assetName): \(error)")
        }
        do {
            guard let image = try model.loadFunction(named: "image"),
                  let text = try model.loadFunction(named: "text") else {
                throw PhotoIndexError.model("\(Self.assetName) lacks the image/text entry points; found \(model.functionNames)")
            }
            self.image = image
            self.text = text
        } catch let error as PhotoIndexError {
            throw error
        } catch {
            throw PhotoIndexError.model("could not load the entry points: \(error)")
        }
    }

    /// Whether `folder` holds a complete model: the asset and the three support files.
    public static func isComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let support = folder.appendingPathComponent(supportFolder)
        return fm.fileExists(atPath: folder.appendingPathComponent(assetName).path)
            && ["vocab.bin", "merges.bin", "config.json"].allSatisfy {
                fm.fileExists(atPath: support.appendingPathComponent($0).path)
            }
    }

    /// The unit vector of a picture.
    public func embed(image picture: CGImage) async throws(PhotoIndexError) -> [Float] {
        guard let planes = PixelPlanes.normalised(picture, size: Self.imageSize) else {
            throw PhotoIndexError.extraction("cannot prepare the picture for the semantic model")
        }
        var input = NDArray(shape: [1, 3, Self.imageSize, Self.imageSize], scalarType: .float32)
        input.mutableView(as: Float.self).withUnsafeMutablePointer { pointer, _, _ in
            planes.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: planes.count) }
        }
        return try await run(image, inputs: ["pixel_values": input])
    }

    /// The unit vector of a sentence.
    public func embed(text sentence: String) async throws(PhotoIndexError) -> [Float] {
        let ids = tokenizer.encode(sentence, length: Self.textLength)
        return try await embed(ids: ids)
    }

    /// The unit vector for token ids already laid out at ``textLength``.
    public func embed(ids: [Int32]) async throws(PhotoIndexError) -> [Float] {
        var input = NDArray(shape: [1, Self.textLength], scalarType: .int32)
        input.mutableView(as: Int32.self).withUnsafeMutablePointer { pointer, _, _ in
            ids.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: ids.count) }
        }
        return try await run(text, inputs: ["ids": input])
    }

    private func run(_ function: InferenceFunction, inputs: [String: NDArray]) async throws(PhotoIndexError) -> [Float] {
        var output = NDArray(shape: [1, Self.dimension], scalarType: .float32)
        var views = InferenceFunction.MutableViews()
        views.insert(output.mutableRawView(), for: "embedding")
        do {
            _ = try await function.run(inputs: inputs, states: InferenceFunction.MutableViews(), outputViews: consume views)
        } catch {
            throw PhotoIndexError.model("inference failed: \(error)")
        }
        var floats = [Float](repeating: 0, count: Self.dimension)
        output.view(as: Float.self).withUnsafePointer { pointer, _, _ in
            floats.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: pointer, count: Self.dimension) }
        }
        return Vectors.unit(floats)
    }
}
