import Foundation
import Testing
@testable import IngestCore

@Suite("What a volume looks like")
struct VolumeLookTests {
    @Test func `Two unknown folders beside a camera folder are tolerated, three are not`() {
        #expect(look { f in f.write("M4ROOT/CLIP/a.MP4"); for n in 0 ..< 2 { f.write("X\(n)/a.txt") } } == .cameraCard(.sony))
        #expect(isMaybe(look { f in f.write("M4ROOT/CLIP/a.MP4"); for n in 0 ..< 3 { f.write("X\(n)/a.txt") } }))
    }

    @Test func `A multi-folder card built only of camera folders stays a card`() {
        let r = look { f in
            for name in ["DCIM/100CANON/a.CR3", "PRIVATE/AUDIO/a.WAV", "XFVC/REEL_0001/a.MP4", "CRM/REEL_0001/a.CRM", "MISC/a", "CONTENTS/a", "AVF_INFO/a", "SONY/a", "LOG/a"] { f.write(name) }
        }
        if case .cameraCard = r {} else { Issue.record("\(r)") }
    }

    @Test func `doc-derived: nine ARRI reels, nine RED magazines and nine TAKE folders are all cards`() {
        #expect(look { f in for n in 1 ... 9 { f.write("A00\(n)R0Z3/A00\(n)C001_240504_R0Z3.mxf") } } == .cameraCard(.arri))
        #expect(look { f in for n in 1 ... 9 { f.write("A00\(n)_0101XY.RDM/A00\(n)_C001_0101XY.RDC/a.R3D") } } == .cameraCard(.red))
        #expect(look { f in for n in 1 ... 9 { f.write("Scene001_00\(n).TAKE/a_Tr1.WAV") } } == .cameraCard(.audioRecorder))
    }

    @Test func `doc-derived: a recorder with project folders of any name is a recorder`() {
        let r = look { f in
            for name in ["Interview", "Ambience", "Wild", "Day1", "Day2", "Day3", "Day4", "Day5", "Day6", "Day7"] {
                f.write("\(name)/001.WAV", riffBytes(originator: "SoundDev: MixPre-10 II TJ0000000", date: "2026-10-01"))
            }
        }
        #expect(r == .cameraCard(.audioRecorder))
    }

    @Test func `Date folders with no recorder in them are no recorder`() {
        let r = look { f in
            for n in 1 ... 9 { f.write("26100\(n)/mix.wav", riffBytes(originator: "Pro Tools", date: "2026-10-01")) }
        }
        #expect(r == .notACard)
    }

    @Test func `One recorder folder among client folders doesn't make a recorder`() {
        let r = look { f in
            f.write("Audio/001.WAV", riffBytes(originator: "SoundDev: MixPre-10 II TJ0000000", date: "2026-10-01"))
            for n in 0 ..< 10 { f.write("Client \(n)/notes.txt") }
        }
        #expect(r == .notACard)
    }

    @Test func `Project bundles count at the root and one level down`() {
        #expect(look { $0.write("M4ROOT/CLIP/a.MP4"); $0.write("Job.fcpbundle/x") } == .notACard)
        #expect(look { $0.write("M4ROOT/CLIP/a.MP4"); $0.write("Edits/Job.fcpbundle/x") } == .notACard)
    }

    @Test func `Unknown media of every kind is asked about, not offered as a drive`() {
        #expect(isMaybe(look { $0.write("holiday.mov") }))
        #expect(isMaybe(look { $0.write("Clips/a.MP4") }))
        #expect(isMaybe(look { $0.write("a.mxf") }))
        #expect(isMaybe(look { $0.write("DSC0001.ARW") }))
        #expect(isMaybe(look { $0.write("TASCAM_0001.wav") }))
    }

    @Test("An external recorder SSD must be asked about") func atomos() {
        let f = Fixture("d2b")
        f.write("NINJAV_S001_S001_T001.MOV", mp4Bytes(major: "qt  ", moov: mvhd(unix: 1_760_000_000)))
        #expect(CardProber.look(atRoot: f.root) != .notACard)
    }
    @Test("A freshly formatted RED card is a card") func emptyRDM() {
        let f = Fixture("d2c")
        try? FileManager.default.createDirectory(at: f.root.appendingPathComponent("A001_1101XY.RDM"), withIntermediateDirectories: true)
        #expect(CardProber.look(atRoot: f.root) != .notACard)
    }
    @Test("A working SSD with a DCIM folder is not a card") func workingDriveDCIM() {
        let f = Fixture("d3")
        f.write("DCIM/100MSDCF/DSC00001.ARW", [1, 2, 3])
        for name in ["Exports", "Selects", "Graphics", "Music"] { f.write("\(name)/a.mov", [1]) }
        if case .cameraCard = CardProber.look(atRoot: f.root) { Issue.record("working drive called a camera card") }
    }
    @Test("A recorder card with nine folders") func recorderFolders() {
        let f = Fixture("d8")
        for d in 1 ... 9 {
            let name = "26100\(d)"
            f.write("\(name)/\(name)_001.WAV", riffBytes(originator: "SoundDev: 888 AB1234C", date: "2026-10-01"))
        }
        #expect(CardProber.look(atRoot: f.root) != .notACard)
    }

    // The review's C14: a folder for each clip was counted as a drive full of strangers.
    @Test("Nine Sony clip folders are asked about, not offered as a drive") func clipFolders() {
        #expect(isMaybe(look { f in for n in 1 ... 9 { f.write("A005C00\(n)_160510N2/A005C00\(n)_160510N2.mxf"); f.write("A005C00\(n)_160510N2/A005C00\(n)_160510N2M01.xml") } }))
    }

    @Test("Nine CinemaDNG take folders are asked about, not offered as a drive") func takeFolders() {
        #expect(isMaybe(look { f in for n in 1 ... 9 { f.write("A007_07271236_C03\(n)/A007_07271236_C03\(n)_000000.dng") } }))
    }

    @Test("Nine client folders holding other names stay a drive") func clientFolders() {
        #expect(look { f in for n in 0 ..< 9 { f.write("Client \(n)/Edit v2.mov") } } == .notACard)
    }
}
