// Bounds-checked reading. Cards can be corrupt, so nothing here may trap on file content.
import Foundation
import CIngest

/// A read-only window on one file. Every read goes through `ci_pread`; a small cache means
/// walking neighbouring atoms costs one read, not one per atom.
final class ByteFile {
    let path: String
    /// From stat. Virtual volumes can report 0 for a file that has data.
    let size: UInt64
    private var windowStart: UInt64 = 0
    private var window: [UInt8] = []

    private static let windowSize = 16 * 1024
    static let maxRead = 64 << 20

    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        self.path = path
        self.size = UInt64(max(st.st_size, 0))
    }

    /// Up to `count` bytes at `offset`. Short or empty at end of file or on a read error.
    func read(at offset: UInt64, count: Int) -> [UInt8] {
        guard count > 0, offset <= UInt64(Int64.max) - UInt64(Self.maxRead) else { return [] }
        let count = min(count, Self.maxRead)
        if offset >= windowStart, offset + UInt64(count) <= windowStart + UInt64(window.count) {
            let start = Int(offset - windowStart)
            return Array(window[start ..< start + count])
        }
        if count >= Self.windowSize { return raw(offset, count) }
        window = raw(offset, Self.windowSize)
        windowStart = offset
        return Array(window.prefix(count))
    }

    private func raw(_ offset: UInt64, _ count: Int) -> [UInt8] {
        var got: Int64 = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            got = path.withCString { ci_pread($0, offset, buffer.baseAddress, count) }
            initialized = got > 0 ? Int(got) : 0
        }
        return bytes
    }
}

extension UInt8 {
    var isASCIIDigit: Bool { (48 ... 57).contains(self) }
    var isASCIIUpper: Bool { (65 ... 90).contains(self) }
    var isASCIILetter: Bool { isASCIIUpper || (97 ... 122).contains(self) }
}

extension Array where Element == UInt8 {
    /// The bytes as text, with anything unprintable as a line break.
    var printableLines: String { String(map { (0x20 ... 0x7E).contains($0) ? Character(UnicodeScalar($0)) : "\n" }) }

    private func int<T: FixedWidthInteger>(_ i: Int, bigEndian: Bool) -> T? {
        let size = MemoryLayout<T>.size
        guard i >= 0, count >= size, i <= count - size else { return nil }
        var v: T = 0
        for k in 0 ..< size { v = v << 8 | T(self[i + (bigEndian ? k : size - 1 - k)]) }
        return v
    }
    func be16(_ i: Int) -> UInt16? { int(i, bigEndian: true) }
    func le16(_ i: Int) -> UInt16? { int(i, bigEndian: false) }
    func be32(_ i: Int) -> UInt32? { int(i, bigEndian: true) }
    func le32(_ i: Int) -> UInt32? { int(i, bigEndian: false) }
    func be64(_ i: Int) -> UInt64? { int(i, bigEndian: true) }
    func le64(_ i: Int) -> UInt64? { int(i, bigEndian: false) }

    /// First occurrence of `needle` at or after `from`.
    func find(_ needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, from >= 0, from < count, count - from >= needle.count else { return nil }
        return withUnsafeBytes { hay -> Int? in
            guard let base = hay.baseAddress else { return nil }
            return needle.withUnsafeBytes { n -> Int? in
                guard let nBase = n.baseAddress,
                      let hit = memmem(base + from, count - from, nBase, n.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
        }
    }

    func matches(_ needle: [UInt8], at i: Int) -> Bool {
        guard i >= 0, i <= count - needle.count else { return false }
        for k in 0 ..< needle.count where self[i + k] != needle[k] { return false }
        return true
    }

    /// Bytes as text, stopping at the first NUL, with surrounding space removed. Empty for nothing usable.
    func text(from start: Int = 0, length: Int? = nil) -> String {
        guard start >= 0, start < count else { return "" }
        let wanted = Swift.max(length ?? count, 0)
        let end = wanted >= count - start ? count : start + wanted
        guard start < end else { return "" }
        var stop = start
        while stop < end, self[stop] != 0 { stop += 1 }
        return String(decoding: self[start ..< stop], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// UTF-16 big-endian text, as MXF strings are stored.
    func utf16be(from start: Int, length: Int) -> String {
        guard start >= 0, length >= 2, start + length <= count else { return "" }
        var units: [UInt16] = []
        var i = start
        while i + 1 < start + length, let u = be16(i), u != 0 { units.append(u); i += 2 }
        return String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
