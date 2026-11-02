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
    var id: String { path }
    var isCurrent: Bool { anchor?.isCurrent == true }

    /// Stable enough to remember a drive by. UUIDs are only a hint on exFAT, so the name and size count too.
    var key: String { "\(uuid ?? "-")|\(name)|\(total)" }
    var freeText: String { ByteFormat.string(free) + " free" }
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
                              total: UInt64(v.volumeTotalCapacity ?? 0), free: UInt64(v.volumeAvailableCapacity ?? 0),
                              fsType: type, isReadOnly: v.volumeIsReadOnly ?? false, isInternal: v.volumeIsInternal ?? false,
                              anchor: MountAnchor(path: path)))
        }
        return out
    }

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
