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
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.bundleID, isDirectory: true)
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

    /// Off unless someone turns it on: it's the only reason the app would go online by itself.
    var checksForUpdates: Bool {
        get { d.bool(forKey: "checksForUpdates") }
        set { d.set(newValue, forKey: "checksForUpdates") }
    }

    var sawFirstRun: Bool {
        get { d.bool(forKey: "sawFirstRun") }
        set { d.set(newValue, forKey: "sawFirstRun") }
    }

    var workingDriveKey: String? {
        get { d.string(forKey: "workingDrive") }
        set { d.set(newValue, forKey: "workingDrive") }
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

    func setup(onDrive path: String) -> DriveSetup? {
        FileManager.default.contents(atPath: path + "/" + AppInfo.driveFolder + "/setup.json")
            .flatMap { try? JSONDecoder().decode(DriveSetup.self, from: $0) }
    }

    func save(setup: DriveSetup, onDrive path: String) throws {
        let folder = path + "/" + AppInfo.driveFolder
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(setup).write(to: URL(fileURLWithPath: folder + "/setup.json"), options: .atomic)
    }
}
