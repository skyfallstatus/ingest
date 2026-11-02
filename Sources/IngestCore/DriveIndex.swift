import CIngest
import Foundation

/// A listing of a working drive, for finding what's already there and learning its layout.
/// It's only ever a hint: a stale index can hide a copy, but it can never make a card look safe,
/// because "safe" always rests on reading the real files.
public final class DriveIndex: @unchecked Sendable {
    public let entries: [DriveEntry]
    public let folderCount: Int
    private let bySize: [UInt64: [Int32]]
    private let byName: [String: [Int32]]

    public init(entries: [DriveEntry]) {
        self.entries = entries
        var folders = 0
        var size: [UInt64: [Int32]] = [:], name: [String: [Int32]] = [:]
        size.reserveCapacity(entries.count)
        for (i, e) in entries.enumerated() {
            if e.isDir { folders += 1; continue }
            size[e.size, default: []].append(Int32(i))
            name[matchKey((e.path as NSString).lastPathComponent), default: []].append(Int32(i))
        }
        folderCount = folders; bySize = size; byName = name
    }

    public func files(ofSize size: UInt64) -> [DriveEntry] { (bySize[size] ?? []).map { entries[Int($0)] } }
    public func files(named name: String) -> [DriveEntry] { (byName[matchKey(name)] ?? []).map { entries[Int($0)] } }

    /// Reads a whole drive. About 10 s on a 4 TB exFAT drive with 450,000 files.
    public static func scan(root: String, progress: ((Int) -> Void)? = nil) -> DriveIndex {
        var out: [DriveEntry] = []
        var folders = 0
        walkTree(root) { e, rel in
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { return 0 }
            if e.type == Int32(CI_ENTRY_DIR) {
                if Junk.isJunk(name: name, depth: Int(e.depth), isDir: true) || (e.depth == 1 && name == AppInfo.driveFolder) { return 1 }
                folders += 1
                if folders % 50 == 0 { progress?(folders) }
                out.append(DriveEntry(path: rel, isDir: true, size: 0, mtime: e.mtime))
            } else if e.type == Int32(CI_ENTRY_FILE) {
                out.append(DriveEntry(path: rel, isDir: false, size: e.size, mtime: e.mtime))
            }
            return 0
        }
        progress?(folders)
        return DriveIndex(entries: out)
    }

    // MARK: Cache

    private static let magic: UInt32 = 0x31495844  // "DXI1"

    public func save(to url: URL) {
        var d = Data()
        d.reserveCapacity(entries.count * 80)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(Self.magic); put(UInt64(entries.count))
        for e in entries {
            put(e.size); put(e.mtime); put(UInt8(e.isDir ? 1 : 0))
            let bytes = Array(e.path.utf8)
            put(UInt16(min(bytes.count, 65535)))
            d.append(contentsOf: bytes.prefix(65535))
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> DriveIndex? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count >= 12 else { return nil }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DriveIndex? in
            guard raw.loadUnaligned(as: UInt32.self) == magic else { return nil }
            // A damaged cache is rebuilt, so a count no file this size could hold is simply refused.
            let claimed = raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
            guard claimed <= UInt64((raw.count - 12) / 19) else { return nil }
            let count = Int(claimed)
            var off = 12
            var out: [DriveEntry] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                guard off + 19 <= raw.count else { return nil }
                let size = raw.loadUnaligned(fromByteOffset: off, as: UInt64.self)
                let mtime = raw.loadUnaligned(fromByteOffset: off + 8, as: Int64.self)
                let isDir = raw[off + 16] == 1
                let len = Int(raw.loadUnaligned(fromByteOffset: off + 17, as: UInt16.self))
                off += 19
                guard off + len <= raw.count else { return nil }
                let path = String(decoding: UnsafeRawBufferPointer(rebasing: raw[off..<(off + len)]), as: UTF8.self)
                off += len
                out.append(DriveEntry(path: path, isDir: isDir, size: size, mtime: mtime))
            }
            return DriveIndex(entries: out)
        }
    }
}
