//
//  CatalogEntry.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  One asset with everything the index knows about it — the shape the
//  `report` verb renders from. Assembled by the store; rendered elsewhere.
//

import Foundation

/// One asset's full index record.
public struct CatalogEntry: Sendable, Equatable, Codable {

    public let asset: IndexedAsset

    /// Scene and object labels, best first.
    public let labels: [Label]

    /// Everything OCR read, newline-joined.
    public let ocr: String

    /// The transcribed speech, empty when none.
    public let transcript: String

    /// Named people whose faces appear, sorted.
    public let people: [String]

    public init(asset: IndexedAsset, labels: [Label], ocr: String, transcript: String, people: [String]) {
        self.asset = asset
        self.labels = labels
        self.ocr = ocr
        self.transcript = transcript
        self.people = people
    }
}
