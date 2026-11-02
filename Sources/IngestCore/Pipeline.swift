import Foundation

/// Where a card goes on the drive.
public struct Destination: Hashable, Sendable {
    public var footageRoot: String          // drive-relative: receives the card tree
    public var stillsRoot: String?          // drive-relative: receives stills from a mixed card
    public var audioRoot: String?           // drive-relative: receives an audio recorder's card
    public init(footageRoot: String, stillsRoot: String? = nil, audioRoot: String? = nil) {
        self.footageRoot = footageRoot; self.stillsRoot = stillsRoot; self.audioRoot = audioRoot
    }
}

public enum Pipeline {
    /// Per-file drive path. Cards are always kept whole: flattening breaks clips and collides names.
    /// Stills from a mixed card keep their own tree under the stills folder.
    static func drivePath(for file: CardFile, destination d: Destination, hasVideo: Bool) -> String {
        var root = d.footageRoot
        if file.kind == .still, let s = d.stillsRoot { root = s }
        else if !hasVideo, let a = d.audioRoot { root = a }
        return root + "/" + file.relPath
    }

    /// Everything still to copy, plus the card's folders so empty ones survive.
    public static func makeJob(read: CardRead, states: [String: FileState], cardName: String, driveRoot: String,
                               camera: CameraIdentity?, destination: Destination, probe: ProbeResult, index: DriveIndex?) -> IngestJob {
        var items: [IngestItem] = []
        var dirs: [String] = [destination.footageRoot]
        if let s = destination.stillsRoot, probe.hasStills { dirs.append(s) }
        for d in read.listing.dirs { dirs.append(destination.footageRoot + "/" + d) }

        // Striped BRAW only merges when both halves share a folder, so a half joins its partner.
        // Only paths the probe flagged: the name mapping alone would claim every .braw is striped.
        var partnerDir: [String: String] = [:]
        let striped = Set(probe.issues.filter { $0.code == "braw.striped" }.flatMap(\.paths))
        for f in read.listing.files where striped.contains(f.relPath) {
            guard let partner = CardProber.stripedPartnerName(of: f.relPath), let index else { continue }
            if let hit = index.files(named: partner).first { partnerDir[f.relPath] = (hit.path as NSString).deletingLastPathComponent }
        }
        for f in read.listing.files {
            switch states[f.relPath] {
            case .verified: continue
            default: break
            }
            guard let quick = read.quick[f.relPath] else { continue }
            var path = drivePath(for: f, destination: destination, hasVideo: probe.hasVideo)
            if let dir = partnerDir[f.relPath] { path = dir + "/" + f.name }
            items.append(IngestItem(file: f, drivePath: path, quick: quick))
        }
        return IngestJob(cardRoot: read.listing.root, cardName: cardName, driveRoot: driveRoot, camera: camera,
                         destination: destination.footageRoot, dirsToCreate: dirs, items: items)
    }

    /// Re-applies what only the finished state can settle: halves now together, weak flushes reported.
    public static func settle(issues: [CardIssue], states: [String: FileState], weak: Bool, driveRoot: String) -> [CardIssue] {
        var out: [CardIssue] = []
        for i in issues {
            guard i.code == "braw.striped" else { out.append(i); continue }
            let unresolved = i.paths.filter { rel in
                guard let partner = CardProber.stripedPartnerName(of: rel) else { return false }
                guard case .verified(let drive, _, _)? = states[rel] else { return true }
                let dir = (drive as NSString).deletingLastPathComponent
                return !IngestEngine.pathExists(driveRoot + "/" + dir + "/" + partner)
            }
            if !unresolved.isEmpty { out.append(CardIssue(severity: i.severity, code: i.code, message: i.message, paths: unresolved)) }
        }
        if weak {
            out.append(CardIssue(severity: .hold, code: "drive.weak-verify",
                                 message: "This drive wouldn't confirm it had finished writing. Check the footage plays before formatting."))
        }
        return out
    }

    /// The last look before anything turns green: the drive still holds every file, and the card hasn't changed.
    public static func conclude(read: CardRead, states: [String: FileState], issues: [CardIssue], driveRoot: String,
                                kind: @escaping (String) -> FileKind) -> (verdict: CardVerdict, states: [String: FileState]) {
        var checked = states
        for f in read.listing.files {
            guard case .verified(let drive, _, _)? = states[f.relPath] else { continue }
            var st = stat()
            if lstat(driveRoot + "/" + drive, &st) != 0 || (UInt64(st.st_size) != f.size && f.size != 0) {
                checked[f.relPath] = .missing
            }
        }
        // Names and sizes alone can't tell a swapped card from the same card, so the fingerprints are taken again too.
        let again = CardReader.read(root: read.listing.root, kind: kind)
        let verdict = Verdict.evaluate(listing: read.listing, unreadable: read.unreadable, states: checked, issues: issues,
                                       cardUnchanged: read.listing.sameContents(as: again.listing) && read.quick == again.quick)
        return (verdict, checked)
    }

    /// Writes the manifest for what this job verified under its destination.
    /// A card's own `ascmhl` history was copied and verified byte for byte, so appending would change a proved file.
    /// In that case the card's history stands, and this returns false.
    @discardableResult
    public static func writeManifest(job: IngestJob, states: [String: FileState], read: CardRead) throws -> Bool {
        if read.listing.files.contains(where: { $0.relPath.lowercased().hasPrefix("ascmhl/") }) { return false }
        let prefix = job.destination + "/"
        var rows: [ASCMHL.Row] = []
        for f in read.listing.files {
            guard case .verified(let drive, let hash, let bytes)? = states[f.relPath], drive.hasPrefix(prefix) else { continue }
            rows.append(ASCMHL.Row(path: String(drive.dropFirst(prefix.count)), size: bytes, mtime: f.mtime, hash: hash))
        }
        guard !rows.isEmpty else { return false }
        try ASCMHL.write(root: job.driveRoot + "/" + job.destination, rows: rows)
        return true
    }
}
