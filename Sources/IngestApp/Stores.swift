import Foundation
import IngestCore

/// What the app remembers about a camera body.
struct CameraMemory: Codable, Hashable {
    var folder: String
    var clockOffsetDays: Int?   // Days to add to this camera's clock. Set once the same gap is seen twice.
    var suspectedOffsetDays: Int?
    var displayName: String?
    var serialTail: String?
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String
    var date: Date
    var cardName: String
    var camera: String?
    var driveName: String
    var path: String            // absolute, at the time
    var files: Int
    var bytes: UInt64
    var outcome: String
}

/// Local memory. The drive keeps its own setup and ledger, so nothing here is needed to stay safe.
final class Stores {
    private let d = UserDefaults.standard
    private let support: URL

    init() {
        // The self-test keeps its history apart from the real one.
        let base = ProcessInfo.processInfo.environment["INGEST_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.name, isDirectory: true)
        support = base
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    var indexCacheFolder: URL {
        if ProcessInfo.processInfo.environment["INGEST_SUPPORT_DIR"] != nil { return support.appendingPathComponent("index", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.bundleID, isDirectory: true)
    }

    var allowDiskImages: Bool {
        d.bool(forKey: "allowDiskImages") || ProcessInfo.processInfo.environment["INGEST_ALLOW_DISK_IMAGES"] == "1"
    }

    var overrides: [String: String] {
        get { d.dictionary(forKey: "volumeRoles") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "volumeRoles") }
    }

    /// On unless someone has turned it off.
    var opensOnCardIn: Bool {
        get { d.object(forKey: "opensOnCardIn") as? Bool ?? true }
        set { d.set(newValue, forKey: "opensOnCardIn") }
    }

    var sawFirstRun: Bool {
        get { d.bool(forKey: "sawFirstRun") }
        set { d.set(newValue, forKey: "sawFirstRun") }
    }

    var workingDriveKey: String? {
        get { d.string(forKey: "workingDrive") }
        set { d.set(newValue, forKey: "workingDrive") }
    }

    /// Where the working folder was when it was chosen, to say where it was if it goes missing.
    var workingFolderPath: String? {
        get { d.string(forKey: "workingFolder") }
        set { d.set(newValue, forKey: "workingFolder") }
    }

    /// Folders on this Mac that have been made drives, as plain bookmarks, so a folder that's moved is found where it went.
    /// Kept beside the history, so the self-test's own support folder holds its own, and none of anyone else's.
    var folderBookmarks: [Data] {
        get {
            guard let data = try? Data(contentsOf: support.appendingPathComponent("folders.plist")) else { return [] }
            return (try? PropertyListDecoder().decode([Data].self, from: data)) ?? []
        }
        set { try? PropertyListEncoder().encode(newValue).write(to: support.appendingPathComponent("folders.plist"), options: .atomic) }
    }

    func remember(folder path: String) {
        guard let mark = try? URL(fileURLWithPath: path, isDirectory: true).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
              let key = VolumeWatcher.folder(at: path)?.key else { return }
        var marks = folderBookmarks.filter { VolumeWatcher.folders([$0]).first?.key != key }
        marks.append(mark)
        folderBookmarks = marks
    }

    /// Forgets a folder. Nothing in it is touched.
    func forget(folderKey key: String) {
        folderBookmarks = folderBookmarks.filter { mark in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: mark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { return true }
            return VolumeWatcher.folder(at: url.path)?.key != key
        }
    }

    var cameras: [String: CameraMemory] {
        get { (d.data(forKey: "cameras")).flatMap { try? JSONDecoder().decode([String: CameraMemory].self, from: $0) } ?? [:] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "cameras") }
    }

    var history: [HistoryEntry] {
        get {
            guard let data = try? Data(contentsOf: support.appendingPathComponent("history.json")) else { return [] }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return (try? dec.decode([HistoryEntry].self, from: data)) ?? []
        }
        set {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try? enc.encode(newValue).write(to: support.appendingPathComponent("history.json"), options: .atomic)
        }
    }

    // MARK: Drive setup lives on the drive, so it travels with it

    /// A setup that would lead off the drive counts as no setup at all.
    static func setup(onDrive path: String) -> DriveSetup? {
        FileManager.default.contents(atPath: path + "/" + AppInfo.driveFolder + "/setup.json")
            .flatMap { try? JSONDecoder().decode(DriveSetup.self, from: $0) }
            .flatMap { $0.staysOnDrive ? $0 : nil }
    }

    func save(setup: DriveSetup, onDrive path: String) throws {
        let folder = try Ledger.appFolder(on: path)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(setup).write(to: URL(fileURLWithPath: folder + "/setup.json"), options: .atomic)
    }
}
