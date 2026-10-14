//
//  GemmaTokenizer.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  SigLIP 2's text side reads Gemma's tokenizer: a byte-fallback BPE over the
//  whole lower-cased string, spaces turned into "▁" first, <eos> appended,
//  right-padded with <pad> to a fixed length. It is read from two flat files
//  the export writes — the vocabulary, and the merges as id triples in rank
//  order — so a query costs no JSON parse of a 34 MB tokenizer.json.
//

import Foundation

/// Gemma's byte-fallback BPE, as SigLIP 2's text encoder was trained on it.
public struct GemmaTokenizer: Sendable {

    /// Token id of `<pad>`.
    public let pad: Int32
    /// Token id of `<eos>`.
    public let eos: Int32
    /// Token id of `<unk>`, used only if a byte token were ever missing.
    public let unk: Int32

    /// Single-scalar tokens: the starting symbols of a merge.
    private let scalars: [UInt32: Int32]
    /// `<0x00>`…`<0xFF>` for characters the vocabulary does not hold.
    private let bytes: [Int32]
    /// (left id << 32 | right id) → (rank, merged id).
    private let merges: [UInt64: (rank: Int32, merged: Int32)]

    /// Reads `vocab.bin` and `merges.bin` from `folder`.
    public init(folder: URL, pad: Int32 = 0, eos: Int32 = 1, unk: Int32 = 3) throws(PhotoIndexError) {
        let vocabulary = try Self.read(folder.appendingPathComponent("vocab.bin"))
        let mergeData = try Self.read(folder.appendingPathComponent("merges.bin"))
        let tokens = try Self.tokens(in: vocabulary)

        var scalars: [UInt32: Int32] = [:]
        var byIdentity: [String: Int32] = [:]
        for (id, token) in tokens.enumerated() {
            let unicode = token.unicodeScalars
            if unicode.count == 1, let only = unicode.first { scalars[only.value] = Int32(id) }
            if token.count == 6, token.hasPrefix("<0x"), token.hasSuffix(">") { byIdentity[token] = Int32(id) }
        }
        let bytes = (0..<256).map { byIdentity[String(format: "<0x%02X>", $0)] ?? unk }

        let triples = try Self.triples(in: mergeData)
        var merges: [UInt64: (rank: Int32, merged: Int32)] = [:]
        merges.reserveCapacity(triples.count)
        for (rank, triple) in triples.enumerated() {
            let key = UInt64(UInt32(bitPattern: triple.left)) << 32 | UInt64(UInt32(bitPattern: triple.right))
            if merges[key] == nil { merges[key] = (Int32(rank), triple.merged) }
        }

        self.pad = pad
        self.eos = eos
        self.unk = unk
        self.scalars = scalars
        self.bytes = bytes
        self.merges = merges
    }

    /// The ids for `text` at exactly `length`: lower-cased, BPE, `<eos>`, `<pad>` to the end.
    /// A text longer than fits keeps its first `length - 1` tokens and the `<eos>`.
    public func encode(_ text: String, length: Int) -> [Int32] {
        var ids = Array(tokenize(text).prefix(length - 1))
        ids.append(eos)
        ids += Array(repeating: pad, count: length - ids.count)
        return ids
    }

    /// The BPE ids of `text`, without `<eos>` or padding.
    public func tokenize(_ text: String) -> [Int32] {
        let normalised = text.lowercased().replacingOccurrences(of: " ", with: "\u{2581}")
        var symbols: [Int32] = []
        for scalar in normalised.unicodeScalars {
            if let id = scalars[scalar.value] {
                symbols.append(id)
            } else {
                symbols += String(scalar).utf8.map { bytes[Int($0)] }
            }
        }
        return Self.merge(symbols, merges)
    }

    /// Repeatedly merges the adjacent pair with the lowest rank (the leftmost on a tie).
    static func merge(_ start: [Int32], _ merges: [UInt64: (rank: Int32, merged: Int32)]) -> [Int32] {
        var symbols = start
        while symbols.count > 1 {
            var best: (index: Int, rank: Int32, merged: Int32)?
            for i in 0..<(symbols.count - 1) {
                let key = UInt64(UInt32(bitPattern: symbols[i])) << 32 | UInt64(UInt32(bitPattern: symbols[i + 1]))
                if let found = merges[key], found.rank < (best?.rank ?? .max) {
                    best = (i, found.rank, found.merged)
                }
            }
            guard let best else { break }
            symbols[best.index] = best.merged
            symbols.remove(at: best.index + 1)
        }
        return symbols
    }

    // MARK: - Files

    private static func read(_ url: URL) throws(PhotoIndexError) -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw PhotoIndexError.storage("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func tokens(in data: Data) throws(PhotoIndexError) -> [String] {
        var reader = Reader(data: data)
        guard let count = reader.u32() else { throw PhotoIndexError.storage("vocab.bin is empty") }
        var tokens: [String] = []
        tokens.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let length = reader.u32(), let bytes = reader.bytes(Int(length)) else {
                throw PhotoIndexError.storage("vocab.bin is truncated")
            }
            tokens.append(String(decoding: bytes, as: UTF8.self))
        }
        return tokens
    }

    private static func triples(in data: Data) throws(PhotoIndexError) -> [(left: Int32, right: Int32, merged: Int32)] {
        var reader = Reader(data: data)
        guard let count = reader.u32() else { throw PhotoIndexError.storage("merges.bin is empty") }
        var triples: [(left: Int32, right: Int32, merged: Int32)] = []
        triples.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let a = reader.u32(), let b = reader.u32(), let c = reader.u32() else {
                throw PhotoIndexError.storage("merges.bin is truncated")
            }
            triples.append((Int32(bitPattern: a), Int32(bitPattern: b), Int32(bitPattern: c)))
        }
        return triples
    }

    /// Little-endian reads over a byte buffer.
    private struct Reader {
        let data: Data
        var offset = 0

        mutating func u32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }
    }
}
