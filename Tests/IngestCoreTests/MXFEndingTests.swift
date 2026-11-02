import Foundation
import Testing
@testable import IngestCore

@Suite("MXF endings")
struct MXFEndingTests {
    @Test func `doc-derived: a finished MXF passes`() {
        let f = Fixture("mxf")
        f.write("XDROOT/Clip/a.MXF", mxfBytes(text: xavcXML()))
        #expect(f.probe().issues.isEmpty)
    }

    @Test func `One byte short of a finished Sony clip is a hold`() {
        let f = Fixture("mxf")
        f.write("XDROOT/Clip/a.MXF", Array(mxfBytes(text: xavcXML()).dropLast()))
        #expect(hasIssue(f.probe(), "mxf.cut-short", .hold))
    }

    @Test func `A Sony header still open is a hold, even with a RIP`() {
        let f = Fixture("mxf")
        f.write("XDROOT/Clip/a.MXF", mxfBytes(status: 1, text: xavcXML()))
        #expect(hasIssue(f.probe(), "mxf.cut-short", .hold))
    }

    @Test func `A damaged head with a Sony sidecar still counts as Sony`() {
        let f = Fixture("mxf")
        f.write("XDROOT/Clip/a.MXF", [UInt8](repeating: 0, count: 8192))
        f.write("XDROOT/Clip/aM01.XML", text: xavcXML())
        #expect(hasIssue(f.probe(), "mxf.cut-short", .hold))
    }

    @Test func `doc-derived: X-OCN has no proof yet, so a note`() {
        let f = Fixture("mxf")
        f.write("CINEROOT/Clip/a.MXF", mxfBytes(rip: false, text: xavcXML(codec: "RAW_X-OCN_ST")))
        let r = f.probe()
        #expect(hasIssue(r, "mxf.unconfirmed-ending", .note))
        #expect(!r.issues.contains { $0.severity != .note })
    }

    @Test func `doc-derived: MXF with no maker in its header and no RIP are a single note, never a hold`() {
        let f = Fixture("mxf")
        f.write("A_0001_12RJ/A_0001C001_240504_104800_a12RJ.mxf", mxfBytes(rip: false))
        f.write("A_0001_12RJ/A_0001C002_240504_104800_a12RJ.mxf", mxfBytes(rip: false))
        let r = f.probe()
        #expect(r.issues.filter { $0.code == "mxf.unconfirmed-ending" }.first?.paths.count == 2)
        #expect(!r.issues.contains { $0.severity != .note })
    }

    @Test func `doc-derived: an open header with a good RIP is legal outside Sony`() {
        let f = Fixture("mxf")
        f.write("A_0001_12RJ/A_0001C001_240504_104800_a12RJ.mxf", mxfBytes(status: 1))
        #expect(f.probe().issues.isEmpty)
    }
}
