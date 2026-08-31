//
//  MediaKind.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//

/// What an indexed asset is.
///
/// A screenshot is a kind of its own rather than a flag on an image because it
/// is the single most-filtered category — "find the screenshot where the error
/// said X" — and a first-class kind keeps that filter one word everywhere.
public enum MediaKind: String, Sendable, CaseIterable, Codable {
    /// A photograph or other picture.
    case image
    /// A screen capture, decided by ``ScreenshotRule``.
    case screenshot
    /// A video.
    case video
}
