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
    /// False from the moment this mount ends. A DriveState is one mount of one drive, never a place.
    var isCurrent: Bool { ledger.mount?.isCurrent == true }

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
    var proved: [String: Proof] = [:]   // read in full on both sides, while this card and `provedOn` have stayed in
    var provedOn: DriveState?           // the one drive anything here says anything about
    var weak = false
    var volumeGone = false
    var needsRematch = false
    var looks = 0                       // the newest last look wins, whatever order they land in
    var driveWentAway = false           // why `error` says what it says, for when the drive comes back
    var cameraFolder: String?
    var error: String?
    var ejectError: String?
    var ejected = false                 // out, and still on screen for the moment it takes to say so
    var liveBytes: UInt64 = 0
    var liveChecked: UInt64 = 0
    var checkBytes: UInt64 = 0          // what the running check has to read
    var checkStarted: Date?
    var existingHome: String?
    var canJoinHome = false             // nothing at its place in that folder would have to be overwritten
    var shootLabel: String?             // "Lantern Bakery Co. · 22.10.26 Spring menu", once it's been named
    var keptElsewhere = false           // a job took on files proved in another folder, so they're not only on the card
    var badCopyNote: String?            // what a rescue left where it was
    var folderError: String?            // why an empty folder couldn't be added
    var destinationDrive: String?       // the drive `pendingDestination` is on
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
    /// The only reading of the verdict that may turn anything green: concluded, current, and about this mount of this
    /// drive, with this mount of this card.
    func isSafe(on drive: DriveState?) -> Bool {
        guard verdict == .safe, phase == .finished, let drive, provedOn === drive else { return false }
        return drive.isCurrent && volume.isCurrent
    }

    /// Everything a drive said about this card, gone in one step, before anything is said about another drive.
    func forgetDrive() {
        proved = [:]; states = [:]; weak = false; verdict = nil; issues = []; provedOn = nil; existingHome = nil; canJoinHome = false
        keptElsewhere = false; badCopyNote = nil; folderError = nil
        if !isBusy, !volumeGone { phase = .reading(done: 0, total: 0) }
    }
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
    let updates = Updates()
    init() { updates.busy = { [weak self] in self?.cardInTheWay } }
    private let watcher = VolumeWatcher()
    private var queue: [CardSession] = []
    private var queueRunning = false
    private var sleepToken: NSObjectProtocol?
    private var keptAwake = 0
    private(set) var ignored: [Volume] = []     // plugged in, and not offered as anything
    private(set) var notified: [String] = []    // titles, in order, for the tests
    private var refreshPending = false
    private var announced: Set<String> = []     // what's already had its moment on screen
    private var askedPermission = false
    private var looks = 0                       // the newest look at the volumes wins, whatever order they land in
    var lookLandsLate: (@MainActor (Int) async -> Void)?    // tests: holds a last look back, to land it out of order
    /// Every volume and what it is. Off the main thread: the first read can wait on a permission prompt.
    var findVolumes: @Sendable (_ allowDiskImages: Bool, _ overrides: [String: String]) -> [(Volume, VolumeRole)] = { allow, overrides in
        VolumeWatcher.scan(allowDiskImages: allow).map { ($0, VolumeWatcher.role(of: $0, overrides: overrides)) }
    }
    var isDemo = false
    var opensOnCardIn = true { didSet { stores.opensOnCardIn = opensOnCardIn } }
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
        if !isDemo, Bundle.main.bundleIdentifier != nil { updates.start(SparkleEngine(updates: updates)) }
        cameraMemory = stores.cameras
        watcher.onChange = { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
        watcher.start()
        scheduleRefresh()
    }

    /// The card a restart would get in the way of: one being copied, read or checked.
    var cardInTheWay: String? {
        cards.first { c in
            if c.isBusy || c.isMatching { return true }
            if case .reading = c.phase { return true }
            if case .checking = c.phase { return true }
            return false
        }?.name
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
        looks += 1
        let look = looks
        let allow = stores.allowDiskImages, overrides = stores.overrides, find = findVolumes
        let known = Set(drives.filter(\.isCurrent).map(\.path))
        // A new drive's ledger and setup are read here too: a large ledger is no reason to freeze the widget.
        let found: [(Volume, VolumeRole, (Ledger, DriveSetup?)?)] = await Task.detached(priority: .userInitiated) {
            find(allow, overrides).map { v, role in
                (v, role, role == .drive && !known.contains(v.path) ? (Ledger(driveRoot: v.path, mount: v.anchor), Stores.setup(onDrive: v.path)) : nil)
            }
        }.value
        guard look == looks else { return }

        /// The same mount, still there. A path is only a place: another volume can be at it before anyone hears the first one go.
        func stillHere(_ v: Volume) -> Bool { v.isCurrent && found.contains { $0.0.path == v.path && $0.0.key == v.key } }

        // A card pulled out mid-copy stays on screen: someone needs to hear about it.
        // One already marked stays too, whatever its job has done since, until the card is back or someone dismisses it.
        for c in cards where !stillHere(c.volume) && !c.ejected && !c.volumeGone {
            // The reads can fail before this hears the card has gone, so a copy that has just ended short counts too, and
            // so does one already being read again, because losing the card is what took its proof.
            let settling = switch c.phase { case .ready, .reading, .checking: true; case .stopped: c.driveWentAway; default: false }
            let cutShort = settling && c.pendingDestination != nil && c.filesToGo > 0
            if c.phase == .copying || cutShort {
                let pulled = "\(c.name) \(c.phase == .copying ? "was removed while copying" : "came out before every file was copied"). What's copied stays on the drive. Put it back in and it's read again before it can say Safe."
                c.error = pulled
                c.volumeGone = true
                c.verdict = nil
                c.control.stop()
                if cutShort { c.phase = .stopped }
                notify(title: "Don't format \(c.name)", body: pulled)
            } else { queue.removeAll { $0 === c }; cards.removeAll { $0 === c } }
        }
        drives.removeAll { d in
            guard !stillHere(d.volume) else { return false }
            if d === workingDrive {
                for c in cards where c.isBusy {
                    c.control.stop()
                    if !c.volumeGone { c.error = "\(d.name) was unplugged. Plug it back in to finish."; c.driveWentAway = true }    // the card's own warning matters more
                }
            }
            return true
        }
        if let w = workingDrive, !drives.contains(where: { $0 === w }) {
            workingDrive = nil
            driveChanged()      // no drive, no green
        }
        maybeCards = found.compactMap { v, r, _ in if case .maybeCard(let why) = r { (v, why) } else { nil } }
        unreadable = found.compactMap { v, r, _ in r == .unreadable ? v : nil }
        ignored = found.compactMap { v, r, _ in r == .ignored && !(v.isReadOnly && v.isInternal) ? v : nil }

        for (v, role, load) in found where role == .drive && !drives.contains(where: { $0.path == v.path }) {
            guard let load else { scheduleRefresh(); continue }     // this mount ended just now: the next look reads the new one
            let d = DriveState(volume: v, ledger: load.0, setup: load.1)
            drives.append(d)
            loadCachedIndex(d)
            refreshIndex(d)
        }
        chooseWorkingDrive()
        // Whatever mounts at a path may be a different card, so a session never outlives its volume.
        cards.removeAll { c in
            !c.isBusy && (c.volumeGone || !stillHere(c.volume)) && found.contains { $0.0.path == c.volume.path }
        }
        var arrived = false
        for (v, role, _) in found where role == .card && !cards.contains(where: { $0.volume.path == v.path }) {
            let c = CardSession(volume: v)      // nothing carries over: proof ends when a card leaves the Mac
            cards.append(c)
            arrived = true
            Task { await self.readCard(c) }
        }
        let waiting = Set(maybeCards.map(\.volume.key) + unreadable.map(\.key))
        if arrived || !waiting.subtracting(announced).isEmpty { onArrival?() }
        announced = waiting
        // A volume that can't be read, or that needs an answer, comes first. Setup would only cover it, and say to plug in a
        // drive that's already there.
        if unreadable.isEmpty, maybeCards.isEmpty, let first = onFirstLook { onFirstLook = nil; first() }
    }

    private func chooseWorkingDrive() {
        // The saved drive always wins when it turns up, unless a copy is running.
        if let k = stores.workingDriveKey, workingDrive?.volume.key != k, !isCopying,
           let hit = drives.first(where: { $0.volume.key == k }) {
            workingDrive = hit; driveChanged(); return
        }
        if workingDrive != nil { return }
        // A drive that isn't set up is never chosen silently: it could be camera media nobody recognised.
        if let hit = drives.first(where: { $0.setup != nil }) { workingDrive = hit; driveChanged() }
    }

    /// A job belongs to the drive it started on, so nothing changes the working drive while one is running or waiting.
    func use(drive: DriveState) {
        guard !isCopying else { return }
        guard workingDrive !== drive else { rematchAll(); return }
        workingDrive = drive
        stores.workingDriveKey = drive.volume.key
        driveChanged()
    }

    /// Every card, stopped ones too, loses all it knew from the old drive before the new one is looked at, so nothing about
    /// one drive can be read as being about another, even for a moment.
    private func driveChanged() {
        for c in cards where !c.isBusy {
            c.forgetDrive()
            c.control.reset()       // whatever stopped it stopped a job on the old drive
            if c.driveWentAway, workingDrive != nil, !c.volumeGone { c.driveWentAway = false; c.error = nil }     // it says why until there's a drive again
            if c.read != nil, !c.volumeGone { Task { await self.matchCard(c) } }
        }
    }

    /// Why a volume that's plugged in isn't offered as a drive, for the person looking for it.
    func whyIgnored(_ v: Volume) -> String {
        v.isReadOnly ? "macOS has it read-only." : v.isInternal ? "macOS reports it as internal." : "it looks like a backup."
    }

    /// A name to tell this drive by. Two drives can carry one label, and macOS mounts the second under a numbered path.
    func label(of d: DriveState) -> String {
        drives.filter { $0.name == d.name }.count > 1 ? (d.path as NSString).lastPathComponent : d.name
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
        driveChanged()      // no drive, no green
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
        let root = c.volume.path, mount = c.volume.anchor
        // A Codex virtual volume fills in gradually: wait until it stops changing before trusting a listing.
        func marker() async -> Date? {
            await Task.detached(priority: .userInitiated) { () -> Date? in
                guard CardProber.isCodexVirtual(root: URL(fileURLWithPath: root)) else { return nil }
                return (try? FileManager.default.attributesOfItem(atPath: root + "/.codexvfs"))?[.modificationDate] as? Date
            }.value
        }
        if var last = await marker() {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard let m = await marker(), m != last else { break }
                last = m
            }
        }
        let read = await Task.detached(priority: .userInitiated) {
            CardReader.read(root: root, kind: Self.kind, mount: mount) { done, total in
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
        guard let read = c.read else { return }
        guard let drive = workingDrive else {
            await probeCard(c, read: read, focus: nil)
            await finish(c)
            return
        }
        if c.provedOn !== drive {
            c.forgetDrive()
            c.provedOn = drive
        }
        func current() -> Bool { !c.isBusy && c.provedOn === drive && workingDrive === drive }
        let ledger = drive.ledger, index = drive.index, root = drive.path, proved = c.proved
        var states = await Task.detached(priority: .userInitiated) {
            CardMatcher.match(read: read, ledger: ledger, index: index, driveRoot: root, proved: proved)
        }.value
        guard current() else { return }
        // A job told where this card goes isn't finished by a copy somewhere else, however good. What it owes stays owed.
        if let d = c.pendingDestination, c.destinationDrive == drive.volume.key {
            let places = Dictionary(Pipeline.makeJob(read: read, states: [:], cardName: c.name, driveRoot: root, camera: nil, destination: d, probe: c.probe, index: index)
                .items.map { ($0.file.relPath, $0.drivePath) }, uniquingKeysWith: { a, _ in a })
            for (rel, s) in states {
                let found: String? = switch s { case .likely(let p), .verified(let p, _, _): p; default: nil }
                guard let found, let place = places[rel], found != place else { continue }
                if case .failed? = c.states[rel] { states[rel] = c.states[rel] } else { states[rel] = .missing }
                c.proved[rel] = nil
                c.keptElsewhere = true
            }
        }
        // A file that failed still failed, and for the same reason, until something new is known about it.
        for (rel, state) in c.states { if case .failed = state, states[rel] == .missing { states[rel] = state } }
        // Copies this app didn't make still have to prove themselves, by reading both sides.
        let likely = read.listing.files.compactMap { f -> (file: CardFile, drivePath: String, quick: String)? in
            guard case .likely(let p)? = states[f.relPath], let q = read.quick[f.relPath] else { return nil }
            return (f, p, q)
        }
        c.states = states
        let focus = Set(read.listing.files.map(\.relPath).filter { if case .verified? = states[$0] { false } else { true } })
        await probeCard(c, read: read, focus: focus)
        guard current() else { return }
        if !likely.isEmpty {
            c.phase = .checking(done: 0, total: likely.count)
            let control = c.control, cardRoot = read.listing.root, name = c.name, mount = read.mount
            c.liveChecked = 0
            c.checkBytes = likely.reduce(0) { $0 + $1.file.size }
            c.checkStarted = Date()
            let ticker = trackBytes(of: c)
            defer { ticker.cancel() }
            keepAwake()
            defer { letSleep() }
            let checked = await Task.detached(priority: .userInitiated) {
                IngestEngine.confirm(cardRoot: cardRoot, driveRoot: root, candidates: likely, ledger: ledger, jobName: name, control: control, cardMount: mount) { d, t in
                    Task { @MainActor in if !c.isBusy { c.phase = .checking(done: d, total: t) } }
                }
            }.value
            guard current() else { return }
            for (k, v) in checked.states { states[k] = v }
            c.proved.merge(checked.proofs) { _, new in new }
            if checked.weak { c.weak = true }
            c.states = states
            if control.isStopped {
                c.phase = .stopped
                return
            }
        }
        let home = CardMatcher.existingHome(states: states, files: read.listing.files)
        c.existingHome = home
        c.canJoinHome = await Task.detached(priority: .userInitiated) { home.map { CardMatcher.canJoin(home: $0, read: read, driveRoot: root) } ?? false }.value
        guard current() else { return }
        await finish(c)
        // A check can run a long while with nobody watching, so the end of one is news, as the end of a copy is.
        if !likely.isEmpty, c.isSafe(on: drive) || c.isHold { announce(c, drive: drive) }
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

    /// The verdict. The last look reads every file on the card again, so it's taken off the main thread, and only counts
    /// if the card and drive it was about are still the ones in front of us.
    private func finish(_ c: CardSession) async {
        guard !c.isBusy, let read = c.read else { return }
        guard let drive = workingDrive else {
            c.issues = c.probe.issues
            c.verdict = Verdict.withoutDrive(read: read, issues: c.probe.issues)
            c.phase = c.isEmpty ? .finished : .ready
            return
        }
        c.looks += 1
        let look = c.looks
        let states = c.states, proved = c.proved, probed = c.probe.issues, weak = c.weak, ledger = drive.ledger, root = drive.path
        let end = await Task.detached(priority: .userInitiated) {
            let issues = Pipeline.settle(issues: probed, states: states, weak: weak, driveRoot: root, ledger: ledger)
            return Pipeline.conclude(read: read, states: states, proved: proved, issues: issues, driveRoot: root, kind: Self.kind)
        }.value
        await lookLandsLate?(look)
        guard look == c.looks, !c.isBusy, !c.volumeGone, c.provedOn === drive, workingDrive === drive else { return }
        c.issues = end.issues; c.states = end.states; c.verdict = end.verdict
        c.proved = c.proved.filter { if case .verified? = end.states[$0.key] { true } else { false } }
        c.phase = (c.isSafe || c.isHold || c.isEmpty) ? .finished : .ready
        // A file that lost its proof is read again. That proof is gone now, so this can only happen once for each.
        let lost = states.contains { rel, state in
            if case .verified = state, case .verified? = end.states[rel] { false } else if case .verified = state { true } else { false }
        }
        if lost, c.volume.isCurrent, drive.isCurrent { rematch(c) }
    }

    /// One more pass, now if nothing's running, or as soon as what's running is done.
    private func rematch(_ c: CardSession) {
        if c.isMatching { c.needsRematch = true } else { Task { await self.matchCard(c) } }
    }

    /// Goes over a settled card again when someone comes to look at it. It costs a look at each file, never a full read.
    /// A look can't be dropped because a match is running: that match may already be past its own.
    func lookAgain() {
        for c in cards where c.phase == .finished {
            if c.isMatching { c.needsRematch = true } else { Task { await self.finish(c) } }
        }
    }

    /// Cards someone might want read again from the start. Everything else already offers it, or does it anyway.
    var cardsToCheckAgain: [CardSession] { cards.filter { $0.phase == .finished && !$0.isEmpty } }

    // MARK: Copying

    func start(_ c: CardSession, destination: Destination, extraFolders: [String] = []) {
        guard !c.isBusy else { return }
        guard let drive = workingDrive else { c.error = "Plug in your working drive first."; return }
        guard let read = c.read else { return }
        guard cards.contains(where: { $0 === c }), FileManager.default.fileExists(atPath: c.volume.path) else {
            c.error = "\(c.name) isn't plugged in any more."
            return
        }
        guard !reserved(besides: c).contains(matchKey(destination.footageRoot)) else {
            c.error = "Another card is going to that folder."
            return
        }
        c.control.reset()
        if c.provedOn !== drive {
            c.forgetDrive()
            c.provedOn = drive
        }
        do {
            try IngestEngine.preflight(job: job(for: c, read: read, drive: drive, destination: destination, extraFolders: extraFolders), ledger: drive.ledger)
            // A rescue leaves a bad copy where it is, and whoever opens that folder should be told. Going on with the same job isn't one.
            if destination.footageRoot != c.pendingDestination?.footageRoot { c.badCopyNote = badCopySentence(c, leaving: destination) }
            for (rel, state) in c.states { if case .failed = state { c.states[rel] = .missing } }     // this job says what becomes of them
            c.pendingDestination = destination
            c.destinationDrive = drive.volume.key
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

    /// Makes the empty folders a copy left out, in the folder the card was proved in, and looks again. What's proved is still
    /// proved, so the last look is all it takes. No file is written, and nothing else on the drive changes.
    func addMissingFolders(_ c: CardSession) async {
        guard !c.isBusy, !c.volumeGone, let drive = workingDrive, c.provedOn === drive, drive.isCurrent, let read = c.read,
              let home = Pipeline.home(read: read, states: c.states),
              let missing = c.issues.first(where: { $0.code == Pipeline.emptyFoldersCode })?.paths else { return }
        let root = drive.path
        let failed = await Task.detached(priority: .userInitiated) { IngestEngine.addFolders(missing, home: home, driveRoot: root) }.value
        let names = failed.map { ($0 as NSString).lastPathComponent }
        c.folderError = names.isEmpty ? nil : "Couldn't add \(names.prefix(2).joined(separator: ", "))\(names.count > 2 ? " and \(names.count - 2) more" : ""). Something on the drive has that name, or it won't take a new folder."
        await finish(c)
        if c.isSafe(on: drive) { announce(c, drive: drive) }
    }

    private func badCopySentence(_ c: CardSession, leaving destination: Destination) -> String? {
        guard let old = c.pendingDestination?.footageRoot ?? c.existingHome, old != destination.footageRoot else { return nil }
        let bad = (c.read?.listing.files ?? []).filter { c.states[$0.relPath]?.isBadCopyOnDrive == true }
        guard let first = bad.first else { return nil }
        return bad.count == 1 ? "A bad copy of \(first.name) is still in \(old)." : "Bad copies of \(bad.count) files are still in \(old)."
    }

    /// Adds what's left of a card to the folder that already holds the rest of it.
    func add(_ card: CardSession, to home: String) {
        let stills = CardMatcher.existingHome(states: card.states, files: card.read?.listing.files ?? [], kinds: [.still], smallestFile: 0)
        start(card, destination: Destination(footageRoot: home, stillsRoot: stills))
    }

    /// Copies a card into a new folder of its own inside `folder`, a path on the working drive.
    func copy(_ card: CardSession, into folder: String) {
        guard let drive = workingDrive else { return }
        let base = card.probe.reel ?? (CardSession.friendlyName(card.volume.name) == "Card" ? "Card 1" : card.volume.name)
        var name = base, n = 2
        let taken = reserved(besides: card)
        func free(_ path: String) -> Bool { drive.existing(path) == nil && !taken.contains(matchKey(path)) }
        while !free(folder.isEmpty ? name : folder + "/" + name) { name = "\(base) \(n)"; n += 1 }
        card.shootLabel = nil       // that was the name of where it was going
        start(card, destination: Destination(footageRoot: folder.isEmpty ? name : folder + "/" + name))
    }

    /// Folders other cards are about to fill. They aren't on the drive yet, so the drive can't say they're taken.
    func reserved(besides card: CardSession) -> Set<String> {
        var out: Set<String> = []
        for c in cards where c !== card && c.phase != .finished && !c.volumeGone {
            guard let d = c.pendingDestination else { continue }
            for path in [d.footageRoot, d.stillsRoot, d.audioRoot].compactMap({ $0 }) { out.insert(matchKey(path)) }
        }
        return out
    }

    private func job(for c: CardSession, read: CardRead, drive: DriveState, destination: Destination, extraFolders: [String]) -> IngestJob {
        var job = Pipeline.makeJob(read: read, states: c.states, proved: c.proved, cardName: c.name, driveRoot: drive.path, camera: c.primaryCamera?.identity,
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
        guard !queueRunning, let c = queue.first else {
            if !queueRunning, workingDrive == nil { chooseWorkingDrive() }      // a drive that came back had to wait for the job
            return
        }
        queueRunning = true
        queue.removeFirst()
        Task { await self.run(c) }
    }

    /// Copying and checking can both run long past the last time anyone touched the Mac.
    private func keepAwake() {
        if keptAwake == 0 {
            sleepToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Reading a camera card")
        }
        keptAwake += 1
    }

    private func letSleep() {
        keptAwake -= 1
        if keptAwake == 0, let t = sleepToken { ProcessInfo.processInfo.endActivity(t); sleepToken = nil }
    }

    var isKeepingAwake: Bool { sleepToken != nil }

    /// All a job leaves behind, worked out off the main thread.
    private struct Finished: Sendable {
        var outcome: IngestOutcome
        var states: [String: FileState], proved: [String: Proof], issues: [CardIssue], verdict: CardVerdict
        var manifestNote: CardIssue?
    }

    private func run(_ c: CardSession) async {
        // The job waited its turn, so it goes to the drive it was set up for, or nowhere.
        guard let drive = workingDrive, c.provedOn === drive, drive.isCurrent, let read = c.read, let destination = c.pendingDestination else {
            // The saved drive can be back already, and only waiting for the job that was unwinding.
            if workingDrive == nil, !drives.contains(where: { $0.volume.key == stores.workingDriveKey }) {
                c.error = "Plug in your working drive to carry on."
                notify(title: "Don't format \(c.name)", body: "Your working drive went before this card was copied.")
            } else if c.driveWentAway { c.driveWentAway = false; c.error = nil }    // it's back, and Resume starts it
            c.phase = .stopped
            queueRunning = false
            pumpQueue()
            return
        }
        keepAwake()
        defer { letSleep() }
        let job = job(for: c, read: read, drive: drive, destination: destination, extraFolders: c.extraFolders)
        // Proved somewhere else isn't proved here. The job says what becomes of these, and a stopped one owes them still.
        for rel in job.items.map(\.file.relPath) {
            if case .verified? = c.states[rel] { c.states[rel] = .missing; c.proved[rel] = nil; c.keptElsewhere = true }
        }
        c.progress = nil
        c.liveBytes = 0
        c.liveChecked = 0
        c.phase = .copying
        c.startedAt = Date()
        askForNotifications()
        let ledger = drive.ledger, control = c.control, root = drive.path, before = c.states, proved = c.proved, wasWeak = c.weak, probed = c.probe.issues
        let ticker = trackBytes(of: c)
        defer { ticker.cancel() }
        let result: Result<Finished, Error> = await Task.detached(priority: .userInitiated) {
            let throttle = Throttle()
            return Result {
                let out = try IngestEngine.run(job: job, ledger: ledger, control: control) { p in
                    guard throttle.ready() else { return }
                    Task { @MainActor in c.progress = p }
                }
                let states = before.merging(out.states) { _, new in new }
                let proofs = proved.merging(out.proofs) { _, new in new }
                let issues = Pipeline.settle(issues: probed, states: states, weak: wasWeak || out.weakVerification, driveRoot: root, ledger: ledger)
                let end = Pipeline.conclude(read: read, states: states, proved: proofs, issues: issues, driveRoot: root, kind: Self.kind)
                var note: CardIssue?
                if out.failures.isEmpty && !out.cancelled && !job.items.isEmpty {
                    do {
                        if !(try Pipeline.writeManifest(job: job, states: end.states, read: read)) {
                            note = CardIssue(severity: .note, code: "mhl.card-history", message: "This card keeps its own checksum history, copied as it was.")
                        }
                    } catch { note = CardIssue(severity: .note, code: "mhl.write", message: "The checksum manifest couldn't be saved. The copy itself is fine.") }
                }
                return Finished(outcome: out, states: end.states, proved: proofs, issues: end.issues, verdict: end.verdict, manifestNote: note)
            }
        }.value

        switch result {
        case .failure(let e):
            if !c.volumeGone { c.error = e.localizedDescription }     // the card's own warning matters more
            c.phase = c.volumeGone ? .stopped : .ready
        case .success(let done):
            let out = done.outcome
            c.proved = done.proved
            if out.weakVerification { c.weak = true }
            c.states = done.states
            c.issues = done.issues + (done.manifestNote.map { [$0] } ?? [])
            c.verdict = done.verdict
            c.existingHome = CardMatcher.existingHome(states: done.states, files: read.listing.files)
            let driveGone = !drive.isCurrent
            if driveGone && c.error == nil { c.error = "\(drive.name) was unplugged. Plug it back in to finish."; c.driveWentAway = true }
            if out.cancelled || driveGone { c.phase = .stopped }
            else if c.isSafe || c.isHold { c.phase = .finished }
            else { c.phase = .ready }
            remember(c, job: job, drive: drive, outcome: done.verdict)
            if c.isSafe(on: drive) || c.isHold { announce(c, drive: drive) }
            else if driveGone { if !c.volumeGone { notify(title: "Don't format \(c.name)", body: "\(drive.name) was unplugged before every file was proved.") } }
            else if !out.cancelled { notify(title: "\(c.name) needs a look", body: "Some files didn't copy. Don't format it.") }
            refreshIndex(drive)
        }
        queueRunning = false
        // What happened while the job was unwinding couldn't take effect until now: nothing else will look.
        if c.volumeGone { scheduleRefresh() }
        if let w = workingDrive, c.provedOn !== w { driveChanged() }
        pumpQueue()
    }

    func stop(_ c: CardSession) {
        if c.phase == .queued { queue.removeAll { $0 === c }; c.phase = .ready }
        else { c.control.stop() }
    }

    func resume(_ c: CardSession) {
        guard workingDrive != nil else { c.error = "Plug in your working drive to carry on."; return }
        guard let d = c.pendingDestination else { recheck(c); return }     // a check that was stopped, with nothing to copy
        c.error = nil
        start(c, destination: d, extraFolders: c.extraFolders)
    }

    /// A pulled card that isn't coming back. It stays on screen until it's back, or until someone says they've seen it.
    func dismiss(_ c: CardSession) {
        queue.removeAll { $0 === c }
        cards.removeAll { $0 === c }
    }

    /// Reads a card and its copy again from the start. Someone asked, so nothing is carried over from before.
    func recheck(_ c: CardSession) {
        guard !c.isBusy else { return }
        c.control.reset()
        c.error = nil
        c.forgetDrive()
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

    /// Where a card is. Usually one folder, and every one of them if it's proved across more.
    func foldersToShow(_ c: CardSession) -> [String] {
        guard let drive = workingDrive else { return [] }
        let split = c.read.map { Pipeline.homes(read: $0, states: c.states) } ?? []
        return (split.isEmpty ? [c.destinationPath ?? c.existingHome].compactMap { $0 } : split).map { drive.path + "/" + $0 }
    }

    func revealDestination(of c: CardSession) {
        guard let drive = workingDrive else { return }
        let folders = foldersToShow(c)
        guard !folders.isEmpty else { NSWorkspace.shared.open(URL(fileURLWithPath: drive.path)); return }
        NSWorkspace.shared.activateFileViewerSelecting(folders.map { URL(fileURLWithPath: $0) })
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
        if c.isSafe(on: drive) {
            notify(title: "\(c.name) is safe to format", body: "\(label(of: drive)) and the card were both read in full, and they match.")
        } else {
            notify(title: "\(c.name) is copied, but needs a look", body: c.issues.first?.message ?? "Check it before formatting.")
        }
    }

    private func notify(title: String, body: String) {
        notified.append(title)
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

    /// Nil when it's saved. Otherwise, what went wrong and what to do about it.
    func accept(setup: DriveSetup, for d: DriveState) -> String? {
        guard setup.staysOnDrive else { return "A folder name in this layout would lead off \(d.name). Change it and try again." }
        do { try stores.save(setup: setup, onDrive: d.path) }
        catch { return "Couldn't save to \(d.name): \(error.localizedDescription) Check it can be written to and has room, then try again." }
        d.setup = setup
        if let i = d.index { d.install(index: i) }
        use(drive: d)
        return nil
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
