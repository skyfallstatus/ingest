import Foundation

enum IngestError: Error, LocalizedError, Equatable {
    case driveNotWritable(String)
    case notEnoughSpace(needed: UInt64, free: UInt64)
    case fileTooLarge(String)
    case sameVolume
    case outsideDrive(String)
    var errorDescription: String? {
        switch self {
        case .driveNotWritable(let d): "\((d as NSString).lastPathComponent) can't be written to."
        case .notEnoughSpace(let n, let f):
            "Not enough room: this needs \(ByteFormat.string(n)) and only \(ByteFormat.string(f)) is free."
        case .fileTooLarge(let n): "\(n) is too large for this drive's format."
        case .sameVolume: "A card can't be copied onto itself. Choose a different drive."
        case .outsideDrive(let p): "\(p) isn't a folder this app can use on the drive."
        }
    }
}
