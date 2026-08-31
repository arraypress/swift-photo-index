//
//  IncrementalDiff.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  What one indexing run must do, decided purely. The whole promise of the
//  tool — re-index touches only what changed — is this comparison, so it
//  lives alone where a test can hand it descriptors and count exactly what
//  comes back.
//

import Foundation

/// The work a source walk implies.
struct SourceDiff: Equatable {
    /// Present in the source, absent from the store.
    let added: [AssetDescriptor]
    /// Present in both, fingerprint changed.
    let updated: [AssetDescriptor]
    /// In the store, gone from the source.
    let removedLocators: [String]
    /// Present in both, untouched.
    let unchangedLocators: [String]
}

enum IncrementalDiff {

    /// Compares a source's current descriptors against the stored
    /// locator → fingerprint map.
    static func diff(current: [AssetDescriptor], stored: [String: String]) -> SourceDiff {
        var added: [AssetDescriptor] = []
        var updated: [AssetDescriptor] = []
        var unchanged: [String] = []
        var remaining = stored

        for descriptor in current {
            if let storedFingerprint = remaining.removeValue(forKey: descriptor.locator) {
                if storedFingerprint == descriptor.fingerprint {
                    unchanged.append(descriptor.locator)
                } else {
                    updated.append(descriptor)
                }
            } else {
                added.append(descriptor)
            }
        }

        return SourceDiff(
            added: added,
            updated: updated,
            removedLocators: remaining.keys.sorted(),
            unchangedLocators: unchanged
        )
    }
}
