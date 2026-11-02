// Brand-specific layouts, each from a real sample where one exists and from the research otherwise.
import Foundation
import ImageIO

// MARK: - Small XML reading

enum XMLScan {
    /// The value of `attribute` on the first `<tag` element. No parsing beyond that, so namespace
    /// versions and CRLF don't matter and a damaged tail doesn't either.
    static func attribute(_ attribute: String, ofTag tag: String, in s: String) -> String? {
        var searchFrom = s.startIndex
        while let open = s.range(of: "<" + tag, range: searchFrom ..< s.endIndex) {
            searchFrom = open.upperBound
            guard let next = s[open.upperBound...].first, next.isWhitespace || next == "/" || next == ">" else { continue }
            guard let close = s[open.upperBound...].firstIndex(of: ">") else { return nil }
            let body = s[open.upperBound ..< close]
            for quote in ["\"", "'"] {
                var from = body.startIndex
                while let hit = body.range(of: attribute + "=" + quote, range: from ..< body.endIndex) {
                    from = hit.upperBound
                    if hit.lowerBound > body.startIndex, !body[body.index(before: hit.lowerBound)].isWhitespace { continue }
                    guard let end = body[hit.upperBound...].range(of: quote) else { return nil }
                    return String(body[hit.upperBound ..< end.lowerBound])
                }
            }
            return nil
        }
        return nil
    }
}

// MARK: - Sony

struct SonyProfile {
    var model: String?
    var systemId: String?
}

struct SonyClipXML {
    var model: String?
    var serial: String?
    var systemId: String?
    var day: CalendarDay?
}

enum Sony {
    /// MEDIAPRO.XML at `/<X>/` or `/PRIVATE/<X>/`, proven by its namespace. The folder name is not evidence.
    static func findProfiles(_ ctx: CardContext) -> [(root: String, profile: SonyProfile)] {
        var out: [(String, SonyProfile)] = []
        for (lower, rel) in ctx.byLowerPath where lower.hasSuffix("/mediapro.xml") {
            let parts = CardContext.components(lower)
            guard parts.count == 2 || (parts.count == 3 && parts[0] == "private") else { continue }
            guard let file = ctx.open(rel), let profile = parseProfile(file.read(at: 0, count: 64 << 10)) else { continue }
            out.append((CardContext.folder(of: rel), profile))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// True for the Sony MXF proven by real files to end in a RIP: XAVC from the FX6 and RAW from an AXS-R5.
    /// X-OCN has no public real sample, so it stays unproven.
    static func hasProvenEnding(_ xml: String) -> Bool {
        guard let codec = XMLScan.attribute("videoCodec", ofTag: "VideoFrame", in: xml) else { return false }
        return codec.hasPrefix("AVC_") || codec.hasPrefix("F55RAW")
    }

    static func parseProfile(_ bytes: [UInt8]) -> SonyProfile? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.contains("http://xmlns.sony.net/pro/metadata/mediaprofile") else { return nil }
        var model = XMLScan.attribute("systemKind", ofTag: "System", in: text)
        if let m = model, let space = m.firstIndex(of: " ") { model = String(m[..<space]) }
        return SonyProfile(model: model, systemId: XMLScan.attribute("systemId", ofTag: "System", in: text))
    }

    static func parseClipXML(_ text: String) -> SonyClipXML? {
        guard text.contains("<NonRealTimeMeta") else { return nil }
        var c = SonyClipXML()
        // On an AXS recorder `Device` is the recorder (AXS-R5) and `Camera` the body (PMW-F55). Real Netflix OCF.
        let tag = XMLScan.attribute("modelName", ofTag: "Camera", in: text) != nil ? "Camera" : "Device"
        c.model = XMLScan.attribute("modelName", ofTag: tag, in: text)
        c.serial = XMLScan.attribute("serialNo", ofTag: tag, in: text)
        c.day = XMLScan.attribute("value", ofTag: "CreationDate", in: text).flatMap(WrittenDate.day)
        // The last 8 bytes of a clip UMID are the body's systemId.
        if let umid = XMLScan.attribute("umidRef", ofTag: "TargetMaterial", in: text), umid.count == 64 {
            c.systemId = String(umid.suffix(16))
        }
        return c
    }

    static func identity(model: String?, serial: String?, systemId: String?) -> CameraIdentity {
        let clean = CameraNames.cleanSerial(serial)
        guard let model, !model.isEmpty else {
            return CameraIdentity(family: .sony, make: "Sony", displayModel: "Sony", serial: clean, bodyKey: clean ?? systemId, modelIsCertain: false)
        }
        return CameraIdentity(family: .sony, make: "Sony", model: model,
                              displayModel: CameraNames.safeFolderName(CameraNames.sony(model)),
                              serial: clean, bodyKey: clean ?? systemId)
    }

    /// Top-level `meta`, handler `nrtm`, child `xml `, 4 bytes in. Sits after `moov`.
    static func nrtmXML(_ file: ByteFile, _ qt: QTInfo) -> String? {
        guard let meta = AtomWalker.first("meta", in: qt.topLevel) else { return nil }
        let kids = metaChildren(file, of: meta)
        guard let hdlr = AtomWalker.first("hdlr", in: kids),
              file.read(at: hdlr.payload, count: 12).be32(8) == FourCC("nrtm").raw,
              let xml = AtomWalker.first("xml ", in: kids) else { return nil }
        let b = file.read(at: xml.payload + 4, count: Int(min(xml.payloadSize, 256 << 10)))
        return String(decoding: b, as: UTF8.self)
    }

    /// Within 25 KB on camera originals, but a real re-wrapped FX6 file has it at 445 KB.
    static func embeddedXML(inMXFHead head: [UInt8]) -> String? {
        guard let start = head.find(Array("<NonRealTimeMeta".utf8)) else { return nil }
        let close = Array("</NonRealTimeMeta>".utf8)
        let end = head.find(close, from: start).map { $0 + close.count } ?? head.count
        return String(decoding: head[start ..< end], as: UTF8.self)
    }

    /// `ILME-FX2 1234567` under local tag 0x8114 in the first `rtmd` sample. The offset varies between
    /// files, so scan, and let the value prove itself: it must start with the model.
    static func rtmdSerial(_ file: ByteFile, _ qt: QTInfo, model: String) -> String? {
        guard let track = qt.track(format: "rtmd"), let sample = QuickTime.firstSample(file, track) else { return nil }
        let b = file.read(at: sample.offset, count: min(sample.size, 64 << 10))
        return scanSerial(b, model: model)
    }

    static func scanSerial(_ b: [UInt8], model: String) -> String? {
        var from = 0
        while let i = b.find([0x81, 0x14], from: from) {
            from = i + 2
            guard let length = b.be16(i + 2), length >= 3, length <= 256 else { continue }
            let words = b.text(from: i + 4, length: Int(length)).split(separator: " ")
            if words.count >= 2, words[0] == model, let serial = CameraNames.cleanSerial(String(words[1])) { return serial }
        }
        return nil
    }

    /// VENICE 2 carries `MPC-3628` (8K) or `MPC-3626` (6K) in the MXF. BURANO and VENICE by the same pattern.
    static func cineModel(inHead head: [UInt8]) -> String? {
        for model in ["MPC-3628", "MPC-3626", "MPC-3610", "MPC-2610"] where head.find(Array(model.utf8)) != nil { return model }
        return nil
    }
}

// MARK: - Canon

/// What a maker's own metadata block says.
struct BodyFacts {
    var model: String?
    var serial: String?
    var date: CalendarDay?
}

enum Canon {
    private static let metadataUUID: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]

    private static func uuidBox(_ file: ByteFile, _ qt: QTInfo) -> Atom? {
        for atom in qt.moovChildren where atom.type == "uuid" {
            if file.read(at: atom.payload, count: 16) == metadataUUID { return atom }
        }
        return nil
    }

    static func isCanon(_ file: ByteFile, _ qt: QTInfo) -> Bool {
        if qt.major == "crx " || qt.hasBrand("CAEP") { return true }
        if (qt.udtaCString(file, "manu") ?? "").hasPrefix("Canon") { return true }
        return uuidBox(file, qt) != nil
    }

    static func read(_ file: ByteFile, _ qt: QTInfo) -> BodyFacts {
        var c = BodyFacts()
        c.model = qt.udtaCString(file, "modl")
        guard let uuid = uuidBox(file, qt) else { return c }
        let kids = AtomWalker.children(file, of: uuid, skip: 16)

        if let cnth = AtomWalker.first("CNTH", in: kids),
           let cnda = AtomWalker.first("CNDA", in: AtomWalker.children(file, of: cnth)) {
            let jpeg = Data(AtomWalker.payload(file, cnda, cap: 4 << 20))
            if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                if c.model == nil { c.model = tiff?[kCGImagePropertyTIFFModel] as? String }
                c.serial = exif?[kCGImagePropertyExifBodySerialNumber] as? String
                c.date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(WrittenDate.day)
            }
        }
        // CR3 and CRM keep plain TIFF blobs instead.
        if let cmt1 = AtomWalker.first("CMT1", in: kids), c.model == nil {
            c.model = TIFF.strings(AtomWalker.payload(file, cmt1, cap: 1 << 20), wanted: [0x0110])[0x0110]
        }
        if let cmt2 = AtomWalker.first("CMT2", in: kids) {
            let s = TIFF.strings(AtomWalker.payload(file, cmt2, cap: 1 << 20), wanted: [0x9003, 0xA431])
            if c.serial == nil { c.serial = s[0xA431] }
            if c.date == nil { c.date = s[0x9003].flatMap(WrittenDate.day) }
        }
        return c
    }
}

extension QTInfo {
    /// Canon's `manu` and `modl`: 4 bytes version, 2 bytes language, then a C string.
    func udtaCString(_ file: ByteFile, _ type: FourCC) -> String? {
        guard let atom = udta[type] else { return nil }
        let s = AtomWalker.payload(file, atom, cap: 256).text(from: 6)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Nikon

enum Nikon {
    /// True for a file with Nikon's own tag block in its head. R3D NE has no public layout yet,
    /// so this looks for the marker telemetry-parser uses, not for a structure.
    static func isNikonRaw(_ file: ByteFile) -> Bool {
        let b = file.read(at: 0, count: 256 << 10)
        return b.find(Array("NCTG".utf8)) != nil || b.find(Array("Nikon".utf8)) != nil || b.find(Array("NIKON".utf8)) != nil
    }

    /// `moov/udta/NCDT/NCTG`: u32 tag, u16 format, u16 count, value. 0x01 make, 0x02 model,
    /// 0x11 create date, 0x12 original date, 0x110A431 serial.
    static func tags(_ file: ByteFile, _ qt: QTInfo) -> BodyFacts {
        var n = BodyFacts()
        guard let ncdt = qt.udta["NCDT"],
              let nctg = AtomWalker.first("NCTG", in: AtomWalker.children(file, of: ncdt)) else { return n }
        let b = AtomWalker.payload(file, nctg, cap: 1 << 20)
        var p = 0
        var original: CalendarDay?
        var created: CalendarDay?
        var entries = 0
        walk: while p + 8 <= b.count, entries < 4096, let tag = b.be32(p), let format = b.be16(p + 4), let count = b.be16(p + 6) {
            entries += 1
            let unit: Int
            switch format {
            case 1, 2, 6, 7: unit = 1
            case 3, 8: unit = 2
            case 4, 9, 11: unit = 4
            case 5, 10, 12: unit = 8
            default: break walk
            }
            let value = p + 8
            let length = Int(count) * unit
            guard value + length <= b.count else { break }
            if format == 2 {
                let s = b.text(from: value, length: length)
                switch tag {
                case 0x02: n.model = s
                case 0x110A431: n.serial = s
                case 0x11: created = WrittenDate.day(s)
                case 0x12: original = WrittenDate.day(s)
                default: break
                }
            }
            p = value + length
        }
        n.date = original ?? created
        return n
    }
}

// MARK: - DJI

enum DJI {
    /// First `djmd` sample is protobuf. Field 1 → field 1 → field 5 is the serial, field 10 the model.
    /// Other firmware could shift this, so a value that doesn't look like a serial is dropped.
    static func serial(_ file: ByteFile, _ qt: QTInfo) -> String? {
        guard let track = qt.track(format: "djmd"), let sample = QuickTime.firstSample(file, track) else { return nil }
        let b = file.read(at: sample.offset, count: min(sample.size, 16 << 10))
        guard let outer = Protobuf.fields(b).first(where: { $0.field == 1 }),
              let inner = Protobuf.fields(outer.bytes).first(where: { $0.field == 1 }),
              let value = Protobuf.fields(inner.bytes).first(where: { $0.field == 5 }) else { return nil }
        let s = value.bytes.text()
        guard (8 ... 24).contains(s.count), s.utf8.allSatisfy({ $0.isASCIIDigit || $0.isASCIIUpper }) else { return nil }
        return s
    }
}

// MARK: - ARRI

enum ARRIMetadata {
    private static func utf16(_ s: String, bigEndian: Bool) -> [UInt8] {
        s.utf8.flatMap { bigEndian ? [0, $0] : [$0, 0] }
    }

    /// Long needles only: four bytes like "ARRI" turn up by chance in a megabyte of essence.
    static func mentionsARRI(_ head: [UInt8]) -> Bool {
        for word in ["ARRIRAW", "ALEXA", "AMIRA", "com.arri."] {
            if head.find(Array(word.utf8)) != nil || head.find(utf16(word, bigEndian: true)) != nil
                || head.find(utf16(word, bigEndian: false)) != nil { return true }
        }
        return false
    }

    /// ALEXA 35: UTF-16 JSON in the header partition, which can be 16 MiB. Older MXF: XML.
    static func read(_ file: ByteFile, head: [UInt8], deep: Bool) -> (model: String?, serial: String?) {
        var r = scan(head)
        if r.model == nil, deep, file.size > UInt64(MXF.headSize) {
            r = scan(file.read(at: 0, count: 17 << 20))
        }
        return r
    }

    private static func scan(_ b: [UInt8]) -> (model: String?, serial: String?) {
        for needle in [utf16("cameraModel", bigEndian: true), utf16("cameraModel", bigEndian: false), Array("cameraModel".utf8), Array("CameraModel".utf8)] {
            guard let hit = b.find(needle) else { continue }
            let region = Array(b[hit ..< min(b.count, hit + 4096)]).filter { $0 != 0 }
            let text = String(decoding: region, as: UTF8.self)
            if let model = field("ameraModel", text) {
                return (model, field("ameraSerialNumber", text))
            }
        }
        return (nil, nil)
    }

    /// The value after `name` in JSON or XML: `"cameraModel":"ALEXA 35"`, `<CameraModel>ALEXA Mini LF<`.
    private static func field(_ name: String, _ text: String) -> String? {
        guard let hit = text.range(of: name) else { return nil }
        let after = text[hit.upperBound...].drop { "\"':> =\t\r\n".contains($0) }
        let value = after.prefix { !"\"<,}\r\n".contains($0) }.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `.ari` starts `ARRI`, `.arx` starts `CDXA`, then 12 34 56 78. The model is plain text in the 4 KB header:
    /// `Alexa LF Plus W` and `ARRI ALEXA Mini LF` on real frames. `AlexaLF_2.0:41017` beside it is firmware,
    /// so a name must have a space in it.
    static func modelInFrame(_ file: ByteFile) -> String? {
        let b = file.read(at: 0, count: 8192)
        guard b.matches([0x12, 0x34, 0x56, 0x78], at: 4),
              b.matches(Array("ARRI".utf8), at: 0) || b.matches(Array("CDXA".utf8), at: 0) else { return nil }
        let text = b.printableLines
        return captures(frameModel, text)?.first?.trimmingCharacters(in: .whitespaces)
    }
    private static let frameModel = regex("(?m)^((?:ARRI )?(?:Alexa|ALEXA|Amira|AMIRA) [A-Za-z0-9 +]+)$")

    /// ALE: tab-separated. `Column`, the header row, a blank, `Data`, rows.
    static func modelInALE(_ file: ByteFile) -> String? {
        let text = String(decoding: file.read(at: 0, count: 256 << 10), as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        guard let column = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "column" }),
              column + 1 < lines.count,
              let data = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "data" }),
              data + 1 < lines.count else { return nil }
        let names = lines[column + 1].split(separator: "\t", omittingEmptySubsequences: false).map { $0.lowercased() }
        let row = lines[data + 1].split(separator: "\t", omittingEmptySubsequences: false)
        for wanted in ["camera_model", "camera model", "cameramodel", "camera_type", "cameratype"] {
            if let i = names.firstIndex(of: wanted), i < row.count {
                let v = row[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }
}

// MARK: - Audio recorders

enum AudioRecorders {
    /// A `bext` chunk alone proves nothing: Premiere and Pro Tools write one. Only a recorder's own name counts.
    /// Real MixPre-10 II: "SoundDev: MixPre-10 II TJ0000000", with `sTAKE=` lines in the description.
    static func identify(_ info: RIFFInfo) -> (make: String?, model: String?, serial: String?)? {
        let originator = info.originator ?? ""
        let lower = originator.lowercased()
        for (needle, prefix, make) in [("sounddev", "SoundDev", "Sound Devices"), ("sound devices", "Sound Devices", "Sound Devices"),
                                       ("mixpre", "", "Sound Devices"), ("zoom", "Zoom", "Zoom"), ("tascam", "Tascam", "Tascam"),
                                       ("cantar", "", "Aaton"), ("nagra", "Nagra", "Nagra")]
        where lower.contains(needle) {
            var rest = originator
            if !prefix.isEmpty, let r = rest.range(of: prefix, options: [.caseInsensitive, .anchored]) { rest = String(rest[r.upperBound...]) }
            var words = rest.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
            var serial: String?
            if words.count > 1, let last = words.last, looksLikeSerial(last) { serial = words.removeLast() }
            return (make, words.isEmpty ? nil : words.joined(separator: " "), serial)
        }
        let description = info.description ?? ""
        if description.contains("zTAKE=") || description.contains("zSPEED=") { return ("Zoom", nil, nil) }
        if description.contains("sTAKE=") || description.contains("sSPEED=") { return ("Sound Devices", nil, nil) }
        return nil
    }

    private static func looksLikeSerial(_ s: String) -> Bool {
        s.count >= 6 && s.utf8.allSatisfy { $0.isASCIIDigit || $0.isASCIIUpper }
            && s.utf8.contains(where: \.isASCIIDigit) && s.utf8.contains(where: \.isASCIIUpper)
    }
}
