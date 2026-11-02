// Turns a setup and a New Shoot request into folders. Pure: it asks `existing` about the drive and touches nothing.
import Foundation

public struct Preset: Hashable, Sendable {
    public var name: String
    public var setup: DriveSetup
}

public enum ShootPlanner {
    /// A card's folder name, short enough to take a number or a code after it and keep it.
    public static func cardLabel(_ name: String) -> String { SafeName.cap(name, maxBytes: SafeName.maxBytes - 40) }

    private static let pathJoiner = " \u{203A} "

    // MARK: Names

    public static func shootFolderName(setup: DriveSetup, shootName: String, day: CalendarDay) -> String {
        let style = setup.shootName
        let date = DateText.format(day, pattern: style.dateFormat)
        var name = style.uppercase ? shootName.uppercased() : shootName
        if style.separator == "_" { name = name.replacingOccurrences(of: " ", with: "_") }
        // The date is what sorts the folder, so a long name gives way before it does.
        let room = SafeName.maxBytes - date.utf8.count - style.separator.utf8.count
        name = SafeName.clean(name, maxBytes: max(room, 1))
        if name.isEmpty { return SafeName.clean(date) }
        let joined = style.position == .prefix ? date + style.separator + name : name + style.separator + date
        return SafeName.clean(joined)
    }

    // MARK: Clients

    /// The client folder that is this name, ignoring case, accents, whitespace and Unicode form.
    private static func sameClient(as name: String, in clients: [ClientFolder]) -> ClientFolder? {
        let key = LayoutNames.matchKey(name)
        guard !key.isEmpty else { return nil }
        return clients.first { LayoutNames.matchKey($0.name) == key }
    }

    /// A folder that is probably what they meant but is not the same name: "Lantern Bakery" for
    /// "Lantern Bakery Co.". nil when the name matches exactly. The plan never merges these on its own.
    public static func nearMatch(for name: String, in clients: [ClientFolder]) -> ClientFolder? {
        let key = LayoutNames.matchKey(name)
        guard key.utf8.count >= 3, sameClient(as: name, in: clients) == nil else { return nil }
        let never = CalendarDay(year: 0, month: 0, day: 0)
        let close = clients.compactMap { c in closeness(key, LayoutNames.matchKey(c.name)).map { (client: c, distance: $0) } }
        return close.min { a, b in
            a.distance != b.distance ? a.distance < b.distance : (a.client.lastShoot ?? never) > (b.client.lastShoot ?? never)
        }?.client
    }

    /// Lower is closer, nil is unrelated.
    private static func closeness(_ a: String, _ b: String) -> Int? {
        let shorter = a.utf8.count <= b.utf8.count ? a : b
        let longer = a.utf8.count <= b.utf8.count ? b : a
        if longer.hasPrefix(shorter + " ") || longer.hasSuffix(" " + shorter) { return 1 }
        let letters: (String) -> String = { String($0.filter { $0.isLetter || $0.isNumber }) }
        if letters(a) == letters(b) { return 0 }
        let limit = shorter.count >= 6 ? 2 : (shorter.count >= 4 ? 1 : 0)
        guard limit > 0, longer.count - shorter.count <= limit else { return nil }
        let distance = editDistance(Array(a), Array(b))
        return distance <= limit ? distance + 1 : nil
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func newClientName(_ typed: String, clients: [ClientFolder]) -> String {
        let driveIsUppercase = (LayoutNames.upperShare(clients.map(\.name)) ?? 0) >= 0.8
        let cleaned = SafeName.clean(driveIsUppercase ? typed.uppercased() : typed)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    // MARK: The plan

    /// Pure. `existing` returns the on-drive spelling of a drive-relative folder, or nil if it is absent.
    public static func plan(setup: DriveSetup, request: ShootRequest, clients: [ClientFolder],
                            existing: (String) -> String?) -> ShootPlan {
        let matchedClient = sameClient(as: request.client, in: clients)
        let clientLevel = setup.path.firstIndex(of: .client)
        var knownClientPath = matchedClient.map { $0.path.split(separator: "/").map(String.init) } ?? []
        if knownClientPath.count != (clientLevel ?? -1) + 1 { knownClientPath = [] }

        var rows: [PlanRow] = []
        var pills: [PlanPill] = []
        var toCreate: [String] = []

        func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

        /// `parent` is nil when the parent is itself new, so nothing below it can exist.
        func locate(_ wanted: String, in parent: String?) -> (name: String, exists: Bool) {
            guard let parent else { return (wanted, false) }
            if let found = existing(join(parent, wanted)) {
                let spelling = found.split(separator: "/").last.map(String.init) ?? found
                return (spelling, true)
            }
            return (wanted, false)
        }

        // Levels above the shoot.
        var levels: [(name: String, exists: Bool)] = []
        var parentPath = ""
        var parentExists = true
        var pathSoFar: [String] = []
        var clientExists = false
        var existingClientName: String?
        for (index, level) in setup.path.enumerated() {
            let wanted: String
            let isClient: Bool
            switch level {
            case .year: wanted = String(request.day.year); isClient = false
            case .literal(let name): wanted = name; isClient = false
            case .client:
                wanted = matchedClient?.name ?? newClientName(request.client, clients: clients)
                isClient = true
            }
            var found = locate(wanted, in: parentExists ? parentPath : nil)
            // The client list is itself evidence of what is on the drive.
            if !found.exists, index < knownClientPath.count,
               zip(knownClientPath.prefix(index), pathSoFar).allSatisfy({ LayoutNames.matchKey($0) == LayoutNames.matchKey($1) }),
               LayoutNames.matchKey(knownClientPath[index]) == LayoutNames.matchKey(wanted) {
                found = (knownClientPath[index], true)
            }
            if isClient {
                clientExists = found.exists
                existingClientName = found.exists ? found.name : matchedClient?.name
            }
            let changes: Bool
            if case .literal = level { changes = false } else { changes = true }
            pills.append(PlanPill(label: found.name, depth: index, changesEachShoot: changes))
            levels.append(found)
            pathSoFar.append(found.name)
            parentPath = join(parentPath, found.name)
            parentExists = found.exists
            if !found.exists { toCreate.append(parentPath) }
        }

        // The part already on the drive reads as one line.
        let settled = levels.prefix { $0.exists }
        var rowDepth = 0
        if !settled.isEmpty {
            rows.append(PlanRow(name: settled.map(\.name).joined(separator: pathJoiner), depth: 0, isNew: false, receivesFiles: false))
            rowDepth = 1
        }
        for level in levels.dropFirst(settled.count) {
            rows.append(PlanRow(name: level.name, depth: rowDepth, isNew: true, receivesFiles: false))
            rowDepth += 1
        }

        // The shoot.
        let shoot = locate(shootFolderName(setup: setup, shootName: request.shootName, day: request.day),
                           in: parentExists ? parentPath : nil)
        let shootPath = join(parentPath, shoot.name)
        rows.append(PlanRow(name: shoot.name, depth: rowDepth, isNew: !shoot.exists, receivesFiles: false))
        pills.append(PlanPill(label: shoot.name, depth: setup.path.count, changesEachShoot: true))
        if !shoot.exists { toCreate.append(shootPath) }

        /// Adds a folder's row, pill and creation. Returns where it ended up.
        @discardableResult
        func add(_ wanted: String, under parent: String, parentExists: Bool, rowDepth: Int, pillDepth: Int?)
            -> (path: String, exists: Bool, row: Int) {
            let found = locate(wanted, in: parentExists ? parent : nil)
            let path = join(parent, found.name)
            rows.append(PlanRow(name: found.name, depth: rowDepth, isNew: !found.exists, receivesFiles: false))
            if let pillDepth { pills.append(PlanPill(label: found.name, depth: pillDepth, changesEachShoot: false)) }
            if !found.exists { toCreate.append(path) }
            return (path, found.exists, rows.count - 1)
        }

        /// The folder a card lands in. Cards never share a folder, even when the camera reported no reel.
        /// `cardLabel` leaves the room a number needs, so a long reel name can't cut its own number off.
        func cardFolder(under parent: String, parentExists: Bool, prefix: String) -> String {
            let reelText = SafeName.clean(request.cardFolder)
            if !reelText.isEmpty {
                let alreadyPrefixed = !prefix.isEmpty && reelText.lowercased().hasPrefix(prefix.lowercased())
                return SafeName.clean(alreadyPrefixed ? reelText : prefix + reelText)
            }
            func candidate(_ number: Int) -> String {
                let label = number < 10 ? "0\(number)" : String(number)
                return SafeName.clean(prefix.isEmpty ? "Card \(label)" : prefix + label)
            }
            guard parentExists else { return candidate(1) }
            let free = (1...999).first { existing(join(parent, candidate($0))) == nil }
            return candidate(free ?? 1000)
        }

        /// Places a card under a folder that is listed in the plan. Rows only show it for per-card footage.
        func placeCard(under parent: (path: String, exists: Bool), prefix: String) -> String {
            let found = locate(cardFolder(under: parent.path, parentExists: parent.exists, prefix: prefix),
                               in: parent.exists ? parent.path : nil)
            let path = join(parent.path, found.name)
            if !found.exists { toCreate.append(path) }
            return path
        }

        // What this card has no use for.
        let photoFolders = setup.inner.filter(isPhoto)
        let audioFolders = setup.inner.filter { $0.role == .audio }
        let footageFolders = setup.inner.filter { $0.role == .footage }
        let stillsHaveAHome = !request.hasStills || !photoFolders.isEmpty
        let audioHasAHome = !request.hasAudio || !audioFolders.isEmpty
        let omitFootage = !request.hasVideo && (request.hasStills || request.hasAudio) && stillsHaveAHome && audioHasAHome

        let cardPrefix: String
        switch setup.footage {
        case .perCamera: cardPrefix = ""
        case .perCard(let prefix): cardPrefix = setup.shootName.uppercase ? prefix.uppercased() : prefix
        }
        let cameraName = SafeName.clean(request.cameraFolder)

        var skipped: [String] = []
        var footagePath: String?
        var stillsTarget: (path: String, exists: Bool, row: Int)?
        var stillsAreRaw = false
        var audioTarget: (path: String, exists: Bool, row: Int)?
        var footageRow: Int?

        let innerDepth = rowDepth + 1
        let innerPill = setup.path.count + 1
        for folder in setup.inner {
            if isPhoto(folder), !request.hasStills { skipped.append(folder.name); continue }
            if folder.role == .audio, !request.hasAudio { skipped.append(folder.name); continue }
            if folder.role == .footage, omitFootage { skipped.append(folder.name); continue }

            let placed = add(folder.name, under: shootPath, parentExists: shoot.exists, rowDepth: innerDepth, pillDepth: innerPill)
            if folder.role == .audio, audioTarget == nil { audioTarget = placed }
            if isPhoto(folder), stillsTarget == nil || (folder.role == .photoRaw && !stillsAreRaw) {
                stillsTarget = placed
                stillsAreRaw = folder.role == .photoRaw
            }

            if folder.role == .footage, footagePath == nil {
                switch setup.footage {
                case .perCamera:
                    if cameraName.isEmpty {
                        footageRow = placed.row
                        footagePath = placeCard(under: (placed.path, placed.exists), prefix: "")
                    } else {
                        let camera = add(cameraName, under: placed.path, parentExists: placed.exists,
                                         rowDepth: innerDepth + 1, pillDepth: innerPill + 1)
                        footageRow = camera.row
                        footagePath = placeCard(under: (camera.path, camera.exists), prefix: "")
                    }
                case .perCard:
                    let name = cardFolder(under: placed.path, parentExists: placed.exists, prefix: cardPrefix)
                    let card = add(name, under: placed.path, parentExists: placed.exists, rowDepth: innerDepth + 1, pillDepth: nil)
                    footageRow = card.row
                    footagePath = card.path
                }
            } else {
                for child in folder.children {
                    let nested = add(child.name, under: placed.path, parentExists: placed.exists,
                                     rowDepth: innerDepth + 1, pillDepth: innerPill + 1)
                    if child.role == .photoRaw, isPhoto(folder), !stillsAreRaw {
                        stillsTarget = nested
                        stillsAreRaw = true
                    }
                }
            }
        }

        // Stills and audio land after the folder walk, so every parent is already on the list.
        var stillsPath: String?
        if let target = stillsTarget {
            stillsPath = placeCard(under: (target.path, target.exists), prefix: cardPrefix)
            rows[target.row].receivesFiles = true
        }
        var audioPath: String?
        if let target = audioTarget {
            audioPath = placeCard(under: (target.path, target.exists), prefix: cardPrefix)
            rows[target.row].receivesFiles = true
        }
        if footagePath == nil, footageFolders.isEmpty, !omitFootage {
            // A hand-made setup with no footage folder still keeps each card apart.
            footagePath = placeCard(under: (shootPath, shoot.exists), prefix: cardPrefix)
        }
        if let footageRow { rows[footageRow].receivesFiles = true }

        return ShootPlan(
            rows: rows,
            shootPath: shootPath,
            footagePath: footagePath ?? stillsPath ?? audioPath ?? shootPath,
            stillsPath: stillsPath,
            audioPath: audioPath,
            foldersToCreate: toCreate,
            skippedNote: skippedNote(skipped, request: request),
            clientExists: clientExists,
            existingClientName: existingClientName,
            pills: pills
        )
    }

    private static func isPhoto(_ folder: InnerFolder) -> Bool {
        folder.role == .photo || folder.role == .photoRaw || folder.role == .photoExports
    }

    private static func skippedNote(_ skipped: [String], request: ShootRequest) -> String? {
        guard !skipped.isEmpty else { return nil }
        var kinds: [String] = []
        if request.hasVideo { kinds.append("video") }
        if request.hasStills { kinds.append("photos") }
        if request.hasAudio { kinds.append("audio") }
        let what: String
        switch kinds.count {
        case 0: what = "no media found"
        case 1: what = "only \(kinds[0]) here"
        default: what = "only \(kinds[0]) and \(kinds[1]) here"
        }
        return "No \(skipped.joined(separator: " or ")) folder: \(what)."
    }

    // MARK: Presets

    public static func presets() -> [Preset] {
        let inner = [
            InnerFolder(name: "Photo", role: .photo, children: [
                InnerFolder(name: "RAW", role: .photoRaw),
                InnerFolder(name: "Exports", role: .photoExports),
            ]),
            InnerFolder(name: "Footage", role: .footage),
            InnerFolder(name: "Project", role: .project),
        ]
        let sortable = ShootNameStyle(dateFormat: "yyyy-MM-dd")
        let dayFirst = ShootNameStyle(dateFormat: "dd.MM.yy")
        func preset(_ name: String, _ path: [PathLevel], _ style: ShootNameStyle) -> Preset {
            Preset(name: name, setup: DriveSetup(path: path, shootName: style, inner: inner, footage: .perCamera))
        }
        return [
            preset("Client \u{203A} Year \u{203A} Date Shoot", [.client, .year], sortable),
            preset("Year \u{203A} Client \u{203A} Date Shoot", [.year, .client], sortable),
            preset("Year \u{203A} Paid work \u{203A} Client \u{203A} Date Shoot", [.year, .literal("Paid work"), .client], dayFirst),
            preset("Date Shoot at the top", [], dayFirst),
        ]
    }
}
