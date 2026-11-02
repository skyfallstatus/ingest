// What real camera originals taught us, kept as byte-accurate fixtures so it survives the samples being deleted.
// No footage lives in this repository. Each fixture states the real file it follows.
//
// Sony excerpt: Netflix "Sparks" OCF, A005C006_160510NM01.xml, © Netflix, CC BY 4.0.
// Live tests at the end read INGEST_SAMPLES, by default /tmp/ingest-samples, and skip cleanly when it isn't there.
import Foundation
import Testing
@testable import IngestCore

@Suite("Formats field: Sony")
struct FormatsFieldSony {
    /// From the real M01: a recorder writes itself as Device and the body as Camera.
    let axs = #"""
    <NonRealTimeMeta lastUpdate="2016-05-11T13:05:18-08:00" xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.00">
    	<TargetMaterial umidRef="060A2B340101010501010D4313000000E2E304FC187505D4080046020132348E"/>
    	<CreationDate value="2016-05-10T15:37:36-08:00"/>
    	<VideoFormat>
    		  <VideoFrame captureFps="59.94p" formatFps="59.94p" videoCodec="F55RAWSQ_4096_2160"/>
    	</VideoFormat>
    	<Device manufacturer="Sony" modelName="AXS-R5" serialNo="00013454">
    	</Device>
    	<Camera manufacturer="Sony" modelName="PMW-F55" serialNo="101982"/>
    </NonRealTimeMeta>
    """#

    @Test func `A recorder is not the camera: Camera wins over Device`() throws {
        let c = try #require(Sony.parseClipXML(axs))
        #expect(c.model == "PMW-F55")
        #expect(c.serial == "101982")
        #expect(CameraNames.sony("PMW-F55") == "F55")
        #expect(Sony.hasProvenEnding(axs))
    }

    @Test func `A clip with only Device still reads, and X-OCN stays unproven`() throws {
        #expect(Sony.parseClipXML(sonyClipXML())?.model == "ILME-FX3")
        #expect(!Sony.hasProvenEnding(#"<VideoFrame videoCodec="X-OCN_ST_4096"/>"#))
    }

    @Test func `A cut F55 RAW clip is held, from its sidecar, though the MXF holds no XML`() {
        let f = Fixture("f55")
        f.write("A005C006_160510N2/A005C006_160510N2.mxf", mxfBytes(company: "Sony", product: "AXS ", status: 4, cut: true))
        f.write("A005C006_160510N2/A005C006_160510N2M01.xml", text: axs)
        let r = f.probe()
        #expect(hasIssue(r, "mxf.cut-short", .hold))
        #expect(r.cameras.first?.identity.displayModel == "F55")
        #expect(r.reel == "A005")
    }
}

@Suite("Formats field: ARRI")
struct FormatsFieldARRI {
    @Test func `Real model strings become the name people use`() {
        #expect(CameraNames.arri("ARRI ALEXA 35") == "ALEXA 35")
        #expect(CameraNames.arri("ARRI ALEXA Mini LF") == "ALEXA Mini LF")
        #expect(CameraNames.arri("ALEXA Mini LF") == "ALEXA Mini LF")
        #expect(CameraNames.arri("Alexa LF Plus W") == "ALEXA LF")
        #expect(CameraNames.arri("Alexa65  XT") == "ALEXA 65")
        #expect(CameraNames.display(family: .arri, model: "ARRI ALEXA 35") == "ALEXA 35")
    }

    @Test func `Real names, each serial checked against the camera's own metadata`() {
        #expect(ClipName.arri("DW0001C020_251020_132002_c1I7H")?.serial == "70253")     // MXF JSON
        #expect(ClipName.arri("DW0001C020_251020_132002_c1I7H")?.reelFolder == "DW0001_1I7H")
        #expect(ClipName.arri("F004C028_190925_MN99")?.serial == "30141")               // ALE Camera_sn
        #expect(ClipName.arri("F004C028_190925_MN99")?.reelFolder == "F004MN99")
        #expect(ClipName.arri("B003C002_180327_R1ZA.1195823")?.serial == "2566")        // Codex XML SourceSerial
        #expect(ClipName.arri("A003C025_150830_R0D0")?.serial == "468")                 // QuickTime key
    }

    @Test func `ALEXA 35 JSON as real files have it: UTF-8, spaces round the colon`() {
        let json = "application/json\u{80}{p{\n\t\"cameraModel\" : \"ARRI ALEXA 35\",\n\t\"cameraSerialNumber\" : \"70253\",\n\t\"cameraSoftwarePackageName\" : \"5.01.00\"\n}\n"
        let f = Fixture("a35")
        f.write("DW0001_1I7H/DW0001C020_251020_132002_c1I7H.mxf", mxfBytes(company: "ARRI", status: 1, text: json))
        let r = f.probe()
        #expect(r.issues.isEmpty)       // an open header with a sound RIP, like 53 of 72 real files
        #expect(r.cameras.first?.identity.displayModel == "ALEXA 35")
        #expect(r.cameras.first?.identity.serial == "70253")
        #expect(r.reel == "DW0001_1I7H")
    }

    @Test func `A cut ARRI MXF is held: all 72 real ones end in a RIP`() {
        let f = Fixture("a35")
        f.write("DW0001_1I7H/DW0001C020_251020_132002_c1I7H.mxf", mxfBytes(company: "ARRI", status: 1, cut: true))
        #expect(hasIssue(f.probe(), "mxf.cut-short", .hold))
    }

    private func frame(_ magic: String, model: String) -> [UInt8] {
        var b = ascii(magic) + [0x12, 0x34, 0x56, 0x78] + [UInt8](repeating: 0, count: 200)
        b += ascii("ARRI 709") + [0, 0] + ascii("AlexaLF_2.0:41017") + [0, 0] + ascii(model) + [0, 0]
        return b + [UInt8](repeating: 0, count: 4096 - b.count)
    }

    @Test func `A frame says its own model: firmware beside it is not a name`() {
        let f = Fixture("ari")
        let path = "B003R1ZA/B003C002_180327_R1ZA/4448x1856/B003C002_180327_R1ZA."
        for n in 1195823 ... 1195825 { f.write(path + "\(n).ari", frame("ARRI", model: "Alexa LF Plus W")) }
        let r = f.probe()
        #expect(r.cameras.first?.identity.displayModel == "ALEXA LF")
        #expect(r.cameras.first?.identity.modelIsCertain == true)
        #expect(r.cameras.first?.identity.serial == "2566")
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.reel == "B003R1ZA")
        #expect(r.issues.isEmpty)
    }

    @Test func `HDE frames start CDXA and carry the model too`() {
        let f = Fixture("arx")
        f.write("F004MN99/F004C028_190925_MN99/F004C028_190925_MN99.0328979.arx", frame("CDXA", model: "ARRI ALEXA Mini LF"))
        f.write("F004MN99/F004C028_190925_MN99/F004C028_190925_MN99.5.wav", [1])
        f.write("F004MN99/F004C028_190925_MN99/F004C028_190925_MN99.12.wav", [1])
        let r = f.probe()
        #expect(r.cameras.count == 1)
        #expect(r.cameras.first?.identity.displayModel == "ALEXA Mini LF")
        #expect(r.issues.isEmpty)
    }

    @Test func `A gap inside a resolution folder names the clip, not 4448x1856`() throws {
        let f = Fixture("ari")
        let path = "B003C002_180327_R1ZA/4448x1856/B003C002_180327_R1ZA."
        for n in [1195823, 1195824, 1195826] { f.write(path + "\(n).ari", frame("ARRI", model: "Alexa LF Plus W")) }
        let issue = try #require(f.probe().issues.first { $0.code == "arri.frame-gap" })
        #expect(issue.severity == .hold)
        #expect(issue.message.contains("B003C002_180327_R1ZA"))
        #expect(issue.message.contains("1195825"))
        #expect(!issue.message.contains("4448x1856"))
    }

    @Test func `One short .ari frame is a hold: real frames are all one size`() throws {
        let f = Fixture("ari")
        let path = "B003C002_180327_R1ZA/4448x1856/B003C002_180327_R1ZA."
        for n in 1 ... 4 { f.write(path + "000000\(n).ari", frame("ARRI", model: "Alexa LF Plus W")) }
        f.write(path + "0000003.ari", Array(frame("ARRI", model: "Alexa LF Plus W").prefix(1024)))
        let issue = try #require(f.probe().issues.first)
        #expect(issue.code == "arri.frame-size")
        #expect(issue.severity == .hold)
        #expect(issue.paths == [path + "0000003.ari"])
    }

    @Test func `HDE frame sizes vary on real files, so that is no problem`() {
        let f = Fixture("arx")
        for (n, pad) in [(1, 0), (2, 40), (3, 90)] {
            f.write("F004MN99/F004C028_190925_MN99/F004C028_190925_MN99.000000\(n).arx", frame("CDXA", model: "ARRI ALEXA Mini LF") + [UInt8](repeating: 1, count: pad))
        }
        #expect(f.probe().issues.isEmpty)
    }

    @Test func `A real Codex XML is a sidecar, and so is md5.ada`() {
        #expect(CardProber.kind(ofRelativePath: "B003C002_180327_R1ZA/xml/md5.ada") == .sidecar)
        #expect(CardProber.kind(ofRelativePath: "B003C002_180327_R1ZA/xml/B003C002_180327_R1ZA.xml") == .sidecar)
    }
}

@Suite("Formats field: Blackmagic")
struct FormatsFieldBlackmagic {
    let base = [("manufacturer", "Blackmagic Design")]

    private func clip(_ model: String, count: UInt32?) -> [UInt8] {
        let numbers: [(String, UInt32)] = count.map { [("multicard_volume_number", 1), ("multicard_volume_count", $0)] } ?? []
        let meta = keysMeta(base + [("camera_type", model), ("date_recorded", "2021:04:19")], numbers: numbers)
        return atom("wide") + atom("mdat", [UInt8](repeating: 0x55, count: 2048)) + atom("moov", mvhd(unix: 1_660_000_000) + meta)
    }

    @Test func `A real count of 1, a u32, settles it on firmware 7`() {
        let f = Fixture("braw")
        f.write("Wetsuit.braw", clip("Blackmagic URSA Mini Pro 12K", count: 1))
        let r = f.probe()
        #expect(r.issues.isEmpty)
        #expect(r.captureDays.first?.day == CalendarDay(year: 2021, month: 4, day: 19))
        #expect(r.captureDays.first?.source == .cameraMetadata)
    }

    @Test func `A count of 2 in that same real form is proof`() {
        let f = Fixture("braw")
        f.write("A001_04191219_C057.braw", clip("Blackmagic URSA Mini Pro 12K", count: 2))
        #expect(hasIssue(f.probe(), "braw.striped", .hold))
    }

    @Test func `Firmware 9 drops the key on real URSA Cine clips, so a single card proves nothing`() {
        let f = Fixture("braw")
        f.write("A004_03311642_C035.braw", clip("Blackmagic URSA Cine 12K LF", count: nil))
        let r = f.probe()
        #expect(hasIssue(r, "braw.maybe-striped", .note))
        #expect(!r.issues.contains { $0.severity == .hold })
    }

    @Test func `Key names as real .mov metadata has them`() {
        let f = Fixture("mov")
        f.write("A002_08271039_C043.mov", mp4Bytes(major: "qt  ", moov: mvhd(unix: 1_694_505_248) + keysMeta([
            ("com.apple.proapps.manufacturer", "Blackmagic Design"),
            ("com.blackmagic-design.cameraType", "Blackmagic Cinema Camera 6K"),
            ("com.blackmagic-design.cinemacamera.uuid", "5e3ddb6e-816c-40d0-a492-db94d65e0535"),
            ("com.blackmagic-design.camera.dateRecorded", "2023:08:27"),
        ])))
        let r = f.probe()
        #expect(r.cameras.first?.identity.displayModel == "Cinema Camera 6K")
        #expect(r.cameras.first?.identity.bodyKey == "5e3ddb6e-816c-40d0-a492-db94d65e0535")
        #expect(r.cameras.first?.identity.serial == nil)
        #expect(r.captureDays.first?.day == CalendarDay(year: 2023, month: 8, day: 27))
    }

    @Test func `A CinemaDNG sequence is one clip, and a missing frame is a hold`() {
        let f = Fixture("dng")
        for n in [0, 1, 2, 4] { f.write("A007_07271236_C038/A007_07271236_C038_00000\(n).dng", [0]) }
        let r = f.probe()
        #expect(r.cameras.first?.clipCount == 1)
        #expect(hasIssue(r, "dng.frame-gap", .hold))
        #expect(r.issues.first?.message.contains("A007_07271236_C038") == true)
    }

    @Test func `A CinemaDNG sequence from 000000 with no gap passes`() {
        let f = Fixture("dng")
        for n in 0 ... 5 { f.write("A007_07271236_C038/A007_07271236_C038_00000\(n).dng", [0]) }
        #expect(f.probe().issues.isEmpty)
    }
}

// MARK: - Live samples, when present

private let trees = Samples.root + "/trees"
private func tree(_ name: String) -> Bool { FileManager.default.fileExists(atPath: trees + "/" + name) }
private func live(_ name: String) -> ProbeResult {
    CardProber.probe(root: URL(fileURLWithPath: trees + "/" + name), files: listing(trees + "/" + name, depth: 8), focus: nil)
}

@Suite("Formats field: live samples")
struct FormatsFieldLive {
    @Test(.enabled(if: tree("a35"))) func `ALEXA 35 reel`() {
        let r = live("a35")
        #expect(r.cameras.first?.identity.displayModel == "ALEXA 35")
        #expect(r.cameras.first?.identity.serial == "70253")
        #expect(r.reel == "DW0001_1I7H")
        #expect(r.issues.isEmpty)
    }
    @Test(.enabled(if: tree("lf"))) func `ALEXA LF frames`() {
        let r = live("lf")
        #expect(r.cameras.first?.identity.displayModel == "ALEXA LF")
        #expect(r.cameras.first?.identity.serial == "2566")
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.issues.isEmpty)
    }
    @Test(.enabled(if: tree("sparks"))) func `F55 on an AXS-R5`() {
        let r = live("sparks")
        #expect(r.cameras.first?.identity.displayModel == "F55")
        #expect(r.cameras.first?.identity.serial == "101982")
        #expect(r.issues.isEmpty)
    }
    @Test(.enabled(if: tree("bmd"))) func `Eight Blackmagic bodies`() {
        let r = live("bmd")
        #expect(r.cameras.count == 8)
        #expect(r.cameras.allSatisfy { $0.identity.family == .blackmagic && $0.identity.serial == nil && $0.identity.bodyKey != nil })
        #expect(!r.issues.contains { $0.severity != .note })
    }
    @Test(.enabled(if: tree("dng"))) func `Pocket 4K CinemaDNG`() {
        let r = live("dng")
        #expect(r.cameras.first?.identity.displayModel == "Pocket Cinema Camera 4K")
        #expect(r.cameras.first?.identity.serial == nil)
        #expect(r.cameras.first?.clipCount == 1)
        #expect(r.issues.isEmpty)
    }
    @Test(.enabled(if: tree("stills"))) func `Stills from every family`() {
        let r = live("stills")
        let names = Set(r.cameras.map(\.identity.displayModel))
        #expect(["R5", "R5 II", "R6", "R3", "Z8", "Zf", "S1H", "GH7", "X-H2S", "A7 IV", "A1", "ZV-E1", "HERO10 Black"].allSatisfy(names.contains))
    }
}
