// Who shot a clip, read from synthetic bytes, so no test here needs a real file.
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import IngestCore

private func protobuf(_ fields: [(Int, String)]) -> [UInt8] {
    fields.flatMap { [UInt8($0.0 << 3 | 2), UInt8($0.1.utf8.count)] + ascii($0.1) }
}

/// One timed-metadata track whose only sample holds `sample`.
private func clip(trackFormat: String, sample: [UInt8], major: String = "XAVC", udta: [UInt8] = []) -> [UInt8] {
    let ftyp = atom("ftyp", ascii(major) + be32(0))
    let stsd = atom("stsd", [0, 0, 0, 0] + be32(1) + be32(16) + ascii(trackFormat) + [UInt8](repeating: 0, count: 8))
    let stco = atom("stco", [0, 0, 0, 0] + be32(1) + be32(ftyp.count + 8))
    let stsz = atom("stsz", [0, 0, 0, 0] + be32(sample.count) + be32(1))
    let trak = atom("trak", atom("mdia", atom("hdlr", [UInt8](repeating: 0, count: 24)) + atom("minf", atom("stbl", stsd + stco + stsz))))
    return ftyp + atom("mdat", sample) + atom("moov", mvhd(unix: 1_760_000_000) + trak + udta)
}

private func jpeg(make: String, model: String, date: String) -> [UInt8] {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
    let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: make, kCGImagePropertyTIFFModel: model],
                                  kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date]]
    CGImageDestinationAddImage(dest, context.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return [UInt8](out as Data)
}

@Suite("Identification without a real file")
struct SyntheticIdentity {
    @Test func `The serial comes from the first rtmd sample, through the track tables`() throws {
        let sample = [UInt8](repeating: 0, count: 40) + [0x81, 0x14] + be16(63) + ascii("ILME-FX2 1234567") + [UInt8](repeating: 0, count: 47)
        let f = Fixture("rtmd")
        let path = f.write("clip.mp4", clip(trackFormat: "rtmd", sample: sample))
        let file = try #require(ByteFile(path: path))
        let qt = try #require(QuickTime.inspect(file))
        #expect(Sony.rtmdSerial(file, qt, model: "ILME-FX2") == "1234567")
    }

    @Test func `DJI: model from the ilst item, serial from the first djmd sample`() {
        let serial = "1WTZM6C0000TEST"
        let sample = protobuf([(1, String(decoding: protobuf([(1, String(decoding: protobuf([(5, serial)]), as: UTF8.self))]), as: UTF8.self))])
        let item = atom("©too", atom("data", be32(1) + be32(0) + ascii("DJI OsmoPocket3")))
        let udta = atom("udta", atom("meta", atom("ilst", item)))
        let f = Fixture("dji")
        f.write("DCIM/DJI_001/DJI_20261022115458_0143_D.MP4", clip(trackFormat: "djmd", sample: sample, major: "isom", udta: udta))
        let r = f.probe()
        #expect(r.cameras.first?.identity.displayModel == "Osmo Pocket 3")
        #expect(r.cameras.first?.identity.serial == serial)
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 10, day: 22))
    }

    @Test func `Insta360 keeps serial and model in the trailer`() {
        let record = protobuf([(1, "IAQEB0000TEST"), (2, "Insta360 X3")])
        let magic = ascii("8db42d694ccc418790edff439fe026bf")
        let trailer = record + [0x01, 0x01] + le32(record.count) + [UInt8](repeating: 0, count: 40) + magic
        let f = Fixture("insta")
        f.write("VID_20260531_010338_00_001.insv", mp4Bytes(moov: mvhd(unix: 1_760_000_000)) + trailer)
        f.write("VID_20260531_010338_10_001.insv", mp4Bytes(moov: mvhd(unix: 1_760_000_000)) + trailer)
        let r = f.probe()
        #expect(r.cameras.first?.identity.family == .insta360)
        #expect(r.cameras.first?.identity.serial == "IAQEB0000TEST")
        #expect(r.cameras.first?.clipCount == 1)
    }

    @Test func `EXIF gives make, model and day`() {
        let f = Fixture("exif")
        f.write("DCIM/100MSDCF/DSC00001.JPG", jpeg(make: "SONY", model: "ILCE-7M4", date: "2026:10:22 01:48:15"))
        let r = f.probe()
        #expect(r.cameras.first?.identity.family == .sony)
        #expect(r.cameras.first?.identity.make == "Sony")
        #expect(r.cameras.first?.identity.displayModel == "A7 IV")
        #expect(r.captureDays.first?.source == .cameraMetadata)
    }

    @Test func `P2 XML names the body when the MXF names nobody`() {
        let f = Fixture("p2")
        f.write("LASTCLIP.TXT", text: "0001AB")
        f.write("CONTENTS/VIDEO/0001AB.MXF", mxfPartitionPrefix + [0x02, 0x04, 0x00, 0x10] + [UInt8](repeating: 0, count: 64))
        f.write("CONTENTS/CLIP/0001AB.XML", text: "<P2Main><ModelName>AJ-PX270</ModelName></P2Main>")
        #expect(f.probe().cameras.first?.identity.displayModel == "PX270")
    }

    @Test func `Panasonic and Fujifilm say who they are in udta text`() {
        let f = Fixture("udta")
        f.write("P1000001.MOV", mp4Bytes(moov: mvhd(unix: 1_760_000_000) + atom("udta", atom("PANA", [0, 1] + ascii("DC-GH7") + [0]))))
        #expect(f.probe().cameras.first?.identity.displayModel == "GH7")
        let g = Fixture("udta")
        g.write("DSCF0001.MOV", mp4Bytes(moov: mvhd(unix: 1_760_000_000) + atom("udta", atom("FFMV", [0, 1] + ascii("X-H2S") + [0]))))
        #expect(g.probe().cameras.first?.identity.displayModel == "X-H2S")
    }

    @Test func `A card with an index and no clips still names its body`() {
        let f = Fixture("sony")
        f.write("M4ROOT/MEDIAPRO.XML", text: sonyProfileXML)
        let r = f.probe()
        #expect(r.cameras.first?.clipCount == 0)
        #expect(r.cameras.first?.identity.bodyKey == "0000AAFFFE000002")
        #expect(r.captureDays.isEmpty)
    }

    @Test func `Focus decides the dates, not the whole card`() {
        let f = Fixture("focus")
        for (name, date) in [("C0001", "2026-01-20T10:00:00+01:00"), ("C0002", "2026-01-21T10:00:00+01:00")] {
            f.write("M4ROOT/CLIP/\(name).MP4", mp4Bytes(major: "XAVC", moov: mvhd(unix: 1_700_000_000)))
            f.write("M4ROOT/CLIP/\(name)M01.XML", text: sonyClipXML(date: date))
        }
        #expect(f.probe(focus: ["M4ROOT/CLIP/C0002.MP4"]).captureDays.map(\.day) == [CalendarDay(year: 2026, month: 1, day: 21)])
        #expect(f.probe(focus: []).captureDays.isEmpty)
        #expect(f.probe(focus: []).cameras.first?.clipCount == 2)
    }

    @Test("VENICE 2 6K") func venice6K() {
        #expect(CameraNames.sony("MPC-3626") == "VENICE 2")
        #expect(Sony.cineModel(inHead: Array("xxMPC-3626xx".utf8)) != nil)
    }
    @Test("Osmo 360 OSV") func osv() {
        let path = "DCIM/CAM_001/CAM_20251116120149_0002_D.OSV"
        #expect(CardProber.kind(ofRelativePath: path) == .video)
        #expect(VolumeProbe.family(ofDCIMFolder: "CAM_001") == .dji)
    }
    @Test func `doc-derived: an OSV-only card is video, and its name gives the day`() {
        let f = Fixture("osv")
        f.write("DCIM/CAM_001/CAM_20251116120149_0002_D.OSV", [0, 1, 2, 3])
        f.write("DCIM/CAM_001/CAM_20251116120149_0002_D.LRF", [0])
        let r = f.probe()
        #expect(r.hasVideo)
        #expect(r.cameras.first?.identity.family == .dji)
        #expect(r.cameras.first?.identity.modelIsCertain == false)
        #expect(r.captureDays.first?.day == CalendarDay(year: 2025, month: 11, day: 16))
        #expect(r.issues.isEmpty)
    }
}
