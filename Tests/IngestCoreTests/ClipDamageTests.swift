import Foundation
import Testing
@testable import IngestCore

@Suite("Damaged clips")
struct ClipDamageTests {
    @Test("R3D NE with a custom Nikon prefix is not a damaged RED clip") func nikonPrefix() {
        let f = Fixture("d6")
        let nctg = atom("NCTG", be32(2) + be16(2) + be16(9) + ascii("NIKON ZR\u{0}"))
        let moov = mvhd(unix: 1_760_000_000) + atom("udta", atom("NCDT", nctg))
        f.write("DCIM/100NC_ZR/ROM_0001.R3D", mp4Bytes(moov: moov, mdat: 300 << 10))
        let r = f.probe()
        #expect(!r.issues.contains { $0.code.hasPrefix("red.") })
    }
    @Test("A truncated R3D NE must not pass") func nikonTruncated() {
        let f = Fixture("d6b")
        let bytes: [UInt8] = atom("ftyp", ascii("isom") + be32(0)) + Array(atom("mdat", [UInt8](repeating: 1, count: 4096)).dropLast(1024))
        f.write("DCIM/100NC_ZR/DSC_0001.R3D", bytes)
        let r = f.probe()
        #expect(r.issues.contains { $0.severity == .hold })
    }
    @Test("An extreme 64-bit mvhd date must not crash") func hugeMvhd() {
        let f = Fixture("d10")
        let values: [UInt64] = [UInt64(Int64.max) - 1, UInt64(1) << 62, UInt64(1) << 48, 253_402_300_800 + 2_082_844_800]
        for (i, raw) in values.enumerated() {
            var v1: [UInt8] = [1, 0, 0, 0]
            for s in stride(from: 56, through: 0, by: -8) { v1.append(UInt8((raw >> UInt64(s)) & 255)) }
            v1 += [UInt8](repeating: 0, count: 104)
            f.write("DCIM/100TEST/MVI_000\(i).MP4", mp4Bytes(moov: atom("mvhd", v1)))
        }
        _ = f.probe()   // reaching here is the test
    }
    @Test("A moov-first clip cut short is held") func moovFirstCut() {
        let f = Fixture("d11")
        let moov = atom("moov", mvhd(unix: 1_760_000_000))
        let cut: [UInt8] = atom("ftyp", ascii("mp42") + be32(0)) + moov + be32(1 << 20) + ascii("mdat") + [UInt8](repeating: 2, count: 4096)
        f.write("DCIM/100EOSR6/MVI_0001.MP4", cut)
        #expect(f.probe().issues.contains { $0.severity == .hold })
    }
    @Test func `A trailer after moov that isn't an atom is not called cut short`() {
        let f = Fixture("trailer")
        f.write("a.mp4", mp4Bytes(moov: mvhd(unix: 1_760_000_000)) + [0, 2, 0, 0, 1, 0, 0, 0, 9, 9, 9])
        #expect(f.probe().issues.isEmpty)
    }
}
