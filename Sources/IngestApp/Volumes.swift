import AppKit
import DiskArbitration
import Foundation
import IngestCore

struct Volume: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var uuid: String?
    var total: UInt64
    var free: UInt64
    var fsType: String
    var isReadOnly: Bool
    var isInternal: Bool
    var anchor: MountAnchor? = nil      // this mount. Dead once it's unmounted, whatever comes back at this path.
    var isFolder = false                // a folder on this Mac, used as a drive. `path` is the folder itself.
    var fileID: UInt64? = nil           // that folder's own ID on its volume
    var id: String { path }
    var isCurrent: Bool { anchor?.isCurrent == true }

    /// Stable enough to remember a drive by. UUIDs are only a hint on exFAT, so the name and size count too.
    /// A folder is its volume and its own ID: it keeps them through a rename or a move on that volume, and a folder
    /// deleted and made again is another folder.
    var key: String { isFolder ? "folder|\(uuid ?? "-")|\(fileID ?? 0)" : "\(uuid ?? "-")|\(name)|\(total)" }
    var freeText: String { ByteFormat.string(free) + " free" }
    /// "Movies", for "Footage is missing. It was in Movies."
    var parentName: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

enum VolumeRole: Equatable, Sendable {
    case card, maybeCard(String), drive, ignored, unreadable
}

/// Watches for mounts and unmounts. DiskArbitration tells us when; the filesystem tells us what.
final class VolumeWatcher: @unchecked Sendable {
    private let session = DASessionCreate(kCFAllocatorDefault)
    private let queue = DispatchQueue(label: "volumes")
    var onChange: (@Sendable () -> Void)?

    func start() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, queue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let keys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, keys, { _, _, ctx in
            guard let ctx else { return }
            Unmanaged<VolumeWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange?()
        }, me)
        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            guard let ctx else { return }
            Unmanaged<VolumeWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange?()
        }, me)
    }

    /// Every mounted volume a person could plug in. Runs off the main thread: the first read can wait on a permission prompt.
    static func scan(allowDiskImages: Bool) -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsInternalKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        var out: [Volume] = []
        let only = ProcessInfo.processInfo.environment["INGEST_ONLY_VOLUMES"]?.split(separator: ":").map(String.init)
        for url in urls {
            let path = url.path
            guard path.hasPrefix("/Volumes/") else { continue }
            if let only, !only.contains(url.lastPathComponent) { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard v.volumeIsLocal == true, v.volumeIsBrowsable != false else { continue }
            var isImage = false
            if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
               let d = DADiskCopyDescription(disk) as? [CFString: Any] {
                let proto = d[kDADiskDescriptionDeviceProtocolKey] as? String
                let model = d[kDADiskDescriptionDeviceModelKey] as? String
                isImage = proto == "Virtual Interface" || (model ?? "").contains("Disk Image")
            }
            if isImage && !allowDiskImages { continue }
            var fs = statfs()
            statfs(path, &fs)
            let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let uuid = v.volumeUUIDString.flatMap { $0.hasPrefix("00000000-0000-0000-0000") ? nil : $0 }
            out.append(Volume(path: path, name: v.volumeName ?? url.lastPathComponent, uuid: uuid,
                              total: UInt64(v.volumeTotalCapacity ?? 0), free: IngestEngine.freeBytes(at: path) ?? UInt64(v.volumeAvailableCapacity ?? 0),
                              fsType: type, isReadOnly: v.volumeIsReadOnly ?? false, isInternal: v.volumeIsInternal ?? false,
                              anchor: MountAnchor(path: path)))
        }
        return out
    }

    /// Saved folders, where they are now, and the ones that aren't anywhere they could be used. A folder in the Trash is gone,
    /// one that has since moved somewhere it couldn't be chosen isn't offered, and a bookmark that leads to a folder with
    /// another key leads to another folder. While the self-test fences the app in, only the folders it names exist.
    static func folders(_ saved: [SavedFolder]) -> (found: [Volume], missing: [SavedFolder]) {
        let env = ProcessInfo.processInfo.environment
        let fence = env["INGEST_ONLY_VOLUMES"] == nil ? nil : Set((env["INGEST_ONLY_FOLDERS"] ?? "").split(separator: ":").map { FolderCheck.real(String($0)) })
        var found: [Volume] = [], missing: [SavedFolder] = []
        for s in saved {
            if let fence, !fence.contains(FolderCheck.real(s.path)) { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: s.mark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let path = FolderCheck.real(url.path)
                if fence?.contains(path) != false, !FolderCheck.isInTrash(path), FolderCheck.placeProblem(path) == nil,
                   let v = folder(at: path), v.key == s.key {
                    if !found.contains(where: { $0.key == v.key }) { found.append(v) }
                    continue
                }
            }
            missing.append(s)
        }
        return (found, missing)
    }

    /// A folder as a drive, as it is now. Nil if it isn't a folder on a local internal volume.
    static func folder(at path: String) -> Volume? {
        let path = FolderCheck.real(path)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileIdentifierKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeIsReadOnlyKey,
                                         .volumeIsInternalKey, .volumeIsLocalKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.isDirectory == true, v.volumeIsLocal == true,
              v.volumeIsInternal == true || FolderCheck.onStartupDisk(path), let id = v.fileIdentifier else { return nil }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return Volume(path: path, name: url.lastPathComponent, uuid: v.volumeUUIDString, total: UInt64(v.volumeTotalCapacity ?? 0),
                      free: IngestEngine.freeBytes(at: path) ?? 0, fsType: type, isReadOnly: v.volumeIsReadOnly ?? false, isInternal: true,
                      anchor: MountAnchor(path: path), isFolder: true, fileID: UInt64(id))
    }

    /// Free space on the Mac's own disk, as a job would count it.
    static var macFree: UInt64 { IngestEngine.freeBytes(at: NSHomeDirectory()) ?? 0 }

    static func role(of v: Volume, overrides: [String: String]) -> VolumeRole {
        if overrides[v.key] == "ignore" { return .ignored }
        let url = URL(fileURLWithPath: v.path)
        // A denied permission looks exactly like an empty volume. Never treat it as one. This is also the read that can
        // wait on a permission prompt, so it stays first, off the main thread, whatever's been chosen for this volume.
        guard let dir = opendir(v.path), v.anchor != nil else { return .unreadable }
        closedir(dir)
        switch overrides[v.key] {
        case "card": return .card
        case "drive": return .drive
        default: break
        }
        if FileManager.default.fileExists(atPath: v.path + "/" + AppInfo.driveFolder + "/setup.json") { return .drive }
        if FileManager.default.fileExists(atPath: v.path + "/Backups.backupdb") { return .ignored }
        switch CardProber.look(atRoot: url) {
        case .cameraCard: return .card
        case .maybeCard(let why): return .maybeCard(why)
        case .notACard: return (v.isReadOnly || v.isInternal) ? .ignored : .drive
        }
    }

    /// Unmounts and ejects. On failure, names whoever is holding the volume open.
    static func eject(path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            return nil
        } catch {
            return blocker(path: path).map { "\($0) is using this card. Close it and try again." } ?? "macOS couldn't eject it. Try again in a moment."
        }
    }

    private static func blocker(path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-Fc", "+f", "--", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: "\n").first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
    }
}

/// Where copies may go on this Mac. Each refusal is one plain sentence, shown once the picker has closed.
enum FolderCheck {
    /// The path with every link resolved, as the folder really is.
    static func real(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }

    private static var home: String { real(NSHomeDirectory()) }

    static func isInTrash(_ path: String) -> Bool { path == home + "/.Trash" || path.hasPrefix(home + "/.Trash/") }

    private static func inside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    /// On the disk the Mac started from, its system or its data. That's the Mac's own disk, and keeps the Mac's 20 GB,
    /// even when macOS calls it external, as it does for a Mac started from an external disk.
    static func onStartupDisk(_ path: String) -> Bool {
        func device(_ p: String) -> dev_t? { var st = stat(); return stat(p, &st) == 0 ? st.st_dev : nil }
        guard let d = device(path) else { return false }
        return d == device("/") || d == device("/System/Volumes/Data")
    }

    /// Folders macOS empties by itself. Only a test, or the self-test, may put copies there, and only in its own folder.
    private static func isTemporary(_ path: String) -> Bool {
        guard ["/tmp", "/var", "/private/tmp", "/private/var"].contains(where: { inside(path, $0) }) else { return false }
        let env = ProcessInfo.processInfo.environment
        let own = [env["INGEST_TEST_SCRATCH"]].compactMap { $0 }.map(real)
            + (env["INGEST_ONLY_VOLUMES"] == nil ? [] : (env["INGEST_ONLY_FOLDERS"] ?? "").split(separator: ":").map { real(String($0)) })
        return !own.contains { !$0.isEmpty && inside(path, $0) }
    }

    /// What's wrong with this place, from its path alone. Cheap enough for every look at the volumes.
    static func placeProblem(_ path: String) -> String? {
        let home = home
        if path == "/" { return "That's the whole disk. Choose a folder on it." }
        if path == "/Volumes" { return "That's a folder macOS uses. Choose another folder." }
        if inside(path, "/Volumes") {      // only an internal disk gets this far: a drive that plugs in is named before this
            let disk = path.split(separator: "/")[1]
            return "That's on \(disk), another disk in this Mac. To copy there, use It's a Drive on \(disk)."
        }
        if isTemporary(path) { return "That's a temporary folder, which macOS empties. Choose another folder." }
        if path == home { return "That's your home folder. Choose a folder inside it, like Movies." }
        if inside(path, home + "/Library/Mobile Documents") { return "That folder is in iCloud Drive. Choose one that stays on this Mac." }
        if inside(path, home + "/Library/CloudStorage") { return "That folder syncs to the cloud. Choose one that stays on this Mac." }
        if inside(path, home + "/Library") { return "That's inside Library, which macOS and apps use. Choose another folder." }
        if ["Desktop", "Documents", "Downloads"].contains(where: { inside(path, home + "/" + $0) }) {
            return "Copies don't go in Desktop, Documents or Downloads. Choose another folder, like Movies."
        }
        if isInTrash(path) { return "That folder is in the Trash." }
        for system in ["/Applications", "/System", "/Library"] where inside(path, system) || inside(path, "/System/Volumes/Data" + system) {
            return "That's a folder macOS uses. Choose another folder."
        }
        return nil
    }

    /// Everything that can be said against this folder, before it's offered as a drive. Reads the folder, so off the main thread.
    /// `drives` and `cards` are what's plugged in now, to say which one a folder on another volume belongs to.
    static func problem(with chosen: String, drives: [Volume], cards: [Volume], deadline: Date = Date().addingTimeInterval(5)) -> String? {
        let path = real(chosen)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeURLKey, .isUbiquitousItemKey]),
              v.isDirectory == true else { return "That isn't a folder Ingest can open." }
        if v.volumeIsLocal != true { return "That folder isn't on this Mac." }
        if v.isUbiquitousItem == true { return "That folder is in iCloud Drive. Choose one that stays on this Mac." }
        if v.volumeIsInternal != true && !onStartupDisk(path) {
            let root = v.volume.map { real($0.path) }
            if let d = drives.first(where: { real($0.path) == root }) { return "That's on \(d.name). Choose \(d.name) in the list instead." }
            if let c = cards.first(where: { real($0.path) == root }) { return "That folder is on \(c.name)." }
            return "That folder isn't on this Mac."
        }
        if let why = placeProblem(path) { return why }
        if mountInside(path) { return "A drive is mounted inside that folder. Choose another folder." }
        // Inside a folder that's already a drive, or holding one: their copies and records would be mixed up.
        var up = (path as NSString).deletingLastPathComponent
        while up != "/" && !up.isEmpty {
            if FileManager.default.fileExists(atPath: up + "/" + AppInfo.driveFolder) {
                let name = (up as NSString).lastPathComponent
                return "That folder is inside \(name), where copies already go. Choose \(name) or another folder."
            }
            up = (up as NSString).deletingLastPathComponent
        }
        switch heldDrive(in: path, deadline: deadline) {
        case .some(.some(let name)): return "Copies already go to \(name), inside that folder. Choose \(name) or another folder."
        case .some(.none): break
        case .none: return "That folder holds too much to check. Choose a folder just for your copies."
        }
        if access(path, W_OK) != 0 { return "Ingest can't write to that folder." }
        return nil
    }

    /// A volume mounted anywhere under `path`.
    private static func mountInside(_ path: String) -> Bool {
        var list: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&list, MNT_NOWAIT)
        guard n > 0, let list else { return false }
        for i in 0..<Int(n) {
            let on = withUnsafeBytes(of: list[i].f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if on.hasPrefix(path + "/") { return true }
        }
        return false
    }

    /// The name of a folder under `path` that holds Ingest's own folder, `.some(nil)` if there's none, nil if it couldn't
    /// all be looked at in time. The chosen folder's own `.ingest` is its own, and fine.
    private static func heldDrive(in path: String, deadline: Date) -> String?? {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsPackageDescendants]) else { return nil }
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen % 512 == 0, Date() > deadline { return nil }
            guard url.lastPathComponent == AppInfo.driveFolder else { continue }
            walk.skipDescendants()
            let holder = url.deletingLastPathComponent().path
            if real(holder) != path { return .some((holder as NSString).lastPathComponent) }
        }
        return .some(nil)
    }
}
