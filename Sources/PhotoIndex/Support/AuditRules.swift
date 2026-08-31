//
//  AuditRules.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  Every rule the privacy audit applies, pure and pinned: what counts as a
//  card number, a machine-readable zone, an IBAN, a contact detail, and
//  where "home" is in a pile of coordinates. Nothing here touches the
//  store, a file, or Vision — a test feeds strings and numbers and reads
//  findings back, which is the only way rules about SENSITIVE data can be
//  tested without ever holding any.
//

import CreditCardValidator
import Foundation

enum AuditRules {

    // MARK: - Masking

    /// The last four characters survive; everything else is dots. The
    /// audit's one promise is that a finding can be printed anywhere.
    static func maskKeepingSuffix(_ value: String, keep: Int = 4) -> String {
        let chars = Array(value)
        guard chars.count > keep else { return String(repeating: "•", count: chars.count) }
        return "••••" + String(chars.suffix(keep))
    }

    // MARK: - Payment cards

    /// Runs of 13–19 digits, tolerating the single spaces or dashes cards
    /// are printed with. Deduplicated, order kept.
    static func cardCandidates(in text: String) -> [String] {
        var results: [String] = []
        var seen: Set<String> = []
        var digits = ""
        var pendingSeparator = false

        func flush() {
            if (13...19).contains(digits.count), !seen.contains(digits) {
                seen.insert(digits)
                results.append(digits)
            }
            digits = ""
            pendingSeparator = false
        }

        for character in text {
            if character.isASCII && character.isNumber {
                digits.append(character)
                pendingSeparator = false
            } else if (character == " " || character == "-"), !digits.isEmpty, !pendingSeparator {
                pendingSeparator = true
            } else {
                flush()
            }
        }
        flush()
        return results
    }

    /// Candidates that pass Luhn, with the card network when it is
    /// recognisable and only the last four digits surviving.
    static func cardFindings(in text: String) -> [(masked: String, network: String?)] {
        cardCandidates(in: text)
            .filter { CreditCardValidator.validate($0) }
            .map { (maskKeepingSuffix($0), CreditCardValidator.detectType($0)?.rawValue) }
    }

    // MARK: - Passport MRZ (TD3)

    /// The ICAO 7-3-1 check digit over `0-9`, `A-Z` (10–35) and `<` (0).
    static func mrzCheckDigit<S: StringProtocol>(_ field: S) -> Int? {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, character) in field.enumerated() {
            let value: Int
            switch character {
            case "<": value = 0
            case "0"..."9": value = character.wholeNumberValue!
            case "A"..."Z": value = Int(character.asciiValue! - Character("A").asciiValue!) + 10
            default: return nil
            }
            sum += value * weights[index % 3]
        }
        return sum % 10
    }

    /// Confirmed passport zones in OCR text: a 44-character TD3 second line
    /// whose document-number, birth-date and expiry check digits all
    /// validate. Three passing checksums do not happen to noise. The masked
    /// form keeps only the nationality: `P<IRL•••`.
    static func passportFindings(in text: String) -> [String] {
        var masked: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            // OCR likes to space out monospaced zones; the zone itself never
            // contains spaces.
            let line = rawLine.uppercased().filter { $0 != " " }
            guard line.count == 44,
                  line.allSatisfy({ $0 == "<" || ("A"..."Z").contains($0) || $0.isNumber })
            else { continue }
            let chars = Array(line)
            func slice(_ range: Range<Int>) -> String { String(chars[range]) }
            guard
                let docCheck = mrzCheckDigit(slice(0..<9)),
                docCheck == chars[9].wholeNumberValue,
                let dobCheck = mrzCheckDigit(slice(13..<19)),
                dobCheck == chars[19].wholeNumberValue,
                let expiryCheck = mrzCheckDigit(slice(21..<27)),
                expiryCheck == chars[27].wholeNumberValue
            else { continue }
            masked.append("P<" + slice(10..<13) + "•••")
        }
        return masked
    }

    // MARK: - IBAN

    /// Per-country IBAN lengths (the SEPA area and neighbours). Flattening
    /// the text glues neighbouring words onto a candidate, so the country's
    /// registered length — not the regex — decides where an IBAN ends.
    static let ibanLengths: [String: Int] = [
        "AT": 18, "BE": 16, "CH": 21, "CZ": 24, "DE": 22, "DK": 18, "EE": 20,
        "ES": 24, "FI": 18, "FR": 27, "GB": 22, "GR": 27, "HR": 21, "HU": 28,
        "IE": 22, "IS": 26, "IT": 27, "LI": 21, "LT": 20, "LU": 20, "LV": 21,
        "MC": 27, "NL": 18, "NO": 15, "PL": 28, "PT": 25, "RO": 24, "SE": 24,
        "SI": 19, "SK": 24,
    ]

    /// IBANs in the text, spaces tolerated (they are printed in groups of
    /// four), cut to the country's registered length and confirmed by
    /// mod-97. Masked to country and tail: `GB82•••5432`.
    static func ibanFindings(in text: String) -> [String] {
        let flattened = text.uppercased().replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: "[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}") else { return [] }
        let range = NSRange(flattened.startIndex..., in: flattened)
        var results: [String] = []
        var seen: Set<String> = []
        for match in regex.matches(in: flattened, range: range) {
            guard let matchRange = Range(match.range, in: flattened) else { continue }
            let run = String(flattened[matchRange])
            guard let length = ibanLengths[String(run.prefix(2))], run.count >= length else { continue }
            let candidate = String(run.prefix(length))
            guard ibanIsValid(candidate), !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            results.append(String(candidate.prefix(4)) + "•••" + String(candidate.suffix(4)))
        }
        return results
    }

    /// ISO 13616: first four characters to the end, letters as two digits,
    /// the whole number ≡ 1 (mod 97). Folded a character at a time so no
    /// big-integer type is needed.
    static func ibanIsValid(_ candidate: String) -> Bool {
        guard candidate.count >= 15, candidate.count <= 34 else { return false }
        let rearranged = candidate.dropFirst(4) + candidate.prefix(4)
        var remainder = 0
        for character in rearranged {
            if let digit = character.wholeNumberValue, character.isNumber {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = character.asciiValue, ("A"..."Z").contains(character) {
                let value = Int(ascii - Character("A").asciiValue!) + 10
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    // MARK: - Contact details and SSNs

    /// Dashed social security numbers — the undashed form is nine ordinary
    /// digits and would flag every phone number and order id in the library.
    static func ssnFindings(in text: String) -> [String] {
        matches("\\b[0-9]{3}-[0-9]{2}-[0-9]{4}\\b", in: text)
            .map { "•••-••-" + $0.suffix(4) }
    }

    /// Email addresses, masked to their domain: `d•••@example.com`.
    static func emailFindings(in text: String) -> [String] {
        matches("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", in: text).map { address in
            let parts = address.split(separator: "@", maxSplits: 1)
            let first = parts[0].prefix(1)
            return "\(first)•••@\(parts.count > 1 ? String(parts[1]) : "")"
        }
    }

    /// International-format phone numbers only — bare digit runs are order
    /// numbers and timestamps far more often than they are phones.
    static func phoneFindings(in text: String) -> [String] {
        matches("\\+[0-9][0-9 ()\\-]{6,18}[0-9]", in: text)
            .map { String($0.prefix(4)) + "•••" }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        var results: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let value = String(text[matchRange])
            if seen.insert(value).inserted { results.append(value) }
        }
        return results
    }

    // MARK: - Where home is

    /// The densest ~100 m grid cell across every coordinate in the library,
    /// as a centroid — presumptively home. Needs `minimumCount` sightings:
    /// three photos somewhere are a visit, not a residence.
    static func homeCluster(
        _ coordinates: [(lat: Double, lon: Double)], minimumCount: Int = 5
    ) -> (lat: Double, lon: Double)? {
        guard coordinates.count >= minimumCount else { return nil }
        var buckets: [String: [(lat: Double, lon: Double)]] = [:]
        for coordinate in coordinates {
            let key = "\(Int((coordinate.lat / 0.001).rounded()))|\(Int((coordinate.lon / 0.001).rounded()))"
            buckets[key, default: []].append(coordinate)
        }
        guard let densest = buckets.values.max(by: { $0.count < $1.count }),
              densest.count >= minimumCount else { return nil }
        let lat = densest.map(\.lat).reduce(0, +) / Double(densest.count)
        let lon = densest.map(\.lon).reduce(0, +) / Double(densest.count)
        return (lat, lon)
    }

    /// Great-circle distance in metres — haversine, more than accurate
    /// enough at the hundred-metre scale the audit reasons at.
    static func meters(
        from a: (lat: Double, lon: Double), to b: (lat: Double, lon: Double)
    ) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
}
