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
    public var cancelled: Bool
    public var weakVerification: Bool   // the drive wouldn't confirm a flush, or the cache couldn't be bypassed
    public var failures: [String] { states.compactMap { if case .failed = $0.value { $0.key } else { nil } } }
}

/// Lets tests break things at the worst moment. Unused in the app.
public struct FaultHooks: Sendable {
    public var afterCopy: (@Sendable (_ tempPath: String, _ sourcePath: String, _ attempt: Int) -> Void)?
    public var syncVolume: (@Sendable (_ driveRoot: String) -> Int32)?
    public init(afterCopy: (@Sendable (String, String, Int) -> Void)? = nil, syncVolume: (@Sendable (String) -> Int32)? = nil) {
        self.afterCopy = afterCopy; self.syncVolume = syncVolume
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
    public static func preflight(job: IngestJob) throws {
        // A card can't be copied onto itself.
        if job.driveRoot == job.cardRoot || job.driveRoot.hasPrefix(job.cardRoot + "/") { throw IngestError.sameVolume }
        let need = job.items.reduce(UInt64(0)) { $0 + $1.file.size }
        var fs = statfs()
        guard statfs(job.driveRoot, &fs) == 0 else { throw IngestError.driveNotWritable(job.driveRoot) }
        let free = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        let margin: UInt64 = 256 * 1024 * 1024 + UInt64(job.items.count) * 256 * 1024  // ledger, manifests, cluster slack
        if need + margin > free { throw IngestError.notEnoughSpace(needed: need + margin, free: free) }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if type == "msdos" || type == "fat32", let big = job.items.first(where: { $0.file.size >= 1 << 32 }) {
            throw IngestError.fileTooLarge(big.file.name)
        }
    }

    public static func run(job: IngestJob, ledger: Ledger, control: IngestControl, hooks: FaultHooks = FaultHooks(),
                           progress: @escaping @Sendable (IngestProgress) -> Void) throws -> IngestOutcome {
        try preflight(job: job)
        let journal = try ledger.open(LedgerHeader(job: job.id, started: Date(), cardName: job.cardName, camera: job.camera,
                                                   destination: job.destination, app: "\(AppInfo.name) \(AppInfo.version)"))
        defer { journal.close() }

        var made = Set<String>()
        for d in job.dirsToCreate { try makeDir(d, root: job.driveRoot, made: &made) }
        sweepStaleTemps(root: job.driveRoot + "/" + job.destination)

        let total = job.items.reduce(UInt64(0)) { $0 + $1.file.size }
        var states: [String: FileState] = [:]
        var weak = false
        var verified = 0
        var recorded: [LedgerEntry] = []

        func report(_ phase: IngestProgress.Phase, _ i: Int, _ name: String) {
            progress(IngestProgress(phase: phase, fileIndex: i + 1, fileCount: job.items.count, verifiedFiles: verified,
                                    bytesCopied: control.bytesCopied, bytesTotal: total, currentName: name))
        }

        /// A file counts only once its proof is on the drive.
        func accept(_ item: IngestItem, hash: UInt64, bytes: UInt64, weak thisWeak: Bool) {
            weak = weak || thisWeak
            let entry = LedgerEntry(cardPath: item.file.relPath, drivePath: item.drivePath, size: bytes,
                                    quick: item.quick, hash: hexHash(hash), weak: thisWeak ? true : nil)
            do {
                try journal.record(entry)
                recorded.append(entry)
                states[item.file.relPath] = .verified(drivePath: item.drivePath, hash: hexHash(hash), bytes: bytes)
                verified += 1
            } catch {
                states[item.file.relPath] = .failed("couldn't record the check on the drive")
            }
        }

        for (i, item) in job.items.enumerated() {
            if control.isStopped { break }
            report(.copying, i, item.file.name)
            let src = job.cardRoot + "/" + item.file.relPath
            let dst = job.driveRoot + "/" + item.drivePath
            let dir = (item.drivePath as NSString).deletingLastPathComponent
            do { try makeDir(dir, root: job.driveRoot, made: &made) } catch {
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
                let both = readBoth(card: src, drive: dst, control: control)
                if both.cancelled { break }
                guard both.identical else {
                    states[item.file.relPath] = .failed("a different file already has that name on the drive"); continue
                }
                accept(item, hash: both.card.hash, bytes: both.card.bytes, weak: !both.cacheBypassed || ledger.isWeak(drivePath: item.drivePath))
                ci_add_u64(control.copied, item.file.size)
                continue
            }

            let temp = job.driveRoot + "/" + dir + "/.ingest-" + job.id.prefix(8) + "-\(i).part"
            switch copyAndProve(item, from: src, to: dst, temp: temp, control: control, hooks: hooks, checking: { report(.checking, i, item.file.name) }) {
            case .stopped: break
            case .failed(let why): states[item.file.relPath] = .failed(why)
            case .proved(let hash, let bytes, let thisWeak): accept(item, hash: hash, bytes: bytes, weak: thisWeak)
            }
            report(.copying, i, item.file.name)
        }

        report(.finishing, max(0, job.items.count - 1), "")
        for d in made.sorted(by: { $0.count > $1.count }) { _ = ci_fsync_dir(job.driveRoot + "/" + d) }
        if (hooks.syncVolume?(job.driveRoot) ?? ci_sync_volume(job.driveRoot)) != 0 {
            // The drive wouldn't confirm any of it, so this job's copies stay weak on every later visit too.
            weak = true
            for var entry in recorded where entry.weak != true {
                entry.weak = true
                try? journal.record(entry)
            }
        }
        return IngestOutcome(states: states, cancelled: control.isStopped, weakVerification: weak)
    }

    private enum CopyResult { case proved(hash: UInt64, bytes: UInt64, weak: Bool), failed(String), stopped }

    /// Up to two attempts. A file only takes its real name once the copy, the drive and a second read of the card agree.
    private static func copyAndProve(_ item: IngestItem, from src: String, to dst: String, temp: String, control: IngestControl,
                                     hooks: FaultHooks, checking: () -> Void) -> CopyResult {
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
            let both = readBoth(card: src, drive: temp, control: control)
            if both.cancelled { discard(temp); break }
            let sizeHolds = item.file.size == 0 || copy.bytes == item.file.size  // virtual volumes list 0
            guard both.identical, sizeHolds, copy.hash == both.card.hash, copy.bytes == both.card.bytes else {
                lastError = both.readsOK ? "the copy didn't match the card" : describe(both.drive.stage != 0 ? both.drive : both.card, "checking")
                discard(temp)
                rewind()
                continue
            }
            // Times are metadata: failing to set them never fails a verified copy.
            _ = ci_set_times(temp, item.file.mtime, item.file.mtimeNanos)
            let rc = ci_rename_excl(temp, dst)
            if rc != 0 {
                discard(temp)
                return .failed("couldn't put the file in place: \(String(cString: strerror(rc)))")
            }
            unlinkAppleDouble(of: temp)
            unlinkAppleDouble(of: dst)
            return .proved(hash: copy.hash, bytes: copy.bytes, weak: copy.weak_flush != 0 || !both.cacheBypassed)
        }
        return control.isStopped ? .stopped : .failed(lastError)
    }

    /// Proves "already on the drive" by reading both sides in full. Anything less isn't proof.
    /// With `record` off nothing is written to the drive: a check, for a tool that must leave a drive as it found it.
    public static func confirm(cardRoot: String, driveRoot: String, candidates: [(file: CardFile, drivePath: String, quick: String)],
                               ledger: Ledger, jobName: String, control: IngestControl, record: Bool = true,
                               progress: @escaping @Sendable (Int, Int) -> Void) -> (states: [String: FileState], weak: Bool) {
        var out: [String: FileState] = [:]
        var weak = false
        guard !candidates.isEmpty else { return (out, false) }
        ci_store_u64(control.checked, 0)
        let journal = !record ? nil : try? ledger.open(LedgerHeader(job: UUID().uuidString, started: Date(), cardName: jobName, camera: nil,
                                                                    destination: "", app: "\(AppInfo.name) \(AppInfo.version)"))
        defer { journal?.close() }
        for (i, c) in candidates.enumerated() {
            if control.isStopped { break }
            progress(i + 1, candidates.count)
            let both = readBoth(card: cardRoot + "/" + c.file.relPath, drive: driveRoot + "/" + c.drivePath, control: control)
            if both.cancelled { break }
            guard both.identical else { out[c.file.relPath] = .missing; continue }   // looked the same, wasn't. It gets copied.
            let hash = hexHash(both.card.hash)
            let thisWeak = !both.cacheBypassed || ledger.isWeak(drivePath: c.drivePath)
            weak = weak || thisWeak
            out[c.file.relPath] = .verified(drivePath: c.drivePath, hash: hash, bytes: both.card.bytes)
            try? journal?.record(LedgerEntry(cardPath: c.file.relPath, drivePath: c.drivePath, size: both.card.bytes,
                                             quick: c.quick, hash: hash, weak: thisWeak ? true : nil))
        }
        return (out, weak)
    }

    private struct BothSides {
        var card: ci_result, drive: ci_result
        var cacheBypassed: Bool     // false when the drive side may have come from the Mac's cache
        var cancelled: Bool { card.stage == Int32(CI_STAGE_CANCELLED) || drive.stage == Int32(CI_STAGE_CANCELLED) }
        var readsOK: Bool { card.stage == 0 && drive.stage == 0 }
        var identical: Bool { readsOK && card.hash == drive.hash && card.bytes == drive.bytes }
    }

    /// The one read behind every proof: each side in full, from the device, this session.
    private static func readBoth(card: String, drive: String, control: IngestControl) -> BothSides {
        var a = ci_result(), b = ci_result()
        var invalidated: Int32 = 0
        DispatchQueue.concurrentPerform(iterations: 2) { which in
            if which == 0 { a = ci_hash_uncached(card, control.cancelFlag, nil, control.checked) }
            else { b = ci_hash_uncached(drive, control.cancelFlag, &invalidated, nil) }
        }
        return BothSides(card: a, drive: b, cacheBypassed: invalidated != 0)
    }

    private static func describe(_ r: ci_result, _ doing: String) -> String {
        let why = r.err != 0 ? String(cString: strerror(r.err)) : "unknown error"
        return "\(doing) failed: \(why)"
    }

    static func pathExists(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 }

    /// A crash or a pulled drive can leave a temp file behind. It never held a real name, so it's safe to remove.
    static func sweepStaleTemps(root: String) {
        var stale: [String] = []
        walkTree(root) { e, rel in
            let name = (rel as NSString).lastPathComponent
            if e.type == Int32(CI_ENTRY_FILE), name.hasPrefix(".ingest-"), name.hasSuffix(".part") { stale.append(root + "/" + rel) }
            return 0
        }
        for p in stale { discard(p) }
    }

    private static func discard(_ temp: String) { unlink(temp); unlinkAppleDouble(of: temp) }

    /// exFAT gives every new file a 4 KB `._` sidecar. Removing it is the last step of each file.
    static func unlinkAppleDouble(of path: String) {
        let ns = path as NSString
        unlink(ns.deletingLastPathComponent + "/._" + ns.lastPathComponent)
    }

    static func makeDir(_ rel: String, root: String, made: inout Set<String>) throws {
        guard !rel.isEmpty, rel != ".", !made.contains(rel) else { return }
        var built = ""
        for part in rel.split(separator: "/", omittingEmptySubsequences: true) {
            built = built.isEmpty ? String(part) : built + "/" + part
            if made.contains(built) { continue }
            let full = root + "/" + built
            if mkdir(full, 0o755) != 0 && errno != EEXIST { throw IngestError.driveNotWritable(root) }
            var st = stat()
            guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw IngestError.driveNotWritable(root) }
            unlinkAppleDouble(of: full)
            made.insert(built)
        }
    }
}
