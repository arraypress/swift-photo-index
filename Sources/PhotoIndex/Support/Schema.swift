//
//  Schema.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The index's on-disk shape, versioned from day one. An index is a cache in
//  spirit but a database in practice: people will hold one across months of
//  releases, so the version check and the migration path exist before there
//  is anything to migrate.
//

import Foundation

enum Schema {

    /// The version this build writes.
    static let version = 2

    /// Everything a fresh index contains.
    static let creation: [String] = [
        """
        CREATE TABLE meta(
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE assets(
            id            INTEGER PRIMARY KEY,
            source        TEXT NOT NULL,
            locator       TEXT NOT NULL,
            fingerprint   TEXT NOT NULL,
            kind          TEXT NOT NULL,
            created       REAL,
            modified      REAL,
            byte_size     INTEGER,
            width         INTEGER,
            height        INTEGER,
            latitude      REAL,
            longitude     REAL,
            duration      REAL,
            camera        TEXT,
            lens          TEXT,
            orientation   INTEGER,
            place         TEXT,
            face_count    INTEGER NOT NULL DEFAULT 0,
            has_transcript INTEGER NOT NULL DEFAULT 0,
            indexed_at    REAL NOT NULL,
            UNIQUE(source, locator)
        )
        """,
        """
        CREATE TABLE labels(
            asset_id   INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            label      TEXT NOT NULL,
            confidence REAL NOT NULL
        )
        """,
        "CREATE INDEX labels_by_asset ON labels(asset_id)",
        """
        CREATE TABLE prints(
            asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
            data     BLOB NOT NULL
        )
        """,
        """
        CREATE TABLE faces(
            id         INTEGER PRIMARY KEY,
            asset_id   INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
            embedding  BLOB NOT NULL,
            cluster_id INTEGER
        )
        """,
        "CREATE INDEX faces_by_asset ON faces(asset_id)",
        "CREATE INDEX faces_by_cluster ON faces(cluster_id)",
        """
        CREATE TABLE clusters(
            id   INTEGER PRIMARY KEY,
            name TEXT
        )
        """,
        // The searchable text. rowid is the asset id, maintained by the store —
        // contentless FTS would forbid the delete-then-reinsert the updater uses.
        "CREATE VIRTUAL TABLE content USING fts5(ocr, labels, transcript, people, place)",
    ] + embeddingsTable

    /// The semantic vectors (schema 2): one per asset, float16, tagged with
    /// the model that made them so a different model re-embeds, never mixes.
    static let embeddingsTable: [String] = [
        """
        CREATE TABLE embeddings(
            asset_id INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
            model    TEXT NOT NULL,
            data     BLOB NOT NULL
        )
        """,
    ]

    /// Step migrations, keyed by the version they upgrade FROM.
    static let migrations: [Int: [String]] = [
        1: embeddingsTable,
    ]

    /// Opens the schema: creates it fresh, walks it forward, or refuses a
    /// database written by a newer build — silently misreading one would
    /// corrupt it.
    static func prepare(_ db: Database) throws {
        let hasMeta = try !db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'").isEmpty

        guard hasMeta else {
            for statement in creation { try db.exec(statement) }
            try db.run("INSERT INTO meta(key, value) VALUES('schema_version', ?)",
                       [.text(String(version))])
            return
        }

        let stored = try db.query("SELECT value FROM meta WHERE key='schema_version'")
            .first.flatMap { $0.text(0) }.flatMap(Int.init) ?? 0

        if stored == version { return }
        guard stored < version else {
            throw PhotoIndexError.storage(
                "this index was written by a newer build (schema \(stored), this build reads \(version)) — upgrade the tool, or delete the index to rebuild it")
        }
        var at = stored
        while at < version {
            guard let steps = migrations[at] else {
                throw PhotoIndexError.storage("no migration path from schema \(at)")
            }
            for statement in steps { try db.exec(statement) }
            at += 1
        }
        try db.run("UPDATE meta SET value=? WHERE key='schema_version'", [.text(String(version))])
    }
}
