// The card as a whole: its listing, and how that listing breaks into clips.
import Foundation

/// What one clip amounts to, however many files it takes. A multi-part R3D, a folder of .ari frames,
/// a pair of .insv and a chain of GoPro chapters are all one unit.
struct ClipUnit {
    var primary: CardFile
    var members: [CardFile]
    var isStill: Bool
    var group: String
}

final class CardContext {
    let rootPath: String
    let files: [CardFile]
    /// Lower-cased relative path to the path as listed. Case differs between bodies and copies.
    private(set) var byLowerPath: [String: String] = [:]
    private(set) var byFolder: [String: [CardFile]] = [:]

    init(root: URL, files: [CardFile]) {
        var path = root.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        rootPath = path
        self.files = files
        byLowerPath.reserveCapacity(files.count)
        for f in files {
            byLowerPath[f.relPath.lowercased()] = f.relPath
            byFolder[Self.folder(of: f.relPath), default: []].append(f)
        }
    }

    func absolute(_ relPath: String) -> String { rootPath + "/" + relPath }
    func open(_ relPath: String) -> ByteFile? { ByteFile(path: absolute(relPath)) }

    static func folder(of relPath: String) -> String {
        guard let slash = relPath.lastIndex(of: "/") else { return "" }
        return String(relPath[..<slash])
    }
    static func stem(of name: String) -> String { (name as NSString).deletingPathExtension }
    static func components(_ relPath: String) -> [String] { relPath.split(separator: "/").map(String.init) }

    static func isInDCIM(_ relPath: String) -> Bool { components(relPath.lowercased()).dropLast().contains("dcim") }

    /// A same-folder file by case-insensitive name.
    func sibling(of relPath: String, named lowerName: String) -> String? {
        let folder = Self.folder(of: relPath).lowercased()
        return byLowerPath[folder.isEmpty ? lowerName : folder + "/" + lowerName]
    }

    /// Which family the tree of folders suggests. Only used when the bytes of a clip said nothing.
    lazy var structureHint: CameraFamily? = {
        var tops: Set<String> = []
        var seconds: Set<String> = []
        for f in files {
            let parts = Self.components(f.relPath.lowercased())
            if parts.count > 1 { tops.insert(parts[0]) }
            if parts.count > 2 { seconds.insert(parts[0] + "/" + parts[1]) }
        }
        if seconds.contains(where: { $0.hasPrefix("crm/reel_") || $0.hasPrefix("xfvc/reel_") || $0.hasPrefix("contents/clips0") }) { return .canon }
        if byLowerPath["lastclip.txt"] != nil, tops.contains("contents") { return .panasonic }
        if seconds.contains("private/pana_grp") { return .panasonic }
        if byLowerPath["sony/sonycard.ind"] != nil || byLowerPath["private/sony/sonycard.ind"] != nil { return .sony }
        for s in seconds where s.hasPrefix("dcim/") {
            if let family = VolumeProbe.family(ofDCIMFolder: String(s.dropFirst(5))) { return family }
        }
        return nil
    }()
}

enum ClipUnits {
    private static let rawVideo: Set<String> = ["nev", "r3d", "braw", "crm", "mov"]

    static func build(_ ctx: CardContext) -> [ClipUnit] {
        var byKey: [String: ClipUnit] = [:]
        var order: [String] = []
        var audio: [CardFile] = []

        func add(_ key: String, _ f: CardFile, still: Bool = false, preferred: Bool = false) {
            if var unit = byKey[key] {
                unit.members.append(f)
                if preferred { unit.primary = f }
                byKey[key] = unit
            } else {
                byKey[key] = ClipUnit(primary: f, members: [f], isStill: still, group: groupKey(f, still: still))
                order.append(key)
            }
        }

        let sorted = ctx.files.sorted { $0.relPath < $1.relPath }
        for f in sorted {
            let folder = CardContext.folder(of: f.relPath)
            let lowerFolder = folder.lowercased()
            let stem = CardContext.stem(of: f.name)
            switch f.kind {
            case .audio:
                audio.append(f)
            case .still:
                add("still:\(folder)/\(stem)", f, still: true, preferred: Extensions.cameraRaw.contains(f.ext))
            case .video:
                if isProxy(f, folder: lowerFolder, stem: stem, ctx: ctx) { continue }
                switch f.ext {
                case "r3d":
                    add("r3d:\(folder)/\(part(of: stem)?.stem ?? stem)", f)
                case "ari", "arx", "dng":
                    add("frames:\(folder)", f)
                case "braw2":
                    if ctx.sibling(of: f.relPath, named: (stem + ".braw").lowercased()) == nil { add("file:\(f.relPath)", f) }
                case "insv":
                    add("insv:\(folder)/\(stem.replacingOccurrences(of: "_10_", with: "_00_"))", f, preferred: stem.contains("_00_"))
                case "mxf":
                    let parts = CardContext.components(lowerFolder)
                    if parts.first == "contents", parts.count == 2 {            // P2: one MXF per essence track
                        if parts[1] == "video" || parts[1] == "avclip" { add("file:\(f.relPath)", f) }
                    } else if parts.contains(where: { $0.hasPrefix("clips0") }), parts.count >= 3 {
                        add("clipfolder:\(folder)", f)                          // Older Canon XF
                    } else {
                        add("file:\(f.relPath)", f)
                    }
                case "mov" where lowerFolder.hasSuffix(".rdc"):
                    add("rdc:\(folder)", f)
                default:
                    if let g = ClipName.goPro(f.name) {
                        add("gopro:\(folder)/\(g.prefix)\(g.video)", f, preferred: g.chapter == 1)
                    } else if f.ext == "mp4", let s = ClipName.canonStream(stem) {
                        add("stream:\(folder)/\(s.clip)", f, preferred: s.stream == 1)
                    } else {
                        add("file:\(f.relPath)", f)
                    }
                }
            default: break
            }
        }

        // WAVs on a camera card belong to the clips. They are a source of their own only on a recorder.
        if byKey.isEmpty {
            for f in audio {
                let folder = CardContext.folder(of: f.relPath)
                if folder.lowercased().hasSuffix(".take") { add("take:\(folder)", f) } else { add("file:\(f.relPath)", f) }
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// `A001_C001_0213N4_002` is part 2 of `A001_C001_0213N4`.
    static func part(of stem: String) -> (stem: String, number: Int)? {
        let u = Array(stem.utf8)
        guard u.count > 4, u[u.count - 4] == 95, u.suffix(3).allSatisfy(\.isASCIIDigit),
              let n = Int(String(decoding: u.suffix(3), as: UTF8.self)) else { return nil }
        return (String(decoding: u.dropLast(4), as: UTF8.self), n)
    }

    private static func isProxy(_ f: CardFile, folder: String, stem: String, ctx: CardContext) -> Bool {
        let parts = CardContext.components(folder)
        if parts.contains(where: { ["proxy", "proxies", "pxroot", "pxtmp"].contains($0) }) { return true }
        if parts.last == "sub", stem.uppercased().hasSuffix("S03") { return true }
        if stem.hasSuffix("_P") || stem.hasSuffix("_Proxy") { return true }
        if stem.count > 4, stem.hasSuffix("P"), let c = captures(proxyChunk, stem), !c.isEmpty { return true }
        if f.ext == "mov", folder.hasSuffix(".rdc") {
            return ctx.byFolder[CardContext.folder(of: f.relPath)]?.contains { $0.ext == "r3d" } ?? false
        }
        // Nikon: raw and proxy share a name. Pyxis: .braw and .MP4 share one.
        if f.ext == "mp4" {
            for ext in rawVideo where ctx.sibling(of: f.relPath, named: (stem + "." + ext).lowercased()) != nil { return true }
        }
        return false
    }
    private static let proxyChunk = regex("_[0-9]{2}P$")

    /// Clips that probably came the same way: same top folder, same type, same shape of name.
    private static func groupKey(_ f: CardFile, still: Bool) -> String {
        let top = f.relPath.firstIndex(of: "/").map { String(f.relPath[..<$0]) } ?? ""
        var shape = ""
        for c in CardContext.stem(of: f.name).prefix(48).unicodeScalars {
            if ("0" ... "9").contains(c) { shape.append("9") }
            else if CharacterSet.letters.contains(c) { shape.append("a") }
            else { shape.unicodeScalars.append(c) }
        }
        return "\(top)|\(still ? "still" : f.ext)|\(shape)"
    }
}
