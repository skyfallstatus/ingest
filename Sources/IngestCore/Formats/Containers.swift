// The small non-QuickTime readers: R3D, MXF, RIFF, Insta360 trailer, protobuf, TIFF, GPMF.
import Foundation

// MARK: - R3D

struct R3DFooter: Equatable {
    /// "REOB" one-file clip, "REOF" another part follows, "REOC" last part.
    var kind: String
    var declaredSize: UInt64
}

enum R3D {
    static func hasMagic(_ file: ByteFile) -> Bool { hasMagic(file.read(at: 0, count: 8)) }
    static func hasMagic(_ head: [UInt8]) -> Bool {
        head.matches(Array("RED2".utf8), at: 4) || head.matches(Array("RED1".utf8), at: 4)
    }

    /// String tags of the header, by tag number: 0x1006 PIN, 0x1071, 0x10A0, 0x1023 date and so on.
    static func tags(_ file: ByteFile) -> [UInt16: String] {
        let head = file.read(at: 0, count: 8)
        guard hasMagic(head), let declared = head.be32(0) else { return [:] }
        let b = file.read(at: 0, count: Int(min(max(declared, 1024), 256 << 10)))
        let end = min(b.count, Int(declared))
        let start = b.find(Array("rdi".utf8)) ?? 0x40
        // The block has no fixed offset. A false start can jump straight onto a true entry and land
        // correctly too, so the longest chain wins: the true start always has the most entries.
        var best: (entries: Int, tags: [UInt16: String]) = (0, [:])
        var p = start
        while p + 4 < end, p < start + 4096 {
            if let found = walkTags(b, from: p, end: end), found.entries > best.entries { best = found }
            p += 1
        }
        return best.tags
    }

    /// Tag entries are u16 size (counting itself), u16 tag, value, with no gaps until the block ends.
    private static func walkTags(_ b: [UInt8], from start: Int, end: Int) -> (entries: Int, tags: [UInt16: String])? {
        var p = start
        var out: [UInt16: String] = [:]
        var entries = 0
        while p < end {
            guard let size = b.be16(p), size >= 4, p + Int(size) <= end, let tag = b.be16(p + 2) else { return nil }
            if tag >> 12 == 1 { out[tag] = b.text(from: p + 4, length: Int(size) - 4) }
            entries += 1
            p += Int(size)
        }
        return entries >= 8 && !out.isEmpty ? (entries, out) : nil
    }

    /// The footer sits in the last 4 KB. Newer bodies could need more, so step back a little before giving up.
    static func footer(_ file: ByteFile) -> R3DFooter? {
        var back: UInt64 = 4096
        while back <= 64 * 1024, back <= file.size {
            let b = file.read(at: file.size - back, count: 0x48)
            let kind = b.text(from: 4, length: 4)
            if kind == "REOB" || kind == "REOF" || kind == "REOC", let declared = b.be64(0x40) {
                return R3DFooter(kind: kind, declaredSize: declared)
            }
            back += 4096
        }
        return nil
    }
}

// MARK: - MXF

struct MXFInfo {
    var company: String?
    var product: String?
    var modified: CalendarDay?
    /// The bytes read from the start of the file, for text scans.
    var head: [UInt8]
}

enum MXF {
    private static let partitionPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]
    private static let identificationKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x30, 0x00]
    static let headSize = 1 << 20

    static func parse(_ file: ByteFile) -> MXFInfo? {
        let b = file.read(at: 0, count: headSize)
        // A run-in of up to 64 KB may come before the header partition.
        guard let start = b.find(partitionPrefix), start <= 65536 else { return nil }
        var info = MXFInfo(head: b)
        var p = start
        while p + 17 <= b.count {
            guard b.matches([0x06, 0x0E, 0x2B, 0x34], at: p),
                  let (length, lengthSize) = berLength(b, at: p + 16) else { break }
            let value = p + 16 + lengthSize
            guard length <= UInt64(Int.max / 2) else { break }
            if b.matches(identificationKey, at: p) {
                readIdentification(b, from: value, to: min(b.count, value + Int(length)), into: &info)
                break
            }
            let next = value + Int(length)
            guard next > p, next <= b.count else { break }
            p = next
        }
        if info.company == nil, let hit = b.find(identificationKey),
           let (length, lengthSize) = berLength(b, at: hit + 16), length < UInt64(b.count) {
            let value = hit + 16 + lengthSize
            readIdentification(b, from: value, to: min(b.count, value + Int(length)), into: &info)
        }
        return info
    }

    private static func berLength(_ b: [UInt8], at i: Int) -> (UInt64, Int)? {
        guard i >= 0, i < b.count else { return nil }
        let first = b[i]
        if first < 0x80 { return (UInt64(first), 1) }
        let n = Int(first & 0x7F)
        guard n >= 1, n <= 8, i + n < b.count else { return nil }
        var v: UInt64 = 0
        for k in 1 ... n { v = v << 8 | UInt64(b[i + k]) }
        return (v, n + 1)
    }

    /// Local set: u16 tag, u16 length, value. 0x3C01 company, 0x3C02 product, 0x3C06 modification date.
    private static func readIdentification(_ b: [UInt8], from: Int, to: Int, into info: inout MXFInfo) {
        var p = from
        while p + 4 <= to, let tag = b.be16(p), let len = b.be16(p + 2) {
            let value = p + 4
            guard value + Int(len) <= to else { return }
            switch tag {
            case 0x3C01: info.company = b.utf16be(from: value, length: Int(len))
            case 0x3C02: info.product = b.utf16be(from: value, length: Int(len))
            case 0x3C06:
                if let year = b.be16(value), value + 3 < b.count {
                    let day = CalendarDay(year: Int(year), month: Int(b[value + 2]), day: Int(b[value + 3]))
                    if WrittenDate.isValid(day) { info.modified = day }
                }
            default: break
            }
            p = value + Int(len)
        }
    }
}

/// How an MXF file closes. All 188 real camera files sampled are closed-complete in the header and end in a
/// Random Index Pack whose last entry is a footer partition. A cut file has lost that end.
struct MXFEnding {
    var isMXF: Bool
    var headerClosedComplete: Bool
    var hasRandomIndex: Bool
    var isFinished: Bool { isMXF && headerClosedComplete && hasRandomIndex }
}

extension MXF {
    private static let ripKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x11, 0x01, 0x00]

    static func ending(_ file: ByteFile) -> MXFEnding {
        var end = MXFEnding(isMXF: false, headerClosedComplete: false, hasRandomIndex: false)
        let head = file.read(at: 0, count: 65536 + 16)
        guard let start = head.find(partitionPrefix), start <= 65536, start + 15 <= head.count else { return end }
        end.isMXF = true
        end.headerClosedComplete = head[start + 13] == 0x02 && head[start + 14] == 0x04
        end.hasRandomIndex = hasRandomIndex(file)
        return end
    }

    /// The last 4 bytes give the pack's length. Its last entry, 12 bytes before that, is the footer's offset.
    private static func hasRandomIndex(_ file: ByteFile) -> Bool {
        guard file.size > 40, let length = file.read(at: file.size - 4, count: 4).be32(0),
              length >= 33, UInt64(length) <= file.size else { return false }
        guard file.read(at: file.size - UInt64(length), count: 16) == ripKey else { return false }
        guard let offset = file.read(at: file.size - 12, count: 8).be64(0), offset < file.size else { return false }
        let footer = file.read(at: offset, count: 16)
        return footer.matches(partitionPrefix, at: 0) && footer.count == 16 && footer[13] == 0x04
    }
}

// MARK: - RIFF / Broadcast WAV

struct RIFFInfo {
    var originator: String?
    var description: String?
    var originationDate: String?
    var ixml: String?
}

enum RIFF {
    static func parse(_ file: ByteFile) -> RIFFInfo? {
        let head = file.read(at: 0, count: 12)
        guard head.count == 12, head.matches(Array("WAVE".utf8), at: 8),
              head.matches(Array("RIFF".utf8), at: 0) || head.matches(Array("RF64".utf8), at: 0)
                || head.matches(Array("BW64".utf8), at: 0) else { return nil }
        var info = RIFFInfo()
        var bigDataSize: UInt64?
        var p: UInt64 = 12
        var chunks = 0
        while file.size >= 8, p <= file.size - 8, chunks < 256 {
            chunks += 1
            let h = file.read(at: p, count: 8)
            guard h.count == 8, let raw = h.le32(4) else { break }
            let id = h.text(from: 0, length: 4)
            var size = UInt64(raw)
            if raw == 0xFFFF_FFFF, id == "data", let big = bigDataSize { size = big }
            let body = p + 8
            switch id {
            case "ds64":
                bigDataSize = file.read(at: body, count: 16).le64(8)
            case "bext":
                let b = file.read(at: body, count: Int(min(size, 602)))
                info.description = b.text(from: 0, length: 256)
                info.originator = b.text(from: 256, length: 32)
                info.originationDate = b.text(from: 320, length: 10)
            case "iXML":
                info.ixml = String(decoding: file.read(at: body, count: Int(min(size, 256 << 10))), as: UTF8.self)
            default: break
            }
            if info.originator != nil, info.ixml != nil { break }
            let (next, overflow) = body.addingReportingOverflow(size &+ (size & 1))
            guard !overflow else { break }
            p = next
        }
        return info
    }
}

// MARK: - Insta360 trailer

enum Insta360 {
    private static let magic = Array("8db42d694ccc418790edff439fe026bf".utf8)

    /// The last 72 bytes are 32 of padding, length, version and the magic. Records run backwards from there,
    /// each followed by its u16 id and u32 length. Record 0x101 is protobuf: 1 serial, 2 model.
    static func trailer(_ file: ByteFile) -> (serial: String?, model: String?)? {
        guard file.size > 78 else { return nil }
        let tail = file.read(at: file.size - 78, count: 78)
        guard tail.count == 78, tail.matches(magic, at: 46) else { return nil }
        var end = file.size - 72
        for _ in 0 ..< 32 {
            guard end > 6 else { break }
            let h = file.read(at: end - 6, count: 6)
            guard let id = h.le16(0), let length = h.le32(2), length > 0, UInt64(length) + 6 <= end else { break }
            if id == 0x101 {
                let body = file.read(at: end - 6 - UInt64(length), count: Int(min(length, 8192)))
                let fields = Protobuf.fields(body)
                let serial = fields.first { $0.field == 1 }.map { $0.bytes.text() }
                let model = fields.first { $0.field == 2 }.map { $0.bytes.text() }
                return (serial, model)
            }
            end -= UInt64(length) + 6
        }
        return (nil, nil)
    }
}

// MARK: - Protobuf

enum Protobuf {
    /// Length-delimited fields of one message. Other wire types are skipped. Stops at the first bad byte.
    static func fields(_ b: [UInt8]) -> [(field: Int, bytes: [UInt8])] {
        var out: [(Int, [UInt8])] = []
        var p = 0
        while p < b.count, out.count < 256 {
            guard let (key, n) = varint(b, p) else { break }
            p += n
            let field = Int(key >> 3 & 0xFFFF)
            switch key & 7 {
            case 0:
                guard let (_, n2) = varint(b, p) else { return out }
                p += n2
            case 1: p += 8
            case 5: p += 4
            case 2:
                guard let (length, n2) = varint(b, p), length <= UInt64(b.count) else { return out }
                p += n2
                guard p + Int(length) <= b.count else { return out }
                out.append((field, Array(b[p ..< p + Int(length)])))
                p += Int(length)
            default: return out
            }
        }
        return out
    }

    private static func varint(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < b.count, shift < 64 {
            let byte = b[i]
            v |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (v, i - start) }
            shift += 7
        }
        return nil
    }
}

// MARK: - TIFF

enum TIFF {
    /// ASCII values of `wanted` tags in the first IFD of a TIFF blob, as held in Canon's CMT1 and CMT2 boxes.
    static func strings(_ b: [UInt8], wanted: Set<UInt16>) -> [UInt16: String] {
        guard b.count >= 8 else { return [:] }
        let little = b[0] == 0x49 && b[1] == 0x49
        guard little || (b[0] == 0x4D && b[1] == 0x4D) else { return [:] }
        func u16(_ i: Int) -> UInt16? { little ? b.le16(i) : b.be16(i) }
        func u32(_ i: Int) -> UInt32? { little ? b.le32(i) : b.be32(i) }
        guard let ifd = u32(4), let count = u16(Int(min(ifd, UInt32(Int32.max)))) else { return [:] }
        var out: [UInt16: String] = [:]
        for k in 0 ..< Int(count) {
            let e = Int(ifd) + 2 + k * 12
            guard let tag = u16(e), let type = u16(e + 2), let n = u32(e + 4) else { break }
            guard wanted.contains(tag), type == 2, n > 0, n < 4096 else { continue }
            if n <= 4 {
                out[tag] = b.text(from: e + 8, length: Int(n))
            } else if let at = u32(e + 8), at < UInt32(b.count) {
                out[tag] = b.text(from: Int(at), length: Int(n))
            }
        }
        return out
    }
}

// MARK: - GoPro GPMF

enum GPMF {
    /// A string value: fourcc, type 'c', struct size, u16 repeat, text. Fixed layout, so a scan is enough.
    static func string(_ b: [UInt8], key: String) -> String? {
        let needle = Array(key.utf8)
        var from = 0
        while let i = b.find(needle, from: from) {
            from = i + 4
            guard i + 8 <= b.count, b[i + 4] == UInt8(ascii: "c"), let repeatCount = b.be16(i + 6) else { continue }
            let length = Int(b[i + 5]) * Int(repeatCount)
            guard length > 0, length <= 128, i + 8 + length <= b.count else { continue }
            let s = b.text(from: i + 8, length: length)
            if !s.isEmpty { return s }
        }
        return nil
    }
}
