// Is this mounted volume a card? Root only, and fast: a working drive holds the same folders much deeper down.
import Foundation

enum VolumeProbe {
    private struct Entry { var name: String; var isDir: Bool }

    /// Folders a camera may leave at the root beside its media. Anything else counts as unknown.
    private static let cardFolders: Set<String> = [
        "dcim", "private", "m4root", "xdroot", "cineroot", "avchd", "avf_info", "sony", "misc", "crm", "xfvc",
        "contents", "mp_root", "mssony", "stills", "proxy", "presets", "3dluts", "falsetakes", "false take",
        "trash", "bdmv", "certificate", "hifi", "lost.dir", "android", "ad_lumix", "canonmsc", "eosmisc", "nikon",
        "log", "logs", "extra", "hidden", "arri_udf",
    ]
    /// Files and bundles only editing leaves behind. `.fcpbundle` and `.dra` are folders.
    private static let projectExtensions: Set<String> = [
        "prproj", "drp", "drt", "dra", "aep", "aepx", "fcpbundle", "fcpxml", "ppj", "veg", "sesx", "als", "ptx",
        "logicx", "band", "imovielibrary", "photoslibrary", "tvlibrary", "backupdb",
    ]
    private static let cameraNamedMOV = regex(#"^[A-Z][0-9]{3}_[0-9]{8}_C[0-9]{3,4}\.mov$"#)

    /// Up to here a camera folder is believed. A card has no reason to hold more strangers than this.
    private static let toleratedUnknownFolders = 2
    /// More strangers than this and it is someone's drive, whatever else sits at the root.
    private static let maxUnknownFolders = 8

    private static func list(_ path: String, limit: Int = 4096) -> [Entry] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var out: [Entry] = []
        while out.count < limit, let e = readdir(dir) {
            let name = withUnsafePointer(to: &e.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            if name == "." || name == ".." || Junk.isSystemName(name) { continue }
            var isDir = Int32(e.pointee.d_type) == DT_DIR
            if Int32(e.pointee.d_type) == DT_UNKNOWN {
                var st = stat()
                isDir = lstat(path + "/" + name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }
            out.append(Entry(name: name, isDir: isDir))
        }
        return out
    }

    private static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    private static func isProject(_ entry: Entry) -> Bool { projectExtensions.contains(ext(entry.name)) }

    static func look(atRoot root: URL) -> VolumeLook {
        var rootPath = root.path
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        let entries = list(rootPath)
        let filesAtRoot = entries.filter { !$0.isDir }.map(\.name)

        if filesAtRoot.contains(".codexvfs") {
            return .cameraCard(entries.contains { $0.isDir && ClipName.isARRIReelFolder($0.name) } ? .arri : .unknown)
        }
        if entries.contains(where: isProject) { return .notACard }

        let unknown = entries.filter { $0.isDir && !cardFolders.contains($0.name.lowercased()) && !isCameraFolderName($0.name) }.map(\.name)
        // A recorder's folders are its own, however many there are, so this comes before counting them.
        if isRecorder(rootPath, entries: entries, filesAtRoot: filesAtRoot, unknown: unknown) { return .cameraCard(.audioRecorder) }
        if unknown.count > maxUnknownFolders { return .notACard }
        for folder in unknown where list(rootPath + "/" + folder, limit: 512).contains(where: isProject) { return .notACard }

        if let family = marker(rootPath, entries: entries, filesAtRoot: filesAtRoot) {
            guard unknown.count > toleratedUnknownFolders else { return .cameraCard(family) }
            return .maybeCard("Camera folders next to \(unknown.count) other folders, so this could be a working drive")
        }
        return maybeCard(rootPath, entries: entries)
    }

    /// The strongest thing the root says. nil when it says nothing.
    private static func marker(_ rootPath: String, entries: [Entry], filesAtRoot: [String]) -> CameraFamily? {
        var dirs: [String: String] = [:]
        for e in entries where e.isDir { dirs[e.name.lowercased()] = e.name }
        func listIn(_ lower: String) -> [Entry] { dirs[lower].map { list(rootPath + "/" + $0, limit: 512) } ?? [] }

        if (rootPath as NSString).lastPathComponent.uppercased() == "ARRI_UDF" || dirs["arri_udf"] != nil { return .arri }
        if dirs["m4root"] != nil || dirs["xdroot"] != nil || dirs["cineroot"] != nil { return .sony }
        let privateNames = Set(listIn("private").filter(\.isDir).map { $0.name.lowercased() })
        if !privateNames.isDisjoint(with: ["m4root", "xdroot", "cineroot", "pxroot"]) { return .sony }
        if privateNames.contains("pana_grp") { return .panasonic }
        if privateNames.contains("audio") { return .canon }
        if renamedSonyRoot(rootPath, dirs: dirs) { return .sony }

        for folder in ["xfvc", "crm"] where dirs[folder] != nil {
            if listIn(folder).contains(where: { $0.isDir && $0.name.uppercased().hasPrefix("REEL_") }) { return .canon }
        }
        if dirs["contents"] != nil {
            if filesAtRoot.contains(where: { $0.uppercased() == "LASTCLIP.TXT" }) { return .panasonic }
            if listIn("contents").contains(where: { $0.isDir && $0.name.uppercased() == "CLIPS001" }) { return .canon }
        }
        for e in entries where e.isDir && ext(e.name) == "rdm" {
            if list(rootPath + "/" + e.name, limit: 64).contains(where: { $0.isDir && ext($0.name) == "rdc" }) { return .red }
        }
        for e in entries where e.isDir && ClipName.isARRIReelFolder(e.name) {
            let inside = list(rootPath + "/" + e.name, limit: 64)
            if inside.contains(where: { ["mxf", "ale", "mov", "ari", "arx"].contains(ext($0.name)) || $0.isDir }) { return .arri }
        }
        if dirs["avchd"] != nil || privateNames.contains("avchd") { return dirs["sony"] != nil ? .sony : .unknown }
        if dirs["dcim"] != nil {
            let hinted = listIn("dcim").filter(\.isDir).compactMap { family(ofDCIMFolder: $0.name) }.first
            return hinted ?? (dirs["sony"] != nil ? .sony : .unknown)
        }
        return nil
    }

    /// Camera-made names at the root, which must not count against a card.
    private static func isCameraFolderName(_ name: String) -> Bool {
        let e = ext(name)
        return e == "rdm" || e == "take" || ClipName.isARRIReelFolder(name)
    }

    /// `/<X>/MEDIAPRO.XML` or `/PRIVATE/<X>/MEDIAPRO.XML`: Sony lets a body rename the root folder.
    private static func renamedSonyRoot(_ rootPath: String, dirs: [String: String]) -> Bool {
        var candidates = dirs.values.map { rootPath + "/" + $0 }
        if let priv = dirs["private"] {
            candidates += list(rootPath + "/" + priv, limit: 32).filter(\.isDir).map { rootPath + "/" + priv + "/" + $0.name }
        }
        for folder in candidates.prefix(24) {
            for name in ["MEDIAPRO.XML", "mediapro.xml"] {
                let path = folder + "/" + name
                if let file = ByteFile(path: path), Sony.parseProfile(file.read(at: 0, count: 4096)) != nil { return true }
            }
        }
        return false
    }

    private static let recorderName = regex("^(ZOOM[0-9]{4}|Scene[0-9]+_[0-9]+|STE-[0-9]{3})")
    private static let recorderFolder = regex("^(FOLDER[0-9]{2}|[0-9]{6})$")

    private static func recorderWAV(_ folder: String, _ name: String) -> Bool {
        if captures(recorderName, name) != nil { return true }
        guard let file = ByteFile(path: folder + "/" + name), let info = RIFF.parse(file) else { return false }
        return AudioRecorders.identify(info) != nil
    }

    private static func wavs(in path: String, limit: Int = 64) -> [String] {
        list(path, limit: limit).filter { !$0.isDir && ["wav", "bwf"].contains(ext($0.name)) }.map(\.name)
    }

    /// `.TAKE` folders, a recorder's own file names, or a WAV whose `bext` names a recorder. A recorder's
    /// card can hold a folder per day or project, so folders only count against it when they prove nothing.
    private static func isRecorder(_ rootPath: String, entries: [Entry], filesAtRoot: [String], unknown: [String]) -> Bool {
        let dated = unknown.filter { captures(recorderFolder, $0) != nil }
        let other = unknown.filter { captures(recorderFolder, $0) == nil }
        if other.count <= toleratedUnknownFolders {
            if entries.contains(where: { $0.isDir && (ext($0.name) == "take" || ["false take", "falsetakes"].contains($0.name.lowercased())) }) { return true }
            if filesAtRoot.filter({ ["wav", "bwf"].contains(ext($0)) }).prefix(4).contains(where: { recorderWAV(rootPath, $0) }) { return true }
            for folder in dated.prefix(4) {
                let path = rootPath + "/" + folder
                if wavs(in: path).prefix(2).contains(where: { recorderWAV(path, $0) }) { return true }
            }
            return false
        }
        // Project folders with free names: every one looked at must hold a recorder's WAV.
        return other.prefix(6).allSatisfy { folder in
            let path = rootPath + "/" + folder
            return wavs(in: path).first.map { recorderWAV(path, $0) } ?? false
        }
    }

    /// The DCF suffix is a hint: owners can change it, and a bare DCIM says nothing.
    static func family(ofDCIMFolder name: String) -> CameraFamily? {
        let u = name.uppercased()
        if u.hasPrefix("CAMERA"), u.count == 8 { return .insta360 }
        if u.hasPrefix("DJI_") || u.hasPrefix("CAM_") { return .dji }      // CAM_001 is the Osmo 360
        guard u.count >= 5, u.prefix(3).allSatisfy(\.isNumber) else { return nil }
        let tail = u.dropFirst(3)
        if tail == "MSDCF" { return .sony }
        if tail.hasPrefix("EOS") || tail == "CANON" { return .canon }
        if tail == "_PANA" || tail == "PANA" { return .panasonic }
        if tail == "NIKON" || tail.hasPrefix("NC") || tail.hasPrefix("ND") || tail.hasPrefix("NZ") { return .nikon }
        if tail == "_FUJI" { return .fujifilm }
        if tail == "GOPRO" { return .gopro }
        if tail == "MEDIA" { return .dji }
        if tail == "APPLE" { return .apple }
        if tail.first == "_", tail.count == 5, tail.dropFirst().allSatisfy(\.isNumber) { return .canon }   // NNN_mmdd on Cinema EOS
        return nil
    }

    /// Media nobody recognises is still media: it must be asked about, never offered as a backup drive.
    /// Looks at the root, one folder down, and a little further, because a clip can have a folder of its own.
    private static func maybeCard(_ rootPath: String, entries: [Entry]) -> VolumeLook {
        func reason(_ names: [String]) -> String? {
            let extensions = Set(names.map(ext))
            if !extensions.isDisjoint(with: ["braw", "braw2"]) { return "Blackmagic RAW clips with no card folders around them" }
            if extensions.contains("r3d") { return "R3D clips with no card folders around them" }
            if extensions.contains("mxf") { return "MXF clips in a layout this app doesn't know" }
            if names.contains(where: { ext($0) == "mov" && (captures(cameraNamedMOV, $0) != nil || ClipName.arri(($0 as NSString).deletingPathExtension) != nil) }) {
                return "Camera-named ProRes clips with no card folders around them"
            }
            if !extensions.isDisjoint(with: Extensions.video) { return "Video files in a layout this app doesn't know" }
            if !extensions.isDisjoint(with: Extensions.cameraRaw) { return "Camera raw photos in a layout this app doesn't know" }
            if !extensions.isDisjoint(with: ["wav", "bwf"]) { return "Audio files in a layout this app doesn't know" }
            return nil
        }
        if entries.contains(where: { $0.isDir && ext($0.name) == "rdm" }) { return .maybeCard("A RED magazine with no clips in it") }
        if let why = reason(entries.filter { !$0.isDir }.map(\.name)) { return .maybeCard(why) }

        var listings = 0
        var deeper: [String] = []
        for folder in entries.filter(\.isDir).map({ rootPath + "/" + $0.name }).prefix(16) {
            listings += 1
            let inside = list(folder, limit: 256)
            if let why = reason(inside.filter { !$0.isDir }.map(\.name)) { return .maybeCard(why) }
            deeper += inside.filter(\.isDir).prefix(4).map { folder + "/" + $0.name }
        }
        for folder in deeper where listings < 24 {
            listings += 1
            if let why = reason(list(folder, limit: 256).filter { !$0.isDir }.map(\.name)) { return .maybeCard(why) }
        }
        return .notACard
    }
}
