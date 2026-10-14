//
//  PipelineTests.swift
//  PhotoIndexTests
//
//  Created by David Sherlock on 2026.
//
//  The whole pipeline over a generated corpus: images with DRAWN text so OCR
//  has deterministic targets, a rendered video, and a spoken track from
//  `say`. Everything runs against temp directories — never a real library,
//  never a network.
//

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SpeechTranscriber
import UniformTypeIdentifiers
import XCTest
@testable import PhotoIndex

final class PipelineTests: XCTestCase {

    // MARK: - Fixture drawing

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pix-pipeline-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Draws big black words on a coloured board — a deterministic OCR target.
    static func drawImage(words: [String], background: CGColor, to url: URL,
                          width: Int = 800, height: Int = 500, shade: CGFloat = 0) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoIndexError.extraction("no context") }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if shade > 0 {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: shade))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 84, nil)
        for (row, word) in words.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: word, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: CGFloat(height - 120 - row * 110))
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PhotoIndexError.extraction("no image") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The standard corpus: three text images, a screenshot-named one, and a
    /// near-duplicate pair.
    private func makeCorpus(in directory: URL) throws {
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let orange = CGColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        try Self.drawImage(words: ["INVOICE", "4021", "TOTAL DUE"], background: white,
                           to: directory.appendingPathComponent("invoice.png"))
        try Self.drawImage(words: ["SOURDOUGH", "STARTER", "DAY FOUR"], background: white,
                           to: directory.appendingPathComponent("recipe.png"))
        try Self.drawImage(words: ["ERROR 517", "EXCLUSIVITY", "VIOLATION"], background: white,
                           to: directory.appendingPathComponent("Screenshot 2026-01-01 at 09.00.00.png"))
        try Self.drawImage(words: [], background: orange,
                           to: directory.appendingPathComponent("sunset.png"))
        try Self.drawImage(words: [], background: orange,
                           to: directory.appendingPathComponent("sunset-copy.png"))
        try Self.drawImage(words: [], background: orange,
                           to: directory.appendingPathComponent("sunset-shaded.png"), shade: 0.12)
    }

    private func makeIndexed(_ corpus: URL) async throws -> (IndexStore, IndexReport) {
        let store = try IndexStore(directory: temporaryDirectory("store"))
        let report = try await Indexer(store: store).index(source: FolderSource(paths: [corpus.path]))
        return (store, report)
    }

    // MARK: - Round trips

    func testIndexSearchRoundTrip() async throws {
        let corpus = try temporaryDirectory("corpus")
        try makeCorpus(in: corpus)
        let (store, report) = try await makeIndexed(corpus)

        XCTAssertEqual(report.added, 6)
        XCTAssertEqual(report.failures, [:])

        let engine = SearchEngine(store: store)
        let invoice = try engine.search("invoice 4021")
        XCTAssertEqual(invoice.first?.asset.locator,
                       corpus.appendingPathComponent("invoice.png").path)
        XCTAssertTrue(invoice.first?.matched.contains(.ocr) ?? false)
        XCTAssertNotNil(invoice.first?.snippet)

        let screenshot = try engine.search("exclusivity violation")
        XCTAssertEqual(screenshot.first?.asset.kind, .screenshot,
                       "the filename rule stamped the kind")
        XCTAssertEqual(try engine.search("exclusivity", kind: .image).count, 0,
                       "the kind filter excludes it")
        XCTAssertEqual(try engine.search("sourdough").count, 1)
    }

    func testReindexTouchesOnlyWhatChanged() async throws {
        let corpus = try temporaryDirectory("corpus")
        try makeCorpus(in: corpus)
        let (store, _) = try await makeIndexed(corpus)

        let second = try await Indexer(store: store).index(source: FolderSource(paths: [corpus.path]))
        XCTAssertEqual(second.processed, 0, "an untouched corpus is all unchanged")
        XCTAssertEqual(second.unchanged, 6)

        // Rewrite one file with different content — the size change flips the
        // fingerprint even inside the same mtime second.
        try Self.drawImage(words: ["INVOICE", "9999", "PAID IN FULL"],
                           background: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                           to: corpus.appendingPathComponent("invoice.png"))
        let third = try await Indexer(store: store).index(source: FolderSource(paths: [corpus.path]))
        XCTAssertEqual(third.updated, 1)
        XCTAssertEqual(third.added, 0)

        let engine = SearchEngine(store: store)
        XCTAssertEqual(try engine.search("9999").count, 1)
        XCTAssertEqual(try engine.search("4021").count, 0, "stale text is gone")

        try FileManager.default.removeItem(at: corpus.appendingPathComponent("recipe.png"))
        let fourth = try await Indexer(store: store).index(source: FolderSource(paths: [corpus.path]))
        XCTAssertEqual(fourth.removed, 1)
        XCTAssertEqual(try engine.search("sourdough").count, 0)
    }

    func testIndexingOneFolderKeepsAnother() async throws {
        let first = try temporaryDirectory("first")
        let second = try temporaryDirectory("second")
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        try Self.drawImage(words: ["HARBOUR"], background: white, to: first.appendingPathComponent("a.png"))
        try Self.drawImage(words: ["MEADOW"], background: white, to: second.appendingPathComponent("b.png"))
        let store = try IndexStore(directory: temporaryDirectory("store"))

        _ = try await Indexer(store: store).index(source: FolderSource(paths: [first.path]))
        let other = try await Indexer(store: store).index(source: FolderSource(paths: [second.path]))
        XCTAssertEqual(other.removed, 0, "walking B judges only B")
        let engine = SearchEngine(store: store)
        XCTAssertEqual(try engine.search("harbour").count, 1, "A is still indexed")
        XCTAssertEqual(try engine.search("meadow").count, 1)

        try FileManager.default.removeItem(at: second.appendingPathComponent("b.png"))
        let again = try await Indexer(store: store).index(source: FolderSource(paths: [second.path]))
        XCTAssertEqual(again.removed, 1, "a file gone from the walked folder is still forgotten")
        XCTAssertEqual(try engine.search("harbour").count, 1)
    }

    func testSimilarAndPerceptualDupes() async throws {
        let corpus = try temporaryDirectory("corpus")
        try makeCorpus(in: corpus)
        let (store, _) = try await makeIndexed(corpus)
        let engine = SearchEngine(store: store)

        let similar = try engine.similar(to: corpus.appendingPathComponent("sunset.png").path, limit: 3)
        XCTAssertEqual(similar.first?.asset.locator,
                       corpus.appendingPathComponent("sunset-copy.png").path,
                       "the byte-identical copy is nearest")
        XCTAssertEqual(similar.first?.distance ?? -1, 0, accuracy: 0.001)

        // Strict: only the byte-identical pair counts.
        let exact = try engine.duplicateGroups(threshold: 0.05)
        XCTAssertEqual(
            exact.map { Set($0.map { URL(fileURLWithPath: $0.locator).lastPathComponent }) },
            [Set(["sunset.png", "sunset-copy.png"])])

        // Default: an edited export joins its original; unrelated images
        // stay out of the group.
        let groups = try engine.duplicateGroups()
        let sunsetGroup = groups.first { group in
            group.contains { $0.locator.hasSuffix("/sunset.png") }
        }
        let names = Set((sunsetGroup ?? []).map { URL(fileURLWithPath: $0.locator).lastPathComponent })
        XCTAssertTrue(names.isSuperset(of: ["sunset.png", "sunset-copy.png", "sunset-shaded.png"]),
                      "an edited export groups with its original: \(names)")
        XCTAssertFalse(names.contains("invoice.png"), "different images stay out: \(names)")
    }

    // MARK: - Video

    /// Renders a short video whose frames carry drawn words.
    static func makeVideo(words: [String], to url: URL, seconds: Double = 2) async throws {
        let width = 640, height = 400
        let framesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pix-frame-\(UUID().uuidString).png")
        try drawImage(words: words, background: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                      to: framesDirectory, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: framesDirectory) }
        guard let source = CGImageSourceCreateWithURL(framesDirectory as CFURL, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotoIndexError.extraction("no frame image")
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = 10
        let frameCount = Int(seconds * Double(fps))
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw PhotoIndexError.extraction("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PhotoIndexError.extraction("writer: \(String(describing: writer.error))")
        }
    }

    func testVideoFramesAreReadAndSearchable() async throws {
        let corpus = try temporaryDirectory("video")
        try await Self.makeVideo(words: ["HELLO", "PIX FLEET"],
                                 to: corpus.appendingPathComponent("clip.mov"))
        let (store, report) = try await makeIndexed(corpus)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.failures, [:])

        let engine = SearchEngine(store: store)
        let hits = try engine.search("fleet")
        XCTAssertEqual(hits.first?.asset.kind, .video)
        XCTAssertTrue(hits.first?.matched.contains(.ocr) ?? false)
        XCTAssertGreaterThan(hits.first?.asset.duration ?? 0, 1)
    }

    func testSilentVideoAudioPassSkipsGracefully() async throws {
        let corpus = try temporaryDirectory("silent")
        try await Self.makeVideo(words: ["QUIET"], to: corpus.appendingPathComponent("quiet.mov"))
        let store = try IndexStore(directory: temporaryDirectory("store"))
        var options = Indexer.Options()
        options.includeAudio = true
        let report = try await Indexer(store: store)
            .index(source: FolderSource(paths: [corpus.path]), options: options)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.transcribed, 0)
        XCTAssertEqual(report.failures, [:], "no audio track is a skip, not a failure")
    }

    func testSpokenVideoBecomesSearchable() async throws {
        guard SpeechTranscriber.isAvailable else {
            print("[skip] SpeechAnalyzer model unavailable on this machine")
            return
        }
        let corpus = try temporaryDirectory("spoken")
        let video = corpus.appendingPathComponent("memo.mov")
        try await Self.makeVideo(words: ["MEMO"], to: video, seconds: 4)

        // A spoken track from `say`, muxed under the frames. The extension
        // matters: float32 into .aiff fails at open ("fmt?" — AIFF cannot
        // carry it) leaving a zero-byte file, so say writes WAVE, which
        // passthrough muxes into .mov as LPCM.
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("pix-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "--data-format=LEF32@22050",
                         "the pineapple manifesto arrived on tuesday"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw PhotoIndexError.extraction("say failed to render the fixture")
        }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack!, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: min(videoDuration, audioDuration)),
                             of: audioTrack!, at: .zero)
        let muxed = corpus.appendingPathComponent("spoken.mov")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw PhotoIndexError.extraction("no export session")
        }
        try await export.export(to: muxed, as: .mov)
        try FileManager.default.removeItem(at: video)

        let store = try IndexStore(directory: temporaryDirectory("store"))
        var options = Indexer.Options()
        options.includeAudio = true
        let report = try await Indexer(store: store)
            .index(source: FolderSource(paths: [corpus.path]), options: options)
        XCTAssertEqual(report.transcribed, 1, "failures: \(report.failures)")

        let hits = try SearchEngine(store: store).search("pineapple manifesto")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.first?.matched.contains(.transcript) ?? false)
    }

    // MARK: - Audit end to end

    func testAuditFindsSeededCardAndPassport() async throws {
        let corpus = try temporaryDirectory("audit-corpus")
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        try Self.drawImage(words: ["PAYMENT CARD", "4242 4242 4242 4242", "EXP 12/29"],
                           background: white, to: corpus.appendingPathComponent("card.png"),
                           width: 1200, height: 500)
        try Self.drawImage(words: ["P<IRLSHERLOCK<<DAVID<MICHAEL<<<<<<<<<<<<<<<<",
                                   "L898902C36IRL7408122F1204159<<<<<<<<<<<<<<08"],
                           background: white, to: corpus.appendingPathComponent("passport.png"),
                           width: 2400, height: 400)
        let (store, report) = try await makeIndexed(corpus)
        XCTAssertEqual(report.failures, [:])

        let findings = try await Auditor(store: store).run(
            options: .init(minimumSeverity: .low, scanDocuments: false))

        let card = findings.first { $0.category == .card }
        XCTAssertEqual(card?.excerpt, "••••4242")
        XCTAssertEqual(card?.locator, corpus.appendingPathComponent("card.png").path)
        XCTAssertEqual(card?.severity, .high)

        let passport = findings.first { $0.category == .passport }
        XCTAssertEqual(passport?.excerpt, "P<IRL•••")
        XCTAssertEqual(passport?.locator, corpus.appendingPathComponent("passport.png").path)

        // The leak test: no finding anywhere carries a seeded value.
        for finding in findings {
            XCTAssertFalse(finding.why.contains("4242 4242"), finding.why)
            XCTAssertFalse((finding.excerpt ?? "").contains("4242424242424242"))
            XCTAssertFalse((finding.excerpt ?? "").contains("L898902C3"))
        }
    }
}
