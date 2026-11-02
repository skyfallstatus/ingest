// A drive listing folded into a tree of folders. Files only leave totals behind, which keeps 450,000 entries cheap.
import Foundation

struct DriveTree {
    struct Folder {
        var name: String
        var parent: Int32
        var children: [Int32] = []
        var isNoise: Bool
        var isCardMarker: Bool
        var isCardRoot = false      // holds a camera card's own tree directly
        var cardTrees: Int32 = 0    // card roots at or below here
        var videoBytes: UInt64 = 0  // sizes count as at least 1, because virtual volumes can list 0
        var stillBytes: UInt64 = 0
        var rawStillBytes: UInt64 = 0
        var audioBytes: UInt64 = 0
        var projectFiles: Int32 = 0
        var newestMtime: Int64 = 0

        var mediaBytes: UInt64 { videoBytes + stillBytes + audioBytes }
    }

    private(set) var folders: [Folder]
    private var index: [String: Int32] = [:]
    static let root: Int32 = 0

    subscript(_ id: Int32) -> Folder { folders[Int(id)] }

    init(entries: [DriveEntry]) {
        folders = [Folder(name: "", parent: -1, isNoise: false, isCardMarker: false)]
        folders.reserveCapacity(entries.count / 8)
        index.reserveCapacity(entries.count / 8)

        var lastParentPath = Substring()
        var lastParent: Int32 = Self.root

        for entry in entries {
            if entry.isDir {
                let folder = folderID(Self.clean(entry.path))
                if entry.mtime > folders[Int(folder)].newestMtime { folders[Int(folder)].newestMtime = entry.mtime }
                continue
            }
            let slash = entry.path.utf8.lastIndex(of: UInt8(ascii: "/"))
            let name = slash.map { entry.path[entry.path.utf8.index(after: $0)...] } ?? entry.path[...]
            guard name.utf8.first != UInt8(ascii: ".") else { continue }

            // Listings keep a folder's files together, so the parent is nearly always the one just used.
            let parentPath = slash.map { entry.path[..<$0] } ?? Substring()
            if parentPath != lastParentPath {
                lastParent = folderID(Self.clean(String(parentPath)))
                lastParentPath = parentPath
            }

            let i = Int(lastParent)
            let weight = max(entry.size, 1)
            switch Self.kinds[Self.lowerExtension(name)] ?? .other {
            case .video: folders[i].videoBytes &+= weight
            case .still: folders[i].stillBytes &+= weight
            case .rawStill:
                folders[i].stillBytes &+= weight
                folders[i].rawStillBytes &+= weight
            case .audio: folders[i].audioBytes &+= weight
            case .project: folders[i].projectFiles &+= 1
            case .other: break
            }
            if entry.mtime > folders[i].newestMtime { folders[i].newestMtime = entry.mtime }
        }
        rollUp()
    }

    // MARK: Building

    private static func clean(_ path: String) -> String {
        var view = Substring(path)
        if view.hasPrefix("./") { view = view.dropFirst(2) }
        while view.hasPrefix("/") { view = view.dropFirst() }
        while view.hasSuffix("/") { view = view.dropLast() }
        return view.count == path.count ? path : String(view)
    }

    private mutating func folderID(_ path: String) -> Int32 {
        if path.isEmpty { return Self.root }
        if let known = index[path] { return known }
        let parent: Int32
        let name: String
        if let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) {
            parent = folderID(String(path[path.startIndex..<slash]))
            name = String(path[path.utf8.index(after: slash)...])
        } else {
            parent = Self.root
            name = path
        }
        let id = Int32(folders.count)
        folders.append(Folder(name: name, parent: parent, isNoise: LayoutNames.isNoise(name),
                              isCardMarker: LayoutNames.isCardMarker(name)))
        folders[Int(parent)].children.append(id)
        index[path] = id
        return id
    }

    /// Parents are always created before their children, so a reverse walk sees every child first.
    /// Noise never rolls up: Premiere's preview caches are not footage.
    private mutating func rollUp() {
        for i in stride(from: folders.count - 1, to: 0, by: -1) {
            let folder = folders[i]
            let parent = Int(folder.parent)
            if folder.isCardMarker {
                if folders[parent].name.caseInsensitiveCompare("PRIVATE") == .orderedSame, parent != 0 {
                    folders[parent].isCardRoot = false
                    folders[Int(folders[parent].parent)].isCardRoot = true
                } else {
                    folders[parent].isCardRoot = true
                }
            }
        }
        for i in stride(from: folders.count - 1, to: 0, by: -1) {
            if folders[i].isCardRoot { folders[i].cardTrees += 1 }
            let folder = folders[i]
            let parent = Int(folder.parent)
            if folder.newestMtime > folders[parent].newestMtime { folders[parent].newestMtime = folder.newestMtime }
            if folder.isNoise { continue }
            folders[parent].videoBytes &+= folder.videoBytes
            folders[parent].stillBytes &+= folder.stillBytes
            folders[parent].rawStillBytes &+= folder.rawStillBytes
            folders[parent].audioBytes &+= folder.audioBytes
            folders[parent].projectFiles &+= folder.projectFiles
            folders[parent].cardTrees &+= folder.cardTrees
        }
    }

    // MARK: Reading

    /// Child folders worth looking at: no noise, and no card-internal folders.
    func usefulChildren(of id: Int32) -> [Int32] {
        self[id].children.filter { !self[$0].isNoise && !self[$0].isCardMarker }
    }

    /// A dated note or a stray screenshot is not a shoot. A shoot holds footage, a project, a real amount of
    /// stills or audio, or folders of its own.
    func looksWorkedOn(_ id: Int32) -> Bool {
        let folder = self[id]
        if folder.videoBytes > 0 || folder.projectFiles > 0 || folder.cardTrees > 0 { return true }
        if folder.stillBytes + folder.audioBytes >= 8_000_000 { return true }
        let children = usefulChildren(of: id)
        return children.count >= 2 || children.contains { LayoutNames.hint(for: self[$0].name) != nil }
    }

    /// Everything above a folder, drive root excluded, outermost first.
    func ancestors(of id: Int32) -> [Int32] {
        var out: [Int32] = []
        var cursor = self[id].parent
        while cursor > Self.root {
            out.append(cursor)
            cursor = self[cursor].parent
        }
        return out.reversed()
    }

    func path(of id: Int32) -> String {
        (ancestors(of: id) + [id]).map { self[$0].name }.joined(separator: "/")
    }

    // MARK: File kinds

    private enum MediaKind { case video, still, rawStill, audio, project, other }

    private static let kinds: [String: MediaKind] = {
        var table: [String: MediaKind] = [:]
        for ext in Extensions.video { table[ext] = .video }
        // Stills stay this short list: a PNG in a folder is a logo, and that folder mustn't look like the photos' home.
        for ext in ["jpg", "jpeg", "heic", "heif", "tif", "tiff"] { table[ext] = .still }
        for ext in Extensions.cameraRaw { table[ext] = .rawStill }
        for ext in Extensions.audio { table[ext] = .audio }
        for ext in ["prproj", "drp", "drt", "aep", "fcpx", "fcpxml", "veg"] { table[ext] = .project }
        return table
    }()

    private static func lowerExtension(_ name: Substring) -> String {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) else { return "" }
        return name[name.utf8.index(after: dot)...].lowercased()
    }
}
