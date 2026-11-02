// How someone organises a drive, and a plan for one shoot on it.
import Foundation

public enum PathLevel: Codable, Hashable, Sendable {
    case year                   // "2026"
    case literal(String)        // "Paid work": always the same
    case client                 // changes per client
}

public struct ShootNameStyle: Codable, Hashable, Sendable {
    public enum Position: String, Codable, Sendable { case prefix, suffix }
    public var dateFormat: String       // Unicode pattern: "dd.MM.yy", "yyyy-MM-dd", "yyMMdd", "yyyy-MM"
    public var position: Position
    public var separator: String        // usually " "
    public var uppercase: Bool          // shoot names are written in capitals on this drive
    public init(dateFormat: String = "dd.MM.yy", position: Position = .prefix, separator: String = " ", uppercase: Bool = false) {
        self.dateFormat = dateFormat; self.position = position; self.separator = separator; self.uppercase = uppercase
    }
}

public enum FolderRole: String, Codable, Sendable {
    case footage, photo, photoRaw, photoExports, audio, project, exports, plain
}

public struct InnerFolder: Codable, Hashable, Sendable {
    public var name: String
    public var role: FolderRole
    public var children: [InnerFolder]
    public init(name: String, role: FolderRole, children: [InnerFolder] = []) {
        self.name = name; self.role = role; self.children = children
    }
}

/// What sits inside the footage folder. Every card is always copied whole, in its own folder.
public enum FootageStyle: Codable, Hashable, Sendable {
    case perCamera              // Footage/FX3/<card folder>/…
    case perCard(prefix: String)// 01 ORIGINALS/CARD A082/…   (prefix "CARD ")
}

public struct LearnedStats: Codable, Hashable, Sendable {
    public var foldersRead: Int
    public var shootsFound: Int
    public var shootsFollowing: Int
    public var exception: String?       // "5 older shoots also have a folder called Video. Nothing in them moves."
    public var mostRecentClient: String?
    public var mostRecentDay: CalendarDay?
    public init(foldersRead: Int, shootsFound: Int, shootsFollowing: Int, exception: String? = nil,
                mostRecentClient: String? = nil, mostRecentDay: CalendarDay? = nil) {
        self.foldersRead = foldersRead; self.shootsFound = shootsFound; self.shootsFollowing = shootsFollowing
        self.exception = exception; self.mostRecentClient = mostRecentClient; self.mostRecentDay = mostRecentDay
    }
}

public struct DriveSetup: Codable, Hashable, Sendable {
    public var path: [PathLevel]        // folders above the shoot folder
    public var shootName: ShootNameStyle
    public var inner: [InnerFolder]     // inside each shoot
    public var footage: FootageStyle
    public var learned: LearnedStats?   // nil for presets
    public init(path: [PathLevel], shootName: ShootNameStyle, inner: [InnerFolder], footage: FootageStyle, learned: LearnedStats? = nil) {
        self.path = path; self.shootName = shootName; self.inner = inner; self.footage = footage; self.learned = learned
    }
}

/// What someone typed to name a shoot.
public struct ShootRequest: Hashable, Sendable {
    public var client: String
    public var shootName: String
    public var day: CalendarDay
    public var cameraFolder: String     // "FX3"
    public var cardFolder: String       // "A082"
    public var hasVideo: Bool
    public var hasStills: Bool
    public var hasAudio: Bool
    public init(client: String, shootName: String, day: CalendarDay, cameraFolder: String, cardFolder: String,
                hasVideo: Bool, hasStills: Bool, hasAudio: Bool) {
        self.client = client; self.shootName = shootName; self.day = day; self.cameraFolder = cameraFolder
        self.cardFolder = cardFolder; self.hasVideo = hasVideo; self.hasStills = hasStills; self.hasAudio = hasAudio
    }
}

/// One row of the folder preview.
struct PlanRow: Hashable, Sendable {
    var name: String
    var depth: Int
    var isNew: Bool              // false when the folder exists
    var receivesFiles: Bool      // true on the row the card lands in
}

public struct ShootPlan: Hashable, Sendable {
    var rows: [PlanRow]
    public var shootPath: String        // drive-relative
    public var footagePath: String      // drive-relative folder that receives the card tree
    public var stillsPath: String?      // drive-relative folder for DCIM stills, when the setup has one
    public var audioPath: String?       // drive-relative folder for audio recorder cards
    public var foldersToCreate: [String]// drive-relative, parents first
    public var skippedNote: String?     // "No Photo folder: only video here."
    public var clientExists: Bool
    public var existingClientName: String? // spelling already on the drive
    var pills: [PlanPill]        // for the path animation
}

struct PlanPill: Hashable, Sendable {
    var label: String
    var depth: Int
    var changesEachShoot: Bool
}
