// What a card adds up to: which clips are worth opening, then the cameras, days and reel they show.
import Foundation

enum Sampling {
    /// First, last and an even spread between them.
    static func indices(count: Int, take: Int) -> [Int] {
        guard count > 0, take > 0 else { return [] }
        guard count > take else { return Array(0 ..< count) }
        guard take > 1 else { return [0] }
        var out: [Int] = []
        for i in 0 ..< take {
            let at = i * (count - 1) / (take - 1)
            if out.last != at { out.append(at) }
        }
        return out
    }
}

enum Cameras {
    private static let samplesPerGroup = 5
    private static let samplesWhenMixed = 24
    private static let maxGroupsRead = 40

    private struct Seen {
        var identity: CameraIdentity
        var altKey: String?
        var clips: Int
    }

    static func tally(_ units: [ClipUnit], _ reader: ClipReader) -> [CameraOnCard] {
        let ordered = Dictionary(grouping: units, by: \.group).values.sorted { ($0.count, $0[0].group) > ($1.count, $1[0].group) }

        var seen: [Seen] = []
        var leftovers = 0
        for (i, list) in ordered.enumerated() {
            guard i < maxGroupsRead else {
                leftovers += list.count
                continue
            }
            for share in shares(list, reader) { merge(share, into: &seen) }
        }
        // Past the read limit, a clip counts for the biggest camera in the listing. Identification
        // decides nothing about copying, and a hundred one-off names shouldn't cost a hundred reads.
        if let biggest = seen.indices.max(by: { seen[$0].clips < seen[$1].clips }) {
            seen[biggest].clips += leftovers
        }
        // A card with an index and no clips still says which body it was in.
        for (_, profile) in reader.sonyMedia where seen.isEmpty {
            merge(Seen(identity: Sony.identity(model: profile.model, serial: nil, systemId: profile.systemId),
                       altKey: profile.systemId, clips: 0), into: &seen)
        }
        return seen
            .map { CameraOnCard(identity: $0.identity, clipCount: $0.clips) }
            .sorted { ($0.clipCount, $1.identity.displayModel) > ($1.clipCount, $0.identity.displayModel) }
    }

    private static let unknown = CameraIdentity(family: .unknown, displayModel: "Camera", modelIsCertain: false)

    /// Reads a few clips of one group. When they disagree, reads more, then splits the group's count in proportion.
    private static func shares(_ list: [ClipUnit], _ reader: ClipReader) -> [Seen] {
        func read(_ take: Int) -> [Seen] {
            var found: [Seen] = []
            for i in Sampling.indices(count: list.count, take: take) {
                let facts = reader.facts(list[i])
                guard let identity = facts.identity else { continue }
                merge(Seen(identity: identity, altKey: facts.altKey, clips: 1), into: &found)
            }
            return found
        }
        var found = read(samplesPerGroup)
        if found.count > 1 { found = read(samplesWhenMixed) }
        guard !found.isEmpty else { return [Seen(identity: unknown, clips: list.count)] }

        let sampled = found.reduce(0) { $0 + $1.clips }
        var assigned = 0
        for i in found.indices {
            let share = i == found.count - 1 ? list.count - assigned : found[i].clips * list.count / sampled
            found[i].clips = share
            assigned += share
        }
        return found
    }

    private static func merge(_ new: Seen, into seen: inout [Seen]) {
        if let i = seen.firstIndex(where: { sameBody($0, new) }) {
            seen[i].clips += new.clips
            seen[i].identity = better(seen[i].identity, new.identity)
            seen[i].altKey = seen[i].altKey ?? new.altKey
        } else {
            seen.append(new)
        }
    }

    private static func sameBody(_ a: Seen, _ b: Seen) -> Bool {
        let x = a.identity, y = b.identity
        guard x.family == y.family else { return false }
        if x.family == .unknown { return x.model == y.model }
        if let s = x.serial, let t = y.serial { return s == t }
        if let k = a.altKey, k == b.altKey { return true }
        if let k = x.bodyKey, k == y.bodyKey { return true }
        // Model unread on one side: the same family on one card is the same camera until shown otherwise.
        guard let m = x.model, let n = y.model else { return true }
        guard m.caseInsensitiveCompare(n) == .orderedSame else { return false }
        return x.bodyKey == nil || y.bodyKey == nil
    }

    /// Keeps whatever each sighting knows. A certain model beats a guess.
    private static func better(_ a: CameraIdentity, _ b: CameraIdentity) -> CameraIdentity {
        var out = a.modelIsCertain || !b.modelIsCertain ? a : b
        let other = a.modelIsCertain || !b.modelIsCertain ? b : a
        out.serial = out.serial ?? other.serial
        out.bodyKey = out.serial ?? out.bodyKey ?? other.bodyKey
        out.model = out.model ?? other.model
        return out
    }
}

enum CaptureDays {
    private static let samples = 5
    private static let bisectionBudget = 24

    static func build(_ units: [ClipUnit], _ reader: ClipReader) -> [CaptureDay] {
        var counts: [CalendarDay: (files: Int, source: DateSource)] = [:]
        for list in Dictionary(grouping: units, by: \.group).values {
            let sorted = list.sorted {
                ($0.primary.mtime, $0.primary.relPath) < ($1.primary.mtime, $1.primary.relPath)
            }
            var evidence: [Int: (CalendarDay, DateSource)] = [:]
            func look(_ i: Int) {
                guard evidence[i] == nil else { return }
                let f = reader.facts(sorted[i])
                if let d = f.day, let s = f.source { evidence[i] = (d, s) }
            }
            let picks = Sampling.indices(count: sorted.count, take: samples)
            picks.forEach(look)

            // Where two neighbouring samples name different days, narrow down the change.
            var gaps = Array(zip(picks, picks.dropFirst()))
            var budget = bisectionBudget
            while let (a, b) = gaps.popLast(), budget > 0 {
                guard b - a > 1, evidence[a]?.0 != evidence[b]?.0 else { continue }
                let mid = (a + b) / 2
                look(mid)
                budget -= 1
                gaps.append((a, mid))
                gaps.append((mid, b))
            }

            let known = evidence.keys.sorted()
            guard !known.isEmpty else { continue }
            var next = 0
            for (i, unit) in sorted.enumerated() {
                while next + 1 < known.count, abs(known[next + 1] - i) <= abs(known[next] - i) { next += 1 }
                guard let (day, source) = evidence[known[next]] else { continue }
                let current = counts[day]
                counts[day] = ((current?.files ?? 0) + unit.members.count, stronger(current?.source, source))
            }
        }
        return counts
            .map { CaptureDay(day: $0.key, fileCount: $0.value.files, source: $0.value.source) }
            .sorted { $0.day < $1.day }
    }

    private static func rank(_ s: DateSource) -> Int {
        switch s {
        case .cameraMetadata: 3
        case .fileName: 2
        case .containerUTC: 1
        case .fileModified: 0
        }
    }

    private static func stronger(_ a: DateSource?, _ b: DateSource) -> DateSource {
        guard let a else { return b }
        return rank(a) >= rank(b) ? a : b
    }
}

enum Reels {
    static func pick(_ units: [ClipUnit]) -> String? {
        var counts: [String: Int] = [:]
        for u in units where !u.isStill {
            if let reel = reel(u) { counts[reel, default: 0] += 1 }
        }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    private static func reel(_ unit: ClipUnit) -> String? {
        let parts = CardContext.components(unit.primary.relPath)
        for folder in parts.dropLast() {
            if folder.lowercased().hasSuffix(".rdm") {
                let name = String(folder.dropLast(4))
                let head = name.split(separator: "_").first.map(String.init) ?? name
                return captures(redReel, head) != nil ? head : name
            }
            if ClipName.isARRIReelFolder(folder) { return folder }
        }
        if let named = ClipName.reel(CardContext.stem(of: unit.primary.name)) { return named }
        return parts.dropLast().first { $0.uppercased().hasPrefix("REEL_") }
    }
    private static let redReel = regex("^[A-Z][0-9]{3}$")
}
