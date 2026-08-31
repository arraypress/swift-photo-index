//
//  EXIFFields.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The two EXIF interpretation rules, pure and pinned: the colon-date
//  format, and how a camera's make and model become one name. ImageIO hands
//  over the raw strings; nothing here touches a file.
//

import Foundation

enum EXIFFields {

    /// An EXIF date — `2026:08:31 20:15:03` — as a Date in the local zone,
    /// which is what EXIF means by it (the format carries no zone).
    /// Sub-second suffixes are tolerated; garbage is nil, never a guess.
    static func parseDate(_ raw: String?) -> Date? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// One camera name from make and model. Models usually repeat the make
    /// ("Apple" + "iPhone 16 Pro" but also "NIKON CORPORATION" + "NIKON
    /// Z 6") — the rule: when the model already starts with the make's
    /// first word, the model IS the name.
    static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (make.isEmpty, model.isEmpty) {
        case (true, true): return nil
        case (true, false): return model
        case (false, true): return make
        case (false, false):
            let makeWord = make.split(separator: " ").first.map(String.init) ?? make
            if model.lowercased().hasPrefix(makeWord.lowercased()) { return model }
            return "\(make) \(model)"
        }
    }
}
