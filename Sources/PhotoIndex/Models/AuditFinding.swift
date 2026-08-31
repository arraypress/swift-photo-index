//
//  AuditFinding.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  What a privacy audit reports — the shape only. Every rule that decides
//  a finding exists lives in Support/AuditRules; the pass that applies them
//  lives in Core/Auditor. A finding never carries the sensitive value it
//  describes: the excerpt is masked at construction and there is no other
//  field to leak through.
//

import Foundation

/// What kind of sensitive thing was found.
public enum AuditCategory: String, Sendable, Codable, CaseIterable {
    /// A number shaped like a payment card that passes its checksum.
    case card
    /// A passport machine-readable zone whose check digits validate.
    case passport
    /// An IBAN that passes mod-97.
    case iban
    /// An API key or token, by the secret scanner's rules.
    case secret
    /// A social security number pattern.
    case ssn
    /// An email address or phone number in the pixels.
    case contact
    /// GPS within ~100 m of the library's densest location — likely home.
    case homeLocation
    /// GPS coordinates present at all.
    case location
    /// The photo reads as a photographed document.
    case document
    /// Faces are present (and possibly named).
    case faces
    /// A camera body or lens serial number in the file's metadata.
    case serial
    /// An owner, artist or copyright name in the file's metadata.
    case owner
}

/// How urgently a finding deserves a look.
public enum AuditSeverity: String, Sendable, Codable, CaseIterable, Comparable {
    case low, medium, high

    public static func < (a: AuditSeverity, b: AuditSeverity) -> Bool {
        let order: [AuditSeverity] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// One thing the audit found, already safe to print: the excerpt is masked
/// and the full matched value is nowhere in the structure.
public struct AuditFinding: Sendable, Codable, Equatable {

    public let category: AuditCategory
    public let severity: AuditSeverity

    /// The asset it was found in.
    public let locator: String
    public let source: SourceKind

    /// Why this is a finding, as a sentence.
    public let why: String

    /// A masked glimpse — `••••4242`, `P<IRL•••` — never the value itself.
    public let excerpt: String?

    public init(category: AuditCategory, severity: AuditSeverity,
                locator: String, source: SourceKind, why: String, excerpt: String? = nil) {
        self.category = category
        self.severity = severity
        self.locator = locator
        self.source = source
        self.why = why
        self.excerpt = excerpt
    }
}
