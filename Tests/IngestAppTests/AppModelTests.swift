// The real AppModel, against real files in folders. Volumes are handed in, so no test ever looks at what's plugged in.
import Foundation
import Testing
@testable import IngestApp
@testable import IngestCore

/// Everything a run makes goes in one folder, and goes with the run. A suite leaves nothing on the Mac.
private let scratch: String = {
    let p = NSTemporaryDirectory() + "ingest-app-tests-" + UUID().uuidString
    atexit { try? FileManager.default.removeItem(atPath: scratch) }
    return p
}()

private let setUp: Void = { setenv("INGEST_SUPPORT_DIR", scratch + "/support", 1) }()

private func temp() -> String {
    let p = scratch + "/" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private func put(_ path: String, _ d: Data) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! d.write(to: URL(fileURLWithPath: path))
}

private func rnd(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

private func volume(_ path: String, _ id: String, name: String? = nil) -> Volume {
    Volume(path: path, name: name ?? id, uuid: id, total: 1_000_000_000, free: 800_000_000, fsType: "exfat", isReadOnly: false, isInternal: false,
           anchor: MountAnchor(path: path))
}

private final class Plugged: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Volume, VolumeRole)] = []
    var now: [(Volume, VolumeRole)] {
        get { lock.lock(); defer { lock.unlock() }; return list }
        set { lock.lock(); list = newValue; lock.unlock() }
    }
}

/// A drive that stops taking writes, from a fault hook on the engine's thread.
private final class Dying: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var now: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A model, what's plugged into it, and a card with two files on it.
@MainActor private final class Bench {
    let model: AppModel
    let plugged = Plugged()
    let card = temp(), a = temp(), b = temp()
    lazy var cardVolume = volume(card, "CARD")
    lazy var driveA = volume(a, "DRIVE-A")
    lazy var driveB = volume(b, "DRIVE-B")

    init() {
        _ = setUp
        model = AppModel()
        model.isDemo = true
        model.stores.workingDriveKey = nil
        let plugged = plugged
        model.findVolumes = { _, _ in plugged.now }
        put(card + "/one.bin", rnd(1_000_000))
        put(card + "/two.bin", rnd(1_000_000))
    }

    func until(_ what: String, _ seconds: Double = 20, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    func drive(_ v: Volume) -> DriveState { model.drives.first { $0.path == v.path }! }

    /// Card in, both drives in, drive A in use, and the card settled against it.
    func ready() async -> CardSession {
        plugged.now = [(cardVolume, .card), (driveA, .drive), (driveB, .drive)]
        await model.refresh()
        model.use(drive: drive(driveA))
        let c = model.cards[0]
        await until("the card to settle") { c.phase == .ready && !c.isMatching }
        return c
    }

    /// All the way to Safe on drive A.
    func safe() async -> CardSession {
        let c = await ready()
        model.start(c, destination: Destination(footageRoot: "S"))
        await until("the copy") { c.phase == .finished && !c.isBusy }
        #expect(c.isSafe(on: model.workingDrive), "\(String(describing: c.verdict))")
        return c
    }
}

@Suite("The app model", .serialized) @MainActor struct AppModelTests {
    @Test func `Stop, switch drive, Resume: nothing proved on the old drive counts on the new one`() async throws {
        let w = Bench()
        let c = await w.ready()
        let first = try #require(c.read)
        var one = first
        one.listing.files = first.listing.files.filter { $0.relPath == "one.bin" }
        let ledger = w.drive(w.driveA).ledger
        let job = Pipeline.makeJob(read: one, states: [:], cardName: "C", driveRoot: w.a, camera: nil, destination: Destination(footageRoot: "S"), probe: ProbeResult(), index: nil)
        let partial = try IngestEngine.run(job: job, ledger: ledger, control: IngestControl()) { _ in }
        c.states = partial.states
        c.proved = partial.proofs
        c.pendingDestination = Destination(footageRoot: "S")
        c.phase = .stopped
        put(w.b + "/S/one.bin", rnd(1_000_000))     // same name and size on the new drive, unrelated bytes

        let b = w.drive(w.driveB)
        w.model.use(drive: b)
        #expect(c.states.isEmpty && c.proved.isEmpty, "it's all gone before anything else happens")
        await w.until("the rematch") { !c.isMatching && c.phase != .stopped }
        w.model.resume(c)
        await w.until("the job") { !c.isBusy && (c.phase == .ready || c.phase == .finished) && c.progress != nil }
        #expect(!c.isSafe(on: b))
        await w.until("the rematch after the job") { !c.isMatching && !b.isScanning }
        if case .verified? = c.states["one.bin"] { Issue.record("the wrong bytes must never count") }
        #expect(!c.isSafe(on: b))
        #expect(c.verdict != .safe)
    }

    @Test func `Choosing another drive takes the green away at once`() async {
        let w = Bench()
        let c = await w.safe()
        let b = w.drive(w.driveB)
        w.model.use(drive: b)
        #expect(!c.isSafe(on: b))
        #expect(c.verdict == nil && c.phase != .finished)
        await w.until("the rematch") { !c.isMatching && c.phase == .ready }
        #expect(!c.isSafe(on: b))
    }

    @Test func `A different drive at the same path loses the old verdict`() async throws {
        let w = Bench()
        let c = await w.safe()
        let old = try #require(w.model.workingDrive)
        try FileManager.default.removeItem(atPath: w.a + "/S")
        w.plugged.now = [(w.cardVolume, .card), (volume(w.a, "REPLACEMENT"), .drive), (w.driveB, .drive)]
        await w.model.refresh()
        #expect(w.model.workingDrive !== old)
        #expect(!c.isSafe(on: w.model.workingDrive) && !c.isSafe(on: old))
        #expect(c.verdict != .safe)
    }

    @Test func `A clone at the same path, with the same UUID, is still a new mount`() async throws {
        let w = Bench()
        let c = await w.safe()
        let old = try #require(w.model.workingDrive)
        old.ledger.mount?.retire()
        #expect(!c.isSafe(on: old), "from the moment the mount ends, before anything has noticed")
        w.plugged.now = [(w.cardVolume, .card), (volume(w.a, "DRIVE-A"), .drive), (w.driveB, .drive)]
        await w.model.refresh()
        #expect(w.drive(w.driveA) !== old)
        #expect(w.model.workingDrive !== old)
        #expect(c.verdict != .safe)
        #expect(c.proved.isEmpty)
    }

    @Test func `A card back in starts again, with nothing carried over`() async throws {
        let w = Bench()
        let c = await w.safe()
        c.volume.anchor?.retire()
        #expect(!c.isSafe(on: w.model.workingDrive), "from the moment it leaves")
        w.plugged.now = [(volume(w.card, "CARD"), .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        let again = try #require(w.model.cards.first)
        #expect(again !== c)
        #expect(again.proved.isEmpty && again.states.isEmpty && again.verdict == nil)
        await w.until("it to run to Safe by reading") { again.isSafe(on: w.model.workingDrive) }
        #expect(again.control.bytesChecked == 2_000_000, "it was read again, in full")
    }

    @Test func `A changed copy takes the green away when someone looks`() async throws {
        let w = Bench()
        let c = await w.safe()
        let h = FileHandle(forUpdatingAtPath: w.a + "/S/one.bin")!
        try h.seek(toOffset: 5000); try h.write(contentsOf: Data([1, 2, 3])); try h.close()
        w.model.lookAgain()
        await w.until("the look") { c.verdict != .safe }
        #expect(!c.isSafe(on: w.model.workingDrive))
        if case .verified? = c.states["one.bin"] { Issue.record("a changed copy can't stay proved") }
    }

    // A look during a match was dropped, so green stood over a changed copy.
    @Test func `A look during a match isn't lost`() async throws {
        let w = Bench()
        let c = await w.safe()
        await w.until("the rescan") { !c.isMatching && !w.drive(w.driveA).isScanning }
        c.isMatching = true
        let h = FileHandle(forUpdatingAtPath: w.a + "/S/one.bin")!
        try h.seek(toOffset: 5000); try h.write(contentsOf: Data([1, 2, 3])); try h.close()
        w.model.lookAgain()
        #expect(c.needsRematch)
        c.isMatching = false
        c.needsRematch = false
        await w.model.matchCard(c)
        #expect(!c.isSafe(on: w.model.workingDrive))
        #expect(c.verdict != .safe)
    }

    // An older look landing after a newer one must not bring its green back.
    @Test func `An older look can't land over a newer one`() async throws {
        let w = Bench()
        let c = await w.safe()
        await w.until("the rescan") { !c.isMatching && !w.drive(w.driveA).isScanning }
        var release: CheckedContinuation<Void, Never>?
        var held = false
        let oldest = c.looks + 1
        w.model.lookLandsLate = { look in
            guard look == oldest else { return }
            await withCheckedContinuation { release = $0; held = true }
        }
        w.model.lookAgain()
        await w.until("the first look to reach the end, finding nothing wrong") { held }
        let h = FileHandle(forUpdatingAtPath: w.a + "/S/one.bin")!
        try h.seek(toOffset: 5000); try h.write(contentsOf: Data([1, 2, 3])); try h.close()
        w.model.lookAgain()
        await w.until("the newer look") { c.verdict != .safe && !c.isMatching }
        release?.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!c.isSafe(on: w.model.workingDrive))
        #expect(c.verdict != .safe)
    }

    // A file that lost its proof was called only on the card, and nothing read it again.
    @Test func `A file that lost its proof is read again, and comes back by itself`() async throws {
        let w = Bench()
        let c = await w.safe()
        await w.until("the rescan") { !c.isMatching && !w.drive(w.driveA).isScanning }
        let before = c.control.bytesChecked
        #expect(utimes(w.a + "/S/one.bin", nil) == 0)      // same bytes, a new time
        w.model.lookAgain()
        await w.until("it to be read and go green") { c.isSafe(on: w.model.workingDrive) && c.control.bytesChecked != before }
        #expect(c.control.bytesChecked == 1_000_000, "the one file, and only that one")
    }

    // The rescan after a job turned the reason into nothing.
    @Test func `A failed copy keeps its reason through the rescan`() async throws {
        let w = Bench()
        let c = await w.ready()
        put(w.a + "/S/one.bin", rnd(1_000_000))         // same name, other bytes
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("the job and its rescan") { !c.isBusy && !c.isMatching && c.progress != nil && !w.drive(w.driveA).isScanning }
        try await Task.sleep(for: .milliseconds(200))
        await w.until("it to settle") { !c.isMatching }
        guard case .failed(let why)? = c.states["one.bin"] else { Issue.record("\(String(describing: c.states["one.bin"]))"); return }
        #expect(why.contains("name on the drive") || why.contains("match"), "\(why)")
        let sheet = CardSheet.make(c, model: w.model)
        let said = ((sheet.line(.drive)?.detail ?? []) + (sheet.line(.readDrive)?.detail ?? [])).joined()
        #expect(said.contains("one.bin"), "\(said)")
    }

    @Test func `A drive that comes back carries on, and stops saying it's unplugged`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card)]
        await w.model.refresh()
        await w.until("it to stop") { !c.isBusy }
        #expect(c.error?.contains("unplugged") == true)
        let back = volume(w.a, "DRIVE-A")
        w.model.stores.workingDriveKey = back.key
        w.plugged.now = [(w.cardVolume, .card), (back, .drive)]
        await w.model.refresh()
        #expect(c.error == nil)
        #expect(!c.control.isStopped)
        await w.until("it to settle") { !c.isMatching && c.phase == .ready }
    }

    @Test func `A card back before its job has stopped gets a new session`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        c.volume.anchor?.retire()
        w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        w.plugged.now = [(volume(w.card, "CARD"), .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        await w.until("a new session") { w.model.cards.first.map { $0 !== c && !$0.volumeGone } ?? false }
    }

    @Test func `A card taken out after a job ended short isn't said to have gone mid-copy`() async throws {
        let w = Bench()
        let c = await w.ready()
        put(w.a + "/S/one.bin", rnd(1_000_000))
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("the job") { !c.isBusy && c.phase == .ready && !c.isMatching && c.progress != nil }
        c.volume.anchor?.retire()
        w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        #expect(c.error?.contains("while copying") == false, "\(c.error ?? "")")
        #expect(c.error?.contains("read again") == true, "\(c.error ?? "")")
    }

    // Found by the self-test on real clips. A pulled card makes its files lose their proof, which starts a re-read, so by the
    // time anyone hears the card has gone it can be mid-check, and the session went with no word to anyone.
    @Test func `A card pulled while its job's files are being read again still says so`() async throws {
        let w = Bench()
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("the job") { !c.isBusy && c.pendingDestination != nil && (c.phase == .finished || c.phase == .ready) && !c.isMatching }
        for phase in [CardSession.Phase.checking(done: 0, total: 1), .reading(done: 0, total: 0)] {
            c.phase = phase
            c.states["one.bin"] = .missing
            c.volumeGone = false
            c.error = nil
            w.model.cards = [c]
            c.volume.anchor?.retire()
            w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive)]
            await w.model.refresh()
            #expect(w.model.cards.contains { $0 === c }, "it stays on screen")
            #expect(c.volumeGone && c.phase == .stopped, "\(c.phase)")
        }
    }

    @Test func `Nothing is read again from a card that has gone`() async throws {
        let w = Bench()
        let c = await w.safe()
        await w.until("the rescan") { !c.isMatching && !w.drive(w.driveA).isScanning }
        let before = c.control.bytesChecked
        c.volume.anchor?.retire()
        w.model.lookAgain()
        await w.until("the look") { c.verdict != .safe }
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.control.bytesChecked == before)
        #expect(!c.isMatching)
    }

    /// Everything the widget says about a card, for reading the way a person would.
    private func said(_ c: CardSession, _ w: Bench) -> String {
        let sheet = CardSheet.make(c, model: w.model)
        return ([sheet.bottom.title, sheet.bottom.sentence, MenuBarState.make(w.model).word, MenuBarState.make(w.model).spoken]
            + sheet.lines.flatMap { [$0.label] + $0.detail }).joined(separator: " | ")
    }

    // The owner's decision. Plug back in, it checks, the rest copies, Safe, and it stays Safe. The first file was copied
    // by a real job that never reached its seal, as a pulled cable or a crash leaves it.
    @Test func `A job that was cut off finishes as if nothing happened`() async throws {
        let w = Bench()
        let whole = CardReader.read(root: w.card) { _ in .video }
        var part = whole
        part.listing.files = whole.listing.files.filter { $0.relPath == "one.bin" }
        let job = Pipeline.makeJob(read: part, states: [:], cardName: "C", driveRoot: w.a, camera: nil, destination: Destination(footageRoot: "S"), probe: ProbeResult(hasVideo: true), index: nil)
        let dying = Dying()
        _ = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: w.a), control: IngestControl(),
                                 hooks: FaultHooks(syncVolume: { _ in dying.now = true; return 0 }, journalFails: { dying.now })) { _ in }

        let c = await w.ready()
        await w.until("the rescan and the check") { !w.drive(w.driveA).isScanning && !c.isMatching && c.phase == .ready && { if case .verified? = c.states["one.bin"] { true } else { false } }() }
        #expect(!c.weak, "a confirmed flush and a full read finished it")
        #expect(c.filesToGo == 1, "and the other file is still owed")
        #expect(!said(c, w).lowercased().contains("flush") && !said(c, w).lowercased().contains("cache"), "\(said(c, w))")

        c.phase = .checking(done: 1, total: 1)
        let checking = said(c, w).lowercased()
        #expect(checking.contains("checking") && !checking.contains("flush") && !checking.contains("cache"), "\(checking)")
        c.phase = .ready

        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("Safe") { c.isSafe(on: w.model.workingDrive) }
        #expect(c.issues.isEmpty, "\(c.issues)")
        w.model.recheck(c)
        await w.until("Safe again, from the start") { c.isSafe(on: w.model.workingDrive) }
        #expect(c.issues.isEmpty, "\(c.issues)")
    }

    // "didn't match" went out with no Copy button, in the very case the app exists for.
    @Test func `A bad copy on the drive doesn't take the Copy button away`() async throws {
        let w = Bench()
        var card = try Data(contentsOf: URL(fileURLWithPath: w.card + "/one.bin"))
        card[500_000] ^= 0xFF
        put(w.a + "/Sorted/one.bin", card)      // the right name, size and ends, and a bad middle
        put(w.a + "/Sorted/two.bin", try Data(contentsOf: URL(fileURLWithPath: w.card + "/two.bin")))
        w.plugged.now = [(w.cardVolume, .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        let live = w.drive(w.driveA)
        live.setup = ShootPlanner.presets()[0].setup
        w.model.use(drive: live)
        let c = w.model.cards[0]
        await w.until("the scan and the check") { !live.isScanning && !c.isMatching && c.phase == .ready && { if case .failed? = c.states["one.bin"] { true } else { false } }() }
        let sheet = CardSheet.make(c, model: w.model)
        #expect(sheet.bottom.sentence == "1 file didn't match.")
        #expect(sheet.showsNaming)
        #expect(sheet.bottom.action == .copy(c.totalFiles), "the form starts a new folder, so that's the whole card")
    }

    /// A bad copy sitting in the folder the card is going to: the right name, size and ends, and a bad middle.
    private func stuckOnABadCopy(_ w: Bench) async throws -> (CardSession, Data) {
        var bad = try Data(contentsOf: URL(fileURLWithPath: w.card + "/one.bin"))
        bad[500_000] ^= 0xFF
        put(w.a + "/Sorted/one.bin", bad)
        put(w.a + "/Sorted/two.bin", try Data(contentsOf: URL(fileURLWithPath: w.card + "/two.bin")))
        w.plugged.now = [(w.cardVolume, .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        let live = w.drive(w.driveA)
        live.setup = ShootPlanner.presets()[0].setup
        w.model.use(drive: live)
        let c = w.model.cards[0]
        await w.until("the check") { !live.isScanning && !c.isMatching && c.phase == .ready && { if case .failed? = c.states["one.bin"] { true } else { false } }() }
        w.model.start(c, destination: Destination(footageRoot: "Sorted"))
        await w.until("the job") { !c.isBusy && c.phase != .queued && !c.isMatching && { if case .failed? = c.states["one.bin"] { true } else { false } }() }
        await w.until("the look after it") { !c.isMatching }
        await w.model.matchCard(c)              // the rescan a job's end asks for, which can land at any time or be folded into another
        return (c, bad)
    }

    @Test func `A bad copy where the card is going isn't a dead end`() async throws {
        let w = Bench()
        let (c, bad) = try await stuckOnABadCopy(w)
        let sheet = CardSheet.make(c, model: w.model)
        #expect(sheet.bottom.title == "Don't format" || sheet.bottom.kind == .failed)
        let choose = try #require(sheet.line(.drive)?.actions.first { $0 == .chooseFolder }, "\(sheet.lines.map(\.actions))")
        #expect(choose.title == "Choose Folder…")
        #expect(sheet.line(.readDrive)?.detail.contains("Choose another folder, or remove the bad copy and copy again.") == true, "\(said(c, w))")

        w.model.copy(c, into: "Elsewhere")      // what the button does once the panel has a folder
        await w.until("the copy") { c.phase == .finished && !c.isBusy }
        #expect(c.isSafe(on: w.model.workingDrive), "\(String(describing: c.verdict))")
        #expect(FileManager.default.contents(atPath: w.a + "/Sorted/one.bin") == bad, "the bad copy is still someone's to look at")
    }

    @Test func `Copy into a folder never lands on a name that's taken`() async throws {
        let w = Bench()
        let c = await w.ready()
        try FileManager.default.createDirectory(atPath: w.a + "/Shoot/CARD", withIntermediateDirectories: true)
        await w.model.refresh()
        w.drive(w.driveA).index = DriveIndex.scan(root: w.a)
        w.model.copy(c, into: "Shoot")
        await w.until("the copy") { c.phase == .finished && !c.isBusy }
        #expect(c.isSafe(on: w.model.workingDrive), "\(String(describing: c.verdict))")
        #expect(c.pendingDestination?.footageRoot == "Shoot/CARD 2", "\(String(describing: c.pendingDestination))")
    }

    /// A copy under way, with both the card and the drive taken at once, as a hub does.
    private func hubPulled(_ w: Bench) async -> CardSession {
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        c.volume.anchor?.retire(); w.driveA.anchor?.retire()
        w.plugged.now = [(w.driveB, .drive)]
        await w.model.refresh()
        await w.until("the job to stop") { !c.isBusy }
        return c
    }

    @Test func `Card and drive out together keep the card's warning when the drive comes back`() async throws {
        let w = Bench()
        let c = await hubPulled(w)
        #expect(c.error?.contains("removed while copying") == true, "\(String(describing: c.error))")
        #expect(MenuBarState.make(w.model).word == "Card pulled")
        #expect(w.model.notified.filter { $0.contains("Don't format") }.count == 1, "the card already said so: \(w.model.notified)")
        w.plugged.now = [(volume(w.a, "DRIVE-A"), .drive), (w.driveB, .drive)]
        await w.model.refresh()
        w.model.use(drive: w.model.drives.first { $0.path == w.a }!)
        try await Task.sleep(for: .milliseconds(300))
        #expect(c.error?.contains("removed while copying") == true, "\(String(describing: c.error))")
        #expect(MenuBarState.make(w.model).word == "Card pulled")
    }

    @Test func `A drive heard going before the card doesn't take the card's warning with it`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card), (w.driveB, .drive)]
        await w.model.refresh()
        c.volume.anchor?.retire()
        w.plugged.now = [(w.driveB, .drive)]
        await w.model.refresh()
        #expect(c.driveWentAway && c.volumeGone, "the job has to have been running when the card went")
        await w.until("the job to stop") { !c.isBusy }
        w.plugged.now = [(volume(w.a, "DRIVE-A"), .drive), (w.driveB, .drive)]
        await w.model.refresh()
        w.model.use(drive: w.model.drives.first { $0.path == w.a }!)
        try await Task.sleep(for: .milliseconds(300))
        #expect(c.error?.contains("removed while copying") == true, "\(String(describing: c.error))")
    }

    @Test func `A pulled card with no drive left can still be dismissed`() async throws {
        let w = Bench()
        let c = await cardPulledMidCopy(w)
        await w.until("the job to stop") { !c.isBusy }
        w.plugged.now = []
        await w.model.refresh()
        await w.until("no drive") { w.model.workingDrive == nil }
        let line = try #require(CardSheet.make(c, model: w.model).line(.drive))
        #expect(line.actions == [.dismiss], "\(line.actions)")
        #expect(line.detail.first?.contains("removed while copying") == true, "\(line.detail)")
        #expect(!said(c, w).contains("Plug it in to carry on"), "no drive carries on a card that's out")
        #expect(CardSheet.make(c, model: w.model).bottom.sentence.hasSuffix("not proved yet."))
        w.model.dismiss(c)
        #expect(w.model.cards.isEmpty)
    }

    @Test func `A pulled card doesn't keep its folder from another card`() async throws {
        let w = Bench()
        let c = await cardPulledMidCopy(w)
        await w.until("the job to stop") { !c.isBusy }
        let other = temp()
        put(other + "/x.bin", rnd(1000))
        w.plugged.now = [(volume(other, "OTHER"), .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        let o = try #require(w.model.cards.first { $0 !== c })
        await w.until("the other card to settle") { o.phase == .ready && !o.isMatching }
        w.model.start(o, destination: Destination(footageRoot: "S"))
        #expect(o.error == nil, "\(String(describing: o.error))")
        await w.until("its copy") { o.phase == .finished && !o.isBusy }
        #expect(o.isSafe(on: w.model.workingDrive))
    }

    @Test func `Copy Again isn't offered with nowhere to copy to`() async throws {
        let w = Bench()
        let read = CardReader.read(root: w.card) { _ in .video }
        let job = Pipeline.makeJob(read: read, states: [:], cardName: "C", driveRoot: w.a, camera: nil, destination: Destination(footageRoot: "S"), probe: ProbeResult(hasVideo: true), index: nil)
        _ = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: w.a), control: IngestControl(), hooks: FaultHooks(syncVolume: { _ in 5 })) { _ in }
        chmod(w.a + "/.ingest/ledger", 0o555)       // a held copy, on a drive that won't take a record of the check
        defer { chmod(w.a + "/.ingest/ledger", 0o755) }
        let c = await w.ready()
        await w.until("the check") { { if case .failed? = c.states["one.bin"] { true } else { false } }() }
        w.drive(w.driveA).setup = ShootPlanner.presets()[0].setup     // a drive with no setup says that before anything else
        let sheet = CardSheet.make(c, model: w.model)
        #expect(sheet.lines.flatMap(\.actions).allSatisfy { if case .copyAgain = $0 { false } else { true } }, "\(sheet.lines.map(\.actions))")
        #expect(sheet.bottom.sentence == "2 files not proved yet.", "\(sheet.bottom.sentence)")
    }

    @Test func `A stopped card with no drive doesn't say the files are only on the card`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card), (w.driveB, .drive)]
        await w.model.refresh()
        await w.until("the job to stop") { !c.isBusy }
        #expect(w.model.workingDrive == nil)
        let foot = CardSheet.make(c, model: w.model).bottom.sentence
        #expect(foot.hasSuffix("not proved yet."), "\(foot)")
        #expect(!foot.contains("only on this card"))
        #expect(CardSheet.make(c, model: w.model).line(.drive)?.detail.first?.contains("was unplugged") == true, "it still says why until the drive is back")
    }

    // A pull can fail the job before the app hears the drive go, so the job has already ended by then.
    @Test func `A job that ended just before the drive went keeps its reason and says nothing false`() async throws {
        let w = Bench()
        let c = await w.ready()
        c.pendingDestination = Destination(footageRoot: "S")
        c.error = "DRIVE-A was unplugged. Plug it back in to finish."
        c.driveWentAway = true
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card)]
        await w.model.refresh()
        await w.until("no drive") { w.model.workingDrive == nil && c.phase == .ready && !c.isMatching }
        #expect(c.error?.contains("unplugged") == true)
        let foot = CardSheet.make(c, model: w.model).bottom.sentence
        #expect(foot == "2 files not proved yet.", "\(foot)")
    }

    /// The same card and drive on another day: a new model, and new mounts.
    private func laterVisit(_ w: Bench) async -> (AppModel, CardSession) {
        let model = AppModel(), plugged = Plugged()
        model.isDemo = true
        model.stores.workingDriveKey = nil
        model.findVolumes = { _, _ in plugged.now }
        plugged.now = [(volume(w.card, "CARD"), .card), (volume(w.a, "DRIVE-A"), .drive)]
        await model.refresh()
        model.use(drive: model.drives[0])
        let c = model.cards[0]
        await w.until("the later visit") { !model.drives[0].isScanning && !c.isMatching && (c.phase == .finished || c.phase == .ready) }
        return (model, c)
    }

    /// A clip and a still, so the card reads as footage.
    private func mixedCard(_ w: Bench) { put(w.card + "/DCIM/A.JPG", rnd(2_000_000)); put(w.card + "/CLIP/A.MP4", rnd(2_000_000)) }

    @Test func `A rescue copies the whole card to the new folder, and Safe names that folder`() async throws {
        let w = Bench()
        let (c, bad) = try await stuckOnABadCopy(w)
        let good = FileManager.default.contents(atPath: w.a + "/Sorted/two.bin")
        w.model.retry(c)                        // the same folder again isn't a rescue
        await w.until("the retry") { !c.isBusy && !c.isMatching }
        #expect(c.badCopyNote == nil, "\(String(describing: c.badCopyNote))")
        c.shootLabel = "Old Client / Old Shoot"
        w.model.copy(c, into: "Elsewhere")
        await w.until("the copy") { c.phase == .finished && !c.isBusy }
        #expect(c.isSafe(on: w.model.workingDrive), "\(String(describing: c.verdict))")
        for f in ["one.bin", "two.bin"] { #expect(FileManager.default.fileExists(atPath: w.a + "/Elsewhere/CARD/" + f), "\(f)") }
        #expect(c.destinationPath == "Elsewhere/CARD")
        #expect(CardSheet.make(c, model: w.model).path?.contains("Old Shoot") != true, "\(String(describing: CardSheet.make(c, model: w.model).path))")
        let manifest = try #require(try FileManager.default.contentsOfDirectory(atPath: w.a + "/Elsewhere/CARD/ascmhl").first { $0.hasSuffix(".mhl") })
        let text = try String(contentsOfFile: w.a + "/Elsewhere/CARD/ascmhl/" + manifest, encoding: .utf8)
        #expect(text.contains("one.bin") && text.contains("two.bin"))
        #expect(FileManager.default.contents(atPath: w.a + "/Sorted/one.bin") == bad, "the old folder is left alone")
        #expect(FileManager.default.contents(atPath: w.a + "/Sorted/two.bin") == good)
        #expect(said(c, w).contains("A bad copy of one.bin is still in Sorted."), "\(said(c, w))")
        // Next time it's plugged in, the good copy is the one that counts.
        let (model, again) = await laterVisit(w)
        #expect(again.isSafe(on: model.workingDrive), "\(String(describing: again.verdict))")
    }

    @Test func `After a rescue the card's home is the new folder, not the one with the bad copy`() async throws {
        let w = Bench()
        var bad = rnd(2_000_000)
        put(w.card + "/DCIM/A.JPG", bad)
        let job = Pipeline.makeJob(read: CardReader.read(root: w.card) { _ in .still }, states: [:], cardName: "C", driveRoot: w.a, camera: nil, destination: Destination(footageRoot: "Old"), probe: ProbeResult(hasVideo: true), index: nil)
        _ = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: w.a), control: IngestControl()) { _ in }
        bad[1_000_000] ^= 0xFF
        put(w.a + "/Old/DCIM/A.JPG", bad)           // a copy with a record, gone bad since
        let c = await w.ready()
        await w.until("the check") { !c.isMatching && c.phase == .ready && c.filesToGo == 1 }
        #expect(c.existingHome == nil || c.existingHome == "Old")
        w.model.start(c, destination: Destination(footageRoot: "Rescue"))
        await w.until("the rescue") { c.phase == .finished && !c.isBusy }
        #expect(c.isSafe(on: w.model.workingDrive), "\(String(describing: c.verdict))")
        #expect(c.existingHome == "Rescue", "\(String(describing: c.existingHome))")
        let (model, again) = await laterVisit(w)
        #expect(again.isSafe(on: model.workingDrive), "the older copy can't take it back: \(String(describing: again.verdict))")
        #expect(again.existingHome == "Rescue", "\(String(describing: again.existingHome))")
    }

    @Test func `A stopped rescue isn't Safe until the whole card is in the new folder`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.safe()
        c.pendingDestination = nil
        c.phase = .ready
        w.model.copy(c, into: "Elsewhere")
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        #expect(c.verifiedFiles <= c.totalFiles, "\(c.verifiedFiles) of \(c.totalFiles)")
        w.model.stop(c)
        await w.until("it to stop") { c.phase == .stopped }
        #expect(c.filesToGo > 0, "what isn't in the new folder yet is still to go")
        let foot = CardSheet.make(c, model: w.model).bottom.sentence
        #expect(foot.hasSuffix("not in the new folder yet."), "they aren't only on the card: \(foot)")
        w.model.resume(c)
        await w.until("the rest") { c.phase == .finished && !c.isBusy }
        #expect(c.isSafe(on: w.model.workingDrive))
        let there = try FileManager.default.subpathsOfDirectory(atPath: w.a + "/Elsewhere/CARD").filter { $0.hasSuffix(".bin") }
        #expect(there.count == 3, "\(there)")
    }

    @Test func `The Copy button counts what the job will copy`() async throws {
        let w = Bench()
        let other = temp()
        let shared = try Data(contentsOf: URL(fileURLWithPath: w.card + "/one.bin"))
        put(other + "/one.bin", shared)
        let read = CardReader.read(root: other) { _ in .video }
        let job = Pipeline.makeJob(read: read, states: [:], cardName: "C", driveRoot: w.a, camera: nil, destination: Destination(footageRoot: "Earlier"), probe: ProbeResult(hasVideo: true), index: nil)
        _ = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: w.a), control: IngestControl()) { _ in }
        w.plugged.now = [(w.cardVolume, .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        let live = w.drive(w.driveA)
        live.setup = ShootPlanner.presets()[0].setup
        w.model.use(drive: live)
        let c = w.model.cards[0]
        await w.until("the check") { !live.isScanning && !c.isMatching && c.phase == .ready && c.filesToGo == 1 }
        #expect(CardSheet.make(c, model: w.model).bottom.action == .copy(2), "a new folder gets the whole card")
    }

    @Test func `A second card isn't offered the first card's folder`() async throws {
        let w = Bench()
        let marker = rnd(1_382_400)
        put(w.card + "/AVF_INFO/AVIN0001.BNP", marker); put(w.card + "/DCIM/C0001.JPG", rnd(2_000_000))
        let first = await w.safe()
        #expect(first.isSafe(on: w.model.workingDrive))
        let second = temp()
        put(second + "/AVF_INFO/AVIN0001.BNP", marker); put(second + "/DCIM/C0002.JPG", rnd(2_000_000))
        let live = w.drive(w.driveA)
        live.setup = ShootPlanner.presets()[0].setup
        w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive), (volume(second, "SECOND"), .card)]
        await w.model.refresh()
        let c = try #require(w.model.cards.first { $0 !== first })
        await w.until("the check") { !c.isMatching && c.phase == .ready && c.filesToGo == 1 }
        #expect(c.existingHome == nil, "\(String(describing: c.existingHome))")
        #expect(CardSheet.make(c, model: w.model).existingShoot == nil)
    }

    @Test func `Add to keeps a card's stills where they went`() async throws {
        let w = Bench()
        mixedCard(w)
        put(w.card + "/CLIP/B.MP4", rnd(2_000_000))
        let read = CardReader.read(root: w.card) { CardProber.kind(ofRelativePath: $0) }
        let job = Pipeline.makeJob(read: read, states: [:], cardName: "C", driveRoot: w.a, camera: nil, destination: Destination(footageRoot: "Foot/A", stillsRoot: "Stills/A"),
                                   probe: ProbeResult(hasVideo: true, hasStills: true), index: nil)
        _ = try IngestEngine.run(job: job, ledger: Ledger(driveRoot: w.a), control: IngestControl()) { _ in }
        put(w.card + "/CLIP/C.MP4", rnd(2_000_000))     // what's left of this card
        let c = await w.ready()
        await w.until("the check") { !c.isMatching && c.phase == .ready && c.filesToGo == 1 }
        w.model.add(c, to: try #require(c.existingHome))
        await w.until("the copy") { !c.isBusy && c.filesToGo == 0 }
        #expect(FileManager.default.fileExists(atPath: w.a + "/Foot/A/CLIP/C.MP4"))
        #expect(!FileManager.default.fileExists(atPath: w.a + "/Foot/A/DCIM/A.JPG"), "it's already at its place, under Stills")
    }

    // A job can see the drive go, and stop, before the app has looked at all.
    @Test func `A card pulled after its job stopped for the drive keeps its warning`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card), (w.driveB, .drive)]
        await w.model.refresh()
        await w.until("it to stop") { c.phase == .stopped }
        c.volume.anchor?.retire()
        w.plugged.now = [(w.driveB, .drive)]
        await w.model.refresh()
        #expect(w.model.cards.contains { $0 === c }, "the session goes, and the warning with it")
        #expect(c.volumeGone)
    }

    @Test func `A look landing after a card is pulled can't bring back what needs the card`() async throws {
        let w = Bench()
        let c = await w.ready()
        c.pendingDestination = Destination(footageRoot: "S"); c.destinationPath = "S"
        let gate = Dying()
        w.model.lookLandsLate = { _ in while !gate.now { try? await Task.sleep(for: .milliseconds(5)) } }
        Task { await w.model.matchCard(c) }
        try await Task.sleep(for: .milliseconds(200))
        c.volume.anchor?.retire()
        w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        gate.now = true
        await w.until("the look") { !c.isMatching }
        try await Task.sleep(for: .milliseconds(100))
        w.model.lookLandsLate = nil
        #expect(c.phase == .stopped, "\(c.phase)")
        #expect(CardSheet.make(c, model: w.model).line(.drive)?.actions == [.dismiss])
    }

    @Test func `A job that fails with the card gone keeps the card's warning`() async throws {
        let w = Bench()
        let c = await w.ready()
        try FileManager.default.createDirectory(atPath: w.a + "/.ingest/ledger", withIntermediateDirectories: true)
        chmod(w.a + "/.ingest/ledger", 0o555)       // the job can't open its record, so it throws
        defer { chmod(w.a + "/.ingest/ledger", 0o755) }
        let pulled = "CARD was removed while copying."
        w.model.start(c, destination: Destination(footageRoot: "S"))
        c.volumeGone = true; c.error = pulled
        await w.until("the job to fail") { !c.isBusy }
        #expect(c.error == pulled, "\(String(describing: c.error))")
        #expect(c.phase == .stopped, "\(c.phase)")
    }

    @Test func `A queued card isn't told to plug in a drive that's plugged in`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let other = temp()
        put(other + "/x.bin", rnd(1000))
        let otherVolume = volume(other, "OTHER")
        w.plugged.now = [(w.cardVolume, .card), (otherVolume, .card), (w.driveA, .drive)]
        await w.model.refresh()
        #expect(w.model.accept(setup: ShootPlanner.presets()[0].setup, for: w.drive(w.driveA)) == nil)     // a set-up drive is chosen again at once
        let c = try #require(w.model.cards.first { $0.volume.path == w.card })
        let o = try #require(w.model.cards.first { $0 !== c })
        await w.until("both cards") { o.phase == .ready && !o.isMatching && c.phase == .ready && !c.isMatching }
        w.model.start(c, destination: Destination(footageRoot: "A"))
        w.model.start(o, destination: Destination(footageRoot: "B"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card), (otherVolume, .card)]
        await w.model.refresh()
        let back = volume(w.a, "DRIVE-A")
        w.model.stores.workingDriveKey = back.key
        w.plugged.now = [(w.cardVolume, .card), (otherVolume, .card), (back, .drive)]
        await w.model.refresh()
        await w.until("both idle") { !c.isBusy && !o.isBusy }
        try await Task.sleep(for: .milliseconds(300))
        #expect(o.error == nil, "\(String(describing: o.error))")
    }

    @Test func `A queued card hears the drive went, and forgets it when it's back`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let other = temp()
        put(other + "/x.bin", rnd(1000))
        let otherVolume = volume(other, "OTHER")
        w.plugged.now = [(w.cardVolume, .card), (otherVolume, .card), (w.driveA, .drive)]
        await w.model.refresh()
        w.model.use(drive: w.drive(w.driveA))
        let c = try #require(w.model.cards.first { $0.volume.path == w.card })
        let o = try #require(w.model.cards.first { $0 !== c })
        await w.until("both cards") { o.phase == .ready && !o.isMatching && c.phase == .ready && !c.isMatching }
        w.model.start(c, destination: Destination(footageRoot: "A"))
        w.model.start(o, destination: Destination(footageRoot: "B"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card), (otherVolume, .card)]
        await w.model.refresh()
        await w.until("both stopped") { !c.isBusy && !o.isBusy }
        #expect(o.error == "Plug in your working drive to carry on.", "\(String(describing: o.error))")
        #expect(w.model.notified.contains("Don't format OTHER"), "\(w.model.notified)")
        let back = volume(w.a, "DRIVE-A")
        w.model.stores.workingDriveKey = back.key
        w.plugged.now = [(w.cardVolume, .card), (otherVolume, .card), (back, .drive)]
        await w.model.refresh()
        #expect(o.error == nil, "\(String(describing: o.error))")
    }

    @Test func `A saved drive turning up during a job doesn't take away what that job proved`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        w.plugged.now = [(w.cardVolume, .card), (w.driveA, .drive)]
        await w.model.refresh()
        w.model.use(drive: w.drive(w.driveA))
        let c = w.model.cards[0]
        await w.until("the card to settle") { c.phase == .ready && !c.isMatching }
        w.model.stores.workingDriveKey = w.driveB.key       // the drive it would rather have, not plugged in yet
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.plugged.now = [(w.cardVolume, .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()                             // seen while the job runs, so it has to wait
        await w.until("the copy") { !c.isBusy && c.phase == .finished }
        #expect(w.model.workingDrive?.path == w.a, "the card is Safe here, and nothing has looked since")
        #expect(c.isSafe(on: w.model.workingDrive))
    }

    @Test func `A drive that came back during a job is chosen when the job's done`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        w.plugged.now = [(w.cardVolume, .card), (w.driveA, .drive)]
        await w.model.refresh()
        w.model.use(drive: w.drive(w.driveA))
        let c = w.model.cards[0]
        await w.until("the card to settle") { c.phase == .ready && !c.isMatching }
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card)]
        await w.model.refresh()
        let back = volume(w.a, "DRIVE-A")
        w.plugged.now = [(w.cardVolume, .card), (back, .drive)]
        await w.model.refresh()                             // it can't be chosen while the job is still unwinding
        #expect(c.isBusy, "the job has to be running for this to mean anything")
        await w.until("the job to stop") { !c.isBusy }
        await w.until("the drive to be chosen") { w.model.workingDrive?.path == w.a }
    }

    @Test func `Only a copy that's really bad is called bad`() async throws {
        let w = Bench()
        let c = await w.ready()
        w.drive(w.driveA).setup = ShootPlanner.presets()[0].setup
        c.pendingDestination = Destination(footageRoot: "S"); c.destinationPath = "S"
        let hint = "Choose another folder, or remove the bad copy and copy again."
        func detail() -> [String] { CardSheet.make(c, model: w.model).line(.readDrive)?.detail ?? [] }
        c.states["one.bin"] = .failed("the copy on the drive doesn't match the card")
        #expect(detail().contains(hint))
        c.states["one.bin"] = .failed("the copy didn't match the card")     // the job's own read-back, so nothing is on the drive
        #expect(!detail().contains(hint), "\(detail())")
        c.states["one.bin"] = .failed("checking failed: Input/output error")
        #expect(!detail().contains(hint), "\(detail())")
        #expect(detail().first == "one.bin couldn't be read back, from the card or the drive.", "\(detail())")
        c.states["one.bin"] = .failed("the copy on the drive doesn't match the card")
        c.phase = .stopped
        #expect(!detail().contains(hint), "there's no button for it on a stopped card")
    }

    @Test func `A failed file keeps the Copy button, for the whole card`() async throws {
        let w = Bench()
        let c = await w.ready()
        w.drive(w.driveA).setup = ShootPlanner.presets()[0].setup
        c.states["one.bin"] = .failed("couldn't put the file in place")
        c.states["two.bin"] = .verified(drivePath: "S/two.bin", hash: "1", bytes: 1)
        #expect(CardSheet.make(c, model: w.model).bottom.action == .copy(2))
    }

    @Test func `A file in the way says what to do`() async throws {
        let w = Bench()
        let c = await w.ready()
        w.drive(w.driveA).setup = ShootPlanner.presets()[0].setup
        c.pendingDestination = Destination(footageRoot: "S"); c.destinationPath = "S"
        c.states["one.bin"] = .failed("a different file already has that name on the drive")
        let detail = CardSheet.make(c, model: w.model).line(.drive)?.detail ?? []
        #expect(detail.contains("Choose another folder, or remove that file if it's a bad copy, and copy again."), "\(detail)")
    }

    @Test func `A card that's out isn't still to check`() async throws {
        let w = Bench()
        let c = await w.ready()
        c.states["one.bin"] = .likely(drivePath: "S/one.bin")
        c.phase = .stopped
        c.volumeGone = true
        let foot = CardSheet.make(c, model: w.model).bottom.sentence
        #expect(foot == "Stopped. 2 files not proved yet.", "\(foot)")
    }

    @Test func `A drive pulled during a copy tells someone`() async throws {
        let w = Bench()
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        w.driveA.anchor?.retire()
        w.plugged.now = [(w.cardVolume, .card), (w.driveB, .drive)]
        await w.model.refresh()
        await w.until("it to stop") { !c.isBusy }
        #expect(w.model.notified.contains { $0.contains("Don't format") }, "\(w.model.notified)")
    }

    /// A copy under way, with the card pulled from under it.
    private func cardPulledMidCopy(_ w: Bench) async -> CardSession {
        put(w.card + "/big.bin", rnd(400_000_000))
        let c = await w.ready()
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("copying") { c.phase == .copying && (c.progress?.verifiedFiles ?? 0) >= 1 }
        c.volume.anchor?.retire()
        w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        return c
    }

    // The warning went about a second after the job stopped, and the widget said no card was ever there.
    @Test func `A pulled card's warning stays after the job stops`() async throws {
        let w = Bench()
        let c = await cardPulledMidCopy(w)
        await w.until("the job to stop") { !c.isBusy }
        try await Task.sleep(for: .milliseconds(600))      // past the look the job's end asks for
        await w.model.refresh()
        #expect(w.model.cards.contains { $0 === c }, "the session has to outlive the job")
        #expect(c.volumeGone)
        #expect(MenuBarState.make(w.model).word == "Card pulled", "\(MenuBarState.make(w.model).word)")
        #expect(w.model.notified.contains { $0.contains("Don't format") }, "and anyone not watching gets told: \(w.model.notified)")
    }

    @Test func `A pulled card can be dismissed, and goes when it's back`() async throws {
        let w = Bench()
        let c = await cardPulledMidCopy(w)
        await w.until("the job to stop") { !c.isBusy }
        #expect(CardSheet.make(c, model: w.model).line(.drive)?.actions == [.dismiss])
        w.plugged.now = [(volume(w.card, "CARD"), .card), (w.driveA, .drive), (w.driveB, .drive)]
        await w.model.refresh()
        #expect(w.model.cards.first.map { $0 !== c } == true, "the card itself is the best dismissal")
        let again = try #require(w.model.cards.first)
        again.volume.anchor?.retire()
        w.plugged.now = [(w.driveA, .drive), (w.driveB, .drive)]
        let second = await cardPulledAgain(w, again)
        w.model.dismiss(second)
        #expect(w.model.cards.isEmpty)
    }

    private func cardPulledAgain(_ w: Bench, _ c: CardSession) async -> CardSession {
        c.volumeGone = true
        c.phase = .stopped
        w.model.cards = [c]
        await w.model.refresh()
        return c
    }

    // Setup covered the reason, at the one moment a new tester needs it.
    @Test func `Setup says why a plugged-in drive can't be used`() async {
        let w = Bench()
        var ntfs = volume(w.a, "NTFS"); ntfs.isReadOnly = true
        w.plugged.now = [(ntfs, .ignored)]
        await w.model.refresh()
        let foot = CardSheet.waitingForDrive(model: w.model)
        #expect(foot.sentence.contains("NTFS") && foot.sentence.contains("read-only"), "\(foot.sentence)")
        w.plugged.now = []
        await w.model.refresh()
        #expect(CardSheet.waitingForDrive(model: w.model).sentence == "It's where your footage goes.")
    }

    @Test func `First-run setup waits for a volume it has to ask about`() async {
        let w = Bench()
        var met = false
        w.model.onFirstLook = { met = true }
        w.plugged.now = [(w.driveA, .maybeCard("Camera folders next to 3 other folders"))]
        await w.model.refresh()
        #expect(!met)
        w.plugged.now = [(w.driveA, .drive)]
        await w.model.refresh()
        #expect(met)
    }

    // Every re-inserted card now takes this path, and it can be long.
    @Test func `A check keeps the Mac awake, can be stopped, and says when it's done`() async throws {
        let w = Bench()
        let c = await w.safe()
        w.model.recheck(c)
        var awake = false
        await w.until("Safe again") {
            awake = awake || w.model.isKeepingAwake
            return c.isSafe(on: w.model.workingDrive)
        }
        #expect(awake)
        #expect(!w.model.isKeepingAwake, "and lets it sleep after")
        #expect(w.model.notified.filter { $0.contains("safe to format") }.count == 2, "\(w.model.notified)")
        c.phase = .checking(done: 0, total: 2)
        #expect(CardSheet.make(c, model: w.model).bottom.action == .stop)
        c.phase = .finished
    }

    @Test func `A stopped check says so, and Resume starts it again`() async throws {
        let w = Bench()
        let c = await w.safe()
        w.model.recheck(c)
        c.control.stop()
        await w.until("it to stop") { c.phase == .stopped }
        let sheet = CardSheet.make(c, model: w.model)
        #expect(sheet.bottom.sentence.hasPrefix("Stopped.") && sheet.bottom.sentence.contains("to check"), "\(sheet.bottom.sentence)")
        #expect(sheet.line(.drive)?.actions == [.resume])
        w.model.resume(c)
        await w.until("Safe again") { c.isSafe(on: w.model.workingDrive) }
    }

    @Test func `A plugged-in drive that isn't offered says why`() async {
        let w = Bench()
        var read = volume(w.a, "NTFS"); read.isReadOnly = true
        w.plugged.now = [(read, .ignored)]
        await w.model.refresh()
        #expect(w.model.ignored.map(\.name) == ["NTFS"])
        #expect(CardSheet.idle(model: w.model).sentence.contains("read-only"))
    }

    @Test func `Safe says which of two drives with one name`() async {
        let w = Bench()
        let first = temp() + "/SHOOT SSD", second = temp() + "/SHOOT SSD 1"
        try! FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        let one = volume(first, "ONE", name: "SHOOT SSD"), two = volume(second, "TWO", name: "SHOOT SSD")
        w.plugged.now = [(w.cardVolume, .card), (one, .drive), (two, .drive)]
        await w.model.refresh()
        let c = w.model.cards[0]
        w.model.use(drive: w.drive(two))
        await w.until("the card") { c.phase == .ready && !c.isMatching }
        w.model.start(c, destination: Destination(footageRoot: "S"))
        await w.until("Safe") { c.isSafe(on: w.model.workingDrive) }
        #expect(MenuBarState.make(w.model).spoken.contains("SHOOT SSD 1"))
        #expect(w.model.notified.last?.isEmpty == false)
    }

    @Test func `A settled card can always be read again`() async {
        let w = Bench()
        let c = await w.safe()
        #expect(w.model.cardsToCheckAgain.contains { $0 === c })
    }

    @Test func `An unchanged card reads nothing again when someone looks`() async {
        let w = Bench()
        let c = await w.safe()
        let proved = c.proved, read = c.control.bytesChecked
        w.model.lookAgain()
        await w.model.matchCard(c)
        await w.until("it to settle") { !c.isMatching }
        #expect(c.control.bytesChecked == read, "nothing was read in full")
        #expect(c.isSafe(on: w.model.workingDrive) && c.proved == proved)
    }

    @Test func `Recheck reads both sides again`() async {
        let w = Bench()
        let c = await w.safe()
        w.model.recheck(c)
        #expect(c.proved.isEmpty && !c.isSafe(on: w.model.workingDrive))
        await w.until("Safe again") { c.isSafe(on: w.model.workingDrive) }
        #expect(c.control.bytesChecked == 2_000_000)
    }

    // Folder Setup could change the drive under a running job.
    @Test func `The working drive can't change under a job`() async {
        let w = Bench()
        let c = await w.ready()
        let a = w.model.workingDrive
        c.phase = .queued
        w.model.use(drive: w.drive(w.driveB))
        #expect(w.model.workingDrive === a)
        c.phase = .ready
    }

    @Test func `With no drive, a card that can't be listed isn't empty`() async {
        let w = Bench()
        let gone = "/tmp/ingest-no-such-card-" + UUID().uuidString
        let c = CardSession(volume: volume(w.card, "GONE"))
        c.read = CardReader.read(root: gone) { _ in .video }
        w.model.cards = [c]
        await w.model.matchCard(c)
        #expect(c.verdict != .empty && c.verdict != .safe && c.verdict != nil)
        #expect(c.phase != .finished)
    }

    @Test func `With no drive, an empty card is empty`() async {
        let w = Bench()
        let c = CardSession(volume: volume(temp(), "BLANK"))
        c.read = CardReader.read(root: c.volume.path) { _ in .video }
        w.model.cards = [c]
        await w.model.matchCard(c)
        #expect(c.verdict == .empty)
    }

    @Test func `Two drives with one name stay two drives`() async {
        let w = Bench()
        let first = temp() + "/SHOOT SSD", second = temp() + "/SHOOT SSD 1"
        try! FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        w.plugged.now = [(w.cardVolume, .card), (volume(first, "ONE", name: "SHOOT SSD"), .drive), (volume(second, "TWO", name: "SHOOT SSD"), .drive)]
        await w.model.refresh()
        let c = w.model.cards[0]
        await w.until("the card") { c.phase == .ready }
        let actions = CardSheet.make(c, model: w.model).line(.drive)?.actions ?? []
        #expect(Set(actions).count == 2 && Set(actions.map(\.title)).count == 2, "\(actions)")
        let ids = actions.compactMap { a -> String? in if case .useDrive(let id, _) = a { id } else { nil } }
        #expect(Set(ids) == Set(w.model.drives.map(\.id)))
    }

    @Test func `Safe names the drive however long its name is`() async {
        let w = Bench()
        w.driveA.name = "Samsung SSD Projects"
        let c = await w.safe()
        let sheet = CardSheet.make(c, model: w.model)
        #expect(sheet.line(.drive)?.detail.contains("Samsung SSD Projects") == true)
        #expect(MenuBarState.make(w.model).spoken.contains("Samsung SSD Projects"))
    }

    // A menu bar out of room hides the item, and that can be the only way back in.
    @Test func `A long drive name stays out of the menu bar`() async {
        let w = Bench()
        w.driveA.name = "Samsung SSD Projects"
        _ = await w.ready()
        #expect(MenuBarState.make(w.model).word == "Not on drive")
        #expect(MenuBarState.make(w.model).spoken.contains("Don't format"))
    }

    @Test func `First-run setup waits while a volume can't be read`() async {
        let w = Bench()
        var met = false
        w.model.onFirstLook = { met = true }
        w.plugged.now = [(w.driveA, .unreadable)]
        await w.model.refresh()
        #expect(!met && w.model.unreadable.count == 1)
        w.plugged.now = [(w.driveA, .drive)]
        await w.model.refresh()
        #expect(met)
    }

    @Test func `A setup that can't be saved says so, and why`() async throws {
        let w = Bench()
        _ = await w.ready()
        let d = w.drive(w.driveB)
        let setup = ShootPlanner.presets()[0].setup
        try "not a folder".write(toFile: w.b + "/.ingest", atomically: true, encoding: .utf8)
        #expect(w.model.accept(setup: setup, for: d) != nil)
        #expect(d.setup == nil)
        try FileManager.default.removeItem(atPath: w.b + "/.ingest")
        var bad = setup
        bad.path = [.literal("../elsewhere")]
        #expect(w.model.accept(setup: bad, for: d) != nil)
        #expect(!FileManager.default.fileExists(atPath: w.b + "/.ingest/setup.json"))
        #expect(w.model.accept(setup: setup, for: d) == nil)
        #expect(d.setup == setup)
    }

    @Test func `A setup on a drive that leads off it counts as none`() throws {
        let w = Bench()
        var setup = ShootPlanner.presets()[0].setup
        setup.path = [.literal("../card/escaped")]
        put(w.a + "/.ingest/setup.json", try JSONEncoder().encode(setup))
        #expect(Stores.setup(onDrive: w.a) == nil)
    }

    @Test func `Two cards named for one shoot don't share a folder, even in the queue`() async {
        let w = Bench()
        let other = temp()
        put(other + "/three.bin", rnd(1_000_000))
        w.plugged.now = [(w.cardVolume, .card), (volume(other, "CARD2"), .card), (w.driveA, .drive)]
        await w.model.refresh()
        let d = w.drive(w.driveA)
        d.setup = ShootPlanner.presets()[0].setup
        w.model.use(drive: d)
        let cards = w.model.cards
        await w.until("both cards") { cards.allSatisfy { $0.phase == .ready && !$0.isMatching } }
        func compose(_ c: CardSession) -> ShootComposer {
            c.probe.reel = "A001"
            c.draft.client = "Client"; c.draft.shootName = "Shoot"; c.draft.cameraFolder = "FX3"
            return ShootComposer(model: w.model, card: c, drive: d, setup: d.setup!)
        }
        let first = compose(cards[0]).plan
        w.model.createShoot(cards[0], plan: first, cameraFolder: "FX3", chosenDay: CalendarDay(Date()))
        let second = compose(cards[1]).plan
        #expect(first.footagePath != second.footagePath)
        w.model.start(cards[1], destination: Destination(footageRoot: first.footagePath))
        #expect(cards[1].error != nil, "and the engine's door is shut too")
        await w.until("the first copy") { !cards[0].isBusy }
    }

    @Test func `A long reel name keeps its number`() async {
        let w = Bench()
        let c = await w.ready()
        let d = w.drive(w.driveA)
        d.setup = ShootPlanner.presets()[0].setup
        c.probe.reel = String(repeating: "A", count: 300)
        c.draft.client = "Client"; c.draft.shootName = "Shoot"; c.draft.cameraFolder = "FX3"
        let composer = ShootComposer(model: w.model, card: c, drive: d, setup: d.setup!)
        let first = composer.plan
        try! FileManager.default.createDirectory(atPath: d.path + "/" + first.footagePath, withIntermediateDirectories: true)
        #expect(composer.plan.footagePath != first.footagePath)
    }
}
