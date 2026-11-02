// What the completeness pass really looked at, so the last line of the checklist never claims more.
// No clip is played here: every check reads structure, and the sentence says so.
import Foundation

public struct ClipCheckCount: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {     // in the order the report lists them
        case index      // QuickTime family: an index, and data as long as it says
        case mxfEnding  // MXF: the ending a finished clip has
        case redParts   // R3D: numbered parts and their footers
        case redNumbers // RED ProRes: numbered parts only, which can't show a missing last part
        case frameRun   // .ari, .arx, CinemaDNG: frame numbers with no gap
        case chapters   // GoPro: chapter numbers with no gap
        case streams    // Canon: stream numbers with no gap
    }
    public var kind: Kind
    public var format: String       // "MP4", "R3D"
    public var checked: Int         // files the check reached a conclusion on
    public var failed: Int          // of those checked, files the check found something wrong with
    public var unconfirmed: Int     // files it couldn't conclude anything about
    public init(kind: Kind, format: String, checked: Int, failed: Int = 0, unconfirmed: Int) {
        self.kind = kind; self.format = format; self.checked = checked; self.failed = failed; self.unconfirmed = unconfirmed
    }

    /// The claim is only true of a format that every file passed.
    var passed: Bool { checked > 0 && failed == 0 && unconfirmed == 0 }
    var total: Int { checked + unconfirmed }

    var checkName: String {
        switch kind {
        case .index: "index"
        case .mxfEnding: "ending"
        case .redParts, .redNumbers: "parts"
        case .frameRun: "frame number"
        case .chapters: "chapter"
        case .streams: "stream"
        }
    }
}

public struct ClipCheckReport: Codable, Hashable, Sendable {
    public var counts: [ClipCheckCount]
    public var unchecked: [String]  // "MTS", "Photos", "Audio": on the card, and nothing here looks at them
    public init(counts: [ClipCheckCount] = [], unchecked: [String] = []) {
        self.counts = counts; self.unchecked = unchecked
    }

    /// True when no check reached any file, so the line must not look like a pass.
    public var checkedNothing: Bool { !counts.contains { $0.checked > 0 } }
    /// Any file a check was meant to reach and couldn't.
    var hasGaps: Bool { !unchecked.isEmpty || counts.contains { $0.unconfirmed > 0 } }

    /// "Each MP4 has an index. Not played." "RED parts are all there. Not played." "Not checked for this format."
    /// Only a format every file passed gets its claim: "1 of 2 MP4 files didn't pass the index check. Not played."
    public var sentence: String {
        guard !checkedNothing else { return "Not checked for this format." }
        var parts: [String] = []
        let full = counts.filter(\.passed)
        let indexed = full.filter { $0.kind == .index }.map(\.format)
        if !indexed.isEmpty { parts.append("Each \(Self.list(indexed)) has an index.") }
        let mxf = full.filter { $0.kind == .mxfEnding }.map(\.format)
        if !mxf.isEmpty { parts.append("Each \(Self.list(mxf)) has a finished ending.") }
        if full.contains(where: { $0.kind == .redParts }) { parts.append("RED parts are all there.") }
        if full.contains(where: { $0.kind == .redNumbers }) { parts.append("RED part numbers have no gaps, though the last part can't be confirmed.") }
        if full.contains(where: { $0.kind == .frameRun }) { parts.append("Frame numbers have no gaps.") }
        if full.contains(where: { $0.kind == .chapters }) { parts.append("GoPro chapters have no gaps.") }
        if full.contains(where: { $0.kind == .streams }) { parts.append("Canon streams have no gaps.") }
        for c in counts where c.failed > 0 { parts.append("\(c.failed) of \(c.total) \(c.format) files didn't pass the \(c.checkName) check.") }
        for c in counts where c.unconfirmed > 0 { parts.append("\(c.unconfirmed) of \(c.total) \(c.format) files couldn't be checked.") }
        parts.append("Not played.")
        if !unchecked.isEmpty { parts.append("\(Self.list(unchecked)) not checked.") }
        return parts.joined(separator: " ")
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Tallies one completeness pass. Every file a check handles is marked covered, so what's left is what
/// no check looks at.
struct ClipCheckTally {
    private var counts: [String: ClipCheckCount] = [:]
    private var covered: Set<String> = []
    private var failed: Set<String> = []

    mutating func add(_ kind: ClipCheckCount.Kind, _ file: CardFile, concluded: Bool, format: String? = nil) {
        let name = format ?? file.ext.uppercased()
        var count = counts[kind.rawValue + "|" + name] ?? ClipCheckCount(kind: kind, format: name, checked: 0, unconfirmed: 0)
        if concluded { count.checked += 1 } else { count.unconfirmed += 1 }
        counts[kind.rawValue + "|" + name] = count
        covered.insert(file.relPath)
    }

    /// This file was checked and didn't pass. Counted once, however many ways it failed.
    mutating func fail(_ kind: ClipCheckCount.Kind, _ file: CardFile, format: String? = nil) {
        let key = kind.rawValue + "|" + (format ?? file.ext.uppercased())
        if failed.insert(key + "|" + file.relPath).inserted { counts[key]?.failed += 1 }
    }

    func report(files: [CardFile]) -> ClipCheckReport {
        var video: Set<String> = [], photos = false, audio = false
        for f in files where !covered.contains(f.relPath) {
            switch f.kind {
            case .video: video.insert(f.ext.uppercased())
            case .still: photos = true
            case .audio: audio = true
            case .sidecar, .other: break
            }
        }
        var unchecked = video.sorted()
        if photos { unchecked.append("Photos") }
        if audio { unchecked.append("Audio") }
        let kinds = ClipCheckCount.Kind.allCases
        // The commonest format first, so a card of MP4s with one MOV reads that way round.
        let sorted = counts.values.sorted {
            let a = kinds.firstIndex(of: $0.kind) ?? 0, b = kinds.firstIndex(of: $1.kind) ?? 0
            if a != b { return a < b }
            let x = $0.checked + $0.unconfirmed, y = $1.checked + $1.unconfirmed
            return x != y ? x > y : $0.format < $1.format
        }
        return ClipCheckReport(counts: sorted, unchecked: unchecked)
    }
}
