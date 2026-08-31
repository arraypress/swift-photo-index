//
//  Indexer.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  One indexing run: diff the source against the store, load only what
//  changed, run the extractors, write everything down. One asset failing is
//  a line in the report, never the end of the run — a 20,000-photo walk that
//  dies on photo 19,997 has wasted an afternoon.
//

import Foundation
import SpeechTranscriber

/// Runs indexing passes against a store.
public final class Indexer {

    /// What a run should do beyond the default.
    public struct Options {
        /// Transcribe video audio — the one genuinely expensive pass.
        public var includeAudio = false
        /// The face-cluster join distance; the default is calibrated.
        public var faceThreshold: Float = Clustering.defaultThreshold

        public init() {}
    }

    private let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    /// Indexes one source incrementally.
    public func index(
        source: AssetSource,
        options: Options = Options(),
        progress: ((String) -> Void)? = nil
    ) async throws -> IndexReport {
        let start = Date()
        var report = IndexReport()

        let descriptors = try await source.descriptors()
        let stored = try store.fingerprints(source: source.kind)
        let diff = IncrementalDiff.diff(current: descriptors, stored: stored)

        report.unchanged = diff.unchangedLocators.count
        report.removed = diff.removedLocators.count
        try store.removeAssets(source: source.kind, locators: diff.removedLocators)

        var seeds = try store.loadClusterSeeds()

        for (isNew, descriptor) in diff.added.map({ (true, $0) }) + diff.updated.map({ (false, $0) }) {
            progress?(descriptor.locator)
            do {
                let loaded = try await source.load(descriptor)
                let transcribed = try await process(loaded, source: source.kind,
                                                   options: options, seeds: &seeds)
                if isNew { report.added += 1 } else { report.updated += 1 }
                if transcribed { report.transcribed += 1 }
            } catch {
                report.failures[descriptor.locator] = String(describing: error)
            }
        }

        // Videos already indexed but never transcribed: --audio picks them up
        // without the files having changed.
        if options.includeAudio {
            let processed = Set((diff.added + diff.updated).map(\.locator))
            for entry in try store.videosNeedingTranscript(source: source.kind)
            where !processed.contains(entry.locator) {
                progress?(entry.locator)
                do {
                    let loaded = try await source.load(
                        AssetDescriptor(locator: entry.locator, fingerprint: ""))
                    if let url = loaded.videoFileURL,
                       let transcript = try await transcribe(url) {
                        try store.updateTranscript(assetID: entry.id, transcript: transcript)
                        report.transcribed += 1
                    }
                } catch {
                    report.failures[entry.locator] = String(describing: error)
                }
            }
        }

        report.seconds = Date().timeIntervalSince(start)
        return report
    }

    // MARK: - One asset

    /// Extracts and stores one loaded asset. Returns whether audio was
    /// transcribed.
    private func process(
        _ loaded: LoadedAsset, source: SourceKind,
        options: Options, seeds: inout [ClusterSeed]
    ) async throws -> Bool {
        var content = ExtractedContent()
        var duration = Double?.none

        if loaded.media == .image, let image = loaded.cgImage {
            content.ocr = (try? Extractors.ocr(in: image)) ?? ""
            content.labels = (try? Extractors.labels(in: image)) ?? []
            content.featurePrint = try? Extractors.featurePrint(of: image)
            content.faces = (try? Extractors.faces(in: image)) ?? []
        } else if loaded.media == .video, let url = loaded.videoFileURL {
            let sampled = try await VideoSampling.frames(from: url)
            duration = sampled.duration
            var lines: Set<String> = []
            var bestLabels: [String: Double] = [:]
            for (offset, frame) in sampled.frames.enumerated() {
                if let text = try? Extractors.ocr(in: frame.image) {
                    for line in text.split(separator: "\n") { lines.insert(String(line)) }
                }
                for label in (try? Extractors.labels(in: frame.image)) ?? [] {
                    bestLabels[label.name] = max(bestLabels[label.name] ?? 0, label.confidence)
                }
                if let detected = try? Extractors.faces(in: frame.image) {
                    content.faces.append(contentsOf: detected)
                }
                if offset == sampled.frames.count / 2 {
                    content.featurePrint = try? Extractors.featurePrint(of: frame.image)
                }
            }
            content.ocr = lines.sorted().joined(separator: "\n")
            content.labels = bestLabels
                .map { Label(name: $0.key, confidence: $0.value) }
                .sorted { $0.confidence > $1.confidence }
                .prefix(Extractors.labelLimit)
                .map { $0 }
            if options.includeAudio {
                content.transcript = try await transcribe(url)
            }
        }
        // A video with no reachable file still gets its metadata row.

        let filename = source == .folder
            ? URL(fileURLWithPath: loaded.descriptor.locator).lastPathComponent
            : nil
        let kind = ScreenshotRule.kind(
            media: loaded.media, filename: filename,
            photoLibrarySaysScreenshot: loaded.screenshotHint)

        let assetID = try store.upsertAsset(IndexStore.AssetRecord(
            source: source, locator: loaded.descriptor.locator,
            fingerprint: loaded.descriptor.fingerprint, kind: kind,
            created: loaded.created, modified: loaded.modified, byteSize: loaded.byteSize,
            width: loaded.width, height: loaded.height,
            latitude: loaded.latitude, longitude: loaded.longitude,
            duration: duration,
            camera: loaded.camera, lens: loaded.lens, orientation: loaded.orientation,
            faceCount: content.faces.count,
            hasTranscript: content.transcript != nil
        ))

        // Faces first: the people column depends on their cluster names.
        var assigned: [(face: DetectedFace, clusterID: Int64)] = []
        for face in content.faces {
            if let index = Clustering.nearestIndex(face.embedding, in: seeds,
                                                   threshold: options.faceThreshold) {
                Clustering.absorb(face.embedding, into: &seeds[index])
                assigned.append((face, seeds[index].id))
            } else {
                let id = try store.createCluster()
                seeds.append(ClusterSeed(id: id, centroid: face.embedding, count: 1))
                assigned.append((face, id))
            }
        }
        try store.replaceFaces(assetID: assetID, assigned)

        let named = try store.namedClusters()
        let namesHere = Set(assigned.map(\.clusterID))
        let people = named.filter { namesHere.contains($0.id) }.map(\.name).sorted()

        try store.replaceLabels(assetID: assetID, content.labels)
        if let print = content.featurePrint, !print.isEmpty {
            try store.upsertPrint(assetID: assetID, print)
        }
        // The camera rides in the labels column so "iphone" is a query,
        // not just a JSON field.
        let labelsText = (content.labels.map(\.name) + [loaded.camera].compactMap { $0 })
            .joined(separator: " ")
        try store.replaceContent(
            assetID: assetID,
            ocr: content.ocr,
            labelsText: labelsText,
            transcript: content.transcript,
            people: people.joined(separator: " ")
        )
        return content.transcript != nil
    }

    /// The spoken words of a video, or nil when it simply has no audio.
    private func transcribe(_ url: URL) async throws -> String? {
        do {
            let transcript = try await SpeechTranscriber.transcribe(videoURL: url)
            let text = transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch TranscriptionError.noAudioTrack {
            return nil
        }
    }
}
