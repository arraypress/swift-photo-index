//
//  Auditor.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The privacy audit: what is sitting in this library that its owner would
//  regret syncing, sharing or leaving on a sold machine? It reads almost
//  everything from the index the tool already built — OCR text, labels,
//  coordinates, faces — so the pass is a query, not an extraction. The two
//  exceptions go back to the files, cheaply and only for folder assets: an
//  ImageIO header read for serial numbers and owner fields the index does
//  not store, and a document-recognition look at images whose OCR is dense.
//
//  Photos-library assets get the index-only findings: their file-level
//  passes would need full image-data requests through PhotoKit, which is a
//  cost this pass deliberately does not incur. The CLI says so out loud.
//

import Foundation
import ImageIO
import SecretScanner
import Vision

/// The audit pass over an index.
public struct Auditor {

    public struct Options: Sendable {
        /// Restrict to one source, or audit everything.
        public var source: SourceKind?
        /// Restrict folder assets to this path prefix.
        public var pathPrefix: String?
        /// Findings below this are dropped.
        public var minimumSeverity: AuditSeverity
        /// Run document recognition on dense-OCR folder images.
        public var scanDocuments: Bool
        /// Read serial/owner metadata from folder image files.
        public var scanFileMetadata: Bool

        public init(source: SourceKind? = nil, pathPrefix: String? = nil,
                    minimumSeverity: AuditSeverity = .medium,
                    scanDocuments: Bool = true, scanFileMetadata: Bool = true) {
            self.source = source
            self.pathPrefix = pathPrefix
            self.minimumSeverity = minimumSeverity
            self.scanDocuments = scanDocuments
            self.scanFileMetadata = scanFileMetadata
        }
    }

    private let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    /// Runs the audit. Findings come back most severe first, and every
    /// excerpt is already masked — safe to print as-is.
    public func run(options: Options = Options()) async throws -> [AuditFinding] {
        let entries = try store.catalog(source: options.source, pathPrefix: options.pathPrefix)
        var findings: [AuditFinding] = []

        // Concrete patterns only: entropy-based generic rules are tuned for
        // source code, and OCR text is exactly the noise they false-fire on.
        let secretScanner = SecretScanner(generic: false)

        for entry in entries {
            let locator = entry.asset.locator
            let source = entry.asset.source

            if !entry.ocr.isEmpty {
                for card in AuditRules.cardFindings(in: entry.ocr) {
                    findings.append(AuditFinding(
                        category: .card, severity: .high, locator: locator, source: source,
                        why: "a \(card.network ?? "payment-card")-shaped number in the pixels passes its checksum",
                        excerpt: card.masked))
                }
                for passport in AuditRules.passportFindings(in: entry.ocr) {
                    findings.append(AuditFinding(
                        category: .passport, severity: .high, locator: locator, source: source,
                        why: "a passport machine-readable zone with three valid check digits",
                        excerpt: passport))
                }
                for iban in AuditRules.ibanFindings(in: entry.ocr) {
                    findings.append(AuditFinding(
                        category: .iban, severity: .medium, locator: locator, source: source,
                        why: "an IBAN in the pixels passes mod-97", excerpt: iban))
                }
                for secret in secretScanner.scan(entry.ocr, path: locator) {
                    findings.append(AuditFinding(
                        category: .secret, severity: .high, locator: locator, source: source,
                        why: "\(secret.name) readable in the pixels", excerpt: secret.masked))
                }
                for ssn in AuditRules.ssnFindings(in: entry.ocr) {
                    findings.append(AuditFinding(
                        category: .ssn, severity: .high, locator: locator, source: source,
                        why: "a social-security-shaped number in the pixels", excerpt: ssn))
                }
                for email in AuditRules.emailFindings(in: entry.ocr) {
                    findings.append(AuditFinding(
                        category: .contact, severity: .low, locator: locator, source: source,
                        why: "an email address readable in the pixels", excerpt: email))
                }
                for phone in AuditRules.phoneFindings(in: entry.ocr) {
                    findings.append(AuditFinding(
                        category: .contact, severity: .low, locator: locator, source: source,
                        why: "a phone number readable in the pixels", excerpt: phone))
                }
            }

            if entry.asset.faceCount > 0 {
                let named = entry.people.isEmpty ? "" : " (\(entry.people.joined(separator: ", ")))"
                findings.append(AuditFinding(
                    category: .faces, severity: .low, locator: locator, source: source,
                    why: "\(entry.asset.faceCount) face\(entry.asset.faceCount == 1 ? "" : "s") present\(named)"))
            }
        }

        findings.append(contentsOf: locationFindings(entries))

        // The two passes that go back to the files — folder assets only.
        let folderImages = entries.filter {
            $0.asset.source == .folder && $0.asset.kind != .video
                && FileManager.default.fileExists(atPath: $0.asset.locator)
        }
        if options.scanFileMetadata {
            for entry in folderImages {
                findings.append(contentsOf: fileMetadataFindings(entry.asset))
            }
        }
        if options.scanDocuments {
            for entry in folderImages where entry.ocr.count >= 80 {
                if let finding = await documentFinding(entry.asset) {
                    findings.append(finding)
                }
            }
        }

        return findings
            .filter { $0.severity >= options.minimumSeverity }
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
                return $0.locator < $1.locator
            }
    }

    // MARK: - Location

    /// Every asset with coordinates near the library's densest spot is the
    /// highest-value location finding: publish one of those and you have
    /// published where you live. The rest are noted at low severity.
    private func locationFindings(_ entries: [CatalogEntry]) -> [AuditFinding] {
        let located = entries.compactMap { entry -> (CatalogEntry, (lat: Double, lon: Double))? in
            guard let lat = entry.asset.latitude, let lon = entry.asset.longitude else { return nil }
            return (entry, (lat, lon))
        }
        let home = AuditRules.homeCluster(located.map(\.1))
        var findings: [AuditFinding] = []
        for (entry, coordinate) in located {
            if let home, AuditRules.meters(from: coordinate, to: home) <= 100 {
                findings.append(AuditFinding(
                    category: .homeLocation, severity: .high,
                    locator: entry.asset.locator, source: entry.asset.source,
                    why: "GPS within 100 m of the library's most-photographed spot — likely home"))
            } else {
                findings.append(AuditFinding(
                    category: .location, severity: .low,
                    locator: entry.asset.locator, source: entry.asset.source,
                    why: "carries GPS coordinates"))
            }
        }
        return findings
    }

    // MARK: - File metadata (folder assets)

    /// Serial numbers and owner fields never make it into the index; a
    /// header read per flagged file is cheap and stays on this machine.
    private func fileMetadataFindings(_ asset: IndexedAsset) -> [AuditFinding] {
        let url = URL(fileURLWithPath: asset.locator)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return [] }

        var findings: [AuditFinding] = []
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]

        for (key, label) in [(kCGImagePropertyExifBodySerialNumber, "camera body"),
                             (kCGImagePropertyExifLensSerialNumber, "lens")] {
            if let serial = exif?[key] as? String, !serial.isEmpty {
                findings.append(AuditFinding(
                    category: .serial, severity: .medium,
                    locator: asset.locator, source: asset.source,
                    why: "a \(label) serial number in the file's metadata links photos across accounts",
                    excerpt: AuditRules.maskKeepingSuffix(serial)))
            }
        }
        let owners = [tiff?[kCGImagePropertyTIFFArtist], tiff?[kCGImagePropertyTIFFCopyright],
                      iptc?[kCGImagePropertyIPTCByline]]
        for case let name as String in owners where !name.isEmpty {
            findings.append(AuditFinding(
                category: .owner, severity: .medium,
                locator: asset.locator, source: asset.source,
                why: "an owner name in the file's metadata",
                excerpt: String(name.prefix(1)) + "•••"))
            break
        }
        return findings
    }

    // MARK: - Documents (folder assets)

    /// A photographed document is a finding in itself, whatever it says.
    private func documentFinding(_ asset: IndexedAsset) async -> AuditFinding? {
        let request = RecognizeDocumentsRequest()
        guard let observations = try? await request.perform(
            on: URL(fileURLWithPath: asset.locator)), !observations.isEmpty
        else { return nil }
        return AuditFinding(
            category: .document, severity: .medium,
            locator: asset.locator, source: asset.source,
            why: "reads as a photographed document")
    }
}
