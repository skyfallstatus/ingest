// Fixtures built in code. A test named "doc-derived" comes from the research docs alone: it proves the code
// agrees with the docs, not that the docs agree with cameras. The others test logic with no format claim,
// or follow a layout seen in a real file.
import Foundation
import Testing
@testable import IngestCore

@Suite("Formats RED completeness")
struct FormatsRED {
    let rdc = "A020_0213N4.RDM/A020_C001_0213N4.RDC/"
    let tags = [(0x10A0, "KOMODO 6K"), (0x1071, "my-komodo"), (0x1006, "120-ABC-DEF")]

    @Test func `doc-derived: three contiguous parts ending in REOC are whole`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: "REOF", tags: tags))
        f.write(rdc + "A020_C001_0213N4_002.R3D", r3dBytes(footer: "REOF"))
        f.write(rdc + "A020_C001_0213N4_003.R3D", r3dBytes(footer: "REOC"))
        f.write(rdc + "A020_C001_0213N4.mov", [0])
        let r = f.probe()
        #expect(r.issues.isEmpty)
        #expect(r.reel == "A020")
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.cameras.first?.identity.displayModel == "KOMODO 6K")
        #expect(r.cameras.first?.identity.modelIsCertain == true)
        #expect(r.cameras.first?.identity.serial == "120-ABC-DEF")
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 1, day: 20))
    }

    @Test func `doc-derived: a missing middle part is held, naming the clip`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: "REOF"))
        f.write(rdc + "A020_C001_0213N4_003.R3D", r3dBytes(footer: "REOC"))
        let r = f.probe()
        #expect(hasIssue(r, "red.missing-part", .hold))
        #expect(r.issues.first?.message.contains("A020_C001_0213N4") == true)
        #expect(r.issues.first?.message.contains("002") == true)
    }

    @Test func `doc-derived: REOF on the last part means later parts are gone`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: "REOF"))
        f.write(rdc + "A020_C001_0213N4_002.R3D", r3dBytes(footer: "REOF"))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }

    @Test func `doc-derived: first part missing is held`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_002.R3D", r3dBytes(footer: "REOC"))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }

    @Test func `doc-derived: no footer at all is held`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: nil))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }

    @Test func `doc-derived: a footer size that disagrees with the file is held`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: "REOB", declaredSize: 999_999))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }

    @Test func `doc-derived: a footer type nobody knows is held, never passed`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: "XXXX"))
        #expect(hasIssue(f.probe(), "red.missing-part", .hold))
    }

    @Test func `doc-derived: Phantom Track puts two stems in one RDC, judged apart`() {
        let f = Fixture("red")
        f.write(rdc + "A020_C001_0213N4_001.R3D", r3dBytes(footer: "REOB"))
        f.write(rdc + "X020_C001_0213N4_001.R3D", r3dBytes(footer: "REOF"))
        f.write(rdc + "X020_C001_0213N4_002.R3D", r3dBytes(footer: "REOC"))
        let r = f.probe()
        #expect(r.issues.isEmpty)
        #expect(r.cameras.first?.clipCount == 2)
    }

    @Test func `doc-derived: model falls back to 0x1071 and says it is unsure`() {
        let f = Fixture("red")
        f.write("A.RDM/A001_C001_0101XY.RDC/A001_C001_0101XY_001.R3D", r3dBytes(footer: "REOB", tags: [(0x1071, "RAPTOR"), (0x1006, "120-ABC-DEF")]))
        let i = f.probe().cameras.first?.identity
        #expect(i?.displayModel == "RAPTOR")
        #expect(i?.modelIsCertain == false)
    }

    @Test func `doc-derived: an .R3D in DCIM with atoms and no RED bytes is Nikon, with no RED checks`() {
        let f = Fixture("nikon")
        f.write("DCIM/100NIKON/DSC_0001.R3D", mp4Bytes(moov: mvhd(unix: 1_760_000_000)))
        let r = f.probe()
        #expect(r.cameras.first?.identity.family == .nikon)
        #expect(r.issues.isEmpty)
    }

    @Test func `doc-derived: a zero-filled .R3D in DCIM is damage, so the index check holds it`() {
        let f = Fixture("nikon")
        f.write("DCIM/100NIKON/DSC_0001.R3D", [UInt8](repeating: 0, count: 8192))
        let r = f.probe()
        #expect(hasIssue(r, "video.no-index", .hold))
        #expect(!r.issues.contains { $0.code.hasPrefix("red.") })
    }

    @Test func `doc-derived: a .NEV with Nikon tags is Nikon`() {
        var nctg: [UInt8] = []
        let model = ascii("NIKON Z 8\0"), serial = ascii("3001234\0"), date = ascii("2026:01:20 10:00:00\0")
        nctg += be32(0x02) + be16(2) + be16(model.count) + model
        nctg += be32(0x110A431) + be16(2) + be16(serial.count) + serial
        nctg += be32(0x12) + be16(2) + be16(date.count) + date
        let udta = atom("udta", atom("NCDT", atom("NCHD", [0, 0, 0, 0]) + atom("NCTG", nctg)))
        let f = Fixture("nev")
        f.write("DCIM/100NC_Z8/DSC_0001.NEV", mp4Bytes(major: "qt  ", moov: mvhd(unix: 1_700_000_000) + udta))
        f.write("DCIM/100NC_Z8/DSC_0001.MP4", [1, 2, 3])
        let r = f.probe()
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.cameras.first?.identity.family == .nikon)
        #expect(r.cameras.first?.identity.displayModel == "Z8")
        #expect(r.cameras.first?.identity.serial == "3001234")
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 1, day: 20))
    }
}

@Suite("Formats BRAW")
struct FormatsBRAW {
    let real = [("manufacturer", "Blackmagic Design"), ("camera_type", "Blackmagic URSA Cine 12K LF"), ("camera_id", "9f7a7c5e-1111-4222-8333-444455556666"),
                ("date_recorded", "2026:01:20"), ("reel_name", "A001")]

    @Test func `doc-derived: camera_id is a body key, never a serial`() {
        let f = Fixture("braw")
        f.write("A001_08151512_C001.braw", brawBytes(real))
        let i = f.probe().cameras.first?.identity
        #expect(i?.serial == nil)
        #expect(i?.bodyKey == "9f7a7c5e-1111-4222-8333-444455556666")
        #expect(i?.displayModel == "URSA Cine 12K LF")
    }

    @Test func `doc-derived: a .braw2 on the card is held and names both cards`() {
        let f = Fixture("braw")
        f.write("A001_08151512_C001.braw2", [1, 2, 3])
        let r = f.probe()
        #expect(hasIssue(r, "braw.striped", .hold))
        #expect(r.issues.first?.message.contains("both cards") == true)
        #expect(r.issues.first?.paths == ["A001_08151512_C001.braw2"])
    }

    @Test func `doc-derived: a multicard key says the partner exists from the .braw alone`() {
        let f = Fixture("braw")
        f.write("A001_08151512_C001.braw", brawBytes(real + [("multicard_volume_count", "2")]))
        f.write("A001_08151512_C002.braw", brawBytes(real + [("multicard_volume_count", "1")]))
        let r = f.probe()
        #expect(r.issues.map(\.paths) == [["A001_08151512_C001.braw"]])
        #expect(hasIssue(r, "braw.striped", .hold))
    }

    @Test func `Striped partner names keep their case`() {
        #expect(CardProber.stripedPartnerName(of: "A/B/A001_08151512_C001.BRAW2") == "A001_08151512_C001.BRAW")
        #expect(CardProber.stripedPartnerName(of: "A/B/A001_08151512_C001.braw") == "A001_08151512_C001.braw2")
        #expect(CardProber.stripedPartnerName(of: "C0001.MP4") == nil)
    }

    @Test func `doc-derived: filename day wins over a UTC day one off, keeping the year from mvhd`() {
        let f = Fixture("braw")
        // 2026-08-14 23:30 UTC, shot on the 15th local, and date_recorded is free text.
        f.write("A001_08150130_C001.braw", brawBytes([("manufacturer", "Blackmagic Design"), ("date_recorded", "Monday")], unix: 1_786_750_200))
        let r = f.probe()
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 8, day: 15))
        #expect(r.captureDays.first?.source == .fileName)
    }

    @Test func `A year-less filename date is not enough by itself`() {
        let f = Fixture("braw")
        f.write("A001_08151512_C001.braw", [UInt8](repeating: 0, count: 64))
        let days = CardProber.probe(root: f.root, files: f.files().map { var c = $0; c.mtime = 0; return c }, focus: nil).captureDays
        #expect(days.isEmpty)
    }
}

@Suite("Formats index check")
struct FormatsIndex {
    func state(_ bytes: [UInt8]) -> QuickTime.IndexState {
        let f = Fixture("idx")
        let path = f.write("x.mp4", bytes)
        return ByteFile(path: path).map(QuickTime.indexState) ?? .missing
    }

    @Test func `moov at the end is fine, moov at the front is fine`() {
        #expect(state(mp4Bytes(moov: mvhd(unix: 1))) == .present)
        #expect(state(atom("ftyp", ascii("isom") + be32(0)) + atom("moov", mvhd(unix: 1)) + atom("mdat", [1, 2, 3])) == .present)
    }

    @Test func `doc-derived: fragmented MP4 with moof and no moov is not called broken, or whole`() {
        #expect(state(atom("styp", ascii("msdh") + be32(0)) + atom("moof", [0, 0, 0, 0]) + atom("mdat", [1])) == .unconfirmed)
        #expect(state(atom("ftyp", ascii("iso5") + be32(0)) + atom("sidx", [0, 0]) + atom("mdat", [1])) == .unconfirmed)
    }

    @Test func `doc-derived: no moov and the file just ends: missing`() {
        #expect(state(atom("ftyp", ascii("XAVC") + be32(0)) + atom("free", [0, 0]) + atom("mdat", [1, 2, 3])) == .missing)
    }

    @Test func `doc-derived: mdat promising more than the file holds: missing`() {
        var b = atom("ftyp", ascii("XAVC") + be32(0))
        b += be32(1_000_000) + ascii("mdat") + [1, 2, 3]
        #expect(state(b) == .missing)
    }

    @Test func `doc-derived: mdat of size 0, running to the end: missing`() {
        #expect(state(atom("ftyp", ascii("mp42") + be32(0)) + be32(0) + ascii("mdat") + [1, 2, 3, 4]) == .missing)
    }

    @Test func `doc-derived: moov cut short: missing`() {
        var b = atom("ftyp", ascii("mp42") + be32(0)) + atom("mdat", [1, 2])
        b += be32(100_000) + ascii("moov") + [1, 2, 3]
        #expect(state(b) == .missing)
    }

    @Test func `Empty and all-zero files: missing`() {
        #expect(state([]) == .missing)
        #expect(state([UInt8](repeating: 0, count: 4096)) == .missing)
    }

    @Test func `doc-derived: a chain that breaks but has moov further on is not called broken`() {
        let moov = atom("moov", mvhd(unix: 1))
        #expect(state(atom("ftyp", ascii("mp42") + be32(0)) + [0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x02, 0x03, 0x04] + moov) == .present)
    }

    @Test func `An MPEG TS or MXF behind a video extension is someone else's business`() {
        #expect(state([0x47] + [UInt8](repeating: 0, count: 187)) == .otherContainer)
        #expect(state([0x06, 0x0E, 0x2B, 0x34] + [UInt8](repeating: 0, count: 60)) == .otherContainer)
    }

    @Test func `doc-derived: a truncated clip on a card gets a hold, and the good one beside it doesn't`() {
        let f = Fixture("idx")
        f.write("M4ROOT/CLIP/C0001.MP4", mp4Bytes(major: "XAVC", moov: mvhd(unix: 1_700_000_000)))
        f.write("M4ROOT/CLIP/C0002.MP4", atom("ftyp", ascii("XAVC") + be32(0)) + be32(1_000_000) + ascii("mdat") + [1, 2, 3])
        let r = f.probe()
        #expect(r.issues.count == 1)
        #expect(hasIssue(r, "video.no-index", .hold))
        #expect(r.issues.first?.paths == ["M4ROOT/CLIP/C0002.MP4"])
    }
}

@Suite("Formats other completeness rules")
struct FormatsCompleteness {
    @Test func `doc-derived: ARRI frames are contiguous from min to max, not from 1`() {
        let f = Fixture("ari")
        let clip = "A001R0Z3/A001C001_140711_R0Z3/"
        for n in 27301 ... 27305 { f.write(clip + "A001C001_140711_R0Z3.00\(n).ari", [0x41]) }
        let r = f.probe()
        #expect(r.issues.isEmpty)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.cameras.first?.identity.family == .arri)
        #expect(r.cameras.first?.identity.serial == "1263")
        #expect(r.cameras.first?.identity.displayModel == "ALEXA")
        #expect(r.cameras.first?.identity.modelIsCertain == false)
        #expect(r.reel == "A001R0Z3")
    }

    @Test func `doc-derived: one missing frame is a hold`() {
        let f = Fixture("ari")
        let clip = "A001R0Z3/A001C001_140711_R0Z3/"
        for n in [27301, 27302, 27304] { f.write(clip + "A001C001_140711_R0Z3.00\(n).arx", [0x41]) }
        let r = f.probe()
        #expect(hasIssue(r, "arri.frame-gap", .hold))
        #expect(r.issues.first?.message.contains("27303") == true)
    }

    @Test func `doc-derived: GoPro chapters are checked per video, not in folder order`() {
        let f = Fixture("gopro")
        for name in ["GX011234", "GX021234", "GX011235", "GX021235", "GX031235", "GH019999"] {
            f.write("DCIM/100GOPRO/\(name).MP4", [0])
            f.write("DCIM/100GOPRO/\(name).THM", [0])
        }
        let r = f.probe()
        #expect(r.issues.filter { $0.code == "gopro.chapter-gap" }.isEmpty)
        #expect(r.cameras.first?.clipCount == 3)
    }

    @Test func `doc-derived: more than one ARRI reel on a medium is a note`() {
        let f = Fixture("arri")
        f.write("A_0001_12NR/A_0001C001_240504_104800_a12NR.mxf", [0])
        f.write("B_0002_12NR/B_0002C001_240505_104800_a12NR.mxf", [0])
        let r = f.probe()
        #expect(hasIssue(r, "arri.multiple-reels", .note))
    }

    @Test func `doc-derived: a Codex HDE volume is a blocker`() throws {
        let f = Fixture("codex")
        let root = f.root.appendingPathComponent("A001R0Z3_hde")
        f.write("logs/vfs.log", text: "fine\n")
        let json = #"{"volume_label":"A001R0Z3_hde","vfs_type":"hde","media_id":"1","log_file":"\#(f.root.path)/logs/vfs.log"}"#
        f.write("A001R0Z3_hde/.codexvfs", text: json)
        #expect(CardProber.isCodexVirtual(root: root))
        let r = CardProber.probe(root: root, files: [], focus: nil)
        #expect(hasIssue(r, "codex.hde", .blocker))
        #expect(r.issues.first?.message.contains("original volume") == true)
    }

    @Test func `doc-derived: a CRC error in the Codex log for this volume is a blocker`() {
        let f = Fixture("codex")
        let root = f.root.appendingPathComponent("A001R0Z3")
        f.write("logs/vfs.log", text: "12:00 ok\n12:01 CRC ERROR: A001R0Z3/A001C001_140711_R0Z3/A001C001_140711_R0Z3.0027301.ari\n")
        f.write("A001R0Z3/.codexvfs", text: #"{"volume_label":"A001R0Z3","vfs_type":"arri","media_id":"1","log_file":"\#(f.root.path)/logs/vfs.log"}"#)
        let r = CardProber.probe(root: root, files: [], focus: nil)
        #expect(hasIssue(r, "codex.crc", .blocker))
        #expect(r.issues.first?.paths.count == 1)
    }

    @Test func `doc-derived: a CRC error on another volume doesn't count, a clean log neither`() {
        let f = Fixture("codex")
        let root = f.root.appendingPathComponent("A001R0Z3")
        f.write("logs/vfs.log", text: "12:01 CRC ERROR: B002R0Z3/B002C001_140711_R0Z3/B002C001_140711_R0Z3.0027301.ari\n")
        f.write("A001R0Z3/.codexvfs", text: #"{"volume_label":"A001R0Z3","log_file":"\#(f.root.path)/logs/vfs.log"}"#)
        #expect(CardProber.probe(root: root, files: [], focus: nil).issues.isEmpty)
    }

    @Test func `doc-derived: a Codex log that can't be read is a hold, not silence`() {
        let f = Fixture("codex")
        f.write(".codexvfs", text: #"{"volume_label":"X","log_file":"/tmp/ingest-formats-fixtures/nope.log"}"#)
        #expect(hasIssue(f.probe(), "codex.crc-unknown", .hold))
    }

    @Test func `A plain folder is not Codex`() {
        #expect(CardProber.isCodexVirtual(root: Fixture("plain").root) == false)
    }

    @Test func `An unknown layout is not an issue`() {
        let f = Fixture("odd")
        f.write("WEIRD/THING/clip.xyz", [1, 2, 3])
        f.write("WEIRD/notes.txt", text: "hello")
        #expect(f.probe().issues.isEmpty)
    }
}

@Suite("Formats identification from structure and bytes")
struct FormatsIdentify {
    @Test func `doc-derived: MEDIAPRO at /PRIVATE/M4ROOT, placeholder serial absent, version suffix stripped`() {
        let f = Fixture("sony")
        f.write("PRIVATE/M4ROOT/MEDIAPRO.XML", text: sonyProfileXML)
        f.write("PRIVATE/M4ROOT/CLIP/C0001.MP4", atom("ftyp", ascii("XAVC") + be32(0)) + be32(1_000_000) + ascii("mdat") + [1])
        let r = f.probe()
        let i = r.cameras.first?.identity
        #expect(i?.model == "ILME-FX6V")
        #expect(i?.displayModel == "FX6")
        #expect(i?.serial == nil)
        #expect(i?.bodyKey == "0000AAFFFE000002")
    }

    @Test func `doc-derived: a renamed root is found by its namespace, not its name`() {
        let f = Fixture("sony")
        f.write("A123/MEDIAPRO.XML", text: sonyProfileXML)
        f.write("A123/CLIP/A123C001_260120AB.MP4", mp4Bytes(major: "XAVC", moov: mvhd(unix: 1_700_000_000)))
        f.write("A123/CLIP/A123C001_260120ABM01.XML", text: sonyClipXML(model: "ILME-FX6V", serial: "7654321"))
        let r = f.probe()
        #expect(r.cameras.first?.identity.serial == "7654321")
        #expect(r.reel == "A123")
        #expect(CardProber.look(atRoot: f.root) == .cameraCard(.sony))
    }

    @Test func `A folder called M4ROOT with a stranger's XML is not evidence of a body`() {
        let f = Fixture("sony")
        f.write("WORK/M4ROOT/MEDIAPRO.XML", text: "<Something/>")
        let ctx = CardContext(root: f.root, files: f.files())
        #expect(ClipReader(ctx).sonyMedia.isEmpty)
    }

    @Test func `doc-derived: an embedded MXF XML is found in the header, and the date is the written text`() {
        var mxf: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00, 0x10]
        mxf += [UInt8](repeating: 0, count: 2000)
        mxf += ascii(sonyClipXML(model: "ILME-FX6V", serial: "7654321"))
        let f = Fixture("mxf")
        f.write("XDROOT/Clip/B001C001_261022FV.MXF", mxf)
        let r = f.probe()
        #expect(r.cameras.first?.identity.serial == "7654321")
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 10, day: 22))
        #expect(r.reel == "B001")
    }

    @Test func `doc-derived: rtmd scan takes the value only if it starts with the model`() {
        var b = [UInt8](repeating: 0, count: 300)
        b += [0x81, 0x14] + be16(63) + ascii("ILME-FX2 1234567") + [UInt8](repeating: 0, count: 47)
        #expect(Sony.scanSerial(b, model: "ILME-FX2") == "1234567")
        #expect(Sony.scanSerial(b, model: "ILME-FX3") == nil)
    }

    @Test func `A name proves no brand: A001C001 with nothing in its bytes stays unknown`() {
        let f = Fixture("name")
        f.write("A001C001_260120XX.MP4", mp4Bytes(moov: mvhd(unix: 1_700_000_000)))
        f.write("A002C001_260120_R0Z3.MOV", mp4Bytes(moov: mvhd(unix: 1_700_000_000)))
        let r = f.probe()
        #expect(r.cameras.allSatisfy { $0.identity.family == .unknown })
    }

    @Test func `doc-derived: ARRI by filename alone is weak, with the serial from Base36`() {
        let f = Fixture("arri")
        f.write("A_0001_12RJ/A_0001C001_240504_104800_a12RJ.mxf", [0])
        let r = f.probe()
        let i = r.cameras.first?.identity
        #expect(i?.family == .arri)
        #expect(i?.serial == "50239")
        #expect(i?.displayModel == "ALEXA")
        #expect(i?.modelIsCertain == false)
        #expect(r.reel == "A_0001_12RJ")
        #expect(r.captureDays.first?.day == CalendarDay(year: 2024, month: 5, day: 4))
    }

    @Test func `doc-derived: Mini LF drops the user prefix before decoding, and the ALE gives the model`() {
        let f = Fixture("arri")
        f.write("A004RN9O/A004C010_210421_RN9O.mxf", [0])
        f.write("A004RN9O/A004RN9O.ale", text: "Heading\nFIELD_DELIM\tTABS\n\nColumn\nName\tCamera_Model\tCamera_SN\n\nData\nA004C010\tALEXA Mini LF\t30156\n")
        let i = f.probe().cameras.first?.identity
        #expect(i?.serial == "30156")
        #expect(i?.displayModel == "ALEXA Mini LF")
        #expect(i?.modelIsCertain == true)
    }

    @Test func `doc-derived: ARRI QuickTime keys name the model`() {
        let f = Fixture("arri")
        f.write("A001R0Z3/A001C001_140711_R0Z3.mov", mp4Bytes(major: "qt  ", moov: mvhd(unix: 1_400_000_000) + keysMeta([
            ("com.arri.camera.CameraModel", "ALEXA Mini"), ("com.arri.camera.CameraSerialNumber", "22222"),
        ])))
        let i = f.probe().cameras.first?.identity
        #expect(i?.family == .arri)
        #expect(i?.displayModel == "ALEXA Mini")
        #expect(i?.serial == "22222")
    }

    @Test func `doc-derived: ALEXA 35 JSON in UTF-16 inside an MXF header`() {
        func utf16(_ s: String) -> [UInt8] { s.utf8.flatMap { [0, $0] } }
        var mxf: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x02, 0x04, 0x00, 0x10]
        mxf += [UInt8](repeating: 0, count: 500)
        mxf += utf16(#"{"cameraModel":"ALEXA 35","cameraSerialNumber":"50239"}"#)
        mxf += [UInt8](repeating: 0, count: 500)
        let f = Fixture("arri")
        f.write("A_0001_12RJ/A_0001C001_240504_104800_a12RJ.mxf", mxf)
        let i = f.probe().cameras.first?.identity
        #expect(i?.displayModel == "ALEXA 35")
        #expect(i?.serial == "50239")
        #expect(i?.modelIsCertain == true)
    }

    @Test func `doc-derived: CAEP with no Canon strings is still Canon, with no serial`() {
        let f = Fixture("canon")
        f.write("DCIM/100EOSR5/IMG_0001.MP4", mp4Bytes(major: "mp42", compatible: ["mp42", "CAEP"], moov: mvhd(unix: 1_700_000_000)))
        let i = f.probe().cameras.first?.identity
        #expect(i?.family == .canon)
        #expect(i?.serial == nil)
        #expect(i?.modelIsCertain == false)
    }

    @Test func `doc-derived: a CRM with CMT1 and CMT2 TIFF blobs`() {
        func tiff(_ tag: Int, _ s: String) -> [UInt8] {
            let v = ascii(s + "\0")
            return ascii("II") + [42, 0] + le32(8) + [1, 0] + [UInt8(tag & 255), UInt8(tag >> 8)] + [2, 0] + le32(v.count) + le32(26) + le32(0) + v
        }
        let uuid: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]
        let moov = mvhd(unix: 1_700_000_000) + atom("uuid", uuid + atom("CMT1", tiff(0x0110, "Canon EOS R5")) + atom("CMT2", tiff(0x9003, "2026:01:20 10:00:00")))
        let f = Fixture("canon")
        f.write("CRM/REEL_0001/A001C001_260120AB_CANON.CRM", mp4Bytes(major: "crx ", compatible: ["crx "], moov: moov))
        let r = f.probe()
        #expect(r.cameras.first?.identity.displayModel == "R5")
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 1, day: 20))
        #expect(r.captureDays.first?.source == .cameraMetadata)
    }

    @Test func `doc-derived: canon proxies and Sony proxies are not clips`() {
        let f = Fixture("proxy")
        f.write("XFVC/REEL_0001/A001C001_260120AB_CANON.MP4", mp4Bytes(major: "mp42", compatible: ["CAEP"], moov: mvhd(unix: 1_700_000_000)))
        f.write("XFVC/REEL_0001/A001C001_260120AB_CANON_P.MP4", [0])
        f.write("XFVC/REEL_0001/A001C001_260120AB_CANON_Proxy.MP4", [0])
        f.write("M4ROOT/SUB/C0001S03.MP4", [0])
        f.write("Proxy/A001_08151512_C001.mp4", [0])
        let r = f.probe()
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.reel == "A001")
    }

    @Test func `doc-derived: GPMF in udta gives the model and serial`() {
        let minf = ascii("MINF") + [UInt8(ascii: "c"), 1] + be16(12) + ascii("HERO12 Black")
        let casn = ascii("CASN") + [UInt8(ascii: "c"), 1] + be16(14) + ascii("C3501323456789") + [0, 0]
        let gpmf = ascii("DEVC") + [0, 4] + be16(32) + minf + casn
        let f = Fixture("gopro")
        f.write("DCIM/100GOPRO/GX011234.MP4", mp4Bytes(moov: mvhd(unix: 1_700_000_000) + atom("udta", atom("GPMF", gpmf))))
        let i = f.probe().cameras.first?.identity
        #expect(i?.family == .gopro)
        #expect(i?.displayModel == "HERO12 Black")
        #expect(i?.serial == "C3501323456789")
    }

    @Test func `doc-derived: a bext naming a recorder is a recorder, and Premiere isn't`() {
        let f = Fixture("audio")
        f.write("Scene001_001.WAV", riffBytes(originator: "ZOOM F6", date: "2026-01-20"))
        let r = f.probe()
        #expect(r.cameras.first?.identity.family == .audioRecorder)
        #expect(r.cameras.first?.identity.displayModel == "F6")
        #expect(r.captureDays.first?.day == CalendarDay(year: 2026, month: 1, day: 20))
        #expect(r.hasAudio && !r.hasVideo)

        let g = Fixture("audio")
        g.write("mix.wav", riffBytes(originator: "Adobe Premiere Pro 2026.0 (Macin", date: "2026-01-20"))
        #expect(g.probe().cameras.first?.identity.family == .unknown)
    }

    @Test func `doc-derived: RF64 is read too`() {
        let f = Fixture("audio")
        f.write("260120_001.WAV", riffBytes(originator: "Sound Devices 888", date: "2026:01:20", form: "RF64"))
        #expect(f.probe().cameras.first?.identity.displayModel == "888")
    }

    @Test func `doc-derived: older Canon XF clip folders count one clip per folder`() {
        let f = Fixture("xf")
        f.write("CONTENTS/CLIPS001/AA0001/AA000101.MXF", [0])
        f.write("CONTENTS/CLIPS001/AA0001/AA000102.MXF", [0])
        f.write("CONTENTS/CLIPS001/AA0001/AA000101.CIF", [0])
        f.write("CONTENTS/CLIPS001/AA0002/AA000201.MXF", [0])
        f.write("CONTENTS/CLIPS001/INDEX.MIF", [0])
        let r = f.probe()
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.clipCount == 2)
        #expect(r.cameras.first?.identity.family == .canon)
        #expect(r.cameras.first?.identity.modelIsCertain == false)
    }

    @Test func `doc-derived: a P2 card counts video essence only`() {
        let f = Fixture("p2")
        f.write("LASTCLIP.TXT", text: "0001AB")
        f.write("CONTENTS/VIDEO/0001AB.MXF", [0])
        f.write("CONTENTS/AUDIO/0001AB00.MXF", [0])
        f.write("CONTENTS/AUDIO/0001AB01.MXF", [0])
        f.write("CONTENTS/PROXY/0001AB.MP4", [0])
        f.write("CONTENTS/CLIP/0001AB.XML", text: "<P2Main><ModelName>AJ-PX270</ModelName></P2Main>")
        let r = f.probe()
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.cameras.first?.identity.family == .panasonic)
    }

    @Test func `doc-derived: a RED ProRes-only clip spans .mov parts and counts once`() {
        let f = Fixture("redmov")
        f.write("A020_0213N4.RDM/A020_C001_0213N4.RDC/A020_C001_0213N4_001.mov", mp4Bytes(moov: mvhd(unix: 1_700_000_000)))
        f.write("A020_0213N4.RDM/A020_C001_0213N4.RDC/A020_C001_0213N4_002.mov", mp4Bytes(moov: mvhd(unix: 1_700_000_000)))
        let r = f.probe()
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.cameras.first?.identity.family == .red)
        #expect(r.reel == "A020")
    }

    @Test func `doc-derived: RED bytes in DCIM stay Nikon, and an unread ending is a note, not silence`() {
        let f = Fixture("nikon")
        f.write("DCIM/100NIKON/ROM_0001.R3D", r3dBytes(footer: nil, tags: [(0x1071, "NIKON ZR"), (0x1006, "123-456")]))
        let r = f.probe()
        #expect(r.cameras.first?.identity.family == .nikon)
        #expect(r.cameras.first?.identity.displayModel == "ZR")
        #expect(hasIssue(r, "nikon.r3d-ending", .note))
        #expect(!r.issues.contains { $0.severity != .note })
    }

    @Test func `WAVs beside camera clips are not a camera of their own`() {
        let f = Fixture("audio")
        let clip = "A001R0Z3/A001C001_140711_R0Z3/"
        f.write(clip + "A001C001_140711_R0Z3.0000001.ari", [0])
        f.write(clip + "A001C001_140711_R0Z3.wav", riffBytes(originator: "x", date: "2026-01-20"))
        let r = f.probe()
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.identity.family == .arri)
        #expect(r.hasAudio)
    }

    @Test func `Sampled days fill in between, and a change of day is found by bisection`() {
        let f = Fixture("days")
        var files: [CardFile] = []
        for n in 1 ... 40 {
            let name = String(format: "C%04d", n)
            let date = n <= 23 ? "2026-01-20T10:00:00+01:00" : "2026-01-21T10:00:00+01:00"
            f.write("M4ROOT/CLIP/\(name).MP4", mp4Bytes(major: "XAVC", moov: mvhd(unix: 1_700_000_000)))
            f.write("M4ROOT/CLIP/\(name)M01.XML", text: sonyClipXML(model: "ILME-FX3", date: date))
            files.append(CardFile(relPath: "M4ROOT/CLIP/\(name).MP4", size: 1000, mtime: 1_700_000_000 + Int64(n), kind: .video))
            files.append(CardFile(relPath: "M4ROOT/CLIP/\(name)M01.XML", size: 1000, mtime: 1_700_000_000 + Int64(n), kind: .sidecar))
        }
        let r = CardProber.probe(root: f.root, files: files, focus: nil)
        #expect(r.captureDays.map(\.day) == [CalendarDay(year: 2026, month: 1, day: 20), CalendarDay(year: 2026, month: 1, day: 21)])
        #expect(r.captureDays.map(\.fileCount) == [23, 17])
    }

    @Test func `mtime is the last resort and says so`() throws {
        let f = Fixture("mtime")
        f.write("A.MP4", [0, 0, 0, 0])
        let r = f.probe()
        #expect(r.captureDays.first?.source == .fileModified)
    }

    @Test func `doc-derived: a folder of same-shaped names from two bodies splits in proportion`() {
        let f = Fixture("two")
        for n in 1 ... 10 {
            let name = String(format: "C%04d", n)
            f.write("\(name).MP4", mp4Bytes(major: "XAVC", moov: mvhd(unix: 1_700_000_000)))
            let body = n <= 5 ? ("ILME-FX3", "1111111", "0000AAFFFE000001") : ("ILME-FX6V", "7654321", "0000AAFFFE000003")
            f.write("\(name)M01.XML", text: sonyClipXML(model: body.0, serial: body.1, systemId: body.2))
        }
        let r = f.probe()
        #expect(r.cameras.count == 2)
        #expect(r.cameras.map(\.clipCount).reduce(0, +) == 10)
    }
}

@Suite("Formats look")
struct FormatsLook {
    @Test func `doc-derived: strong markers, compared case-insensitively`() {
        #expect(look { $0.write("M4ROOT/CLIP/a.MP4") } == .cameraCard(.sony))
        #expect(look { $0.write("xdroot/Clip/a.MXF") } == .cameraCard(.sony))
        #expect(look { $0.write("CINEROOT/Clip/a.MXF") } == .cameraCard(.sony))
        #expect(look { $0.write("private/M4ROOT/CLIP/a.MP4") } == .cameraCard(.sony))
        #expect(look { $0.write("PRIVATE/XDROOT/Clip/a.MXF") } == .cameraCard(.sony))
        #expect(look { $0.write("PRIVATE/PANA_GRP/x") } == .cameraCard(.panasonic))
        #expect(look { $0.write("PRIVATE/AUDIO/a.WAV") } == .cameraCard(.canon))
        #expect(look { $0.write("CONTENTS/CLIPS001/AA0001/a.MXF") } == .cameraCard(.canon))
        #expect(look { $0.write("CONTENTS/VIDEO/a.MXF"); $0.write("LASTCLIP.TXT") } == .cameraCard(.panasonic))
        #expect(look { $0.write("CRM/REEL_0001/a.CRM") } == .cameraCard(.canon))
        #expect(look { $0.write("XFVC/REEL_0001/a.MP4") } == .cameraCard(.canon))
        #expect(look { $0.write("A020_0213N4.RDM/A020_C001_0213N4.RDC/a.R3D") } == .cameraCard(.red))
        #expect(look { $0.write("A_0001_12NR/A_0001C001_240504_104800_a12NR.mxf") } == .cameraCard(.arri))
        #expect(look { $0.write("A001R0Z3/A001C001_140711_R0Z3.mxf") } == .cameraCard(.arri))
        #expect(look { $0.write("Scene001_003.TAKE/Scene001_003_Tr1.WAV") } == .cameraCard(.audioRecorder))
        #expect(look { $0.write("FOLDER01/ZOOM0001.WAV") } == .cameraCard(.audioRecorder))
        #expect(look { $0.write("Scene001_001.WAV") } == .cameraCard(.audioRecorder))
        #expect(look { $0.write("AVCHD/BDMV/a") } == .cameraCard(.unknown))
        #expect(look { $0.write("DCIM/999XYZ/a.JPG") } == .cameraCard(.unknown))
        #expect(look { $0.write("DCIM/100MSDCF/a.JPG") } == .cameraCard(.sony))
        #expect(look { $0.write("DCIM/100EOSR5/a.CR3") } == .cameraCard(.canon))
        #expect(look { $0.write("DCIM/100_FUJI/a.RAF") } == .cameraCard(.fujifilm))
        #expect(look { $0.write("DCIM/100GOPRO/a.MP4") } == .cameraCard(.gopro))
        #expect(look { $0.write(".codexvfs", text: "{}"); $0.write("A001R0Z3/x.mxf") } == .cameraCard(.arri))
    }

    @Test func `doc-derived: camera files with no structure ask the user`() {
        if case .maybeCard = look({ $0.write("A001_08151512_C001.braw") }) {} else { Issue.record("root BRAW") }
        if case .maybeCard = look({ $0.write("Day 1/A001_08151512_C001.braw") }) {} else { Issue.record("one level down") }
        if case .maybeCard = look({ $0.write("A001_C001_0213N4_001.R3D") }) {} else { Issue.record("root R3D") }
        if case .maybeCard = look({ $0.write("A001_08151512_C001.mov") }) {} else { Issue.record("camera-named ProRes") }
    }

    @Test func `Nothing that looks like a card`() {
        #expect(look { _ in } == .notACard)
        #expect(look { $0.write("Documents/letter.txt") } == .notACard)
    }

    @Test func `Markers deeper than the root don't count`() {
        #expect(look { $0.write("CLIENT/CARD A082/M4ROOT/CLIP/a.MP4") } == .notACard)
        #expect(look { $0.write("BACKUP/DCIM/100MSDCF/a.JPG") } == .notACard)
    }

    @Test func `A root DCIM next to dozens of client folders is not a card`() {
        let r = look { f in
            f.write("DCIM/100MSDCF/a.JPG")
            for n in 0 ..< 24 { f.write("CLIENT \(n)/notes.txt") }
        }
        #expect(r == .notACard)
    }

    @Test func `Project files at the root or one level down mean a working drive`() {
        #expect(look { $0.write("M4ROOT/CLIP/a.MP4"); $0.write("edit.prproj") } == .notACard)
        #expect(look { $0.write("A001_08151512_C001.braw"); $0.write("Edit/edit.drp") } == .notACard)
    }
}

@Suite("Formats names")
struct FormatsNames {
    @Test func `Display names`() {
        let sony = ["ILME-FX3": "FX3", "ILME-FX6V": "FX6", "ILME-FX6T": "FX6", "ILME-FX2": "FX2", "ILME-FX30": "FX30", "ILME-FX3A": "FX3A", "ILME-FR7": "FR7",
                    "ILCE-7SM3": "A7S III", "ILCE-7M4": "A7 IV", "ILCE-1": "A1", "ILCE-1M2": "A1 II", "ILCE-7RM5": "A7R V", "ILCE-7CM2": "A7C II",
                    "ILCE-9M3": "A9 III", "ILCE-6700": "A6700", "ILCE-7CR": "A7CR", "ZV-E1": "ZV-E1", "ZV-E10": "ZV-E10", "ZV-E10M2": "ZV-E10 II",
                    "PXW-FX9": "FX9", "PXW-Z200": "Z200", "HXR-NX800": "NX800", "MPC-2610": "BURANO", "MPC-3628": "VENICE 2", "DSC-RX100M7": "RX100 VII"]
        for (model, name) in sony { #expect(CameraNames.sony(model) == name) }
        #expect(CameraNames.canon("Canon EOS R5") == "R5")
        #expect(CameraNames.canon("Canon EOS C70") == "C70")
        #expect(CameraNames.canon("Canon EOS R5m2") == "R5 II")
        #expect(CameraNames.canon("Canon EOS R5 C") == "R5 C")
        #expect(CameraNames.canon("EOS C400") == "C400")
        #expect(CameraNames.nikon("NIKON Z 8") == "Z8")
        #expect(CameraNames.nikon("NIKON Z 6_3") == "Z6 III")
        #expect(CameraNames.nikon("NIKON Z f") == "Zf")
        #expect(CameraNames.nikon("NIKON ZR") == "ZR")
        #expect(CameraNames.panasonic("DC-GH7") == "GH7")
        #expect(CameraNames.blackmagic("Blackmagic URSA Cine 12K LF") == "URSA Cine 12K LF")
        #expect(CameraNames.dji("DJI OsmoPocket3") == "Osmo Pocket 3")
        #expect(CameraNames.apple("Apple iPhone 17 Pro Max 24mm") == "iPhone 17 Pro Max")
    }

    @Test func `A display name is a safe folder name, whatever a file claims`() {
        #expect(CameraNames.safeFolderName("../../etc/passwd") == "etc passwd")
        #expect(CameraNames.safeFolderName("A:B/C\\D") == "A B C D")
        #expect(CameraNames.safeFolderName("  ...  ") == "Camera")
        #expect(CameraNames.safeFolderName("V-RAPTOR [X] 8K VV") == "V-RAPTOR [X] 8K VV")
        #expect(CameraNames.safeFolderName("bad\u{0}name\u{7}.") == "badname")
        #expect(CameraNames.safeFolderName(String(repeating: "x", count: 200)).count == 48)
    }

    @Test func `Serials: placeholders are not serials`() {
        #expect(CameraNames.cleanSerial("4294967295") == nil)
        #expect(CameraNames.cleanSerial("0000000") == nil)
        #expect(CameraNames.cleanSerial("  ") == nil)
        #expect(CameraNames.cleanSerial(nil) == nil)
        #expect(CameraNames.cleanSerial("123456789012") == "123456789012")
    }

    @Test func `Base36, both worked examples from the docs`() {
        #expect(Base36.decode("12RJ") == 50239)
        #expect(Base36.decode("N9O") == 30156)
        #expect(Base36.decode("a") == nil)
        #expect(ClipName.arri("A_0001C001_240504_104800_a12NR")?.serial == "50103")
        #expect(ClipName.arri("A004C010_210421_RN9O")?.serial == "30156")
        #expect(ClipName.arri("A_0001C001_240504_104800_h12NR_hde")?.reelFolder == "A_0001_12NR")
        #expect(ClipName.arri("A001C001_140711_R0Z3.0027301")?.reelFolder == "A001R0Z3")
        #expect(ClipName.arri("A082C001_260120DB") == nil)
    }

    @Test func `Reels`() {
        #expect(ClipName.reel("A082C001_260120DB") == "A082")
        #expect(ClipName.reel("C001L001_261022ZT") == "C001")
        #expect(ClipName.reel("A001C001_260120XX_CANON") == "A001")
        #expect(ClipName.reel("AA0001C001") == "AA0001")
        #expect(ClipName.reel("A001_08151512_C001") == "A001")
        #expect(ClipName.reel("A020_C001_0213N4") == "A020")
        #expect(ClipName.reel("A_0001C001_240504_104800_a12NR") == "A_0001_12NR")
        #expect(ClipName.reel("C0283") == nil)
        #expect(ClipName.reel("A20261024_0005") == nil)
        #expect(ClipName.reel("FX6_1020_0001") == nil)
        #expect(ClipName.reel("DSC02465") == nil)
    }

    @Test func `Dates are the digits as written`() {
        #expect(WrittenDate.day("2026-10-22T01:48:15+09:00") == CalendarDay(year: 2026, month: 10, day: 22))
        #expect(WrittenDate.day("2026:01:20 18:01:11") == CalendarDay(year: 2026, month: 1, day: 20))
        #expect(WrittenDate.day("20150317") == CalendarDay(year: 2015, month: 3, day: 17))
        #expect(WrittenDate.day("Monday") == nil)
        #expect(WrittenDate.day("2026-02-30") == nil)
        #expect(WrittenDate.day("0000:00:00 00:00:00") == nil)
        #expect(WrittenDate.day("") == nil)
    }

    @Test func `GoPro names`() {
        #expect(ClipName.goPro("GX011234.MP4")?.chapter == 1)
        #expect(ClipName.goPro("GH021234.mp4")?.video == 1234)
        #expect(ClipName.goPro("GL011234.LRV") == nil)
        #expect(ClipName.goPro("GOPR1234.MP4") == nil)
    }

    @Test func `Kinds: photos go to the photo folder and only photos do`() {
        let cases: [(String, FileKind)] = [
            ("DCIM/100MSDCF/DSC02465.ARW", .still), ("DCIM/100MSDCF/DSC02465.JPG", .still),
            ("DCIM/100EOSR5/IMG_0001.CR3", .still), ("DCIM/100EOS5D/IMG_0001.CR2", .still), ("DCIM/100NIKON/DSC_0001.NEF", .still),
            ("DCIM/100_FUJI/DSCF0001.RAF", .still), ("DCIM/101APPLE/IMG_1.HEIC", .still), ("anywhere/IMG_0001.DNG", .still),
            ("stills/A001_08151512_S001.jpg", .still), ("STILLS/A001_08151512_S001.braw", .still), ("stills/A001_08151512_S001.dng", .still),
            ("M4ROOT/THMBNL/C0001T01.JPG", .sidecar), ("XDROOT/Thmbnl/C0001T01.JPG", .sidecar),
            ("Camera01/Thumb/VID_20260531_010338_00_001.bmp", .sidecar), ("DCIM/Camera01/Thumb/x.jpg", .sidecar),
            ("M4ROOT/CLIP/C0001.MP4", .video), ("M4ROOT/CLIP/C0001M01.XML", .sidecar), ("XDROOT/Clip/x.MXF", .video),
            ("a.braw", .video), ("a.BRAW2", .video), ("A.RDC/a_001.R3D", .video), ("DCIM/100NC_Z8/DSC_0001.R3D", .video), ("a.NEV", .video),
            ("a.ari", .video), ("a.arx", .video), ("a.insv", .video), ("CRM/REEL_0001/a.CRM", .video), ("AVCHD/BDMV/STREAM/00000.MTS", .video),
            ("a.lrv", .sidecar), ("a.LRF", .sidecar), ("a.THM", .sidecar), ("a.RMD", .sidecar), ("a.rtn", .sidecar), ("a.ale", .sidecar),
            ("a.SRT", .sidecar), ("a.sidecar", .sidecar), ("a.WAV", .audio), ("PRIVATE/AUDIO/a.wav", .audio), ("a.MP3", .audio),
            ("cover.jpg", .other), ("MISC/version.txt", .other), ("noextension", .other), (".hidden", .other), ("Clip_000123.dng", .video),
        ]
        for (path, kind) in cases { #expect(CardProber.kind(ofRelativePath: path) == kind, "\(path)") }
    }

    @Test func `Kind is cheap: a hundred thousand paths in well under a second`() {
        let t = Date()
        for n in 0 ..< 100_000 { _ = CardProber.kind(ofRelativePath: "M4ROOT/CLIP/C\(n).MP4") }
        #expect(Date().timeIntervalSince(t) < 1.0)
    }
}
