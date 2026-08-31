//
//  PhotoKitSource.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Assets from the Apple Photos library, through PhotoKit and nothing else —
//  the .photoslibrary bundle is opaque on purpose and walking inside it
//  would corrupt what Photos believes about its own store. This source can
//  only be exercised with a Photos grant, which a headless run does not
//  have; its pure bookkeeping is tested through the same diffing every
//  source shares, and the live path is verified interactively.
//

import CoreGraphics
import Foundation
import ImageIO
import Photos

/// Images and videos from the user's Photos library.
public final class PhotoKitSource: AssetSource {

    /// The access states a caller has to speak about.
    public enum Access: String, Sendable {
        case authorized
        case limited
        case denied
        case notDetermined
    }

    /// Current Photos read access, without prompting.
    public static func authorization() -> Access {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Asks the system for access, showing the consent dialog when the state
    /// is not yet determined. Only meaningful in an interactive session.
    public static func requestAccess() async -> Access {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return authorization()
    }

    public let kind: SourceKind = .photos

    /// When true, an original that only exists in iCloud is skipped rather
    /// than downloaded.
    private let localOnly: Bool

    public init(localOnly: Bool = false) {
        self.localOnly = localOnly
    }

    public func descriptors() async throws -> [AssetDescriptor] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetched = PHAsset.fetchAssets(with: options)
        var descriptors: [AssetDescriptor] = []
        descriptors.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            let stamp = asset.modificationDate ?? asset.creationDate
            descriptors.append(AssetDescriptor(
                locator: asset.localIdentifier,
                fingerprint: String(Int(stamp?.timeIntervalSince1970 ?? 0))
            ))
        }
        return descriptors
    }

    public func load(_ descriptor: AssetDescriptor) async throws -> LoadedAsset {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.locator], options: nil)
        guard let asset = fetched.firstObject else {
            throw PhotoIndexError.input("asset no longer in the library: \(descriptor.locator)")
        }

        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        let location = asset.location?.coordinate

        if asset.mediaType == .video {
            let url = await videoURL(for: asset)
            return LoadedAsset(
                descriptor: descriptor, media: .video, screenshotHint: false,
                created: asset.creationDate, modified: asset.modificationDate,
                width: asset.pixelWidth, height: asset.pixelHeight,
                latitude: location?.latitude, longitude: location?.longitude,
                videoFileURL: url
            )
        }

        let loadedImage = await requestImage(for: asset)
        guard let loadedImage else {
            throw PhotoIndexError.input(localOnly
                ? "original is in iCloud and --local-only is set: \(descriptor.locator)"
                : "Photos returned no image for: \(descriptor.locator)")
        }
        return LoadedAsset(
            descriptor: descriptor, media: .image, screenshotHint: isScreenshot,
            created: asset.creationDate, modified: asset.modificationDate,
            width: asset.pixelWidth, height: asset.pixelHeight,
            latitude: location?.latitude, longitude: location?.longitude,
            camera: loadedImage.camera, lens: loadedImage.lens,
            orientation: loadedImage.orientation,
            cgImage: loadedImage.image
        )
    }

    // MARK: - PhotoKit plumbing

    /// One decoded image with the EXIF the same bytes carry — the folder
    /// source reads these off disk; reading them here too is what keeps
    /// `camera:` searchable regardless of where a photo lives.
    private struct LoadedImage {
        let image: CGImage
        let camera: String?
        let lens: String?
        let orientation: Int?
    }

    private func requestImage(for asset: PHAsset) async -> LoadedImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = !localOnly
        let data: Data? = await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                // One delivery is promised for a data request, but the
                // contract is soft enough to guard: resuming twice traps.
                guard resumed.claim() else { return }
                continuation.resume(returning: data)
            }
        }
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              // The same decode FolderSource uses, so both sources hand
              // Vision the same kind of pixels.
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: FolderSource.maxPixelSize,
              ] as CFDictionary)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = properties?[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        return LoadedImage(
            image: image,
            camera: EXIFFields.cameraName(
                make: tiff?[kCGImagePropertyTIFFMake] as? String,
                model: tiff?[kCGImagePropertyTIFFModel] as? String),
            lens: (aux?[kCGImagePropertyExifAuxLensModel] as? String)
                ?? (exif?[kCGImagePropertyExifLensModel] as? String),
            orientation: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue)
    }

    private func videoURL(for asset: PHAsset) async -> URL? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = !localOnly
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard resumed.claim() else { return }
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }
}

/// A claim ticket a completion handler can only cash once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
