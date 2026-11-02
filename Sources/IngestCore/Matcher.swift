import Foundation

public enum CardMatcher {
    /// Largest number of same-sized files on the drive worth opening for one card file.
    private static let maxCandidates = 16
    public static let oneMiB: UInt64 = 1 << 20

    /// Nothing comes out of here `.verified` unless it's in `proved` and both files are still those files, on the same
    /// mounts: bytes read in full on both sides, while this card and this drive have stayed in.
    /// Everything else is at most `.likely`, and has to prove itself by being read.
    public static func match(read: CardRead, ledger: Ledger, index: DriveIndex?, driveRoot: String,
                             proved: [String: Proof] = [:]) -> [String: FileState] {
        var out: [String: FileState] = [:]
        var cache: [String: String] = [:]   // drive path → fingerprint
        let root = ResolvedRoot(driveRoot)
        var taken: Set<String> = []         // two files on a card with the same bytes are still two files
        for f in read.listing.files {
            if let quick = read.quick[f.relPath], let proof = proved[f.relPath], let root, proof.holds(for: f, quick: quick, on: root),
               case .verified(let p, _, _) = proof.state { taken.insert(p) }
        }
        for f in read.listing.files {
            guard let quick = read.quick[f.relPath] else { out[f.relPath] = .failed("won't open"); continue }
            if let proof = proved[f.relPath], let root, proof.holds(for: f, quick: quick, on: root) { out[f.relPath] = proof.state; continue }
            if let e = ledger.entry(size: f.size, quick: quick, notAt: taken) {
                out[f.relPath] = .likely(drivePath: e.drivePath)
                taken.insert(e.drivePath)
                continue
            }
            guard let index else { out[f.relPath] = .missing; continue }
            // A large file with the same size is a candidate wherever it is and whatever it's called,
            // so hand-sorted or renamed rushes are still found. Small files must share the name too.
            var candidates = index.files(ofSize: f.size)
            if f.size < oneMiB {
                let key = matchKey(f.name)
                candidates = candidates.filter { matchKey(($0.path as NSString).lastPathComponent) == key }
            }
            // Prefer a copy with the same trailing path: it's the one we'd want to point at.
            candidates.sort { sharedTail($0.path, f.relPath) > sharedTail($1.path, f.relPath) }
            var found: String?
            for c in candidates.filter({ !taken.contains($0.path) }).prefix(maxCandidates) {
                let fp: String?
                if let hit = cache[c.path] { fp = hit }
                else { fp = fingerprint(path: driveRoot + "/" + c.path).map(hexHash); cache[c.path] = fp }
                if fp == quick { found = c.path; break }
            }
            if let found { taken.insert(found) }
            out[f.relPath] = found.map { .likely(drivePath: $0) } ?? .missing
        }
        return out
    }

    /// Whether this card can join `home` without overwriting anything: every file already at its place there has the card's size
    /// and ends. A camera rewrites its index as it films, so a card filmed further can't, and takes a new folder of its own.
    public static func canJoin(home: String, read: CardRead, driveRoot: String) -> Bool {
        for f in read.listing.files {
            let path = driveRoot + "/" + home + "/" + f.relPath
            var st = stat()
            guard lstat(path, &st) == 0, st.st_size > 0 else { continue }
            guard UInt64(st.st_size) == f.size, let quick = read.quick[f.relPath], fingerprint(path: path).map(hexHash) == quick else { return false }
        }
        return true
    }

    private static func sharedTail(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: "/").reversed(), y = b.split(separator: "/").reversed()
        return zip(x, y).prefix { $0 == $1 }.count
    }

    /// Where earlier parts of this card already live, so the rest can join them.
    /// Returns the drive-relative folder that plays the role of the card root.
    /// Only substantial footage counts: every card of a camera shares marker files, some of them over a megabyte, which say
    /// nothing about which card this is.
    /// Clips come first: stills have a folder of their own, and more of them doesn't make that the card's home.
    public static func existingHome(states: [String: FileState], files: [CardFile]) -> String? {
        existingHome(states: states, files: files, kinds: [.video, .audio]) ?? existingHome(states: states, files: files, kinds: [.still])
    }

    public static func existingHome(states: [String: FileState], files: [CardFile], kinds: Set<FileKind>, smallestFile: UInt64 = oneMiB) -> String? {
        var counts: [String: Int] = [:]
        let sizes = Dictionary(files.filter { kinds.contains($0.kind) }.map { ($0.relPath, $0.size) }, uniquingKeysWith: { a, _ in a })
        for (rel, s) in states where sizes[rel].map({ $0 >= smallestFile }) == true {
            let drive: String
            switch s {
            case .likely(let p), .verified(let p, _, _): drive = p
            default: continue
            }
            let tail = "/" + rel
            guard drive.hasSuffix(tail) else { continue }       // only a whole-tree copy is a home
            counts[String(drive.dropLast(tail.count)), default: 0] += 1
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}
