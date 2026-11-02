import CIngest
import Foundation

public struct ListingError: Hashable, Sendable {
    public var path: String
    public var reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

/// Everything found on a card. Every listed entry ends up copied and verified, or reported.
public struct CardListing: Sendable {
    public var root: String
    public var files: [CardFile]
    public var dirs: [String]           // card-relative, so empty folders survive: Panasonic P2 cards need them
    public var errors: [ListingError]   // anything that could not be read or isn't a regular file
    public init(root: String, files: [CardFile], dirs: [String], errors: [ListingError]) {
        self.root = root; self.files = files; self.dirs = dirs; self.errors = errors
    }
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// Same files, same sizes? Used to prove the card didn't change while it was being copied.
    func sameContents(as other: CardListing) -> Bool {
        guard files.count == other.files.count, errors == other.errors else { return false }
        func key(_ f: CardFile) -> String { "\(f.relPath)|\(f.size)" }
        return Set(files.map(key)) == Set(other.files.map(key))
    }
}

enum Junk {
    /// Only exact macOS and Windows droppings. Anything else on a card is someone's work.
    /// `FALSE TAKE`, `TRASH`, `.sidecar`, `.RMD` all stay.
    static let rootDirs: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
                                        ".DocumentRevisions-V100", "System Volume Information", "$RECYCLE.BIN"]
    static let rootFiles: Set<String> = [".metadata_never_index", ".VolumeIcon.icns", ".apdisk",
                                         ".com.apple.timemachine.donotpresent"]
    /// Any droppings at any level, for looking at a volume rather than copying it.
    static func isSystemName(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || rootDirs.contains(name) || rootFiles.contains(name)
    }
    static func isJunk(name: String, depth: Int, isDir: Bool) -> Bool {
        if name.hasPrefix("._") || name == ".DS_Store" { return true }
        if depth == 1 { return isDir ? rootDirs.contains(name) : rootFiles.contains(name) }
        return false
    }
}

public func listCard(root: String, kind: @escaping (String) -> FileKind) -> CardListing {
    var files: [CardFile] = [], dirs: [String] = [], errors: [ListingError] = []
    walkTree(root, strict: true) { entry, rel in
        let name = (rel as NSString).lastPathComponent
        switch entry.type {
        case Int32(CI_ENTRY_DIR):
            if Junk.isJunk(name: name, depth: Int(entry.depth), isDir: true) { return 1 }
            dirs.append(rel)
        case Int32(CI_ENTRY_FILE):
            if Junk.isJunk(name: name, depth: Int(entry.depth), isDir: false) { return 0 }
            files.append(CardFile(relPath: rel, size: entry.size, mtime: entry.mtime, mtimeNanos: entry.mtime_ns, kind: kind(rel)))
        case Int32(CI_ENTRY_ERROR):
            if name.hasPrefix("._") { return 0 }   // a broken AppleDouble file holds nothing of value
            errors.append(ListingError(path: rel.isEmpty ? "/" : rel, reason: String(cString: strerror(entry.err))))
        default:
            errors.append(ListingError(path: rel, reason: "not a regular file"))
        }
        return 0
    }
    return CardListing(root: root, files: files, dirs: dirs, errors: errors)
}
