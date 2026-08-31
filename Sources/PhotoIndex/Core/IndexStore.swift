//
//  IndexStore.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The index on disk. Everything SQLite is behind this type: the indexer
//  hands it extracted values, the search engine asks it questions, and no
//  other file in the package contains a line of SQL.
//

import Foundation

/// The persistent index.
public final class IndexStore {

    let db: Database

    /// Where the database file lives.
    public let path: String

    /// Opens (or creates) an index at `location`: a `.sqlite` file used
    /// directly, or a directory holding `index.sqlite`. WAL journaling means
    /// a search answers while an index run writes.
    public init(at location: URL) throws {
        let file: URL
        if location.pathExtension.lowercased() == "sqlite" {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = location
        } else {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            file = location.appendingPathComponent("index.sqlite")
        }
        self.path = file.path
        self.db = try Database(path: file.path)
        try Schema.prepare(db)
    }

    /// Opens (or creates) the index inside `directory`.
    public convenience init(directory: URL) throws {
        try self.init(at: directory)
    }

    // MARK: - Meta

    func metaValue(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key=?", [.text(key)]).first?.text(0)
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }

    // MARK: - Assets

    /// The row shape the indexer writes.
    struct AssetRecord {
        let source: SourceKind
        let locator: String
        let fingerprint: String
        let kind: MediaKind
        let created: Date?
        let modified: Date?
        let byteSize: Int?
        let width: Int?
        let height: Int?
        let latitude: Double?
        let longitude: Double?
        let duration: Double?
        let camera: String?
        let lens: String?
        let orientation: Int?
        let faceCount: Int
        let hasTranscript: Bool
    }

    private static let assetColumns =
        "id, source, locator, kind, created, modified, byte_size, width, height, latitude, longitude, duration, camera, lens, orientation, place, face_count, has_transcript"

    /// Locator → fingerprint for one source, for the incremental diff.
    func fingerprints(source: SourceKind) throws -> [String: String] {
        var map: [String: String] = [:]
        for row in try db.query("SELECT locator, fingerprint FROM assets WHERE source=?", [.text(source.rawValue)]) {
            if let locator = row.text(0), let fingerprint = row.text(1) {
                map[locator] = fingerprint
            }
        }
        return map
    }

    /// Writes or refreshes one asset row; returns its stable id.
    func upsertAsset(_ record: AssetRecord, indexedAt: Date = Date()) throws -> Int64 {
        try db.run(
            """
            INSERT INTO assets(source, locator, fingerprint, kind, created, modified, byte_size,
                               width, height, latitude, longitude, duration, camera, lens, orientation,
                               face_count, has_transcript, indexed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source, locator) DO UPDATE SET
                fingerprint=excluded.fingerprint, kind=excluded.kind, created=excluded.created,
                modified=excluded.modified, byte_size=excluded.byte_size, width=excluded.width,
                height=excluded.height, latitude=excluded.latitude, longitude=excluded.longitude,
                duration=excluded.duration, camera=excluded.camera, lens=excluded.lens,
                orientation=excluded.orientation, face_count=excluded.face_count,
                has_transcript=excluded.has_transcript, indexed_at=excluded.indexed_at
            """,
            [
                .text(record.source.rawValue), .text(record.locator), .text(record.fingerprint),
                .text(record.kind.rawValue),
                record.created.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.modified.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.byteSize.map { .int(Int64($0)) } ?? .null,
                record.width.map { .int(Int64($0)) } ?? .null,
                record.height.map { .int(Int64($0)) } ?? .null,
                record.latitude.map { .real($0) } ?? .null,
                record.longitude.map { .real($0) } ?? .null,
                record.duration.map { .real($0) } ?? .null,
                record.camera.map { .text($0) } ?? .null,
                record.lens.map { .text($0) } ?? .null,
                record.orientation.map { .int(Int64($0)) } ?? .null,
                .int(Int64(record.faceCount)),
                .int(record.hasTranscript ? 1 : 0),
                .real(indexedAt.timeIntervalSince1970),
            ]
        )
        guard let id = try db.query(
            "SELECT id FROM assets WHERE source=? AND locator=?",
            [.text(record.source.rawValue), .text(record.locator)]
        ).first?.int(0) else {
            throw PhotoIndexError.storage("upsert lost the row for \(record.locator)")
        }
        return id
    }

    /// Removes assets a source no longer has. Labels, prints and faces
    /// cascade; the FTS rows are dropped here because virtual tables sit
    /// outside foreign keys.
    func removeAssets(source: SourceKind, locators: [String]) throws {
        for locator in locators {
            let ids = try db.query(
                "SELECT id FROM assets WHERE source=? AND locator=?",
                [.text(source.rawValue), .text(locator)]
            ).compactMap { $0.int(0) }
            for id in ids {
                try db.run("DELETE FROM content WHERE rowid=?", [.int(id)])
            }
            try db.run("DELETE FROM assets WHERE source=? AND locator=?",
                       [.text(source.rawValue), .text(locator)])
        }
        try dropEmptyClusters()
    }

    /// Forgets a whole source, or just the folder assets under a path prefix.
    /// Returns how many assets went.
    @discardableResult
    public func forget(source: SourceKind, pathPrefix: String? = nil) throws -> Int {
        let rows: [Database.Row]
        if let prefix = pathPrefix {
            rows = try db.query("SELECT id FROM assets WHERE source=? AND locator LIKE ?",
                                [.text(source.rawValue), .text(prefix + "%")])
        } else {
            rows = try db.query("SELECT id FROM assets WHERE source=?", [.text(source.rawValue)])
        }
        let ids = rows.compactMap { $0.int(0) }
        for id in ids {
            try db.run("DELETE FROM content WHERE rowid=?", [.int(id)])
            try db.run("DELETE FROM assets WHERE id=?", [.int(id)])
        }
        try dropEmptyClusters()
        return ids.count
    }

    private func dropEmptyClusters() throws {
        try db.run(
            "DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster_id FROM faces WHERE cluster_id IS NOT NULL)")
    }

    func asset(byID id: Int64) throws -> IndexedAsset? {
        try db.query("SELECT \(Self.assetColumns) FROM assets WHERE id=?", [.int(id)])
            .first.map(Self.makeAsset)
    }

    /// The asset a locator names, from any source.
    public func asset(byLocator locator: String) throws -> IndexedAsset? {
        try db.query("SELECT \(Self.assetColumns) FROM assets WHERE locator=?", [.text(locator)])
            .first.map(Self.makeAsset)
    }

    private static func makeAsset(_ row: Database.Row) -> IndexedAsset {
        IndexedAsset(
            id: row.int(0) ?? 0,
            source: SourceKind(rawValue: row.text(1) ?? "") ?? .folder,
            locator: row.text(2) ?? "",
            kind: MediaKind(rawValue: row.text(3) ?? "") ?? .image,
            created: row.real(4).map(Date.init(timeIntervalSince1970:)),
            modified: row.real(5).map(Date.init(timeIntervalSince1970:)),
            byteSize: row.int(6).map(Int.init),
            width: row.int(7).map(Int.init),
            height: row.int(8).map(Int.init),
            latitude: row.real(9),
            longitude: row.real(10),
            duration: row.real(11),
            camera: row.text(12),
            lens: row.text(13),
            orientation: row.int(14).map(Int.init),
            place: row.text(15),
            faceCount: Int(row.int(16) ?? 0),
            hasTranscript: (row.int(17) ?? 0) == 1
        )
    }

    // MARK: - Content

    /// Replaces the searchable text for one asset.
    func replaceContent(assetID: Int64, ocr: String, labelsText: String, transcript: String?, people: String) throws {
        // The place rides along from the asset row, so a re-index never
        // wipes a geocoded name.
        let place = try db.query("SELECT place FROM assets WHERE id=?", [.int(assetID)])
            .first?.text(0) ?? ""
        try db.run("DELETE FROM content WHERE rowid=?", [.int(assetID)])
        try db.run("INSERT INTO content(rowid, ocr, labels, transcript, people, place) VALUES(?,?,?,?,?,?)",
                   [.int(assetID), .text(ocr), .text(labelsText), .text(transcript ?? ""), .text(people), .text(place)])
    }

    /// Adds a transcript to an already-indexed asset.
    func updateTranscript(assetID: Int64, transcript: String) throws {
        try db.run("UPDATE content SET transcript=? WHERE rowid=?", [.text(transcript), .int(assetID)])
        try db.run("UPDATE assets SET has_transcript=1 WHERE id=?", [.int(assetID)])
    }

    func replaceLabels(assetID: Int64, _ labels: [Label]) throws {
        try db.run("DELETE FROM labels WHERE asset_id=?", [.int(assetID)])
        for label in labels {
            try db.run("INSERT INTO labels(asset_id, label, confidence) VALUES(?,?,?)",
                       [.int(assetID), .text(label.name), .real(label.confidence)])
        }
    }

    /// The best confidence among an asset's labels containing any token.
    /// Tokens arrive from ``FTSQuery/tokens`` — alphanumeric only, so LIKE
    /// wildcards cannot smuggle in.
    func matchedLabelConfidence(assetID: Int64, tokens: [String]) throws -> Double? {
        guard !tokens.isEmpty else { return nil }
        let clauses = tokens.map { _ in "label LIKE ?" }.joined(separator: " OR ")
        let binds: [Database.Value] = [.int(assetID)] + tokens.map { .text("%\($0)%") }
        return try db.query(
            "SELECT MAX(confidence) FROM labels WHERE asset_id=? AND (\(clauses))", binds
        ).first?.real(0)
    }

    // MARK: - Prints

    func upsertPrint(assetID: Int64, _ floats: [Float]) throws {
        try db.run("INSERT INTO prints(asset_id, data) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data",
                   [.int(assetID), .blob(Vectors.data(from: floats))])
    }

    func print(forAssetID id: Int64) throws -> [Float]? {
        try db.query("SELECT data FROM prints WHERE asset_id=?", [.int(id)])
            .first?.blob(0).map(Vectors.floats(from:))
    }

    func allPrints() throws -> [(assetID: Int64, floats: [Float])] {
        try db.query("SELECT asset_id, data FROM prints").compactMap { row in
            guard let id = row.int(0), let blob = row.blob(1) else { return nil }
            return (id, Vectors.floats(from: blob))
        }
    }

    // MARK: - Faces and clusters

    /// Replaces an asset's faces with freshly assigned ones.
    func replaceFaces(assetID: Int64, _ faces: [(face: DetectedFace, clusterID: Int64)]) throws {
        try db.run("DELETE FROM faces WHERE asset_id=?", [.int(assetID)])
        for entry in faces {
            try db.run(
                "INSERT INTO faces(asset_id, x, y, w, h, embedding, cluster_id) VALUES(?,?,?,?,?,?,?)",
                [
                    .int(assetID),
                    .real(entry.face.x), .real(entry.face.y),
                    .real(entry.face.width), .real(entry.face.height),
                    .blob(Vectors.data(from: entry.face.embedding)),
                    .int(entry.clusterID),
                ]
            )
        }
        try dropEmptyClusters()
    }

    /// Every cluster's running state, centroids recomputed from members —
    /// exact means beat stored approximations at this scale.
    func loadClusterSeeds() throws -> [ClusterSeed] {
        var grouped: [Int64: [[Float]]] = [:]
        for row in try db.query("SELECT cluster_id, embedding FROM faces WHERE cluster_id IS NOT NULL") {
            guard let id = row.int(0), let blob = row.blob(1) else { continue }
            grouped[id, default: []].append(Vectors.floats(from: blob))
        }
        return grouped.keys.sorted().compactMap { id in
            let members = grouped[id]!
            guard let first = members.first else { return nil }
            var centroid = [Float](repeating: 0, count: first.count)
            var counted = 0
            for member in members where member.count == centroid.count {
                for i in centroid.indices { centroid[i] += member[i] }
                counted += 1
            }
            guard counted > 0 else { return nil }
            for i in centroid.indices { centroid[i] /= Float(counted) }
            return ClusterSeed(id: id, centroid: centroid, count: counted)
        }
    }

    func createCluster() throws -> Int64 {
        try db.run("INSERT INTO clusters(name) VALUES(NULL)")
        return db.lastInsertID
    }

    /// Every populated cluster, biggest first.
    public func clusters() throws -> [FaceCluster] {
        try db.query(
            """
            SELECT c.id, c.name, COUNT(f.id), COUNT(DISTINCT f.asset_id),
                   (SELECT a.locator FROM assets a JOIN faces f2 ON f2.asset_id=a.id
                    WHERE f2.cluster_id=c.id ORDER BY a.id LIMIT 1)
            FROM clusters c JOIN faces f ON f.cluster_id=c.id
            GROUP BY c.id ORDER BY COUNT(f.id) DESC, c.id
            """
        ).map { row in
            FaceCluster(
                id: row.int(0) ?? 0,
                name: row.text(1),
                faceCount: Int(row.int(2) ?? 0),
                assetCount: Int(row.int(3) ?? 0),
                sampleLocator: row.text(4)
            )
        }
    }

    /// Names a cluster and refreshes the people text of every asset it
    /// appears in, so search sees the name immediately.
    public func nameCluster(id: Int64, name: String) throws {
        guard try !db.query("SELECT id FROM clusters WHERE id=?", [.int(id)]).isEmpty else {
            throw PhotoIndexError.input("no cluster \(id) — `faces` lists them")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw PhotoIndexError.input("a name cannot be empty") }
        try db.run("UPDATE clusters SET name=? WHERE id=?", [.text(trimmed), .int(id)])
        try refreshPeople(clusterID: id)
    }

    func namedClusters() throws -> [(id: Int64, name: String)] {
        try db.query("SELECT id, name FROM clusters WHERE name IS NOT NULL").compactMap { row in
            guard let id = row.int(0), let name = row.text(1) else { return nil }
            return (id, name)
        }
    }

    private func refreshPeople(clusterID: Int64) throws {
        let assetIDs = try db.query(
            "SELECT DISTINCT asset_id FROM faces WHERE cluster_id=?", [.int(clusterID)]
        ).compactMap { $0.int(0) }
        for assetID in assetIDs {
            let names = try db.query(
                """
                SELECT DISTINCT c.name FROM faces f JOIN clusters c ON f.cluster_id=c.id
                WHERE f.asset_id=? AND c.name IS NOT NULL ORDER BY c.name
                """,
                [.int(assetID)]
            ).compactMap { $0.text(0) }
            try db.run("UPDATE content SET people=? WHERE rowid=?",
                       [.text(names.joined(separator: " ")), .int(assetID)])
        }
    }

    /// The clusters an asset's faces belong to.
    func clusterIDs(forAssetID id: Int64) throws -> Set<Int64> {
        Set(try db.query(
            "SELECT DISTINCT cluster_id FROM faces WHERE asset_id=? AND cluster_id IS NOT NULL",
            [.int(id)]
        ).compactMap { $0.int(0) })
    }

    /// Assets containing ALL of the given clusters, newest first.
    func assetsHavingClusters(_ ids: [Int64], kind: MediaKind?, limit: Int) throws -> [IndexedAsset] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var sql =
            """
            SELECT \(Self.assetColumns.split(separator: ",").map { "a.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", "))
            FROM assets a JOIN faces f ON f.asset_id=a.id
            WHERE f.cluster_id IN (\(placeholders))
            """
        var binds: [Database.Value] = ids.map { .int($0) }
        if let kind {
            sql += " AND a.kind=?"
            binds.append(.text(kind.rawValue))
        }
        sql += " GROUP BY a.id HAVING COUNT(DISTINCT f.cluster_id)=? ORDER BY a.created DESC, a.id DESC LIMIT ?"
        binds.append(.int(Int64(ids.count)))
        binds.append(.int(Int64(limit)))
        return try db.query(sql, binds).map(Self.makeAsset)
    }

    // MARK: - Search

    /// One FTS candidate with its stored text, for ranking and provenance.
    struct FTSRow {
        let assetID: Int64
        let bm25: Double
        let ocr: String
        let labels: String
        let transcript: String
        let people: String
        let place: String
    }

    /// The FTS candidates for a MATCH expression, best first. Column weights:
    /// words actually on screen beat guessed labels; spoken words and named
    /// people sit between.
    func ftsCandidates(match: String, limit: Int) throws -> [FTSRow] {
        try db.query(
            """
            SELECT rowid, bm25(content, 3.0, 1.5, 2.0, 2.0, 2.0), ocr, labels, transcript, people, place
            FROM content WHERE content MATCH ?
            ORDER BY bm25(content, 3.0, 1.5, 2.0, 2.0, 2.0) LIMIT ?
            """,
            [.text(match), .int(Int64(limit))]
        ).compactMap { row in
            guard let id = row.int(0) else { return nil }
            return FTSRow(
                assetID: id,
                bm25: row.real(1) ?? 0,
                ocr: row.text(2) ?? "",
                labels: row.text(3) ?? "",
                transcript: row.text(4) ?? "",
                people: row.text(5) ?? "",
                place: row.text(6) ?? ""
            )
        }
    }

    /// Folder videos still lacking a transcript, for a later --audio pass.
    func videosNeedingTranscript(source: SourceKind) throws -> [(id: Int64, locator: String)] {
        try db.query(
            "SELECT id, locator FROM assets WHERE source=? AND kind='video' AND has_transcript=0",
            [.text(source.rawValue)]
        ).compactMap { row in
            guard let id = row.int(0), let locator = row.text(1) else { return nil }
            return (id, locator)
        }
    }

    // MARK: - Places

    /// Assets holding coordinates but no geocoded place yet.
    public func assetsNeedingPlace(source: SourceKind? = nil) throws -> [(id: Int64, latitude: Double, longitude: Double)] {
        var sql = "SELECT id, latitude, longitude FROM assets WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND place IS NULL"
        var binds: [Database.Value] = []
        if let source {
            sql += " AND source=?"
            binds.append(.text(source.rawValue))
        }
        return try db.query(sql, binds).compactMap { row in
            guard let id = row.int(0), let latitude = row.real(1), let longitude = row.real(2) else { return nil }
            return (id, latitude, longitude)
        }
    }

    /// Writes a geocoded place onto an asset and into search.
    public func setPlace(assetID: Int64, place: String) throws {
        try db.run("UPDATE assets SET place=? WHERE id=?", [.text(place), .int(assetID)])
        try db.run("UPDATE content SET place=? WHERE rowid=?", [.text(place), .int(assetID)])
    }

    // MARK: - Catalog

    /// Everything the index knows, one entry per asset — what `report`
    /// renders. Filtered to a source or a folder prefix, capture order.
    public func catalog(source: SourceKind? = nil, pathPrefix: String? = nil) throws -> [CatalogEntry] {
        var sql = "SELECT \(Self.assetColumns) FROM assets"
        var clauses: [String] = []
        var binds: [Database.Value] = []
        if let source {
            clauses.append("source=?")
            binds.append(.text(source.rawValue))
        }
        if let pathPrefix {
            clauses.append("locator LIKE ?")
            binds.append(.text(pathPrefix + "%"))
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY created, id"

        var entries: [CatalogEntry] = []
        for row in try db.query(sql, binds) {
            let asset = Self.makeAsset(row)
            let labels: [Label] = try db.query(
                "SELECT label, confidence FROM labels WHERE asset_id=? ORDER BY confidence DESC, label",
                [.int(asset.id)]
            ).compactMap { r in
                guard let name = r.text(0), let confidence = r.real(1) else { return nil }
                return Label(name: name, confidence: confidence)
            }
            let content = try db.query(
                "SELECT ocr, transcript FROM content WHERE rowid=?", [.int(asset.id)]).first
            let people = try db.query(
                """
                SELECT DISTINCT c.name FROM faces f JOIN clusters c ON f.cluster_id=c.id
                WHERE f.asset_id=? AND c.name IS NOT NULL ORDER BY c.name
                """, [.int(asset.id)]
            ).compactMap { $0.text(0) }
            entries.append(CatalogEntry(
                asset: asset, labels: labels,
                ocr: content?.text(0) ?? "",
                transcript: content?.text(1) ?? "",
                people: people))
        }
        return entries
    }

    // MARK: - Status

    public func status() throws -> IndexStatus {
        func counts(_ sql: String) throws -> [String: Int] {
            var result: [String: Int] = [:]
            for row in try db.query(sql) {
                if let key = row.text(0), let count = row.int(1) { result[key] = Int(count) }
            }
            return result
        }
        func single(_ sql: String) throws -> Int {
            Int(try db.query(sql).first?.int(0) ?? 0)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return IndexStatus(
            assetCounts: try counts("SELECT kind, COUNT(*) FROM assets GROUP BY kind"),
            sourceCounts: try counts("SELECT source, COUNT(*) FROM assets GROUP BY source"),
            labelled: try single("SELECT COUNT(DISTINCT asset_id) FROM labels"),
            withPrints: try single("SELECT COUNT(*) FROM prints"),
            withTranscripts: try single("SELECT COUNT(*) FROM assets WHERE has_transcript=1"),
            faces: try single("SELECT COUNT(*) FROM faces"),
            clusters: try single("SELECT COUNT(DISTINCT cluster_id) FROM faces WHERE cluster_id IS NOT NULL"),
            namedClusters: try single("SELECT COUNT(*) FROM clusters WHERE name IS NOT NULL"),
            databaseBytes: bytes,
            databasePath: path
        )
    }
}
