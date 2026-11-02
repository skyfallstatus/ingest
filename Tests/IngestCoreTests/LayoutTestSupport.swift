import Foundation
@testable import IngestCore

/// A drive made of paths, in the order they are added. Parents appear first, as in a real walk.
struct FakeDrive {
    private(set) var entries: [DriveEntry] = []
    private var folders = Set<String>()

    mutating func folder(_ path: String, mtime: Int64 = 1_700_000_000) {
        guard !path.isEmpty, !folders.contains(path) else { return }
        if let slash = path.lastIndex(of: "/") { folder(String(path[..<slash]), mtime: mtime) }
        folders.insert(path)
        entries.append(DriveEntry(path: path, isDir: true, size: 0, mtime: mtime))
    }

    mutating func file(_ path: String, size: UInt64 = 1_000_000, mtime: Int64 = 1_700_000_000) {
        if let slash = path.lastIndex(of: "/") { folder(String(path[..<slash]), mtime: mtime) }
        entries.append(DriveEntry(path: path, isDir: false, size: size, mtime: mtime))
    }
}

/// Answers `existing` the way the app will: NFC + case-fold on each component, returning the on-drive spelling.
func lookup(_ folders: [String]) -> (String) -> String? {
    func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    var table: [String: String] = [:]
    for folder in folders {
        var prefix: [String] = []
        for component in folder.split(separator: "/") {
            prefix.append(String(component))
            let path = prefix.joined(separator: "/")
            table[key(path)] = path
        }
    }
    return { table[key($0)] }
}

/// A typical setup: year, a fixed folder, client, with photo and footage folders inside each shoot.
func sampleSetup() -> DriveSetup {
    DriveSetup(
        path: [.year, .literal("Paid work"), .client],
        shootName: ShootNameStyle(dateFormat: "dd.MM.yy"),
        inner: [
            InnerFolder(name: "Photo", role: .photo, children: [
                InnerFolder(name: "RAW", role: .photoRaw),
                InnerFolder(name: "Exports", role: .photoExports),
            ]),
            InnerFolder(name: "Footage", role: .footage),
            InnerFolder(name: "Project", role: .project),
        ],
        footage: .perCamera
    )
}
