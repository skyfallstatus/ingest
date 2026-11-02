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

    init(size: String = "512m") throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let label = "ING" + UUID().uuidString.prefix(6)     // exFAT labels stop at 11 characters
        #expect(Self.hdiutil(["create", "-type", "SPARSE", "-size", size, "-fs", "ExFAT", "-volname", String(label), dmg]) == 0)
        attach()
    }

    func attach(readOnly: Bool = false) { #expect(Self.hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", root, dmg] + (readOnly ? ["-readonly"] : [])) == 0) }
    @discardableResult func detach() -> Int32 { Self.hdiutil(["detach", root]) }
    deinit {
        detach()
        try? FileManager.default.removeItem(atPath: folder)
    }
}

private let kind: (String) -> FileKind = { _ in .video }
private let fm = FileManager.default

private func publish(_ from: String, _ to: String) -> Int32 { IngestEngine.publish(from, as: to, drivePath: "to", journal: nil) }

@Suite("Real volumes", .serialized)
struct DiskImageTests {
    /// A real full exFAT drive: a record fails with its bytes half down and the file's end moved, so nothing marks where it stops.
    private func fillUntilARecordFails(_ journal: LedgerJournal, _ drive: String, like line: LedgerEntry) -> String {
        let filler = drive + "/filler.bin"
        let fd = open(filler, O_CREAT | O_WRONLY, 0o644)
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        for size in [buf.count, 4096] { while write(fd, &buf, size) > 0 {} }
        fsync(fd); close(fd)
        for i in 0 ..< 200_000 {
            var e = line; e.cardPath = "PAD\(i).MP4"; e.drivePath = "S/PAD\(i).MP4"
            if (try? journal.record(e)) == nil { return filler }
        }
        Issue.record("no record failed")
        return filler
    }

    private func visit(_ card: String, _ drive: String, _ read: CardRead, record: Bool) -> CardVerdict {
        let ledger = Ledger(driveRoot: drive)
        let f = read.listing.files[0]
        let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(f, "S/" + f.relPath, read.quick[f.relPath]!)], ledger: ledger, jobName: "x", control: IngestControl(), record: record) { _, _ in }
        let issues = Pipeline.settle(issues: [], states: r.states, weak: r.weak, driveRoot: drive, ledger: ledger)
        return Pipeline.conclude(read: read, states: r.states, proved: r.proofs, issues: issues, driveRoot: drive, kind: kind).verdict
    }

    private func entry(_ card: String, _ read: CardRead, weak: Bool? = nil) -> LedgerEntry {
        let f = read.listing.files[0]
        return LedgerEntry(cardPath: f.relPath, drivePath: "S/" + f.relPath, size: f.size, quick: read.quick[f.relPath]!,
                           hash: hexHash(ci_hash_uncached(card + "/" + f.relPath, nil, nil, nil).hash), weak: weak)
    }

    @Test func `A failed record on a full drive can't swallow a refusal after it`() throws {
        let card = temp(), image = try Image(size: "600m"), drive = image.root
        put(card + "/C0001.MP4", rnd(1_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "TORN", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
        try journal.begin()
        put(drive + "/S/C0001.MP4", fm.contents(atPath: card + "/C0001.MP4")!)
        let line = entry(card, read)
        try journal.record(line)
        let filler = fillUntilARecordFails(journal, drive, like: line)
        unlink(filler)
        _ = journal.seal([line], flushVolume: { EIO })
        journal.close()
        guard case .hold = visit(card, drive, read, record: true) else { Issue.record("the refusal has to be on the record"); return }
    }

    @Test func `A failed record on a full drive can't swallow a weak mark after it`() throws {
        let card = temp(), image = try Image(size: "600m"), drive = image.root
        put(card + "/C0001.MP4", rnd(1_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "TORN", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
        try journal.begin()
        put(drive + "/S/C0001.MP4", fm.contents(atPath: card + "/C0001.MP4")!)
        var other = entry(card, read); other.drivePath = "S/OTHER.MP4"
        try journal.record(other)
        let filler = fillUntilARecordFails(journal, drive, like: other)
        unlink(filler)
        try journal.record(entry(card, read, weak: true))
        #expect(journal.seal([], flushVolume: { 0 }))
        journal.close()
        guard case .hold = visit(card, drive, read, record: true) else { Issue.record("a weak mark has to be on the record"); return }
    }

    @Test func `A read-only drive can't finish a copy whose record was lost`() throws {
        let card = temp(), image = try Image(), drive = image.root
        put(card + "/C0001.MP4", rnd(2_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let dying = Flag()
        _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                 hooks: FaultHooks(afterCopy: { _, _, _ in dying.on = true }, syncVolume: { _ in 0 }, journalFails: { dying.on })) { _ in }
        #expect(fm.fileExists(atPath: drive + "/S/C0001.MP4"), "the attack needs the file with no record of it")
        image.detach()
        image.attach(readOnly: true)
        guard case .hold = visit(card, drive, read, record: false) else { Issue.record("a look can't finish it"); return }
        guard case .hold = visit(card, drive, read, record: true) else { Issue.record("and there's no flush to be had"); return }
    }

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
        // Only the file: a device number can change across mounts if another image attaches, and nothing relies on it.
        let after = ResolvedRoot(drive)?.stamp("S/C0001.MP4")
        #expect(after?.inode == stamped?.inode && after?.size == stamped?.size && after?.mtime == stamped?.mtime && after?.mtimeNanos == stamped?.mtimeNanos,
                "nothing on the file gives it away, which is why the mount has to")
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
        if case .failed? = r.states["S/clip.bin"] {} else { Issue.record("a link can't prove anything: \(String(describing: r.states["S/clip.bin"]))") }
    }

    // ExFAT can't rename exclusively, and checking first left a gap another writer could fall into.
    @Test func `A file already at the name keeps it`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8)); put(to, Data("OTHER CLIENT FOOTAGE".utf8))
        #expect(publish(from, to) == EEXIST)
        #expect(fm.contents(atPath: to) == Data("OTHER CLIENT FOOTAGE".utf8))
        #expect(fm.contents(atPath: from) == Data("NEW".utf8))
    }

    // A writer that publishes by rename leaves the app's reservation unchanged, and was overwritten.
    @Test func `A writer that renames onto the name keeps it`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8))
        let theirs: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 1 else { return }
            let side = String(cString: to!) + ".their"
            try? Data("OTHER CLIENT FOOTAGE".utf8).write(to: URL(fileURLWithPath: side))
            rename(side, to!)
        }
        #expect(withFaults(reserving: theirs) { publish(from, to) } == EEXIST)
        #expect(fm.contents(atPath: to) == Data("OTHER CLIENT FOOTAGE".utf8))
        #expect(fm.contents(atPath: from) == Data("NEW".utf8), "and the proved file is still at its temporary name")
    }

    @Test func `A writer that renames an empty file onto the name keeps it`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8))
        let theirs: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 1 else { return }
            let side = String(cString: to!) + ".their"
            FileManager.default.createFile(atPath: side, contents: Data())
            rename(side, to!)                                          // empty, so only its identity can tell
        }
        #expect(withFaults(reserving: theirs) { publish(from, to) } == EEXIST)
        #expect(fm.contents(atPath: to) == Data())
        #expect(fm.contents(atPath: from) == Data("NEW".utf8), "and the proved file is still at its temporary name")
    }

    // A real job on real exFAT, and the ID that really moved.
    @Test func `An empty file on exFAT stays proved whatever its made-up ID does`() throws {
        let card = temp(), image = try Image(), drive = image.root
        put(card + "/SONY/SONYCARD.IND", Data())
        put(card + "/C0001.MP4", rnd(500_000))
        let read = CardReader.read(root: card, kind: kind)
        let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
        #expect(!out.weakVerification)
        var raw = ci_stamp()
        #expect(ci_stamp_file(drive + "/S/SONY/SONYCARD.IND", &raw) == 0)
        #expect(raw.ino > UInt64(1) << 63, "exFAT has no cluster to number an empty file by")
        #expect(Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict == .safe)
        #expect(ResolvedRoot(drive)?.stamp("S/SONY/SONYCARD.IND") == out.proofs["SONY/SONYCARD.IND"]?.stamp)
        #expect(DriveStamp({ var other = raw; other.ino &+= 1; return other }()) == DriveStamp(raw))
    }

    // A drive mounted read-only refuses a flush too. It has nothing on its way, so that's no reason to doubt it.
    @Test func `A copy on a read-only volume isn't called weak for refusing a flush`() throws {
        let card = temp(), image = try Image(), drive = image.root
        let d = rnd(100_000)
        put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
        image.detach()
        image.attach(readOnly: true)
        let read = CardReader.read(root: card, kind: kind)
        let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                     ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
        #expect(!r.weak)
        if case .verified? = r.states["C0001.MP4"] {} else { Issue.record("\(String(describing: r.states["C0001.MP4"]))") }
    }

    // Read-only can't confirm a flush, so nothing unfinished can be finished there, however good the read.
    @Test func `A cut-off copy on a read-only volume stays on hold`() throws {
        let card = temp(), image = try Image(), drive = image.root
        put(card + "/C0001.MP4", rnd(100_000))
        let read = CardReader.read(root: card, kind: kind)
        let dying = Flag()
        _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                 hooks: FaultHooks(syncVolume: { _ in dying.on = true; return 0 }, journalFails: { dying.on })) { _ in }
        image.detach()
        image.attach(readOnly: true)
        let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                     ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
        #expect(r.weak)
        if case .verified? = r.states["C0001.MP4"] {} else { Issue.record("\(String(describing: r.states["C0001.MP4"]))") }
    }

    // The job that would clear a stale temp was refused for lack of the room that temp was taking.
    @Test func `A dead job's temp doesn't stop the job that clears it`() throws {
        let card = temp(), image = try Image(size: "420m"), drive = image.root
        put(card + "/C0001.MP4", rnd(60_000_000))
        put(drive + "/.ingest/tmp/DEAD.0.part", rnd(250_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
        #expect(out.failures.isEmpty)
        #expect(!fm.fileExists(atPath: drive + "/.ingest/tmp/DEAD.0.part"))
    }

    // A job removed the sidecar holding the tags of folders it never made.
    @Test func `A job leaves an existing folder's tags alone`() throws {
        let card = temp(), image = try Image(), drive = image.root
        put(card + "/C0001.MP4", rnd(1000))
        try fm.createDirectory(atPath: drive + "/Shoot", withIntermediateDirectories: true)
        #expect(setxattr(drive + "/Shoot", "com.apple.metadata:_kMDItemUserTags", "x", 1, 0, 0) == 0)
        #expect(fm.fileExists(atPath: drive + "/._Shoot"))
        let read = CardReader.read(root: card, kind: kind)
        _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "Shoot/Card"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
        #expect(fm.fileExists(atPath: drive + "/._Shoot"))
        #expect(getxattr(drive + "/Shoot", "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0) == 1)
    }

    @Test func `A writer that gets to the name first keeps it, even with nothing written yet`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/to"
        put(from, Data("NEW".utf8))
        let first: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 0 else { return }
            close(open(to!, O_CREAT | O_EXCL | O_WRONLY, 0o644))       // in, between the refused rename and the reservation
        }
        #expect(withFaults(reserving: first) { publish(from, to) } == EEXIST)
        #expect(fm.contents(atPath: to) == Data())
        #expect(fm.contents(atPath: from) == Data("NEW".utf8), "and the proved file is still at its temporary name")
    }

    @Test func `An empty name is taken, and only the name`() throws {
        let image = try Image(), from = image.root + "/from", to = image.root + "/sub/to"
        put(from, Data("NEW".utf8))
        try fm.createDirectory(atPath: image.root + "/sub", withIntermediateDirectories: true)
        #expect(publish(from, to) == 0)
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
        #expect(withFaults(reserving: careful) { publish(from, to) } == 0)
        #expect(fm.contents(atPath: to) == Data("NEW".utf8))

        let from2 = image.root + "/from2", to2 = image.root + "/to2"
        put(from2, Data("NEW".utf8))
        let careless: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { to, done in
            guard done == 1 else { return }
            let fd = open(to!, O_CREAT | O_TRUNC | O_WRONLY, 0o644)    // what a careless one does
            _ = write(fd, "OTHER", 5)
            close(fd)
        }
        #expect(withFaults(reserving: careless) { publish(from2, to2) } == EEXIST)
        #expect(fm.contents(atPath: to2) == Data("OTHER".utf8))
        #expect(fm.contents(atPath: from2) == Data("NEW".utf8), "and the proved file is still at its temporary name")
    }
}
