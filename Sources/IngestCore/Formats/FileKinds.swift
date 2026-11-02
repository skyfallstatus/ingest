// Classifying a path. Called for every file on a card, so no I/O and no regular expressions.
import Foundation

enum Extensions {
    static let cameraRaw: Set<String> = [
        "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "dng", "rw2", "orf", "pef", "srw",
        "iiq", "3fr", "fff", "x3f", "erf", "mrw", "rwl", "gpr", "kdc", "dcr", "raw", "insp",
    ]
    static let image: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "hif", "tif", "tiff", "png", "bmp", "gif", "webp"]
    static let video: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mxf", "braw", "braw2", "r3d", "nev", "insv", "crm", "ari", "arx",
        "avi", "mts", "m2ts", "m2t", "mpg", "mpeg", "3gp", "mkv", "wmv", "dv", "vob", "360", "osv",
    ]
    static let audio: Set<String> = ["wav", "wave", "bwf", "rf64", "w64", "aif", "aiff", "mp3", "m4a", "aac", "flac", "ogg", "wma"]
    static let sidecar: Set<String> = [
        "xml", "thm", "lrf", "lrv", "rtn", "rmd", "ale", "ada", "srt", "sidecar", "cif", "cpf", "sif", "mif", "xmp",
        "cube", "3dl", "lut", "mhl", "bnp", "inp", "int", "ind", "cpi", "mpl", "bdm", "bin", "dat", "csv", "aae",
    ]
    /// ISO-style containers the index check understands.
    static let quickTime: Set<String> = ["mp4", "m4v", "mov", "qt", "braw", "insv", "nev", "crm"]
}

enum FileKinds {
    private static let thumbnailFolders: Set<String> = ["thmbnl", "thumb", "thumbs", "thumbnail", "thumbnails", "icon"]

    static func kind(_ path: String) -> FileKind {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...].lowercased()

        if Extensions.video.contains(ext) {
            if ext == "braw", isBlackmagicStill(path, stem: name[..<dot]) { return .still }
            return .video
        }
        if Extensions.audio.contains(ext) { return .audio }
        if Extensions.sidecar.contains(ext) { return .sidecar }

        let isRaw = Extensions.cameraRaw.contains(ext)
        guard isRaw || Extensions.image.contains(ext) else { return .other }
        let folders = path.split(separator: "/").dropLast().map { $0.lowercased() }
        if folders.contains(where: thumbnailFolders.contains) { return .sidecar }
        if isRaw {
            // CinemaDNG is one DNG per frame. Those are a clip, not thousands of photos.
            if ext == "dng", !folders.contains("dcim"), !folders.contains("stills"), isFrameNumbered(name[..<dot]) { return .video }
            return .still
        }
        return folders.contains("dcim") || folders.contains("stills") ? .still : .other
    }

    /// `A001_08151512_S001.braw` in a `stills` folder is one frame someone chose to keep.
    private static func isBlackmagicStill(_ path: String, stem: Substring) -> Bool {
        guard path.split(separator: "/").dropLast().contains(where: { $0.lowercased() == "stills" }),
              let mark = stem.range(of: "_S", options: .backwards) else { return false }
        let digits = stem[mark.upperBound...]
        return digits.count >= 3 && digits.allSatisfy(\.isNumber)
    }

    private static func isFrameNumbered(_ stem: Substring) -> Bool {
        var digits = 0
        for c in stem.utf8.reversed() {
            if c.isASCIIDigit { digits += 1 } else { return digits >= 6 && (c == 95 || c == 46) }
        }
        return false
    }
}
