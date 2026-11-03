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
    let bytes: Int

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

    init(megabytes: Int = 512) throws {
        bytes = megabytes << 20
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let label = "ING" + UUID().uuidString.prefix(6)     // exFAT labels stop at 11 characters
        guard Self.hdiutil(["create", "-type", "SPARSE", "-size", "\(megabytes)m", "-fs", "ExFAT", "-volname", String(label), dmg]) == 0 else {
            try? FileManager.default.removeItem(atPath: folder)
            throw NotItsOwnImage(description: "the image couldn't be made")
        }
        do { try attach() } catch { try? FileManager.default.removeItem(atPath: folder); throw error }
    }

    /// A test with no image has nowhere to go: what's left at `root` is a plain folder on the Mac's own disk.
    func attach(readOnly: Bool = false) throws {
        let code = Self.hdiutil(["attach", "-nobrowse", "-noautoopen", "-mountpoint", root, dmg] + (readOnly ? ["-readonly"] : []))
        guard code == 0, imageMounted(at: root) == dmg else { throw NotItsOwnImage(description: "\(dmg) isn't mounted at \(root)") }
    }
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
    /// It writes until the disk refuses, so it runs only on this image, on a volume no bigger than it, and for no more than its size.
    private func fillUntilARecordFails(_ journal: LedgerJournal, _ image: Image, like line: LedgerEntry) throws -> String {
        guard imageMounted(at: image.root) == image.dmg else { throw NotItsOwnImage(description: "\(image.root) isn't this test's image") }
        var fs = statfs()
        guard statfs(image.root, &fs) == 0, UInt64(fs.f_blocks) * UInt64(fs.f_bsize) <= UInt64(image.bytes) else {
            throw NotItsOwnImage(description: "\(image.root) is bigger than its image")
        }
        let filler = image.root + "/filler.bin"
        let fd = open(filler, O_CREAT | O_WRONLY, 0o644)
        writeUntilFull(fd, limit: image.bytes)
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

    @Test func `A test can tell its own image from the Mac's own disk`() throws {
        let image = try Image(megabytes: 32)
        #expect(imageMounted(at: image.root) == image.dmg)
        #expect(imageMounted(at: temp()) == nil, "a plain folder, which is what a failed attach leaves")
        #expect(imageMounted(at: image.folder) == nil)
    }

    @Test func `What fills a disk won't touch a folder that lost its image`() throws {
        let image = try Image(megabytes: 32)
        #expect(image.detach() == 0)
        let drive = temp()
        let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "J", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
        defer { journal.close() }
        let line = LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil)
        #expect(throws: NotItsOwnImage.self) { _ = try fillUntilARecordFails(journal, image, like: line) }
        #expect(!fm.fileExists(atPath: image.root + "/filler.bin"), "it stopped before writing a byte")
    }

    @Test func `An image that won't attach ends the test, not just a line of it`() throws {
        let image = try Image(megabytes: 32)
        #expect(image.detach() == 0)
        try fm.removeItem(atPath: image.dmg)
        #expect(throws: NotItsOwnImage.self) { try image.attach() }
    }

    @Test func `Filling stops at its limit, whatever the disk would take`() throws {
        let path = temp() + "/f"
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        defer { close(fd) }
        let written = writeUntilFull(fd, limit: 3 << 20)
        #expect(written == 3 << 20)
        #expect(try fm.attributesOfItem(atPath: path)[.size] as? Int == 3 << 20)
    }

    @Test func `A failed record on a full drive can't swallow a refusal after it`() throws {
        let card = temp(), image = try Image(megabytes: 600), drive = image.root
        put(card + "/C0001.MP4", rnd(1_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "TORN", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
        try journal.begin()
        put(drive + "/S/C0001.MP4", fm.contents(atPath: card + "/C0001.MP4")!)
        let line = entry(card, read)
        try journal.record(line)
        let filler = try fillUntilARecordFails(journal, image, like: line)
        unlink(filler)
        _ = journal.seal([line], flushVolume: { EIO })
        journal.close()
        guard case .hold = visit(card, drive, read, record: true) else { Issue.record("the refusal has to be on the record"); return }
    }

    @Test func `A failed record on a full drive can't swallow a weak mark after it`() throws {
        let card = temp(), image = try Image(megabytes: 600), drive = image.root
        put(card + "/C0001.MP4", rnd(1_000_000))
        let read = CardReader.read(root: card, kind: kind)
        let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "TORN", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
        try journal.begin()
        put(drive + "/S/C0001.MP4", fm.contents(atPath: card + "/C0001.MP4")!)
        var other = entry(card, read); other.drivePath = "S/OTHER.MP4"
        try journal.record(other)
        let filler = try fillUntilARecordFails(journal, image, like: other)
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
        try image.attach(readOnly: true)
        guard case .hold = visit(card, drive, read, record: false) else { Issue.record("a look can't finish it"); return }
        guard case .hold = visit(card, drive, read, record: true) else { Issue.record("and there's no flush to be had"); return }
    }

    @Test func `An unmount kills a mount for good, and doesn't have to ask its leave`() throws {
        let image = try Image()
        let anchor = try #require(MountAnchor(path: image.root))
        #expect(anchor.isCurrent)
        #expect(image.detach() == 0, "an anchor must never hold a volume in")
        #expect(!anchor.isCurrent)
        try image.attach()
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
        try image.attach()
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
        try image.attach()
        let again = CardReader.read(root: card, kind: kind)
        let states = CardMatcher.match(read: again, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive, proved: out.proofs)
        #expect(states["C0001.MP4"] == .likely(drivePath: "S/C0001.MP4"), "known at once, and read again before it counts")
    }

    /// The copy itself asks for room before each chunk, and a real volume answers. 10 MiB at most is written, onto this image.
    @Test func `A copy stops before it takes a real volume under what it has to keep`() throws {
        let image = try Image(megabytes: 64)
        guard imageMounted(at: image.root) == image.dmg else { throw NotItsOwnImage(description: "\(image.root) isn't this test's image") }
        let src = temp() + "/in.bin", dst = image.root + "/out.bin"
        put(src, rnd(10 << 20))
        let before = try #require(IngestEngine.freeBytes(at: image.root))
        guard before > 20 << 20 else { throw NotItsOwnImage(description: "the image has \(before) bytes free") }
        let keep = before - (9 << 20)     // room for one 8 MiB chunk, not for the whole file
        let r = ci_copy(src, dst, 10 << 20, keep, nil, nil)
        #expect(r.stage == Int32(CI_STAGE_LOW_SPACE))
        #expect(r.bytes < 10 << 20)
        unlink(dst)
        #expect((IngestEngine.freeBytes(at: image.root) ?? 0) >= keep)
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
        try image.attach(readOnly: true)
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
        try image.attach(readOnly: true)
        let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                     ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
        #expect(r.weak)
        if case .verified? = r.states["C0001.MP4"] {} else { Issue.record("\(String(describing: r.states["C0001.MP4"]))") }
    }

    // The job that would clear a stale temp was refused for lack of the room that temp was taking.
    @Test func `A dead job's temp doesn't stop the job that clears it`() throws {
        let card = temp(), image = try Image(megabytes: 420), drive = image.root
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
