import CIngest
import Foundation
import Testing
@testable import IngestCore

// MARK: XXH64

private func x(_ s: String) -> String { let b = Array(s.utf8); return hexHash(ci_xxh64_oneshot(b, b.count, 0)) }

/// The official generated buffer from xxHash's sanity tests.
private func officialBuffer(_ n: Int) -> [UInt8] {
    var gen: UInt64 = 2654435761
    return (0..<n).map { _ in
        let b = UInt8(gen >> 56)
        gen = gen &* 11400714785074694797
        return b
    }
}

@Test func xxh64StringVectors() {
    #expect(x("") == "ef46db3751d8e999")
    #expect(x("a") == "d24ec4f1a98c6e5b")
    #expect(x("abc") == "44bc2cf5ad770999")
    #expect(x("Nobody inspects the spammish repetition") == "fbcea83c8a378bf1")
    #expect(x("The quick brown fox jumps over the lazy dog") == "0b242d361fda71bc")
    #expect(x("Call me Ishmael. Some years ago--never mind how long precisely-") == "02a2e85470d6fd96")
    #expect(x("0123456789abcdef0123456789abcdef") == "642a94958e71e6c5")
    #expect(x("0123456789abcdef0123456789abcdefX") == "ce5a102349511ece")
}

@Test func xxh64OfficialGeneratedVectors() {
    #expect(Array(officialBuffer(8)) == [0x00, 0x52, 0x92, 0x9b, 0xb7, 0x32, 0xa3, 0x24])
    let cases: [(Int, UInt64, String)] = [
        (0, 0, "ef46db3751d8e999"), (0, 0x9E3779B1, "ac75fda2929b17ef"), (1, 0, "e934a84adb052768"),
        (1, 0x9E3779B1, "5014607643a9b4c3"), (3, 0, "ff7e1959cb50794a"), (4, 0, "9136a0dca57457ee"),
        (8, 0, "cdbcf538e71d1348"), (31, 0, "299b39a290e6d783"), (32, 0, "18b216492bb44b70"),
        (33, 0, "55c8dc3e578f5b59"), (64, 0, "ef558f8acac2b5cd"), (100, 0, "4bfe019cd91d9ea4"),
    ]
    for (len, seed, want) in cases {
        let b = officialBuffer(len)
        #expect(hexHash(ci_xxh64_oneshot(b, len, seed)) == want, "len \(len) seed \(seed)")
    }
}

@Test func xxh64StreamingMatchesOneShotAtEverySplit() {
    let b = officialBuffer(257)
    let want = ci_xxh64_oneshot(b, b.count, 0)
    for split in 0...b.count {
        var s = ci_xxh64()
        ci_xxh64_init(&s, 0)
        b.withUnsafeBytes { p in
            ci_xxh64_update(&s, p.baseAddress, split)
            ci_xxh64_update(&s, p.baseAddress! + split, b.count - split)
        }
        var copy = s
        #expect(ci_xxh64_final(&copy) == want, "split \(split)")
    }
}

// MARK: The verdict: every way it must refuse

private let file = CardFile(relPath: "CLIP/C0001.MP4", size: 10, mtime: 0, kind: .video)
private let file2 = CardFile(relPath: "CLIP/C0002.MP4", size: 10, mtime: 0, kind: .video)
private func listing(_ f: [CardFile] = [file, file2], errors: [ListingError] = []) -> CardListing {
    CardListing(root: "/x", files: f, dirs: [], errors: errors)
}
private let good: [String: FileState] = [
    file.relPath: .verified(drivePath: "a", hash: "1"), file2.relPath: .verified(drivePath: "b", hash: "2"),
]

@Test func safeOnlyWhenEverythingHolds() {
    #expect(Verdict.evaluate(listing: listing(), unreadable: [], states: good, issues: [], cardUnchanged: true) == .safe)
}

@Test func anyUnverifiedFileIsNotSafe() {
    for bad in [FileState.missing, .likely(drivePath: "a"), .failed("x")] {
        var s = good; s[file.relPath] = bad
        guard case .notSafe(let r, let t, _) = Verdict.evaluate(listing: listing(), unreadable: [], states: s, issues: [], cardUnchanged: true) else {
            Issue.record("\(bad) must not be safe"); continue
        }
        #expect(r == 1 && t == 2)
    }
    var s = good; s[file.relPath] = nil
    #expect(Verdict.evaluate(listing: listing(), unreadable: [], states: s, issues: [], cardUnchanged: true) != .safe)
}

@Test func listingErrorIsNotSafeEvenWhenAllFilesVerified() {
    let l = listing(errors: [ListingError(path: "x.zip", reason: "won't open")])
    #expect(Verdict.evaluate(listing: l, unreadable: [], states: good, issues: [], cardUnchanged: true) != .safe)
}

@Test func unreadableFileIsNotSafe() {
    let u = [ListingError(path: "C0003.MP4", reason: "won't open")]
    #expect(Verdict.evaluate(listing: listing(), unreadable: u, states: good, issues: [], cardUnchanged: true) != .safe)
}

@Test func changedCardIsNotSafe() {
    #expect(Verdict.evaluate(listing: listing(), unreadable: [], states: good, issues: [], cardUnchanged: false) != .safe)
}

@Test func blockerBeatsEverything() {
    let i = CardIssue(severity: .blocker, code: "codex.crc", message: "CRC error")
    #expect(Verdict.evaluate(listing: listing(), unreadable: [], states: good, issues: [i], cardUnchanged: true) != .safe)
}

@Test func holdIsAmberNotGreen() {
    let i = CardIssue(severity: .hold, code: "red.missing-part", message: "Part missing")
    #expect(Verdict.evaluate(listing: listing(), unreadable: [], states: good, issues: [i], cardUnchanged: true) == .hold([i]))
}

@Test func noteDoesNotStopGreen() {
    let i = CardIssue(severity: .note, code: "n", message: "FYI")
    #expect(Verdict.evaluate(listing: listing(), unreadable: [], states: good, issues: [i], cardUnchanged: true) == .safe)
}

@Test func emptyCardIsEmptyNotSafe() {
    #expect(Verdict.evaluate(listing: listing([]), unreadable: [], states: [:], issues: [], cardUnchanged: true) == .empty)
}

@Test func anEmptyLookingCardWithErrorsIsNotEmpty() {
    let l = listing([], errors: [ListingError(path: "/", reason: "I/O error")])
    #expect(Verdict.evaluate(listing: l, unreadable: [], states: [:], issues: [], cardUnchanged: true) != .empty)
    #expect(Verdict.evaluate(listing: l, unreadable: [], states: [:], issues: [], cardUnchanged: true) != .safe)
}

// MARK: Junk filter

@Test func onlyExactSystemDroppingsAreJunk() {
    #expect(Junk.isJunk(name: "._C0001.MP4", depth: 3, isDir: false))
    #expect(Junk.isJunk(name: ".DS_Store", depth: 2, isDir: false))
    #expect(Junk.isJunk(name: ".Spotlight-V100", depth: 1, isDir: true))
    #expect(Junk.isJunk(name: ".Trashes", depth: 1, isDir: true))
    // Real work that looks disposable must never be skipped.
    for keep in ["FALSE TAKE", "FALSETAKES", "TRASH", "Thumb", "THMBNL", "A001.sidecar", "clip.RMD", "reel.ale", "P001.LRF", ".codexvfs"] {
        #expect(!Junk.isJunk(name: keep, depth: 1, isDir: false), "\(keep)")
        #expect(!Junk.isJunk(name: keep, depth: 2, isDir: true), "\(keep)")
    }
    // A folder only counts as a system folder at the root of the volume.
    #expect(!Junk.isJunk(name: ".Trashes", depth: 3, isDir: true))
}

// MARK: Engine, on the real filesystem

private func write(_ root: String, _ rel: String, _ size: Int) { put(root + "/" + rel, rnd(size)) }

private func ingest(card: String, drive: String, dest: String, hooks: FaultHooks = FaultHooks()) throws -> (CardVerdict, [String: FileState]) {
    let kind: (String) -> FileKind = { _ in .video }
    let read = CardReader.read(root: card, kind: kind)
    let ledger = Ledger(driveRoot: drive)
    var states = CardMatcher.match(read: read, ledger: ledger, index: DriveIndex.scan(root: drive), driveRoot: drive)
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: dest, states: states), ledger: ledger, control: IngestControl(), hooks: hooks) { _ in }
    for (k, v) in out.states { states[k] = v }
    let issues = Pipeline.settle(issues: [], states: states, weak: out.weakVerification, driveRoot: drive)
    let r = Pipeline.conclude(read: read, states: states, issues: issues, driveRoot: drive, kind: kind)
    return (r.verdict, r.states)
}

@Test func copyIsByteIdenticalAndRecognisedAfterwards() throws {
    let card = temp(), drive = temp()
    write(card, "M4ROOT/CLIP/C0001.MP4", 9_000_000)   // crosses an 8 MiB buffer
    write(card, "M4ROOT/CLIP/C0001M01.XML", 2100)
    write(card, "SONY/SONYCARD.IND", 0)
    let (v, _) = try ingest(card: card, drive: drive, dest: "Shoot/A082")
    #expect(v == .safe)
    #expect(FileManager.default.contentsEqual(atPath: card + "/M4ROOT/CLIP/C0001.MP4", andPath: drive + "/Shoot/A082/M4ROOT/CLIP/C0001.MP4"))
    let read = CardReader.read(root: card) { _ in .video }
    let again = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive)
    // Known at once, yet not proof: a record never turns a card green on its own.
    #expect(!again.values.contains { if case .verified = $0 { true } else { false } })
    if case .likely? = again["M4ROOT/CLIP/C0001.MP4"] {} else { Issue.record("the clip should still be recognised") }
    #expect(try ingest(card: card, drive: drive, dest: "Shoot/A082").0 == .safe)
}

@Test func deletedCopyIsNoLongerSafe() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000); write(card, "B.MP4", 2_000_000)
    #expect(try ingest(card: card, drive: drive, dest: "S").0 == .safe)
    try FileManager.default.removeItem(atPath: drive + "/S/A.MP4")
    let read = CardReader.read(root: card) { _ in .video }
    let s = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: DriveIndex.scan(root: drive), driveRoot: drive)
    #expect(s["A.MP4"] == .missing)
    let v = Pipeline.conclude(read: read, states: s, issues: [], driveRoot: drive) { _ in .video }.verdict
    #expect(v != .safe)
}

@Test func truncatedCopyOnDriveIsNotAccepted() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 3_000_000)
    #expect(try ingest(card: card, drive: drive, dest: "S").0 == .safe)
    let fh = FileHandle(forUpdatingAtPath: drive + "/S/A.MP4")!
    try fh.truncate(atOffset: 1_000_000); try fh.close()
    let read = CardReader.read(root: card) { _ in .video }
    let s = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive)
    #expect(s["A.MP4"] == .missing)
}

@Test func corruptedCopyNeverGetsItsRealName() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000)
    let hooks = FaultHooks(afterCopy: { temp, _, _ in
        let h = FileHandle(forUpdatingAtPath: temp)!
        try? h.seek(toOffset: 1000); try? h.write(contentsOf: Data([0x55, 0xAA, 0x55])); try? h.close()
    })
    let (v, _) = try ingest(card: card, drive: drive, dest: "S", hooks: hooks)
    #expect(v != .safe)
    #expect(!FileManager.default.fileExists(atPath: drive + "/S/A.MP4"))
    #expect(tempFiles(on: drive).isEmpty)
}

@Test func aFileThatIsNotTheListedSizeIsNotAccepted() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000)
    let read = CardReader.read(root: card) { _ in .video }
    var job = makeJob(read, drive: drive, dest: "S")
    job.items[0].file.size += 1
    let out = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: drive), control: IngestControl()) { _ in }
    #expect(!out.failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: drive + "/S/A.MP4"))
}

/// Inverts one byte, so every call changes the file again.
private func flipByte(_ path: String) {
    let h = FileHandle(forUpdatingAtPath: path)!
    try? h.seek(toOffset: 1000)
    let b = (try? h.read(upToCount: 1))?.first ?? 0
    try? h.seek(toOffset: 1000); try? h.write(contentsOf: Data([b ^ 0xFF])); try? h.close()
}

@Test func aBadCopyIsRetriedOnceAndThenSucceeds() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000)
    let (v, _) = try ingest(card: card, drive: drive, dest: "S", hooks: FaultHooks(afterCopy: { temp, _, attempt in if attempt == 1 { flipByte(temp) } }))
    #expect(v == .safe)
    #expect(FileManager.default.contentsEqual(atPath: card + "/A.MP4", andPath: drive + "/S/A.MP4"))
}

// On a retry with a stable source the copy is proved against the card as it now stands, so the hook changes it every time.
@Test func aSourceThatChangesDuringTheCopyNeverGetsItsRealName() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000)
    let (v, _) = try ingest(card: card, drive: drive, dest: "S", hooks: FaultHooks(afterCopy: { _, src, _ in flipByte(src) }))
    #expect(v != .safe)
    #expect(!FileManager.default.fileExists(atPath: drive + "/S/A.MP4"))
    #expect(tempFiles(on: drive).isEmpty)
}

@Test func stoppingLeavesNoTempAndAResumeFinishes() throws {
    let card = temp(), drive = temp()
    for i in 0..<6 { write(card, "c/\(i).MP4", 300_000) }
    let control = IngestControl()
    let read = CardReader.read(root: card) { _ in .video }
    let out = try IngestEngine.run(job: makeJob(read, drive: drive, dest: "S"), ledger: Ledger(driveRoot: drive), control: control) {
        if $0.verifiedFiles >= 2 { control.stop() }
    }
    #expect(out.cancelled)
    #expect(tempFiles(on: drive).isEmpty)
    #expect(Pipeline.conclude(read: read, states: out.states, issues: [], driveRoot: drive) { _ in .video }.verdict != .safe)
    #expect(try ingest(card: card, drive: drive, dest: "S").0 == .safe)
}

@Test func existingDifferentFileIsNeverOverwritten() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000)
    write(drive, "S/A.MP4", 2_000_000)   // same name, same size, different bytes
    let before = FileManager.default.contents(atPath: drive + "/S/A.MP4")
    let (v, s) = try ingest(card: card, drive: drive, dest: "S")
    #expect(v != .safe)
    if case .failed = s["A.MP4"] {} else { Issue.record("expected a failure") }
    #expect(FileManager.default.contents(atPath: drive + "/S/A.MP4") == before)
}

@Test func renamedCopyElsewhereStillHasToProveItself() throws {
    let card = temp(), drive = temp()
    write(card, "C0001.MP4", 3_000_000)
    try FileManager.default.createDirectory(atPath: drive + "/hand sorted", withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: card + "/C0001.MP4", toPath: drive + "/hand sorted/Interview take 1.MP4")
    let read = CardReader.read(root: card) { _ in .video }
    let s = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: DriveIndex.scan(root: drive), driveRoot: drive)
    #expect(s["C0001.MP4"] == .likely(drivePath: "hand sorted/Interview take 1.MP4"))
    #expect(Verdict.evaluate(listing: read.listing, unreadable: [], states: s, issues: [], cardUnchanged: true) != .safe)
}

@Test func sameSizeDifferentContentIsNotAMatch() throws {
    let card = temp(), drive = temp()
    write(card, "C0001.MP4", 3_000_000)
    write(drive, "elsewhere/C0001.MP4", 3_000_000)
    let read = CardReader.read(root: card) { _ in .video }
    let s = CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: DriveIndex.scan(root: drive), driveRoot: drive)
    #expect(s["C0001.MP4"] == .missing)
}

@Test func tornLedgerLineIsIgnoredNotFatal() throws {
    let card = temp(), drive = temp()
    write(card, "A.MP4", 2_000_000)
    #expect(try ingest(card: card, drive: drive, dest: "S").0 == .safe)
    let folder = drive + "/.ingest/ledger/"
    let name = try #require(try FileManager.default.contentsOfDirectory(atPath: folder).first { $0.hasSuffix(".jsonl") })
    let h = FileHandle(forWritingAtPath: folder + name)!
    try h.seekToEnd(); try h.write(contentsOf: Data("{\"cardPath\":\"tor".utf8)); try h.close()
    let read = CardReader.read(root: card) { _ in .video }
    #expect(CardMatcher.match(read: read, ledger: Ledger(driveRoot: drive), index: nil, driveRoot: drive)["A.MP4"] != .missing)
}

@Test func unicodeNamesSurviveExactly() throws {
    let card = temp(), drive = temp()
    let nfd = "E\u{301}te\u{301} A001_1103351\u{202F}PM_C001.mov"
    write(card, "CLIP/" + nfd, 1000)
    #expect(try ingest(card: card, drive: drive, dest: "S").0 == .safe)
    #expect(matchKey("E\u{301}.MP4") == matchKey("\u{C9}.mp4"))
}

@Test func nothingIsLeftBehind() throws {
    let card = temp(), drive = temp()
    for i in 0..<20 { write(card, "c/\(i).bin", 1000 * (i + 1)) }
    _ = try ingest(card: card, drive: drive, dest: "S")
    let all = FileManager.default.enumerator(atPath: drive)?.compactMap { $0 as? String } ?? []
    #expect(!all.contains { $0.hasSuffix(".part") })
}

@Test func notEnoughSpaceRefusesBeforeWritingAnything() {
    let job = IngestJob(cardRoot: "/", cardName: "c", driveRoot: "/tmp", camera: nil, destination: "d", dirsToCreate: [],
                        items: [IngestItem(file: CardFile(relPath: "x", size: UInt64.max / 4, mtime: 0, kind: .video), drivePath: "x", quick: "0")])
    #expect(throws: IngestError.self) { try IngestEngine.preflight(job: job) }
}

// MARK: Manifest

@Test func c4MatchesSpecShape() {
    let c = ASCMHL.c4(Data("hello".utf8))
    #expect(c.hasPrefix("c4") && c.count == 90)
}

@Test func manifestAppendsAndNeverOverwrites() throws {
    let root = temp()
    let r = [ASCMHL.Row(path: "a&b <c>.mp4", size: 1, mtime: 0, hash: "0123456789abcdef")]
    let first = try ASCMHL.write(root: root, rows: r)
    let body = try String(contentsOfFile: first, encoding: .utf8)
    #expect(body.contains("a&amp;b &lt;c&gt;.mp4"))
    let second = try ASCMHL.write(root: root, rows: r, now: Date().addingTimeInterval(5))
    #expect(first != second && (second as NSString).lastPathComponent.hasPrefix("0002_"))
    let chain = try String(contentsOfFile: root + "/ascmhl/ascmhl_chain.xml", encoding: .utf8)
    #expect(chain.contains("sequencenr=\"1\"") && chain.contains("sequencenr=\"2\""))
}

@Test func indexCacheRoundTrips() {
    let e = [DriveEntry(path: "a/é b.mp4", isDir: false, size: 12, mtime: 34), DriveEntry(path: "a", isDir: true, size: 0, mtime: 1)]
    let url = URL(fileURLWithPath: temp() + "/i.idx")
    DriveIndex(entries: e).save(to: url)
    #expect(DriveIndex.load(from: url)?.entries == e)
}

// MARK: Reading ahead

/// Sizes either side of every boundary in the read path: chunks of 2 and 8 MiB, and 16 MiB, where reads start to overlap.
private let boundaries: [Int] = [0, 1, 4095, 1 << 20, (2 << 20) - 1, 2 << 20, (2 << 20) + 1, (8 << 20) - 1, 8 << 20, (8 << 20) + 1,
                                 (16 << 20) - 1, 16 << 20, (16 << 20) + 1, 24 << 20, (32 << 20) + 3, 40 << 20]

@Test(arguments: boundaries) func readingAheadHashesEveryByteInOrder(size: Int) {
    let dir = temp(), path = dir + "/f.bin"
    let data = rnd(size)
    put(path, data)
    var invalidated: Int32 = 0
    let r = ci_hash_uncached(path, nil, &invalidated, nil)
    #expect(r.stage == 0 && r.err == 0)
    #expect(r.bytes == UInt64(size))
    #expect(r.hash == data.withUnsafeBytes { ci_xxh64_oneshot($0.baseAddress, size, 0) })
    #expect(invalidated == 1)
}

@Test(arguments: boundaries) func readingAheadCopiesEveryByteInOrder(size: Int) throws {
    let dir = temp(), src = dir + "/in.bin", dst = dir + "/out.bin"
    let data = rnd(size)
    put(src, data)
    let control = IngestControl()
    let r = ci_copy(src, dst, UInt64(size), nil, control.copied)
    #expect(r.stage == 0 && r.err == 0)
    #expect(r.bytes == UInt64(size))
    #expect(r.hash == data.withUnsafeBytes { ci_xxh64_oneshot($0.baseAddress, size, 0) })
    #expect(control.bytesCopied == UInt64(size))
    #expect(try Data(contentsOf: URL(fileURLWithPath: dst)) == data)
}

@Test func checkingReportsTheBytesItHashed() {
    let dir = temp(), path = dir + "/f.bin"
    put(path, rnd(20 << 20))
    let control = IngestControl()
    let r = ci_hash_uncached(path, nil, nil, control.checked)
    #expect(r.stage == 0 && control.bytesChecked == 20 << 20)
}

@Test func aStopReachesAnOverlappedRead() {
    let dir = temp(), src = dir + "/in.bin", dst = dir + "/out.bin"
    put(src, rnd(40 << 20))
    let control = IngestControl()
    control.stop()
    #expect(ci_hash_uncached(src, control.cancelFlag, nil, nil).stage == Int32(CI_STAGE_CANCELLED))
    #expect(ci_copy(src, dst, 40 << 20, control.cancelFlag, nil).stage == Int32(CI_STAGE_CANCELLED))
}

@Test func aFailedReadIsNeverAHash() {
    let r = ci_hash_uncached(temp(), nil, nil, nil)     // a directory opens, and then can't be read
    #expect(r.stage == Int32(CI_STAGE_READ) && r.err != 0)
}
