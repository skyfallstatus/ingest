import Foundation

/// One file whose bytes were proved identical on the card and the drive, by reading both.
struct LedgerEntry: Codable, Hashable, Sendable {
    var cardPath: String     // card-relative
    var drivePath: String    // drive-relative
    var size: UInt64
    var quick: String        // quick fingerprint of the card file
    var hash: String         // XXH64
    var weak: Bool?          // verification was weaker than usual on this drive
}

struct LedgerHeader: Codable, Hashable, Sendable {
    var job: String
    var started: Date
    var cardName: String
    var camera: CameraIdentity?
    var destination: String      // drive-relative root of the card tree
    var app: String
}

/// A step in a job's own record. `finishing` goes down before the drive is asked to confirm the job, and `sealed` once it
/// has. A job that reached the first and not the second never got that confirmation, however the job ended, and even if
/// nothing more could be written after it, so every file in it stays weak.
private enum LedgerMark: String {
    case finishing, sealed
    var line: Data { Data("{\"mark\":\"\(rawValue)\"}\n".utf8) }
    static let prefix = Data("{\"mark\":".utf8)
    init?(line: Data.SubSequence) {
        guard line.starts(with: Self.prefix) else { return nil }
        guard let found = [Self.finishing, .sealed].first(where: { $0.line.dropLast() == line }) else { return nil }
        self = found
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
            var finishing = false, sealed = false
            for line in data.split(separator: 0x0A).dropFirst() {  // the first line is the job header
                switch LedgerMark(line: line) {
                case .finishing: finishing = true
                case .sealed: sealed = true
                case nil:
                    if let e = try? dec.decode(LedgerEntry.self, from: Data(line)) { entries.append(e) }  // a torn last line is simply skipped
                }
            }
            let unconfirmed = finishing && !sealed
            for var e in entries {
                if unconfirmed { e.weak = true }
                add(e)
            }
        }
    }

    private func add(_ e: LedgerEntry) {
        byKey[Self.key(size: e.size, quick: e.quick), default: []].append(e)
        byPath[e.drivePath] = e
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
        return list.first { root?.stamp($0.drivePath)?.size == $0.size }
    }

    /// What this drive's record says about a path, for a file that came from another card.
    func recorded(drivePath: String) -> LedgerEntry? {
        lock.lock(); defer { lock.unlock() }
        return byPath[drivePath]
    }

    /// A ledger, a saved setup and a job are all input from outside, so their paths must stay on the drive, and out of the
    /// folder that holds the app's own files.
    static func isInsideDrive(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && parts.first != Substring(AppInfo.driveFolder) && !parts.contains("..") && !parts.contains(".")
    }

    fileprivate func remember(_ e: LedgerEntry) {
        lock.lock(); add(e); lock.unlock()
    }

    /// This copy was checked less strongly than usual, and that has to stay visible on every later visit. A file with no
    /// record of its own at this path may be that same copy moved or renamed, so its bytes are asked about too.
    func isWeak(drivePath: String, bytes: UInt64 = 0, hash: String = "") -> Bool {
        lock.lock(); defer { lock.unlock() }
        return weakPaths.contains(drivePath) || (byPath[drivePath] == nil && weakContent.contains(Self.content(bytes: bytes, hash: hash)))
    }

    /// The drive can't be told, so at least this mount remembers.
    fileprivate func rememberWeak(_ entries: [LedgerEntry]) {
        for var e in entries { e.weak = true; remember(e) }
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
        let j = LedgerJournal(ledger: self, handle: fh)
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
    private let enc: JSONEncoder
    private let lock = NSLock()
    private var lastSync = DispatchTime.now().uptimeNanoseconds
    private static let syncEvery: UInt64 = 250_000_000     // ns
    var fault: (@Sendable () -> Bool)?                     // tests: makes writing fail, as a dying drive would
    init(ledger: Ledger, handle: FileHandle) {
        self.ledger = ledger; self.handle = handle
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
        if e.weak == true || now - lastSync >= Self.syncEvery {
            try sync()
            lastSync = now
        }
        if e.weak != true { ledger.remember(e) }
    }
    /// Asks the drive to confirm the job, with `sync`. True only if it did and that's on the record. Anything else leaves
    /// the job weak on every later visit: `finishing` is already on the drive by then, and `sealed` never gets there.
    func seal(_ entries: [LedgerEntry], sync: () -> Int32) -> Bool {
        func mark(_ m: LedgerMark) -> Bool {
            lock.lock(); defer { lock.unlock() }
            do { try put(m.line); try sync(); return true } catch { return false }
        }
        let marked = mark(.finishing)
        let synced = sync() == 0
        guard marked, synced, mark(.sealed) else {
            ledger.rememberWeak(entries)
            return false
        }
        return true
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}
