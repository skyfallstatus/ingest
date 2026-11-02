import Foundation
import Testing
@testable import IngestCore

@Suite("Striped BRAW")
struct StripedBRAWTests {
    let cine = [("manufacturer", "Blackmagic Design"), ("camera_type", "Blackmagic URSA Cine 12K LF")]
    let older = [("manufacturer", "Blackmagic Design"), ("camera_type", "Blackmagic URSA Mini Pro 4.6K")]

    @Test func `URSA Cine with no key: one honest note, never a hold, and no claim of proof`() throws {
        let f = Fixture("braw")
        f.write("A001_08151512_C001.braw", brawBytes(cine))
        f.write("A001_08151512_C002.braw", brawBytes(cine))
        let r = f.probe()
        #expect(r.issues.count == 1)
        let note = try #require(r.issues.first)
        #expect(note.severity == .note)
        #expect(note.code == "braw.maybe-striped")
        #expect(note.message.hasPrefix("If this was recorded across two cards,"))
        #expect(note.paths.count == 2)
    }

    @Test func `URSA Mini Pro 12K gets the note, a body that can't stripe doesn't`() {
        let f = Fixture("braw")
        f.write("a.braw", brawBytes([("camera_type", "Blackmagic URSA Mini Pro 12K OLPF"), ("manufacturer", "Blackmagic Design")]))
        #expect(hasIssue(f.probe(), "braw.maybe-striped", .note))
        let g = Fixture("braw")
        g.write("a.braw", brawBytes(older))
        #expect(g.probe().issues.isEmpty)
    }

    @Test func `A count of one settles it, a count that can't be read is no proof`() {
        let f = Fixture("braw")
        f.write("a.braw", brawBytes(cine + [("multicard_volume_count", "1")]))
        #expect(f.probe().issues.isEmpty)
        let g = Fixture("braw")
        g.write("a.braw", brawBytes(older + [("multicard_volume_count", "two")]))
        let r = g.probe()
        #expect(hasIssue(r, "braw.maybe-striped", .note))
        #expect(!r.issues.contains { $0.severity == .hold })
    }

    @Test func `Both halves on one card: the hold stands for the engine, with no extra note`() {
        let f = Fixture("braw")
        f.write("a.braw", brawBytes(cine))
        f.write("a.braw2", [1, 2, 3])
        let r = f.probe()
        #expect(r.issues.map(\.code) == ["braw.striped"])
    }
}
