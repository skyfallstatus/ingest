import CIngest
import CoreServices
import Foundation

/// A file on the drive as it stood when it was proved: which file on which mounted volume, its size and its modified
/// time. It's never evidence about bytes. A change to any of it only ever takes a proof away.
/// exFAT and FAT take a file's ID from its first cluster, and an empty file has none: it gets a made-up ID that changes
/// whenever macOS recycles the vnode, which a long job does on its own. So an empty file has no identity to keep. It has
/// no bytes to prove either, and its size and time still show a change.
public struct DriveStamp: Hashable, Sendable {
    let device: Int64, inode: UInt64, size: UInt64, mtime: Int64, mtimeNanos: Int64
    init(_ s: ci_stamp) { device = s.dev; inode = s.size == 0 ? 0 : s.ino; size = s.size; mtime = s.mtime; mtimeNanos = s.mtime_ns }
}

/// One mount of one volume, or one folder on one. An unmount kills it for good, even if the same volume comes back at the
/// same path, and that's what a proof hangs on: UUIDs repeat on cloned media, and events can be missed, but this can't be.
/// The path has to lead to the very folder it was opened on too, so a folder moved, renamed, deleted or replaced ends it,
/// and once it has ended it stays ended, whatever turns up at the path later.
/// It doesn't hold the volume: an eject goes straight past it.
public final class MountAnchor: Hashable, @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let events: Int32      // what has happened to that folder since, kept by the kernel whether anyone looked or not
    private let lock = NSLock()
    private var retired = false

    public init?(path: String) {
        fd = ci_mount_open(path)
        guard fd >= 0 else { return nil }
        events = ci_watch_open(fd)
        guard events >= 0 else { close(fd); return nil }
        self.path = path
    }
    private var watcher: DispatchSourceFileSystemObject?
    private var above: FSEventStreamRef?
    deinit {
        watcher?.cancel()
        if let above { FSEventStreamStop(above); FSEventStreamInvalidate(above); FSEventStreamRelease(above) }
        close(events); close(fd)
    }

    /// Calls `ended` when the folder is deleted, renamed, moved or revoked, or any folder above it is, so whoever shows it can
    /// look again at once. Asking `isCurrent` is still what counts: this only says when to ask.
    public func onEnd(_ ended: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard watcher == nil else { return }
        let own = dup(fd)      // the source has its own descriptor, closed once it's cancelled, whenever that is
        guard own >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: own, eventMask: [.delete, .rename, .revoke], queue: .global(qos: .utility))
        source.setEventHandler { ended() }
        source.setCancelHandler { close(own) }
        source.resume()
        watcher = source
        above = Self.watchRoot(path, ended)
    }

    /// The descriptor only hears about the folder itself. A folder above it dragged to the Trash takes it along with no event
    /// on it, so FSEvents watches the path to it as well, and says when anything on that path changes.
    private static func watchRoot(_ path: String, _ ended: @escaping @Sendable () -> Void) -> FSEventStreamRef? {
        final class Box { let ended: @Sendable () -> Void; init(_ e: @escaping @Sendable () -> Void) { ended = e } }
        let box = Box(ended)    // the stream keeps its own reference, through `retain`, for as long as it lives
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: { p in p.map { _ = Unmanaged<AnyObject>.fromOpaque($0).retain() }; return p },
                                           release: { p in p.map { Unmanaged<AnyObject>.fromOpaque($0).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            for i in 0..<count where flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().ended()
                return
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let made = withExtendedLifetime(box) {
            FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        }
        guard let stream = made else { return nil }
        FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        return stream
    }

    public var isCurrent: Bool {
        lock.lock(); defer { lock.unlock() }
        if !retired && (ci_watch_fired(events) != 0 || ci_mount_alive(fd, path) == 0) { retired = true }
        return !retired
    }
    /// As an unmount would. For tests, which can't unmount a folder.
    func retire() { lock.lock(); retired = true; lock.unlock() }

    public static func == (a: MountAnchor, b: MountAnchor) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// A root with its symbolic links resolved. Everything under it is then reached with no link allowed on the way, so a
/// drive folder swapped for a link can't lead anywhere else, least of all back to the card.
struct ResolvedRoot {
    let path: String
    let device: Int64

    init?(_ root: String) {
        guard let real = realpath(root, nil) else { return nil }
        defer { free(real) }
        path = String(cString: real)
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        device = Int64(st.st_dev)
    }

    /// The whole path of something under this root.
    func file(_ rel: String) -> String { rel.isEmpty ? path : path + "/" + rel }

    /// The regular file at `rel` right now. Nil if it isn't one, or the path leaves the drive by any route.
    func stamp(_ rel: String) -> DriveStamp? {
        guard Ledger.isInsideDrive(rel) else { return nil }
        var s = ci_stamp()
        guard ci_stamp_file(file(rel), &s) == 0, s.dev == device else { return nil }
        return DriveStamp(s)
    }

    func isPlainFolder(_ rel: String) -> Bool { ci_plain_dir(file(rel)) == 0 }

    var isReadOnly: Bool {
        var fs = statfs()
        return statfs(path, &fs) == 0 && fs.f_flags & UInt32(MNT_RDONLY) != 0
    }
}
