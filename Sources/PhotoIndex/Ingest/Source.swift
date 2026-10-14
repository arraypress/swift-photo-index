//
//  Source.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The seam the whole design hangs on: a source names its assets cheaply
//  (descriptors), and loads one expensively on demand. The indexer diffs
//  descriptors against the store and loads only what changed — so a source
//  never needs to know what an index is, and the index never knows whether
//  an asset came from a folder or the Photos library.
//

import CoreGraphics
import Foundation

/// The cheap identity of one asset: enough to decide whether work is needed.
public struct AssetDescriptor: Sendable, Equatable {

    /// Absolute path (folder) or `PHAsset` local identifier (photos).
    public let locator: String

    /// A stamp that changes when the asset's bytes change — mtime:size on
    /// disk, the modification date in Photos.
    public let fingerprint: String

    public init(locator: String, fingerprint: String) {
        self.locator = locator
        self.fingerprint = fingerprint
    }
}

/// One asset loaded for extraction.
public struct LoadedAsset {

    public let descriptor: AssetDescriptor

    /// Image or video; ``ScreenshotRule`` refines image later.
    public let media: MediaKind

    /// True when the source itself knows this is a screenshot (Photos does).
    public let screenshotHint: Bool

    /// The capture date — EXIF where the file carries one, creation
    /// otherwise. The file mtime goes in ``modified``, never here.
    public let created: Date?
    public let modified: Date?
    public let byteSize: Int?
    public let width: Int?
    public let height: Int?
    public let latitude: Double?
    public let longitude: Double?

    /// EXIF camera, lens and orientation, where the source reads them.
    public let camera: String?
    public let lens: String?
    public let orientation: Int?

    /// A bitmap ready for Vision — downsized, orientation applied. Nil for
    /// videos, whose frames come from ``VideoSampling``.
    public let cgImage: CGImage?

    /// A local file for a video's frames and audio. Nil when the source
    /// cannot provide one (an offloaded original with networking off).
    public let videoFileURL: URL?

    public init(
        descriptor: AssetDescriptor, media: MediaKind, screenshotHint: Bool = false,
        created: Date? = nil, modified: Date? = nil, byteSize: Int? = nil,
        width: Int? = nil, height: Int? = nil,
        latitude: Double? = nil, longitude: Double? = nil,
        camera: String? = nil, lens: String? = nil, orientation: Int? = nil,
        cgImage: CGImage? = nil, videoFileURL: URL? = nil
    ) {
        self.descriptor = descriptor
        self.media = media
        self.screenshotHint = screenshotHint
        self.created = created
        self.modified = modified
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
        self.camera = camera
        self.lens = lens
        self.orientation = orientation
        self.cgImage = cgImage
        self.videoFileURL = videoFileURL
    }
}

/// Somewhere assets come from.
public protocol AssetSource {

    /// Which kind of source this is; stored on every asset it yields.
    var kind: SourceKind { get }

    /// Every asset the source can currently see, cheaply.
    func descriptors() async throws -> [AssetDescriptor]

    /// One asset, loaded for extraction.
    func load(_ descriptor: AssetDescriptor) async throws -> LoadedAsset

    /// Whether a stored locator lies inside what this source walks. Only
    /// those can be judged missing: indexing one folder must not forget
    /// another folder indexed earlier.
    func covers(_ locator: String) -> Bool
}

extension AssetSource {
    /// A source that sees everything of its kind (the Photos library).
    public func covers(_ locator: String) -> Bool { true }
}
