import Foundation

public enum ByteFormat {
    /// "214.6 GB". Decimal units, the way macOS and drive labels count.
    public static func string(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v < 1_000 { return "\(bytes) bytes" }
        if v < 1_000_000 { return String(format: "%.0f KB", v / 1_000) }
        if v < 1_000_000_000 { return String(format: "%.0f MB", v / 1_000_000) }
        if v < 1_000_000_000_000 { return String(format: "%.1f GB", v / 1_000_000_000) }
        return String(format: "%.2f TB", v / 1_000_000_000_000)
    }

    /// "20 GB": a round figure, said as one.
    public static func round(_ bytes: UInt64) -> String {
        bytes % 1_000_000_000 == 0 && bytes >= 1_000_000_000 ? "\(bytes / 1_000_000_000) GB" : string(bytes)
    }
}
