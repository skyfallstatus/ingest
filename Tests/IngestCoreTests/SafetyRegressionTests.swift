import CIngest
import Foundation
import Testing
@testable import IngestCore

// Each test here is an attack from the independent safety review that once produced a false "Safe to format".

private let fm = FileManager.default

/// What a fault hook saw, from the engine's thread.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func add(_ v: Int) { lock.lock(); values.append(v); lock.unlock() }
    func has(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(v) }
    func countOf(_ v: Int) -> Int { lock.lock(); defer { lock.unlock() }; return values.filter { $0 == v }.count }
}

/// A count a fault hook can keep from the engine's thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
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

// A character count was taken in bytes, so a name beyond ASCII cut the folder short.
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

// The listing compared names and sizes, so a changed file with a changed time passed the last look.
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

// A retained proof never looked at the destination, so changed bytes kept Safe.
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

// Proofs made on one drive were carried to another by a resumed job.
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

// A replacement at the same path kept the old verdict. The same drive read through a
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

// The destination folder swapped for a link to the card, so the card was read twice.
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

// A saved setup could hold `..`, and the engine would follow it off the drive.
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

// Only the drive's cache was asked about, so a card read from the Mac's cache could count as proof.
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

// As the owner decided on 2026-11-02. A drive that said no is weak for good, and that has to be on the
// drive. One that stopped answering looks like a pulled cable, so it's finished the way anything is: a confirmed flush, then a
// full read. If the refusal itself couldn't be written, that's the case below, and SAFETY.md says so.
@Test func aRefusalThatCantBeWrittenEndsLikeACutOffJob() throws {
    let (card, drive, read) = try cutOffCopy(flush: 1)
    #expect(check(card, drive, read, flush: nil).weak, "a look holds")
    #expect(check(card, drive, read, flush: 1).weak, "a refused flush holds")
    // Which itself is on the record now, and that's for good. So this test takes a fresh copy for the last step.
    let (card2, drive2, read2) = try cutOffCopy(flush: 1)
    let later = check(card2, drive2, read2, flush: 0)
    #expect(!later.weak, "a confirmed flush and a full read finish it: this is the risk SAFETY.md states")
    #expect(end(read2, later, drive2) == .safe)
}

@Test func aJobTheDriveConfirmedIsNotWeak() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(try laterVisit(card, drive).weak == false)
}

@Test func aSealThatCantBeWrittenLeavesTheJobUnfinished() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let ledger = Ledger(driveRoot: drive)
    #expect(!ledger.isWeak(drivePath: "S/C0001.MP4"), "the drive said yes, so it isn't weak")
    #expect(!unfinished(ledger, read, "S/C0001.MP4").isEmpty, "and it isn't finished")
    #expect(!check(card, drive, read, flush: 0).weak)
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

// Weak was remembered by path, so a rename cleared it.
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
    let ledger = Ledger(driveRoot: drive)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "Again"), ledger: ledger, control: IngestControl()) { _ in }
    #expect(!Ledger(driveRoot: drive).isWeak(drivePath: "Again/C0001.MP4"))
    // And that's the copy a later visit finds, so a card on hold has a way back to green. Here the weak record is the
    // older one in this ledger, and journals load in no set order, so it has to be chosen, not lucky.
    let weakFirst = Ledger(driveRoot: drive)
    #expect(CardMatcher.match(read: read, ledger: weakFirst, index: nil, driveRoot: drive)["C0001.MP4"] == .likely(drivePath: "Again/C0001.MP4"))
    #expect(CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)["C0001.MP4"] == .likely(drivePath: "Again/C0001.MP4"))
    #expect(try laterVisit(card, drive).weak == false)
}

@Test func theOldestRecordInALedgerIsNotAlwaysTheOneToFollow() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "Weak"), ledger: ledger, control: IngestControl(), hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "Good"), ledger: ledger, control: IngestControl()) { _ in }
    #expect(CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)["C0001.MP4"] == .likely(drivePath: "Good/C0001.MP4"))
}

// Reads were compared with each other and never with the listing, so two equal short reads passed.
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

// Any `.ingest-*.part` under a destination was deleted, including real card files.
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

// A listing that fails part way through has to say so, and the card has to use the walker that does.
@Test func aListingThatFailsPartWayIsReported() {
    let card = temp()
    for i in 0..<6 { put(card + "/CLIP/\(i).MP4", rnd(100)) }
    let l = withFaults(badDir: card + "/CLIP") { listCard(root: card, kind: kind) }
    #expect(l.errors.contains { $0.path == "CLIP" }, "\(l.errors)")
    #expect(l.files.count < 6)
    #expect(Verdict.evaluate(listing: l, unreadable: [], states: [:], issues: [], cardUnchanged: true) != .safe)
}

// A device can log a CRC error during the full read, after the card's first look.
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

// The name of the other half cleared the hold, whatever had that name.
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

// A crash between reserving a name and the rename left an empty file there, and that blocked the card for good.
@Test func aReservationACrashLeftBehindIsCleared() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let dead = Ledger(driveRoot: drive)
    let journal = try dead.open(LedgerHeader(job: "DEAD", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    journal.intend(["S/C0001.MP4"])
    journal.close()
    put(drive + "/S/C0001.MP4", Data())

    let read = CardReader.read(root: card, kind: kind)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(out.failures.isEmpty, "\(out.states)")
    #expect(verdict(read, out, drive) == .safe)
}

// A forced detach on real exFAT: 1 round in 10 kept an empty reservation and lost the note written just before it, and the
// card stopped at "an empty file already has that name". So the names go down once, flushed, before any of them is taken.
@Test func aJobPutsTheNamesItMayTakeOnTheDriveBeforeItTakesAny() throws {
    let card = temp(), drive = temp()
    put(card + "/a.bin", rnd(1000)); put(card + "/b.bin", rnd(1000))
    put(drive + "/S/b.bin", Data())                     // already there, so never the app's to claim
    let read = CardReader.read(root: card, kind: kind)
    let seen = Calls()
    let saved = Flag()
    let writes = Calls()
    let hooks = FaultHooks(afterCopy: { _, _, _ in
        writes.add(seen.countOf(2))
        let folder = drive + "/.ingest/ledger/"
        let text = (try? fm.contentsOfDirectory(atPath: folder))?.compactMap { try? String(contentsOfFile: folder + $0, encoding: .utf8) }.joined() ?? ""
        if text.contains("\"reserve\":\"S\\/a.bin\"") { saved.on = true }
        if text.contains("\"reserve\":\"S\\/b.bin\"") { seen.add(1) }
    }, journalFails: { seen.add(2); return false })
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: hooks) { _ in }
    #expect(saved.on, "the name was on the record before the file had it")
    #expect(!seen.has(1), "and a name that was taken already isn't claimed")
    #expect(writes.has(2), "one name and its flush, before the first file was done")
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

// Whatever a dead job meant to do with that name, a file with bytes in it isn't a reservation, and it isn't the app's to remove.
@Test func aFileWithBytesAtAnAbandonedReservationIsLeftAlone() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    let dead = Ledger(driveRoot: drive)
    let journal = try dead.open(LedgerHeader(job: "DEAD", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    journal.intend(["S/theirs.bin"])
    journal.close()
    let theirs = rnd(500)
    put(drive + "/S/theirs.bin", theirs)
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.contents(atPath: drive + "/S/theirs.bin") == theirs)
}

@Test func aReservationGivenBackIsNeverSwept() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    let first = Ledger(driveRoot: drive)
    let journal = try first.open(LedgerHeader(job: "GONE", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    journal.intend(["S/theirs.bin"])
    journal.release("S/theirs.bin")
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
    journal.intend(["S/SONY/SONYCARD.IND"])
    journal.close()
    put(card + "/NEW.MP4", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "T"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: drive + "/S/SONY/SONYCARD.IND"))
}

// The bytes were only asked about for a path with no record, so a strong record elsewhere hid a weak copy.
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

// As the owner decided it. What a sealed job has is a confirmed flush and then a read, so that's what finishes a job that
// was cut off, by a pulled cable or a crash. A real job on real files, stopped short of its seal.
private func cutOffCopy(flush: Int32) throws -> (card: String, drive: String, read: CardRead) {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let dying = Flag()
    let hooks = FaultHooks(syncVolume: { _ in dying.on = true; return flush }, journalFails: { dying.on })
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: hooks) { _ in }
    #expect(out.weakVerification, "it can't say Safe this session")
    #expect(try !ledgerText(drive).contains("sealed") && !ledgerText(drive).contains("refused"))
    return (card, drive, read)
}

private func ledgerText(_ drive: String) throws -> String {
    let folder = drive + "/.ingest/ledger/"
    return try fm.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".jsonl") }.map { try String(contentsOfFile: folder + $0, encoding: .utf8) }.joined()
}

private func unfinished(_ ledger: Ledger, _ read: CardRead, _ path: String) -> [String] {
    let hash = ci_hash_uncached(read.listing.root + "/" + read.listing.files[0].relPath, nil, nil, nil)
    return ledger.unfinishedJobs(drivePath: path, bytes: hash.bytes, hash: hexHash(hash.hash))
}

/// Reads the card's one file against its copy. `flush` nil is a look, which changes nothing. Otherwise that's the drive's answer.
private func check(_ card: String, _ drive: String, _ read: CardRead, at path: String = "S/C0001.MP4", flush: Int32?, hooks more: FaultHooks = FaultHooks())
    -> (states: [String: FileState], proofs: [String: Proof], weak: Bool) {
    var hooks = more
    if let flush, hooks.syncVolume == nil { hooks.syncVolume = { _ in flush } }
    return IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], path, read.quick[read.listing.files[0].relPath]!)],
                                ledger: Ledger(driveRoot: drive), jobName: "x", control: IngestControl(), record: flush != nil, hooks: hooks) { _, _ in }
}

private func end(_ read: CardRead, _ r: (states: [String: FileState], proofs: [String: Proof], weak: Bool), _ drive: String) -> CardVerdict {
    let issues = Pipeline.settle(issues: [], states: r.states, weak: r.weak, driveRoot: drive)
    return Pipeline.conclude(read: read, states: r.states, proved: r.proofs, issues: issues, driveRoot: drive, kind: kind).verdict
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

@Test func aJobCutOffBeforeItsSealIsUnfinishedNotWeak() throws {
    let drive = temp()
    let e = try jobCutOff(drive, sealed: false)
    let ledger = Ledger(driveRoot: drive)
    #expect(!ledger.isWeak(drivePath: "S/a"))
    #expect(ledger.unfinishedJobs(drivePath: "S/a", bytes: e.size, hash: e.hash) == ["CUT"])
}

@Test func aJobTheDriveConfirmedStaysStrongOnALaterVisit() throws {
    let drive = temp()
    let e = try jobCutOff(drive, sealed: true)
    let later = Ledger(driveRoot: drive)
    #expect(!later.isWeak(drivePath: "S/a"))
    #expect(later.unfinishedJobs(drivePath: "S/a", bytes: e.size, hash: e.hash).isEmpty)
}

@Test func aRecordFromBeforeTheMarksIsNeitherWeakNorUnfinished() throws {
    let drive = temp()
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: "OLD", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    let e = LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil)
    try journal.record(e)
    journal.close()
    let later = Ledger(driveRoot: drive)
    #expect(!later.isWeak(drivePath: "S/a"))
    #expect(later.unfinishedJobs(drivePath: "S/a", bytes: 1, hash: "1").isEmpty)
}

@Test func aJobStillRunningIsNeitherWeakNorUnfinished() throws {
    let drive = temp()
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: "LIVE", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    defer { journal.close() }
    try journal.begin()
    try journal.record(LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil))
    let other = Ledger(driveRoot: drive)
    #expect(!other.isWeak(drivePath: "S/a"))
    #expect(other.unfinishedJobs(drivePath: "S/a", bytes: 1, hash: "1").isEmpty)
    #expect(other.hasRunningJob)
}

@Test func aSealThatCouldntBeWrittenIsUnfinishedOnThisMountToo() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    let dying = Flag()
    let same = Ledger(driveRoot: drive)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: same, control: IngestControl(),
                             hooks: FaultHooks(syncVolume: { _ in dying.on = true; return 0 }, journalFails: { dying.on })) { _ in }
    #expect(!same.isWeak(drivePath: "S/C0001.MP4"), "the drive said yes")
    #expect(!unfinished(same, read, "S/C0001.MP4").isEmpty)
}

@Test func aLookWithNoFlushStillHolds() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let before = try ledgerText(drive)
    let look = check(card, drive, read, flush: nil)
    if case .verified? = look.states["C0001.MP4"] {} else { Issue.record("the bytes are still proved") }
    #expect(look.weak)
    guard case .hold = end(read, look, drive) else { Issue.record("\(end(read, look, drive))"); return }
    #expect(try ledgerText(drive) == before, "and a look writes nothing")
    #expect(!unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
}

@Test func aConfirmedFlushThenAFullReadFinishesIt() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let r = check(card, drive, read, flush: 0)
    #expect(!r.weak)
    #expect(end(read, r, drive) == .safe)
}

@Test func whatFinishedItStaysFinished() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    _ = check(card, drive, read, flush: 0)
    #expect(try ledgerText(drive).contains("\"closes\""), "it's on the record")
    let later = Ledger(driveRoot: drive)
    #expect(unfinished(later, read, "S/C0001.MP4").isEmpty)
    #expect(!check(card, drive, read, flush: nil).weak, "a later look needs no flush of its own")
    #expect(check(card, drive, read, flush: 1).weak, "and a later refusal is still a refusal")
}

@Test func aRefusedFlushStillHoldsAndFinishesNothing() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    #expect(check(card, drive, read, flush: 1).weak)
    #expect(try !ledgerText(drive).contains("\"closes\""))
}

@Test func aDriveThatSaidNoStaysWeakForGood() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(), hooks: FaultHooks(syncVolume: { _ in 1 })) { _ in }
    #expect(try ledgerText(drive).contains("\"refused\""))
    for _ in 0..<2 {
        let r = check(card, drive, read, flush: 0)
        #expect(r.weak, "a confirmed flush later doesn't undo a no")
        guard case .hold = end(read, r, drive) else { Issue.record("\(end(read, r, drive))"); return }
    }
}

// The order is the point: bytes read before the drive confirmed anything aren't what it confirmed.
@Test func theFlushComesBeforeTheRead() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let copy = drive + "/S/C0001.MP4"
    let good = try #require(fm.contents(atPath: copy))
    let r = check(card, drive, read, flush: 0, hooks: FaultHooks(syncVolume: { _ in
        var bad = good; bad[500_000] ^= 0xFF
        try? bad.write(to: URL(fileURLWithPath: copy))       // what the drive turns out to have, once it's asked to finish
        return 0
    }))
    if case .failed? = r.states["C0001.MP4"] {} else { Issue.record("a read taken before the flush would have passed this: \(String(describing: r.states["C0001.MP4"]))") }
}

// The prototype cleared on any clean check at all, so a check from before the job could finish it.
@Test func aCheckFromBeforeTheCutOffFinishesNothing() throws {
    let card = temp(), drive = temp()
    let d = rnd(1_000_000)
    put(card + "/C0001.MP4", d); put(drive + "/S/C0001.MP4", d)
    let read = CardReader.read(root: card, kind: kind)
    _ = check(card, drive, read, flush: 0)                       // a clean check, on the record
    try fm.removeItem(atPath: drive + "/S/C0001.MP4")
    let dying = Flag()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                             hooks: FaultHooks(syncVolume: { _ in dying.on = true; return 0 }, journalFails: { dying.on })) { _ in }
    #expect(!unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
    #expect(check(card, drive, read, flush: nil).weak)
}

@Test func aCutOffCopyIsStillUnfinishedUnderANewName() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    try fm.moveItem(atPath: drive + "/S", toPath: drive + "/Renamed")
    #expect(check(card, drive, read, at: "Renamed/C0001.MP4", flush: nil).weak)
}

@Test func aSealedCopyOfTheSameBytesIsNotHeldBack() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "Again"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(unfinished(Ledger(driveRoot: drive), read, "Again/C0001.MP4").isEmpty, "that copy finished by itself")
    #expect(!check(card, drive, read, at: "Again/C0001.MP4", flush: nil).weak)
}

@Test func aCloseThatCantBeWrittenClosesNothing() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let r = check(card, drive, read, flush: 0, hooks: FaultHooks(journalFails: { true }))
    #expect(r.weak, "nothing on the record, so nothing changed")
    #expect(!unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
}

// Resume and Copy Again can meet the file in the job itself, which has to ask for the flush first too.
@Test func aJobThatMeetsAnUnfinishedFileFinishesItTheSameWay() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    let order = Calls()
    let copy = drive + "/S/C0001.MP4"
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in order.add(fm.contents(atPath: copy)?.count ?? 0); return 0 })) { _ in }
    #expect(order.count == 2, "once before it reads, and once to seal")
    #expect(!out.weakVerification)
    #expect(try ledgerText(drive).contains("\"closes\""))
    #expect(unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
}

@Test func aJobThatMeetsAnUnfinishedFileOnARefusingDriveHolds() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    let calls = Counter()     // refused before the read, and confirmed at the seal, so only the first can hold it
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in calls.next() == 1 ? 1 : 0 })) { _ in }
    #expect(calls.value == 2)
    #expect(out.weakVerification)
    #expect(try !ledgerText(drive).contains("\"closes\""))
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/C0001.MP4"), "a no is on the record, here as in a check")
}

@Test func aFinishedFileStaysFinishedIfItsOwnJobIsCutOffLater() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    let dying = Flag()
    let calls = Counter()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                             hooks: FaultHooks(syncVolume: { _ in if calls.next() == 2 { dying.on = true }; return 0 }, journalFails: { dying.on })) { _ in }
    #expect(try !ledgerText(drive).contains("\"sealed\""), "the second job didn't reach its seal")
    #expect(unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty, "but it had already done what the first one needed")
}

/// What a pull can leave: the job listed the name and the file has it, but the record of the file never reached the drive.
private func recordLost(_ card: String, _ drive: String) throws {
    let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "CUT", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    try journal.begin()
    journal.intend(["S/C0001.MP4"])
    journal.close()
    put(drive + "/S/C0001.MP4", fm.contents(atPath: card + "/C0001.MP4")!)
}

private func oneFileCard() -> (card: String, drive: String, read: CardRead) {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    return (card, drive, CardReader.read(root: card, kind: kind))
}

private func rewriteJournals(_ drive: String, _ change: (String) -> String) throws {
    let folder = drive + "/.ingest/ledger/"
    for n in try fm.contentsOfDirectory(atPath: folder) where n.hasSuffix(".jsonl") {
        try change(String(contentsOfFile: folder + n, encoding: .utf8)).write(toFile: folder + n, atomically: false, encoding: .utf8)
    }
}

/// What an older build wrote: its `opened` line says nothing about a refusal, and it left a refusal no mark.
private func writtenByAnOlderBuild(_ drive: String) throws {
    try rewriteJournals(drive) { $0.replacingOccurrences(of: #"{"mark":"opened","refusals":true}"#, with: #"{"mark":"opened"}"#) }
}

@Test func aCopyWhoseRecordWasLostWaitsForAFlushLikeAnyOther() throws {
    let (card, drive, read) = oneFileCard()
    try recordLost(card, drive)
    #expect(unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4") == ["CUT"])
    guard case .hold = end(read, check(card, drive, read, flush: nil), drive) else { Issue.record("a look has nothing to go on"); return }
    let r = check(card, drive, read, flush: 0)
    #expect(!r.weak)
    #expect(end(read, r, drive) == .safe)
    #expect(!check(card, drive, read, flush: nil).weak, "and it stays finished")
}

@Test func aCopyWhoseRecordWasLostHoldsOnARefusedFlush() throws {
    let (card, drive, read) = oneFileCard()
    try recordLost(card, drive)
    guard case .hold = end(read, check(card, drive, read, flush: 1), drive) else { Issue.record("a refusal finishes nothing"); return }
    guard case .hold = end(read, check(card, drive, read, flush: 0), drive) else { Issue.record("and it's a refusal for good"); return }
}

@Test func aNameACutOffJobListedIsFreeOnceAJobThatSealedHasFilledIt() throws {
    let (card, drive, read) = oneFileCard()
    let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "CUT", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    try journal.begin()
    journal.intend(["S/C0001.MP4"])
    journal.close()
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(verdict(read, out, drive) == .safe)
    #expect(unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty, "a resumed job would otherwise hold on every later look")
}

@Test func aRefusedJobsFileWithNoRecordStaysWeak() throws {
    let (card, drive, read) = oneFileCard()
    let dying = Flag()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                             hooks: FaultHooks(afterCopy: { _, _, _ in dying.on = true }, syncVolume: { _ in dying.on = false; return 1 }, journalFails: { dying.on })) { _ in }
    #expect(try ledgerText(drive).contains("\"refused\"") && !ledgerText(drive).contains("\"quick\""))
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/C0001.MP4"))
    guard case .hold = end(read, check(card, drive, read, flush: 0), drive) else { Issue.record("a refusal is weak for good"); return }
}

@Test func aNewJobSaysItMarksRefusals() throws {
    let drive = temp()
    _ = try jobCutOff(drive, sealed: true)
    #expect(try ledgerText(drive).contains(#"{"mark":"opened","refusals":true}"#))
}

@Test func aJobCutOffUnderAnOlderBuildStaysWeakForGood() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    try writtenByAnOlderBuild(drive)
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/C0001.MP4"), "it might have been a refusal, and nothing can show it wasn't")
    #expect(unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty, "so there's nothing a read could finish")
    let r = check(card, drive, read, flush: 0)
    #expect(r.weak)
    guard case .hold = end(read, r, drive) else { Issue.record("a confirmed flush doesn't change it"); return }
    #expect(try !ledgerText(drive).contains("\"closes\""))
}

@Test func aNameAnOlderBuildLeftIsWeakToo() throws {
    let (card, drive, _) = oneFileCard()
    try recordLost(card, drive)
    try writtenByAnOlderBuild(drive)
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/C0001.MP4"))
}

@Test func aJobAnOlderBuildSealedIsStrong() throws {
    let drive = temp()
    let e = try jobCutOff(drive, sealed: true)
    try writtenByAnOlderBuild(drive)
    let later = Ledger(driveRoot: drive)
    #expect(!later.isWeak(drivePath: "S/a", bytes: e.size, hash: e.hash))
    #expect(later.unfinishedJobs(drivePath: "S/a", bytes: e.size, hash: e.hash).isEmpty)
}

@Test func aJobAnOlderBuildIsStillRunningIsntARefusalYet() throws {
    let drive = temp()
    let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "LIVE", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    defer { journal.close() }
    try journal.begin()
    try journal.record(LedgerEntry(cardPath: "a", drivePath: "S/a", size: 1, quick: "1", hash: "1", weak: nil))
    try writtenByAnOlderBuild(drive)
    let other = Ledger(driveRoot: drive)
    #expect(!other.isWeak(drivePath: "S/a", bytes: 1, hash: "1"), "a mark made now would stay long after it sealed")
    #expect(other.hasRunningJob)
}

// A job that ended properly left nothing behind. Its names were never taken, so whatever's at them now is someone else's.
@Test(arguments: [Int32(0), 1])
func aJobThatEndedLeavesItsUnusedNamesToAnyone(flush: Int32) throws {
    let card = temp(), drive = temp(), other = temp()
    put(card + "/a.bin", rnd(1000)); put(card + "/b.bin", rnd(1000))
    put(other + "/c.bin", rnd(1000))
    let control = IngestControl()
    let read = CardReader.read(root: card, kind: kind)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: control,
                             hooks: FaultHooks(afterCopy: { _, _, _ in control.stop() }, syncVolume: { _ in flush })) { _ in }
    #expect(try ledgerText(drive).contains("\"reserve\""), "the attack needs a name that was listed and never used")
    #expect(Ledger(driveRoot: drive).abandonedReservations().isEmpty)
    let theirs = ["a.bin", "b.bin"].map { drive + "/S/" + $0 }.first { !fm.fileExists(atPath: $0) }!
    put(theirs, Data())
    _ = try IngestEngine.run(job: makeJob(CardReader.read(root: other, kind: kind), drive: drive, dest: "T"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: theirs))
}

@Test func aLookWhileAJobIsRunningCantVouchForIt() throws {
    let (card, drive, read) = oneFileCard()
    let held = Flag()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                             hooks: FaultHooks(syncVolume: { _ in held.on = check(card, drive, read, flush: nil).weak; return 0 })) { _ in }
    #expect(held.on, "that job's seal hasn't happened, and it may yet be refused")
    #expect(!check(card, drive, read, flush: nil).weak, "and once it's sealed there's nothing to wait for")
}

@Test func aFileReplacedDuringTheFlushIsntFinished() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let path = drive + "/S/C0001.MP4", bytes = fm.contents(atPath: path)!
    let r = check(card, drive, read, flush: 0, hooks: FaultHooks(syncVolume: { _ in
        try? fm.removeItem(atPath: path); put(path, bytes); return 0     // the same bytes, in a file that flush never saw
    }))
    #expect(r.weak)
    #expect(try !ledgerText(drive).contains("\"closes\""))
    #expect(!unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
}

@Test func aMountThatWentDuringTheCheckFinishesNothing() throws {
    let (card, drive, read) = try cutOffCopy(flush: 0)
    let ledger = Ledger(driveRoot: drive)
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], "S/C0001.MP4", read.quick[read.listing.files[0].relPath]!)],
                                 ledger: ledger, jobName: "x", control: IngestControl(), record: true,
                                 hooks: FaultHooks(syncVolume: { _ in ledger.mount?.retire(); return 0 })) { _, _ in }
    #expect(r.weak)
    #expect(try !ledgerText(drive).contains("\"closes\""))
}

@Test func aJobFinishesOnlyWhatItsFlushCovered() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    let path = drive + "/S/C0001.MP4", bytes = fm.contents(atPath: path)!
    let calls = Counter()
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in
                                       if calls.next() == 1 { try? fm.removeItem(atPath: path); put(path, bytes) }
                                       return 0
                                   })) { _ in }
    #expect(out.weakVerification)
    #expect(try !ledgerText(drive).contains("\"closes\""))
}

@Test func aJobOnAMountThatWentFinishesNothing() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    let ledger = Ledger(driveRoot: drive)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in ledger.mount?.retire(); return 0 })) { _ in }
    #expect(out.weakVerification)
    #expect(try !ledgerText(drive).contains("\"closes\""))
}

@Test func anEmptyListClosesNothing() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    try rewriteJournals(drive) { $0.replacingOccurrences(of: "\"quick\"", with: "\"closes\":[],\"quick\"") }
    #expect(!unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
}

// A job has only ever had to flush when a file it meets was unfinished. Now any file it's about to read gets the same.
@Test func aJobAsksTheDriveBeforeItReadsAFileAlreadyThere() throws {
    let (_, drive, read, _, _) = try provedCard()
    let calls = Counter()     // refused before the read, and confirmed at the seal, so only the first can hold it
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(syncVolume: { _ in calls.next() == 1 ? 1 : 0 })) { _ in }
    #expect(calls.value == 2)
    #expect(out.weakVerification)
    #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/C0001.MP4"))
}

@Test func aJobThatReadsNothingOnTheDriveAsksOnce() throws {
    let (_, drive, read) = oneFileCard()
    let calls = Counter()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                             hooks: FaultHooks(syncVolume: { _ in _ = calls.next(); return 0 })) { _ in }
    #expect(calls.value == 1)
}

private func withoutPermission<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
    #expect(chmod(path, 0) == 0)
    defer { chmod(path, 0o755) }
    return try body()
}

@Test func aJournalThatWontOpenLeavesTheDriveWeak() throws {
    let drive = temp()
    _ = try jobCutOff(drive, sealed: true)
    let folder = drive + "/.ingest/ledger/"
    let name = try #require(try fm.contentsOfDirectory(atPath: folder).first)
    withoutPermission(folder + name) {
        #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/a"), "what it held might have been a refusal")
    }
    #expect(!Ledger(driveRoot: drive).isWeak(drivePath: "S/a"))
}

@Test func aLedgerFolderThatWontOpenLeavesTheDriveWeak() throws {
    let drive = temp()
    _ = try jobCutOff(drive, sealed: true)
    withoutPermission(drive + "/.ingest/ledger") { #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/a")) }
    withoutPermission(drive + "/.ingest") { #expect(Ledger(driveRoot: drive).isWeak(drivePath: "S/a"), "from one level up it looks missing") }
}

@Test func aDriveWithNoRecordYetIsNotWeak() {
    #expect(!Ledger(driveRoot: temp()).isWeak(drivePath: "S/a"))
}

@Test func aCheckOnARecordThatWontOpenHoldsOrSaysWhyNot() throws {
    let (card, drive, read) = try oneFileCardCopied()
    let folder = drive + "/.ingest/ledger/"
    let name = try #require(try fm.contentsOfDirectory(atPath: folder).first)
    try withoutPermission(folder + name) {
        guard case .hold = end(read, check(card, drive, read, flush: 0), drive) else { Issue.record("one journal unread"); return }
    }
    try withoutPermission(drive + "/.ingest/ledger") {
        let r = check(card, drive, read, flush: 0)
        #expect(r.states["C0001.MP4"] == .failed("couldn't record the check on the drive"))
    }
}

@Test func aFreshCopyOnADriveWhoseRecordWontOpenHolds() throws {
    let (_, drive, _) = try oneFileCardCopied()
    let next = temp()
    put(next + "/N.MP4", rnd(1000))
    let folder = drive + "/.ingest/ledger/"
    let name = try #require(try fm.contentsOfDirectory(atPath: folder).first)
    let read = CardReader.read(root: next, kind: kind)
    let out = try withoutPermission(folder + name) {
        try IngestEngine.run(job: makeJob(read, drive: drive, dest: "T"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    }
    #expect(out.weakVerification)
}

private func oneFileCardCopied() throws -> (card: String, drive: String, read: CardRead) {
    let (card, drive, read) = oneFileCard()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    return (card, drive, read)
}

// MARK: Whole card, one folder

/// What the app does with a card on a visit: match it, read what it can, then copy into `dest` whatever the job takes.
private func matchThenCopy(_ card: String, _ drive: String, _ dest: String, kind k: @escaping (String) -> FileKind = kind) throws
    -> (verdict: CardVerdict, job: IngestJob, states: [String: FileState], read: CardRead) {
    let read = CardReader.read(root: card, kind: k)
    let ledger = Ledger(driveRoot: drive)
    var states = CardMatcher.match(read: read, ledger: ledger, index: DriveIndex.scan(root: drive), driveRoot: drive)
    let likely: [(file: CardFile, drivePath: String, quick: String)] = read.listing.files.compactMap { f in
        guard case .likely(let p)? = states[f.relPath], let q = read.quick[f.relPath] else { return nil }
        return (f, p, q)
    }
    let checked = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: likely, ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    for (k, v) in checked.states { states[k] = v }
    var proved = checked.proofs
    let job = Pipeline.makeJob(read: read, states: states, proved: proved, cardName: "T", driveRoot: drive, camera: nil,
                               destination: Destination(footageRoot: dest), probe: ProbeResult(hasVideo: true), index: nil)
    let out = try IngestEngine.run(job: job, ledger: ledger, control: IngestControl()) { _ in }
    for (k, v) in out.states { states[k] = v }
    proved.merge(out.proofs) { _, new in new }
    let issues = Pipeline.settle(issues: [], states: states, weak: checked.weak || out.weakVerification, driveRoot: drive, ledger: ledger)
    let end = Pipeline.conclude(read: read, states: states, proved: proved, issues: issues, driveRoot: drive, kind: k)
    return (end.verdict, job, end.states, read)
}

@Test func aFileProvedElsewhereIsStillCopiedToWhereTheJobIsGoing() throws {
    let (_, drive, read, _, out) = try provedCard()
    func job(_ dest: String) -> IngestJob {
        Pipeline.makeJob(read: read, states: out.states, proved: out.proofs, cardName: "T", driveRoot: drive, camera: nil,
                         destination: Destination(footageRoot: dest), probe: ProbeResult(hasVideo: true), index: nil)
    }
    #expect(job("T").items.map(\.drivePath) == ["T/C0001.MP4"], "the job is going to T, so the card goes to T")
    #expect(job("S").items.isEmpty, "a file already at its place stays proved, and isn't copied again")
}

@Test func aSecondCardGetsItsOwnCopyOfWhatCardsShare() throws {
    let drive = temp(), a = temp(), b = temp(), marker = rnd(1_382_400)
    let rels = ["AVF_INFO/AVIN0001.BNP", "SONY/SONYCARD.IND", "M4ROOT/CLIP/C0001.MP4"]
    for c in [a, b] {
        put(c + "/" + rels[0], marker); put(c + "/" + rels[1], Data()); put(c + "/" + rels[2], rnd(2_000_000))
    }
    #expect(try matchThenCopy(a, drive, "A").verdict == .safe)
    let second = try matchThenCopy(b, drive, "B")
    #expect(second.verdict == .safe)
    for rel in rels { #expect(fm.fileExists(atPath: drive + "/B/" + rel), "\(rel)") }
    #expect(try Pipeline.writeManifest(job: second.job, states: second.states, read: second.read))
    let folder = drive + "/B/ascmhl/"
    let name = try #require(try fm.contentsOfDirectory(atPath: folder).first { $0.hasSuffix(".mhl") })
    let manifest = try String(contentsOfFile: folder + name, encoding: .utf8)
    for rel in rels { #expect(manifest.contains(rel), "the manifest is the whole card: \(rel)") }
}

@Test func twinFilesOnACardAreBothCopied() throws {
    let card = temp(), drive = temp(), same = rnd(300_000)
    put(card + "/AVCHD/BDMV/INDEX.BDM", same)
    put(card + "/AVCHD/BDMV/BACKUP/INDEX.BDM", same)
    put(card + "/AVCHD/BDMV/STREAM/00000.MTS", rnd(2_000_000))
    let read = CardReader.read(root: card, kind: kind), control = IngestControl()
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: control) { p in
        if p.verifiedFiles >= 2 { control.stop() }
    }
    let end = try matchThenCopy(card, drive, "S")
    #expect(end.verdict == .safe)
    for rel in read.listing.files.map(\.relPath) { #expect(fm.fileExists(atPath: drive + "/S/" + rel), "\(rel)") }
    let onDrive = Set(end.states.values.compactMap { s -> String? in if case .verified(let p, _, _) = s { p } else { nil } })
    #expect(onDrive.count == 3, "one drive file answers for one card file")
}

/// A card with two identical files, and a job stopped with only one of them on the drive.
private func twinsHalfCopied() throws -> (card: String, drive: String, read: CardRead, out: IngestOutcome) {
    let card = temp(), drive = temp(), same = rnd(300_000)
    put(card + "/A/INDEX.BDM", same); put(card + "/B/INDEX.BDM", same)
    let read = CardReader.read(root: card, kind: kind), control = IngestControl()
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: control) { p in
        if p.verifiedFiles >= 1 { control.stop() }
    }
    #expect(out.states.count == 1, "\(out.states)")
    return (card, drive, read, out)
}

@Test func aRecordedFileAnswersForOneTwinOnly() throws {
    let (_, drive, read, _) = try twinsHalfCopied()
    let states = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: DriveIndex.scan(root: drive), driveRoot: drive)
    #expect(states.values.filter { $0 == .missing }.count == 1, "\(states)")
}

@Test func aFileNoRecordKnowsAnswersForOneTwinOnly() throws {
    let (_, drive, read, _) = try twinsHalfCopied()
    try fm.removeItem(atPath: drive + "/.ingest")
    let states = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: DriveIndex.scan(root: drive), driveRoot: drive)
    let found = states.values.filter { if case .likely = $0 { true } else { false } }
    #expect(found.count == 1, "\(states)")
}

@Test func aFileAlreadyProvedAnswersForOneTwinOnly() throws {
    let (_, drive, read, out) = try twinsHalfCopied()
    let states = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: DriveIndex.scan(root: drive), driveRoot: drive, proved: out.proofs)
    #expect(states.values.filter { $0 == .missing }.count == 1, "\(states)")
}

@Test func theSpaceCheckLeavesOutWhatsAlreadyThere() throws {
    let drive = temp(), card = temp()
    put(card + "/a.bin", rnd(1000))
    let read = CardReader.read(root: card, kind: kind)
    var job = makeJob(read, drive: drive, dest: "S")
    job.items[0].file.size = 1 << 60
    #expect(throws: IngestError.self) { try IngestEngine.preflight(job: job) }
    put(drive + "/S/a.bin", rnd(1000))
    try IngestEngine.preflight(job: job)
}

@Test func theNewestRecordOfACopyIsTheOneLookedAt() throws {
    func entryOnADrive(oldName: String, newName: String, newestWrittenFirst: Bool = false) throws -> String? {
        let drive = temp()
        put(drive + "/Old/a.bin", rnd(1000)); put(drive + "/New/a.bin", rnd(1000))
        let jobs = [(oldName, 1_000_000_000.0, "Old/a.bin"), (newName, 1_700_000_000.0, "New/a.bin")]
        for (job, year, path) in newestWrittenFirst ? jobs.reversed() : jobs {
            let j = try Ledger(driveRoot: drive).open(LedgerHeader(job: job, started: Date(timeIntervalSince1970: year), cardName: "c", camera: nil, destination: "S", app: "t"))
            try j.record(LedgerEntry(cardPath: "a.bin", drivePath: path, size: 1000, quick: "q", hash: "h", weak: nil))
            j.close()
        }
        return Ledger(driveRoot: drive).entry(size: 1000, quick: "q")?.drivePath
    }
    // The file names say nothing, so both orders.
    #expect(try entryOnADrive(oldName: "A", newName: "Z") == "New/a.bin")
    #expect(try entryOnADrive(oldName: "Z", newName: "A") == "New/a.bin")
    #expect(try entryOnADrive(oldName: "A", newName: "Z", newestWrittenFirst: true) == "New/a.bin", "when it started is what counts")
}

// Headers keep whole seconds, and a small card can go twice in one.
@Test func twoJobsInOneSecondKeepTheirOrder() throws {
    let drive = temp(), when = Date()
    put(drive + "/Old/a.bin", rnd(1000)); put(drive + "/New/a.bin", rnd(1000))
    for (job, path) in [("Z", "Old/a.bin"), ("A", "New/a.bin")] {
        let j = try Ledger(driveRoot: drive).open(LedgerHeader(job: job, started: when, cardName: "c", camera: nil, destination: "S", app: "t"))
        try j.record(LedgerEntry(cardPath: "a.bin", drivePath: path, size: 1000, quick: "q", hash: "h", weak: nil))
        j.close()
        usleep(20_000)
    }
    #expect(Ledger(driveRoot: drive).entry(size: 1000, quick: "q")?.drivePath == "New/a.bin")
}

@Test func aRefusedJobsUnrecordedNameIsWeakOnThisMountToo() throws {
    let (_, drive, read) = oneFileCard()
    let dying = Flag(), ledger = Ledger(driveRoot: drive)
    _ = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: ledger, control: IngestControl(),
                             hooks: FaultHooks(afterCopy: { _, _, _ in dying.on = true }, syncVolume: { _ in dying.on = false; return 1 }, journalFails: { dying.on })) { _ in }
    #expect(ledger.isWeak(drivePath: "S/C0001.MP4"), "it needn't wait for the drive to come back")
}

@Test func aNameGivenBackIsntWeakWhenTheJobIsRefused() throws {
    let drive = temp()
    let ledger = Ledger(driveRoot: drive)
    let journal = try ledger.open(LedgerHeader(job: "J", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    try journal.begin()
    journal.intend(["S/theirs.bin", "S/mine.bin"])
    journal.release("S/theirs.bin")
    _ = journal.seal([], flushVolume: { 1 })
    journal.close()
    #expect(ledger.isWeak(drivePath: "S/mine.bin"))
    #expect(!ledger.isWeak(drivePath: "S/theirs.bin"), "someone else got that name first")
}

@Test func aCutOffJobsNameIsOnlyClearedByAJobThatWantsIt() throws {
    let drive = temp(), other = temp()
    let journal = try Ledger(driveRoot: drive).open(LedgerHeader(job: "CUT", started: Date(), cardName: "c", camera: nil, destination: "S", app: "t"))
    try journal.begin()
    journal.intend(["S/theirs.bin"])
    journal.close()
    put(drive + "/S/theirs.bin", Data())
    put(other + "/Z.MP4", rnd(1000))
    _ = try IngestEngine.run(job: makeJob(CardReader.read(root: other, kind: kind), drive: drive, dest: "T"), ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(fm.fileExists(atPath: drive + "/S/theirs.bin"), "an unrelated job has no reason to touch it")
}

@Test func aManifestNeverGoesThroughALink() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1000))
    try fm.createDirectory(atPath: drive + "/S", withIntermediateDirectories: true)
    #expect(symlink(card, drive + "/S/ascmhl") == 0)
    let read = CardReader.read(root: card, kind: kind)
    let job = makeJob(read, drive: drive, dest: "S")
    let out = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(throws: IngestError.self) { try Pipeline.writeManifest(job: job, states: out.states, read: read) }
    #expect(try fm.contentsOfDirectory(atPath: card) == ["C0001.MP4"], "rule 12")
}

@Test(arguments: [Data("<ascmhldirectory>cut short".utf8), Data([0xFF, 0xFE, 0x00])])
func aChainItCantAppendToIsLeftAlone(chain: Data) throws {
    let root = temp()
    put(root + "/ascmhl/ascmhl_chain.xml", chain)
    #expect(throws: IngestError.self) { try ASCMHL.write(root: root, rows: [ASCMHL.Row(path: "a", size: 1, mtime: 0, hash: "1")]) }
    #expect(fm.contents(atPath: root + "/ascmhl/ascmhl_chain.xml") == chain, "someone's history")
    #expect(try fm.contentsOfDirectory(atPath: root + "/ascmhl") == ["ascmhl_chain.xml"])
}

@Test func aJobThatCantListItsNamesTakesNone() throws {
    let (_, drive, read) = oneFileCard()
    let calls = Counter()
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(journalFails: { calls.next() == 1 })) { _ in }
    guard case .failed? = out.states["C0001.MP4"] else { Issue.record("\(out.states)"); return }
    #expect(!fm.fileExists(atPath: drive + "/S/C0001.MP4"), "a name goes on the list first")
}

@Test func aJobThatCantListItsNamesStillChecksWhatsThere() throws {
    let (_, drive, read) = try oneFileCardCopied()
    let calls = Counter()
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: IngestControl(),
                                   hooks: FaultHooks(journalFails: { calls.next() == 1 })) { _ in }
    if case .verified? = out.states["C0001.MP4"] {} else { Issue.record("\(out.states)") }
}

@Test func aCloseThatDidntHappenLeavesNoStrongLine() throws {
    let (card, drive, read) = oneFileCard()
    try recordLost(card, drive)
    let path = drive + "/S/C0001.MP4", bytes = fm.contents(atPath: path)!
    let r = check(card, drive, read, flush: 0, hooks: FaultHooks(syncVolume: { _ in
        try? fm.removeItem(atPath: path); put(path, bytes); return 0
    }))
    #expect(r.weak)
    #expect(try !ledgerText(drive).contains("\"quick\""), "a strong line here would answer for that job's name")
    #expect(check(card, drive, read, flush: nil).weak, "so a look still holds")
}

@Test func losingTheFirstLineDoesntLoseTheMarkBehindIt() throws {
    let (_, drive, read) = try cutOffCopy(flush: 0)
    try rewriteJournals(drive) { $0.split(separator: "\n").dropFirst().joined(separator: "\n") + "\n" }
    #expect(!unfinished(Ledger(driveRoot: drive), read, "S/C0001.MP4").isEmpty)
}

// Nothing a person reads talks about flushes or caches.
@Test func theWordsOnAHoldAreForAPerson() {
    let message = Pipeline.settle(issues: [], states: [:], weak: true, driveRoot: "/x")[0].message.lowercased()
    for word in ["flush", "cache", "sync", "journal", "hash", "ledger"] { #expect(!message.contains(word), "\(word)") }
}

// Inside `seal`, `sync` was the volume flush, so the job asked three times and heard the last.
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

// A copy made a moment ago can go green while it's still only in a cache.
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

// Rule 14 says empty folders survive, and only a job made them.
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
