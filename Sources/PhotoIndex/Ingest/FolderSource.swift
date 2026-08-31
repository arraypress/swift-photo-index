//
//  FolderSource.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Assets from folders on disk. This is the foundation the tests stand on —
//  it needs no permission, so everything above it can be proven headlessly.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Images and videos found by walking folders.
public final class FolderSource: AssetSource {

    /// Image extensions worth indexing (lowercase).
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]

    /// Video extensions worth indexing (lowercase).
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// The longest edge handed to Vision. Extraction quality plateaus well
    /// below original size, and thumbnails keep a big library's first index
    /// from decoding gigapixels.
    public static let maxPixelSize = 1600

    public let kind: SourceKind = .folder

    private let roots: [URL]

    /// - Parameter paths: Files or folders; folders are walked recursively.
    public init(paths: [String]) {
        self.roots = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
    }

    public func descriptors() async throws -> [AssetDescriptor] {
        let manager = FileManager.default
        var found: [AssetDescriptor] = []

        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                throw PhotoIndexError.input("no such file or folder: \(root.path)")
            }
            if !isDirectory.boolValue {
                if let descriptor = Self.descriptor(for: root) { found.append(descriptor) }
                continue
            }
            found.append(contentsOf: Self.walk(root))
        }
        // Stable order: the filesystem's is whatever it felt like.
        return found.sorted { $0.locator < $1.locator }
    }

    /// Walks one folder synchronously — a directory enumerator cannot be
    /// for-in'd from an async context under Swift 6.2.
    private static func walk(_ root: URL) -> [AssetDescriptor] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [AssetDescriptor] = []
        while let next = walker.nextObject() as? URL {
            if let descriptor = descriptor(for: next) { found.append(descriptor) }
        }
        return found
    }

    public func load(_ descriptor: AssetDescriptor) async throws -> LoadedAsset {
        let url = URL(fileURLWithPath: descriptor.locator)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue

        if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
            return LoadedAsset(
                descriptor: descriptor, media: .video,
                created: attributes?[.creationDate] as? Date,
                modified: modified, byteSize: size,
                videoFileURL: url
            )
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoIndexError.input("cannot read image: \(url.path)")
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PhotoIndexError.input("cannot decode image: \(url.path)")
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let gps = properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let latitude = Self.coordinate(gps, kCGImagePropertyGPSLatitude, ref: kCGImagePropertyGPSLatitudeRef, negative: "S")
        let longitude = Self.coordinate(gps, kCGImagePropertyGPSLongitude, ref: kCGImagePropertyGPSLongitudeRef, negative: "W")

        // EXIF: the capture date is the date that matters — a photo copied
        // between machines keeps it while every file date churns.
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let aux = properties?[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let taken = EXIFFields.parseDate(exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? EXIFFields.parseDate(tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let camera = EXIFFields.cameraName(
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String)
        let lens = (aux?[kCGImagePropertyExifAuxLensModel] as? String)
            ?? (exif?[kCGImagePropertyExifLensModel] as? String)
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        return LoadedAsset(
            descriptor: descriptor, media: .image,
            created: taken ?? attributes?[.creationDate] as? Date,
            modified: modified, byteSize: size,
            width: width, height: height,
            latitude: latitude, longitude: longitude,
            camera: camera, lens: lens, orientation: orientation,
            cgImage: image
        )
    }

    // MARK: - Details

    static func descriptor(for url: URL) -> AssetDescriptor? {
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return AssetDescriptor(
            locator: url.standardizedFileURL.path,
            fingerprint: "\(Int(mtime)):\(size)"
        )
    }

    private static func coordinate(
        _ gps: [CFString: Any]?, _ key: CFString, ref: CFString, negative: String
    ) -> Double? {
        guard let value = (gps?[key] as? NSNumber)?.doubleValue else { return nil }
        let reference = gps?[ref] as? String
        return reference == negative ? -value : value
    }
}
