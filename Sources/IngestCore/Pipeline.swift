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
    public static let emptyFoldersCode = "card.empty-folders"

    /// Per-file drive path. Cards are always kept whole: flattening breaks clips and collides names.
    /// Stills from a mixed card keep their own tree under the stills folder.
    static func drivePath(for file: CardFile, destination d: Destination, hasVideo: Bool) -> String {
        treeRoot(for: file, destination: d, hasVideo: hasVideo) + "/" + file.relPath
    }

    private static func treeRoot(for file: CardFile, destination d: Destination, hasVideo: Bool) -> String {
        if file.kind == .still, let s = d.stillsRoot { return s }
        if !hasVideo, let a = d.audioRoot { return a }
        return d.footageRoot
    }

    /// Every file that isn't already at its place in the folder this job is going to, plus the card's folders so empty ones
    /// survive. A whole card goes to one folder, whatever else is on the drive. A file is only left out if it's proved at that
    /// place on this drive as mounted now. A verified state on its own is a claim about wherever it was made, and `proved` is
    /// what ties it down. Whether the file is still that file is for `conclude`.
    public static func makeJob(read: CardRead, states: [String: FileState], proved: [String: Proof] = [:], cardName: String, driveRoot: String,
                               camera: CameraIdentity?, destination: Destination, probe: ProbeResult, index: DriveIndex?) -> IngestJob {
        var items: [IngestItem] = []
        var dirs: [String] = [destination.footageRoot]
        if let s = destination.stillsRoot, probe.hasStills { dirs.append(s) }
        // A card's folders go where its files go. With stills or audio alone, that isn't the footage folder.
        let treeRoots = Set(read.listing.files.map { treeRoot(for: $0, destination: destination, hasVideo: probe.hasVideo) })
        for root in treeRoots.isEmpty || treeRoots.contains(destination.footageRoot) ? [destination.footageRoot] : Array(treeRoots) {
            for d in read.listing.dirs { dirs.append(root + "/" + d) }
        }

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
            guard let quick = read.quick[f.relPath] else { continue }
            var path = drivePath(for: f, destination: destination, hasVideo: probe.hasVideo)
            if let dir = partnerDir[f.relPath] { path = dir + "/" + f.name }
            if case .verified(path, _, _)? = states[f.relPath], proved[f.relPath]?.isFor(driveRoot: driveRoot) == true { continue }
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
                                 message: "This drive couldn't confirm it has all of this copy, even though it matched when read. Check the footage plays before formatting."))
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
            guard let root else { checked[f.relPath] = .failed("the drive can't be reached"); continue }
            guard let quick = read.quick[f.relPath], let proof = proved[f.relPath], proof.state == states[f.relPath] else {
                checked[f.relPath] = .failed("nothing read in this session proved it")
                continue
            }
            if let why = proof.whyNot(for: f, quick: quick, on: root) { checked[f.relPath] = .failed(why) }
        }
        // Names and sizes alone can't tell a swapped card from the same card, so the fingerprints are taken again too.
        let again = CardReader.read(root: read.listing.root, kind: kind)
        // A device can report trouble only after the bytes have been read, so its log is read after them too.
        var now = issues.filter { !$0.code.hasPrefix("codex.") } + CardProber.deviceIssues(root: read.listing.root, files: read.listing.files)
        if let root, let missing = missingFolders(read: read, states: checked, root: root) { now.append(missing) }
        if let split = splitNote(read: read, states: checked) { now.append(split) }
        let verdict = Verdict.evaluate(listing: read.listing, unreadable: read.unreadable, states: checked, issues: now,
                                       cardUnchanged: read.listing.sameContents(as: again.listing) && read.quick == again.quick)
        return (verdict, checked, now)
    }

    /// Rule 14: empty folders survive, and some cameras need them. Files prove themselves, and a folder with nothing in it
    /// has no other way to, so it's looked for in every place this card's tree was found.
    private static func missingFolders(read: CardRead, states: [String: FileState], root: ResolvedRoot) -> CardIssue? {
        let dirs = read.listing.dirs
        guard !dirs.isEmpty, read.listing.files.allSatisfy({ if case .verified? = states[$0.relPath] { true } else { false } }) else { return nil }
        let leaves = dirs.filter { d in
            let inside = d + "/"
            return !read.listing.files.contains { $0.relPath.hasPrefix(inside) } && !dirs.contains { $0.hasPrefix(inside) }
        }
        guard !leaves.isEmpty else { return nil }
        var homes: Set<String> = []
        for f in read.listing.files {
            guard case .verified(let drive, _, _)? = states[f.relPath], drive.hasSuffix("/" + f.relPath) else { continue }
            homes.insert(String(drive.dropLast(f.relPath.count + 1)))
        }
        let absent = leaves.filter { d in !homes.contains { root.isPlainFolder($0 + "/" + d) } }
        guard !absent.isEmpty else { return nil }
        return CardIssue(severity: .hold, code: emptyFoldersCode,
                         message: "\(absent.count == 1 ? "An empty folder on the card, \((absent[0] as NSString).lastPathComponent), isn't" : "\(absent.count) empty folders on the card aren't") on the drive. Some cameras need them.",
                         paths: absent)
    }

    /// The one folder holding every file of this card at its own place. A card in two folders, or one that was renamed or
    /// sorted by hand, has none, and nothing can say where its empty folders belong.
    public static func home(read: CardRead, states: [String: FileState]) -> String? {
        var home: String?
        for f in read.listing.files {
            guard case .verified(let drive, _, _)? = states[f.relPath], drive.hasSuffix("/" + f.relPath) else { return nil }
            let here = String(drive.dropLast(f.relPath.count + 1))
            guard home == nil || home == here else { return nil }
            home = here
        }
        return home
    }

    /// The folders a card's footage is proved across, if that's more than one. Stills can have a folder of their own, so they're
    /// counted apart, and only footage counts: a marker every card shares can be proved anywhere.
    public static func homes(read: CardRead, states: [String: FileState]) -> [String] {
        var found: [Bool: Set<String>] = [:]
        for f in read.listing.files where f.kind == .video || f.kind == .audio || f.kind == .still {
            guard case .verified(let drive, _, _)? = states[f.relPath], drive.hasSuffix("/" + f.relPath) else { continue }
            found[f.kind == .still, default: []].insert(String(drive.dropLast(f.relPath.count + 1)))
        }
        return found.values.filter { $0.count > 1 }.flatMap { $0 }.sorted()
    }

    public static let splitCode = "card.split"

    /// Every byte can be proved with a card in two places, and that's no reason to hold it. But Safe is when someone tidies up.
    private static func splitNote(read: CardRead, states: [String: FileState]) -> CardIssue? {
        let homes = homes(read: read, states: states)
        guard let last = homes.last else { return nil }
        let names = homes.dropLast().joined(separator: ", ") + " and " + last
        return CardIssue(severity: .note, code: splitCode, message: "This card is proved across \(homes.count) folders: \(names). Keep \(homes.count == 2 ? "both" : "them all").", paths: homes)
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
