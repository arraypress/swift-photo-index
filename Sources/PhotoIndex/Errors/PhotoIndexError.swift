//
//  PhotoIndexError.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Failures the index can report.
public enum PhotoIndexError: Error, Sendable, LocalizedError {

    /// The SQLite store failed — the message carries sqlite's own words.
    case storage(String)

    /// A Vision or AVFoundation pass failed on one asset.
    case extraction(String)

    /// Photos access is not available; the message says which state and what
    /// to do about it.
    case photosAccess(String)

    /// The caller handed something unusable — a missing file, an unreadable
    /// image, an unknown cluster.
    case input(String)

    /// The semantic model is missing, incomplete or failed to run.
    case model(String)

    public var errorDescription: String? {
        switch self {
        case .storage(let message): return "index store: \(message)"
        case .extraction(let message): return "extraction: \(message)"
        case .photosAccess(let message): return message
        case .input(let message): return message
        case .model(let message): return "semantic model: \(message)"
        }
    }
}
