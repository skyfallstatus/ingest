import Foundation
import Testing
@testable import IngestCore

@Suite("Layout learner")
struct LayoutLearnerTests {
    private static let clientNames = ["Tidemark Rowing Club", "Lantern Bakery Co.", "Northfield Dance", "Ada Lovelace Trust",
                                      "Kestrel Bikes", "Oakline", "Sable & Sons"]

    /// A drive of 34 shoots, the 5 oldest with a Video folder.
    private func sampleDrive(videoReplacesFootage: Bool = false) -> FakeDrive {
        var drive = FakeDrive()
        for index in 0..<34 {
            let older = index < 5
            let year = index < 14 ? 2025 : 2026
            let month = index % 12 + 1
            let day = index % 27 + 1
            let client = Self.clientNames[index % Self.clientNames.count]
            let date = String(format: "%02d.%02d.%02d", day, month, year % 100)
            let shoot = "\(year)/Paid work/\(client)/\(date) Shoot \(index)"
            drive.file("\(shoot)/Photo/RAW/DSC\(index).ARW", size: 25_000_000)
            drive.file("\(shoot)/Photo/Exports/DSC\(index).jpg", size: 5_000_000)
            if !(older && videoReplacesFootage) {
                drive.file("\(shoot)/Footage/FX3/A\(100 + index)/PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 40_000_000_000)
            }
            if older { drive.file("\(shoot)/Video/old.mov", size: 8_000_000_000) }
            drive.file("\(shoot)/Project/edit.prproj", size: 2_000_000)
        }
        return drive
    }

    @Test("29 of 34 shoots follow, with the exception named")
    func sampleLayout() throws {
        let setup = try #require(LayoutLearner.learn(entries: sampleDrive().entries))
        #expect(setup.path == [.year, .literal("Paid work"), .client])
        #expect(setup.shootName == ShootNameStyle(dateFormat: "dd.MM.yy", position: .prefix, separator: " ", uppercase: false))
        #expect(setup.inner == sampleSetup().inner)
        #expect(setup.footage == .perCamera)
        let stats = try #require(setup.learned)
        #expect(stats.shootsFound == 34)
        #expect(stats.shootsFollowing == 29)
        #expect(stats.exception == "5 older shoots also have a folder called Video. Nothing in them moves.")
        #expect(stats.mostRecentDay?.year == 2026)
    }

    @Test("A Video folder that replaces Footage deviates the same way")
    func videoInsteadOfFootage() throws {
        let setup = try #require(LayoutLearner.learn(entries: sampleDrive(videoReplacesFootage: true).entries))
        let stats = try #require(setup.learned)
        #expect(stats.shootsFound == 34)
        #expect(stats.shootsFollowing == 29)
        #expect(stats.exception == "5 older shoots also have a folder called Video. Nothing in them moves.")
        #expect(setup.inner.map(\.name) == ["Photo", "Footage", "Project"])
    }

    @Test("Stats name the newest client")
    func mostRecent() throws {
        var drive = FakeDrive()
        for (client, date) in [("Acme", "2026-01-05"), ("Beta", "2026-03-05"), ("Gamma", "2026-02-05"), ("Acme", "2025-12-01")] {
            drive.file("\(client)/\(date) Shoot/Footage/a.mov")
            drive.file("\(client)/\(date) Shoot/Project/a.drp")
        }
        let stats = try #require(LayoutLearner.learn(entries: drive.entries)?.learned)
        #expect(stats.mostRecentClient == "Beta")
        #expect(stats.mostRecentDay == CalendarDay(year: 2026, month: 3, day: 5))
        #expect(stats.exception == nil)
        #expect(stats.foldersRead == 15)
    }

    @Test("Wedding photographer: year, month, couple")
    func wedding() throws {
        var drive = FakeDrive()
        let months = ["04 April", "05 May", "06 June", "07 July", "08 August", "09 September"]
        for (index, month) in months.enumerated() {
            for couple in 0..<3 {
                let name = "Couple\(index)\(couple) & Partner"
                let day = String(format: "%02d.%02d.26", 13 + couple, index + 4)
                let shoot = "2026/\(month)/\(name) \(day)"
                drive.file("\(shoot)/RAW/IMG_0001.CR3", size: 30_000_000)
                drive.file("\(shoot)/Selects/IMG_0001.jpg", size: 8_000_000)
                drive.file("\(shoot)/Gallery/IMG_0001.jpg", size: 2_000_000)
            }
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.path == [.year, .client])    // The contract has no month level.
        #expect(setup.shootName.position == .suffix)
        #expect(setup.shootName.dateFormat == "dd.MM.yy")
        #expect(setup.inner.contains { $0.name == "RAW" && $0.role == .photo })
        #expect(setup.inner.contains { $0.name == "Footage" && $0.role == .footage })
        #expect(setup.footage == .perCamera)
        #expect(setup.learned?.shootsFollowing == 18)
    }

    @Test("Wedding drive whose couples carry no date is not guessed at")
    func weddingWithoutDates() {
        var drive = FakeDrive()
        for month in ["04 April", "05 May", "06 June"] {
            for couple in ["Emma & Tom", "Sara & Jon", "Lea & Max"] {
                drive.file("2026/\(month)/\(couple)/RAW/IMG_0001.CR3", size: 30_000_000)
            }
        }
        #expect(LayoutLearner.learn(entries: drive.entries) == nil)
    }

    @Test("Documentary by project, no dates: nil, not garbage")
    func documentary() {
        var drive = FakeDrive()
        for film in ["The River", "Salt Roads", "Long Winter"] {
            for section in ["Interviews", "B-Roll", "Archive", "Edit", "Sound"] {
                drive.file("\(film)/\(section)/Day 1/C0001.MXF", size: 50_000_000_000)
                drive.file("\(film)/\(section)/Day 2/C0002.MXF", size: 50_000_000_000)
            }
            drive.folder("\(film)/1920x1080")
            drive.folder("\(film)/v2.1.3")
            drive.folder("\(film)/4096")
        }
        #expect(LayoutLearner.learn(entries: drive.entries) == nil)
    }

    @Test("US drive: MM.dd.yy across the drive, including ambiguous folders")
    func usDates() throws {
        var drive = FakeDrive()
        for (index, date) in ["10.23.26", "03.04.26", "11.15.25", "01.02.26", "12.30.25", "06.07.26"].enumerated() {
            let shoot = "Clients/Client \(index % 3)/\(date) Spot \(index)"
            drive.file("\(shoot)/Footage/A7S/C0001.MP4", size: 9_000_000_000)
            drive.file("\(shoot)/Project/a.prproj")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.shootName.dateFormat == "MM.dd.yy")
        #expect(setup.path == [.literal("Clients"), .client])
        #expect(setup.learned?.shootsFound == 6)
        #expect(setup.learned?.mostRecentDay == CalendarDay(year: 2026, month: 10, day: 23))
        #expect(setup.footage == .perCamera)
    }

    @Test("German drive: underscores, German folder names")
    func german() throws {
        var drive = FakeDrive()
        for index in 0..<8 {
            let shoot = "Produktionen/2026-\(String(format: "%02d", index + 2))-23_Kunde\(index)_Dreh"
            drive.file("\(shoot)/Rohmaterial/CARD 0\(index + 1)/M4ROOT/CLIP/C0001.MP4", size: 30_000_000_000)
            drive.file("\(shoot)/Projekt/schnitt.prproj")
            drive.file("\(shoot)/Ausgabe/final.mp4", size: 900_000_000)
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.path == [.literal("Produktionen")])
        #expect(setup.shootName == ShootNameStyle(dateFormat: "yyyy-MM-dd", position: .prefix, separator: "_", uppercase: false))
        #expect(setup.inner.map(\.role) == [.footage, .project, .exports])
        #expect(setup.footage == .perCard(prefix: "CARD "))
    }

    @Test("Empty drive")
    func empty() {
        #expect(LayoutLearner.learn(entries: []) == nil)
        var drive = FakeDrive()
        drive.folder(".Spotlight-V100")
        drive.folder("System Volume Information")
        #expect(LayoutLearner.learn(entries: drive.entries) == nil)
    }

    @Test("Messy drive, mostly downloads: nil")
    func messy() {
        var drive = FakeDrive()
        for index in 0..<120 {
            drive.file("Downloads/installer-\(index)/setup.dmg", size: 90_000_000)
            drive.file("Downloads/wetransfer_stuff_\(index)/clip.mp4", size: 90_000_000)
        }
        for date in ["2026-01-12", "2026-03-02", "2026-05-20", "2026-06-01"] {
            drive.file("Downloads/\(date) statement/statement.pdf")
            drive.file("Downloads/\(date) phone/IMG.mov", size: 40_000_000)
            drive.file("Random/\(date) notes.txt")
        }
        drive.file("Random/Screenshot 2026-10-12.png")
        #expect(LayoutLearner.learn(entries: drive.entries) == nil)
    }

    @Test("Messy drive that does hold real shoots keeps them and ignores the mess")
    func messWithShoots() throws {
        var drive = FakeDrive()
        for index in 0..<200 { drive.file("Downloads/thing-\(index)/file.zip") }
        for date in ["2026-01-12", "2026-03-02"] { drive.file("Downloads/\(date) phone/IMG.mov", size: 40_000_000) }
        for index in 0..<6 {
            let shoot = "Jobs/Client\(index % 2)/2026-0\(index + 1)-15 Job"
            drive.file("\(shoot)/Footage/C0001.MP4", size: 5_000_000_000)
            drive.folder("\(shoot)/Project")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.path == [.literal("Jobs"), .client])
        #expect(setup.learned?.shootsFollowing == 6)
    }

    @Test("French drive with Rushes")
    func french() throws {
        var drive = FakeDrive()
        for index in 0..<9 {
            let client = ["Maison Dupont", "Théâtre Récamier", "Café Lumière"][index % 3]
            let shoot = "Clients/\(client)/\(String(format: "%02d", index + 14)).10.26 Tournage \(index)"
            drive.file("\(shoot)/Rushes/A7S/C0001.MP4", size: 20_000_000_000)
            drive.file("\(shoot)/Rushes/FX3/C0002.MP4", size: 20_000_000_000)
            drive.file("\(shoot)/Son/ambiance.wav", size: 900_000_000)
            drive.file("\(shoot)/Montage/film.prproj")
            drive.file("\(shoot)/Sortie/film.mp4", size: 2_000_000_000)
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.inner.map(\.name) == ["Rushes", "Son", "Montage", "Sortie"])
        #expect(setup.inner.map(\.role) == [.footage, .audio, .project, .exports])
        #expect(setup.footage == .perCamera)
        #expect(setup.shootName.dateFormat == "dd.MM.yy")
    }

    @Test("A language with no name hints still reads, from content alone")
    func noHintsAtAll() throws {
        var drive = FakeDrive()
        for index in 0..<6 {
            let shoot = "クライアント\(index % 2)/2026-0\(index + 1)-23 撮影\(index)"
            drive.file("\(shoot)/素材/C0001.MP4", size: 50_000_000_000)
            drive.file("\(shoot)/編集/film.prproj")
            drive.file("\(shoot)/写真/DSC0001.ARW", size: 30_000_000)
            drive.file("\(shoot)/録音/take1.wav", size: 900_000_000)
            drive.file("\(shoot)/書き出し/film.mp4", size: 1_000_000_000)
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.inner.map(\.role) == [.footage, .project, .photo, .audio, .plain])
        #expect(setup.shootName.uppercase == false)
        #expect(setup.path == [.client])
    }

    @Test("Content beats names: the folder with the camera bytes is the footage folder")
    func contentFirst() throws {
        var drive = FakeDrive()
        for index in 0..<5 {
            let shoot = "2026-0\(index + 1)-10 Job \(index)"
            drive.file("\(shoot)/Stuff/C0001.MP4", size: 80_000_000_000)
            drive.file("\(shoot)/Photos/a.jpg", size: 3_000_000)
            drive.file("\(shoot)/Video Exports/final.mp4", size: 500_000_000)
            drive.file("\(shoot)/Documents/brief.pdf")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        let footage = try #require(setup.inner.first { $0.role == .footage })
        #expect(footage.name == "Stuff")
        #expect(setup.inner.first { $0.name == "Photos" }?.role == .photo)
        #expect(setup.inner.first { $0.name == "Video Exports" }?.role == .exports)
        #expect(setup.inner.first { $0.name == "Documents" }?.role == .plain)
    }

    @Test("Numbered folders keep their numbers, and variants of one folder merge")
    func numbering() throws {
        var drive = FakeDrive()
        for index in 0..<8 {
            let shoot = "CLIENT \(index % 3)/2026-0\(index + 1)-11 JOB \(index)"
            let rushes = index % 4 == 3 ? "01 RUSHES" : "01 ORIGINALS"
            drive.file("\(shoot)/\(rushes)/CARD A0\(10 + index)/PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 30_000_000_000)
            drive.folder("\(shoot)/02 ASSETS")
            drive.file("\(shoot)/03 PREMIERE/a.prproj")
            drive.file("\(shoot)/04 EXPORTS/a.mp4", size: 100_000_000)
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.inner.map(\.name) == ["01 ORIGINALS", "02 ASSETS", "03 PREMIERE", "04 EXPORTS"])
        #expect(setup.inner.map(\.role) == [.footage, .plain, .project, .exports])
        #expect(setup.footage == .perCard(prefix: "CARD "))
        #expect(setup.shootName.uppercase)
        #expect(setup.learned?.shootsFollowing == 8)
        #expect(setup.learned?.exception == nil)
    }

    @Test("A shoot inside a shoot is not a shoot; noise and card trees are ignored")
    func nestingAndNoise() throws {
        var drive = FakeDrive()
        for index in 0..<4 {
            let shoot = "Client/2026-0\(index + 1)-10 Festival"
            drive.file("\(shoot)/01 ORIGINALS/2026-09-17 THU/C0001.MP4", size: 9_000_000_000)
            drive.file("\(shoot)/01 ORIGINALS/2026-09-18 FRI/C0002.MP4", size: 9_000_000_000)
            drive.folder("\(shoot)/03 PREMIERE")
            drive.file("\(shoot)/_CODEX/2026-10-01 notes/a.mov")
            drive.file("\(shoot)/Adobe Premiere Pro Auto-Save/a.prproj")
        }
        for path in ["_ARCHIVE/2026-01-01 Old/a.mov", "_ARCHIVE/2026-01-02 Old/a.mov", "_ARCHIVE/2026-01-03 Old/a.mov",
                     "$RECYCLE.BIN/2026-01-01 Gone/a.mov", "Cache/2026-01-01 Gone/a.mov",
                     "Client/Card/DCIM/2026-01-01/a.mov", "Client/Card/DCIM/2026-01-02/a.mov",
                     "Client/Sony/PRIVATE/M4ROOT/CLIP/2026-01-03 X/a.mp4"] {
            drive.file(path)
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.learned?.shootsFound == 4)
        #expect(setup.path == [.literal("Client")])
    }

    @Test("Month buckets hold shoots, they are not shoots")
    func monthBuckets() throws {
        var drive = FakeDrive()
        for month in 1...4 {
            for day in [10, 20] {
                let bucket = String(format: "2026-%02d", month)
                let shoot = "\(bucket)/\(bucket)-\(day) Job"
                drive.file("\(shoot)/Footage/a.mov", size: 1_000_000_000)
                drive.file("\(shoot)/Project/a.drp")
            }
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.learned?.shootsFound == 8)
        #expect(setup.shootName.dateFormat == "yyyy-MM-dd")
    }

    @Test("Month-only and full dates are one family; full dates win")
    func monthFamily() throws {
        var drive = FakeDrive()
        for (index, date) in ["2026-01", "2026-02", "2026-03", "2026-04-02", "2026-05-02"].enumerated() {
            drive.file("Client \(index % 2)/\(date) JOB \(index)/Footage/a.mov", size: 1_000_000_000)
            drive.file("Client \(index % 2)/\(date) JOB \(index)/Project/a.drp")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.shootName.dateFormat == "yyyy-MM-dd")
        #expect(setup.learned?.shootsFound == 5)
    }

    @Test("Dump folders do not add shoots")
    func dumps() throws {
        var drive = FakeDrive()
        for index in 0..<6 {
            drive.file("Client \(index % 3)/2026-0\(index + 1)-10 Job/Footage/a.mov", size: 2_000_000_000)
            drive.folder("Client \(index % 3)/2026-0\(index + 1)-10 Job/Project")
        }
        for index in 0..<40 { drive.file("TO SORT/pile \(index)/a.mov", size: 2_000_000_000) }
        drive.file("TO SORT/2026-02-02 mystery/a.mov", size: 2_000_000_000)
        for day in 10...17 { drive.file("Admin notes/2026-10-\(day) Thoughts/note.txt") }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.learned?.shootsFound == 6)
        #expect(setup.learned?.exception == nil)
    }

    @Test("A day-first drive stays day-first when every value is ambiguous")
    func ambiguousDefaultsToDayFirst() throws {
        var drive = FakeDrive()
        for (index, date) in ["01.02.26", "03.04.26", "05.06.26", "07.08.26"].enumerated() {
            drive.file("Client/\(date) Job \(index)/Footage/a.mov", size: 1_000_000_000)
            drive.file("Client/\(date) Job \(index)/Project/a.drp")
        }
        #expect(LayoutLearner.learn(entries: drive.entries)?.shootName.dateFormat == "dd.MM.yy")
    }

    @Test("Listing order decides the inner order; NFD names survive")
    func orderAndNFD() throws {
        var drive = FakeDrive()
        let son = "Réalisation".decomposedStringWithCanonicalMapping
        for index in 0..<4 {
            let shoot = "2026-0\(index + 1)-10 Job"
            drive.file("\(shoot)/Zeta/a.mov", size: 2_000_000_000)
            drive.file("\(shoot)/\(son)/a.txt")
            drive.file("\(shoot)/Alpha/a.txt")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.inner.map(\.name) == ["Zeta", son, "Alpha"])
    }

    @Test("A card dumped beside a client's shoots does not hide them")
    func strayCard() throws {
        var drive = FakeDrive()
        for index in 0..<6 {
            let client = "Client \(index % 2)"
            drive.file("\(client)/2026-0\(index + 1)-10 Job/Footage/a.mov", size: 2_000_000_000)
            drive.folder("\(client)/2026-0\(index + 1)-10 Job/Project")
            drive.file("\(client)/DCIM/100CANON/IMG_0001.JPG")
            drive.file("2026/DCIM/100CANON/IMG_000\(index).JPG")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.learned?.shootsFound == 6)
        #expect(LayoutLearner.clients(in: setup, entries: drive.entries).map(\.name).sorted() == ["Client 0", "Client 1"])
    }

    @Test("A folder that only mentions video does not break a shoot's layout")
    func mentionsAreNotRivals() throws {
        var drive = FakeDrive()
        for index in 0..<8 {
            let shoot = "Client \(index % 2)/2026-0\(index + 1)-10 Job"
            drive.file("\(shoot)/Footage/a.mov", size: 2_000_000_000)
            drive.folder("\(shoot)/Project")
            if index < 2 { drive.file("\(shoot)/Camera Reports/log.txt") }
            if index == 2 { drive.file("\(shoot)/Social Media/cut.mp4") }
        }
        let stats = try #require(LayoutLearner.learn(entries: drive.entries)?.learned)
        #expect(stats.shootsFollowing == 8)
        #expect(stats.exception == "2 older shoots also have a folder called Camera Reports. Nothing in them moves.")
    }

    @Test("Folders only, no files: the layout still reads")
    func directoriesOnly() throws {
        var drive = FakeDrive()
        for index in 0..<10 {
            let shoot = "2026/Clients/Client \(index % 3)/\(10 + index).10.26 Job \(index)"
            for inner in ["Photo/RAW", "Photo/Exports", "Footage/FX3", "Project"] { drive.folder("\(shoot)/\(inner)") }
            if index < 2 { drive.folder("\(shoot)/Video") }
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.path == [.year, .literal("Clients"), .client])
        #expect(setup.inner == sampleSetup().inner)
        #expect(setup.learned?.shootsFollowing == 8)
    }

    @Test("Reel and camera names tell the footage style apart")
    func cardNames() {
        #expect(LayoutNames.cardName("CARD A082") == CardName(prefix: "CARD ", reel: "A082"))
        #expect(LayoutNames.cardName("Card_01") == CardName(prefix: "Card_", reel: "01"))
        #expect(LayoutNames.cardName("CARD 01") == CardName(prefix: "CARD ", reel: "01"))
        #expect(LayoutNames.cardName("SD CARD 2") == CardName(prefix: "SD CARD ", reel: "2"))
        #expect(LayoutNames.cardName("A082") == CardName(prefix: "", reel: "A082"))
        #expect(LayoutNames.cardName("A001_C002_0101AB")?.prefix == "")
        for camera in ["FX3", "A7S", "A7SIII", "C70", "C300", "C500", "R5", "CAM A", "Cam 2", "CamB", "GoPro 11", "BMPCC6K", "DJI Mini"] {
            #expect(LayoutNames.cardName(camera) == nil, "\(camera) is not a card")
            #expect(LayoutNames.looksLikeCamera(camera), "\(camera) is a camera")
        }
        for other in ["Interviews", "Selects", "Day 1", "Exports", "Stuff"] {
            #expect(LayoutNames.looksLikeCamera(other) == false, "\(other) is not a camera")
        }
    }

    // MARK: Clients

    @Test("Clients, most recently used first")
    func clients() throws {
        let entries = sampleDrive().entries
        let setup = try #require(LayoutLearner.learn(entries: entries))
        let clients = LayoutLearner.clients(in: setup, entries: entries)
        #expect(Set(clients.map(\.name)) == Set(Self.clientNames))
        let days = clients.compactMap(\.lastShoot)
        #expect(days.count == clients.count)
        #expect(days == days.sorted(by: >))
        #expect(clients[0].path.hasPrefix("2026/Paid work/"))
    }

    @Test("A client with no dated shoot stays listed after the rest; notes do not")
    func clientsWithoutShoots() throws {
        var drive = FakeDrive()
        for index in 0..<4 {
            drive.file("ACME/2026-0\(index + 1)-10 JOB/Footage/a.mov", size: 2_000_000_000)
            drive.folder("ACME/2026-0\(index + 1)-10 JOB/Project")
            drive.file("BETA/2026-1\(index)-10 JOB/Footage/a.mov", size: 2_000_000_000)
            drive.folder("BETA/2026-1\(index)-10 JOB/Project")
        }
        drive.file("DELTA/ITW/a.mov", size: 2_000_000_000)
        drive.file("NOTES/2026-10-10 thoughts/a.txt")
        drive.folder("_CODEX")
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        let clients = LayoutLearner.clients(in: setup, entries: drive.entries)
        #expect(clients.map(\.name) == ["BETA", "ACME", "DELTA"])
        #expect(clients.last?.lastShoot == nil)
    }

    @Test("Setups with no client level have no clients")
    func noClientLevel() {
        var setup = sampleSetup()
        setup.path = [.year]
        #expect(LayoutLearner.clients(in: setup, entries: []).isEmpty)
    }
}

@Suite("What counts as media")
struct LayoutMediaKindTests {
    private func shoot(_ i: Int) -> String { "Client \(i % 2)/2026-0\(i + 1)-10 Job" }

    @Test(arguments: ["MTS", "NEV", "insv", "arx", "avi"])
    func `Footage in any camera format marks its folder as the footage folder`(ext: String) throws {
        var drive = FakeDrive()
        for i in 0 ..< 6 {
            drive.file("\(shoot(i))/Stuff/clip.\(ext)", size: 9_000_000_000)
            drive.file("\(shoot(i))/Project/a.prproj")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.inner.first { $0.name == "Stuff" }?.role == .footage)
        #expect(!setup.inner.contains { $0.name == "Footage" })
    }

    @Test func `A folder of logos is not where a card's photos go`() throws {
        var drive = FakeDrive()
        for i in 0 ..< 6 {
            drive.file("\(shoot(i))/Footage/a.mov", size: 2_000_000_000)
            drive.file("\(shoot(i))/Graphics/logo\(i).png", size: 50_000_000)
            drive.file("\(shoot(i))/Project/a.prproj")
        }
        let setup = try #require(LayoutLearner.learn(entries: drive.entries))
        #expect(setup.inner.first { $0.name == "Graphics" }?.role == .plain)
        let request = ShootRequest(client: "Client 0", shootName: "New", day: CalendarDay(year: 2026, month: 9, day: 9), cameraFolder: "FX3",
                                   cardFolder: "A001", hasVideo: true, hasStills: true, hasAudio: false)
        let plan = ShootPlanner.plan(setup: setup, request: request, clients: [], existing: { _ in nil })
        #expect(plan.stillsPath?.contains("Graphics") != true)
    }
}
