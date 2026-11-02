// Tests against public sample files. They skip cleanly when the files aren't there.
import Foundation
import Testing
@testable import IngestCore

@Suite("Formats public samples")
struct FormatsPublicSampleTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: Samples.braw)))
    func `Vendor BRAW: model, fake camera_id refused, free-text date ignored`() throws {
        let folder = (Samples.braw as NSString).deletingLastPathComponent
        let r = CardProber.probe(root: URL(fileURLWithPath: folder), files: listing(folder, depth: 0) { $0.hasSuffix(".braw") }, focus: nil)
        let i = try #require(r.cameras.first?.identity)
        #expect(i.family == .blackmagic)
        #expect(i.make == "Blackmagic Design")
        #expect(i.model == "Blackmagic URSA Mini Pro 4.6K")
        #expect(i.displayModel == "URSA Mini Pro 4.6K")
        #expect(i.serial == nil)
        #expect(i.bodyKey == nil)
        #expect(r.captureDays.map(\.day) == [CalendarDay(year: 2019, month: 6, day: 11)])
        #expect(r.captureDays.first?.source == .containerUTC)
        #expect(r.issues.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Samples.r3d)))
    func `Public R3D: PIN, uncertain model, local date, footer accepted`() throws {
        let folder = (Samples.r3d as NSString).deletingLastPathComponent
        let r = CardProber.probe(root: URL(fileURLWithPath: folder), files: listing(folder, depth: 0) { $0.hasSuffix(".R3D") }, focus: nil)
        let i = try #require(r.cameras.first?.identity)
        #expect(i.family == .red)
        #expect(i.serial == "102-57C-F9A")
        #expect(i.model == "DRAGON")
        #expect(i.modelIsCertain == false)
        #expect(r.captureDays.map(\.day) == [CalendarDay(year: 2015, month: 3, day: 17)])
        #expect(r.captureDays.first?.source == .cameraMetadata)
        #expect(r.reel == "F099")
        #expect(r.issues.isEmpty)
        let footer = try #require(ByteFile(path: Samples.r3d).flatMap(R3D.footer))
        #expect(footer == R3DFooter(kind: "REOB", declaredSize: 6_619_136))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Samples.r3d)))
    func `A real R3D cut short loses its footer and is held`() throws {
        let real = try Data(contentsOf: URL(fileURLWithPath: Samples.r3d))
        let f = Fixture("r3d-cut")
        f.write("A.RDM/A001_C001_0101XY.RDC/A001_C001_0101XY_001.R3D", Array(real.prefix(3_000_000)))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }
}
