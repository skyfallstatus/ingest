// Learns how a working drive is organised from a listing of it. Pure: no filesystem access.
import Foundation

public struct ClientFolder: Hashable, Sendable {
    public var name: String             // spelling on the drive
    public var path: String             // drive-relative
    public var lastShoot: CalendarDay?
    public init(name: String, path: String, lastShoot: CalendarDay? = nil) {
        self.name = name; self.path = path; self.lastShoot = lastShoot
    }
}

public enum LayoutLearner {
    /// nil when the drive has no recognisable shoots: the app then offers presets.
    /// `entries` is a full listing of the drive, directories included.
    public static func learn(entries: [DriveEntry]) -> DriveSetup? {
        LayoutAnalysis(tree: DriveTree(entries: entries)).run()
    }

    /// Every client folder under this setup, most recently used first.
    public static func clients(in setup: DriveSetup, entries: [DriveEntry]) -> [ClientFolder] {
        guard let clientLevel = setup.path.firstIndex(of: .client) else { return [] }
        let tree = DriveTree(entries: entries)

        var parents: [Int32] = [DriveTree.root]
        for level in setup.path[..<clientLevel] { parents = expand(parents, level, tree) }

        var best: [String: (folder: ClientFolder, mtime: Int64)] = [:]
        for parent in parents {
            for id in tree.usefulChildren(of: parent) {
                let folder = tree[id]
                guard DateText.parse(folder.name) == nil, !LayoutAnalysis.isYear(folder.name) else { continue }
                var shootParents = [id]
                for level in setup.path[(clientLevel + 1)...] { shootParents = expand(shootParents, level, tree) }
                var last = latestShoot(under: shootParents, tree, style: setup.shootName)
                if last == nil {
                    // A client can keep a stray year folder even when the drive's layout has none.
                    let years = shootParents.flatMap { tree.usefulChildren(of: $0) }.filter { LayoutAnalysis.isYear(tree[$0].name) }
                    last = latestShoot(under: years, tree, style: setup.shootName)
                }
                // A folder with no shoots and no media is not a client: it is notes or admin.
                guard last != nil || (!folder.isCardRoot && (folder.mediaBytes > 0 || folder.projectFiles > 0)) else { continue }

                let candidate = ClientFolder(name: folder.name, path: tree.path(of: id), lastShoot: last)
                let key = LayoutNames.matchKey(folder.name)
                if let current = best[key], !isNewer(candidate.lastShoot, folder.newestMtime, than: current.folder.lastShoot, current.mtime) {
                    continue
                }
                best[key] = (candidate, folder.newestMtime)
            }
        }
        return best.values.sorted { a, b in
            if a.folder.lastShoot != b.folder.lastShoot { return isNewer(a.folder.lastShoot, a.mtime, than: b.folder.lastShoot, b.mtime) }
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.folder.name < b.folder.name
        }.map(\.folder)
    }

    private static func isNewer(_ a: CalendarDay?, _ aTime: Int64, than b: CalendarDay?, _ bTime: Int64) -> Bool {
        switch (a, b) {
        case let (a?, b?): return a == b ? aTime > bTime : a > b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return aTime > bTime
        }
    }

    private static func expand(_ parents: [Int32], _ level: PathLevel, _ tree: DriveTree) -> [Int32] {
        parents.flatMap { parent in
            tree.usefulChildren(of: parent).filter { id in
                switch level {
                case .year: return LayoutAnalysis.isYear(tree[id].name)
                case .literal(let name): return LayoutNames.matchKey(tree[id].name) == LayoutNames.matchKey(name)
                case .client: return true
                }
            }
        }
    }

    private static func latestShoot(under parents: [Int32], _ tree: DriveTree, style: ShootNameStyle) -> CalendarDay? {
        let dayFirst = !style.dateFormat.hasPrefix("MM")
        var last: CalendarDay?
        for parent in parents {
            for child in tree.usefulChildren(of: parent) {
                guard let name = DateText.parse(tree[child].name)?.resolved(dayFirst: dayFirst), !name.isMonthBucket,
                      name.position == style.position, tree.looksWorkedOn(child) else { continue }
                if last.map({ name.day > $0 }) ?? true { last = name.day }
            }
        }
        return last
    }
}

// MARK: - The analysis

struct LayoutAnalysis {
    let tree: DriveTree

    /// Fewer shoots than this is a coincidence, not a habit.
    private static let minimumShoots = 3
    /// One value this common at a path level makes that level a fixed name.
    private static let literalShare = 0.8
    /// A folder with a job is part of the layout from this share of shoots upward. Low on purpose: this app's own
    /// shoots drop folders a card has no use for, so a real Photo folder can be missing from most video shoots.
    private static let roleShare = 0.35
    /// A folder with no job has only habit going for it, so most shoots must have it.
    private static let plainShare = 0.5
    /// A folder inside an inner folder must be more regular than that to be worth creating every time.
    private static let nestedShare = 0.5

    private struct Shoot {
        var id: Int32
        var name: DateName
        var ancestors: [Int32]
        var shape: String           // one letter per level above the shoot: Y for a year, V for anything else
        var parent: Int32 { ancestors.last ?? DriveTree.root }
    }

    /// A folder that appears across shoots under names that mean the same thing.
    private final class Slot {
        let key: String
        var hint: NameHint?
        var spellings: [String: Int] = [:]
        var shoots = Set<Int>()
        var nodes: [Int32] = []
        var rankTotal = 0.0
        var occurrences = 0
        var video: UInt64 = 0, stills: UInt64 = 0, rawStills: UInt64 = 0, audio: UInt64 = 0
        var cardTrees = 0
        var nodesWithProjects = 0

        init(key: String) { self.key = key }
        var name: String { mostCommon(spellings) ?? key }
        var number: Int? { LayoutNames.splitNumber(name).number }
        var meanRank: Double { rankTotal / Double(max(occurrences, 1)) }
        var total: UInt64 { video + stills + audio }

        func absorb(_ other: Slot) {
            spellings.merge(other.spellings, uniquingKeysWith: +)
            shoots.formUnion(other.shoots)
            nodes += other.nodes
            rankTotal += other.rankTotal
            occurrences += other.occurrences
            video += other.video; stills += other.stills; rawStills += other.rawStills; audio += other.audio
            cardTrees += other.cardTrees
            nodesWithProjects += other.nodesWithProjects
        }
    }

    private struct KeptFolder {
        var slot: Slot
        var role: FolderRole
        var children: [InnerFolder]
    }

    func run() -> DriveSetup? {
        let shoots = recognisedShoots()
        guard shoots.count >= Self.minimumShoots else { return nil }
        let clusters = Dictionary(grouping: shoots, by: \.shape).sorted { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key
        }
        for (_, members) in clusters.prefix(8) {
            if let setup = layout(from: members, among: shoots) { return setup }
        }
        return nil
    }

    // MARK: Finding shoots

    private func recognisedShoots() -> [Shoot] {
        var dated: [(id: Int32, name: DateName)] = []
        var stack: [Int32] = [DriveTree.root]
        while let id = stack.popLast() {
            for child in tree.usefulChildren(of: id) {
                let folder = tree[child]
                if let name = DateText.parse(folder.name) {
                    // The first date on the way down wins, so a dated folder inside a shoot is never a shoot.
                    if name.isMonthBucket { stack.append(child) } else { dated.append((child, name)) }
                    continue
                }
                // `01 RUSHES` belongs inside a project, so dated folders under it are days, not shoots.
                let numbered = LayoutNames.splitNumber(folder.name).number != nil
                if numbered, LayoutNames.hint(for: folder.name) != nil { continue }
                stack.append(child)
            }
        }

        // Day and month order is settled once, for the whole drive, by the values that can only be one thing.
        var dayFirstEvidence = 0, monthFirstEvidence = 0
        for item in dated {
            guard let ambiguous = item.name.ambiguous else { continue }
            if ambiguous.first > 12 { dayFirstEvidence += 1 }
            if ambiguous.second > 12 { monthFirstEvidence += 1 }
        }
        let dayFirst = dayFirstEvidence >= monthFirstEvidence

        var shoots: [Shoot] = []
        shoots.reserveCapacity(dated.count)
        for item in dated {
            guard let name = item.name.resolved(dayFirst: dayFirst), tree.looksWorkedOn(item.id) else { continue }
            let ancestors = tree.ancestors(of: item.id)
            let shape = String(ancestors.map { Self.isYear(tree[$0].name) ? "Y" : "V" })
            shoots.append(Shoot(id: item.id, name: name, ancestors: ancestors, shape: shape))
        }
        return shoots
    }

    static func isYear(_ name: String) -> Bool {
        guard name.utf8.count == 4, name.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let year = Int(name) else { return false }
        return (1980...2049).contains(year)
    }

    // MARK: Reading one cluster

    private func layout(from cluster: [Shoot], among all: [Shoot]) -> DriveSetup? {
        guard let position = mostCommon(counts(cluster.map(\.name.position.rawValue))).flatMap(ShootNameStyle.Position.init) else { return nil }
        let dumps = dumpParents(in: all)
        var members = cluster.filter { $0.name.position == position && !dumps.contains($0.parent) }
        guard members.count >= Self.minimumShoots else { return nil }

        guard let path = pathLevels(for: &members), members.count >= Self.minimumShoots else { return nil }
        guard siblingsLookLikeShoots(members) else { return nil }

        let style = nameStyle(of: members, position: position)
        let slots = innerSlots(of: members)
        let footage = footageSlot(in: slots, shoots: members.count)
        let kept = keptFolders(slots: slots, footage: footage, shoots: members.count)

        var inner = kept.map { InnerFolder(name: $0.slot.name, role: $0.role, children: $0.children) }
        if footage == nil {
            // No shoot has a footage folder, so there is nothing to copy from. This is the plain default.
            let at = inner.firstIndex { $0.role == .project || $0.role == .exports } ?? inner.count
            inner.insert(InnerFolder(name: "Footage", role: .footage), at: at)
        }

        // Who follows the layout.
        let keptShoots = kept.map(\.slot.shoots)
        // A second home for footage means the shoot is organised differently. `Social Media` or `Camera Reports` is not that.
        let competing = slots.filter { slot in
            footage != nil && !kept.contains { $0.slot === slot } && LayoutNames.isFootageName(slot.name)
        }
        var following: [Shoot] = []
        var thin: [Shoot] = []
        var competed = Set<Int>()
        for slot in competing { competed.formUnion(slot.shoots) }
        for (index, shoot) in members.enumerated() {
            let held = keptShoots.filter { $0.contains(index) }.count
            if held * 2 < keptShoots.count {
                thin.append(shoot)
            } else if !competed.contains(index) {
                following.append(shoot)
            }
        }
        guard !following.isEmpty else { return nil }

        // Everything else on the drive that reads as a shoot, in this drive's date habit, counts as found.
        let family = DateText.family(of: style.dateFormat)
        let memberIDs = Set(members.map(\.id))
        let elsewhere = all.filter { shoot in
            guard !memberIDs.contains(shoot.id), !dumps.contains(shoot.parent), shoot.name.position == position else { return false }
            return DateText.family(of: shoot.name.format) == family || shoot.shape == members[0].shape
        }

        let exception = exceptionSentence(members: members, following: following, thin: thin, elsewhere: elsewhere,
                                          competing: competing, slots: slots, kept: kept)
        let newest = following.max { $0.name.day != $1.name.day ? $0.name.day < $1.name.day : $0.id < $1.id }
        let stats = LearnedStats(
            foldersRead: tree.folders.count - 1,
            shootsFound: members.count + elsewhere.count,
            shootsFollowing: following.count,
            exception: exception,
            mostRecentClient: newest.flatMap { shoot in
                path.firstIndex(of: .client).map { tree[shoot.ancestors[$0]].name }
            },
            mostRecentDay: newest?.name.day
        )
        let footageStyle = footage.map(footageStyle(of:)) ?? .perCamera
        return DriveSetup(path: path, shootName: style, inner: inner, footage: footageStyle, learned: stats)
    }

    /// Folders where a dated child is the exception: downloads, dumps, archives. Their children are not shoots.
    private func dumpParents(in shoots: [Shoot]) -> Set<Int32> {
        var dated: [Int32: Int] = [:]
        for shoot in shoots { dated[shoot.parent, default: 0] += 1 }
        var dumps = Set<Int32>()
        for (parent, count) in dated {
            let children = tree.usefulChildren(of: parent).count
            if children >= 20, Double(count) / Double(children) < 0.1 { dumps.insert(parent) }
        }
        return dumps
    }

    /// One shape, one meaning per level. Shoots that do not fit the fixed levels drop out.
    private func pathLevels(for members: inout [Shoot]) -> [PathLevel]? {
        let shape = Array(members[0].shape)
        var levels: [PathLevel?] = Array(repeating: nil, count: shape.count)
        var varying: [(level: Int, distinct: Int)] = []
        var literals: [Int: String] = [:]

        for level in shape.indices {
            if shape[level] == "Y" { levels[level] = .year; continue }
            var byKey: [String: Int] = [:]
            var spellings: [String: [String: Int]] = [:]
            for shoot in members {
                let name = tree[shoot.ancestors[level]].name
                let key = LayoutNames.matchKey(name)
                byKey[key, default: 0] += 1
                spellings[key, default: [:]][name, default: 0] += 1
            }
            guard let top = mostCommon(byKey), let count = byKey[top], let spelling = spellings[top].flatMap(mostCommon) else { continue }
            literals[level] = spelling      // kept for a varying level too, in case another turns out to be the client
            if Double(count) / Double(members.count) < Self.literalShare { varying.append((level, byKey.count)) }
        }

        // The contract has one client per path. If two levels vary, the busier one is the client.
        let client = varying.max { $0.distinct != $1.distinct ? $0.distinct < $1.distinct : $0.level > $1.level }?.level
        for level in shape.indices where levels[level] == nil {
            if level == client {
                levels[level] = .client
            } else if let literal = literals[level] {
                levels[level] = .literal(literal)
            }
        }
        let fixed = literals.filter { levels[$0.key] == .literal($0.value) }.mapValues(LayoutNames.matchKey)
        if !fixed.isEmpty {
            members.removeAll { shoot in
                fixed.contains { LayoutNames.matchKey(tree[shoot.ancestors[$0.key]].name) != $0.value }
            }
        }
        return levels.compactMap { $0 }
    }

    /// A habit should show among its neighbours. One folder of mostly undated things is a dump with a few lucky names.
    private func siblingsLookLikeShoots(_ members: [Shoot]) -> Bool {
        let parents = Set(members.map(\.parent))
        let siblings = parents.reduce(0) { $0 + tree.usefulChildren(of: $1).count }
        guard siblings > 0 else { return false }
        let share = Double(members.count) / Double(siblings)
        return share >= (parents.count == 1 ? 0.3 : 0.15)
    }

    private func nameStyle(of members: [Shoot], position: ShootNameStyle.Position) -> ShootNameStyle {
        let family = mostCommon(counts(members.map { DateText.family(of: $0.name.format) })) ?? "dd.MM.yy"
        let inFamily = members.filter { DateText.family(of: $0.name.format) == family }
        let fullDays = inFamily.filter { !$0.name.monthOnly }.map(\.name.format)
        let format = mostCommon(counts(fullDays)) ?? mostCommon(counts(inFamily.map(\.name.format))) ?? family
        let separators = members.filter { !$0.name.text.isEmpty }.map(\.name.separator)
        let uppercase = (LayoutNames.upperShare(members.map(\.name.text)) ?? 0) >= 0.8
        return ShootNameStyle(dateFormat: format, position: position, separator: mostCommon(counts(separators)) ?? " ",
                              uppercase: uppercase)
    }

    // MARK: Inside the shoots

    private func innerSlots(of members: [Shoot]) -> [Slot] {
        merged(slots(under: members.map(\.id))).sorted { a, b in
            a.shoots.count != b.shoots.count ? a.shoots.count > b.shoots.count : a.key < b.key
        }
    }

    /// The structural folders under each parent, grouped by what they are. `Slot.shoots` holds indexes into `parents`.
    private func slots(under parents: [Int32]) -> [Slot] {
        var byKey: [String: Slot] = [:]
        for (index, parent) in parents.enumerated() {
            let children = tree.usefulChildren(of: parent).filter(isStructural)
            let span = Double(max(children.count - 1, 1))
            for (rank, child) in children.enumerated() {
                let key = LayoutNames.slotKey(tree[child].name)
                let slot = byKey[key] ?? Slot(key: key)
                byKey[key] = slot
                add(child, to: slot, shoot: index, rank: Double(rank) / span)
            }
        }
        return Array(byKey.values)
    }

    /// Dated, card and camera folders inside a shoot are that shoot's content, not its structure.
    private func isStructural(_ id: Int32) -> Bool {
        let folder = tree[id]
        if folder.isCardRoot || DateText.parse(folder.name) != nil { return false }
        return LayoutNames.cardName(folder.name) == nil && !LayoutNames.looksLikeCamera(folder.name)
    }

    private func add(_ id: Int32, to slot: Slot, shoot: Int, rank: Double) {
        let folder = tree[id]
        slot.spellings[folder.name, default: 0] += 1
        slot.hint = slot.hint ?? LayoutNames.hint(for: folder.name)
        slot.shoots.insert(shoot)
        slot.nodes.append(id)
        slot.rankTotal += rank
        slot.occurrences += 1
        slot.video += folder.videoBytes
        slot.stills += folder.stillBytes
        slot.rawStills += folder.rawStillBytes
        slot.audio += folder.audioBytes
        slot.cardTrees += Int(folder.cardTrees)
        if folder.projectFiles > 0 { slot.nodesWithProjects += 1 }
    }

    /// `01 ORIGINALS` and `01 RUSHES` are one folder under two names: numbered, same job, never side by side.
    /// `Footage` next to `Video` stays apart, because those are two folders.
    private func merged(_ slots: [Slot]) -> [Slot] {
        let ordered = slots.sorted { a, b in
            a.shoots.count != b.shoots.count ? a.shoots.count > b.shoots.count : a.key < b.key
        }
        var survivors: [Slot] = []
        for slot in ordered {
            let host = survivors.first { host in
                guard let hint = slot.hint, host.hint == hint, slot.number != nil, host.number != nil else { return false }
                let overlap = host.shoots.intersection(slot.shoots).count
                return Double(overlap) <= 0.1 * Double(slot.shoots.count)
            }
            if let host { host.absorb(slot) } else { survivors.append(slot) }
        }
        return survivors
    }

    /// Content first. Card trees and camera bytes decide; a name only tips a close call.
    private func footageSlot(in slots: [Slot], shoots: Int) -> Slot? {
        let floor = Self.needed(0.1, of: shoots)
        let considered = slots.filter { $0.shoots.count >= floor }
        let totalVideo = considered.reduce(UInt64(0)) { $0 + $1.video }
        if totalVideo > 0 {
            var best: (slot: Slot, score: Double)?
            for slot in considered where slot.video > 0 || slot.cardTrees > 0 {
                var score = Double(slot.video) / Double(totalVideo)
                score += min(Double(slot.cardTrees) / Double(slot.shoots.count), 1) * 0.5
                switch slot.hint {
                case .footage: score += 0.25
                case nil: break
                default: score -= 0.4
                }
                if best.map({ score > $0.score }) ?? true { best = (slot, score) }
            }
            if let best, best.score > 0 { return best.slot }
        }
        return slots.first { $0.hint == .footage }
    }

    /// How many of `count` make a share of them, and never fewer than two: one folder is not a habit.
    private static func needed(_ share: Double, of count: Int) -> Int { max(2, Int((Double(count) * share).rounded(.up))) }

    private func keptFolders(slots: [Slot], footage: Slot?, shoots: Int) -> [KeptFolder] {
        let chosen = slots.filter { slot in
            slot === footage || slot.shoots.count >= Self.needed(role(of: slot) == .plain ? Self.plainShare : Self.roleShare, of: shoots)
        }
        let numberedOnly = chosen.allSatisfy { $0.number != nil }
        let ordered = chosen.sorted { a, b in
            if numberedOnly, a.number != b.number { return (a.number ?? 0) < (b.number ?? 0) }
            return a.meanRank != b.meanRank ? a.meanRank < b.meanRank : a.key < b.key
        }
        return ordered.map { slot in
            let role = slot === footage ? FolderRole.footage : role(of: slot)
            return KeptFolder(slot: slot, role: role, children: role == .footage ? [] : nestedFolders(in: slot, parentRole: role))
        }
    }

    /// Content first, except that exports look like anything: only their name gives them away.
    private func role(of slot: Slot) -> FolderRole {
        if slot.occurrences > 0, slot.nodesWithProjects * 2 >= slot.occurrences, slot.hint != .exports { return .project }
        if slot.hint == .exports { return .exports }
        let total = max(slot.total, 1)
        let stillShare = Double(slot.stills) / Double(total), audioShare = Double(slot.audio) / Double(total)
        if slot.total > 0 {
            if stillShare >= 0.8, slot.hint != .photo { return .photo }
            if audioShare >= 0.8, slot.hint != .audio { return .audio }
        }
        switch slot.hint {
        case .photo: return .photo
        case .audio: return .audio
        case .project: return .project
        default: return .plain
        }
    }

    private func nestedFolders(in parent: Slot, parentRole: FolderRole) -> [InnerFolder] {
        let minimum = Self.needed(Self.nestedShare, of: parent.nodes.count)
        return slots(under: parent.nodes).filter { $0.shoots.count >= minimum }
            .sorted { $0.meanRank != $1.meanRank ? $0.meanRank < $1.meanRank : $0.key < $1.key }
            .map { slot in
                var role = FolderRole.plain
                if parentRole == .photo {
                    let rawShare = Double(slot.rawStills) / Double(max(slot.stills, 1))
                    if LayoutNames.looksLikeRaw(slot.name) || rawShare >= 0.6 {
                        role = .photoRaw
                    } else if slot.hint == .exports {
                        role = .photoExports
                    }
                }
                return InnerFolder(name: slot.name, role: role)
            }
    }

    private func footageStyle(of slot: Slot) -> FootageStyle {
        var cardVotes = 0, cameraVotes = 0
        var prefixes: [String: Int] = [:]
        for node in slot.nodes {
            for child in tree.usefulChildren(of: node) {
                let folder = tree[child]
                if let card = LayoutNames.cardName(folder.name) {
                    cardVotes += 1
                    prefixes[card.prefix, default: 0] += 1
                } else if LayoutNames.looksLikeCamera(folder.name) {
                    cameraVotes += 1
                } else if folder.cardTrees > 0 {
                    cardVotes += 1
                }
            }
        }
        guard cardVotes > cameraVotes else { return .perCamera }
        return .perCard(prefix: mostCommon(prefixes) ?? "")
    }

    // MARK: Saying what differs

    private func exceptionSentence(members: [Shoot], following: [Shoot], thin: [Shoot], elsewhere: [Shoot],
                                   competing: [Slot], slots: [Slot], kept: [KeptFolder]) -> String? {
        struct Deviation { var shoots: [Shoot]; var singular: String; var plural: String }
        func extra(_ slot: Slot) -> Deviation {
            let name = slot.name
            return Deviation(shoots: slot.shoots.sorted().map { members[$0] },
                             singular: "also has a folder called \(name)", plural: "also have a folder called \(name)")
        }

        // Reasons a shoot does not follow come first, because that is the gap the headline shows.
        var reasons = competing.map(extra)
        if !elsewhere.isEmpty {
            reasons.append(Deviation(shoots: elsewhere, singular: "sits elsewhere on the drive", plural: "sit elsewhere on the drive"))
        }
        if !thin.isEmpty {
            reasons.append(Deviation(shoots: thin, singular: "is missing most of these folders", plural: "are missing most of these folders"))
        }
        if reasons.isEmpty {
            reasons = slots.filter { slot in slot.shoots.count >= 2 && !kept.contains { $0.slot === slot } }.map(extra)
        }
        guard let top = reasons.max(by: { $0.shoots.count != $1.shoots.count ? $0.shoots.count < $1.shoots.count : $0.singular > $1.singular }) else {
            return nil
        }

        let days = following.map(\.name.day).sorted()
        let median = days[days.count / 2]
        let older = top.shoots.allSatisfy { $0.name.day < median }
        let count = top.shoots.count
        let noun = (older ? "older " : "") + (count == 1 ? "shoot" : "shoots")
        return count == 1
            ? "1 \(noun) \(top.singular). Nothing in it moves."
            : "\(count) \(noun) \(top.plural). Nothing in them moves."
    }
}

// MARK: - Counting helpers

private func counts(_ values: [String]) -> [String: Int] {
    var out: [String: Int] = [:]
    for value in values { out[value, default: 0] += 1 }
    return out
}

/// The most frequent key. Ties break on the key, so the same drive always reads the same way.
private func mostCommon(_ counts: [String: Int]) -> String? {
    counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
}
