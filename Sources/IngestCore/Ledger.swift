import Foundation

/// One file whose bytes were proved identical on the card and the drive, by reading both.
struct LedgerEntry: Codable, Hashable, Sendable {
    var cardPath: String     // card-relative
    var drivePath: String    // drive-relative
    var size: UInt64
    var quick: String        // quick fingerprint of the card file
    var hash: String         // XXH64
    var weak: Bool?          // verification was weaker than usual on this drive
    var closes: [String]?    // jobs cut off holding these bytes, closed by this read, which followed a confirmed flush
}

struct LedgerHeader: Codable, Hashable, Sendable {
    var job: String
    var started: Date
    var cardName: String
    var camera: CameraIdentity?
    var destination: String      // drive-relative root of the card tree
    var app: String
}

/// A step in a job's own record. `opened` is on the drive before the job writes anything. `sealed` goes down once the drive
/// has confirmed the job, and `refused` if it said no, which is weak for good. A job with neither was cut off: a pulled cable
/// or a crash. Its files aren't weak, just unfinished, and what a sealed job has will finish them: a confirmed flush, then
/// a full read. That closes them on the record, by naming the job, so it can only ever come after the job it closes.
private enum LedgerMark: String {
    case opened, sealed, refused
    var line: Data { Data("{\"mark\":\"\(rawValue)\"}\n".utf8) }
    static let prefix = Data("{\"mark\":".utf8)
    init?(line: Data.SubSequence) {
        guard line.starts(with: Self.prefix) else { return nil }
        guard let found = [Self.opened, .sealed, .refused].first(where: { $0.line.dropLast() == line }) else { return nil }
        self = found
    }
}

/// A file's real name, reserved or given back. Where a filesystem has no exclusive rename, a crash can leave the reservation
/// behind, and this is how a later job knows that empty file was the app's own and not someone else's.
enum NameNote: String {
    case reserve, release
    func line(_ path: String) -> Data? {
        guard var d = try? JSONEncoder().encode([rawValue: path]) else { return nil }
        d.append(0x0A)
        return d
    }
    static func read(_ line: Data.SubSequence) -> (note: NameNote, path: String)? {
        guard line.starts(with: Data("{\"reserve\":".utf8)) || line.starts(with: Data("{\"release\":".utf8)),
              let pair = (try? JSONDecoder().decode([String: String].self, from: Data(line)))?.first, let note = NameNote(rawValue: pair.key) else { return nil }
        return (note, pair.value)
    }
}

/// Append-only journal on the drive, one line per verified file, so a stopped job loses nothing and a card put back in
/// later is recognised at once. It travels with the drive.
public final class Ledger: @unchecked Sendable {
    let driveRoot: String
    /// This mount of the drive. A Ledger is only good for the mount it was made on.
    public let mount: MountAnchor?
    let root: ResolvedRoot?
    private var byKey: [String: [LedgerEntry]] = [:]
    private var byPath: [String: LedgerEntry] = [:]
    private let lock = NSLock()
    private var weakPaths: Set<String> = []
    private var weakContent: Set<String> = []       // size and full hash, so a weak copy stays weak under a new name
    private var reservations: [String: String] = [:]   // path → the job that reserved it and never finished with it
    private var unfinished: [String: Set<String>] = [:]    // size and hash → jobs cut off holding those bytes
    private var unfinishedPaths: Set<String> = []          // where those jobs put them
    private var closed: [String: Set<String>] = [:]        // size and hash → jobs a later read has closed

    public init(driveRoot: String, mount: MountAnchor? = nil) {
        self.driveRoot = driveRoot
        self.mount = mount ?? MountAnchor(path: driveRoot)
        root = ResolvedRoot(driveRoot)
        load()
    }

    private var folder: String { driveRoot + "/" + AppInfo.driveFolder + "/ledger" }
    private static func key(size: UInt64, quick: String) -> String { "\(size):\(quick)" }

    private func load() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        let dec = JSONDecoder()
        for n in names where n.hasSuffix(".jsonl") && !n.hasPrefix("._") {
            guard let data = FileManager.default.contents(atPath: folder + "/" + n) else { continue }
            var entries: [LedgerEntry] = []
            var opened = false, sealed = false, refused = false
            var reserved: Set<String> = []
            for line in data.split(separator: 0x0A).dropFirst() {  // the first line is the job header
                if let mark = LedgerMark(line: line) {
                    switch mark {
                    case .opened: opened = true
                    case .sealed: sealed = true
                    case .refused: refused = true
                    }
                } else if let (note, path) = NameNote.read(line) {
                    if note == .reserve { reserved.insert(path) } else { reserved.remove(path) }
                } else if let e = try? dec.decode(LedgerEntry.self, from: Data(line)) {     // a torn last line is simply skipped
                    entries.append(e)
                    reserved.remove(e.drivePath)
                }
            }
            let job = String(n.dropLast(".jsonl".count))
            // A journal with no `opened` is a check, or a job from before these marks: neither claims a flush was confirmed.
            let cutOff = opened && !sealed && !refused && !isLive(job: job)
            for var e in entries {
                if refused { e.weak = true }
                else if cutOff, e.closes == nil { noteUnfinished(e, job: job) }     // a closing read stands, whatever became of its job
                add(e)
            }
            for path in reserved { reservations[path] = job }
        }
    }

    /// Empty files at these paths are the app's own, left by a job that died holding the name.
    func abandonedReservations() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return reservations.compactMap { path, job in byPath[path]?.size == 0 || isLive(job: job) ? nil : path }
    }

    private func noteUnfinished(_ e: LedgerEntry, job: String) {
        unfinished[Self.content(bytes: e.size, hash: e.hash), default: []].insert(job)
        unfinishedPaths.insert(e.drivePath)
    }

    /// True if anything on this drive is waiting for a confirmed flush and a full read.
    var hasUnfinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return unfinished.contains { !$0.value.subtracting(closed[$0.key] ?? []).isEmpty }
    }

    /// The cut-off jobs still holding these bytes, as they'd be named by the read that closes them. A file with its own
    /// finished record at this path is that record's. Any other may be the same copy, moved or renamed.
    func unfinishedJobs(drivePath: String, bytes: UInt64, hash: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let key = Self.content(bytes: bytes, hash: hash)
        let open = (unfinished[key] ?? []).subtracting(closed[key] ?? [])
        if open.isEmpty { return [] }
        if let own = byPath[drivePath], own.size == bytes, own.hash == hash, !unfinishedPaths.contains(drivePath) { return [] }
        return open.sorted()
    }

    private func add(_ e: LedgerEntry) {
        byKey[Self.key(size: e.size, quick: e.quick), default: []].append(e)
        byPath[e.drivePath] = e
        if let jobs = e.closes { closed[Self.content(bytes: e.size, hash: e.hash), default: []].formUnion(jobs) }
        if e.weak == true {
            weakPaths.insert(e.drivePath)
            weakContent.insert(Self.content(bytes: e.size, hash: e.hash))
        }
    }

    private static func content(bytes: UInt64, hash: String) -> String { "\(bytes):\(hash)" }

    /// Where a copy of this card file was recorded, if it's still there. This is a hint about where to look, never proof:
    /// size and a head-and-tail fingerprint can't vouch for the middle of a clip, and the record can't vouch for the drive.
    /// Zero-sized listings never match: virtual volumes report 0 for real files.
    func entry(size: UInt64, quick: String) -> LedgerEntry? {
        guard size > 0 else { return nil }
        lock.lock(); let list = byKey[Self.key(size: size, quick: quick)] ?? []; lock.unlock()
        let present = list.filter { root?.stamp($0.drivePath)?.size == $0.size }
        // A good copy beside a weak one is the one to look at, or the weak one would hold the card back for good.
        lock.lock(); defer { lock.unlock() }
        return present.first { !weakPaths.contains($0.drivePath) } ?? present.first
    }

    /// What this drive's record says about a path, for a file that came from another card.
    func recorded(drivePath: String) -> LedgerEntry? {
        lock.lock(); defer { lock.unlock() }
        return byPath[drivePath]
    }

    /// A ledger, a saved setup and a job are all input from outside, so their paths must stay on the drive, and out of the
    /// folder that holds the app's own files.
    /// Split as the filesystem splits, by bytes: to Swift, a slash and the accent after it are one character.
    static func isInsideDrive(_ path: String) -> Bool {
        let parts = path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        return !path.utf8.starts(with: "/".utf8) && parts.first.map(matchKey) != matchKey(AppInfo.driveFolder) && !parts.contains("..") && !parts.contains(".")
    }

    fileprivate func remember(_ e: LedgerEntry) {
        lock.lock(); add(e); lock.unlock()
    }

    /// This copy was checked less strongly than usual, and that has to stay visible on every later visit. Unless the record
    /// at this path is for these very bytes, this may be that same copy moved or renamed, so the bytes are asked about too.
    func isWeak(drivePath: String, bytes: UInt64 = 0, hash: String = "") -> Bool {
        lock.lock(); defer { lock.unlock() }
        if weakPaths.contains(drivePath) { return true }
        if let own = byPath[drivePath], own.size == bytes, own.hash == hash { return false }
        return weakContent.contains(Self.content(bytes: bytes, hash: hash))
    }

    /// The drive can't be told, so at least this mount remembers.
    fileprivate func rememberWeak(_ entries: [LedgerEntry]) {
        for var e in entries { e.weak = true; remember(e) }
    }

    fileprivate func rememberUnfinished(_ entries: [LedgerEntry], job: String) {
        lock.lock(); defer { lock.unlock() }
        for e in entries where e.closes == nil { noteUnfinished(e, job: job) }
    }

    func open(_ header: LedgerHeader) throws -> LedgerJournal {
        _ = try Self.appFolder(on: driveRoot)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard let root, root.isPlainFolder(AppInfo.driveFolder + "/ledger") else { throw IngestError.driveNotWritable(driveRoot) }
        let path = folder + "/" + header.job + ".jsonl"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let fh = FileHandle(forWritingAtPath: path) else {
            throw IngestError.driveNotWritable(driveRoot)
        }
        flock(fh.fileDescriptor, LOCK_EX | LOCK_NB)      // held while the job lives. See `isLive`.
        let j = LedgerJournal(ledger: self, handle: fh, job: header.job)
        try j.write(header)
        return j
    }

    /// The app's own folder on a drive, made if it's missing. A link there is refused: it could lead to a card.
    public static func appFolder(on driveRoot: String) throws -> String {
        guard let root = ResolvedRoot(driveRoot) else { throw IngestError.driveNotWritable(driveRoot) }
        let path = root.file(AppInfo.driveFolder)
        if mkdir(path, 0o755) != 0 && errno != EEXIST { throw IngestError.driveNotWritable(driveRoot) }
        guard root.isPlainFolder(AppInfo.driveFolder) else { throw IngestError.driveNotWritable(driveRoot) }
        return path
    }

    /// Whether another job on this drive is running now. Its journal stays locked until it ends, or its process does.
    func isLive(job: String) -> Bool {
        let fd = Darwin.open(folder + "/" + job + ".jsonl", O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }
}

final class LedgerJournal: @unchecked Sendable {
    private let ledger: Ledger
    private let handle: FileHandle
    private let job: String
    private let enc: JSONEncoder
    private let lock = NSLock()
    private var lastSync = DispatchTime.now().uptimeNanoseconds
    private static let syncEvery: UInt64 = 250_000_000     // ns
    var fault: (@Sendable () -> Bool)?                     // tests: makes writing fail, as a dying drive would
    init(ledger: Ledger, handle: FileHandle, job: String) {
        self.ledger = ledger; self.handle = handle; self.job = job
        enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    }
    private func put(_ d: Data) throws {
        if fault?() == true { throw IngestError.driveNotWritable(ledger.driveRoot) }
        try handle.write(contentsOf: d)
    }
    private func sync() throws {
        if fault?() == true { throw IngestError.driveNotWritable(ledger.driveRoot) }
        try handle.synchronize()
    }
    /// All the way to the device, where it'll go. `synchronize` alone stops at the drive's cache.
    private func flush() throws {
        if fault?() == true { throw IngestError.driveNotWritable(ledger.driveRoot) }
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
    }
    fileprivate func write<T: Encodable>(_ v: T) throws {
        var d = try enc.encode(v)
        d.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try put(d)
    }
    /// A strong record only tells a later visit where to look, so losing one costs nothing: the file is found by name and
    /// proved by reading, as any copy is. A burst of tiny files shares a sync, at most one every quarter second, and a
    /// record can wait for the next one or for the end of the job. A weak mark is synced at once, because nothing else
    /// keeps it, and a failure to keep it is reported.
    func record(_ e: LedgerEntry) throws {
        if e.weak == true { ledger.rememberWeak([e]) }
        try write(e)
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if e.weak == true { try flush(); lastSync = now }
        else if now - lastSync >= Self.syncEvery { try sync(); lastSync = now }
        if e.weak != true { ledger.remember(e) }
    }
    /// Goes down before the job writes anything, and has to reach the drive, or the job doesn't start.
    func begin() throws {
        lock.lock(); defer { lock.unlock() }
        try put(LedgerMark.opened.line)
        try flush()
    }
    /// Says which real name was taken, or given back. Written on its own this can be lost with the drive, so a job doesn't
    /// rely on it for the names it takes: see `intend`.
    func note(_ note: NameNote, _ path: String) {
        lock.lock(); defer { lock.unlock() }
        if let line = note.line(path) { try? put(line) }
    }
    /// Every name this job may take, on the drive before it takes any of them. A pulled drive can keep a reservation and lose
    /// what was written just before it, so one flush now means a later job can always tell an empty file was the app's own.
    func intend(_ paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        for path in paths { if let line = NameNote.reserve.line(path) { try? put(line) } }
        try? flush()
    }
    /// Asks the drive to confirm the job with `flushVolume`. True only if it did and that's on the record. A drive that says
    /// no gets `refused`, which is weak for good. If even that can't be written, the job reads as cut off, and only a later
    /// confirmed flush and full read will finish it. A confirmation that can't be recorded leaves the job cut off too.
    func seal(_ entries: [LedgerEntry], flushVolume: () -> Int32) -> Bool {
        let flushed = flushVolume() == 0
        lock.lock(); defer { lock.unlock() }
        if flushed {
            do { try put(LedgerMark.sealed.line); try flush(); return true } catch { ledger.rememberUnfinished(entries, job: job) }
        } else {
            try? put(LedgerMark.refused.line)
            try? flush()
            ledger.rememberWeak(entries)
        }
        return false
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}
