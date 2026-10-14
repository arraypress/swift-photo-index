//
//  SemanticTests.swift
//  PhotoIndexTests
//
//  Created by David Sherlock on 2026.
//
//  Meaning search, in two halves. The rules — ranking tiers, the cut-off,
//  the BPE merge loop, the float16 store, the schema step — run anywhere.
//  The parity checks need the Core AI export (725 MB) and skip cleanly
//  without it: they hold the Swift tokenizer, the pixel preparation and the
//  asset to the numbers transformers produced (Tools/export_siglip2.py).
//  They look for it at $PIX_MODEL, then Tools/exports (a fresh export),
//  then the installed copy in ~/Library/Application Support/pix.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhotoIndex

// MARK: - Fixtures

private func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/siglip"))
}

private func floats(_ name: String) throws -> [Float] {
    try Data(contentsOf: fixtureURL(name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private let modelFolder: URL? = {
    var candidates: [URL] = []
    if let explicit = ProcessInfo.processInfo.environment["PIX_MODEL"], !explicit.isEmpty {
        candidates.append(URL(fileURLWithPath: explicit))
    }
    candidates.append(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/exports"))
    candidates.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/pix"))
    return candidates.first(where: SemanticEmbedder.isComplete)
}()

private var modelInstalled: Bool { modelFolder != nil }

private struct TextFixture: Decodable {
    let texts: [String]
    let ids: [[Int32]]
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pix-semantic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func record(_ locator: String, kind: MediaKind = .image) -> IndexStore.AssetRecord {
    IndexStore.AssetRecord(
        source: .folder, locator: locator, fingerprint: "1:1", kind: kind,
        created: nil, modified: nil, byteSize: nil, width: nil, height: nil,
        latitude: nil, longitude: nil, duration: nil, camera: nil, lens: nil, orientation: nil,
        faceCount: 0, hasTranscript: false)
}

/// A unit vector pointing mostly along `axis`, with `cosine` to it.
private func vector(axis: Int, cosine: Float, dimension: Int = 8) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[axis] = cosine
    v[(axis + 1) % dimension] = (1 - cosine * cosine).squareRoot()
    return v
}

// MARK: - Rules

@Suite struct SemanticRuleTests {

    @Test("literal words beat any meaning; meaning orders inside a tier")
    func blendedTiers() {
        let literalWeak = Ranking.blended(textScore: 0.5, literal: true, similarity: 0.01)
        let meaningStrong = Ranking.blended(textScore: nil, literal: false, similarity: 0.45)
        let labelHit = Ranking.blended(textScore: 8, literal: false, similarity: 0.12)
        let meaningOnly = Ranking.blended(textScore: nil, literal: false, similarity: 0.15)
        #expect(literalWeak > meaningStrong)
        #expect(meaningOnly > labelHit, "a guessed label cannot outvote what the picture looks like")
        #expect(Ranking.blended(textScore: 8, literal: false, similarity: 0.12)
                > Ranking.blended(textScore: nil, literal: false, similarity: 0.12), "text breaks a tie")
    }

    @Test("literal means every word was read, not guessed")
    func literalCoverage() {
        #expect(Provenance.coversLiterally(tokens: ["invoice", "4021"], texts: ["INVOICE No. 4021", "", "", "", ""]))
        #expect(!Provenance.coversLiterally(tokens: ["dog", "on", "a", "beach"], texts: ["keep off a sign on", "", "", "", ""]),
                "dog and beach came from labels")
        #expect(Provenance.coversLiterally(tokens: ["4021"], texts: ["", "IMG_4021"]))
        #expect(!Provenance.coversLiterally(tokens: ["cat"], texts: ["education"]), "whole words only")
        #expect(!Provenance.coversLiterally(tokens: [], texts: ["anything"]))
    }

    @Test("file names match whole words, without the extension or folders")
    func fileNames() {
        #expect(Provenance.fileNameHolds(tokens: ["4021"], locator: "/scans/IMG_4021.jpg"))
        #expect(Provenance.fileNameHolds(tokens: ["invoice", "4021"], locator: "/a/Invoice 4021.png"))
        #expect(!Provenance.fileNameHolds(tokens: ["scans"], locator: "/scans/IMG_4021.jpg"), "a folder is not the name")
        #expect(!Provenance.fileNameHolds(tokens: ["jpg"], locator: "/scans/IMG_4021.jpg"), "nor is the extension")
        #expect(!Provenance.fileNameHolds(tokens: ["402"], locator: "/scans/IMG_4021.jpg"))
    }

    @Test("float16 storage keeps cosine ranking; means are unit length")
    func vectors() {
        let v = Vectors.unit([0.1, -0.7, 0.3, 0.25, 0.0, 0.6])
        let back = Vectors.floats(fromHalf: Vectors.halfData(from: v))
        #expect(back.count == v.count)
        #expect(abs(Vectors.dot(v, back) - 1) < 1e-3)
        #expect(Vectors.floats(fromHalf: Data([1, 2, 3])).isEmpty, "an odd blob is not a vector")
        let mean = Vectors.meanUnit([[1, 0], [0, 1]])
        #expect(mean.map { abs(Vectors.dot($0, $0) - 1) < 1e-6 } == true)
        #expect(Vectors.meanUnit([]) == nil)
        #expect(Vectors.dot([1, 2], [1]) == 0, "mismatched lengths never rank")
        let other = Vectors.unit([0.5, 0.1, -0.2, 0.9, 0.3, -0.4])
        let dots = Vectors.dots(v, halves: [Vectors.halfData(from: v), Vectors.halfData(from: other), Data([0, 1])])
        #expect(abs(dots[0] - 1) < 1e-3 && abs(dots[1] - Vectors.dot(v, other)) < 1e-3 && dots[2] == 0,
                "scoring straight off float16 blobs agrees with the float path")
    }

    @Test("the BPE loop merges the lowest rank first, leftmost on a tie")
    func mergeOrder() {
        // ids: a=10 b=11 c=12 ab=20 bc=21 abc=30
        func key(_ l: Int32, _ r: Int32) -> UInt64 { UInt64(UInt32(bitPattern: l)) << 32 | UInt64(UInt32(bitPattern: r)) }
        let merges: [UInt64: (rank: Int32, merged: Int32)] = [
            key(11, 12): (0, 21), key(10, 11): (1, 20), key(10, 21): (2, 30),
        ]
        #expect(GemmaTokenizer.merge([10, 11, 12], merges) == [30], "bc first (rank 0), then a+bc")
        #expect(GemmaTokenizer.merge([10, 11, 10, 11], merges) == [20, 20])
        #expect(GemmaTokenizer.merge([12, 10], merges) == [12, 10], "no rule, no change")
        #expect(GemmaTokenizer.merge([], merges) == [])
    }

    @Test("a tiny tokenizer: byte fallback, eos, padding, truncation")
    func tinyTokenizer() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var tokens = ["<pad>", "<eos>", "<bos>", "<unk>", "a", "b", "\u{2581}", "ab", "\u{2581}a"]
        tokens += (0..<256).map { String(format: "<0x%02X>", $0) }
        var vocab = Data()
        func u32(_ v: Int, into data: inout Data) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        u32(tokens.count, into: &vocab)
        for token in tokens {
            let bytes = Data(token.utf8)
            u32(bytes.count, into: &vocab)
            vocab.append(bytes)
        }
        var merges = Data()
        u32(2, into: &merges)
        for triple in [(4, 5, 7), (6, 4, 8)] { u32(triple.0, into: &merges); u32(triple.1, into: &merges); u32(triple.2, into: &merges) }
        try vocab.write(to: folder.appendingPathComponent("vocab.bin"))
        try merges.write(to: folder.appendingPathComponent("merges.bin"))

        let tokenizer = try GemmaTokenizer(folder: folder)
        #expect(tokenizer.tokenize("AB a") == [7, 8], "lower-cased, ab merged, ▁a merged")
        let z = 9 + Int32(UInt8(ascii: "z"))
        #expect(tokenizer.tokenize("z") == [z], "an unknown character falls back to its bytes")
        #expect(tokenizer.encode("ab", length: 4) == [7, 1, 0, 0])
        #expect(tokenizer.encode("ab ab ab ab", length: 3) == [7, 6, 1], "truncated, eos kept last")
        #expect(throws: PhotoIndexError.self) { try GemmaTokenizer(folder: folder.appendingPathComponent("nope")) }
    }

    @Test("an old index steps to schema 2 and keeps its assets")
    func schemaStep() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        let id = try store.upsertAsset(record("/p/old.jpg"))
        try store.replaceContent(assetID: id, ocr: "kept", labelsText: "", transcript: nil, people: "")
        // Make it look like a 1.1.0 index: no embeddings table, version 1.
        let raw = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try raw.exec("DROP TABLE embeddings")
        try raw.run("UPDATE meta SET value='1' WHERE key='schema_version'")

        let upgraded = try IndexStore(directory: directory)
        #expect(try upgraded.asset(byLocator: "/p/old.jpg") != nil)
        #expect(try upgraded.embeddingCount(model: SemanticEmbedder.modelID) == 0)
        #expect(try upgraded.assetsNeedingEmbedding(source: .folder, model: SemanticEmbedder.modelID).map(\.locator) == ["/p/old.jpg"])
        try upgraded.upsertEmbedding(assetID: id, model: SemanticEmbedder.modelID, [1, 0])
        #expect(try upgraded.assetsNeedingEmbedding(source: .folder, model: SemanticEmbedder.modelID).isEmpty)
        #expect(try upgraded.assetsNeedingEmbedding(source: .folder, model: "another@1").count == 1,
                "a different model re-embeds rather than mixing spaces")
    }

    @Test("search: the cut-off, exact words first, file names, and the text-only path")
    func searchBlend() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        let model = SemanticEmbedder.modelID
        func add(_ locator: String, ocr: String = "", labels: String = "", vector: [Float]?) throws {
            let id = try store.upsertAsset(record(locator))
            try store.replaceContent(assetID: id, ocr: ocr, labelsText: labels, transcript: nil, people: "")
            if let vector { try store.upsertEmbedding(assetID: id, model: model, vector) }
        }
        try add("/p/IMG_0001.jpg", vector: vector(axis: 0, cosine: 0.30))
        try add("/p/IMG_0002.jpg", vector: vector(axis: 0, cosine: 0.12))
        try add("/p/IMG_0003.jpg", vector: vector(axis: 0, cosine: 0.05))
        try add("/p/Screenshot 1.png", ocr: "ERROR 517 dog", vector: vector(axis: 0, cosine: 0.02))
        try add("/p/IMG_0004.jpg", labels: "dog", vector: vector(axis: 0, cosine: 0.10))
        try add("/scans/IMG_517.jpg", vector: nil)
        let engine = SearchEngine(store: store)
        let query = vector(axis: 0, cosine: 1)

        let dog = try engine.search("dog", queryVector: query)
        #expect(dog.map(\.asset.locator) == ["/p/Screenshot 1.png", "/p/IMG_0001.jpg", "/p/IMG_0002.jpg", "/p/IMG_0004.jpg"],
                "read words first, then by meaning; 0.05 is under the 0.09 floor")
        #expect(dog.first?.matched == [.ocr])
        #expect(dog[1].matched == [.meaning] && abs((dog[1].similarity ?? 0) - 0.30) < 1e-3)
        #expect(dog.last?.matched == [.labels, .meaning])

        let strict = try engine.search("dog", queryVector: query, minimumSimilarity: 0.2)
        #expect(!strict.map(\.asset.locator).contains("/p/IMG_0002.jpg"))

        let error = try engine.search("517", queryVector: query)
        #expect(Set(error.prefix(2).map(\.asset.locator)) == ["/p/Screenshot 1.png", "/scans/IMG_517.jpg"],
                "an exact number wins over every picture by meaning")
        #expect(error.first { $0.asset.locator == "/scans/IMG_517.jpg" }?.matched == [.filename])

        let textOnly = try engine.search("dog")
        #expect(Set(textOnly.map(\.asset.locator)) == ["/p/Screenshot 1.png", "/p/IMG_0004.jpg"],
                "no query vector, no meaning: the old behaviour")
        #expect(textOnly.allSatisfy { $0.similarity == nil })
    }

    @Test("indexing one folder never forgets another")
    func coverage() {
        let source = FolderSource(paths: ["/Volumes/Shoot/day1", "/tmp/x/"])
        #expect(source.covers("/Volumes/Shoot/day1/a.jpg"))
        #expect(source.covers("/Volumes/Shoot/day1"))
        #expect(!source.covers("/Volumes/Shoot/day10/a.jpg"), "a sibling with the same prefix is not inside")
        #expect(!source.covers("/Users/me/Desktop/a.jpg"))
    }
}

// MARK: - Parity with transformers (needs the model)

@Suite(.serialized) struct SemanticParityTests {

    @Test("the Swift tokenizer reproduces Gemma's ids", .enabled(if: modelInstalled))
    func tokenizerIDs() throws {
        let folder = try #require(modelFolder)
        let tokenizer = try GemmaTokenizer(folder: folder.appendingPathComponent(SemanticEmbedder.supportFolder))
        let fixture = try JSONDecoder().decode(TextFixture.self, from: Data(contentsOf: fixtureURL("text_fixture.json")))
        for (text, ids) in zip(fixture.texts, fixture.ids) {
            #expect(tokenizer.encode(text, length: SemanticEmbedder.textLength) == ids, "\(text)")
        }
    }

    @Test("text embeddings match get_text_features", .enabled(if: modelInstalled))
    func textEmbeddings() async throws {
        let embedder = try await SemanticEmbedder(folder: #require(modelFolder))
        let fixture = try JSONDecoder().decode(TextFixture.self, from: Data(contentsOf: fixtureURL("text_fixture.json")))
        let reference = try floats("text_embeddings.f32")
        var worst: Float = 1
        for (i, text) in fixture.texts.enumerated() {
            let got = try await embedder.embed(text: text)
            let want = Array(reference[(i * SemanticEmbedder.dimension)..<((i + 1) * SemanticEmbedder.dimension)])
            let cosine = Vectors.dot(got, want)
            worst = min(worst, cosine)
            #expect(cosine > 0.999, "\(text): cosine \(cosine)")
        }
        print("siglip text parity: worst cosine \(worst) over \(fixture.texts.count) texts")
    }

    @Test("image embeddings match get_image_features, resize included", .enabled(if: modelInstalled),
          arguments: [("gradient-224.png", 0), ("checker-400x300.png", 1)])
    func imageEmbeddings(name: String, row: Int) async throws {
        let embedder = try await SemanticEmbedder(folder: #require(modelFolder))
        let url = try fixtureURL(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let reference = try floats("image_embeddings.f32")
        let want = Array(reference[(row * SemanticEmbedder.dimension)..<((row + 1) * SemanticEmbedder.dimension)])
        let got = try await embedder.embed(image: image)
        let cosine = Vectors.dot(got, want)
        print("siglip image parity \(name): cosine \(cosine)")
        #expect(cosine > (row == 0 ? 0.999 : 0.99), "\(name): cosine \(cosine)")
    }

    @Test("a sentence lands nearer its picture than a wrong one", .enabled(if: modelInstalled))
    func ordering() async throws {
        let embedder = try await SemanticEmbedder(folder: #require(modelFolder))
        let url = try fixtureURL("checker-400x300.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let picture = try await embedder.embed(image: image)
        let right = try await embedder.embed(text: "a checkerboard pattern")
        let wrong = try await embedder.embed(text: "a dog running on the beach")
        #expect(Vectors.dot(picture, right) > Vectors.dot(picture, wrong))
    }
}
