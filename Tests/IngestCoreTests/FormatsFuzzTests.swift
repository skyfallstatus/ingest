// Cards can be corrupt. No input may crash a parser. These assert only that every call returns.
import Foundation
import Testing
@testable import IngestCore

private func everyParser(_ path: String) {
    guard let file = ByteFile(path: path) else { return }
    if let qt = QuickTime.inspect(file) {
        _ = Sony.nrtmXML(file, qt)
        _ = Canon.read(file, qt)
        _ = Nikon.tags(file, qt)
        _ = DJI.serial(file, qt)
        _ = Sony.rtmdSerial(file, qt, model: "ILME-FX3")
        _ = qt.udtaText(file, "©mod")
    }
    _ = QuickTime.indexState(file)
    _ = R3D.tags(file)
    _ = R3D.footer(file)
    _ = MXF.ending(file)
    if let mxf = MXF.parse(file) { _ = ARRIMetadata.read(file, head: mxf.head, deep: true) }
    _ = RIFF.parse(file)
    _ = Insta360.trailer(file)
    let head = file.read(at: 0, count: 4096)
    _ = Protobuf.fields(head)
    _ = TIFF.strings(head, wanted: [0x0110, 0x9003])
    _ = GPMF.string(head, key: "MINF")
    _ = Sony.scanSerial(head, model: "ILME-FX3")
    _ = ARRIMetadata.modelInALE(file)
}

private func seeds() -> [[UInt8]] {
    let tags = [(0x10A0, "KOMODO"), (0x1006, "x")]
    var out: [[UInt8]] = [
        brawBytes([("manufacturer", "Blackmagic Design"), ("camera_type", "x"), ("multicard_volume_count", "2")]),
        mp4Bytes(major: "XAVC", moov: mvhd(unix: 1) + atom("udta", atom("NCDT", atom("NCTG", be32(2) + be16(2) + be16(4) + ascii("Z 8\0"))) + atom("GPMF", ascii("MINF")))),
        r3dBytes(footer: "REOC", tags: tags),
        riffBytes(originator: "ZOOM F6", date: "2026-01-20"),
        riffBytes(originator: "x", date: "2026-01-20", form: "RF64"),
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00, 0x10] + [UInt8](repeating: 0, count: 64)
            + [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, 0x30, 0x00, 0x83, 0, 0, 40]
            + be16(0x3C01) + be16(8) + [0, 0x41, 0, 0x52, 0, 0x52, 0, 0x49] + be16(0x3C06) + be16(8) + [0x07, 0xEA, 1, 20, 0, 0, 0, 0],
        ascii(sonyClipXML()),
    ]
    // Real bytes where they exist on this machine: heads and tails of real files.
    for path in [Samples.r3d, Samples.braw] {
        if let f = ByteFile(path: path) {
            out.append(f.read(at: 0, count: 8192))
            out.append(f.read(at: f.size > 8192 ? f.size - 8192 : 0, count: 8192))
        }
    }
    return out
}

@Suite("Formats fuzz")
struct FormatsFuzz {
    @Test func `Truncation at every length of every seed`() {
        let f = Fixture("fuzz")
        let path = f.write("clip.bin")
        for seed in seeds() {
            let step = max(seed.count / 400, 1)
            var n = 0
            while n <= seed.count {
                FileManager.default.createFile(atPath: path, contents: Data(seed.prefix(n)))
                everyParser(path)
                n += step
            }
        }
    }

    @Test func `Corrupted bytes in every seed`() {
        var rng = SplitMix(state: 0xC0FFEE)
        let f = Fixture("fuzz")
        let path = f.write("clip.bin")
        for seed in seeds() {
            for _ in 0 ..< 400 {
                var b = seed
                for _ in 0 ..< 1 + rng.below(16) {
                    let i = rng.below(b.count)
                    // Sizes and counts do the damage, so favour extreme values.
                    b[i] = [0x00, 0xFF, 0x80, 0x7F, UInt8(truncatingIfNeeded: rng.next())][rng.below(5)]
                }
                FileManager.default.createFile(atPath: path, contents: Data(b))
                everyParser(path)
            }
        }
    }

    @Test func `Pure noise, with and without a plausible start`() {
        var rng = SplitMix(state: 42)
        let f = Fixture("fuzz")
        let path = f.write("clip.bin")
        let starts: [[UInt8]] = [[], ascii("RIFF"), [0, 0, 0, 8] + ascii("RED2"), [0, 0, 0, 16] + ascii("ftyp"), [0, 0, 0, 1] + ascii("moov"),
                                 [0, 0, 0, 0] + ascii("moov"), [0xFF, 0xFF, 0xFF, 0xFF] + ascii("moov"), [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]]
        for start in starts {
            for _ in 0 ..< 300 {
                let b = start + rng.bytes(rng.below(6000))
                FileManager.default.createFile(atPath: path, contents: Data(b))
                everyParser(path)
            }
        }
    }

    @Test func `Whole probes over corrupt files of every type`() {
        var rng = SplitMix(state: 7)
        let names = ["M4ROOT/MEDIAPRO.XML", "M4ROOT/CLIP/A082C001_260120DB.MP4", "M4ROOT/CLIP/A082C001_260120DBM01.XML", "XDROOT/Clip/a.MXF",
                     "A.RDM/A001_C001_0101XY.RDC/A001_C001_0101XY_001.R3D", "b.braw", "b.braw2", "c.insv", "d.WAV", "DCIM/100MSDCF/e.JPG",
                     "DCIM/100MSDCF/e.ARW", "DCIM/100EOSR5/f.CR3", "g.NEV", "DSC_1.R3D", "A001R0Z3/h.ale", ".codexvfs"]
        let all = seeds()
        for _ in 0 ..< 120 {
            let f = Fixture("fuzz")
            for name in names {
                var b = all[rng.below(all.count)]
                if rng.below(2) == 0, !b.isEmpty { b[rng.below(b.count)] = 0xFF }
                f.write(name, Array(b.prefix(rng.below(b.count + 1))))
            }
            _ = f.probe()
            _ = CardProber.look(atRoot: f.root)
        }
    }
}
