// What the engine knows about cards, cameras and drives.
import Foundation

public enum FileKind: String, Sendable {
    case video, still, audio, sidecar, other
}

/// One non-junk file on a card, exactly as the filesystem listed it.
public struct CardFile: Hashable, Sendable {
    public var relPath: String      // relative to the card root, in readdir form. Never normalise this.
    public var size: UInt64         // as listed. Can be 0 on virtual volumes.
    public var mtime: Int64         // seconds. Never integrity evidence.
    var mtimeNanos: Int64
    public var kind: FileKind
    public init(relPath: String, size: UInt64, mtime: Int64, mtimeNanos: Int64 = 0, kind: FileKind) {
        self.relPath = relPath; self.size = size; self.mtime = mtime; self.mtimeNanos = mtimeNanos; self.kind = kind
    }
    public var name: String { (relPath as NSString).lastPathComponent }
    var ext: String { (relPath as NSString).pathExtension.lowercased() }
}

public enum CameraFamily: String, Codable, Sendable {
    case sony, canon, blackmagic, red, arri, panasonic, nikon, fujifilm, dji, gopro, insta360, apple, audioRecorder, unknown
}

public struct CameraIdentity: Codable, Hashable, Sendable {
    public var family: CameraFamily
    public var make: String?            // "Sony"
    public var model: String?           // Raw model string: "ILME-FX3", stripped of version suffixes
    public var displayModel: String     // Short human name used for folders: "FX3", "ALEXA 35", "URSA Cine 12K LF"
    public var serial: String?          // A real body serial or PIN. nil when unknown. Never a placeholder.
    public var bodyKey: String?         // Stable identifier to remember this body: serial, else e.g. Sony systemId
    public var modelIsCertain: Bool     // false when the model came from a heuristic or conflicting sources
    public init(family: CameraFamily, make: String? = nil, model: String? = nil, displayModel: String,
                serial: String? = nil, bodyKey: String? = nil, modelIsCertain: Bool = true) {
        self.family = family; self.make = make; self.model = model; self.displayModel = displayModel
        self.serial = serial; self.bodyKey = bodyKey; self.modelIsCertain = modelIsCertain
    }
    /// "…0001", the form the UI shows. nil when there is no serial.
    public var serialTail: String? {
        guard let serial, !serial.isEmpty else { return nil }
        return "…" + serial.suffix(4)
    }
}

/// A wall-clock date as the camera wrote it. Never shifted through UTC: a clip shot at 01:48 in Tokyo is that day.
public struct CalendarDay: Codable, Hashable, Comparable, Sendable {
    public var year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
    /// A day the calendar has: no 30 February, no month 13.
    var exists: Bool {
        guard (1 ... 12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
    /// Folder names and camera dates are Gregorian, whatever calendar the Mac is set to.
    public static var gregorian: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    public func date(in calendar: Calendar = CalendarDay.gregorian) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }
    public init(_ date: Date, calendar: Calendar = CalendarDay.gregorian) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }
}

public enum DateSource: String, Codable, Sendable {
    case cameraMetadata, fileName, containerUTC, fileModified
}

public struct CaptureDay: Codable, Hashable, Sendable {
    public var day: CalendarDay
    public var fileCount: Int
    public var source: DateSource
    public init(day: CalendarDay, fileCount: Int, source: DateSource) {
        self.day = day; self.fileCount = fileCount; self.source = source
    }
}

/// A problem found on the card. Only `.note` lets a card turn green.
public enum IssueSeverity: String, Codable, Sendable, Comparable {
    case note       // Worth saying. Does not stop "Safe to format".
    case hold       // Everything copied, but a person should look before formatting. Amber.
    case blocker    // Never "Safe to format" while this stands. Red.
    private var rank: Int { switch self { case .note: 0; case .hold: 1; case .blocker: 2 } }
    public static func < (a: IssueSeverity, b: IssueSeverity) -> Bool { a.rank < b.rank }
}

public struct CardIssue: Codable, Hashable, Sendable {
    public var severity: IssueSeverity
    public var code: String             // stable, e.g. "red.missing-part"
    public var message: String          // one plain sentence for the user
    public var paths: [String]          // card-relative paths involved
    public init(severity: IssueSeverity, code: String, message: String, paths: [String] = []) {
        self.severity = severity; self.code = code; self.message = message; self.paths = paths
    }
}

/// What the probe learned about a card. Identification is best effort and never affects what gets copied.
public struct ProbeResult: Codable, Sendable {
    public var cameras: [CameraOnCard]
    public var reel: String?            // Card/reel label from the files: "A082", "A_0001_12NR". nil when none.
    public var captureDays: [CaptureDay]// newest last
    public var issues: [CardIssue]
    public var hasVideo: Bool
    public var hasStills: Bool
    public var hasAudio: Bool
    public var clipChecks: ClipCheckReport  // what the completeness pass looked at, for the honest last line
    public init(cameras: [CameraOnCard] = [], reel: String? = nil, captureDays: [CaptureDay] = [],
                issues: [CardIssue] = [], hasVideo: Bool = false, hasStills: Bool = false, hasAudio: Bool = false,
                clipChecks: ClipCheckReport = ClipCheckReport()) {
        self.cameras = cameras; self.reel = reel; self.captureDays = captureDays; self.issues = issues
        self.hasVideo = hasVideo; self.hasStills = hasStills; self.hasAudio = hasAudio; self.clipChecks = clipChecks
    }
}

public struct CameraOnCard: Codable, Hashable, Sendable {
    public var identity: CameraIdentity
    public var clipCount: Int
    public init(identity: CameraIdentity, clipCount: Int) { self.identity = identity; self.clipCount = clipCount }
}

/// How a mounted volume looks from its root. Markers are only ever read at the volume root.
public enum VolumeLook: Equatable, Sendable {
    case cameraCard(CameraFamily)   // Strong marker at root
    case maybeCard(String)          // Camera files but no structure, e.g. BRAW on an SSD. Ask the user.
    case notACard
}

public struct DriveEntry: Hashable, Sendable {
    public var path: String     // relative to the drive root, in readdir form
    public var isDir: Bool
    public var size: UInt64
    public var mtime: Int64
    public init(path: String, isDir: Bool, size: UInt64, mtime: Int64) {
        self.path = path; self.isDir = isDir; self.size = size; self.mtime = mtime
    }
}
