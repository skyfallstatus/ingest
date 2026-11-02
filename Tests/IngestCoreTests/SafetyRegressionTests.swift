import CIngest
import Foundation
import Testing
@testable import IngestCore

// Each test here is an attack from the independent safety review that once produced a false "Safe to format".

private let fm = FileManager.default

/// A count a fault hook can keep from the engine's thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

/// A switch a fault hook can flip from the engine's thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
private let kind: (String) -> FileKind = { _ in .video }

private func copyCard(_ card: String, _ drive: String, _ dest: String = "F/A") throws {
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let states = CardMatcher.match(read: read, ledger: ledger, index: DriveIndex.scan(root: drive), driveRoot: drive)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: dest, states: states), ledger: ledger, control: IngestControl()) { _ in }
}

/// A card going back in: the record alone, with nothing read.
private func reinsertVerdict(_ card: String, _ drive: String) -> CardVerdict {
    let read = CardReader.read(root: card, kind: kind)
    let s = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive)
    return Pipeline.conclude(read: read, states: s, proved: [:], issues: [], driveRoot: drive, kind: kind).verdict
}

@Test func unreadableRootIsNeverEmptyOrSafe() {
    let root = temp()
    put(root + "/CLIP/C0001.MP4", rnd(4096))
    chmod(root, 0)
    defer { chmod(root, 0o755) }
    let l = listCard(root: root, kind: kind)
    #expect(!l.errors.isEmpty)
    let v = Verdict.evaluate(listing: l, unreadable: [], states: [:], issues: [], cardUnchanged: true)
    #expect(v != .empty && v != .safe)
}

@Test func missingRootIsNeverEmptyOrSafe() {
    let l = listCard(root: "/tmp/ingest-no-such-card-\(UUID().uuidString)", kind: kind)
    #expect(!l.errors.isEmpty)
    #expect(Verdict.evaluate(listing: l, unreadable: [], states: [:], issues: [], cardUnchanged: true) != .empty)
}

@Test func unreadableSubfolderIsReported() {
    let root = temp()
    put(root + "/A/C0001.MP4", rnd(1000)); put(root + "/B/C0002.MP4", rnd(1000))
    chmod(root + "/B", 0)
    defer { chmod(root + "/B", 0o755) }
    let l = listCard(root: root, kind: kind)
    #expect(l.errors.contains { $0.path == "B" })
    #expect(l.files.count == 1)
}

@Test func aLedgerRecordAloneNeverTurnsACardGreen() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(2_000_000))
    try copyCard(card, drive)
    #expect(reinsertVerdict(card, drive) != .safe)
}

@Test func differentMiddleSameEndsFailsTheRealCheck() throws {
    let card = temp(), drive = temp()
    let head = rnd(64 * 1024), tail = rnd(64 * 1024)
    put(card + "/C0001.MP4", head + rnd(800_000) + tail)
    try copyCard(card, drive)
    put(card + "/C0001.MP4", head + rnd(800_000) + tail)   // another take: same name, size and ends
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let s = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)
    guard case .likely(let p)? = s["C0001.MP4"] else { Issue.record("expected a hint"); return }
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive,
                                 candidates: [(read.listing.files[0], p, read.quick["C0001.MP4"]!)],
                                 ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    #expect(r.states["C0001.MP4"] == .failed("the copy on the drive doesn't match the card"))
}

@Test func driveFileReplacedFailsTheRealCheck() throws {
    let card = temp(), drive = temp()
    let d = rnd(1_000_000)
    put(card + "/C0001.MP4", d)
    try copyCard(card, drive)
    put(drive + "/F/A/C0001.MP4", Data(count: d.count))    // zeros, same size
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    guard case .likely(let p)? = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)["C0001.MP4"] else {
        Issue.record("expected a hint"); return
    }
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], p, read.quick["C0001.MP4"]!)],
                                 ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    #expect(r.states["C0001.MP4"] == .failed("the copy on the drive doesn't match the card"))
}

/// A later visit, in a new session: the record gives a hint, and only a full read of both sides proves it.
private func laterVisit(_ card: String, _ drive: String) throws -> (read: CardRead, states: [String: FileState], proofs: [String: Proof], weak: Bool) {
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    guard case .likely(let p)? = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)["C0001.MP4"] else {
        Issue.record("expected a hint")
        return (read, [:], [:], false)
    }
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], p, try #require(read.quick["C0001.MP4"]))],
                                 ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    return (read, r.states, r.proofs, r.weak)
}

@Test func aWeakCopyStaysWeakOnALaterVisit() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    try copyCard(card, drive)
    try markLedgerWeak(drive)
    let visit = try laterVisit(card, drive)
    #expect(visit.weak)
    let issues = Pipeline.settle(issues: [], states: visit.states, weak: visit.weak, driveRoot: drive)
    let v = Pipeline.conclude(read: visit.read, states: visit.states, proved: visit.proofs, issues: issues, driveRoot: drive, kind: kind).verdict
    if case .hold = v {} else { Issue.record("a weak copy must not turn green on a later visit: \(v)") }
}

@Test func aWeakCopyFoundByTheEngineIsStillWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    try copyCard(card, drive, "S")
    try markLedgerWeak(drive)
    // A stopped check leaves the file only likely, so the job meets it already at its destination.
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(out.states["C0001.MP4"] == .verified(drivePath: "S/C0001.MP4", hash: try #require(hashOfVerified(out.states["C0001.MP4"])), bytes: 1_000_000))
    #expect(out.weakVerification)
}

private func hashOfVerified(_ s: FileState?) -> String? {
    if case .verified(_, let hash, _)? = s { hash } else { nil }
}

@Test func aFailedVolumeSyncIsStillWeakOnALaterVisit() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    #expect(out.weakVerification)
    #expect(try laterVisit(card, drive).weak)
}

@Test func aSoundCopyIsNotCalledWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    try copyCard(card, drive)
    #expect(try laterVisit(card, drive).weak == false)
}

@Test func aCheckThatDoesNotRecordWritesNothingOnTheDrive() throws {
    let card = temp(), drive = temp()
    let d = rnd(1_000_000)
    put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
    let read = CardReader.read(root: card, kind: kind)
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", try #require(read.quick["C0001.MP4"]))],
                                 ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: false) { _, _ in }
    if case .verified? = r.states["C0001.MP4"] {} else { Issue.record("it should still prove the file") }
    #expect(try fm.subpathsOfDirectory(atPath: drive).sorted() == ["S", "S/C0001.MP4"])
}

@Test func aManifestGivesTheBytesRead() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(5000))
    var read = CardReader.read(root: card, kind: kind)
    read.listing.files[0].size = 0      // a virtual volume lists real files at 0 bytes
    let job = makeJob(read, drive: drive, dest: "S")
    let out = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(try Pipeline.writeManifest(job: job, states: out.states, read: read))
    let folder = drive + "/S/ascmhl/"
    let name = try #require(try fm.contentsOfDirectory(atPath: folder).first { $0.hasSuffix(".mhl") })
    #expect(try String(contentsOfFile: folder + name, encoding: .utf8).contains("size=\"5000\""))
}

@Test func zeroListedFilesNeverMatchTheLedger() throws {
    let card = temp(), drive = temp()
    put(card + "/SONY/SONYCARD.IND", Data())
    try copyCard(card, drive)
    let other = temp()
    for i in 0..<5 { put(other + "/clip/\(i).arx", Data()) }   // a virtual volume lists real files at 0 bytes
    let read = CardReader.read(root: other, kind: kind)
    let s = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive)
    #expect(s.values.allSatisfy { $0 == .missing })
}

@Test func forgedLedgerPathIsIgnored() {
    #expect(!Ledger.isInsideDrive("../\u{301}x"), "a slash and the accent after it are one character to Swift, and two to the filesystem")
    #expect(!Ledger.isInsideDrive(".ingest/\u{301}x"))
    #expect(!Ledger.isInsideDrive(".INGEST/tmp/x.part"), "a drive that ignores case reaches the same folder")
    #expect(!Ledger.isInsideDrive("../card/C0001.MP4"))
    #expect(!Ledger.isInsideDrive("F/../../card/C0001.MP4"))
    #expect(!Ledger.isInsideDrive("/Volumes/Card/C0001.MP4"))
    #expect(Ledger.isInsideDrive("F/A..B/C0001.MP4"))
}

// The review's B13 and C13: a character count was taken in bytes, so a name beyond ASCII cut the folder short.
@Test func aNameBeyondASCIIDoesNotCutItsHomeShort() {
    let name = "撮影/é.mov", clip = CardFile(relPath: name, size: 2 << 20, mtime: 0, kind: .video)
    #expect(CardMatcher.existingHome(states: [name: .likely(drivePath: "Shoot/A001/" + name)], files: [clip]) == "Shoot/A001")
}

@Test func sharedMarkerFilesDontMakeAHome() {
    let f = [CardFile(relPath: "SONY/SONYCARD.IND", size: 0, mtime: 0, kind: .other),
             CardFile(relPath: "M4ROOT/MEDIAPRO.XML", size: 900, mtime: 0, kind: .sidecar)]
    let s: [String: FileState] = ["SONY/SONYCARD.IND": .likely(drivePath: "Old/A082/SONY/SONYCARD.IND"),
                                  "M4ROOT/MEDIAPRO.XML": .likely(drivePath: "Old/A082/M4ROOT/MEDIAPRO.XML")]
    #expect(CardMatcher.existingHome(states: s, files: f) == nil)
    let clip = CardFile(relPath: "M4ROOT/CLIP/C1.MP4", size: 5_000_000, mtime: 0, kind: .video)
    var s2 = s; s2[clip.relPath] = .likely(drivePath: "Old/A082/M4ROOT/CLIP/C1.MP4")
    #expect(CardMatcher.existingHome(states: s2, files: f + [clip]) == "Old/A082")
}

/// A card and a drive with every file proved by a real job, ready for an attack.
private func provedCard(size: Int = 2_000_000) throws -> (card: String, drive: String, read: CardRead, ledger: Ledger, out: IngestOutcome) {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(size))
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl()) { _ in }
    #expect(verdict(read, out, drive) == .safe, "the attack has to start from Safe")
    return (card, drive, read, ledger, out)
}

private func verdict(_ read: CardRead, _ out: IngestOutcome, _ drive: String) -> CardVerdict {
    Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict
}

private func setTime(_ path: String, to f: CardFile) { #expect(ci_set_times(path, f.mtime, f.mtimeNanos) == 0) }

/// Writes over the middle of a file in place, keeping its length.
private func editMiddle(_ path: String) {
    let h = FileHandle(forUpdatingAtPath: path)!
    try? h.seek(toOffset: 300_000); try? h.write(contentsOf: Data([1, 2, 3])); try? h.close()
}

@Test func swappedCardWithSameNamesAndSizesIsCaught() throws {
    let (card, drive, read, _, out) = try provedCard()
    put(card + "/C0001.MP4", rnd(2_000_000))    // a different card now sits at this path
    setTime(card + "/C0001.MP4", to: read.listing.files[0])     // with the same time, so only the fingerprint can tell
    #expect(verdict(read, out, drive) != .safe)
}

// The review's A-08: the listing compared names and sizes, so a changed file with a changed time passed the last look.
@Test func aChangedTimeOnTheCardFailsTheLastLook() throws {
    let (card, drive, read, _, out) = try provedCard()
    editMiddle(card + "/C0001.MP4")
    #expect(ci_set_times(card + "/C0001.MP4", read.listing.files[0].mtime + 60, 0) == 0)
    #expect(CardReader.read(root: card, kind: kind).quick == read.quick, "the ends are unchanged, so only the time can tell")
    #expect(verdict(read, out, drive) != .safe)
}

@Test func aProofDoesNotOutliveTheFileItProved() throws {
    let (card, drive, first, ledger, out) = try provedCard()
    let proved = out.proofs
    let file = first.listing.files[0]
    func isVerified(_ read: CardRead) -> Bool {
        if case .verified? = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive, proved: proved)[file.relPath] { true } else { false }
    }
    #expect(isVerified(first), "the same file keeps its proof")
    #expect(isVerified(CardReader.read(root: card, kind: kind)), "and an unchanged session reads nothing again")

    // Same name, same size, new head: a recheck must never carry the old proof across.
    var changed = first
    changed.quick[file.relPath] = String(repeating: "0", count: 16)
    #expect(!isVerified(changed))

    // Same fingerprint, rewritten: the time gives it away, even by a nanosecond.
    changed = first
    changed.listing.files[0].mtime += 1
    #expect(!isVerified(changed))
    changed = first
    changed.listing.files[0].mtimeNanos += 1
    #expect(!isVerified(changed))

    changed = first
    changed.listing.files[0].size += 1
    #expect(!isVerified(changed))
}

// The review's A-01 and C01: a retained proof never looked at the destination, so changed bytes kept Safe.
@Test func aCopyEditedInPlaceLosesItsProof() throws {
    let (card, drive, read, ledger, out) = try provedCard()
    editMiddle(drive + "/S/C0001.MP4")
    #expect(verdict(read, out, drive) != .safe)
    let s = CardMatcher.match(read: CardReader.read(root: card, kind: kind), ledger: ledger, index: nil, driveRoot: drive, proved: out.proofs)
    if case .verified? = s["C0001.MP4"] { Issue.record("a changed copy kept its proof") }
}

@Test func aCopyReplacedWithTheSameSizeAndTimeLosesItsProof() throws {
    let (_, drive, read, _, out) = try provedCard()
    let p = drive + "/S/C0001.MP4"
    let keep = drive + "/S/keep"            // holds the inode, so the new file can't be given the old one
    #expect(rename(p, keep) == 0)
    put(p, Data(count: 2_000_000))
    setTime(p, to: read.listing.files[0])
    #expect(verdict(read, out, drive) != .safe)
}

@Test func aCopyThatOnlyChangedItsTimeLosesItsProof() throws {
    let (_, drive, read, _, out) = try provedCard()
    #expect(ci_set_times(drive + "/S/C0001.MP4", 1_000_000_000, 0) == 0)
    #expect(verdict(read, out, drive) != .safe)
}

// The review's A-02, B01 and C02: proofs made on one drive were carried to another by a resumed job.
@Test func aProofOnOneDriveMeansNothingOnAnother() throws {
    let card = temp(), a = temp(), b = temp()
    put(card + "/one.bin", rnd(1_000_000)); put(card + "/two.bin", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    var first = read
    first.listing.files = read.listing.files.filter { $0.relPath == "one.bin" }
    let onA = try IngestEngine.run(job: makeJob(first, drive: a, dest: "S"), ledger: Ledger(driveRoot: a), control: IngestControl()) { _ in }
    put(b + "/S/one.bin", rnd(1_000_000))      // same name and size, unrelated bytes

    let ledger = Ledger(driveRoot: b)
    let job = Pipeline.makeJob(read: read, states: onA.states, proved: onA.proofs, cardName: "T", driveRoot: b, camera: nil,
                               destination: Destination(footageRoot: "S"), probe: ProbeResult(hasVideo: true), index: nil)
    #expect(job.items.map(\.file.relPath).sorted() == ["one.bin", "two.bin"], "nothing from drive A is left out of a job on drive B")
    let onB = try IngestEngine.run(job: job, ledger: ledger, control: IngestControl()) { _ in }
    var states = onA.states
    for (k, v) in onB.states { states[k] = v }
    let proofs = onA.proofs.merging(onB.proofs) { _, new in new }
    let v = Pipeline.conclude(read: read, states: states, proved: proofs, issues: [], driveRoot: b, kind: kind).verdict
    #expect(v != .safe)
    if case .failed? = onB.states["one.bin"] {} else { Issue.record("the wrong bytes on drive B must be refused") }
}

@Test func aProofIsLeftOutOfAJobOnlyOnItsOwnDrive() throws {
    let (_, drive, read, ledger, out) = try provedCard()
    func items(_ root: String) -> Int {
        Pipeline.makeJob(read: read, states: out.states, proved: out.proofs, cardName: "T", driveRoot: root, camera: nil,
                         destination: Destination(footageRoot: "S"), probe: ProbeResult(hasVideo: true), index: nil).items.count
    }
    #expect(items(drive) == 0)
    #expect(items(temp()) == 1)
    ledger.mount?.retire()
    #expect(items(drive) == 1, "nor once its mount has gone")
}

// The review's A-07, B02 and C04: a replacement at the same path kept the old verdict. The same drive read through a
// new mount proves nothing either: proof ends with the mount, on both sides.
@Test func aProofDiesWithTheDrivesMount() throws {
    let (_, drive, read, ledger, out) = try provedCard()
    ledger.mount?.retire()
    #expect(verdict(read, out, drive) != .safe)
}

@Test func aProofDiesWithTheCardsMount() throws {
    let (_, drive, read, _, out) = try provedCard()
    read.mount?.retire()
    #expect(verdict(read, out, drive) != .safe)
}

@Test func aMissingOrForgedProofIsNoProof() throws {
    let (_, drive, read, ledger, out) = try provedCard()
    #expect(Pipeline.conclude(read: read, states: out.states, proved: [:], issues: [], driveRoot: drive, kind: kind).verdict != .safe)
    var forged = out.states
    forged["C0001.MP4"] = .verified(drivePath: "S/C0001.MP4", hash: "0", bytes: 2_000_000)
    #expect(Pipeline.conclude(read: read, states: forged, proved: out.proofs, issues: [], driveRoot: drive, kind: kind).verdict != .safe)
    let s = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)
    if case .verified? = s["C0001.MP4"] { Issue.record("nothing on the drive can make a proof") }
}

// The review's A-04 and C06: the destination folder swapped for a link to the card, so the card was read twice.
@Test func aDestinationFolderLinkedToTheCardProvesNothing() throws {
    let card = temp(), drive = temp()
    put(card + "/clip.bin", rnd(2_000_000))
    try copyCard(card, drive, "S")
    try fm.removeItem(atPath: drive + "/S")
    try fm.createSymbolicLink(atPath: drive + "/S", withDestinationPath: card)

    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let f = read.listing.files[0]
    let s = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)
    #expect(s[f.relPath] == .missing, "a record that leads through a link isn't even a hint")
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(f, "S/clip.bin", read.quick[f.relPath]!)],
                                 ledger: ledger, jobName: "x", control: IngestControl(), record: false) { _, _ in }
    if case .failed? = r.states[f.relPath] {} else { Issue.record("a link can't prove anything") }
    #expect(r.proofs.isEmpty)
    let job = makeJob(read, drive: drive, dest: "S")
    let out = try? IngestEngine.run(job: job, ledger: ledger, control: IngestControl()) { _ in }
    #expect(out == nil, "and nothing is written through it")
    #expect(try fm.subpathsOfDirectory(atPath: card) == ["clip.bin"], "the card is as it was")
}

@Test func aLinkToAnotherCopyOnTheDriveIsNotThatPath() throws {
    let card = temp(), drive = temp()
    let d = rnd(1_000_000)
    put(card + "/C0001.MP4", d); put(drive + "/Real/C0001.MP4", d)
    try fm.createSymbolicLink(atPath: drive + "/S", withDestinationPath: drive + "/Real")
    let read = CardReader.read(root: card, kind: kind)
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                 ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: false) { _, _ in }
    if case .failed? = r.states["C0001.MP4"] {} else { Issue.record("the same bytes and the same volume, and still no read through a link") }
}

@Test func aDestinationFileLinkedToTheCardIsNotACopy() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(2_000_000))
    try fm.createDirectory(atPath: drive + "/S", withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: drive + "/S/C0001.MP4", withDestinationPath: card + "/C0001.MP4")
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    if case .failed? = out.states["C0001.MP4"] {} else { Issue.record("a link must not pass for a copy: \(String(describing: out.states["C0001.MP4"]))") }
}

@Test func aHardLinkToTheCardIsNotACopy() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    try fm.createDirectory(atPath: drive + "/S", withIntermediateDirectories: true)
    #expect(link(card + "/C0001.MP4", drive + "/S/C0001.MP4") == 0)
    let read = CardReader.read(root: card, kind: kind)
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                 ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: false) { _, _ in }
    #expect(r.states["C0001.MP4"] == .failed("what's on the drive isn't a separate copy of it"))
}

@Test func theAppsOwnFolderCantBeALinkToTheCard() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    try fm.createSymbolicLink(atPath: drive + "/.ingest", withDestinationPath: card)
    let read = CardReader.read(root: card, kind: kind)
    #expect(throws: IngestError.self) { try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in } }
    #expect(try fm.contentsOfDirectory(atPath: card) == ["C0001.MP4"], "the app never writes to a card")
}

// The review's C05: a saved setup could hold `..`, and the engine would follow it off the drive.
@Test func aDestinationThatLeavesTheDriveIsRefusedBeforeAnythingIsWritten() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    let name = (card as NSString).lastPathComponent
    for dest in ["../\(name)/escaped", "/tmp/escaped", "A/../../B", "./A", ".ingest/ledger"] {
        var job = makeJob(read, drive: drive, dest: dest)
        #expect(throws: IngestError.outsideDrive(dest)) { try IngestEngine.preflight(job: job) }
        job.dirsToCreate = []
        #expect(throws: IngestError.self) { try IngestEngine.preflight(job: job) }
    }
    #expect(!fm.fileExists(atPath: card + "/escaped"))
}

@Test func aSavedSetupThatLeavesTheDriveIsNotASetup() {
    let inner = [InnerFolder(name: "Footage", role: .footage)]
    func setup(_ path: [PathLevel], inner: [InnerFolder] = inner) -> DriveSetup {
        DriveSetup(path: path, shootName: ShootNameStyle(), inner: inner, footage: .perCamera)
    }
    #expect(setup([.year, .literal("Paid work"), .client]).staysOnDrive)
    #expect(!setup([.literal("../card")]).staysOnDrive)
    #expect(!setup([.literal("..")]).staysOnDrive)
    #expect(!setup([.literal("a/b")]).staysOnDrive)
    #expect(!setup([.literal("/Volumes/Card")]).staysOnDrive)
    #expect(!setup([.client], inner: [InnerFolder(name: "F", role: .footage, children: [InnerFolder(name: "..", role: .plain)])]).staysOnDrive)
}

// The review's A-03: only the drive's cache was asked about, so a card read from the Mac's cache could count as proof.
@Test func aCardCacheThatWontClearIsWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try withFaults(noMap: card) {
        try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    }
    #expect(out.weakVerification)
    #expect(try laterVisit(card, drive).weak, "and it stays weak after a good read")
}

@Test func aCardCacheThatWontClearIsWeakForACopyAlreadyThere() throws {
    let card = temp(), drive = temp()
    let d = rnd(1_000_000)
    put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
    let read = CardReader.read(root: card, kind: kind)
    let r = withFaults(noMap: card) {
        IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                             ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
    }
    #expect(r.weak)
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/C0001.MP4"))
}

@Test func aDriveCacheThatWontClearIsWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try withFaults(noMap: drive) {
        try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    }
    #expect(out.weakVerification)
}

// The review's A-06: a job the drive wouldn't confirm was only marked afterwards, and that mark could fail too.
@Test func aJobTheDriveWouldntConfirmStaysWeakEvenIfNothingMoreCanBeWritten() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let dying = Flag()
    let hooks = FaultHooks(syncVolume: { _ in dying.on = true; return 1 }, journalFails: { dying.on })
    let same = Ledger(driveRoot: drive)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: same, control: IngestControl(), hooks: hooks) { _ in }
    #expect(out.weakVerification)
    #expect(same.isWeak(drivePath: "S/C0001.MP4"), "this mount knows")
    #expect(try laterVisit(card, drive).weak, "and so does the drive")
}

@Test func aJobTheDriveConfirmedIsNotWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(try laterVisit(card, drive).weak == false)
}

@Test func aSealThatCantBeWrittenLeavesTheJobWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let dying = Flag()
    let hooks = FaultHooks(syncVolume: { _ in dying.on = true; return 0 }, journalFails: { dying.on })
    #expect(try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: hooks) { _ in }.weakVerification)
    #expect(try laterVisit(card, drive).weak)
}

@Test func aStoppedJobTheDriveConfirmedStaysStrong() throws {
    let card = temp(), drive = temp()
    for i in 0..<4 { put(card + "/c/\(i).MP4", rnd(300_000)) }
    let control = IngestControl()
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: control) {
        if $0.verifiedFiles >= 2 { control.stop() }
    }
    #expect(out.cancelled && !out.weakVerification)
}

@Test func aWeakMarkThatCantBeSyncedIsReported() throws {
    let drive = temp()
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: "j", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    defer { journal.close() }
    let calls = Flag()
    journal.fault = { defer { calls.on = true }; return calls.on }  // the write goes through, the sync doesn't
    let e = LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: true)
    #expect(throws: IngestError.self) { try journal.record(e) }
    #expect(ledger.isWeak(drivePath: "S/a"), "this mount still knows")
}

@Test func aWeakCopyWhoseMarkCantBeWrittenNeverGetsItsName() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try withFaults(noMap: card) {
        try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                             hooks: FaultHooks(journalFails: { true })) { _ in }
    }
    if case .failed? = out.states["C0001.MP4"] {} else { Issue.record("it can't count") }
    #expect(!fm.fileExists(atPath: drive + "/S/C0001.MP4"), "or a later visit would find it with no mark on it")
    #expect(tempFiles(on: drive).isEmpty)
}

@Test func aWeakCheckWhoseMarkCantBeWrittenDoesNotCount() throws {
    let card = temp(), drive = temp()
    let d = rnd(1_000_000)
    put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
    put(drive + "/.ingest", Data())         // a file where the ledger's folder has to go, so no journal can open
    let read = CardReader.read(root: card, kind: kind)
    let r = withFaults(noMap: card) {
        IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                             ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
    }
    if case .failed? = r.states["C0001.MP4"] {} else { Issue.record("a weak result that can't be kept can't count") }
    #expect(r.proofs.isEmpty)
}

// The review's C09: weak was remembered by path, so a rename cleared it.
@Test func aWeakCopyStaysWeakUnderANewName() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(2_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    #expect(out.weakVerification)
    try fm.moveItem(atPath: drive + "/S", toPath: drive + "/Renamed")

    let ledger = Ledger(driveRoot: drive)
    let s = CardMatcher.match(read: read, ledger: ledger, index: DriveIndex.scan(root: drive), driveRoot: drive)
    #expect(s["C0001.MP4"] == .likely(drivePath: "Renamed/C0001.MP4"))
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "Renamed/C0001.MP4", read.quick["C0001.MP4"]!)],
                                 ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    #expect(r.weak)
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "Renamed/C0001.MP4"), "and the new name stays weak from here on")
}

@Test func aGoodNewCopyOfTheSameBytesIsNotWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "Again"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(!Ledger(driveRoot: drive).isWeak(drivePath: "Again/C0001.MP4"))
    // And that's the copy a later visit finds, so a card on hold has a way back to green.
    #expect(CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive)["C0001.MP4"] == .likely(drivePath: "Again/C0001.MP4"))
    #expect(try laterVisit(card, drive).weak == false)
}

// The review's A-09: reads were compared with each other and never with the listing, so two equal short reads passed.
@Test func twoEqualShortFilesAreNotAWholeFile() throws {
    let card = temp(), drive = temp()
    let d = rnd(2_000_000)
    put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
    let read = CardReader.read(root: card, kind: kind)
    for path in [card + "/C0001.MP4", drive + "/S/C0001.MP4"] {
        let h = FileHandle(forUpdatingAtPath: path)!
        try h.truncate(atOffset: 500_000); try h.close()
    }
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                 ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: false) { _, _ in }
    if case .failed? = r.states["C0001.MP4"] {} else { Issue.record("two short files aren't a whole file") }
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    if case .verified? = out.states["C0001.MP4"] { Issue.record("a short file passed") }
}

@Test func aProofThatReadFewerBytesThanListedIsNoProof() throws {
    let (_, drive, read, _, out) = try provedCard()
    let fewer = FileState.verified(drivePath: "S/C0001.MP4", hash: "0", bytes: 1)
    var short = out.proofs
    short["C0001.MP4"]?.state = fewer       // the state agrees, the file hasn't changed, and only the count can tell
    #expect(Pipeline.conclude(read: read, states: ["C0001.MP4": fewer], proved: short, issues: [], driveRoot: drive, kind: kind).verdict != .safe)
}

// The review's A-10: any `.ingest-*.part` under a destination was deleted, including real card files.
@Test func aRealFileNamedLikeATempIsNeverSwept() throws {
    let card = temp(), drive = temp()
    put(card + "/.ingest-client.part", rnd(1_000_000))
    var read = CardReader.read(root: card, kind: kind)
    let first = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    put(drive + "/S/.ingest-theirs.part", rnd(100))      // someone else's, never on the card
    put(card + "/new.bin", rnd(1000))
    read = CardReader.read(root: card, kind: kind)
    let job = Pipeline.makeJob(read: read, states: first.states, proved: first.proofs, cardName: "T", driveRoot: drive, camera: nil,
                               destination: Destination(footageRoot: "S"), probe: ProbeResult(hasVideo: true), index: nil)
    #expect(job.items.map(\.file.relPath) == ["new.bin"])
    _ = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: drive + "/S/.ingest-client.part"))
    #expect(fm.fileExists(atPath: drive + "/S/.ingest-theirs.part"))
}

@Test func aDeadJobsTempIsSweptAndALiveJobsIsNot() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let live = try ledger.open(LedgerHeader(job: "LIVE", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    defer { live.close() }
    let temps = drive + "/.ingest/tmp/"
    put(temps + "LIVE.0.part", rnd(100)); put(temps + "DEAD.0.part", rnd(100))
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: temps + "LIVE.0.part"))
    #expect(!fm.fileExists(atPath: temps + "DEAD.0.part"))
}

// The review's M04 and M08: a listing that fails part way through has to say so, and the card has to use the walker that does.
@Test func aListingThatFailsPartWayIsReported() {
    let card = temp()
    for i in 0..<6 { put(card + "/CLIP/\(i).MP4", rnd(100)) }
    let l = withFaults(badDir: card + "/CLIP") { listCard(root: card, kind: kind) }
    #expect(l.errors.contains { $0.path == "CLIP" }, "\(l.errors)")
    #expect(l.files.count < 6)
    #expect(Verdict.evaluate(listing: l, unreadable: [], states: [:], issues: [], cardUnchanged: true) != .safe)
}

// The review's C08: a device can log a CRC error during the full read, after the card's first look.
@Test func anErrorTheDeviceLogsDuringTheCopyIsInTheVerdict() throws {
    let card = temp(), drive = temp(), log = temp() + "/codex.log"
    put(log, Data("all well\n".utf8))
    put(card + "/.codexvfs", Data(#"{"volume_label":"A001","log_file":"\#(log)"}"#.utf8))
    put(card + "/A001/clip.mxf", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let before = CardProber.probe(root: URL(fileURLWithPath: card), files: read.listing.files, focus: nil)
    #expect(!before.issues.contains { $0.severity == .blocker }, "the card looks clean to start with")
    let ledger = Ledger(driveRoot: drive)
    let hooks = FaultHooks(afterCopy: { _, _, _ in
        let h = FileHandle(forUpdatingAtPath: log)!
        _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("CRC ERROR: A001/clip.mxf\n".utf8)); try? h.close()
    })
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl(), hooks: hooks) { _ in }
    let issues = Pipeline.settle(issues: before.issues, states: out.states, weak: false, driveRoot: drive, ledger: ledger)
    let end = Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: issues, driveRoot: drive, kind: kind)
    if case .notSafe = end.verdict {} else { Issue.record("\(end.verdict)") }
    #expect(end.issues.contains { $0.code == "codex.crc" }, "and the sheet hears about it")
}

@Test func engineRefusesASourceThatChangedSinceItWasRead() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(2_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let job = makeJob(read, drive: drive, dest: "S")
    put(card + "/C0001.MP4", rnd(2_000_000))
    let out = try IngestEngine.run(job: job, ledger: ledger, control: IngestControl()) { _ in }
    #expect(!out.failures.isEmpty)
    #expect(!fm.fileExists(atPath: drive + "/S/C0001.MP4"))
}

@Test func aCardCantBeCopiedOntoItself() {
    let job = IngestJob(cardRoot: "/Volumes/Card", cardName: "c", driveRoot: "/Volumes/Card", camera: nil, destination: "d", dirsToCreate: [], items: [])
    #expect(throws: IngestError.sameVolume) { try IngestEngine.preflight(job: job) }
}

@Test func aDriveThatIsTheCardByAnotherNameIsRefused() throws {
    let card = temp(), other = temp() + "/link"
    try fm.createSymbolicLink(atPath: other, withDestinationPath: card)
    let job = IngestJob(cardRoot: card, cardName: "c", driveRoot: other, camera: nil, destination: "d", dirsToCreate: [], items: [])
    #expect(throws: IngestError.sameVolume) { try IngestEngine.preflight(job: job) }
}

@Test func aCardsOwnHistoryIsLeftExactlyAsCopied() throws {
    let card = temp(), drive = temp()
    put(card + "/ascmhl/ascmhl_chain.xml", Data("<ascmhldirectory></ascmhldirectory>".utf8))
    put(card + "/C0001.MP4", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let job = makeJob(read, drive: drive, dest: "S")
    let out = try IngestEngine.run(job: job, ledger: ledger, control: IngestControl()) { _ in }
    #expect(try Pipeline.writeManifest(job: job, states: out.states, read: read) == false)
    #expect(fm.contentsEqual(atPath: card + "/ascmhl/ascmhl_chain.xml", andPath: drive + "/S/ascmhl/ascmhl_chain.xml"))
}

@Test func aWeakFlushIsAHoldNeverGreen() {
    let issues = Pipeline.settle(issues: [], states: [:], weak: true, driveRoot: "/x")
    #expect(issues.map(\.code) == ["drive.weak-verify"] && issues.allSatisfy { $0.severity == .hold })
}

/// One half of a striped clip, proved on the drive, with a hold for the other half.
private func stripedHalf() throws -> (card: String, drive: String, issue: CardIssue, states: [String: FileState]) {
    let card = temp(), drive = temp()
    put(card + "/a.braw", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    return (card, drive, CardIssue(severity: .hold, code: "braw.striped", message: "half", paths: ["a.braw"]), out.states)
}

// The review's A-11 and C07: the name of the other half cleared the hold, whatever had that name.
@Test func aStripedHoldClearsOnlyOnceItsPartnerIsOnTheDrive() throws {
    let (_, drive, issue, states) = try stripedHalf()
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)) == [issue])
    #expect(Pipeline.settle(issues: [issue], states: [:], weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)) == [issue])

    // The other card comes in, and its half is copied and proved beside this one.
    let other = temp()
    put(other + "/a.braw2", rnd(1_000_000))
    let read = CardReader.read(root: other, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)).isEmpty)
    // Only with the record that says so.
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive) == [issue])
}

@Test func aFolderIsNotAStripedPartner() throws {
    let (_, drive, issue, states) = try stripedHalf()
    try fm.createDirectory(atPath: drive + "/S/a.braw2", withIntermediateDirectories: true)
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)) == [issue])
}

@Test func anEmptyOrStrangeFileIsNotAStripedPartner() throws {
    let (_, drive, issue, states) = try stripedHalf()
    put(drive + "/S/a.braw2", Data())
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)) == [issue])
    put(drive + "/S/a.braw2", rnd(1_000_000))       // the right name, and nothing on record
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)) == [issue])
}

@Test func aPartnerChangedSinceItWasProvedIsNotAPartner() throws {
    let (_, drive, issue, states) = try stripedHalf()
    let other = temp()
    put(other + "/a.braw2", rnd(1_000_000))
    let read = CardReader.read(root: other, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    put(drive + "/S/a.braw2", rnd(1_000_000))       // same size, other bytes
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive, ledger: Ledger(driveRoot: drive)) == [issue])
}

@Test func bothHalvesProvedTogetherClearTheHold() throws {
    let card = temp(), drive = temp()
    put(card + "/a.braw", rnd(1000)); put(card + "/a.braw2", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    let issue = CardIssue(severity: .hold, code: "braw.striped", message: "half", paths: ["a.braw", "a.braw2"])
    #expect(Pipeline.settle(issues: [issue], states: out.states, weak: false, driveRoot: drive).isEmpty)
}

@Test func aSecondHalfJoinsItsPartnersFolder() {
    let card = temp()
    put(card + "/a.braw2", rnd(10))
    let read = CardReader.read(root: card, kind: kind)
    let probe = ProbeResult(issues: [CardIssue(severity: .hold, code: "braw.striped", message: "x", paths: ["a.braw2"])], hasVideo: true)
    func path(_ entries: [DriveEntry]) -> String? {
        Pipeline.makeJob(read: read, states: [:], cardName: "x", driveRoot: "/x", camera: nil, destination: Destination(footageRoot: "New"),
                         probe: probe, index: DriveIndex(entries: entries)).items.first?.drivePath
    }
    #expect(path([DriveEntry(path: "Old/A/a.braw", isDir: false, size: 10, mtime: 0)]) == "Old/A/a.braw2")
    #expect(path([DriveEntry(path: "Old/A/a.braw", isDir: false, size: 10, mtime: 0), DriveEntry(path: "Old/B/a.braw", isDir: false, size: 10, mtime: 0)]) == "New/a.braw2",
            "two takes of that name, and nothing to say which is the partner")
}

@Test func aFileThatWontOpenIsUnreadableNotSkipped() {
    let card = temp()
    put(card + "/A.MP4", rnd(1000)); put(card + "/B.MP4", rnd(1000))
    chmod(card + "/B.MP4", 0)
    defer { chmod(card + "/B.MP4", 0o644) }
    let read = CardReader.read(root: card, kind: kind)
    #expect(read.unreadable.map(\.path) == ["B.MP4"])
    #expect(read.quick.keys.sorted() == ["A.MP4"])
}

// MARK: The second round of review

/// A card with one empty file, as real Sony cards have, proved by a real job.
private func provedCardWithEmptyFile() throws -> (card: String, drive: String, read: CardRead, ledger: Ledger, out: IngestOutcome) {
    let card = temp(), drive = temp()
    put(card + "/SONY/SONYCARD.IND", Data())
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl()) { _ in }
    #expect(verdict(read, out, drive) == .safe)
    return (card, drive, read, ledger, out)
}

// Real card, intermittent: "missing=1 verified=137". exFAT makes up the ID of a file with no clusters, and changes it when
// the vnode is recycled, which a long job does by itself.
@Test func anEmptyFileHasNoIdentityToLose() throws {
    var a = ci_stamp(); a.dev = 7; a.ino = 18446744073709551576; a.size = 0; a.mtime = 315529200
    var b = a; b.ino = 18446744073709551403
    #expect(DriveStamp(a) == DriveStamp(b))
    a.size = 5; b.size = 5
    #expect(DriveStamp(a) != DriveStamp(b), "a file with bytes keeps its identity")
}

@Test func anEmptyFileThatGetsANewIDKeepsItsProof() throws {
    let (_, drive, read, _, out) = try provedCardWithEmptyFile()
    let p = drive + "/S/SONY/SONYCARD.IND"
    let keep = drive + "/S/keep"        // holds the inode, so the new file can't be given the old one
    #expect(rename(p, keep) == 0)
    put(p, Data())
    setTime(p, to: read.listing.files.first { $0.size == 0 }!)
    #expect(verdict(read, out, drive) == .safe)
}

@Test func anEmptyFileThatGainedBytesLosesItsProof() throws {
    let (_, drive, read, _, out) = try provedCardWithEmptyFile()
    put(drive + "/S/SONY/SONYCARD.IND", rnd(10))
    #expect(verdict(read, out, drive) != .safe)
}

@Test func anEmptyFileWithANewTimeLosesItsProof() throws {
    let (_, drive, read, _, out) = try provedCardWithEmptyFile()
    #expect(ci_set_times(drive + "/S/SONY/SONYCARD.IND", 1_000_000_000, 0) == 0)
    #expect(verdict(read, out, drive) != .safe)
}

private func expectAReason(_ v: CardVerdict, naming rel: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .notSafe(_, _, let why) = v else { Issue.record("expected not safe: \(v)", sourceLocation: sourceLocation); return }
    #expect(!why.isEmpty && why.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasSuffix(": ") }, "\(why)", sourceLocation: sourceLocation)
    if let rel { #expect(why.contains { $0.hasPrefix(rel + ": ") }, "\(why)", sourceLocation: sourceLocation) }
}

// A run ended NOT SAFE 1/138 with nothing to read. Every way a file can stay unproved has to say so.
@Test(arguments: [FileState.missing, .likely(drivePath: "a"), .failed("it broke"), .failed(""), .failed("  ")])
func notSafeNeverComesWithoutAReason(_ state: FileState) {
    let f = CardFile(relPath: "CLIP/C0001.MP4", size: 10, mtime: 0, kind: .video)
    let listing = CardListing(root: "/x", files: [f], dirs: [], errors: [])
    let v = Verdict.evaluate(listing: listing, unreadable: [], states: [f.relPath: state], issues: [], cardUnchanged: true)
    if case .failed(let why) = state, why.trimmingCharacters(in: .whitespaces).isEmpty {
        guard case .notSafe(_, _, let reasons) = v else { Issue.record("\(v)"); return }
        #expect(!reasons.isEmpty)
        #expect(reasons.allSatisfy { $0.hasPrefix(f.relPath + ": ") && $0.count > f.relPath.count + 3 }, "\(reasons)")
    } else { expectAReason(v, naming: f.relPath) }
}

@Test func aFileWithNoStateAtAllStillGetsAReason() {
    let f = CardFile(relPath: "C0001.MP4", size: 10, mtime: 0, kind: .video)
    expectAReason(Verdict.evaluate(listing: CardListing(root: "/x", files: [f], dirs: [], errors: []), unreadable: [], states: [:], issues: [], cardUnchanged: true), naming: f.relPath)
}

@Test func everyWayOfLosingAProofSaysWhich() throws {
    var (_, drive, read, ledger, out) = try provedCard()
    func why() -> [String] {
        let end = Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive, kind: kind)
        expectAReason(end.verdict, naming: "C0001.MP4")
        if case .notSafe(_, _, let w) = end.verdict { return w }
        return []
    }
    editMiddle(drive + "/S/C0001.MP4")
    #expect(why().contains("C0001.MP4: it changed on the drive after it was proved"))
    try fm.removeItem(atPath: drive + "/S/C0001.MP4")
    #expect(why().contains("C0001.MP4: it's no longer on the drive"))
    ledger.mount?.retire()
    #expect(why().contains("C0001.MP4: the drive was unplugged after this file was proved"))
    (_, drive, read, ledger, out) = try provedCard()
    read.mount?.retire()
    #expect(why().contains("C0001.MP4: the card came out after this file was proved"))
    (_, drive, read, ledger, out) = try provedCard()
    out.proofs = [:]
    expectAReason(Pipeline.conclude(read: read, states: out.states, proved: [:], issues: [], driveRoot: drive, kind: kind).verdict, naming: "C0001.MP4")
}

// The review's A2: a crash between reserving a name and the rename left an empty file there, and that blocked the card for good.
@Test func aReservationACrashLeftBehindIsCleared() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let dead = Ledger(driveRoot: drive)
    let journal = try dead.open(LedgerHeader(job: "DEAD", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    journal.note(.reserve, "S/C0001.MP4")
    journal.close()
    put(drive + "/S/C0001.MP4", Data())

    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(out.failures.isEmpty, "\(out.states)")
    #expect(verdict(read, out, drive) == .safe)
}

@Test func anEmptyFileSomeoneElseMadeKeepsItsNameAndSaysSo() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    put(drive + "/S/C0001.MP4", Data())
    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(out.states["C0001.MP4"] == .failed("an empty file already has that name on the drive"))
    #expect(fm.fileExists(atPath: drive + "/S/C0001.MP4"))
}

@Test func aReservationGivenBackIsNeverSwept() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    let first = Ledger(driveRoot: drive)
    let journal = try first.open(LedgerHeader(job: "GONE", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    journal.note(.reserve, "S/theirs.bin")
    journal.note(.release, "S/theirs.bin")
    journal.close()
    put(drive + "/S/theirs.bin", Data())
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: drive + "/S/theirs.bin"), "someone else got to that name first, so it was never the app's")
}

@Test func aProvedEmptyFileIsNeverTakenForAReservation() throws {
    let (card, drive, _, _, _) = try provedCardWithEmptyFile()
    let dead = Ledger(driveRoot: drive)
    let journal = try dead.open(LedgerHeader(job: "OLD", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    journal.note(.reserve, "S/SONY/SONYCARD.IND")
    journal.close()
    put(card + "/NEW.MP4", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "T"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: drive + "/S/SONY/SONYCARD.IND"))
}

// The review's A4: the bytes were only asked about for a path with no record, so a strong record elsewhere hid a weak copy.
@Test func aWeakCopyMovedOntoAStrongNameStaysWeak() throws {
    let card = temp(), other = temp(), drive = temp()
    put(card + "/a.bin", rnd(1_000_000))
    put(other + "/a.bin", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "W"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    let strong = CardReader.read(root: other, kind: kind)
    _ = try IngestEngine.run(job: makeJob(strong, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    try fm.removeItem(atPath: drive + "/S/a.bin")
    try fm.moveItem(atPath: drive + "/W/a.bin", toPath: drive + "/S/a.bin")
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/a.bin", read.quick["a.bin"]!)],
                                 ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
    #expect(r.weak)
}

@Test func aStrongCopyAtItsOwnRecordStaysStrong() throws {
    let card = temp(), drive = temp()
    put(card + "/a.bin", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "W"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/a.bin", read.quick["a.bin"]!)],
                                 ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl()) { _, _ in }
    #expect(!r.weak)
}

// The reviews' N01 and A13: A-06 again. A drive that stops taking writes can't be told from one that was pulled, so a job
// is only strong once it's sealed, and nothing has to reach the drive for it to stay weak.
@Test func aDriveThatStopsTakingWritesBeforeTheEndLeavesTheJobWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let dying = Flag()
    let hooks = FaultHooks(afterCopy: { _, _, _ in }, syncVolume: { _ in dying.on = true; return 1 }, journalFails: { dying.on })
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: hooks) { _ in }
    #expect(out.weakVerification)
    #expect(try laterVisit(card, drive).weak)
}

private func jobCutOff(_ drive: String, sealed: Bool, job: String = "CUT") throws -> LedgerEntry {
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: job, started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    try journal.begin()
    let e = LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil)
    try journal.record(e)
    if sealed { #expect(journal.seal([e], flushVolume: { 0 })) }
    journal.close()
    return e
}

@Test func aJobCutOffBeforeItsSealIsWeak() throws {
    let drive = temp()
    _ = try jobCutOff(drive, sealed: false)
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/a"))
}

@Test func aJobTheDriveConfirmedStaysStrongOnALaterVisit() throws {
    let drive = temp()
    _ = try jobCutOff(drive, sealed: true)
    #expect(!Ledger(driveRoot: drive).isWeak(drivePath: "S/a"))
}

@Test func aRecordFromBeforeTheMarksIsNotCalledWeak() throws {
    let drive = temp()
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: "OLD", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    try journal.record(LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil))
    journal.close()
    #expect(!Ledger(driveRoot: drive).isWeak(drivePath: "S/a"))
}

@Test func aJobStillRunningIsNotCalledWeak() throws {
    let drive = temp()
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: "LIVE", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    defer { journal.close() }
    try journal.begin()
    try journal.record(LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil))
    #expect(!Ledger(driveRoot: drive).isWeak(drivePath: "S/a"))
}

// The reviews' N02 and A12: inside `seal`, `sync` was the volume flush, so the job asked three times and heard the last.
@Test func theFirstRefusalOfTheVolumeFlushCounts() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    let calls = Counter()
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in calls.next() == 1 ? 1 : 0 })) { _ in }
    #expect(out.weakVerification)
    #expect(calls.value == 1)
}

// The review's A8: a copy made a moment ago can go green while it's still only in a cache.
@Test func aCheckAsksTheDriveToFlushFirst() throws {
    let card = temp(), drive = temp()
    let d = rnd(1000)
    put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
    let read = CardReader.read(root: card, kind: kind)
    func check(record: Bool, flush: Int32) -> (weak: Bool, calls: Int) {
        let calls = Counter()
        let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick["C0001.MP4"]!)],
                                     ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: record,
                                     hooks: FaultHooks(syncVolume: { _ in _ = calls.next(); return flush })) { _, _ in }
        return (r.weak, calls.value)
    }
    #expect(check(record: false, flush: 1) == (false, 0), "a check that promises to change nothing changes nothing")
    #expect(check(record: true, flush: 0) == (false, 1))
    #expect(check(record: true, flush: 1) == (true, 1))
}

// The review's A9: rule 14 says empty folders survive, and only a job made them.
@Test func aCardsEmptyFolderHasToBeOnTheDrive() throws {
    let card = temp(), drive = temp()
    let d = rnd(1000)
    put(card + "/CONTENTS/CLIP/C0001.MP4", d)
    try fm.createDirectory(atPath: card + "/CONTENTS/ICON", withIntermediateDirectories: true)
    put(drive + "/Sorted/CONTENTS/CLIP/C0001.MP4", d)
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "Sorted/CONTENTS/CLIP/C0001.MP4", read.quick["CONTENTS/CLIP/C0001.MP4"]!)],
                                 ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    func verdictNow() -> CardVerdict { Pipeline.conclude(read: read, states: r.states, proved: r.proofs, issues: [], driveRoot: drive, kind: kind).verdict }
    guard case .hold(let issues) = verdictNow() else { Issue.record("\(verdictNow())"); return }
    #expect(issues.map(\.code) == ["card.empty-folders"])
    try fm.createDirectory(atPath: drive + "/Sorted/CONTENTS/ICON", withIntermediateDirectories: true)
    #expect(verdictNow() == .safe)
}

@Test func aJobMakesTheEmptyFoldersWhereTheFilesGo() throws {
    let card = temp(), drive = temp()
    put(card + "/DCIM/a.ARW", rnd(1000))
    try fm.createDirectory(atPath: card + "/DCIM/EMPTY", withIntermediateDirectories: true)
    let read = CardReader.read(root: card) { _ in .still }
    let job = Pipeline.makeJob(read: read, states: [:], cardName: "T", driveRoot: drive, camera: nil,
                               destination: Destination(footageRoot: "F", stillsRoot: "P"), probe: ProbeResult(hasStills: true), index: nil)
    let out = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    let end = Pipeline.conclude(read: read, states: out.states, proved: out.proofs, issues: [], driveRoot: drive) { _ in .still }
    #expect(end.verdict == .safe, "\(end.verdict)")
    #expect(fm.fileExists(atPath: drive + "/P/DCIM/EMPTY"))
}
