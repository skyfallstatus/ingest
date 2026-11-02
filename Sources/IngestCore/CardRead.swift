import Foundation

public enum FileState: Hashable, Sendable {
    case missing
    case likely(drivePath: String)                  // same size and fingerprint. Not proof.
    case verified(drivePath: String, hash: String, bytes: UInt64 = 0)   // both sides read in full and equal
    case failed(String)
}

/// A file proved by reading both sides in full, and what it looked like then. Held in memory only, so quitting forgets
/// it, and nothing found on a drive can make one. It's good for that file as it was, never for whatever now has its name.
public struct Proof: Hashable, Sendable {
    public var state: FileState
    public var file: CardFile
    public var quick: String
    public init(state: FileState, file: CardFile, quick: String) { self.state = state; self.file = file; self.quick = quick }
    func holds(for f: CardFile, quick q: String) -> Bool {
        guard case .verified = state else { return false }
        return f.size == file.size && f.mtime == file.mtime && f.mtimeNanos == file.mtimeNanos && q == quick
    }
}

/// A card read: its files, their fingerprints.
public struct CardRead: Sendable {
    public var listing: CardListing
    public var quick: [String: String]              // relPath → fingerprint. Missing means it couldn't be opened.
    public var unreadable: [ListingError]           // listed, but won't open. Blocks "safe".
    public init(listing: CardListing, quick: [String: String], unreadable: [ListingError]) {
        self.listing = listing; self.quick = quick; self.unreadable = unreadable
    }
}

public enum CardReader {
    /// "Reading 148 of 148 files on the card…"
    public static func read(root: String, kind: @escaping (String) -> FileKind, progress: ((Int, Int) -> Void)? = nil) -> CardRead {
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
        return CardRead(listing: listing, quick: quick, unreadable: unreadable)
    }
}

private struct UnsafeMutableBufferPointerBox<T>: @unchecked Sendable {
    let buf: UnsafeMutableBufferPointer<T>
    init(_ b: UnsafeMutableBufferPointer<T>) { buf = b }
}
