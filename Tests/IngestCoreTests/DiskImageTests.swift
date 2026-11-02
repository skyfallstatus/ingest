// What only a real volume can show: real unmounts, and exFAT's own rename. Throwaway images under /tmp, nothing else.
import CIngest
import Foundation
import Testing
@testable import IngestCore

/// A small exFAT image, mounted at a private path, and gone when the test is.
private final class Image {
    private static let lock = NSLock()
    let folder = "/private/tmp/ingest-image-" + UUID().uuidString.prefix(8)
    var dmg: String { folder + "/v.sparseimage" }
    var root: String { folder + "/m" }

    @discardableResult private static func hdiutil(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args + ["-quiet"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    init() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let label = "ING" + UUID().uuidString.prefix(6)     // exFAT labels stop at 11 characters
        #expect(Self.hdiutil(["create", "-type", "SPARSE", "-size", "512m", "-fs", "ExFAT", "-volname", String(label), dmg]) == 0)
        attach()
    }

    func attach() { #expect(Self.hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", root, dmg]) == 0) }
    @discardableResult func detach() -> Int32 { Self.hdiutil(["detach", root]) }
    deinit {
        detach()
        try? FileManager.default.removeItem(atPath: folder)
    }
}

private let kind: (String) -> FileKind = { _ in .video }
private let fm = FileManager.default

@Suite("Real volumes", .serialized)
struct DiskImageTests {
    @Test func `An unmount kills a mount for good, and doesn't have to ask its leave`() throws {
        let image = try Image()
        let anchor = try #require(MountAnchor(path: image.root))
        #expect(anchor.isCurrent)
        #expect(image.detach() == 0, "an anchor must never hold a volume in")
        #expect(!anchor.isCurrent)
        image.attach()
        #expect(!anchor.isCurrent, "the same volume back at the same path is a new mount")
        #expect(MountAnchor(path: image.root)?.isCurrent == true)
    }

    @Test func `Proof doesn't survive the drive leaving the Mac, even though the file looks identical`() throws {
        let card = temp(), image = try Image(), drive = image.root
        put(card + "/C0001.MP4", rnd(2_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let ledger = Ledger(driveRoot: drive)
        let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl()) { _ in }
        let stamped = ResolvedRoot(drive)?.stamp("S/C0001.MP4")
        #expect(Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict == .safe)
        image.detach()
        image.attach()
        #expect(ResolvedRoot(drive)?.stamp("S/C0001.MP4") == stamped, "nothing on the file gives it away, which is why the mount has to")
        #expect(Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict != .safe)
    }

    @Test func `Proof doesn't survive the card leaving the Mac`() throws {
        let image = try Image(), drive = temp(), card = image.root
        put(card + "/C0001.MP4", rnd(2_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
        #expect(Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict == .safe)
        image.detach()
        image.attach()
        let again = CardReader.read(root: card, kind: kind)
        let states = CardMatcher.match(read: again, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive, proved: out.proofs)
        #expect(states["C0001.MP4"] == .likely(drivePath: "S/C0001.MP4"), "known at once, and read again before it counts")
    }

    @Test func `A whole job on exFAT finishes clean, in the app's own folder`() throws {
        let card = temp(), image = try Image(), drive = image.root
        for i in 0..<5 { put(card + "/CLIP/\(i).MP4", rnd(600_000)) }
        let read = CardReader.read(root: card, kind: kind)
        let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
        #expect(!out.weakVerification)
        #expect(out.failures.isEmpty)
        #expect(Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict == .safe)
        #expect(tempFiles(on: drive).isEmpty)
        for i in 0..<5 { #expect(fm.contentsEqual(atPath: card + "/CLIP/\(i).MP4", andPath: drive + "/S/CLIP/\(i).MP4")) }
        #expect(try fm.contentsOfDirectory(atPath: drive + "/S/CLIP").sorted() == (0..<5).map { "\($0).MP4" }, "no reservations and no sidecars left")
    }

    @Test func `A link on exFAT leads nowhere`() throws {
        let image = try Image(), drive = image.root, card = temp()
        put(card + "/S/clip.bin", rnd(1_000_000))
        try fm.createSymbolicLink(atPath: drive + "/S", withDestinationPath: card + "/S")
        let read = CardReader.read(root: card, kind: kind)
        let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/clip.bin", read.quick["S/clip.bin"]!)],
                                     ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: false) { _, _ in }
        #expect(r.states["S/clip.bin"] == .missing)
    }

    // The review's A-05: exFAT can't rename exclusively, and checking first left a gap another writer could fall into.
    @Test func `A file already at the name keeps it`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8)); put(to, Data("OTHER CLIENT FOOTAGE".utf8))
        #expect(ci_rename_excl(from, to) == EEXIST)
        #expect(fm.contents(atPath: to) == Data("OTHER CLIENT FOOTAGE".utf8))
        #expect(fm.contents(atPath: from) == Data("NEW".utf8))
    }

    @Test func `A writer that gets to the name first keeps it, even with nothing written yet`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8))
        let first: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 0 else { return }
            close(open(to!, O_CREAT | O_EXCL | O_WRONLY, 0o644))       // in, between the refused rename and the reservation
        }
        #expect(withFaults(reserving: first) { ci_rename_excl(from, to) } == EEXIST)
        #expect(fm.contents(atPath: to) == Data())
        #expect(fm.contents(atPath: from) == Data("NEW".utf8), "and the proved file is still at its temporary name")
    }

    @Test func `An empty name is taken, and only the name`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/sub/to"
        put(from, Data("NEW".utf8))
        try fm.createDirectory(atPath: image.root + "/sub", withIntermediateDirectories: true)
        #expect(ci_rename_excl(from, to) == 0)
        #expect(fm.contents(atPath: to) == Data("NEW".utf8))
        #expect(!fm.fileExists(atPath: from))
    }

    @Test func `A writer that arrives at the last moment can't get in with O_EXCL, or be overwritten without it`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8))
        let careful: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 1 else { return }
            let fd = open(to!, O_CREAT | O_EXCL | O_WRONLY, 0o644)     // what a careful writer does
            if fd >= 0 { close(fd); abort() }                          // it must find the name taken
        }
        #expect(withFaults(reserving: careful) { ci_rename_excl(from, to) } == 0)
        #expect(fm.contents(atPath: to) == Data("NEW".utf8))

        let from2 = image.root + "/from2", to2 = image.root + "/to2"
        put(from2, Data("NEW".utf8))
        let careless: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 1 else { return }
            let fd = open(to!, O_CREAT | O_TRUNC | O_WRONLY, 0o644)    // what a careless one does
            _ = write(fd, "OTHER", 5)
            close(fd)
        }
        #expect(withFaults(reserving: careless) { ci_rename_excl(from2, to2) } == EEXIST)
        #expect(fm.contents(atPath: to2) == Data("OTHER".utf8))
        #expect(fm.contents(atPath: from2) == Data("NEW".utf8), "and the proved file is still at its temporary name")
    }
}
