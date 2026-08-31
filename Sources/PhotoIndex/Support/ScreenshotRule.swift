//
//  ScreenshotRule.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Deciding that an image is a screenshot — one pure rule, because the
//  answer feeds the most-used filter in the tool and a fuzzy heuristic here
//  would make `--kind screenshot` untrustworthy. Photos knows outright (the
//  asset subtype); on disk the filename is the honest signal, and nothing
//  subtler is attempted.
//

import Foundation

enum ScreenshotRule {

    /// The stored kind for an asset.
    static func kind(media: MediaKind, filename: String?, photoLibrarySaysScreenshot: Bool) -> MediaKind {
        guard media == .image else { return media }
        if photoLibrarySaysScreenshot { return .screenshot }
        if let filename, nameLooksLikeScreenshot(filename) { return .screenshot }
        return .image
    }

    /// Whether a filename says screenshot: macOS ("Screenshot 2026-08-31…",
    /// older "Screen Shot…"), iOS imports ("IMG_… (screenshot)"), and the
    /// Simulator's exports. Case-insensitive; anything containing the word
    /// counts, because people rename but keep the word.
    static func nameLooksLikeScreenshot(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("screenshot") || lowered.contains("screen shot")
    }
}
