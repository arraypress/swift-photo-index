//
//  IndexedAsset.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  One asset as the index knows it — the shape only. How a row becomes one of
//  these lives with the store; what a search does with one lives in the
//  search engine.
//

import Foundation

/// One indexed image or video.
public struct IndexedAsset: Sendable, Equatable, Codable {

    /// The index's own stable id.
    public let id: Int64

    /// Where the asset came from.
    public let source: SourceKind

    /// The absolute path (folder source) or `PHAsset` local identifier
    /// (photos source).
    public let locator: String

    /// What it is.
    public let kind: MediaKind

    /// When the picture was TAKEN: EXIF capture date where the file carries
    /// one, file creation date otherwise. Never the modification time —
    /// that lives beside it in ``modified``.
    public let created: Date?

    /// File modification time, where the source has one.
    public let modified: Date?

    /// Size in bytes, where known.
    public let byteSize: Int?

    /// Pixel dimensions, where known.
    public let width: Int?
    public let height: Int?

    /// Location, where the asset carries one.
    public let latitude: Double?
    public let longitude: Double?

    /// Video duration in seconds.
    public let duration: Double?

    /// The camera, from EXIF — "Apple iPhone 16 Pro" and the like.
    public let camera: String?

    /// The lens, from EXIF, where recorded.
    public let lens: String?

    /// The EXIF orientation value (1–8), where recorded.
    public let orientation: Int?

    /// A geocoded place name, only ever filled by an explicit `--geocode`
    /// pass — coordinates are captured regardless, so the offline story
    /// stays pure.
    public let place: String?

    /// How many faces detection found.
    public let faceCount: Int

    /// Whether the audio track has been transcribed into the index.
    public let hasTranscript: Bool

    public init(
        id: Int64, source: SourceKind, locator: String, kind: MediaKind,
        created: Date? = nil, modified: Date? = nil, byteSize: Int? = nil,
        width: Int? = nil, height: Int? = nil,
        latitude: Double? = nil, longitude: Double? = nil,
        duration: Double? = nil,
        camera: String? = nil, lens: String? = nil, orientation: Int? = nil,
        place: String? = nil,
        faceCount: Int = 0, hasTranscript: Bool = false
    ) {
        self.id = id
        self.source = source
        self.locator = locator
        self.kind = kind
        self.created = created
        self.modified = modified
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
        self.duration = duration
        self.camera = camera
        self.lens = lens
        self.orientation = orientation
        self.place = place
        self.faceCount = faceCount
        self.hasTranscript = hasTranscript
    }
}
