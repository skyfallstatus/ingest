import Foundation
import Testing
@testable import IngestCore

@Suite("Clips in many files")
struct MultiFileGapTests {
    let clip = mp4Bytes(major: "mp42", moov: mvhd(unix: 1_760_000_000))
    let wide = "A_0089C378H261015_190547EJ_ABCDE"

    @Test func `doc-derived: Canon streams in a row are one clip with no issue`() {
        let f = Fixture("canon")
        for n in 1 ... 3 { f.write("XFVC/REEL_0089/\(wide)_00\(n).MP4", clip) }
        let r = f.probe()
        #expect(r.issues.isEmpty)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.reel == "A_0089")
    }

    @Test func `doc-derived: a hole in Canon streams is a hold, wherever the number sits`() {
        let f = Fixture("canon")
        for n in [1, 3] { f.write("XFVC/REEL_0089/\(wide)_00\(n).MP4", clip) }
        #expect(hasIssue(f.probe(), "canon.missing-stream", .hold))
        let g = Fixture("canon")
        for n in [1, 3] { g.write("XFVC/REEL_0001/A001C001_260120XY_00\(n)_CANON.MP4", clip) }
        #expect(hasIssue(g.probe(), "canon.missing-stream", .hold))
    }

    @Test func `doc-derived: streams starting late could be a relay, so a note`() {
        let f = Fixture("canon")
        for n in [2, 3] { f.write("XFVC/REEL_0089/\(wide)_00\(n).MP4", clip) }
        let r = f.probe()
        #expect(hasIssue(r, "canon.missing-stream", .note))
        #expect(!r.issues.contains { $0.severity == .hold })
    }

    @Test func `A name that isn't Canon's shape has no stream to miss`() {
        #expect(ClipName.canonStream("A082C001_260120DB_001") == nil)       // Sony shape
        #expect(ClipName.canonStream("VID_20260531_010338_00_001") == nil)  // Insta360 counter
        #expect(ClipName.canonStream("A064C004_260507MR_S000") == nil)      // real camera name
        #expect(ClipName.canonStream(wide) == nil)                          // real R5 II name, no stream
        #expect(ClipName.canonStream(wide + "_012")?.stream == 12)
        let f = Fixture("sony")
        for n in [1, 5] { f.write("Clip_00\(n).MP4", clip); f.write("VID_20260531_010338_00_00\(n).mp4", clip) }
        #expect(f.probe().issues.isEmpty)
    }

    @Test func `doc-derived: a .mov gap beside R3D parts is a proxy gap, not a hold`() {
        let f = Fixture("red")
        let dir = "A001_1101XY.RDM/A001_C001_1101XY.RDC/"
        f.write(dir + "A001_C001_1101XY_001.R3D", r3dBytes(footer: "REOB"))
        f.write(dir + "A001_C001_1101XY_001.mov", clip)
        f.write(dir + "A001_C001_1101XY_003.mov", clip)
        #expect(f.probe().issues.isEmpty)
    }

    @Test func `doc-derived: a RED ProRes clip in a row passes`() {
        let f = Fixture("red")
        let dir = "A001_1101XY.RDM/A001_C001_1101XY.RDC/"
        for n in 1 ... 3 { f.write(dir + "A001_C001_1101XY_00\(n).mov", clip) }
        #expect(f.probe().issues.isEmpty)
    }

    @Test func `GoPro: a hole can't be looping, leading chapters gone can`() {
        let f = Fixture("gopro")
        for name in ["GX010001", "GX030001", "GX030002", "GX040002"] { f.write("DCIM/100GOPRO/\(name).MP4", clip) }
        let r = f.probe().issues.filter { $0.code == "gopro.chapter-gap" }
        #expect(r.filter { $0.severity == .hold }.count == 1)
        #expect(r.filter { $0.severity == .note }.count == 1)
    }

    @Test("RED ProRes with a part missing") func redProRes() {
        let f = Fixture("d9")
        let clip = mp4Bytes(major: "qt  ", moov: mvhd(unix: 1_760_000_000))
        f.write("A001_1101XY.RDM/A001_C001_1101XY.RDC/A001_C001_1101XY_001.mov", clip)
        f.write("A001_1101XY.RDM/A001_C001_1101XY.RDC/A001_C001_1101XY_003.mov", clip)
        let r = f.probe()
        #expect(r.issues.contains { $0.severity == .hold })
    }
    @Test("A real R3D, whole and truncated", .enabled(if: FileManager.default.fileExists(atPath: Samples.r3d))) func realR3D() {
        let real = head(Samples.r3d, 7 << 20)
        guard real.count == 6_619_136 else { Issue.record("no sample"); return }
        let f = Fixture("d12")
        let dir = "F099_0317IH.RDM/F099_C001_0317IH.RDC/"
        f.write(dir + "F099_C001_0317IH_001.R3D", real)
        #expect(f.probe().issues.isEmpty)
        f.write(dir + "F099_C001_0317IH_001.R3D", Array(real.dropLast(1)))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }
}
