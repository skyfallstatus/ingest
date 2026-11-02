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
    /// A file is only left out if it's proved on this drive as mounted now. A verified state on its own is a claim about
    /// wherever it was made, and `proved` is what ties it down. Whether the file is still that file is for `conclude`.
    public static func makeJob(read: CardRead, states: [String: FileState], proved: [String: Proof] = [:], cardName: String, driveRoot: String,
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
            // Two files of that name means two takes, and nothing here can say which is the partner.
            let hits = index.files(named: partner)
            if hits.count == 1, let hit = hits.first, hit.size > 0 { partnerDir[f.relPath] = (hit.path as NSString).deletingLastPathComponent }
        }
        for f in read.listing.files {
            if case .verified? = states[f.relPath], proved[f.relPath]?.isFor(driveRoot: driveRoot) == true { continue }
            guard let quick = read.quick[f.relPath] else { continue }
            var path = drivePath(for: f, destination: destination, hasVideo: probe.hasVideo)
            if let dir = partnerDir[f.relPath] { path = dir + "/" + f.name }
            items.append(IngestItem(file: f, drivePath: path, quick: quick))
        }
        return IngestJob(cardRoot: read.listing.root, cardName: cardName, driveRoot: driveRoot, camera: camera,
                         destination: destination.footageRoot, dirsToCreate: dirs, items: items, cardMount: read.mount)
    }

    /// Re-applies what only the finished state can settle: halves now together, weak flushes reported.
    /// A hold for a missing half clears only for a real partner beside this half: its own proved file on this card, or a
    /// file this drive's record says was proved from another card and still looks it. A name on its own isn't a partner.
    public static func settle(issues: [CardIssue], states: [String: FileState], weak: Bool, driveRoot: String, ledger: Ledger? = nil) -> [CardIssue] {
        let root = ResolvedRoot(driveRoot)
        func partnerStands(_ path: String) -> Bool {
            guard let root, let stamp = root.stamp(path), stamp.size > 0 else { return false }
            if states.values.contains(where: { if case .verified(path, _, _) = $0 { true } else { false } }) { return true }
            guard let record = ledger?.recorded(drivePath: path), record.weak != true, record.size == stamp.size else { return false }
            return fingerprint(path: root.file(path)).map(hexHash) == record.quick
        }
        var out: [CardIssue] = []
        for i in issues {
            guard i.code == "braw.striped" else { out.append(i); continue }
            let unresolved = i.paths.filter { rel in
                guard let partner = CardProber.stripedPartnerName(of: rel) else { return false }
                guard case .verified(let drive, _, _)? = states[rel] else { return true }
                return !partnerStands((drive as NSString).deletingLastPathComponent + "/" + partner)
            }
            if !unresolved.isEmpty { out.append(CardIssue(severity: i.severity, code: i.code, message: i.message, paths: unresolved)) }
        }
        if weak {
            out.append(CardIssue(severity: .hold, code: "drive.weak-verify",
                                 message: "This copy couldn't be checked as strictly as usual: a flush wasn't confirmed, or a cache wouldn't clear. Check the footage plays before formatting."))
        }
        return out
    }

    /// The last look before anything turns green: every file is still the file that was proved, on the mounts it was proved
    /// on, the card hasn't changed, and what the card's own device has logged since is taken into account.
    public static func conclude(read: CardRead, states: [String: FileState], proved: [String: Proof], issues: [CardIssue], driveRoot: String,
                                kind: @escaping (String) -> FileKind) -> (verdict: CardVerdict, states: [String: FileState], issues: [CardIssue]) {
        var checked = states
        let root = ResolvedRoot(driveRoot)
        for f in read.listing.files {
            guard case .verified? = states[f.relPath] else { continue }
            guard let root, let quick = read.quick[f.relPath], let proof = proved[f.relPath],
                  proof.state == states[f.relPath], proof.holds(for: f, quick: quick, on: root) else {
                checked[f.relPath] = .missing
                continue
            }
        }
        // Names and sizes alone can't tell a swapped card from the same card, so the fingerprints are taken again too.
        let again = CardReader.read(root: read.listing.root, kind: kind)
        // A device can report trouble only after the bytes have been read, so its log is read after them too.
        let now = issues.filter { !$0.code.hasPrefix("codex.") } + CardProber.deviceIssues(root: read.listing.root, files: read.listing.files)
        let verdict = Verdict.evaluate(listing: read.listing, unreadable: read.unreadable, states: checked, issues: now,
                                       cardUnchanged: read.listing.sameContents(as: again.listing) && read.quick == again.quick)
        return (verdict, checked, now)
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
