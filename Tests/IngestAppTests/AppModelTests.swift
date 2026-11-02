// The real AppModel, against real files in folders. Volumes are handed in, so no test ever looks at what's plugged in.
import Foundation
import Testing
@testable import IngestApp
@testable import IngestCore

private let setUp: Void = { setenv("INGEST_SUPPORT_DIR", NSTemporaryDirectory() + "ingest-app-tests-" + UUID().uuidString, 1) }()

private func temp() -> String {
    let p = NSTemporaryDirectory() + "ingest-app-test-" + UUID().uuidString
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
    // The review's A-02, B01 and C02.
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

    // The review's C03.
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

    // The review's A-07, B02 and C04.
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
        #expect(c.states["one.bin"] == .missing)
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

    // The review's B01: Folder Setup could change the drive under a running job.
    @Test func `The working drive can't change under a job`() async {
        let w = Bench()
        let c = await w.ready()
        let a = w.model.workingDrive
        c.phase = .queued
        w.model.use(drive: w.drive(w.driveB))
        #expect(w.model.workingDrive === a)
        c.phase = .ready
    }

    // The review's C15.
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

    // The review's B03.
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

    // The review's B04.
    @Test func `Safe names the drive however long its name is`() async {
        let w = Bench()
        w.driveA.name = "Samsung SSD Projects"
        let c = await w.safe()
        let sheet = CardSheet.make(c, model: w.model)
        #expect(sheet.line(.drive)?.detail.contains("Samsung SSD Projects") == true)
        #expect(MenuBarState.make(w.model).spoken.contains("Samsung SSD Projects"))
    }

    // The review's B12: a menu bar out of room hides the item, and that can be the only way back in.
    @Test func `A long drive name stays out of the menu bar`() async {
        let w = Bench()
        w.driveA.name = "Samsung SSD Projects"
        _ = await w.ready()
        #expect(MenuBarState.make(w.model).word == "Not on drive")
        #expect(MenuBarState.make(w.model).spoken.contains("Don't format"))
    }

    // The review's B05.
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

    // The review's B06.
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

    // The review's C05.
    @Test func `A setup on a drive that leads off it counts as none`() throws {
        let w = Bench()
        var setup = ShootPlanner.presets()[0].setup
        setup.path = [.literal("../card/escaped")]
        put(w.a + "/.ingest/setup.json", try JSONEncoder().encode(setup))
        #expect(Stores.setup(onDrive: w.a) == nil)
    }

    // The review's C12.
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
