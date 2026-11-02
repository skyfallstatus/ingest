// Shared helpers for the Formats tests. Nothing here writes outside the temporary fixtures folder.
import Foundation
@testable import IngestCore

/// Public sample files, for the tests that want real bytes. Those tests skip when the files aren't there.
enum Samples {
    static let root = ProcessInfo.processInfo.environment["INGEST_SAMPLES"] ?? "/tmp/ingest-samples"
    static let r3d = root + "/F099_C001_0317IH.R3D"
    static let braw = "/Applications/Blackmagic RAW/Blackmagic RAW Speed Test.app/Contents/Resources/profile.braw"
}

/// A listing as the walker would give it, skipping the same junk. `names` keeps only matching files.
func listing(_ root: String, depth: Int = 8, only names: ((String) -> Bool)? = nil) -> [CardFile] {
    var out: [CardFile] = []
    func walk(_ dir: String, _ rel: String, _ level: Int) {
        guard level <= depth, let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in items.sorted() {
            if name.hasPrefix("._") || name == ".DS_Store" || name == ".Spotlight-V100" || name == ".Trashes"
                || name == ".fseventsd" || name == ".TemporaryItems" { continue }
            let path = dir + "/" + name
            let r = rel.isEmpty ? name : rel + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                walk(path, r, level + 1)
            } else if (st.st_mode & S_IFMT) == S_IFREG, names?(name) ?? true {
                out.append(CardFile(relPath: r, size: UInt64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec),
                                    kind: CardProber.kind(ofRelativePath: r)))
            }
        }
    }
    walk(root, "", 0)
    return out
}

/// A throwaway folder under /tmp that removes itself.
final class Fixture {
    let root: URL
    init(_ name: String = "fixture") {
        root = URL(fileURLWithPath: "/tmp/ingest-formats-fixtures/\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, _ bytes: [UInt8] = []) -> String {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url.path
    }
    func write(_ rel: String, text: String) { write(rel, Array(text.utf8)) }
    func files() -> [CardFile] { listing(root.path, depth: 12) }
    func probe(focus: Set<String>? = nil) -> ProbeResult { CardProber.probe(root: root, files: files(), focus: focus) }
}

// MARK: - Byte builders. Layouts come from the research docs, checked against real files where one exists.

func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
func le32(_ v: Int) -> [UInt8] { be32(v).reversed() }
func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

func atom(_ type: String, _ payload: [UInt8] = []) -> [UInt8] { be32(payload.count + 8) + FourCC(stringLiteral: type).bytes + payload }

func mvhd(unix: Int) -> [UInt8] {
    atom("mvhd", [0, 0, 0, 0] + be32(unix + 2_082_844_800) + be32(unix + 2_082_844_800) + be32(600) + be32(600) + Array(repeating: 0, count: 80))
}

/// `moov/meta` with `keys` and `ilst`, the way BRAW and iPhone clips store metadata.
/// `numbers` are the big-endian u32 values real BRAW writes: type 77, as in `multicard_volume_count`.
func keysMeta(_ pairs: [(String, String)], numbers: [(String, UInt32)] = []) -> [UInt8] {
    var keys = [UInt8](repeating: 0, count: 4) + be32(pairs.count + numbers.count)
    var ilst: [UInt8] = []
    let values = pairs.map { ($0.0, be32(1) + be32(0) + ascii($0.1)) } + numbers.map { ($0.0, be32(77) + be32(0) + be32(Int($0.1))) }
    for (i, (name, value)) in values.enumerated() {
        keys += be32(name.utf8.count + 8) + ascii("mdta") + ascii(name)
        let data = atom("data", value)
        ilst += be32(data.count + 8) + be32(i + 1) + data
    }
    let hdlr = atom("hdlr", [UInt8](repeating: 0, count: 8) + ascii("mdta") + [UInt8](repeating: 0, count: 13))
    return atom("meta", hdlr + atom("keys", keys) + atom("ilst", ilst))
}

/// `wide`, `mdat`, then `moov` at the end, with no `ftyp`. The shape of real BRAW.
func brawBytes(_ pairs: [(String, String)], unix: Int = 1_700_000_000, mdat: Int = 2048) -> [UInt8] {
    atom("wide") + atom("mdat", [UInt8](repeating: 0x55, count: mdat)) + atom("moov", mvhd(unix: unix) + keysMeta(pairs))
}

func mp4Bytes(major: String = "isom", compatible: [String] = ["mp42"], moov: [UInt8], mdat: Int = 512) -> [UInt8] {
    atom("ftyp", ascii(major) + be32(0) + compatible.flatMap(ascii)) + atom("mdat", [UInt8](repeating: 0x33, count: mdat)) + atom("moov", moov)
}

let mxfPartitionPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]

/// An MXF laid out as real ones are: header partition, optional Identification set, footer partition and RIP.
/// `cut` stops before the footer. `rip: false` keeps the footer and drops the pack.
func mxfBytes(company: String? = nil, product: String = "ALEXA 35", status: UInt8 = 4, cut: Bool = false, rip: Bool = true,
              text: String = "", pad: Int = 4096) -> [UInt8] {
    func utf16(_ s: String) -> [UInt8] { s.utf8.flatMap { [0, $0] } }
    var out = mxfPartitionPrefix + [0x02, status, 0x00, 0x10] + [UInt8](repeating: 0, count: 16)
    if let company {
        let set = be16(0x3C01) + be16(company.utf8.count * 2) + utf16(company) + be16(0x3C02) + be16(product.utf8.count * 2) + utf16(product)
        out += [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x30, 0x00, 0x83, 0x00] + be16(set.count) + set
    }
    out += ascii(text) + [UInt8](repeating: 0, count: pad)
    if cut { return out }
    let footerAt = out.count
    out += mxfPartitionPrefix + [0x04, 0x04, 0x00, 0x10] + [UInt8](repeating: 0, count: 16)
    guard rip else { return out }
    out += [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x11, 0x01, 0x00, 28]
    return out + [0, 0, 0, 0] + be32(0) + be32(0) + [0, 0, 0, 0] + be32(0) + be32(footerAt) + be32(45)
}

func xavcXML(codec: String = "AVC_3840_2160_H422IP@L52") -> String {
    #"<NonRealTimeMeta xmlns="urn:x"><VideoFormat><VideoFrame videoCodec="\#(codec)"/></VideoFormat><Device manufacturer="Sony" modelName="ILME-FX6V" serialNo="7654321"/></NonRealTimeMeta>"#
}

func r3dTag(_ tag: Int, _ s: String) -> [UInt8] { be16(s.utf8.count + 4) + be16(tag) + ascii(s) }

/// Header laid out as in the real F099 sample: RED2 atom, `rdi` record, then u16 length and tags.
/// Then padding, then a 4 KB footer with its type at +4 and the file size at +0x40.
func r3dBytes(footer: String?, pad: Int = 8192, declaredSize: Int? = nil, tags: [(Int, String)] = []) -> [UInt8] {
    var tagBytes: [UInt8] = []
    let all: [(Int, String)] = tags + [(0x1000, "01:00:04:19"), (0x1001, "12:13:32:05"), (0x1019, "A"), (0x101A, "001"), (0x101B, "001"),
                                       (0x1023, "20260120"), (0x1024, "121327"), (0x1025, "1.0.0")]
    for (t, s) in all { tagBytes += r3dTag(t, s) }
    var header = [UInt8](repeating: 0, count: 0x44 - 8)
    header += ascii("rdi") + [1] + [UInt8](repeating: 0, count: 20)
    header += be16(tagBytes.count) + tagBytes
    var head = be32(header.count + 8) + ascii("RED2") + header
    head += [UInt8](repeating: 0, count: 4096 - head.count)
    let body = [UInt8](repeating: 0xAB, count: pad)
    guard let footer else { return head + body }
    let total = head.count + body.count + 4096
    var foot = be32(0x495) + ascii(footer) + [UInt8](repeating: 0, count: 0x38)
    foot += be32(0) + be32(declaredSize ?? total)
    foot += [UInt8](repeating: 0, count: 4096 - foot.count)
    return head + body + foot
}

func riffBytes(originator: String, date: String, description: String = "", form: String = "RIFF") -> [UInt8] {
    var bext = ascii(description) + [UInt8](repeating: 0, count: 256 - description.utf8.count)
    bext += ascii(originator) + [UInt8](repeating: 0, count: 32 - originator.utf8.count)
    bext += [UInt8](repeating: 0, count: 32) + ascii(date) + ascii("12:00:00")
    bext += [UInt8](repeating: 0, count: 602 - bext.count)
    let data = [UInt8](repeating: 0, count: 64)
    let chunks = ascii("bext") + le32(bext.count) + bext + ascii("data") + le32(data.count) + data
    return ascii(form) + le32(chunks.count + 4) + ascii("WAVE") + chunks
}

let sonyProfileXML = #"""
<?xml version="1.0" encoding="UTF-8"?>
<MediaProfile xmlns="http://xmlns.sony.net/pro/metadata/mediaprofile" createdAt="2026-01-20T18:34:15+01:00" version="2.30">
	<Properties>
		<System systemId="0000AAFFFE000002" systemKind="ILME-FX6V ver.6.000" masterVersion="XAVC-M4@2.00.00"/>
	</Properties>
</MediaProfile>
"""#

func sonyClipXML(model: String = "ILME-FX3", serial: String = "4294967295", date: String = "2026-10-22T01:48:15+09:00",
                 systemId: String = "0000AAFFFE000001") -> String {
    let umid = "060A2B340101010501010D431300000000000000000000AB" + systemId
    return #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20" lastUpdate="2026-01-20T18:04:03+01:00">
    	<TargetMaterial umidRef="\#(umid)"/>
    	<CreationDate value="\#(date)"/>
    	<Device manufacturer="Sony" modelName="\#(model)" serialNo="\#(serial)"/>
    </NonRealTimeMeta>
    """#
}

func hasIssue(_ r: ProbeResult, _ code: String, _ severity: IssueSeverity) -> Bool {
    r.issues.contains { $0.code == code && $0.severity == severity }
}

func head(_ path: String, _ n: Int) -> [UInt8] {
    guard let f = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? f.close() }
    return [UInt8](f.readData(ofLength: n))
}

func look(_ build: (Fixture) -> Void) -> VolumeLook {
    let f = Fixture("look")
    build(f)
    return CardProber.look(atRoot: f.root)
}

func isMaybe(_ l: VolumeLook) -> Bool { if case .maybeCard = l { true } else { false } }

/// SplitMix64: a small generator, so a failing run can be repeated exactly.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func bytes(_ n: Int) -> [UInt8] { (0 ..< n).map { _ in UInt8(truncatingIfNeeded: next()) } }
}
