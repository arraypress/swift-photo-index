//
//  SourceKind.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//

/// Where an asset came from.
///
/// The index is deliberately source-agnostic — extractors and search never
/// know which of these fed them — but the record keeps its origin so a source
/// can be re-walked or forgotten as a unit.
public enum SourceKind: String, Sendable, Codable {
    /// A folder walked on disk; the locator is an absolute path.
    case folder
    /// The Apple Photos library; the locator is a `PHAsset` local identifier.
    case photos
}
