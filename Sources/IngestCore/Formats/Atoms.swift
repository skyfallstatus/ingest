// One QuickTime atom walker, used for MP4, MOV, BRAW, INSV, LRV, NEV, CRM.
import Foundation

struct FourCC: Hashable, ExpressibleByStringLiteral {
    let raw: UInt32
    init(raw: UInt32) { self.raw = raw }
    init(stringLiteral s: String) {
        var v: UInt32 = 0
        for u in s.unicodeScalars { v = v << 8 | (u.value & 0xFF) }
        raw = v
    }
    var bytes: [UInt8] { [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)] }
    var isPrintable: Bool { bytes.allSatisfy { (0x20 ... 0x7E).contains($0) || $0 == 0xA9 } }
}

struct Atom {
    var type: FourCC
    var start: UInt64
    var payload: UInt64
    var end: UInt64
    var payloadSize: UInt64 { end - payload }
}

enum AtomStop { case end, overrun, garbage, stopped, limit }

enum AtomWalker {
    /// The atom whose header sits at `offset`. nil when no valid header fits before `limit`.
    static func header(_ file: ByteFile, at offset: UInt64, limit: UInt64) -> Atom? {
        guard offset < limit, limit - offset >= 8 else { return nil }
        let b = file.read(at: offset, count: 16)
        guard let size32 = b.be32(0), let type = b.be32(4) else { return nil }
        var headerLength: UInt64 = 8
        var size = UInt64(size32)
        if size32 == 1 {
            guard let big = b.be64(8) else { return nil }
            size = big
            headerLength = 16
        } else if size32 == 0 {
            size = limit - offset       // "runs to the end of the enclosing space"
        }
        guard size >= headerLength else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow else { return nil }
        return Atom(type: FourCC(raw: type), start: offset, payload: offset + headerLength, end: end)
    }

    /// Walks the top level of a file. An atom whose end passes EOF is kept and reported as `.overrun`.
    static func topLevel(_ file: ByteFile, maxAtoms: Int = 512, stopAt: (Atom) -> Bool = { _ in false })
        -> (atoms: [Atom], stop: AtomStop) {
        var atoms: [Atom] = []
        var p: UInt64 = 0
        let eof = file.size
        while eof >= 8, p <= eof - 8 {
            guard atoms.count < maxAtoms else { return (atoms, .limit) }
            guard let a = header(file, at: p, limit: eof), a.type.isPrintable else { return (atoms, .garbage) }
            atoms.append(a)
            if a.end > eof { return (atoms, .overrun) }
            if stopAt(a) { return (atoms, .stopped) }
            p = a.end
        }
        return (atoms, .end)
    }

    /// Children of a container, skipping `skip` bytes of payload first. Stops at the first bad child.
    static func children(_ file: ByteFile, of parent: Atom, skip: UInt64 = 0, maxAtoms: Int = 2048) -> [Atom] {
        var out: [Atom] = []
        var p = parent.payload + skip
        while parent.end >= 8, p <= parent.end - 8, out.count < maxAtoms {
            guard let a = header(file, at: p, limit: parent.end), a.end <= parent.end else { break }
            out.append(a)
            p = a.end
        }
        return out
    }

    static func first(_ type: FourCC, in atoms: [Atom]) -> Atom? { atoms.first { $0.type == type } }

    /// Leaf payload, capped.
    static func payload(_ file: ByteFile, _ atom: Atom, cap: Int = 1 << 20) -> [UInt8] {
        file.read(at: atom.payload, count: Int(min(atom.payloadSize, UInt64(cap))))
    }
}

/// A `meta` atom is a plain container in QuickTime and has 4 extra bytes in ISO files.
func metaChildren(_ file: ByteFile, of meta: Atom) -> [Atom] {
    let probe = file.read(at: meta.payload, count: 12)
    let isoStyle = probe.be32(8) == FourCC("hdlr").raw
    return AtomWalker.children(file, of: meta, skip: isoStyle ? 4 : 0)
}

struct MetaValue {
    var text: String?
    var number: Int64?
    /// The value as text, whichever way it was stored.
    var string: String? { text ?? number.map(String.init) }
}

struct QTTrack {
    var handlerName: String
    var format: FourCC?
    var stbl: Atom?
}

/// What a QuickTime-style file says about itself. Everything is optional: a clip can lack any of it.
struct QTInfo {
    var major: FourCC?
    var compatible: [FourCC] = []
    /// `mvhd` creation time as Unix seconds. nil when unset.
    var mvhdCreation: Int64?
    /// `moov/meta` values by key name: BRAW keys, com.apple.*, com.arri.*.
    var keys: [String: MetaValue] = [:]
    /// Direct children of `moov/udta`.
    var udta: [FourCC: Atom] = [:]
    /// `moov/udta/meta/ilst` text items, such as `©too`.
    var ilst: [FourCC: String] = [:]
    var moovChildren: [Atom] = []
    var topLevel: [Atom] = []
    var tracks: [QTTrack] = []

    func key(_ name: String) -> String? { keys[name]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    func track(format: FourCC) -> QTTrack? { tracks.first { $0.format == format } }
    func hasBrand(_ b: FourCC) -> Bool { major == b || compatible.contains(b) }
}

enum QuickTime {
    /// 1904-01-01 to 1970-01-01, in seconds.
    private static let macEpochOffset: Int64 = 2_082_844_800

    static func inspect(_ file: ByteFile) -> QTInfo? {
        let walk = AtomWalker.topLevel(file)
        guard !walk.atoms.isEmpty else { return nil }
        var info = QTInfo()
        info.topLevel = walk.atoms

        if let ftyp = AtomWalker.first("ftyp", in: walk.atoms) {
            let b = AtomWalker.payload(file, ftyp, cap: 256)
            if let major = b.be32(0) { info.major = FourCC(raw: major) }
            var i = 8
            while let c = b.be32(i) { info.compatible.append(FourCC(raw: c)); i += 4 }
        }
        guard let moov = AtomWalker.first("moov", in: walk.atoms), moov.end <= file.size else { return info }
        let children = AtomWalker.children(file, of: moov)
        info.moovChildren = children

        for atom in children {
            switch atom.type {
            case "mvhd": info.mvhdCreation = mvhdCreation(file, atom)
            case "meta": readKeys(file, meta: atom, into: &info)
            case "udta":
                let items = AtomWalker.children(file, of: atom)
                for item in items where info.udta[item.type] == nil { info.udta[item.type] = item }
                if let meta = info.udta["meta"] { readIlstText(file, meta: meta, into: &info) }
            case "trak":
                if info.tracks.count < 16 { info.tracks.append(track(file, atom)) }
            default: break
            }
        }
        return info
    }

    private static func mvhdCreation(_ file: ByteFile, _ atom: Atom) -> Int64? {
        let b = file.read(at: atom.payload, count: 16)
        guard let version = b.first else { return nil }
        let raw: UInt64?
        if version == 1 { raw = b.be64(4) } else { raw = b.be32(4).map(UInt64.init) }
        guard let raw, raw > 0, raw < UInt64(Int64.max) else { return nil }
        let unix = Int64(raw) - macEpochOffset
        return unix > 0 && unix < 4_102_444_800 ? unix : nil     // before 2100, so calendars stay sane
    }

    /// `keys` lists names; `ilst` items are 1-based indexes into it.
    private static func readKeys(_ file: ByteFile, meta: Atom, into info: inout QTInfo) {
        let kids = metaChildren(file, of: meta)
        guard let keysAtom = AtomWalker.first("keys", in: kids),
              let ilst = AtomWalker.first("ilst", in: kids) else { return }
        let k = AtomWalker.payload(file, keysAtom, cap: 1 << 20)
        guard let count = k.be32(4) else { return }
        var names: [String] = []
        var p = 8
        for _ in 0 ..< min(count, 4096) {
            guard let size = k.be32(p), size >= 8, Int(size) <= k.count - p else { break }
            names.append(k.text(from: p + 8, length: Int(size) - 8))
            p += Int(size)
        }
        for item in AtomWalker.children(file, of: ilst, maxAtoms: 4096) {
            let index = Int(item.type.raw)
            guard index >= 1, index <= names.count,
                  let data = AtomWalker.first("data", in: AtomWalker.children(file, of: item)) else { continue }
            let v = value(file, data)
            if info.keys[names[index - 1]] == nil { info.keys[names[index - 1]] = v }
        }
    }

    private static func readIlstText(_ file: ByteFile, meta: Atom, into info: inout QTInfo) {
        guard let ilst = AtomWalker.first("ilst", in: metaChildren(file, of: meta)) else { return }
        for item in AtomWalker.children(file, of: ilst, maxAtoms: 256) {
            guard let data = AtomWalker.first("data", in: AtomWalker.children(file, of: item)),
                  let s = value(file, data).text, !s.isEmpty else { continue }
            info.ilst[item.type] = s
        }
    }

    /// A `data` atom: 4 bytes type, 4 bytes locale, value. Values stay small: covers are not read.
    private static func value(_ file: ByteFile, _ data: Atom) -> MetaValue {
        let b = file.read(at: data.payload, count: Int(min(data.payloadSize, 1024)))
        guard let type = b.be32(0), b.count >= 8 else { return MetaValue() }
        let body = Array(b[8...])
        switch type & 0xFF_FFFF {
        case 1: return MetaValue(text: body.text())
        case 2: return MetaValue(text: body.utf16be(from: 0, length: body.count & ~1))
        case 21, 22, 65, 66, 67, 74, 75, 76, 77, 78:
            var n: Int64 = 0
            guard (1 ... 8).contains(body.count) else { return MetaValue() }
            for byte in body { n = n << 8 | Int64(byte) }
            return MetaValue(number: n)
        default: return MetaValue()
        }
    }

    private static func track(_ file: ByteFile, _ trak: Atom) -> QTTrack {
        var t = QTTrack(handlerName: "")
        guard let mdia = AtomWalker.first("mdia", in: AtomWalker.children(file, of: trak)) else { return t }
        let mdiaKids = AtomWalker.children(file, of: mdia)
        if let hdlr = AtomWalker.first("hdlr", in: mdiaKids) {
            let b = AtomWalker.payload(file, hdlr, cap: 96)
            if b.count > 24 {
                // QuickTime stores a Pascal string here, ISO a C string.
                let start = Int(b[24]) == b.count - 25 ? 25 : 24
                t.handlerName = b.text(from: start)
            }
        }
        guard let minf = AtomWalker.first("minf", in: mdiaKids),
              let stbl = AtomWalker.first("stbl", in: AtomWalker.children(file, of: minf)) else { return t }
        t.stbl = stbl
        if let stsd = AtomWalker.first("stsd", in: AtomWalker.children(file, of: stbl)),
           let format = file.read(at: stsd.payload, count: 16).be32(12) {
            t.format = FourCC(raw: format)
        }
        return t
    }

    /// Where the first sample of a track sits: first chunk offset plus first entry of `stsz`.
    static func firstSample(_ file: ByteFile, _ track: QTTrack) -> (offset: UInt64, size: Int)? {
        guard let stbl = track.stbl else { return nil }
        let kids = AtomWalker.children(file, of: stbl)
        var offset: UInt64?
        if let stco = AtomWalker.first("stco", in: kids) {
            offset = file.read(at: stco.payload, count: 12).be32(8).map(UInt64.init)
        } else if let co64 = AtomWalker.first("co64", in: kids) {
            offset = file.read(at: co64.payload, count: 16).be64(8)
        }
        guard let offset, offset < file.size, let stsz = AtomWalker.first("stsz", in: kids) else { return nil }
        let b = file.read(at: stsz.payload, count: 16)
        guard let fixed = b.be32(4) else { return nil }
        let size = fixed != 0 ? fixed : (b.be32(12) ?? 0)
        guard size > 0 else { return nil }
        return (offset, Int(min(size, 4 << 20)))
    }

    /// Can this file play as it is? Top-level atoms only, so it stays cheap.
    /// `cutShort` is an index with its data gone: R6 and other moov-first bodies write `moov` before `mdat`.
    /// `unconfirmed` is a walk that ended without an answer: it's neither a pass nor a fault.
    enum IndexState { case present, missing, cutShort, otherContainer, unconfirmed }

    static func indexState(_ file: ByteFile) -> IndexState {
        let head = file.read(at: 0, count: 16)
        if head.isEmpty { return file.size == 0 ? .missing : .present }
        if file.size == 0 { return .present }       // virtual volume with no listed size: nothing to judge by
        if isOtherContainer(head) { return .otherContainer }
        let fragments: Set<FourCC> = ["moof", "sidx", "styp", "mfra"]
        let walk = AtomWalker.topLevel(file, stopAt: { fragments.contains($0.type) })
        if let moov = AtomWalker.first("moov", in: walk.atoms) {
            if moov.end > file.size { return .missing }
            // Insta360 keeps a non-atom trailer after `moov`, so only an `mdat` past the end counts.
            if walk.stop == .overrun, walk.atoms.last?.type == "mdat" { return .cutShort }
            return .present
        }
        if let last = walk.atoms.last, fragments.contains(last.type) { return .unconfirmed }   // nothing says where it should end
        switch walk.stop {
        case .limit: return .unconfirmed
        case .garbage: return tailHasMoov(file) ? .present : .missing
        default: return .missing
        }
    }

    /// The first bytes are a real top-level atom. What separates a Nikon R3D NE from a RED file.
    static func startsWithAtom(_ h: [UInt8]) -> Bool {
        guard let size = h.be32(0), let type = h.be32(4), size == 0 || size == 1 || size >= 8 else { return false }
        let known: Set<FourCC> = ["ftyp", "wide", "free", "skip", "mdat", "moov", "pnot", "styp"]
        return known.contains(FourCC(raw: type))
    }

    private static func isOtherContainer(_ h: [UInt8]) -> Bool {
        h.matches([0x06, 0x0E, 0x2B, 0x34], at: 0)              // MXF
            || h.matches(Array("RIFF".utf8), at: 0)
            || h.matches([0x1A, 0x45, 0xDF, 0xA3], at: 0)       // Matroska
            || h.matches([0x00, 0x00, 0x01, 0xBA], at: 0)       // MPEG PS
            || h.first == 0x47                                  // MPEG TS
    }

    /// The chain of atoms broke. The index may still exist past the break, so look before saying it doesn't.
    private static func tailHasMoov(_ file: ByteFile) -> Bool {
        let span = UInt64(8 << 20)
        let tailStart = file.size > span ? file.size - span : 0
        let tail = file.read(at: tailStart, count: Int(min(span, file.size)))
        return hasMovieHeader(tail) || hasMovieHeader(file.read(at: 0, count: Int(min(span, file.size))))
    }

    private static func hasMovieHeader(_ b: [UInt8]) -> Bool {
        let moov = FourCC("moov").bytes, mvhd = FourCC("mvhd").bytes
        var from = 0
        while let i = b.find(moov, from: from) {
            if b.matches(mvhd, at: i + 8) || b.matches(mvhd, at: i + 16) { return true }
            from = i + 4
        }
        return false
    }
}
