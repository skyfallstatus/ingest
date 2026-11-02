import Foundation
import Testing
@testable import IngestCore

@Suite("Shoot planner")
struct LayoutPlannerTests {
    private let tidemark = ClientFolder(name: "Tidemark Rowing Club", path: "2026/Paid work/Tidemark Rowing Club",
                                      lastShoot: CalendarDay(year: 2026, month: 10, day: 19))
    private let drive = lookup(["2026/Paid work/Tidemark Rowing Club/19.10.26 Pool/Footage/FX3"])
    private let regattaDay = CalendarDay(year: 2026, month: 10, day: 23)

    private func request(client: String = "Tidemark Rowing Club", shoot: String = "Regatta day", camera: String = "FX3",
                         card: String = "A082", video: Bool = true, stills: Bool = false, audio: Bool = false) -> ShootRequest {
        ShootRequest(client: client, shootName: shoot, day: regattaDay, cameraFolder: camera, cardFolder: card,
                     hasVideo: video, hasStills: stills, hasAudio: audio)
    }

    @Test("Pills, rows and note")
    func samplePlan() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(), clients: [tidemark], existing: drive)
        #expect(plan.pills == [
            PlanPill(label: "2026", depth: 0, changesEachShoot: true),
            PlanPill(label: "Paid work", depth: 1, changesEachShoot: false),
            PlanPill(label: "Tidemark Rowing Club", depth: 2, changesEachShoot: true),
            PlanPill(label: "23.10.26 Regatta day", depth: 3, changesEachShoot: true),
            PlanPill(label: "Footage", depth: 4, changesEachShoot: false),
            PlanPill(label: "FX3", depth: 5, changesEachShoot: false),
            PlanPill(label: "Project", depth: 4, changesEachShoot: false),
        ])
        #expect(plan.rows == [
            PlanRow(name: "2026 \u{203A} Paid work \u{203A} Tidemark Rowing Club", depth: 0, isNew: false, receivesFiles: false),
            PlanRow(name: "23.10.26 Regatta day", depth: 1, isNew: true, receivesFiles: false),
            PlanRow(name: "Footage", depth: 2, isNew: true, receivesFiles: false),
            PlanRow(name: "FX3", depth: 3, isNew: true, receivesFiles: true),
            PlanRow(name: "Project", depth: 2, isNew: true, receivesFiles: false),
        ])
        #expect(plan.skippedNote == "No Photo folder: only video here.")
        let shoot = "2026/Paid work/Tidemark Rowing Club/23.10.26 Regatta day"
        #expect(plan.shootPath == shoot)
        #expect(plan.footagePath == "\(shoot)/Footage/FX3/A082")
        #expect(plan.stillsPath == nil)
        #expect(plan.audioPath == nil)
        #expect(plan.clientExists)
        #expect(plan.existingClientName == "Tidemark Rowing Club")
        #expect(plan.foldersToCreate == [shoot, "\(shoot)/Footage", "\(shoot)/Footage/FX3", "\(shoot)/Footage/FX3/A082", "\(shoot)/Project"])
    }

    @Test("Per-card footage: the card is a row, not a pill")
    func perCard() {
        let setup = DriveSetup(
            path: [.client],
            shootName: ShootNameStyle(dateFormat: "yyyy-MM-dd", uppercase: true),
            inner: [
                InnerFolder(name: "01 ORIGINALS", role: .footage), InnerFolder(name: "02 ASSETS", role: .plain),
                InnerFolder(name: "03 PREMIERE", role: .project), InnerFolder(name: "04 EXPORTS", role: .exports),
            ],
            footage: .perCard(prefix: "Card ")
        )
        let plan = ShootPlanner.plan(setup: setup, request: request(client: "NORTHGATE", shoot: "Jane Doe"),
                                     clients: [ClientFolder(name: "NORTHGATE", path: "NORTHGATE")], existing: lookup(["NORTHGATE"]))
        let shoot = "NORTHGATE/2026-10-23 JANE DOE"
        #expect(plan.footagePath == "\(shoot)/01 ORIGINALS/CARD A082")
        #expect(plan.rows.map(\.name) == ["NORTHGATE", "2026-10-23 JANE DOE", "01 ORIGINALS", "CARD A082", "02 ASSETS", "03 PREMIERE", "04 EXPORTS"])
        #expect(plan.rows[3].receivesFiles)
        #expect(plan.rows.filter(\.receivesFiles).count == 1)
        #expect(!plan.pills.contains { $0.label.contains("A082") })
        #expect(plan.foldersToCreate.contains("\(shoot)/01 ORIGINALS/CARD A082"))
        #expect(plan.skippedNote == nil)
    }

    @Test("A card that already carries the prefix keeps one")
    func prefixOnce() {
        var setup = sampleSetup()
        setup.footage = .perCard(prefix: "CARD ")
        let plan = ShootPlanner.plan(setup: setup, request: request(card: "CARD A082"), clients: [tidemark], existing: drive)
        #expect(plan.footagePath.hasSuffix("/Footage/CARD A082"))
    }

    @Test("Photos only: no Footage, stills go to RAW in their own folder")
    func photosOnly() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(card: "100MSDCF", video: false, stills: true),
                                     clients: [tidemark], existing: drive)
        let shoot = "2026/Paid work/Tidemark Rowing Club/23.10.26 Regatta day"
        #expect(plan.skippedNote == "No Footage folder: only photos here.")
        #expect(plan.stillsPath == "\(shoot)/Photo/RAW/100MSDCF")
        #expect(plan.footagePath == plan.stillsPath)
        #expect(plan.rows.map(\.name) == ["2026 \u{203A} Paid work \u{203A} Tidemark Rowing Club", "23.10.26 Regatta day", "Photo", "RAW", "Exports", "Project"])
        #expect(plan.rows.first { $0.name == "RAW" }?.receivesFiles == true)
        #expect(plan.foldersToCreate.last == "\(shoot)/Photo/RAW/100MSDCF")
    }

    @Test("Stills fall back to the photo folder when it has no RAW")
    func stillsWithoutRaw() {
        var setup = sampleSetup()
        setup.inner[0].children = []
        let plan = ShootPlanner.plan(setup: setup, request: request(stills: true), clients: [tidemark], existing: drive)
        #expect(plan.stillsPath?.hasSuffix("/23.10.26 Regatta day/Photo/A082") == true)
    }

    @Test("A top-level RAW folder wins over a plain Photo folder")
    func topLevelRaw() {
        var setup = sampleSetup()
        setup.inner = [InnerFolder(name: "Selects", role: .photo), InnerFolder(name: "RAW", role: .photoRaw),
                       InnerFolder(name: "Footage", role: .footage)]
        let plan = ShootPlanner.plan(setup: setup, request: request(stills: true), clients: [tidemark], existing: drive)
        #expect(plan.stillsPath?.hasSuffix("/RAW/A082") == true)
        #expect(plan.rows.first { $0.name == "RAW" }?.receivesFiles == true)
        #expect(plan.rows.first { $0.name == "Selects" }?.receivesFiles == false)
    }

    @Test("Audio role: kept only with audio, and audio stays apart")
    func audio() {
        var setup = sampleSetup()
        setup.inner.insert(InnerFolder(name: "Sound", role: .audio), at: 2)
        let without = ShootPlanner.plan(setup: setup, request: request(), clients: [tidemark], existing: drive)
        #expect(without.skippedNote == "No Photo or Sound folder: only video here.")
        #expect(without.audioPath == nil)
        let with = ShootPlanner.plan(setup: setup, request: request(card: "F3_001", audio: true), clients: [tidemark], existing: drive)
        #expect(with.audioPath?.hasSuffix("/Sound/F3_001") == true)
        #expect(with.skippedNote == "No Photo folder: only video and audio here.")
        let audioOnly = ShootPlanner.plan(setup: setup, request: request(video: false, audio: true), clients: [tidemark], existing: drive)
        #expect(audioOnly.skippedNote == "No Photo or Footage folder: only audio here.")
        #expect(audioOnly.footagePath == audioOnly.audioPath)
        #expect(ShootPlanner.plan(setup: sampleSetup(), request: request(audio: true), clients: [tidemark], existing: drive).audioPath == nil)
    }

    @Test("A photo card on a drive with no Photo folder keeps Footage, so the card has a home")
    func noHomeForStills() {
        var setup = sampleSetup()
        setup.inner.removeFirst()
        let plan = ShootPlanner.plan(setup: setup, request: request(video: false, stills: true), clients: [tidemark], existing: drive)
        #expect(plan.rows.contains { $0.name == "Footage" })
        #expect(plan.stillsPath == nil)
        #expect(plan.footagePath.hasSuffix("/Footage/FX3/A082"))
    }

    @Test("Year comes from the shoot date, and a new year shows as new")
    func newYear() {
        let january = ShootRequest(client: "Tidemark Rowing Club", shootName: "Gala", day: CalendarDay(year: 2027, month: 1, day: 9),
                                   cameraFolder: "FX3", cardFolder: "A090", hasVideo: true, hasStills: false, hasAudio: false)
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: january, clients: [tidemark], existing: drive)
        #expect(plan.shootPath == "2027/Paid work/Tidemark Rowing Club/09.01.27 Gala")
        #expect(plan.rows.prefix(3).map(\.name) == ["2027", "Paid work", "Tidemark Rowing Club"])
        #expect(plan.rows.prefix(4).allSatisfy { $0.isNew })
        #expect(plan.rows.prefix(3).map(\.depth) == [0, 1, 2])
        #expect(!plan.clientExists)
        #expect(plan.existingClientName == "Tidemark Rowing Club")
        #expect(plan.foldersToCreate.prefix(3) == ["2027", "2027/Paid work", "2027/Paid work/Tidemark Rowing Club"])
    }

    @Test("A brand new client under existing parents")
    func newClient() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(client: "New Gym"), clients: [tidemark], existing: drive)
        #expect(plan.rows[0] == PlanRow(name: "2026 \u{203A} Paid work", depth: 0, isNew: false, receivesFiles: false))
        #expect(plan.rows[1] == PlanRow(name: "New Gym", depth: 1, isNew: true, receivesFiles: false))
        #expect(plan.rows[2].depth == 2)
        #expect(!plan.clientExists)
        #expect(plan.existingClientName == nil)
    }

    @Test("Client matching: case, accents, whitespace, NFC and NFD, using the drive's spelling")
    func clientMatching() {
        let nfd = "Caf\u{0065}\u{0301} Cr\u{0065}\u{0300}me".decomposedStringWithCanonicalMapping
        let folder = ClientFolder(name: nfd, path: "2026/Paid work/\(nfd)")
        let existing = lookup(["2026/Paid work/\(nfd)"])
        for typed in ["café crème", "CAFE CREME", "  Café   Crème ", "Caf\u{00E9} Cr\u{00E8}me"] {
            let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(client: typed), clients: [folder], existing: existing)
            #expect(plan.clientExists, "\(typed)")
            #expect(plan.existingClientName == nfd)
            #expect(Array(plan.shootPath.utf8).starts(with: Array("2026/Paid work/\(nfd)".utf8)))
        }
    }

    @Test("Lantern Bakery Co. and a trailing dot on the drive")
    func lantern() {
        let folder = ClientFolder(name: "Lantern Bakery Co.", path: "2026/Paid work/Lantern Bakery Co.")
        let existing = lookup(["2026/Paid work/Lantern Bakery Co."])
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(client: "lantern bakery co."), clients: [folder], existing: existing)
        #expect(plan.clientExists)
        #expect(plan.shootPath.hasPrefix("2026/Paid work/Lantern Bakery Co./"))
    }

    @Test("A close variant does not merge, and nearMatch offers it")
    func nearMatch() {
        let folder = ClientFolder(name: "Lantern Bakery Co.", path: "2026/Paid work/Lantern Bakery Co.")
        let existing = lookup(["2026/Paid work/Lantern Bakery Co."])
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(client: "Lantern Bakery"), clients: [folder], existing: existing)
        #expect(!plan.clientExists)
        #expect(plan.shootPath.hasPrefix("2026/Paid work/Lantern Bakery/"))
        #expect(ShootPlanner.nearMatch(for: "Lantern Bakery", in: [folder]) == folder)
        #expect(ShootPlanner.nearMatch(for: "Lanturn Bakery Co", in: [folder]) == folder)
        #expect(ShootPlanner.nearMatch(for: "lantern bakery co.", in: [folder]) == nil)
        #expect(ShootPlanner.nearMatch(for: "Tidemark Rowing Club", in: [folder]) == nil)
        #expect(ShootPlanner.nearMatch(for: "Co", in: [folder]) == nil)
    }

    @Test("Same date and name adds to the shoot already there, using its spelling")
    func existingShoot() {
        let shoot = "2026/Paid work/Tidemark Rowing Club/23.10.26 REGATTA Day"
        let existing = lookup(["\(shoot)/Footage/FX3", "\(shoot)/Project"])
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(), clients: [tidemark], existing: existing)
        #expect(plan.shootPath == shoot)
        #expect(plan.rows[1] == PlanRow(name: "23.10.26 REGATTA Day", depth: 1, isNew: false, receivesFiles: false))
        #expect(plan.rows.dropFirst().filter(\.isNew).isEmpty)
        #expect(plan.foldersToCreate == ["\(shoot)/Footage/FX3/A082"])
    }

    @Test("On-drive spelling wins at every level")
    func spellings() {
        let existing = lookup(["2026/PAID WORK/Tidemark Rowing Club/23.10.26 Regatta day/FOOTAGE"])
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(), clients: [tidemark], existing: existing)
        #expect(plan.footagePath == "2026/PAID WORK/Tidemark Rowing Club/23.10.26 Regatta day/FOOTAGE/FX3/A082")
    }

    @Test("`existing` may return a whole path or just the name")
    func existingReturnsPath() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(), clients: [tidemark]) { path in
            path.lowercased() == "2026" ? "2026" : (path.lowercased() == "2026/paid work" ? "PAID WORK" : nil)
        }
        #expect(plan.shootPath.hasPrefix("2026/PAID WORK/"))
    }

    @Test("The client list is enough to know a client is there")
    func clientsListCounts() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(), clients: [tidemark]) { _ in nil }
        #expect(plan.clientExists)
        #expect(plan.rows[0].name == "2026 \u{203A} Paid work \u{203A} Tidemark Rowing Club")
        #expect(plan.foldersToCreate.first == plan.shootPath)
    }

    @Test("The client list counts when the client is not the last level")
    func clientAboveYear() {
        var setup = sampleSetup()
        setup.path = [.client, .year]
        let folder = ClientFolder(name: "Tidemark Rowing Club", path: "Tidemark Rowing Club")
        let plan = ShootPlanner.plan(setup: setup, request: request(), clients: [folder]) { _ in nil }
        #expect(plan.clientExists)
        #expect(plan.rows[0] == PlanRow(name: "Tidemark Rowing Club", depth: 0, isNew: false, receivesFiles: false))
        #expect(plan.rows[1] == PlanRow(name: "2026", depth: 1, isNew: true, receivesFiles: false))
    }

    @Test("An `existing` that says yes to everything cannot hang the plan")
    func alwaysExisting() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(card: ""), clients: [tidemark]) { $0 }
        #expect(plan.footagePath.hasSuffix("/Card 1000"))
    }

    @Test("Uppercase applies to shoots and the card prefix, and to clients only on uppercase drives")
    func uppercase() {
        var setup = sampleSetup()
        setup.shootName.uppercase = true
        setup.footage = .perCard(prefix: "Card ")
        let mixed = ShootPlanner.plan(setup: setup, request: request(client: "New Gym"), clients: [tidemark], existing: drive)
        #expect(mixed.shootPath == "2026/Paid work/New Gym/23.10.26 REGATTA DAY")
        #expect(mixed.footagePath.hasSuffix("/Footage/CARD A082"))
        let loud = ClientFolder(name: "NORTHGATE", path: "2026/Paid work/NORTHGATE")
        let upper = ShootPlanner.plan(setup: setup, request: request(client: "New Gym"), clients: [loud], existing: drive)
        #expect(upper.shootPath.hasPrefix("2026/Paid work/NEW GYM/"))
    }

    @Test("Names stay safe on exFAT")
    func safeNames() {
        let setup = sampleSetup()
        let day = regattaDay
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "Spring: menu/v2?*", day: day) == "23.10.26 Spring menuv2")
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "A<b>\"c\"|d\\e\u{0007}\n", day: day) == "23.10.26 Abcde")
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "Trailing... ", day: day) == "23.10.26 Trailing")
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "...", day: day) == "23.10.26")
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "", day: day) == "23.10.26")

        let long = ShootPlanner.shootFolderName(setup: setup, shootName: String(repeating: "é", count: 300), day: day)
        #expect(long.utf8.count <= 200)
        #expect(long.hasPrefix("23.10.26 "))

        var suffix = setup
        suffix.shootName.position = .suffix
        let longSuffix = ShootPlanner.shootFolderName(setup: suffix, shootName: String(repeating: "a", count: 300), day: day)
        #expect(longSuffix.utf8.count <= 200)
        #expect(longSuffix.hasSuffix(" 23.10.26"))

        let hostile = ShootPlanner.plan(setup: setup, request: request(client: "../../etc", camera: "F/X:3", card: "..\\.."),
                                        clients: [], existing: { _ in nil })
        #expect(!hostile.footagePath.split(separator: "/").contains { $0 == ".." || $0 == "." || $0.isEmpty })
        #expect(hostile.foldersToCreate.allSatisfy { !$0.contains("//") })
    }

    @Test("Styles: suffix, underscore, month-only, no client level")
    func styles() {
        var setup = sampleSetup()
        setup.path = []
        setup.shootName = ShootNameStyle(dateFormat: "yyyyMMdd", position: .suffix, separator: "_")
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "Kunde Dreh", day: regattaDay) == "Kunde_Dreh_20261023")
        setup.shootName = ShootNameStyle(dateFormat: "yyyy-MM")
        #expect(ShootPlanner.shootFolderName(setup: setup, shootName: "Job", day: regattaDay) == "2026-10 Job")

        let plan = ShootPlanner.plan(setup: setup, request: request(), clients: [], existing: { _ in nil })
        #expect(plan.shootPath == "2026-10 Regatta day")
        #expect(plan.rows[0].depth == 0)
        #expect(plan.pills[0].depth == 0)
        #expect(!plan.clientExists)
        #expect(plan.existingClientName == nil)
    }

    @Test("A missing reel still gets its own folder")
    func noReel() {
        let shoot = "2026/Paid work/Tidemark Rowing Club/23.10.26 Regatta day"
        let existing = lookup(["\(shoot)/Footage/FX3/Card 01"])
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(card: ""), clients: [tidemark], existing: existing)
        #expect(plan.footagePath == "\(shoot)/Footage/FX3/Card 02")
    }

    @Test("A missing camera drops the camera level, not the card")
    func noCamera() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(camera: ""), clients: [tidemark], existing: drive)
        #expect(plan.footagePath.hasSuffix("/Footage/A082"))
        #expect(plan.rows.first { $0.name == "Footage" }?.receivesFiles == true)
    }

    @Test("Every folder's parent comes first in foldersToCreate")
    func parentsFirst() {
        let plan = ShootPlanner.plan(setup: sampleSetup(), request: request(client: "New", video: true, stills: true, audio: true),
                                     clients: [], existing: { _ in nil })
        var seen = Set<String>()
        for path in plan.foldersToCreate {
            if let slash = path.lastIndex(of: "/") { #expect(seen.contains(String(path[..<slash])), "\(path)") }
            seen.insert(path)
        }
        #expect(Set(plan.foldersToCreate).count == plan.foldersToCreate.count)
    }

    @Test("Presets")
    func presets() {
        let presets = ShootPlanner.presets()
        #expect(presets.map(\.name) == [
            "Client \u{203A} Year \u{203A} Date Shoot",
            "Year \u{203A} Client \u{203A} Date Shoot",
            "Year \u{203A} Paid work \u{203A} Client \u{203A} Date Shoot",
            "Date Shoot at the top",
        ])
        #expect(presets[2].setup.path == sampleSetup().path)
        #expect(presets[2].setup.inner == sampleSetup().inner)
        #expect(presets[3].setup.path.isEmpty)
        #expect(presets.allSatisfy { $0.setup.learned == nil && $0.setup.footage == .perCamera })
        #expect(presets.suffix(2).allSatisfy { $0.setup.shootName.dateFormat == "dd.MM.yy" })
    }
}
