//
//  PureTests.swift
//  PhotoIndexTests
//
//  Created by David Sherlock on 2026.
//
//  The rules pinned alone: query building, ranking, clustering, diffing,
//  screenshots, schema and store bookkeeping — no Vision, no fixtures, no
//  permission. These are the tests CI stands on.
//

import Foundation
import XCTest
@testable import PhotoIndex

final class PureTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pix-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - FTS query building

    func testTokensSurviveHostileQueries() {
        XCTAssertEqual(FTSQuery.tokens("Who's-there? Café №42"), ["who", "s", "there", "café", "42"])
        XCTAssertEqual(FTSQuery.tokens("  \"quoted\"  AND (parens) "), ["quoted", "and", "parens"])
        XCTAssertEqual(FTSQuery.tokens("汉字 test"), ["汉字", "test"])
        XCTAssertEqual(FTSQuery.tokens("!!!"), [])
    }

    func testMatchExpressionQuotesEveryToken() {
        XCTAssertEqual(FTSQuery.matchExpression(["invoice", "4021"]), "\"invoice\" \"4021\"")
        XCTAssertNil(FTSQuery.matchExpression([]))
    }

    func testQueryPlanConsumesNamesLongestFirst() {
        let named: [(id: Int64, name: String)] = [(1, "Jane Smith"), (2, "Jane"), (3, "Bo")]
        let plan = QueryPlan.plan(query: "jane smith at the beach", namedClusters: named)
        XCTAssertEqual(plan.personClusters, [1], "the two-token name wins over its one-token prefix")
        XCTAssertEqual(plan.ftsTokens, ["at", "the", "beach"])

        let personOnly = QueryPlan.plan(query: "Bo", namedClusters: named)
        XCTAssertEqual(personOnly.personClusters, [3])
        XCTAssertTrue(personOnly.ftsTokens.isEmpty)

        let plain = QueryPlan.plan(query: "rainbow", namedClusters: named)
        XCTAssertTrue(plain.personClusters.isEmpty)
        XCTAssertEqual(plain.ftsTokens, ["rainbow"])
    }

    // MARK: - Ranking and provenance

    func testRankingOrdersByEvidence() {
        let strongText = Ranking.score(RankInput(bm25: -5, matchedLabelConfidence: nil, personMatched: false))
        let weakText = Ranking.score(RankInput(bm25: -1, matchedLabelConfidence: nil, personMatched: false))
        XCTAssertGreaterThan(strongText, weakText)

        let withLabel = Ranking.score(RankInput(bm25: -1, matchedLabelConfidence: 0.9, personMatched: false))
        XCTAssertGreaterThan(withLabel, weakText)

        let withPerson = Ranking.score(RankInput(bm25: -1, matchedLabelConfidence: nil, personMatched: true))
        XCTAssertEqual(withPerson, weakText + 0.5, accuracy: 0.0001)
    }

    func testProvenanceNamesTheFieldsAndCutsASnippet() {
        let fields = Provenance.fields(
            tokens: ["invoice"], ocr: "INVOICE 4021", labels: "document paper",
            transcript: "", people: "", place: "")
        XCTAssertEqual(fields, [.ocr])

        let snippet = Provenance.snippet(
            tokens: ["needle"],
            in: String(repeating: "hay ", count: 40) + "the needle sits here" + String(repeating: " more", count: 40))
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.contains("needle"))
        XCTAssertTrue(snippet!.hasPrefix("…") && snippet!.hasSuffix("…"))
        XCTAssertNil(Provenance.snippet(tokens: ["absent"], in: "nothing here"))
    }

    // MARK: - Clustering

    func testClusteringGroupsTightVectorsAndSeparatesOutliers() {
        var seeds: [ClusterSeed] = []
        var nextID: Int64 = 1
        let vectors: [[Float]] = [[0, 0], [0.4, 0], [10, 10], [0.2, 0.1]]
        var assignments: [Int64] = []
        for vector in vectors {
            if let index = Clustering.nearestIndex(vector, in: seeds, threshold: 1) {
                Clustering.absorb(vector, into: &seeds[index])
                assignments.append(seeds[index].id)
            } else {
                seeds.append(ClusterSeed(id: nextID, centroid: vector, count: 1))
                assignments.append(nextID)
                nextID += 1
            }
        }
        XCTAssertEqual(assignments, [1, 1, 2, 1], "near vectors join, the outlier founds its own")
        XCTAssertEqual(seeds[0].count, 3)
        XCTAssertEqual(seeds[0].centroid[0], 0.2, accuracy: 0.0001, "the centroid is the running mean")
    }

    func testClusteringBoundaryIsInclusive() {
        var seeds = [ClusterSeed(id: 7, centroid: [0, 0], count: 1)]
        XCTAssertNotNil(Clustering.nearestIndex([3, 4], in: seeds, threshold: 5), "distance == threshold joins")
        XCTAssertNil(Clustering.nearestIndex([3, 4.001], in: seeds, threshold: 5))
        _ = seeds  // silence the mutable warning symmetry
    }

    // MARK: - Vectors

    func testVectorMaths() {
        XCTAssertEqual(Vectors.euclidean([0, 0], [3, 4]), 5, accuracy: 0.0001)
        XCTAssertEqual(Vectors.cosine([1, 0], [0, 1]), 1, accuracy: 0.0001)
        XCTAssertEqual(Vectors.cosine([2, 0], [4, 0]), 0, accuracy: 0.0001)
        let floats: [Float] = [1.5, -2.25, 0]
        XCTAssertEqual(Vectors.floats(from: Vectors.data(from: floats)), floats)
    }

    // MARK: - Screenshot rule

    func testScreenshotRule() {
        XCTAssertEqual(ScreenshotRule.kind(media: .image, filename: "Screenshot 2026-08-31 at 20.58.40.png",
                                           photoLibrarySaysScreenshot: false), .screenshot)
        XCTAssertEqual(ScreenshotRule.kind(media: .image, filename: "Screen Shot 2019-01-01.png",
                                           photoLibrarySaysScreenshot: false), .screenshot)
        XCTAssertEqual(ScreenshotRule.kind(media: .image, filename: "IMG_1234.jpg",
                                           photoLibrarySaysScreenshot: false), .image)
        XCTAssertEqual(ScreenshotRule.kind(media: .image, filename: nil,
                                           photoLibrarySaysScreenshot: true), .screenshot)
        XCTAssertEqual(ScreenshotRule.kind(media: .video, filename: "screenshot.mov",
                                           photoLibrarySaysScreenshot: false), .video)
    }

    // MARK: - Incremental diff

    func testIncrementalDiff() {
        let current = [
            AssetDescriptor(locator: "/a", fingerprint: "1:10"),
            AssetDescriptor(locator: "/b", fingerprint: "2:20"),
            AssetDescriptor(locator: "/new", fingerprint: "3:30"),
        ]
        let stored = ["/a": "1:10", "/b": "1:20", "/gone": "9:90"]
        let diff = IncrementalDiff.diff(current: current, stored: stored)
        XCTAssertEqual(diff.added.map(\.locator), ["/new"])
        XCTAssertEqual(diff.updated.map(\.locator), ["/b"])
        XCTAssertEqual(diff.removedLocators, ["/gone"])
        XCTAssertEqual(diff.unchangedLocators, ["/a"])
    }

    // MARK: - Store

    func testStoreUpsertKeepsIdentityAndCascades() throws {
        let store = try IndexStore(directory: temporaryDirectory())
        let record = IndexStore.AssetRecord(
            source: .folder, locator: "/pics/a.jpg", fingerprint: "1:1", kind: .image,
            created: nil, modified: nil, byteSize: 10, width: 4, height: 4,
            latitude: nil, longitude: nil, duration: nil, camera: nil, lens: nil, orientation: nil, faceCount: 1, hasTranscript: false)
        let first = try store.upsertAsset(record)
        let again = try store.upsertAsset(IndexStore.AssetRecord(
            source: .folder, locator: "/pics/a.jpg", fingerprint: "2:2", kind: .image,
            created: nil, modified: nil, byteSize: 11, width: 4, height: 4,
            latitude: nil, longitude: nil, duration: nil, camera: nil, lens: nil, orientation: nil, faceCount: 1, hasTranscript: false))
        XCTAssertEqual(first, again, "re-indexing the same locator keeps the same id")
        XCTAssertEqual(try store.fingerprints(source: .folder)["/pics/a.jpg"], "2:2")

        try store.replaceLabels(assetID: first, [Label(name: "document", confidence: 0.8)])
        try store.upsertPrint(assetID: first, [1, 2, 3])
        let cluster = try store.createCluster()
        try store.replaceFaces(assetID: first, [
            (DetectedFace(x: 0, y: 0, width: 0.5, height: 0.5, embedding: [1, 1]), cluster),
        ])
        try store.replaceContent(assetID: first, ocr: "hello", labelsText: "document",
                                 transcript: nil, people: "")

        try store.removeAssets(source: .folder, locators: ["/pics/a.jpg"])
        XCTAssertNil(try store.asset(byLocator: "/pics/a.jpg"))
        XCTAssertTrue(try store.allPrints().isEmpty)
        XCTAssertTrue(try store.clusters().isEmpty, "an emptied cluster is dropped")
        XCTAssertTrue(try store.ftsCandidates(match: "\"hello\"", limit: 5).isEmpty)
    }

    func testNamingAClusterFeedsSearchImmediately() throws {
        let store = try IndexStore(directory: temporaryDirectory())
        var ids: [Int64] = []
        for locator in ["/p/one.jpg", "/p/two.jpg"] {
            let id = try store.upsertAsset(IndexStore.AssetRecord(
                source: .folder, locator: locator, fingerprint: "1:1", kind: .image,
                created: Date(), modified: nil, byteSize: nil, width: nil, height: nil,
                latitude: nil, longitude: nil, duration: nil, camera: nil, lens: nil, orientation: nil, faceCount: 1, hasTranscript: false))
            try store.replaceContent(assetID: id, ocr: "", labelsText: "", transcript: nil, people: "")
            ids.append(id)
        }
        let cluster = try store.createCluster()
        for id in ids {
            try store.replaceFaces(assetID: id, [
                (DetectedFace(x: 0, y: 0, width: 0.4, height: 0.4, embedding: [0, 0]), cluster),
            ])
        }
        try store.nameCluster(id: cluster, name: "Alice")

        let engine = SearchEngine(store: store)
        let hits = try engine.search("alice")
        XCTAssertEqual(Set(hits.map(\.asset.locator)), ["/p/one.jpg", "/p/two.jpg"])
        XCTAssertEqual(hits.first?.matched, [.people])

        XCTAssertThrowsError(try store.nameCluster(id: 999, name: "Nobody"))
    }

    func testFTSQuerySurvivesHostileInputEndToEnd() throws {
        let store = try IndexStore(directory: temporaryDirectory())
        let id = try store.upsertAsset(IndexStore.AssetRecord(
            source: .folder, locator: "/p/note.png", fingerprint: "1:1", kind: .image,
            created: nil, modified: nil, byteSize: nil, width: nil, height: nil,
            latitude: nil, longitude: nil, duration: nil, camera: nil, lens: nil, orientation: nil, faceCount: 0, hasTranscript: false))
        try store.replaceContent(assetID: id, ocr: "who's-there? café 42", labelsText: "",
                                 transcript: nil, people: "")
        let engine = SearchEngine(store: store)
        XCTAssertEqual(try engine.search("\"who's-there?\"").count, 1)
        XCTAssertEqual(try engine.search("café").count, 1)
        XCTAssertThrowsError(try engine.search("!!!"), "a query with no tokens is refused, not empty-matched")
    }

    func testFutureSchemaIsRefusedPlainly() throws {
        let directory = try temporaryDirectory()
        _ = try IndexStore(directory: directory)
        let raw = try Database(path: directory.appendingPathComponent("index.sqlite").path)
        try raw.run("UPDATE meta SET value='99' WHERE key='schema_version'")
        XCTAssertThrowsError(try IndexStore(directory: directory)) { error in
            XCTAssertTrue(String(describing: error).contains("newer"),
                          "the refusal names the reason: \(error)")
        }
    }

    // MARK: - EXIF rules

    func testEXIFDateAndCameraRules() {
        let date = EXIFFields.parseDate("2026:08:31 20:15:03")
        XCTAssertNotNil(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date!)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 8, 31, 20])
        XCTAssertNotNil(EXIFFields.parseDate("2026:08:31 20:15:03.250"), "sub-seconds tolerated")
        XCTAssertNil(EXIFFields.parseDate("2026-08-31 20:15:03"), "hyphens are not EXIF")
        XCTAssertNil(EXIFFields.parseDate("    "))

        XCTAssertEqual(EXIFFields.cameraName(make: "Apple", model: "iPhone 16 Pro"), "Apple iPhone 16 Pro")
        XCTAssertEqual(EXIFFields.cameraName(make: "NIKON CORPORATION", model: "NIKON Z 6"), "NIKON Z 6",
                       "a model that repeats the make IS the name")
        XCTAssertEqual(EXIFFields.cameraName(make: nil, model: "DJI Mini 4"), "DJI Mini 4")
        XCTAssertNil(EXIFFields.cameraName(make: " ", model: nil))
    }

    // MARK: - Catalog

    func testCatalogAssemblesEverything() throws {
        let store = try IndexStore(directory: temporaryDirectory())
        let id = try store.upsertAsset(IndexStore.AssetRecord(
            source: .folder, locator: "/p/trip.jpg", fingerprint: "1:1", kind: .image,
            created: Date(timeIntervalSince1970: 1_770_000_000), modified: nil, byteSize: nil,
            width: 4000, height: 3000, latitude: 51.5, longitude: -0.1, duration: nil,
            camera: "Apple iPhone 16 Pro", lens: nil, orientation: 1,
            faceCount: 1, hasTranscript: false))
        try store.replaceLabels(assetID: id, [Label(name: "beach", confidence: 0.9)])
        // The labels column carries the camera too — the indexer appends it.
        try store.replaceContent(assetID: id, ocr: "PIER 39",
                                 labelsText: "beach Apple iPhone 16 Pro",
                                 transcript: nil, people: "")
        let cluster = try store.createCluster()
        try store.replaceFaces(assetID: id, [
            (DetectedFace(x: 0, y: 0, width: 0.3, height: 0.3, embedding: [0, 0]), cluster),
        ])
        try store.nameCluster(id: cluster, name: "Alice")
        try store.setPlace(assetID: id, place: "London England")

        let entries = try store.catalog(pathPrefix: "/p/")
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.asset.camera, "Apple iPhone 16 Pro")
        XCTAssertEqual(entry.asset.place, "London England")
        XCTAssertEqual(entry.labels.map(\.name), ["beach"])
        XCTAssertEqual(entry.ocr, "PIER 39")
        XCTAssertEqual(entry.people, ["Alice"])
        XCTAssertTrue(try store.catalog(pathPrefix: "/elsewhere/").isEmpty)

        // The place is searchable, and survives a re-index of the content.
        let engine = SearchEngine(store: store)
        XCTAssertEqual(try engine.search("london").first?.matched.contains(.place), true)
        XCTAssertEqual(try engine.search("iphone").first?.matched.contains(.labels), true,
                       "the camera is a query, not just a JSON field")
        try store.replaceContent(assetID: id, ocr: "PIER 39", labelsText: "beach",
                                 transcript: nil, people: "Alice")
        XCTAssertEqual(try engine.search("london").count, 1, "re-index kept the geocode")
    }

    // MARK: - Audit rules

    func testMRZCheckDigitsAndPassportDetection() {
        // Minted TD3 second line: doc/dob/expiry check digits 6, 2, 9.
        XCTAssertEqual(AuditRules.mrzCheckDigit("L898902C3"), 6)
        XCTAssertEqual(AuditRules.mrzCheckDigit("740812"), 2)
        XCTAssertEqual(AuditRules.mrzCheckDigit("120415"), 9)
        XCTAssertNil(AuditRules.mrzCheckDigit("bad!"), "lowercase and punctuation are not MRZ")

        let zone = "P<IRLSHERLOCK<<DAVID<MICHAEL<<<<<<<<<<<<<<<<\nL898902C36IRL7408122F1204159<<<<<<<<<<<<<<08"
        XCTAssertEqual(AuditRules.passportFindings(in: zone), ["P<IRL•••"])
        // OCR spacing inside the zone is tolerated; a corrupted check digit is not.
        let spaced = zone.replacingOccurrences(of: "L898902C36", with: "L8989 02C36")
        XCTAssertEqual(AuditRules.passportFindings(in: spaced), ["P<IRL•••"])
        let corrupted = zone.replacingOccurrences(of: "L898902C36", with: "L898902C37")
        XCTAssertTrue(AuditRules.passportFindings(in: corrupted).isEmpty)
    }

    func testIBANMod97() {
        XCTAssertTrue(AuditRules.ibanIsValid("GB82WEST12345698765432"))
        XCTAssertFalse(AuditRules.ibanIsValid("GB82WEST12345698765431"))
        XCTAssertEqual(AuditRules.ibanFindings(in: "pay to GB82 WEST 1234 5698 7654 32 today"),
                       ["GB82•••5432"])
        XCTAssertTrue(AuditRules.ibanFindings(in: "GB82WEST12345698765431").isEmpty)
    }

    func testCardCandidatesAndMasking() {
        // 4242… is the canonical Luhn-valid test card.
        let text = "receipt 4242 4242 4242 4242 ref 12345678 2026-08-31"
        let findings = AuditRules.cardFindings(in: text)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].masked, "••••4242")
        XCTAssertFalse(findings[0].masked.contains("4242 4242"), "the full number never survives")
        // A Luhn-invalid sixteen digits is not a finding.
        XCTAssertTrue(AuditRules.cardFindings(in: "4242 4242 4242 4241").isEmpty)
        // Nineteen digits in one run parse; twenty digits are not a card.
        XCTAssertEqual(AuditRules.cardCandidates(in: "12345678901234567890").count, 0)
    }

    func testContactAndSSNMasks() {
        XCTAssertEqual(AuditRules.ssnFindings(in: "SSN 078-05-1120 on file"), ["•••-••-1120"])
        XCTAssertEqual(AuditRules.emailFindings(in: "mail dave@example.com now"), ["d•••@example.com"])
        XCTAssertEqual(AuditRules.phoneFindings(in: "call +353 87 123 4567 tonight"), ["+353•••"])
        XCTAssertTrue(AuditRules.phoneFindings(in: "order 8712345670 shipped").isEmpty,
                      "bare digit runs are not phones")
    }

    func testHomeClusterInference() {
        // Ten sightings within ~40 m, three scattered across town.
        var coords: [(lat: Double, lon: Double)] = []
        for i in 0..<10 {
            coords.append((53.3498 + Double(i) * 0.00003, -6.2603))
        }
        coords.append((53.40, -6.30))
        coords.append((53.30, -6.20))
        coords.append((53.35, -6.10))
        let home = try! XCTUnwrap(AuditRules.homeCluster(coords))
        XCTAssertEqual(home.lat, 53.34993, accuracy: 0.001)
        XCTAssertLessThan(AuditRules.meters(from: coords[0], to: home), 100)
        XCTAssertGreaterThan(AuditRules.meters(from: (53.40, -6.30), to: home), 5000)
        // Too few sightings: no home is inferred at all.
        XCTAssertNil(AuditRules.homeCluster(Array(coords.prefix(4))))
    }

    func testMaskKeepingSuffix() {
        XCTAssertEqual(AuditRules.maskKeepingSuffix("4242424242424242"), "••••4242")
        XCTAssertEqual(AuditRules.maskKeepingSuffix("abc"), "•••", "short values vanish entirely")
    }
}
