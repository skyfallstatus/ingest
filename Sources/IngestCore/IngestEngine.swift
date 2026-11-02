import CIngest
import Foundation

public struct IngestItem: Sendable {
    public var file: CardFile
    public var drivePath: String    // drive-relative final path
    public var quick: String
}

public struct IngestJob: Sendable {
    public var id = UUID().uuidString
    public var cardRoot: String
    public var cardName: String
    public var driveRoot: String
    public var camera: CameraIdentity?
    public var destination: String          // drive-relative root of the card tree
    public var dirsToCreate: [String]       // drive-relative, including the card's own empty folders
    public var items: [IngestItem]          // only the files that still need copying
    public var cardMount: MountAnchor?      // the mount the card was read from
}

public struct IngestProgress: Sendable {
    public enum Phase: Sendable { case copying, checking, finishing }
    public var phase: Phase
    public var fileIndex: Int           // 1-based, the file being worked on
    public var fileCount: Int
    public var verifiedFiles: Int
    public var bytesCopied: UInt64
    public var bytesTotal: UInt64
    public var currentName: String
    public init(phase: Phase, fileIndex: Int, fileCount: Int, verifiedFiles: Int, bytesCopied: UInt64, bytesTotal: UInt64, currentName: String) {
        self.phase = phase; self.fileIndex = fileIndex; self.fileCount = fileCount; self.verifiedFiles = verifiedFiles
        self.bytesCopied = bytesCopied; self.bytesTotal = bytesTotal; self.currentName = currentName
    }
}

public struct IngestOutcome: Sendable {
    public var states: [String: FileState]
    public var proofs: [String: Proof]  // what `states` calls verified, tied to the files and mounts it read
    public var cancelled: Bool
    public var weakVerification: Bool   // the drive wouldn't confirm a flush, or the cache couldn't be bypassed
    public var failures: [String] { states.compactMap { if case .failed = $0.value { $0.key } else { nil } } }
}

/// Lets tests break things at the worst moment. Unused in the app.
public struct FaultHooks: Sendable {
    public var afterCopy: (@Sendable (_ tempPath: String, _ sourcePath: String, _ attempt: Int) -> Void)?
    public var syncVolume: (@Sendable (_ driveRoot: String) -> Int32)?
    public var journalFails: (@Sendable () -> Bool)?
    public init(afterCopy: (@Sendable (String, String, Int) -> Void)? = nil, syncVolume: (@Sendable (String) -> Int32)? = nil,
                journalFails: (@Sendable () -> Bool)? = nil) {
        self.afterCopy = afterCopy; self.syncVolume = syncVolume; self.journalFails = journalFails
    }
}

/// Thread-safe stop flag and byte counter shared with the C layer.
public final class IngestControl: @unchecked Sendable {
    let cancelFlag = UnsafeMutablePointer<atomic_int_shim>.allocate(capacity: 1)
    let copied = UnsafeMutablePointer<atomic_u64_shim>.allocate(capacity: 1)
    let checked = UnsafeMutablePointer<atomic_u64_shim>.allocate(capacity: 1)
    public init() {
        cancelFlag.initialize(to: atomic_int_shim()); copied.initialize(to: atomic_u64_shim()); checked.initialize(to: atomic_u64_shim())
    }
    deinit { cancelFlag.deallocate(); copied.deallocate(); checked.deallocate() }
    public func stop() { ci_store_int(cancelFlag, 1) }
    /// Ready to run again after a stop.
    public func reset() { ci_store_int(cancelFlag, 0); ci_store_u64(copied, 0); ci_store_u64(checked, 0) }
    public var isStopped: Bool { ci_load_int(cancelFlag) != 0 }
    public var bytesCopied: UInt64 { ci_load_u64(copied) }
    /// Bytes read from the card a second time, for the proof.
    public var bytesChecked: UInt64 { ci_load_u64(checked) }
}

public enum IngestEngine {
    /// Space check first, so a job never starts that can't finish.
    /// With `ledger`, what a dead job left in `.ingest/tmp` counts as free: the job will clear it, if it's allowed to start.
    public static func preflight(job: IngestJob, ledger: Ledger? = nil) throws {
        // A card can't be copied onto itself, by any name.
        let drive = ResolvedRoot(job.driveRoot)?.path ?? job.driveRoot, card = ResolvedRoot(job.cardRoot)?.path ?? job.cardRoot
        if drive == card || drive.hasPrefix(card + "/") { throw IngestError.sameVolume }
        // Every path here came from somewhere that isn't this engine: a saved setup, a drive's index, a person.
        for rel in [job.destination] + job.dirsToCreate + job.items.map(\.drivePath) where !Ledger.isInsideDrive(rel) {
            throw IngestError.outsideDrive(rel)
        }
        let need = job.items.reduce(UInt64(0)) { $0 + $1.file.size }
        var fs = statfs()
        guard statfs(job.driveRoot, &fs) == 0 else { throw IngestError.driveNotWritable(job.driveRoot) }
        var free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        if let ledger, let root = ResolvedRoot(job.driveRoot) {
            for temp in staleTemps(folder: root.file(tempFolder), ledger: ledger) {
                var st = stat()
                if lstat(temp, &st) == 0 { free += UInt64(st.st_size) }
            }
        }
        let margin: UInt64 = 256 * 1024 * 1024 + UInt64(job.items.count) * 256 * 1024  // ledger, manifests, cluster slack
        if need + margin > free { throw IngestError.notEnoughSpace(needed: need + margin, free: free) }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if type == "msdos" || type == "fat32", let big = job.items.first(where: { $0.file.size >= 1 << 32 }) {
            throw IngestError.fileTooLarge(big.file.name)
        }
    }

    public static func run(job: IngestJob, ledger: Ledger, control: IngestControl, hooks: FaultHooks = FaultHooks(),
                           progress: @escaping @Sendable (IngestProgress) -> Void) throws -> IngestOutcome {
        try preflight(job: job, ledger: ledger)
        guard let root = ResolvedRoot(job.driveRoot), let card = ResolvedRoot(job.cardRoot) else { throw IngestError.driveNotWritable(job.driveRoot) }
        let journal = try ledger.open(LedgerHeader(job: job.id, started: Date(), cardName: job.cardName, camera: job.camera,
                                                   destination: job.destination, app: "\(AppInfo.name) \(AppInfo.version)"))
        defer { journal.close() }
        try journal.begin()
        journal.fault = hooks.journalFails

        var made = Set<String>()
        try makeDir(tempFolder, root: root, made: &made)
        sweep(root: root, ledger: ledger)
        for d in job.dirsToCreate { try makeDir(d, root: root, made: &made) }

        let total = job.items.reduce(UInt64(0)) { $0 + $1.file.size }
        var states: [String: FileState] = [:]
        var proofs: [String: Proof] = [:]
        var weak = false
        var verified = 0
        var recorded: [LedgerEntry] = []
        let cardMount = job.cardMount ?? MountAnchor(path: job.cardRoot)

        func report(_ phase: IngestProgress.Phase, _ i: Int, _ name: String) {
            progress(IngestProgress(phase: phase, fileIndex: i + 1, fileCount: job.items.count, verifiedFiles: verified,
                                    bytesCopied: control.bytesCopied, bytesTotal: total, currentName: name))
        }

        func entry(_ item: IngestItem, hash: UInt64, bytes: UInt64, weak: Bool, closes: [String]? = nil) -> LedgerEntry {
            LedgerEntry(cardPath: item.file.relPath, drivePath: item.drivePath, size: bytes, quick: item.quick, hash: hexHash(hash), weak: weak ? true : nil, closes: closes)
        }

        /// A file counts only once its proof is on the drive.
        func accept(_ item: IngestItem, hash: UInt64, bytes: UInt64, stamp: DriveStamp?, weak thisWeak: Bool, closes: [String]? = nil) {
            weak = weak || thisWeak
            let line = entry(item, hash: hash, bytes: bytes, weak: thisWeak, closes: closes)
            do {
                try journal.record(line)
                recorded.append(line)
                let state = FileState.verified(drivePath: item.drivePath, hash: line.hash, bytes: bytes)
                states[item.file.relPath] = state
                verified += 1
                if let stamp, let cardMount, let driveMount = ledger.mount {
                    proofs[item.file.relPath] = Proof(state: state, file: item.file, quick: item.quick, stamp: stamp, card: cardMount, drive: driveMount)
                }
            } catch {
                states[item.file.relPath] = .failed("couldn't record the check on the drive")
            }
        }

        // Only a name that's free now can end up reserved by this job. Anything already there isn't the app's to claim.
        journal.intend(job.items.map(\.drivePath).filter { !pathExists(root.file($0)) })

        // A file an earlier job left unfinished can turn up here, and a read only finishes it after a confirmed flush.
        let first = ledger.hasUnfinished ? askToFlush(root, hooks) : (confirmed: false, refused: false)

        for (i, item) in job.items.enumerated() {
            if control.isStopped { break }
            report(.copying, i, item.file.name)
            let src = card.file(item.file.relPath)
            let dst = root.file(item.drivePath)
            let dir = (item.drivePath as NSString).deletingLastPathComponent
            do { try makeDir(dir, root: root, made: &made) } catch {
                states[item.file.relPath] = .failed("couldn't create its folder"); continue
            }

            // The card at this path must still be the card that was read. A different card with the
            // same name and sizes would otherwise be stamped with this card's fingerprint.
            guard let current = fingerprint(path: src) else {
                states[item.file.relPath] = .failed("it won't open on the card any more"); continue
            }
            guard hexHash(current) == item.quick else {
                states[item.file.relPath] = .failed("it changed on the card after it was read"); continue
            }

            // Never overwrite. An existing file must prove itself identical, or the job refuses.
            if pathExists(dst) {
                let both = readBoth(card: src, drive: dst, on: root, expected: item.file.size, control: control)
                if both.cancelled { break }
                guard both.identical else {
                    states[item.file.relPath] = .failed(both.drive.stamp.size == 0 && both.readsOK && both.card.bytes != 0
                        ? "an empty file already has that name on the drive" : "a different file already has that name on the drive")
                    continue
                }
                let hash = hexHash(both.card.hash)
                let jobs = ledger.unfinishedJobs(drivePath: item.drivePath, bytes: both.card.bytes, hash: hash)
                let thisWeak = (first.refused && !jobs.isEmpty) || !both.cacheBypassed || ledger.isWeak(drivePath: item.drivePath, bytes: both.card.bytes, hash: hash)
                let closes = first.confirmed && !thisWeak && !jobs.isEmpty ? jobs : nil
                accept(item, hash: both.card.hash, bytes: both.card.bytes, stamp: DriveStamp(both.drive.stamp), weak: thisWeak, closes: closes)
                ci_add_u64(control.copied, item.file.size)
                continue
            }

            let temp = root.file(tempFolder) + "/" + job.id + "." + String(i) + ".part"
            let result = copyAndProve(item, from: src, to: dst, temp: temp, on: root, journal: journal, control: control, hooks: hooks,
                                      checking: { report(.checking, i, item.file.name) },
                                      markWeak: { hash, bytes in (try? journal.record(entry(item, hash: hash, bytes: bytes, weak: true))) != nil })
            switch result {
            case .stopped: break
            case .failed(let why): states[item.file.relPath] = .failed(why)
            case .proved(let hash, let bytes, let thisWeak): accept(item, hash: hash, bytes: bytes, stamp: root.stamp(item.drivePath), weak: thisWeak)
            }
            report(.copying, i, item.file.name)
        }

        report(.finishing, max(0, job.items.count - 1), "")
        for d in made.sorted(by: { $0.count > $1.count }) { _ = ci_fsync_dir(root.file(d)) }
        // Strong status has to be earned here: a job the drive wouldn't confirm stays weak on every later visit.
        if !journal.seal(recorded, flushVolume: { hooks.syncVolume?(root.path) ?? ci_sync_volume(root.path) }) { weak = true }
        return IngestOutcome(states: states, proofs: proofs, cancelled: control.isStopped, weakVerification: weak)
    }

    private enum CopyResult { case proved(hash: UInt64, bytes: UInt64, weak: Bool), failed(String), stopped }

    /// Up to two attempts. A file only takes its real name once the copy, the drive and a second read of the card agree.
    private static func copyAndProve(_ item: IngestItem, from src: String, to dst: String, temp: String, on root: ResolvedRoot, journal: LedgerJournal, control: IngestControl,
                                     hooks: FaultHooks, checking: () -> Void, markWeak: (UInt64, UInt64) -> Bool) -> CopyResult {
        var lastError = "copy failed"
        for attempt in 1 ... 2 where !control.isStopped {
            let copiedBefore = ci_load_u64(control.copied), checkedBefore = ci_load_u64(control.checked)
            func rewind() { ci_store_u64(control.copied, copiedBefore); ci_store_u64(control.checked, checkedBefore) }
            unlink(temp)
            let copy = ci_copy(src, temp, item.file.size, control.cancelFlag, control.copied)
            if copy.stage == Int32(CI_STAGE_CANCELLED) { discard(temp); break }
            if copy.stage != 0 {
                lastError = describe(copy, "copying")
                discard(temp)
                rewind()
                if copy.stage == Int32(CI_STAGE_OPEN_SRC) || copy.stage == Int32(CI_STAGE_READ) { break }
                continue
            }
            hooks.afterCopy?(temp, src, attempt)
            checking()

            // The hash from the copy can't catch a bad read: the same wrong bytes reach both sides.
            // So read the drive back from the device, and read the card a second time, independently.
            let both = readBoth(card: src, drive: temp, on: root, expected: item.file.size, control: control)
            if both.cancelled { discard(temp); break }
            guard both.identical, copy.hash == both.card.hash, copy.bytes == both.card.bytes else {
                lastError = both.readsOK ? "the copy didn't match the card" : describe(both.drive.stage != 0 ? both.drive : both.card, "checking")
                discard(temp)
                rewind()
                continue
            }
            // A later visit finds a file by its name, so a weak copy's mark has to get there first.
            let thisWeak = copy.weak_flush != 0 || !both.cacheBypassed
            if thisWeak, !markWeak(copy.hash, copy.bytes) {
                discard(temp)
                return .failed("couldn't record the check on the drive")
            }
            // Times are metadata: failing to set them never fails a verified copy.
            _ = ci_set_times(temp, item.file.mtime, item.file.mtimeNanos)
            let rc = publish(temp, as: dst, drivePath: item.drivePath, journal: journal)
            if rc != 0 {
                discard(temp)
                return .failed("couldn't put the file in place: \(String(cString: strerror(rc)))")
            }
            unlinkAppleDouble(of: temp)
            unlinkAppleDouble(of: dst)
            return .proved(hash: copy.hash, bytes: copy.bytes, weak: thisWeak)
        }
        return control.isStopped ? .stopped : .failed(lastError)
    }

    /// Gives a proved file its real name, and never takes one from anyone. A crash could leave a reservation behind, which
    /// is why the job said which names it might take before it began. If the name turns out to be taken, that's taken back:
    /// that file was never the app's.
    static func publish(_ temp: String, as dst: String, drivePath: String, journal: LedgerJournal?) -> Int32 {
        let rc = ci_rename_new(temp, dst)
        guard rc == ENOTSUP else { return rc }
        let reserved = ci_rename_reserved(temp, dst)
        if reserved != 0 { journal?.note(.release, drivePath) }
        return reserved
    }

    /// Proves "already on the drive" by reading both sides in full. Anything less isn't proof.
    /// With `record` off nothing is written to the drive: a check, for a tool that must leave a drive as it found it.
    public static func confirm(cardRoot: String, driveRoot: String, candidates: [(file: CardFile, drivePath: String, quick: String)],
                               ledger: Ledger, jobName: String, control: IngestControl, record: Bool = true, cardMount: MountAnchor? = nil,
                               hooks: FaultHooks = FaultHooks(),
                               progress: @escaping @Sendable (Int, Int) -> Void) -> (states: [String: FileState], proofs: [String: Proof], weak: Bool) {
        var out: [String: FileState] = [:]
        var proofs: [String: Proof] = [:]
        var weak = false
        guard !candidates.isEmpty else { return (out, proofs, false) }
        guard let root = ResolvedRoot(driveRoot), let card = ResolvedRoot(cardRoot) else {
            for c in candidates { out[c.file.relPath] = .failed("the card or the drive can't be reached") }
            return (out, proofs, false)
        }
        let cardMount = cardMount ?? MountAnchor(path: cardRoot)
        ci_store_u64(control.checked, 0)
        // A copy made a moment ago may still be on its way, so the drive is asked first. A drive that won't say makes this
        // weak. One mounted read-only has nothing on its way. With `record` off this is a look, and it changes nothing.
        let first = record ? askToFlush(root, hooks) : (confirmed: false, refused: false)
        let journal = !record ? nil : try? ledger.open(LedgerHeader(job: UUID().uuidString, started: Date(), cardName: jobName, camera: nil,
                                                                    destination: "", app: "\(AppInfo.name) \(AppInfo.version)"))
        journal?.fault = hooks.journalFails
        defer { journal?.close() }
        for (i, c) in candidates.enumerated() {
            if control.isStopped { break }
            progress(i + 1, candidates.count)
            let both = readBoth(card: card.file(c.file.relPath), drive: root.file(c.drivePath), on: root, expected: c.file.size, control: control)
            if both.cancelled { break }
            guard both.identical else { out[c.file.relPath] = .failed(both.whyNot); continue }   // looked the same, wasn't
            let hash = hexHash(both.card.hash)
            let thisWeak = first.refused || !both.cacheBypassed || ledger.isWeak(drivePath: c.drivePath, bytes: both.card.bytes, hash: hash)
            weak = weak || thisWeak
            // A file a cut-off job left is finished by what a sealed job has: a confirmed flush, then this read, on the record.
            let jobs = ledger.unfinishedJobs(drivePath: c.drivePath, bytes: both.card.bytes, hash: hash)
            let closes = first.confirmed && !thisWeak && !jobs.isEmpty ? jobs : nil
            let line = LedgerEntry(cardPath: c.file.relPath, drivePath: c.drivePath, size: both.card.bytes, quick: c.quick, hash: hash, weak: thisWeak ? true : nil, closes: closes)
            let kept = (try? journal?.record(line)) != nil
            if !jobs.isEmpty, closes == nil || !kept { weak = true }
            // A weak mark that won't stay on the drive can't stay weak on a later visit, so this can't count as proved.
            if record, thisWeak, journal == nil || !kept {
                out[c.file.relPath] = .failed("couldn't record the check on the drive")
                continue
            }
            let state = FileState.verified(drivePath: c.drivePath, hash: hash, bytes: both.card.bytes)
            out[c.file.relPath] = state
            if let cardMount, let driveMount = ledger.mount {
                proofs[c.file.relPath] = Proof(state: state, file: c.file, quick: c.quick, stamp: DriveStamp(both.drive.stamp), card: cardMount, drive: driveMount)
            }
        }
        return (out, proofs, weak)
    }

    private struct BothSides {
        var card: ci_result, drive: ci_result
        var cacheBypassed: Bool     // false when either side may have come from the Mac's cache
        var expected: UInt64        // as listed. 0 can't be held against a read: virtual volumes list real files at 0.
        var driveDevice: Int64
        var cancelled: Bool { card.stage == Int32(CI_STAGE_CANCELLED) || drive.stage == Int32(CI_STAGE_CANCELLED) }
        var readsOK: Bool { card.stage == 0 && drive.stage == 0 }
        /// Two reads of one file are not two copies, and a file on another volume isn't on this drive.
        private var twoFiles: Bool { drive.stamp.dev == driveDevice && (card.stamp.dev != drive.stamp.dev || card.stamp.ino != drive.stamp.ino) }
        private var whole: Bool { expected == 0 || card.bytes == expected }
        var identical: Bool { readsOK && twoFiles && card.hash == drive.hash && card.bytes == drive.bytes && whole }
        /// Why not, for a person. Only asked once `identical` has said no.
        var whyNot: String {
            if !readsOK { return IngestEngine.describe(drive.stage != 0 ? drive : card, "checking") }
            if !twoFiles { return "what's on the drive isn't a separate copy of it" }
            if !whole { return "it's shorter than the size the card lists" }
            return "the copy on the drive doesn't match the card"
        }
    }

    /// Asks the drive to finish what it's holding. `refused` means it said no. Neither means it couldn't say, as a volume
    /// mounted read-only can't, which is no reason to doubt it and no confirmation either.
    private static func askToFlush(_ root: ResolvedRoot, _ hooks: FaultHooks) -> (confirmed: Bool, refused: Bool) {
        let rc = hooks.syncVolume?(root.path) ?? ci_sync_volume(root.path)
        return (rc == 0, rc != 0 && !root.isReadOnly)
    }

    /// The one read behind every proof: each side in full, from the device, while it stays in. Both paths are resolved,
    /// so a link anywhere on the way refuses the read. Both caches have to clear, or the proof is weak.
    private static func readBoth(card: String, drive: String, on root: ResolvedRoot, expected: UInt64, control: IngestControl) -> BothSides {
        var a = ci_result(), b = ci_result()
        var cardCleared: Int32 = 0, driveCleared: Int32 = 0
        DispatchQueue.concurrentPerform(iterations: 2) { which in
            if which == 0 { a = ci_hash_file(card, 1, control.cancelFlag, &cardCleared, control.checked) }
            else { b = ci_hash_file(drive, 1, control.cancelFlag, &driveCleared, nil) }
        }
        return BothSides(card: a, drive: b, cacheBypassed: cardCleared != 0 && driveCleared != 0, expected: expected, driveDevice: root.device)
    }

    fileprivate static func describe(_ r: ci_result, _ doing: String) -> String {
        let why = r.err != 0 ? String(cString: strerror(r.err)) : "unknown error"
        return "\(doing) failed: \(why)"
    }

    static func pathExists(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 }

    private static let tempFolder = AppInfo.driveFolder + "/tmp"

    /// Temps a dead job left. They only ever live in the app's own folder, so nothing someone else made can be taken for
    /// one, and a job that's still running keeps its own.
    static func staleTemps(folder: String, ledger: Ledger) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".part") && !$0.hasPrefix("._") && !ledger.isLive(job: String($0.prefix { $0 != "." })) }.map { folder + "/" + $0 }
    }

    /// Clears what a crash or a pulled drive left: its temps, and any real name it had reserved and never filled, which
    /// would otherwise stand in the way of that very file for good.
    static func sweep(root: ResolvedRoot, ledger: Ledger) {
        for temp in staleTemps(folder: root.file(tempFolder), ledger: ledger) { discard(temp) }
        for path in ledger.abandonedReservations() where root.stamp(path)?.size == 0 { discard(root.file(path)) }
    }

    private static func discard(_ temp: String) { unlink(temp); unlinkAppleDouble(of: temp) }

    /// exFAT gives every new file a 4 KB `._` sidecar. Removing it is the last step of each file.
    static func unlinkAppleDouble(of path: String) {
        let ns = path as NSString
        unlink(ns.deletingLastPathComponent + "/._" + ns.lastPathComponent)
    }

    static func makeDir(_ rel: String, root: ResolvedRoot, made: inout Set<String>) throws {
        guard !rel.isEmpty, rel != ".", !made.contains(rel) else { return }
        var built = ""
        for part in rel.split(separator: "/", omittingEmptySubsequences: true) {
            built = built.isEmpty ? String(part) : built + "/" + part
            if made.contains(built) { continue }
            let full = root.file(built)
            let new = mkdir(full, 0o755) == 0
            if !new && errno != EEXIST { throw IngestError.driveNotWritable(root.path) }
            guard root.isPlainFolder(built) else { throw IngestError.driveNotWritable(root.path) }
            if new { unlinkAppleDouble(of: full) }      // a folder that was already there keeps its tags and comments
            made.insert(built)
        }
    }
}
