// What folder names mean. Works on names only: no filesystem access, no knowledge of any one person's drive.
import Foundation

/// The job a folder's name suggests, before its content has a say.
enum NameHint: Equatable {
    case footage, photo, project, exports, audio
}

/// A folder named like a card, split into the prefix the drive uses and the reel.
struct CardName: Equatable {
    var prefix: String      // "CARD ", "Card_", or "" for a bare "A082"
    var reel: String        // "A082"
}

enum LayoutNames {
    // MARK: Comparing names

    /// The key two names share when a person would call them the same: NFC + NFD agree, case, accents and runs of
    /// whitespace do not matter, and neither do the trailing dots and spaces exFAT cleaning removes.
    /// Looser than the global `matchKey`, which compares file names: the two rules differ on purpose.
    static func matchKey(_ name: String) -> String {
        let folded = name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.utf8.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.unicodeScalars.append(" "); pendingSpace = false }
                out.unicodeScalars.append(scalar)
            }
        }
        while out.last == "." || out.last == " " { out.removeLast() }
        return out
    }

    // MARK: Noise

    private static let noiseNames: Set<String> = [
        "cache", "system volume information", "$recycle.bin", "recycler", "backups.backupdb",
        "found.000", "lost+found", "#recycle", "@eadir", "cacheclip", "motion graphics template media",
    ]
    private static let noisePrefixes = ["adobe premiere pro ", "adobe after effects "]

    /// True for folders no layout should be learned from.
    static func isNoise(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return true }
        if first == UInt8(ascii: "_") || first == UInt8(ascii: ".") { return true }
        let lower = name.lowercased()
        if noiseNames.contains(lower) { return true }
        return noisePrefixes.contains { lower.hasPrefix($0) }
    }

    private static let cardMarkers: Set<String> = ["m4root", "xdroot", "dcim", "clip", "bpav", "avchd", "canonmsc"]

    /// True for a folder that only exists inside a camera card's own tree.
    static func isCardMarker(_ name: String) -> Bool {
        let lower = name.lowercased()
        return cardMarkers.contains(lower) || lower.hasSuffix(".rdm") || lower.hasSuffix(".rdc")
    }

    // MARK: Numbered folders

    /// "01 ORIGINALS" → (1, "ORIGINALS"). A number on its own, or something date-like, stays as it is.
    static func splitNumber(_ name: String) -> (number: Int?, rest: Substring) {
        let whole = Substring(name)
        var digits = 0
        for byte in name.utf8 {
            guard byte >= 48, byte <= 57 else { break }
            digits += 1
        }
        guard digits >= 1, digits <= 3 else { return (nil, whole) }
        let afterDigits = name.utf8.index(name.utf8.startIndex, offsetBy: digits)
        var cursor = afterDigits
        var separators = 0
        while cursor < name.utf8.endIndex {
            let byte = name.utf8[cursor]
            guard byte == 32 || byte == 46 || byte == 95 || byte == 45 else { break }
            separators += 1
            cursor = name.utf8.index(after: cursor)
        }
        guard separators >= 1, cursor < name.utf8.endIndex else { return (nil, whole) }
        let first = name.utf8[cursor]
        if first >= 48, first <= 57 { return (nil, whole) }
        return (Int(name[name.startIndex..<afterDigits]), name[cursor...])
    }

    /// The identity of an inner folder: numbering, case, accents and a plural "s" do not change what it is.
    static func slotKey(_ name: String) -> String {
        var key = matchKey(String(splitNumber(name).rest))
        if key.count > 3, key.hasSuffix("s") { key.removeLast() }
        return key
    }

    // MARK: Hints

    private static let hintWords: [(NameHint, Set<String>)] = [
        (.exports, ["export", "exports", "delivery", "deliveries", "deliverable", "deliverables", "render", "renders",
                    "output", "outputs", "sortie", "sorties", "livraison", "livraisons", "livrable", "livrables",
                    "rendu", "rendus", "ausgabe", "salida", "entrega", "entregas"]),
        (.project, ["project", "projects", "projet", "projets", "projekt", "projekte", "proyecto", "proyectos",
                    "progetto", "premiere", "resolve", "davinci", "edit", "edits", "montage", "aftereffects", "ae",
                    "schnitt"]),
        (.audio, ["audio", "audios", "sound", "sounds", "son", "sons", "ton", "sonido"]),
        (.photo, ["photo", "photos", "image", "images", "foto", "fotos", "fotografie", "bilder", "imagen", "imagenes"]),
        (.footage, ["footage", "rushes", "rushs", "rush", "originals", "original", "originaux", "source", "sources",
                    "video", "videos", "cam", "camera", "cameras", "media", "prises", "tournage", "rohmaterial",
                    "drehmaterial", "material", "brutos", "girato", "clips"]),
    ]

    /// The folded words of a name, without its leading number.
    private static func words(of name: String) -> [String] {
        matchKey(String(splitNumber(name).rest)).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// What the name alone suggests. Several words can hit, so "Video Exports" counts as exports.
    static func hint(for name: String) -> NameHint? {
        let tokens = words(of: name)
        guard !tokens.isEmpty else { return nil }
        let joined = tokens.joined()
        for (hint, words) in hintWords where words.contains(joined) || tokens.contains(where: words.contains) {
            return hint
        }
        return nil
    }

    /// True when the whole name says footage: `Video`, `02 Rushes`. `Social Media` only mentions it.
    static func isFootageName(_ name: String) -> Bool {
        let tokens = words(of: name)
        guard tokens.count == 1, let footageWords = hintWords.first(where: { $0.0 == .footage })?.1 else { return false }
        return footageWords.contains(tokens[0])
    }

    private static let rawWords: Set<String> = ["raw", "raws", "negative", "negatives", "negatif", "negatifs", "dng"]

    /// Inside a photo folder: is this the folder of originals?
    static func looksLikeRaw(_ name: String) -> Bool {
        words(of: name).contains(where: rawWords.contains)
    }

    // MARK: Cards and cameras

    private static let cardWords: Set<String> = [
        "CARD", "CARDS", "CARTE", "CARTES", "KARTE", "KARTEN", "TARJETA", "SCHEDA", "CARTAO", "KAART", "KORT",
        "REEL", "ROLL", "MAG", "BOBINE", "SD", "CF", "CFX", "CFAST", "CFEXPRESS",
    ]

    /// "CARD A082", "A082", "CARD 01", "Card_3", "A001_C002_0101AB". "C300" stays a camera.
    static func cardName(_ name: String) -> CardName? {
        let scalars = Array(name.unicodeScalars)
        guard !scalars.isEmpty else { return nil }

        // A leading card word, or two ("SD CARD 2"), followed by the reel.
        var cursor = 0
        var matchedWord = false
        while cursor < scalars.count {
            var end = cursor
            while end < scalars.count, CharacterSet.alphanumerics.contains(scalars[end]) { end += 1 }
            guard end > cursor, end < scalars.count else { break }
            let word = String(String.UnicodeScalarView(scalars[cursor..<end])).uppercased()
            guard cardWords.contains(word) else { break }
            matchedWord = true
            var next = end
            while next < scalars.count, scalars[next] == " " || scalars[next] == "_" || scalars[next] == "-" { next += 1 }
            cursor = next
        }
        if matchedWord, cursor > 0, cursor < scalars.count {
            let reel = String(String.UnicodeScalarView(scalars[cursor...]))
            let hasDigit = reel.utf8.contains { $0 >= 48 && $0 <= 57 }
            if hasDigit || reel.unicodeScalars.count == 1 {
                return CardName(prefix: String(String.UnicodeScalarView(scalars[..<cursor])), reel: reel)
            }
        }

        // A bare reel: one letter, three digits, then nothing or an underscore tail.
        let bytes = Array(name.utf8)
        guard bytes.count >= 4, bytes[0].isASCIILetter, bytes[1].isASCIIDigit, bytes[2].isASCIIDigit, bytes[3].isASCIIDigit else { return nil }
        if bytes.count > 4, bytes[4] != UInt8(ascii: "_") { return nil }
        let number = Int(bytes[1] - 48) * 100 + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        if bytes.count == 4, number % 100 == 0 { return nil }  // C100, C300, C500: cinema bodies, not reels
        return CardName(prefix: "", reel: name)
    }

    private static let cameraWords = [
        "GOPRO", "HERO", "DJI", "DRONE", "OSMO", "MAVIC", "IPHONE", "INSTA360", "BMPCC", "POCKET", "URSA", "PYXIS",
        "ALEXA", "AMIRA", "KOMODO", "RAPTOR", "VENICE", "BURANO", "SONY", "CANON", "NIKON", "PANASONIC", "LUMIX",
        "FUJI", "BLACKMAGIC",
    ]
    private static let cameraLabels: Set<String> = ["CAM", "CAMERA", "CAMERAS", "KAMERA", "CAMARA"]

    /// `FX3`, `A7S`, `C70`, `CAM A`, `R5`, `GoPro 2`. The test runs after `cardName`, so a reel never lands here.
    static func looksLikeCamera(_ name: String) -> Bool {
        let upper = name.uppercased()
        let words = upper.split { $0 == " " || $0 == "_" || $0 == "-" }.map(String.init)
        guard let firstWord = words.first else { return false }
        if cameraLabels.contains(firstWord) { return words.count == 2 && words[1].count <= 2 }
        if firstWord.hasPrefix("CAM"), firstWord.count == 4, words.count == 1 { return true }  // "CAMA", "CAMB"
        if cameraWords.contains(where: { upper.hasPrefix($0) }) { return true }
        guard words.count == 1 else { return false }
        // Short model codes: letters, digits, optional letters.
        let bytes = Array(firstWord.utf8)
        guard bytes.count >= 2, bytes.count <= 8 else { return false }
        var i = 0
        while i < bytes.count, bytes[i].isASCIILetter { i += 1 }
        guard i >= 1, i <= 3 else { return false }
        let digitStart = i
        while i < bytes.count, bytes[i].isASCIIDigit { i += 1 }
        guard i > digitStart, i - digitStart <= 3 else { return false }
        while i < bytes.count, bytes[i].isASCIILetter { i += 1 }
        return i == bytes.count
    }

    /// Share of letters that are capitals. nil when the text has no cased letters.
    static func upperShare(_ names: some Sequence<String>) -> Double? {
        var upper = 0, lower = 0
        for name in names {
            for scalar in name.unicodeScalars {
                if scalar.properties.isUppercase { upper += 1 } else if scalar.properties.isLowercase { lower += 1 }
            }
        }
        return upper + lower == 0 ? nil : Double(upper) / Double(upper + lower)
    }
}
