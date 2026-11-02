import Foundation
import Testing
@testable import IngestCore

private func moov() -> [UInt8] { mvhd(unix: 1_760_000_000) }

@Suite("What the last check can honestly say") struct ClipChecksTests {
    @Test("An MP4 with an index is the check, and it wasn't played") func mp4() {
        let f = Fixture("cc-mp4")
        f.write("PRIVATE/M4ROOT/CLIP/C0001.MP4", mp4Bytes(moov: moov()))
        f.write("PRIVATE/M4ROOT/CLIP/C0002.MP4", mp4Bytes(moov: moov()))
        let r = f.probe().clipChecks
        #expect(r.sentence == "Each MP4 has an index. Not played.")
        #expect(!r.checkedNothing)
        #expect(!r.hasGaps)
    }

    @Test("Mixed QuickTime formats are named, commonest first") func mixed() {
        let f = Fixture("cc-mix")
        f.write("CLIP/A.MP4", mp4Bytes(moov: moov()))
        f.write("CLIP/B.MP4", mp4Bytes(moov: moov()))
        f.write("CLIP/C.MOV", mp4Bytes(major: "qt  ", moov: moov()))
        #expect(f.probe().clipChecks.sentence == "Each MP4 and MOV has an index. Not played.")
    }

    @Test("RED parts say parts, not an index") func red() {
        let f = Fixture("cc-red")
        f.write("A001.RDM/A001_C001.RDC/A001_C001_0101AB_001.R3D", r3dBytes(footer: "REOF"))
        f.write("A001.RDM/A001_C001.RDC/A001_C001_0101AB_002.R3D", r3dBytes(footer: "REOC"))
        #expect(f.probe().clipChecks.sentence == "RED parts are all there. Not played.")
    }

    @Test("A format nothing looks at says so, and is not a pass") func nothing() {
        let f = Fixture("cc-mts")
        f.write("AVCHD/BDMV/STREAM/00001.MTS", [0x47, 0, 0, 0])
        let r = f.probe().clipChecks
        #expect(r.sentence == "Not checked for this format.")
        #expect(r.checkedNothing)
        #expect(r.unchecked == ["MTS"])
    }

    @Test("A photo card checked nothing") func photos() {
        let f = Fixture("cc-photo")
        f.write("DCIM/100MSDCF/DSC00001.ARW", [1, 2, 3])
        #expect(f.probe().clipChecks.sentence == "Not checked for this format.")
    }

    @Test("Files beside the checked ones aren't swept into the claim") func partial() {
        let f = Fixture("cc-part")
        f.write("CLIP/A.MP4", mp4Bytes(moov: moov()))
        f.write("CLIP/B.MTS", [0x47, 0, 0, 0])
        f.write("DCIM/100MSDCF/DSC00001.ARW", [1, 2, 3])
        f.write("AUDIO/take.wav", riffBytes(originator: "Recorder", date: "2026-10-22"))
        let r = f.probe().clipChecks
        #expect(r.sentence == "Each MP4 has an index. Not played. MTS, Photos and Audio not checked.")
        #expect(r.hasGaps)
    }

    @Test("A file that won't open is counted as unchecked, not as passed") func unopenable() {
        let f = Fixture("cc-gone")
        f.write("CLIP/A.MP4", mp4Bytes(moov: moov()))
        f.write("CLIP/B.MP4", mp4Bytes(moov: moov()))
        let files = f.files()
        try? FileManager.default.removeItem(at: f.root.appendingPathComponent("CLIP/B.MP4"))
        let r = CardProber.probe(root: f.root, files: files, focus: nil).clipChecks
        #expect(r.sentence == "1 of 2 MP4 files couldn't be checked. Not played.")
        #expect(r.hasGaps)
    }

    @Test("A broken MP4 still counts as looked at, and its issue carries the news") func broken() {
        let f = Fixture("cc-broken")
        f.write("CLIP/A.MP4", atom("ftyp", ascii("isom")) + atom("mdat", [UInt8](repeating: 0, count: 64)))
        let r = f.probe()
        #expect(hasIssue(r, "video.no-index", .hold))
        #expect(!r.clipChecks.checkedNothing)
        #expect(r.clipChecks.sentence == "1 of 1 MP4 files didn't pass the index check. Not played.")
    }

    @Test("One broken file takes the claim away from the whole format") func oneBad() {
        let f = Fixture("cc-one")
        f.write("CLIP/A.MP4", mp4Bytes(moov: moov()))
        f.write("CLIP/B.MP4", atom("ftyp", ascii("isom")) + atom("mdat", [UInt8](repeating: 0, count: 64)))
        #expect(f.probe().clipChecks.sentence == "1 of 2 MP4 files didn't pass the index check. Not played.")
    }

    @Test("A missing RED part is never all there") func redMissing() {
        let f = Fixture("cc-redgap")
        f.write("A001.RDM/A001_C001.RDC/A001_C001_0101AB_001.R3D", r3dBytes(footer: "REOF"))
        f.write("A001.RDM/A001_C001.RDC/A001_C001_0101AB_003.R3D", r3dBytes(footer: "REOC"))
        let r = f.probe()
        #expect(hasIssue(r, "red.missing-part", .hold))
        #expect(r.clipChecks.sentence == "2 of 2 R3D files didn't pass the parts check. Not played.")
    }

    @Test("A cut MXF has no finished ending") func mxfCut() {
        let f = Fixture("cc-mxf")
        f.write("XDROOT/Clip/a.MXF", Array(mxfBytes(text: xavcXML()).dropLast()))
        let r = f.probe()
        #expect(hasIssue(r, "mxf.cut-short", .hold))
        #expect(r.clipChecks.sentence == "1 of 1 MXF files didn't pass the ending check. Not played.")
    }

    @Test("Holes are never no gaps") func holes() {
        let g = Fixture("cc-hole")
        for name in ["GX010042", "GX030042"] { g.write("DCIM/100GOPRO/\(name).MP4", mp4Bytes(moov: moov())) }
        #expect(!g.probe().clipChecks.sentence.contains("GoPro chapters have no gaps"))
        let c = Fixture("cc-stream")
        for n in [1, 3] { c.write("XFVC/REEL_0089/A_0089C378H261015_190547EJ_ABCDE_00\(n).MP4", mp4Bytes(major: "mp42", moov: moov())) }
        #expect(!c.probe().clipChecks.sentence.contains("Canon streams have no gaps"))
        let a = Fixture("cc-frame")
        for i in [100, 102] { a.write("A001/A001C001_0000\(i).ari", [UInt8](repeating: 1, count: 16)) }
        #expect(!a.probe().clipChecks.sentence.contains("Frame numbers have no gaps"))
    }

    @Test("A frame sequence says gaps, not playback") func frames() {
        let f = Fixture("cc-frames")
        for i in 0..<3 { f.write("A001/A001C001_0000\(i + 100).ari", [UInt8](repeating: 1, count: 16)) }
        #expect(f.probe().clipChecks.sentence == "Frame numbers have no gaps. Not played.")
    }

    @Test("GoPro chapters are their own check on top of the index") func gopro() {
        let f = Fixture("cc-gopro")
        f.write("DCIM/100GOPRO/GX010042.MP4", mp4Bytes(moov: moov()))
        f.write("DCIM/100GOPRO/GX020042.MP4", mp4Bytes(moov: moov()))
        #expect(f.probe().clipChecks.sentence == "Each MP4 has an index. GoPro chapters have no gaps. Not played.")
    }

    // Running out of patience was reported as an index that passed.
    @Test("A walk that gave up is neither a pass nor a fault") func walkLimit() {
        let f = Fixture("cc-limit")
        f.write("CLIP/A.MP4", (0..<513).flatMap { _ in atom("free") })
        let r = f.probe()
        #expect(hasIssue(r, "video.index-unconfirmed", .hold))
        #expect(r.clipChecks.checkedNothing, "it can't read as a pass")
        #expect(!r.clipChecks.sentence.contains("has an index"))
    }

    @Test("A fragmented clip can't be told from one cut short, so it says so") func fragments() {
        let f = Fixture("cc-frag")
        f.write("CLIP/A.MP4", atom("ftyp", ascii("isom")) + atom("moof", [0, 0, 0, 0]))
        let r = f.probe()
        #expect(hasIssue(r, "video.index-unconfirmed", .hold))
        #expect(!r.clipChecks.sentence.contains("has an index"))
    }

    // Numbers can show a gap, and can't show the last part is the last.
    @Test("RED ProRes never claims every part is there") func redProRes() {
        let f = Fixture("cc-redmov")
        f.write("A001_0101XY.RDM/A001_C001_0101XY.RDC/A001_C001_0101XY_001.MOV", mp4Bytes(major: "qt  ", moov: moov()))
        let r = f.probe().clipChecks
        #expect(!r.sentence.contains("RED parts are all there"))
        #expect(r.sentence.contains("RED part numbers have no gaps, though the last part can't be confirmed."))
    }

    @Test("RED ProRes with a hole is still a hole") func redProResGap() {
        let f = Fixture("cc-redhole")
        for n in [1, 3] { f.write("A001_0101XY.RDM/A001_C001_0101XY.RDC/A001_C001_0101XY_00\(n).MOV", mp4Bytes(major: "qt  ", moov: moov())) }
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }
}
