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

/// Append-only journal on the drive, one line per verified file, so a stopped or crashed job loses nothing
/// and a card put back in later is recognised at once. It travels with the drive.
public final class Ledger: @unchecked Sendable {
    let driveRoot: String
    private var byKey: [String: [LedgerEntry]] = [:]
    private let lock = NSLock()
    private var weakPaths: Set<String> = []

    public init(driveRoot: String) {
        self.driveRoot = driveRoot
        load()
    }

    private var folder: String { driveRoot + "/" + AppInfo.driveFolder + "/ledger" }
    private static func key(size: UInt64, quick: String) -> String { "\(size):\(quick)" }

    private func load() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        let dec = JSONDecoder()
        for n in names where n.hasSuffix(".jsonl") && !n.hasPrefix("._") {
            guard let data = FileManager.default.contents(atPath: folder + "/" + n) else { continue }
            for line in data.split(separator: 0x0A).dropFirst() {  // the first line is the job header
                if let e = try? dec.decode(LedgerEntry.self, from: Data(line)) { add(e) }  // a torn last line is simply skipped
            }
        }
    }

    private func add(_ e: LedgerEntry) {
        byKey[Self.key(size: e.size, quick: e.quick), default: []].append(e)
        if e.weak == true { weakPaths.insert(e.drivePath) }
    }

    /// Where a copy of this card file was recorded, if it's still there. This is a hint about where to look, never proof:
    /// size and a head-and-tail fingerprint can't vouch for the middle of a clip, and the record can't vouch for the drive.
    /// Zero-sized listings never match: virtual volumes report 0 for real files.
    func entry(size: UInt64, quick: String) -> LedgerEntry? {
        guard size > 0 else { return nil }
        lock.lock(); let list = byKey[Self.key(size: size, quick: quick)] ?? []; lock.unlock()
        for e in list {
            guard Self.isInsideDrive(e.drivePath) else { continue }
            var st = stat()
            if lstat(driveRoot + "/" + e.drivePath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, UInt64(st.st_size) == e.size { return e }
        }
        return nil
    }

    /// A ledger is a file on a drive, so it's untrusted input: its paths must stay on the drive.
    static func isInsideDrive(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    fileprivate func remember(_ e: LedgerEntry) {
        lock.lock(); add(e); lock.unlock()
    }

    /// This copy was checked less strongly than usual, and that has to stay visible on every later visit.
    func isWeak(drivePath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return weakPaths.contains(drivePath)
    }

    func open(_ header: LedgerHeader) throws -> LedgerJournal {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + header.job + ".jsonl"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let fh = FileHandle(forWritingAtPath: path) else {
            throw IngestError.driveNotWritable(driveRoot)
        }
        let j = LedgerJournal(ledger: self, handle: fh)
        try j.write(header)
        return j
    }
}

final class LedgerJournal: @unchecked Sendable {
    private let ledger: Ledger
    private let handle: FileHandle
    private let enc: JSONEncoder
    private let lock = NSLock()
    private var lastSync = DispatchTime.now().uptimeNanoseconds
    private static let syncEvery: UInt64 = 250_000_000     // ns
    init(ledger: Ledger, handle: FileHandle) {
        self.ledger = ledger; self.handle = handle
        enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    }
    fileprivate func write<T: Encodable>(_ v: T) throws {
        var d = try enc.encode(v)
        d.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try handle.write(contentsOf: d)
    }
    /// A record is only written once its file is proved and in place, so any record that survives is true. A burst of tiny
    /// files shares a sync: a drive pulled that moment can lose the last quarter second of records, and those files are
    /// then found by name and proved by reading, as any copy is. A weak mark is synced at once, because nothing else keeps it.
    func record(_ e: LedgerEntry) throws {
        try write(e)
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if e.weak == true || now - lastSync >= Self.syncEvery {
            try? handle.synchronize()
            lastSync = now
        }
        lock.unlock()
        ledger.remember(e)
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}
