import Foundation

public enum FileState: Hashable, Sendable {
    case missing
    case likely(drivePath: String)                  // same size and fingerprint. Not proof.
    case verified(drivePath: String, hash: String, bytes: UInt64 = 0)   // both sides read in full and equal
    case failed(String)
}

extension FileState {
    /// Why a file failed when a copy on the drive is what's wrong. That copy is still there.
    public static let badCopy = "the copy on the drive doesn't match the card"
    public static let nameTaken = "a different file already has that name on the drive"
    public var isBadCopyOnDrive: Bool { if case .failed(let why) = self { why == Self.badCopy || why == Self.nameTaken } else { false } }
}

/// A file proved by reading both sides in full, and what both sides looked like then. Held in memory only, so quitting
/// forgets it, and nothing found on a drive can make one. It only ever made a claim about this mount of this card and
/// this mount of this drive, for this destination file, so it's checked against all of that each time it's used.
public struct Proof: Hashable, Sendable {
    public var state: FileState
    public var file: CardFile
    public var quick: String
    var stamp: DriveStamp
    var card: MountAnchor
    var drive: MountAnchor

    /// Still about this drive as it's mounted now. Says nothing about the file: it's what a job needs to skip one.
    func isFor(driveRoot: String) -> Bool { drive.path == driveRoot && drive.isCurrent && card.isCurrent }

    /// The card file and the drive file are both the ones that were read, on the mounts they were read on.
    func holds(for f: CardFile, quick q: String, on root: ResolvedRoot) -> Bool { whyNot(for: f, quick: q, on: root) == nil }

    /// What stopped this proof holding, in words for a person. Nil while it holds.
    func whyNot(for f: CardFile, quick q: String, on root: ResolvedRoot) -> String? {
        guard case .verified(let path, _, let bytes) = state else { return "it wasn't proved" }
        if !card.isCurrent { return "the card came out after this file was proved" }
        if !drive.isCurrent { return "the drive was unplugged after this file was proved" }
        guard f.size == 0 || bytes == f.size else { return "its read stopped short of the size the card lists" }
        guard f.size == file.size && f.mtime == file.mtime && f.mtimeNanos == file.mtimeNanos && q == quick else { return "it changed on the card after it was proved" }
        guard let now = root.stamp(path) else { return "it's no longer on the drive" }
        return now == stamp ? nil : "it changed on the drive after it was proved"
    }
}

/// A card read: its files, their fingerprints, and the mount they were read from.
public struct CardRead: Sendable {
    public var listing: CardListing
    public var quick: [String: String]              // relPath → fingerprint. Missing means it couldn't be opened.
    public var unreadable: [ListingError]           // listed, but won't open. Blocks "safe".
    public var mount: MountAnchor?                  // nil, and nothing read here can ever be proved
    public init(listing: CardListing, quick: [String: String], unreadable: [ListingError], mount: MountAnchor? = nil) {
        self.listing = listing; self.quick = quick; self.unreadable = unreadable; self.mount = mount
    }
}

public enum CardReader {
    /// "Reading 148 of 148 files on the card…"
    /// `mount` is the mount the caller knows this card by. Without one, this mount is taken before anything is read.
    public static func read(root: String, kind: @escaping (String) -> FileKind, mount: MountAnchor? = nil,
                            progress: ((Int, Int) -> Void)? = nil) -> CardRead {
        let mount = mount ?? MountAnchor(path: root)
        let listing = listCard(root: root, kind: kind)
        let files = listing.files
        var results = [String?](repeating: nil, count: files.count)
        let lock = NSLock()
        var done = 0
        results.withUnsafeMutableBufferPointer { buf in
            let ptr = UnsafeMutableBufferPointerBox(buf)
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let h = fingerprint(path: root + "/" + files[i].relPath).map(hexHash)
                lock.lock(); ptr.buf[i] = h; done += 1; let d = done; lock.unlock()
                if d % 8 == 0 || d == files.count { progress?(d, files.count) }
            }
        }
        var quick: [String: String] = [:]
        var unreadable: [ListingError] = []
        for (i, f) in files.enumerated() {
            if let h = results[i] { quick[f.relPath] = h }
            else { unreadable.append(ListingError(path: f.relPath, reason: "listed on the card but it won't open")) }
        }
        return CardRead(listing: listing, quick: quick, unreadable: unreadable, mount: mount)
    }
}

private struct UnsafeMutableBufferPointerBox<T>: @unchecked Sendable {
    let buf: UnsafeMutableBufferPointer<T>
    init(_ b: UnsafeMutableBufferPointer<T>) { buf = b }
}
