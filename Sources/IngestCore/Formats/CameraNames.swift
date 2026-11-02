// Names people use, and the facts a filename can carry. A name is never proof of a brand.
import Foundation

enum CameraNames {
    private static let romans = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"]

    /// "ILME-FX3" → "FX3", "ILCE-7SM3" → "A7S III", "MPC-3628" → "VENICE 2".
    static func sony(_ model: String) -> String {
        let cine = ["MPC-3610": "VENICE", "MPC-3626": "VENICE 2", "MPC-3628": "VENICE 2", "MPC-2610": "BURANO"]
        if let name = cine[model] { return name }
        if model.hasPrefix("ILCE-") { return "A" + sonyMark(String(model.dropFirst(5))) }
        if model.hasPrefix("DSC-") { return sonyMark(String(model.dropFirst(4))) }
        if model.hasPrefix("ILME-") {
            var body = String(model.dropFirst(5))
            if body == "FX6V" || body == "FX6T" { body = "FX6" }
            return body
        }
        for prefix in ["PXW-", "HXR-", "PMW-", "HDC-"] where model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        if model.hasPrefix("ZV-"), let (body, mark) = trailingMark(model) { return "\(body) \(mark)" }
        return model
    }

    /// "7SM3" → "7S III". A trailing letter stays: "7RM4A" → "7R IVA".
    private static func sonyMark(_ body: String) -> String {
        if let (start, mark) = trailingMark(body) { return "\(start) \(mark)" }
        return body
    }

    private static func trailingMark(_ s: String) -> (String, String)? {
        guard let c = captures(markRE, s), c.count == 3, let n = Int(c[1]), n >= 2, n < romans.count else { return nil }
        return (c[0], romans[n] + c[2])
    }
    private static let markRE = regex("^(.*[0-9A-Z])M([0-9])(A?)$")

    /// "Canon EOS R5" → "R5", "Canon EOS R5m2" → "R5 II", "Canon EOS C70" → "C70".
    static func canon(_ model: String) -> String {
        var s = model
        for prefix in ["Canon ", "EOS "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if let c = captures(canonMarkRE, s), c.count == 2, let n = Int(c[1]), n >= 2, n < romans.count {
            return "\(c[0]) \(romans[n])"
        }
        return s
    }
    private static let canonMarkRE = regex("^(.*[0-9])m([0-9])$")

    /// "NIKON Z 8" → "Z8", "NIKON Z 6_3" → "Z6 III", "NIKON Z f" → "Zf".
    static func nikon(_ model: String) -> String {
        var s = model
        for prefix in ["NIKON CORPORATION ", "NIKON ", "Nikon "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if let c = captures(nikonRE, s), c.count == 3 {
            var name = "Z" + c[0]
            if let n = Int(c[1].dropFirst()), n >= 2, n < romans.count { name += " " + romans[n] }
            return name + c[2]
        }
        return s
    }
    private static let nikonRE = regex("^Z ?([0-9a-zA-Z]+?)(_[0-9])?()$")

    /// "DC-GH7" → "GH7", "AU-EVA1" → "EVA1".
    static func panasonic(_ model: String) -> String {
        for prefix in ["DC-", "DMC-", "AU-", "AG-", "AJ-"] where model.hasPrefix(prefix) { return String(model.dropFirst(prefix.count)) }
        return model
    }

    /// "DJI OsmoPocket3" → "Osmo Pocket 3".
    static func dji(_ model: String) -> String {
        var s = model
        if s.hasPrefix("DJI ") { s = String(s.dropFirst(4)) }
        var out = ""
        var previous: Character?
        for c in s {
            if let p = previous, c != " ", p != " ",
               (p.isLowercase && (c.isUppercase || c.isNumber)) || (p.isNumber && c.isUppercase) {
                out.append(" ")
            }
            out.append(c)
            previous = c
        }
        return out
    }

    /// What real files say: "ARRI ALEXA 35" → "ALEXA 35", "Alexa LF Plus W" → "ALEXA LF", "Alexa65  XT" → "ALEXA 65".
    static func arri(_ model: String) -> String {
        var words = model.split(separator: " ").map(String.init)
        if words.first?.uppercased() == "ARRI" { words.removeFirst() }
        guard let first = words.first else { return "ALEXA" }
        let upper = first.uppercased()
        if upper.hasPrefix("ALEXA"), upper.count > 5 {
            words.replaceSubrange(0 ... 0, with: ["ALEXA", String(upper.dropFirst(5))])
        } else if upper == "ALEXA" || upper == "AMIRA" {
            words[0] = upper
        }
        if words.count > 2, let tail = ["Plus W", "Plus 4:3", "Plus", "XT", "SXT"].first(where: { words.joined(separator: " ").hasSuffix(" " + $0) }) {
            words.removeLast(tail.split(separator: " ").count)
        }
        return words.joined(separator: " ")
    }

    /// "Blackmagic URSA Cine 12K LF" → "URSA Cine 12K LF".
    static func blackmagic(_ model: String) -> String {
        model.hasPrefix("Blackmagic ") ? String(model.dropFirst("Blackmagic ".count)) : model
    }

    /// "Apple iPhone 17 Pro Max 24mm" → "iPhone 17 Pro Max". The Blackmagic Cam app adds the lens.
    static func apple(_ model: String) -> String {
        var s = model
        if s.hasPrefix("Apple ") { s = String(s.dropFirst(6)) }
        var words = s.split(separator: " ")
        if let last = words.last, last.hasSuffix("mm"), last.dropLast(2).allSatisfy({ $0.isNumber || $0 == "." }), !last.dropLast(2).isEmpty {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Usable as one folder name on any drive format the app meets.
    static func safeFolderName(_ s: String, fallback: String = "Camera") -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F { continue }
            if "/\\:*?\"<>|".unicodeScalars.contains(u) { out.append(" "); continue }
            out.unicodeScalars.append(u)
        }
        out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while let f = out.first, f == "." || f == " " { out.removeFirst() }
        out = String(out.prefix(48))
        while let l = out.last, l == "." || l == " " { out.removeLast() }
        return out.isEmpty ? fallback : out
    }

    static func cleanSerial(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 3, t.count <= 64 else { return nil }
        let lower = t.lowercased()
        if ["4294967295", "unknown", "none", "n/a", "null", "ffffffff"].contains(lower) { return nil }
        if t.allSatisfy({ $0 == "0" }) { return nil }
        guard t.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return nil }
        return t
    }

    /// One line per family. `make` is the one spelling kept: EXIF has "SONY" and "NIKON CORPORATION", clips "Sony".
    /// `short` names a body with no readable model. `makePrefixes` are lower-case starts of an EXIF or QuickTime make.
    private static let brands: [(family: CameraFamily, make: String?, short: String, makePrefixes: [String])] = [
        (.sony, "Sony", "Sony", ["sony"]),
        (.canon, "Canon", "Canon", ["canon"]),
        (.nikon, "Nikon", "Nikon", ["nikon"]),
        (.fujifilm, "FUJIFILM", "Fujifilm", ["fuji"]),
        (.panasonic, "Panasonic", "Panasonic", ["panasonic"]),
        (.dji, "DJI", "DJI", ["dji"]),
        (.gopro, "GoPro", "GoPro", ["gopro"]),
        (.apple, "Apple", "iPhone", ["apple"]),
        (.insta360, "Insta360", "Insta360", ["insta360", "arashi"]),
        (.blackmagic, "Blackmagic Design", "Blackmagic", ["blackmagic"]),
        (.red, "RED", "RED", []),
        (.arri, "ARRI", "ALEXA", []),
        (.audioRecorder, nil, "Recorder", []),
        (.unknown, nil, "Camera", []),
    ]

    /// nil for makes with no family of their own.
    static func family(forMake make: String) -> CameraFamily? {
        let m = make.lowercased()
        return brands.first { $0.makePrefixes.contains(where: m.hasPrefix) }?.family
    }
    static func make(_ family: CameraFamily) -> String? { brands.first { $0.family == family }?.make }
    static func shortBrand(_ family: CameraFamily) -> String { brands.first { $0.family == family }?.short ?? "Camera" }

    static func display(family: CameraFamily, model: String) -> String {
        let name: String
        switch family {
        case .sony: name = sony(model)
        case .canon: name = canon(model)
        case .nikon: name = nikon(model)
        case .panasonic: name = panasonic(model)
        case .dji: name = dji(model)
        case .blackmagic: name = blackmagic(model)
        case .arri: name = arri(model)
        case .apple: name = apple(model)
        case .fujifilm: name = model.hasPrefix("FUJIFILM ") ? String(model.dropFirst(9)) : model
        default: name = model
        }
        return safeFolderName(name)
    }
}
