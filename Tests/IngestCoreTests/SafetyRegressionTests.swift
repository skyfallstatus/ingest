import CIngest
import Foundation
import Testing
@testable import IngestCore

// Each test here is an attack from the independent safety review that once produced a false "Safe to format".

private let fm = FileManager.default
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
    return Pipeline.conclude(read: read, states: s, issues: [], driveRoot: drive, kind: kind).verdict
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
    #expect(r.states["C0001.MP4"] == .missing)
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
    #expect(r.states["C0001.MP4"] == .missing)
}

/// A later visit, in a new session: the record gives a hint, and only a full read of both sides proves it.
private func laterVisit(_ card: String, _ drive: String) throws -> (read: CardRead, states: [String: FileState], weak: Bool) {
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    guard case .likely(let p)? = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)["C0001.MP4"] else {
        Issue.record("expected a hint")
        return (read, [:], false)
    }
    let r = IngestEngine.confirm(cardRoot: card, driveRoot: drive, candidates: [(read.listing.files[0], p, try #require(read.quick["C0001.MP4"]))],
                                 ledger: ledger, jobName: "x", control: IngestControl()) { _, _ in }
    return (read, r.states, r.weak)
}

@Test func aWeakCopyStaysWeakOnALaterVisit() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(1_000_000))
    try copyCard(card, drive)
    try markLedgerWeak(drive)
    let visit = try laterVisit(card, drive)
    #expect(visit.weak)
    let issues = Pipeline.settle(issues: [], states: visit.states, weak: visit.weak, driveRoot: drive)
    let v = Pipeline.conclude(read: visit.read, states: visit.states, issues: issues, driveRoot: drive, kind: kind).verdict
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
    #expect(!Ledger.isInsideDrive("../card/C0001.MP4"))
    #expect(!Ledger.isInsideDrive("F/../../card/C0001.MP4"))
    #expect(!Ledger.isInsideDrive("/Volumes/Card/C0001.MP4"))
    #expect(Ledger.isInsideDrive("F/A..B/C0001.MP4"))
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

@Test func swappedCardWithSameNamesAndSizesIsCaught() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(2_000_000))
    try copyCard(card, drive)
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let s = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive)
    let p: String
    if case .likely(let hit)? = s["C0001.MP4"] { p = hit } else { Issue.record("expected a hint"); return }
    let proved: [String: FileState] = ["C0001.MP4": .verified(drivePath: p, hash: "0")]
    put(card + "/C0001.MP4", rnd(2_000_000))    // a different card now sits at this path
    #expect(Pipeline.conclude(read: read, states: proved, issues: [], driveRoot: drive, kind: kind).verdict != .safe)
}

@Test func aProofDoesNotOutliveTheFileItProved() throws {
    let card = temp(), drive = temp()
    put(card + "/C0001.MP4", rnd(2_000_000))
    try copyCard(card, drive)
    let first = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    let file = first.listing.files[0]
    let quick = first.quick[file.relPath]!
    let proved = [file.relPath: Proof(state: .verified(drivePath: file.relPath, hash: "0"), file: file, quick: quick)]
    func isVerified(_ read: CardRead) -> Bool {
        if case .verified? = CardMatcher.match(read: read, ledger: ledger, index: nil, driveRoot: drive, proved: proved)[file.relPath] { true } else { false }
    }
    #expect(isVerified(first), "the same file keeps its proof")

    // Same name, same size, new head: a recheck must never carry the old proof across.
    var changed = first
    changed.quick[file.relPath] = String(repeating: "0", count: 16)
    #expect(!isVerified(changed))

    // Same fingerprint, rewritten: the time gives it away.
    changed = first
    changed.listing.files[0].mtime += 1
    #expect(!isVerified(changed))

    changed = first
    changed.listing.files[0].size += 1
    #expect(!isVerified(changed))
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

@Test func aStripedHoldClearsOnlyOnceItsPartnerIsOnTheDrive() {
    let drive = temp()
    put(drive + "/S/a.braw", rnd(10))
    let issue = CardIssue(severity: .hold, code: "braw.striped", message: "half", paths: ["a.braw"])
    let states: [String: FileState] = ["a.braw": .verified(drivePath: "S/a.braw", hash: "1")]
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive) == [issue])
    #expect(Pipeline.settle(issues: [issue], states: [:], weak: false, driveRoot: drive) == [issue])
    put(drive + "/S/a.braw2", rnd(10))
    #expect(Pipeline.settle(issues: [issue], states: states, weak: false, driveRoot: drive).isEmpty)
}

@Test func aSecondHalfJoinsItsPartnersFolder() {
    let card = temp()
    put(card + "/a.braw2", rnd(10))
    let read = CardReader.read(root: card, kind: kind)
    let probe = ProbeResult(issues: [CardIssue(severity: .hold, code: "braw.striped", message: "x", paths: ["a.braw2"])], hasVideo: true)
    let index = DriveIndex(entries: [DriveEntry(path: "Old/A/a.braw", isDir: false, size: 10, mtime: 0)])
    let job = Pipeline.makeJob(read: read, states: [:], cardName: "x", driveRoot: "/x", camera: nil,
                               destination: Destination(footageRoot: "New"), probe: probe, index: index)
    #expect(job.items.first?.drivePath == "Old/A/a.braw2")
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
