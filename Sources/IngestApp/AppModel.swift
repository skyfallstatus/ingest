import AppKit
import Foundation
import IngestCore
import Observation
import UserNotifications

/// A working drive and everything known about it.
@MainActor @Observable final class DriveState: Identifiable {
    let volume: Volume
    let ledger: Ledger
    var setup: DriveSetup?
    var index: DriveIndex?
    var clients: [ClientFolder] = []
    var isScanning = false
    var foldersRead = 0
    var scanWaiters: [@MainActor () -> Void] = []
    private var folders: [String: String] = [:]     // match key of a path → spelling on the drive

    var id: String { volume.id }
    var name: String { volume.name }
    var path: String { volume.path }

    init(volume: Volume, ledger: Ledger, setup: DriveSetup?) { self.volume = volume; self.ledger = ledger; self.setup = setup }

    func install(index: DriveIndex) {
        self.index = index
        var map: [String: String] = [:]
        map.reserveCapacity(index.folderCount)
        for e in index.entries where e.isDir { map[matchKey(e.path)] = e.path }
        folders = map
        if let setup { clients = LayoutLearner.clients(in: setup, entries: index.entries) }
    }

    /// Spelling of a folder on the drive, or nil. The index can be stale, so the disk has the last word.
    func existing(_ rel: String) -> String? {
        if let hit = folders[matchKey(rel)] { return hit }
        var st = stat()
        return lstat(path + "/" + rel, &st) == 0 ? rel : nil
    }
}

/// What's been typed into the shoot row. It belongs to the card, so a rematch or a reorder never loses it.
@MainActor @Observable final class ShootDraft {
    var client = ""
    var shootName = ""
    var date = Date()
    var cameraFolder = ""
    var prefilled = false
}

@MainActor @Observable final class CardSession: Identifiable {
    enum Phase: Equatable {
        case reading(done: Int, total: Int)
        case checking(done: Int, total: Int)
        case ready
        case queued
        case copying
        case stopped
        case finished
    }

    let volume: Volume
    var name: String
    var phase: Phase = .reading(done: 0, total: 0)
    var read: CardRead?
    var states: [String: FileState] = [:]
    var probe = ProbeResult()
    var verdict: CardVerdict?
    var issues: [CardIssue] = []
    var progress: IngestProgress?
    var startedAt: Date?
    var destinationPath: String?        // drive-relative, where this card went
    var pendingDestination: Destination?
    var extraFolders: [String] = []
    var isMatching = false
    var proved: [String: Proof] = [:]   // read in full on both sides, in this run of the app, on this drive
    var provedDriveKey: String?
    var weak = false
    var volumeGone = false
    var needsRematch = false
    var cameraFolder: String?
    var error: String?
    var ejectError: String?
    var ejected = false                 // out, and still on screen for the moment it takes to say so
    var liveBytes: UInt64 = 0
    var liveChecked: UInt64 = 0
    var checkBytes: UInt64 = 0          // what the running check has to read
    var checkStarted: Date?
    var existingHome: String?
    var shootLabel: String?             // "Lantern Bakery Co. · 22.10.26 Spring menu", once it's been named
    let draft = ShootDraft()
    let control = IngestControl()

    let id = UUID()     // a card pulled mid-copy can sit beside its own remount, so the volume can't be the identity
    init(volume: Volume) { self.volume = volume; self.name = Self.friendlyName(volume.name) }

    static let genericNames: Set<String> = ["NO NAME", "UNTITLED", "EOS_DIGITAL", "NIKON", "CANON", "SD CARD", "SDCARD", "MEMORY CARD", "LUMIX", "SONY"]
    static func friendlyName(_ n: String) -> String { genericNames.contains(n.uppercased()) ? "Card" : n }

    var totalFiles: Int { read?.listing.files.count ?? 0 }
    var totalBytes: UInt64 { read?.listing.totalBytes ?? 0 }
    /// Proved so far, counting the running job, so the number falls as each file is proved.
    var verifiedFiles: Int {
        let settled = states.values.reduce(0) { if case .verified = $1 { $0 + 1 } else { $0 } }
        return phase == .copying ? settled + (progress?.verifiedFiles ?? 0) : settled
    }
    var filesToGo: Int { max(0, totalFiles - verifiedFiles) }
    var primaryCamera: CameraOnCard? { probe.cameras.first }
    var isBusy: Bool { phase == .copying || phase == .queued }

    /// The verdict alone. Anything that can turn green goes through `isSafe(on:)`.
    var isSafe: Bool { verdict == .safe }
    var isHold: Bool { if case .hold? = verdict { true } else { false } }
    var isEmpty: Bool { verdict == .empty }
    var failureReasons: [String] {
        if case .notSafe(_, _, let why)? = verdict { return why }
        return []
    }
    /// The only reading of the verdict that may turn anything green: concluded, current, and about this drive.
    func isSafe(on drive: DriveState?) -> Bool {
        verdict == .safe && phase == .finished && provedDriveKey != nil && provedDriveKey == drive?.volume.key
    }

    /// Keeps what these states prove, tied to the files as this read saw them.
    func keepProof(of found: [String: FileState], read: CardRead) {
        let files = Dictionary(read.listing.files.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        for (rel, state) in found {
            if case .verified = state, let file = files[rel], let quick = read.quick[rel] {
                proved[rel] = Proof(state: state, file: file, quick: quick)
            }
        }
    }
}

/// What a card proved in this run of the app, so a remount doesn't read it all again. Never written down.
struct RememberedProof {
    var proved: [String: Proof]
    var driveKey: String
    var weak: Bool
    var taken = Date()
    /// A menu bar app can run for weeks. A read from another day isn't this session's.
    var isFresh: Bool { Date().timeIntervalSince(taken) < 12 * 3600 }
}

@MainActor @Observable final class AppModel {
    var cards: [CardSession] = []
    var drives: [DriveState] = []
    var maybeCards: [(volume: Volume, reason: String)] = []
    var unreadable: [Volume] = []
    var workingDrive: DriveState?
    var history: [HistoryEntry] = []
    var cameraMemory: [String: CameraMemory] = [:]

    let stores = Stores()
    let loginItem = LoginItem()
    let updates = UpdateChecker()
    private let watcher = VolumeWatcher()
    private var queue: [CardSession] = []
    private var queueRunning = false
    private var sleepToken: NSObjectProtocol?
    private var refreshPending = false
    private var announced: Set<String> = []     // what's already had its moment on screen
    private var remembered: [String: RememberedProof] = [:]     // by card volume
    private var askedPermission = false
    var isDemo = false
    var opensOnCardIn = true { didSet { stores.opensOnCardIn = opensOnCardIn } }
    var checksForUpdates = false { didSet { stores.checksForUpdates = checksForUpdates } }
    private(set) var hasVolumeChoices = false   // an "It's a Card" or "It's a Drive" there is to take back
    /// Something new needs a person: a card, or a volume that can't be decided alone.
    var onArrival: (@MainActor () -> Void)?
    /// The first look at the volumes has landed: a new person meets setup, nobody else does.
    var onFirstLook: (@MainActor () -> Void)?
    var onEjected: (@MainActor () -> Void)?

    func start() {
        hasVolumeChoices = !stores.overrides.isEmpty
        history = stores.history
        opensOnCardIn = stores.opensOnCardIn
        checksForUpdates = stores.checksForUpdates
        cameraMemory = stores.cameras
        watcher.onChange = { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
        watcher.start()
        scheduleRefresh()
    }

    /// Asked just after the first copy starts, so a new person doesn't meet a second system prompt at launch.
    private func askForNotifications() {
        guard !askedPermission, !isDemo, Bundle.main.bundleIdentifier != nil else { return }  // the service exists only inside a bundle
        askedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))  // a mount comes as a burst of events
            refreshPending = false
            await refresh()
        }
    }

    func refresh() async {
        let allow = stores.allowDiskImages, overrides = stores.overrides
        let found: [(Volume, VolumeRole)] = await Task.detached(priority: .userInitiated) {
            VolumeWatcher.scan(allowDiskImages: allow).map { ($0, VolumeWatcher.role(of: $0, overrides: overrides)) }
        }.value

        let live = Set(found.map(\.0.path))
        // A card pulled out mid-copy stays on screen: someone needs to hear about it.
        for c in cards where !live.contains(c.volume.path) && !c.ejected {
            // The reads can fail before this hears the card has gone, so a copy that has just ended short counts too.
            let cutShort = c.phase == .ready && c.pendingDestination != nil && c.filesToGo > 0
            if c.phase == .copying || cutShort {
                c.error = "\(c.name) was removed while copying. Nothing already checked is lost: put it back in to finish."
                c.volumeGone = true
                c.verdict = nil
                c.control.stop()
                if cutShort { c.phase = .stopped }
            } else { queue.removeAll { $0 === c }; cards.removeAll { $0 === c } }
        }
        drives.removeAll { d in
            let gone = !live.contains(d.path)
            if gone && d === workingDrive {
                for c in cards where c.isBusy { c.control.stop(); c.error = "\(d.name) was unplugged. Plug it back in to finish." }
            }
            return gone
        }
        if let w = workingDrive, !live.contains(w.path) {
            workingDrive = nil
            for c in cards where !c.isBusy { finishMatch(c) }   // no drive, no green
        }
        maybeCards = found.compactMap { v, r in if case .maybeCard(let why) = r { (v, why) } else { nil } }
        unreadable = found.compactMap { v, r in r == .unreadable ? v : nil }

        for (v, role) in found where role == .drive && !drives.contains(where: { $0.path == v.path }) {
            let setup = stores.setup(onDrive: v.path)
            let d = DriveState(volume: v, ledger: Ledger(driveRoot: v.path), setup: setup)
            drives.append(d)
            loadCachedIndex(d)
            refreshIndex(d)
        }
        chooseWorkingDrive()
        // Whatever mounts at a path may be a different card, so a session never outlives its volume.
        cards.removeAll { c in
            !c.isBusy && found.contains { $0.0.path == c.volume.path && ($0.0.key != c.volume.key || c.volumeGone) }
        }
        var arrived = false
        for (v, role) in found where role == .card && !cards.contains(where: { $0.volume.path == v.path }) {
            let c = CardSession(volume: v)
            if let memory = remembered[v.key], memory.isFresh {
                c.proved = memory.proved; c.provedDriveKey = memory.driveKey; c.weak = memory.weak
            }
            cards.append(c)
            arrived = true
            Task { await self.readCard(c) }
        }
        let waiting = Set(maybeCards.map(\.volume.key) + unreadable.map(\.key))
        if arrived || !waiting.subtracting(announced).isEmpty { onArrival?() }
        announced = waiting
        if let first = onFirstLook { onFirstLook = nil; first() }
    }

    private func chooseWorkingDrive() {
        // The saved drive always wins when it turns up, unless a copy is running.
        if let k = stores.workingDriveKey, workingDrive?.volume.key != k, !isCopying,
           let hit = drives.first(where: { $0.volume.key == k }) {
            workingDrive = hit; rematchAll(); return
        }
        if workingDrive != nil { return }
        // A drive that isn't set up is never chosen silently: it could be camera media nobody recognised.
        if let hit = drives.first(where: { $0.setup != nil }) { workingDrive = hit; rematchAll() }
    }

    func use(drive: DriveState) {
        workingDrive = drive
        stores.workingDriveKey = drive.volume.key
        rematchAll()
    }

    func setRole(_ role: String, for v: Volume) {
        stores.overrides[v.key] = role
        hasVolumeChoices = true
        scheduleRefresh()
    }

    func hasChosenRole(for v: Volume) -> Bool { stores.overrides[v.key] != nil }

    /// Takes back "It's a Card" or "It's a Drive", so the volume is asked about again.
    func forgetChoice(for v: Volume) {
        stores.overrides[v.key] = nil
        hasVolumeChoices = !stores.overrides.isEmpty
        release(v)
        scheduleRefresh()
    }

    private func release(_ v: Volume) {
        cards.removeAll { $0.volume.key == v.key && !$0.isBusy }
        guard !isCopying, let d = drives.first(where: { $0.volume.key == v.key }) else { return }
        drives.removeAll { $0 === d }
        guard workingDrive === d else { return }
        workingDrive = nil
        if stores.workingDriveKey == v.key { stores.workingDriveKey = nil }
        for c in cards where !c.isBusy { finishMatch(c) }   // no drive, no green
    }

    // MARK: Drive index

    private func cacheURL(_ d: DriveState) -> URL {
        let safe = d.volume.key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "|", with: "_")
        return stores.indexCacheFolder.appendingPathComponent(safe + ".idx")
    }

    private func loadCachedIndex(_ d: DriveState) {
        let url = cacheURL(d)
        Task {
            let idx = await Task.detached(priority: .userInitiated) { DriveIndex.load(from: url) }.value
            if let idx, d.index == nil { d.install(index: idx); self.rematchAll() }
        }
    }

    /// Rescans in the background. exFAT keeps no change history across mounts, so the cache is only a head start.
    func refreshIndex(_ d: DriveState, then: (@MainActor () -> Void)? = nil) {
        if let then { d.scanWaiters.append(then) }
        guard !d.isScanning else { return }
        d.isScanning = true
        d.foldersRead = 0
        let root = d.path, url = cacheURL(d)
        Task {
            let idx = await Task.detached(priority: .utility) {
                let i = DriveIndex.scan(root: root) { n in Task { @MainActor in d.foldersRead = n } }
                i.save(to: url)
                return i
            }.value
            d.install(index: idx)
            d.foldersRead = idx.folderCount
            d.isScanning = false
            self.rematchAll()
            let waiting = d.scanWaiters
            d.scanWaiters = []
            for w in waiting { w() }
        }
    }

    private func rematchAll() {
        for c in cards where !c.isBusy && c.read != nil && c.phase != .stopped { Task { await self.matchCard(c) } }
    }

    // MARK: Card

    private nonisolated static func kind(_ path: String) -> FileKind { CardProber.kind(ofRelativePath: path) }

    func readCard(_ c: CardSession) async {
        let root = c.volume.path
        // A Codex virtual volume fills in gradually: wait until it stops changing before trusting a listing.
        if CardProber.isCodexVirtual(root: URL(fileURLWithPath: root)) {
            var last: Date?
            for _ in 0..<60 {
                let m = (try? FileManager.default.attributesOfItem(atPath: root + "/.codexvfs"))?[.modificationDate] as? Date
                if m == last { break }
                last = m
                try? await Task.sleep(for: .seconds(2))
            }
        }
        let read = await Task.detached(priority: .userInitiated) {
            CardReader.read(root: root, kind: Self.kind) { done, total in
                Task { @MainActor in if !c.isBusy { c.phase = .reading(done: done, total: total) } }
            }
        }.value
        c.read = read
        await matchCard(c)
    }

    /// One match at a time per card. A rescan landing mid-match asks for another pass; a running copy is left alone.
    func matchCard(_ c: CardSession) async {
        guard !c.isBusy else { return }
        guard !c.isMatching else { c.needsRematch = true; return }
        c.isMatching = true
        repeat {
            c.needsRematch = false
            await matchOnce(c)
        } while c.needsRematch && !c.isBusy
        c.isMatching = false
    }

    private func matchOnce(_ c: CardSession) async {
        guard let read = c.read, let drive = workingDrive else {
            if let read = c.read { await probeCard(c, read: read, focus: nil); finishMatch(c) }
            return
        }
        if c.provedDriveKey != drive.volume.key {   // proof is about one drive
            c.proved = [:]; c.weak = false; c.provedDriveKey = drive.volume.key
        }
        let ledger = drive.ledger, index = drive.index, root = drive.path, proved = c.proved
        var states = await Task.detached(priority: .userInitiated) {
            CardMatcher.match(read: read, ledger: ledger, index: index, driveRoot: root, proved: proved)
        }.value
        guard !c.isBusy else { return }
        // Copies this app didn't make still have to prove themselves, by reading both sides.
        let likely = read.listing.files.compactMap { f -> (file: CardFile, drivePath: String, quick: String)? in
            guard case .likely(let p)? = states[f.relPath], let q = read.quick[f.relPath] else { return nil }
            return (f, p, q)
        }
        c.states = states
        let focus = Set(read.listing.files.map(\.relPath).filter { if case .verified? = states[$0] { false } else { true } })
        await probeCard(c, read: read, focus: focus)
        if !likely.isEmpty {
            c.phase = .checking(done: 0, total: likely.count)
            let control = c.control, cardRoot = read.listing.root, name = c.name
            c.liveChecked = 0
            c.checkBytes = likely.reduce(0) { $0 + $1.file.size }
            c.checkStarted = Date()
            let ticker = trackBytes(of: c)
            defer { ticker.cancel() }
            let checked = await Task.detached(priority: .userInitiated) {
                IngestEngine.confirm(cardRoot: cardRoot, driveRoot: root, candidates: likely, ledger: ledger, jobName: name, control: control) { d, t in
                    Task { @MainActor in if !c.isBusy { c.phase = .checking(done: d, total: t) } }
                }
            }.value
            for (k, v) in checked.states { states[k] = v }
            c.keepProof(of: checked.states, read: read)
            if checked.weak { c.weak = true }
            c.states = states
            remember(proofOf: c)
        }
        guard !c.isBusy else { return }
        c.existingHome = CardMatcher.existingHome(states: states, files: read.listing.files)
        finishMatch(c)
    }

    /// Bytes move mid-file, so they're read directly rather than waiting for the next file.
    private func trackBytes(of c: CardSession) -> Task<Void, Never> {
        let control = c.control
        return Task { @MainActor in
            while !Task.isCancelled {
                c.liveBytes = control.bytesCopied
                c.liveChecked = control.bytesChecked
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func remember(proofOf c: CardSession) {
        guard c.volume.uuid != nil, let driveKey = c.provedDriveKey, !c.proved.isEmpty else { return }
        remembered[c.volume.key] = RememberedProof(proved: c.proved, driveKey: driveKey, weak: c.weak)
    }

    /// As quitting would.
    func forgetProofs() { remembered = [:] }

    private func probeCard(_ c: CardSession, read: CardRead, focus: Set<String>?) async {
        let url = URL(fileURLWithPath: read.listing.root), files = read.listing.files
        let probe = await Task.detached(priority: .userInitiated) { CardProber.probe(root: url, files: files, focus: focus) }.value
        c.probe = probe
        if CardSession.friendlyName(c.volume.name) == "Card", let cam = probe.cameras.first?.identity.displayModel, cam != "Camera" {
            c.name = cam + " card"
        }
        if let key = probe.cameras.first?.identity.bodyKey, let id = probe.cameras.first?.identity {
            var mem = cameraMemory[key] ?? CameraMemory(folder: id.displayModel)
            mem.displayName = id.displayModel
            mem.serialTail = id.serialTail
            cameraMemory[key] = mem
            stores.cameras = cameraMemory
        }
    }

    private func finishMatch(_ c: CardSession) {
        guard !c.isBusy else { return }
        conclude(c)
        c.phase = (c.isSafe || c.isHold || c.isEmpty) ? .finished : .ready
    }

    private func conclude(_ c: CardSession) {
        guard let read = c.read else { return }
        let drive = workingDrive
        if let drive {
            let issues = Pipeline.settle(issues: c.probe.issues, states: c.states, weak: c.weak, driveRoot: drive.path)
            let (v, states) = Pipeline.conclude(read: read, states: c.states, issues: issues, driveRoot: drive.path, kind: Self.kind)
            c.issues = issues; c.states = states; c.verdict = v
        } else {
            c.issues = c.probe.issues
            c.verdict = read.listing.files.isEmpty ? .empty : .notSafe(remaining: read.listing.files.count, total: read.listing.files.count, reasons: [])
        }
    }

    // MARK: Copying

    func start(_ c: CardSession, destination: Destination, extraFolders: [String] = []) {
        guard !c.isBusy else { return }
        guard let drive = workingDrive else { c.error = "Plug in your working drive first."; return }
        guard let read = c.read else { return }
        guard cards.contains(where: { $0 === c }), FileManager.default.fileExists(atPath: c.volume.path) else {
            c.error = "\(c.name) isn't plugged in any more."
            return
        }
        c.control.reset()
        do {
            try IngestEngine.preflight(job: job(for: c, read: read, drive: drive, destination: destination, extraFolders: extraFolders))
            c.pendingDestination = destination
            c.extraFolders = extraFolders
            c.destinationPath = destination.footageRoot
            c.error = nil
            c.phase = .queued
            queue.append(c)
            pumpQueue()
        } catch {
            c.error = error.localizedDescription
        }
    }

    private func job(for c: CardSession, read: CardRead, drive: DriveState, destination: Destination, extraFolders: [String]) -> IngestJob {
        var job = Pipeline.makeJob(read: read, states: c.states, cardName: c.name, driveRoot: drive.path, camera: c.primaryCamera?.identity,
                                   destination: destination, probe: c.probe, index: drive.index)
        job.dirsToCreate = extraFolders + job.dirsToCreate
        return job
    }

    func createShoot(_ c: CardSession, plan p: ShootPlan, cameraFolder: String, chosenDay: CalendarDay) {
        remember(camera: c.primaryCamera?.identity, folder: cameraFolder, cardDay: c.probe.captureDays.last?.day, chosenDay: chosenDay)
        let dest = Destination(footageRoot: p.footagePath, stillsRoot: c.probe.hasStills ? p.stillsPath : nil, audioRoot: p.audioPath)
        start(c, destination: dest, extraFolders: p.foldersToCreate)
    }

    private func pumpQueue() {
        guard !queueRunning, let c = queue.first else { return }
        queueRunning = true
        queue.removeFirst()
        if sleepToken == nil {
            sleepToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Copying a camera card")
        }
        Task { await self.run(c) }
    }

    private func run(_ c: CardSession) async {
        guard let drive = workingDrive, let read = c.read, let destination = c.pendingDestination else {
            c.error = "Plug in your working drive to carry on."
            c.phase = .stopped
            queueRunning = false
            pumpQueue()
            return
        }
        let job = job(for: c, read: read, drive: drive, destination: destination, extraFolders: c.extraFolders)
        c.progress = nil
        c.liveBytes = 0
        c.liveChecked = 0
        c.phase = .copying
        c.startedAt = Date()
        askForNotifications()
        let ledger = drive.ledger, control = c.control
        let ticker = trackBytes(of: c)
        defer { ticker.cancel() }
        let result: Result<IngestOutcome, Error> = await Task.detached(priority: .userInitiated) {
            let throttle = Throttle()
            return Result {
                try IngestEngine.run(job: job, ledger: ledger, control: control) { p in
                    guard throttle.ready() else { return }
                    Task { @MainActor in c.progress = p }
                }
            }
        }.value

        switch result {
        case .failure(let e):
            c.error = e.localizedDescription
            c.phase = .ready
        case .success(let out):
            for (k, v) in out.states { c.states[k] = v }
            c.keepProof(of: out.states, read: read)
            if out.weakVerification { c.weak = true }
            c.provedDriveKey = drive.volume.key
            remember(proofOf: c)
            c.issues = Pipeline.settle(issues: c.probe.issues, states: c.states, weak: c.weak, driveRoot: drive.path)
            let (v, states) = Pipeline.conclude(read: read, states: c.states, issues: c.issues, driveRoot: drive.path, kind: Self.kind)
            c.states = states
            c.verdict = v
            if out.failures.isEmpty && !out.cancelled && !job.items.isEmpty {
                do {
                    if !(try Pipeline.writeManifest(job: job, states: states, read: read)) {
                        c.issues.append(CardIssue(severity: .note, code: "mhl.card-history", message: "This card keeps its own checksum history, copied as it was."))
                    }
                } catch { c.issues.append(CardIssue(severity: .note, code: "mhl.write", message: "The checksum manifest couldn't be saved. The copy itself is fine.")) }
            }
            c.existingHome = CardMatcher.existingHome(states: states, files: read.listing.files)
            let driveGone = !FileManager.default.fileExists(atPath: drive.path)
            if driveGone && c.error == nil { c.error = "\(drive.name) was unplugged. Plug it back in to finish." }
            if out.cancelled || driveGone { c.phase = .stopped }
            else if c.isSafe || c.isHold { c.phase = .finished }
            else { c.phase = .ready }
            remember(c, job: job, drive: drive, outcome: v)
            if c.isSafe || c.isHold { announce(c, drive: drive) }
            else if !out.cancelled { notify(title: "\(c.name) needs a look", body: "Some files didn't copy. Don't format it.") }
            refreshIndex(drive)
        }
        queueRunning = false
        if queue.isEmpty, let t = sleepToken { ProcessInfo.processInfo.endActivity(t); sleepToken = nil }
        pumpQueue()
    }

    func stop(_ c: CardSession) {
        if c.phase == .queued { queue.removeAll { $0 === c }; c.phase = .ready }
        else { c.control.stop() }
    }

    func resume(_ c: CardSession) {
        guard let d = c.pendingDestination else { return }
        guard workingDrive != nil else { c.error = "Plug in your working drive to carry on."; return }
        c.error = nil
        start(c, destination: d, extraFolders: c.extraFolders)
    }

    /// Re-reads a card whose contents changed under us.
    func recheck(_ c: CardSession) {
        c.control.reset()
        c.error = nil
        c.phase = .reading(done: 0, total: 0)
        Task { await self.readCard(c) }
    }

    func retry(_ c: CardSession) {
        guard let d = c.pendingDestination else { return }
        start(c, destination: d, extraFolders: c.extraFolders)
    }

    func eject(_ c: CardSession) async {
        c.ejectError = nil
        if let why = await VolumeWatcher.eject(path: c.volume.path) { c.ejectError = why; return }
        c.ejected = true
        try? await Task.sleep(for: .milliseconds(1400))
        cards.removeAll { $0 === c }
        onEjected?()
        scheduleRefresh()   // the same card may be back already
    }

    func revealDestination(of c: CardSession) {
        guard let drive = workingDrive else { return }
        let rel = c.destinationPath ?? c.existingHome
        guard let rel else { NSWorkspace.shared.open(URL(fileURLWithPath: drive.path)); return }
        reveal(path: drive.path + "/" + rel)
    }

    /// The copy on the drive of a file named in an issue, else the card's folder.
    func reveal(_ rel: String?, of c: CardSession) {
        if let drive = workingDrive, let rel, case .verified(let onDrive, _, _)? = c.states[rel] {
            reveal(path: drive.path + "/" + onDrive)
        } else { revealDestination(of: c) }
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func remember(_ c: CardSession, job: IngestJob, drive: DriveState, outcome: CardVerdict) {
        let text: String
        switch outcome {
        case .safe: text = "Safe to format"
        case .hold: text = "Copied, needs a look"
        case .empty: text = "Empty"
        case .notSafe: text = "Not finished"
        }
        history.insert(HistoryEntry(id: job.id, date: Date(), cardName: c.name, camera: c.primaryCamera?.identity.displayModel,
                                    driveName: drive.name, path: drive.path + "/" + job.destination, files: c.verifiedFiles,
                                    bytes: job.items.reduce(0) { $0 + $1.file.size }, outcome: text), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        stores.history = history
    }

    private func announce(_ c: CardSession, drive: DriveState) {
        if c.isSafe {
            notify(title: "\(c.name) is safe to format", body: "\(drive.name) and the card were both read in full, and they match.")
        } else {
            notify(title: "\(c.name) is copied, but needs a look", body: c.issues.first?.message ?? "Check it before formatting.")
        }
    }

    private func notify(title: String, body: String) {
        guard !isDemo, Bundle.main.bundleIdentifier != nil else { return }
        let n = UNMutableNotificationContent()
        n.title = title; n.body = body; n.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
    }

    // MARK: Cameras

    func folderName(for camera: CameraIdentity?) -> String {
        guard let camera else { return "Camera" }
        if let key = camera.bodyKey, let hit = cameraMemory[key] { return hit.folder }
        return camera.displayModel
    }

    func clockOffset(for camera: CameraIdentity?) -> Int {
        guard let key = camera?.bodyKey else { return 0 }
        return cameraMemory[key]?.clockOffsetDays ?? 0
    }

    func remember(camera: CameraIdentity?, folder: String, cardDay: CalendarDay?, chosenDay: CalendarDay) {
        guard let camera, let key = camera.bodyKey else { return }
        var mem = cameraMemory[key] ?? CameraMemory(folder: folder)
        mem.folder = folder
        if let cardDay {
            // One changed date proves nothing: a shoot can be filed on any day. A clock is only called wrong
            // when the same large gap comes up on a second card. Filing under the card's own date clears it.
            let days = CalendarDay.gregorian.dateComponents([.day], from: cardDay.date(), to: chosenDay.date()).day ?? 0
            if days == 0 { mem.clockOffsetDays = nil; mem.suspectedOffsetDays = nil }
            else if abs(days) >= 7 {
                if mem.suspectedOffsetDays == days { mem.clockOffsetDays = days }
                mem.suspectedOffsetDays = days
            }
        }
        cameraMemory[key] = mem
        stores.cameras = cameraMemory
    }

    func forgetCamera(_ key: String) {
        cameraMemory[key] = nil
        stores.cameras = cameraMemory
    }

    // MARK: Setup

    func accept(setup: DriveSetup, for d: DriveState) {
        do { try stores.save(setup: setup, onDrive: d.path) }
        catch { return }
        d.setup = setup
        if let i = d.index { d.install(index: i) }
        use(drive: d)
    }

    var isCopying: Bool { cards.contains { $0.isBusy } }

    func forgetVolumeChoices() {
        let chosen = stores.overrides.keys
        stores.overrides = [:]
        hasVolumeChoices = false
        for key in chosen {
            if let v = cards.first(where: { $0.volume.key == key })?.volume ?? drives.first(where: { $0.volume.key == key })?.volume { release(v) }
        }
        Task { await self.refresh() }
    }

    /// Worst news first, so a calmer card can never hide a worse one.
    var cardsWorstFirst: [CardSession] {
        cards.enumerated()
            .map { (card: $1, rank: CardSheet.severity(of: $1, in: self), order: $0) }
            .sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.order < $1.order }
            .map(\.card)
    }
}

/// At most ten progress updates a second reach the main thread.
final class Throttle: @unchecked Sendable {
    private var last = Date.distantPast
    private let lock = NSLock()
    func ready() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) < 0.1 { return false }
        last = now
        return true
    }
}
