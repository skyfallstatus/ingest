import AppKit
import IngestCore
import SwiftUI

/// Renders every state to PNG with sample data, in light and dark, for checking the design without touching any volume.
/// These are the real views. Only the data is staged.
@MainActor enum DemoRenderer {
    private static func volume(_ name: String, path: String, total: UInt64 = 1_000_000_000_000) -> Volume {
        Volume(path: path, name: name, uuid: nil, total: total, free: 412_000_000_000, fsType: "exfat",
               isReadOnly: false, isInternal: false, anchor: MountAnchor(path: "/tmp"))
    }

    private static func sampleSetup() -> DriveSetup {
        DriveSetup(path: [.literal("Clients"), .client],
                   shootName: ShootNameStyle(dateFormat: "dd.MM.yy"),
                   inner: [InnerFolder(name: "Photo", role: .photo, children: [InnerFolder(name: "RAW", role: .photoRaw), InnerFolder(name: "Exports", role: .photoExports)]),
                           InnerFolder(name: "Footage", role: .footage), InnerFolder(name: "Project", role: .project)],
                   footage: .perCamera,
                   learned: LearnedStats(foldersRead: 212, shootsFound: 38, shootsFollowing: 33,
                                         exception: "5 older shoots also have a Video folder and won't be moved.",
                                         mostRecentClient: "Tidemark Rowing Club", mostRecentDay: CalendarDay(year: 2026, month: 10, day: 19)))
    }

    @MainActor private static var stagedDrive: DriveState?

    /// A folder on this Mac, as a drive.
    private static func folder() -> DriveState {
        var v = volume("Footage", path: NSHomeDirectory() + "/Movies/Footage")
        v.isFolder = true
        v.isInternal = true
        v.free = 180_200_000_000
        return DriveState(volume: v, ledger: Ledger(driveRoot: "/tmp/demo-ssd-none", mount: MountAnchor(path: "/tmp")), setup: nil)
    }

    /// Where copies go, as setup opens it: what's ticked is what it would tick, unless `choice` was picked.
    private struct FirstPage: View {
        @State private var choice: DriveState?
        @State private var folder: DriveState?
        @State private var touched: Bool
        init(choice: DriveState? = nil) {
            _choice = State(initialValue: choice)
            _folder = State(initialValue: choice?.volume.isFolder == true ? choice : nil)
            _touched = State(initialValue: choice != nil)
        }
        var body: some View { WhereCopiesGo(choice: $choice, folder: $folder, touched: $touched, close: {}) { _ in } }
    }

    private static func drive(_ model: AppModel) -> DriveState {
        let d = DriveState(volume: volume("Field SSD", path: "/tmp/demo-ssd"), ledger: Ledger(driveRoot: "/tmp/demo-ssd-none", mount: MountAnchor(path: "/tmp")), setup: sampleSetup())
        var e: [DriveEntry] = []
        for p in ["Clients", "Clients/Lantern Bakery Co.", "Clients/Tidemark Rowing Club",
                  "Clients/Lantern Bakery Co./02.09.26 Launch", "Clients/Lantern Bakery Co./02.09.26 Launch/Footage",
                  "Clients/Tidemark Rowing Club/19.10.26 Pool", "Clients/Tidemark Rowing Club/19.10.26 Pool/Footage"] {
            e.append(DriveEntry(path: p, isDir: true, size: 0, mtime: 0))
        }
        d.install(index: DriveIndex(entries: e))
        d.clients = [ClientFolder(name: "Tidemark Rowing Club", path: "Clients/Tidemark Rowing Club", lastShoot: CalendarDay(year: 2026, month: 10, day: 19)),
                     ClientFolder(name: "Lantern Bakery Co.", path: "Clients/Lantern Bakery Co.", lastShoot: CalendarDay(year: 2026, month: 9, day: 2))]
        d.foldersRead = 212
        model.drives = [d]
        model.workingDrive = d
        stagedDrive = d
        return d
    }

    private static let day = CalendarDay(year: 2026, month: 10, day: 22)
    private static let bytes: UInt64 = 61_200_000_000
    private static let mp4s = ClipCheckReport(counts: [ClipCheckCount(kind: .index, format: "MP4", checked: 148, unconfirmed: 0)])
    private static let home = "Clients/Lantern Bakery Co./22.10.26 Spring menu/Footage/FX3/A082"

    private static func card(_ files: Int = 148, size: UInt64 = 61_200_000_000, verified: Int = 0, day: CalendarDay? = nil,
                             phase: CardSession.Phase, name: String = "A082", read: Bool = true) -> CardSession {
        let c = CardSession(volume: volume(name, path: "/tmp/demo-\(name)"))
        let f = (0..<files).map { CardFile(relPath: String(format: "M4ROOT/CLIP/C%04d.MP4", $0 + 1), size: size / UInt64(max(files, 1)), mtime: 0, kind: .video) }
        if read {
            var quick: [String: String] = [:]
            for x in f { quick[x.relPath] = "0" }
            c.read = CardRead(listing: CardListing(root: "/tmp/demo-card", files: f, dirs: [], errors: []), quick: quick, unreadable: [])
        }
        for x in f.prefix(verified) { c.states[x.relPath] = .verified(drivePath: "x", hash: "0", bytes: x.size) }
        let id = CameraIdentity(family: .sony, make: "Sony", model: "ILME-FX3", displayModel: "FX3", serial: "0000001", bodyKey: "0000001")
        c.probe = ProbeResult(cameras: [CameraOnCard(identity: id, clipCount: files)], reel: name == "A082" ? "A082" : nil,
                              captureDays: [CaptureDay(day: day ?? DemoRenderer.day, fileCount: files, source: .cameraMetadata)], hasVideo: true, clipChecks: mp4s)
        c.phase = phase
        c.provedOn = stagedDrive
        return c
    }

    private static func named(_ c: CardSession) -> CardSession {
        c.shootLabel = "Lantern Bakery Co. / 22.10.26 Spring menu"
        c.pendingDestination = Destination(footageRoot: home)
        c.destinationPath = home
        c.destinationDrive = stagedDrive?.volume.key
        return c
    }

    private static func draft(_ c: CardSession, client: String, shoot: String, date: CalendarDay? = nil) -> CardSession {
        c.draft.client = client
        c.draft.shootName = shoot
        c.draft.date = (date ?? DemoRenderer.day).date()
        c.draft.cameraFolder = "FX3"
        c.draft.prefilled = true
        return c
    }

    private static func copying() -> CardSession {
        let c = named(card(phase: .copying))
        c.liveBytes = 21_400_000_000
        c.startedAt = Date().addingTimeInterval(-90)
        c.progress = IngestProgress(phase: .copying, fileIndex: 53, fileCount: 148, verifiedFiles: 52, bytesCopied: 21_400_000_000, bytesTotal: bytes, currentName: "C0053.MP4")
        return c
    }

    private static func safe() -> CardSession {
        let c = named(card(verified: 148, phase: .finished))
        c.verdict = .safe
        return c
    }

    private static func hold(_ issue: CardIssue) -> CardSession {
        let c = named(card(verified: 148, phase: .finished))
        c.verdict = .hold([issue])
        c.issues = [issue]
        return c
    }

    private static func failed() -> CardSession {
        let c = named(card(verified: 147, phase: .ready))
        if let f = c.read?.listing.files.last { c.states[f.relPath] = .failed("the copy didn't match the card") }
        c.verdict = .notSafe(remaining: 1, total: 148, reasons: ["C0148.MP4: the copy didn't match the card"])
        return c
    }

    /// The widget as it stands on screen: rounded, with its hairline, on a quiet ground.
    private struct Widget<Content: View>: View {
        let dark: Bool
        @ViewBuilder var content: Content
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Grid.radius, style: .continuous)
            content.clipShape(shape).overlay(shape.strokeBorder(Color.line, lineWidth: 0.5))
                .padding(14).background(dark ? Color(white: 0.16) : Color(red: 0.87, green: 0.89, blue: 0.92))
        }
    }

    static func save<V: View>(_ view: V, _ name: String, _ dir: String, model: AppModel, dark: Bool = true) {
        guard let png = pixels(view, model: model, dark: dark) else { return }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        print(name)
    }

    /// Settles the view, measures it, and draws it. Offscreen, so controls look inactive.
    static func pixels<V: View>(_ view: V, model: AppModel, dark: Bool = true, ui: PanelUI? = nil, clear: Bool = false) -> Data? {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view.environment(model).environment(ui ?? PanelUI()).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = host.appearance
        w.isOpaque = !clear
        w.backgroundColor = clear ? .clear : NSColor(Color.surface)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        var size = host.fittingSize
        for _ in 0..<3 {
            w.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            size = host.fittingSize
        }
        return grab(host).flatMap(png)
    }

    private static func grab(_ host: NSView) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = host.bounds.size     // 2x, whatever the screen the render happens to run on
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The window draws in the display's colour space. A PNG in that space would read as a different green.
    private static func png(_ rep: NSBitmapImageRep) -> Data? {
        (rep.converting(to: .sRGB, renderingIntent: .perceptual) ?? rep).representation(using: .png, properties: [:])
    }

    static func run(to dir: String) {
        if CommandLine.arguments.contains("--media") { media(to: dir); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Motion.off = true
        let model = AppModel()
        model.isDemo = true
        let d = drive(model)
        let setup = d.setup!

        func both(_ name: String, _ body: () -> Void) {
            for dark in [false, true] {
                body()
                save(Widget(dark: dark) { PanelView() }, name + (dark ? "-dark" : ""), dir, model: model, dark: dark)
            }
            model.cards = []
            model.maybeCards = []
            model.unreadable = []
        }
        func state(_ name: String, _ make: @escaping () -> CardSession) { both(name) { model.cards = [make()] } }

        // The main path
        both("idle") {}
        state("reading") { card(phase: .reading(done: 61, total: 148), read: false) }
        state("comparing") { let c = card(phase: .reading(done: 148, total: 148)); c.isMatching = true; return c }
        state("dont-format") { let c = draft(card(phase: .ready), client: "", shoot: ""); c.verdict = .notSafe(remaining: 148, total: 148, reasons: []); return c }
        state("naming") { draft(card(phase: .ready), client: "Lantern Bakery Co.", shoot: "Spring menu") }
        state("copying", copying)
        state("failed", failed)
        state("safe", safe)
        state("ejected") { let c = safe(); c.ejected = true; return c }

        // On the way there
        state("proving") {
            let c = card(phase: .checking(done: 12, total: 30))
            c.liveChecked = 5_000_000_000
            c.checkBytes = 12_500_000_000
            c.checkStarted = Date().addingTimeInterval(-6)
            return c
        }
        state("queued") { named(card(phase: .queued)) }
        state("finishing") {
            let c = named(card(phase: .copying))
            c.liveBytes = bytes
            c.progress = IngestProgress(phase: .finishing, fileIndex: 148, fileCount: 148, verifiedFiles: 148, bytesCopied: bytes, bytesTotal: bytes, currentName: "")
            return c
        }
        state("stopped") {
            let c = named(card(verified: 52, phase: .stopped))
            c.verdict = .notSafe(remaining: 96, total: 148, reasons: [])
            return c
        }

        // Already on the drive, untouched by anyone
        state("already-on-drive") {
            let c = card(verified: 148, phase: .finished)
            c.verdict = .safe
            c.existingHome = "Clients/Tidemark Rowing Club/19.10.26 Pool/Footage/FX3/A082"
            return c
        }
        state("recognised-card") {
            let c = draft(card(verified: 90, phase: .ready), client: "", shoot: "")
            c.existingHome = "Clients/Tidemark Rowing Club/19.10.26 Pool/Footage/FX3/A082"
            return c
        }

        // Things that go wrong, on the line they went wrong on
        state("needs-a-look") { hold(CardIssue(severity: .hold, code: "video.no-index", message: "C0087.MP4 has no index, probably from a recording cut short.", paths: ["M4ROOT/CLIP/C0087.MP4"])) }
        state("card-pulled") {
            let c = named(card(verified: 52, phase: .stopped))
            c.error = "A082 was removed while copying. Nothing already checked is lost: put it back in to finish."
            c.volumeGone = true
            return c
        }
        state("drive-unplugged") {
            let c = named(card(verified: 52, phase: .stopped))
            c.error = "Field SSD was unplugged. Plug it back in to finish."
            return c
        }
        state("not-enough-room") {
            let c = draft(card(phase: .ready), client: "Lantern Bakery Co.", shoot: "Spring menu")
            c.error = "Not enough room: this needs 61.5 GB and only 40.2 GB is free."
            return c
        }
        state("card-changed") {
            let c = named(card(verified: 148, phase: .ready))
            c.verdict = .notSafe(remaining: 0, total: 148, reasons: ["The card changed while it was being checked."])
            return c
        }
        state("wont-open") {
            let c = card(phase: .ready)
            c.read?.unreadable = [ListingError(path: "M4ROOT/CLIP/C0007.MP4", reason: "listed on the card but it won't open")]
            c.verdict = .notSafe(remaining: 148, total: 148, reasons: ["x"])
            return c
        }
        state("eject-blocked") {
            let c = safe()
            c.ejectError = "Premiere Pro is using this card. Close it and try again."
            return c
        }
        state("weak-drive") { hold(CardIssue(severity: .hold, code: "drive.weak-verify", message: "This drive couldn't confirm it has all of this copy, even though it matched when read. Check the footage plays before formatting.")) }
        state("red-part-missing") {
            let c = hold(CardIssue(severity: .hold, code: "red.missing-part", message: "RED clip A001_C004 is missing part 003, so it would play short.", paths: []))
            c.probe.clipChecks = ClipCheckReport(counts: [ClipCheckCount(kind: .redParts, format: "R3D", checked: 148, unconfirmed: 0)])
            return c
        }

        // The honest last line
        state("clips-red") {
            let c = safe()
            c.probe.clipChecks = ClipCheckReport(counts: [ClipCheckCount(kind: .redParts, format: "R3D", checked: 148, unconfirmed: 0)])
            return c
        }
        state("clips-not-checked") {
            let c = safe()
            c.probe.clipChecks = ClipCheckReport(unchecked: ["MTS"])
            return c
        }

        // Naming details
        state("client-completing") { draft(card(phase: .ready), client: "Lan", shoot: "") }
        state("clock-wrong") { draft(card(99, size: 24_000_000_000, day: CalendarDay(year: 2026, month: 1, day: 20), phase: .ready), client: "Lantern Bakery Co.", shoot: "Lobby", date: CalendarDay(year: 2026, month: 1, day: 20)) }
        state("near-match") { draft(card(phase: .ready), client: "Lanturn Bakry Co.", shoot: "Spring menu") }

        // Without a working drive
        let working = model.workingDrive
        let unset = DriveState(volume: volume("Field SSD", path: "/tmp/demo-ssdb"), ledger: Ledger(driveRoot: "/tmp/demo-ssd-none"), setup: nil)
        model.workingDrive = nil
        model.drives = []
        state("no-drive") { let c = card(phase: .ready); c.verdict = .notSafe(remaining: 148, total: 148, reasons: []); return c }
        both("idle-no-drive") {}
        model.drives = [unset]
        state("drive-not-chosen") { let c = card(phase: .ready); c.verdict = .notSafe(remaining: 148, total: 148, reasons: []); return c }
        model.workingDrive = unset
        state("drive-not-set-up") { let c = card(phase: .ready); c.verdict = .notSafe(remaining: 148, total: 148, reasons: []); return c }
        both("idle-not-set-up") {}
        model.drives = [d]
        model.workingDrive = working

        // Other volumes
        both("maybe-card") { model.maybeCards = [(volume("KINGSTON", path: "/tmp/demo-k"), "It holds BRAW files but no camera folders.")] }
        both("unreadable") { model.unreadable = [volume("Card B", path: "/tmp/demo-b")] }
        state("empty") { let c = card(0, size: 0, phase: .finished); c.verdict = .empty; return c }

        // Several cards, worst first
        both("two-cards") {
            let a = safe()
            let b = card(96, size: 31_200_000_000, phase: .ready, name: "A083")
            b.verdict = .notSafe(remaining: 96, total: 96, reasons: [])
            model.cards = [a, b]
        }

        // First launch, in the widget
        model.cameraMemory = ["0000001": CameraMemory(folder: "FX3", displayName: "FX3", serialTail: "…0001")]
        let empty = DriveState(volume: volume("Field SSD", path: "/tmp/demo-ssdc"), ledger: Ledger(driveRoot: "/tmp/demo-ssd-none"), setup: nil)
        empty.foldersRead = 3
        for dark in [false, true] {
            let s = dark ? "-dark" : ""
            func setupPage<V: View>(_ v: V, _ name: String) {
                save(Widget(dark: dark) { VStack(spacing: 0) { v }.frame(width: Grid.width).background(Color.surface).foregroundStyle(Color.ink) }, name + s, dir, model: model, dark: dark)
            }
            setupPage(SetupView(drive: d, learned: setup, close: {}, changeDrive: {}), "first-run-layout")
            setupPage(SetupView(drive: empty, learned: nil) {}, "first-run-empty-drive")
            setupPage(ReadingDrive(drive: d) {}, "reading-drive")
            let drives = model.drives
            model.drives = []
            setupPage(FirstPage(), "first-run-no-drive")
            model.drives = [d]
            setupPage(FirstPage(), "first-run")
            let archive = DriveState(volume: volume("Archive", path: "/tmp/demo-archive", total: 4_000_000_000_000), ledger: Ledger(driveRoot: "/tmp/demo-ssd-none"), setup: nil)
            model.drives = [d, archive]
            setupPage(FirstPage(), "first-run-two-drives")
            let footage = folder()
            model.drives = [d, archive, footage]
            setupPage(FirstPage(choice: footage), "first-run-folder")
            setupPage(SetupView(drive: footage, learned: nil, close: {}, changeDrive: {}), "first-run-folder-layout")
            model.drives = drives
            setupPage(SetupEditor(setup: .constant(setup)) {}, "setup-editor")
        }

        // Behind the one quiet control
        model.history = [
            HistoryEntry(id: "1", date: Date(timeIntervalSince1970: 1_792_400_000), cardName: "A081", camera: "FX3", driveName: "Field SSD", path: "/tmp/Clients/Tidemark Rowing Club/19.10.26 Pool/Footage/FX3/A081", files: 96, bytes: 31_200_000_000, outcome: "Safe to format"),
            HistoryEntry(id: "2", date: Date(timeIntervalSince1970: 1_792_400_000), cardName: "A080", camera: "FX3", driveName: "Field SSD", path: "/tmp/Clients/Tidemark Rowing Club/19.10.26 Pool/Footage/FX3/A080", files: 148, bytes: bytes, outcome: "Copied, needs a look"),
            HistoryEntry(id: "3", date: Date(timeIntervalSince1970: 1_787_000_000), cardName: "A076", camera: nil, driveName: "Field SSD", path: "/tmp/Clients/Lantern Bakery Co./02.09.26 Launch/Footage/A076", files: 40, bytes: 20_000_000_000, outcome: "Not finished"),
        ]
        model.cameraMemory = ["0000001": CameraMemory(folder: "FX3", clockOffsetDays: 3, displayName: "FX3", serialTail: "…0001"),
                              "1": CameraMemory(folder: "B Cam", displayName: "A7S III", serialTail: "…0192")]
        let plugged = model.drives
        model.drives = plugged + [folder()]
        defer { model.drives = plugged }
        for dark in [false, true] {
            func page(_ name: String, _ set: (PanelUI) -> Void) {
                let ui = PanelUI()
                set(ui)
                guard let png = pixels(Widget(dark: dark) { PanelView() }, model: model, dark: dark, ui: ui) else { return }
                try? png.write(to: URL(fileURLWithPath: dir + "/" + name + (dark ? "-dark" : "") + ".png"))
                print(name)
            }
            for p in LibraryView.Page.allCases { page("library-" + p.rawValue.lowercased()) { $0.page = p } }
            page("report-a-bug") { $0.feedback = .bug }
            page("suggest-a-feature") { $0.feedback = .feature }
        }

        // The menu bar, without opening anything
        for dark in [false, true] { saveMenuBar(dir, model: model, dark: dark) }
        NSApp.terminate(nil)
    }

    private static func saveMenuBar(_ dir: String, model: AppModel, dark: Bool) {
        func menu(_ cards: [CardSession], maybe: Bool = false, locked: Bool = false) -> MenuBarState {
            model.cards = cards
            model.maybeCards = maybe ? [(volume("KINGSTON", path: "/tmp/k"), "x")] : []
            model.unreadable = locked ? [volume("Card B", path: "/tmp/b")] : []
            defer { model.cards = []; model.maybeCards = []; model.unreadable = [] }
            return MenuBarState.make(model)
        }
        func left(_ n: Int) -> CardSession {
            let c = copying()
            for f in (c.read?.listing.files ?? []).prefix(148 - n) { c.states[f.relPath] = .verified(drivePath: "x", hash: "0", bytes: f.size) }
            c.progress?.verifiedFiles = 0
            return c
        }
        let pulled = named(card(verified: 52, phase: .stopped))
        pulled.volumeGone = true
        pulled.error = "x"
        let list: [(String, MenuBarState)] = [
            ("No card", menu([])),
            ("Not checked yet", menu([card(phase: .reading(done: 3, total: 9), read: false)])),
            ("Don't format", menu([{ let c = card(phase: .ready); c.verdict = .notSafe(remaining: 148, total: 148, reasons: []); return c }()])),
            ("Don't format, copying", menu([left(96)])),
            ("Don't format, checking", menu([card(phase: .checking(done: 3, total: 9))])),
            ("Safe", menu([safe()])),
            ("Look before you format", menu([hold(CardIssue(severity: .hold, code: "x", message: "x"))])),
            ("Failed", menu([failed()])),
            ("Stopped", menu([named(card(verified: 52, phase: .stopped))])),
            ("Card pulled", menu([pulled])),
            ("Two cards", menu([safe(), { let c = card(phase: .ready, name: "A083"); c.verdict = .notSafe(remaining: 148, total: 148, reasons: []); return c }()])),
            ("A volume to ask about", menu([], maybe: true)),
            ("A volume it can't read", menu([], locked: true)),
        ]
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).font(.small12).foregroundStyle(Color.ink2).frame(width: 170, alignment: .leading)
                    Image(nsImage: MenuBarArt.image(for: row.1)).renderingMode(.template).foregroundStyle(Color.ink)
                    Spacer()
                }
                .frame(height: 30)
                .padding(.horizontal, 12)
                .background(Color.foot)
            }
        }
        .frame(width: 420)
        save(sheet, "menu-bar" + (dark ? "-dark" : ""), dir, model: model, dark: dark)
    }

    // MARK: The README's pictures, from scripts/render-media.sh

    /// The widget as `StatusBar` hangs it, with the same edge and shadow. `cacheDisplay` draws a shadow's offset upside down,
    /// so here `y` is negative to fall where it falls on screen.
    private struct Hung: View {
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Grid.radius, style: .continuous)
            PanelView().clipShape(shape).overlay(shape.strokeBorder(Color.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 3, y: -1)
                .shadow(color: .black.opacity(0.2), radius: 22, y: -12)
        }
    }

    /// A slim piece of menu bar with the real mark in it. The widget hangs as `WidgetSpot` hangs it: level with the item's
    /// right edge, 6 pt below it, there while a card is in or it's in use, and with no animation of its own.
    private struct Stage: View {
        @Environment(AppModel.self) private var model
        @Environment(PanelUI.self) private var ui
        let size: CGSize

        var body: some View {
            let open = !model.cards.isEmpty || ui.isKey
            let bar = RoundedRectangle(cornerRadius: 9, style: .continuous)
            VStack(alignment: .trailing, spacing: 6) {
                Image(nsImage: MenuBarArt.image(for: MenuBarState.make(model))).renderingMode(.template).foregroundStyle(Color.ink)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.ink.opacity(open ? 0.1 : 0)))
                    .padding(.trailing, 20).frame(width: 360, height: 26, alignment: .trailing)
                    .background(bar.fill(Color.foot).overlay(bar.strokeBorder(Color.line, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: -1).shadow(color: .black.opacity(0.1), radius: 8, y: -3))
                    .padding(.trailing, -20).zIndex(1)     // the menu bar stays above the widget's shadow
                Hung().opacity(open ? 1 : 0)
            }
            .padding(.top, 12).padding(.trailing, 40)
            .frame(width: size.width, height: size.height, alignment: .topTrailing)
        }
    }

    /// A copy `files` files in, proved one at a time in card order as the engine reports it, at a steady staged speed.
    private static func copied(_ c: CardSession, _ files: Int) {
        let size = bytes / 148, done = UInt64(files) * size
        c.liveBytes = files == 148 ? c.totalBytes : done + size / 2
        c.liveChecked = done
        c.startedAt = Date().addingTimeInterval(-Double(c.liveBytes + c.liveChecked) / 640e6)
        c.progress = IngestProgress(phase: .copying, fileIndex: files + 1, fileCount: 148, verifiedFiles: files, bytesCopied: c.liveBytes, bytesTotal: bytes, currentName: "")
    }

    private static func shorter(_ c: CardSession) -> CardSession {
        if c.shootLabel != nil { c.shootLabel = "Lantern Bakery Co. / 22.10.26 Menu" }      // fits the line beside Show in Finder
        return c
    }

    /// Stills on nothing, then the card's whole run filmed as it happens: SwiftUI's own animations can't be stepped by hand.
    private static func media(to dir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = AppModel()
        model.isDemo = true
        _ = drive(model)

        Motion.off = true
        func still(_ name: String, dark: Bool = false, _ make: () -> CardSession) {
            model.cards = [shorter(make())]
            let view = Hung().padding(EdgeInsets(top: 28, leading: 40, bottom: 56, trailing: 40))
            try? pixels(view, model: model, dark: dark, clear: true)?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        still("widget-reading") { card(phase: .reading(done: 61, total: 148), read: false) }
        still("widget-copying") { let c = named(card(phase: .copying)); copied(c, 52); return c }
        still("widget-safe", safe)
        still("widget-safe-dark", dark: true, safe)
        model.cards = []
        Motion.off = false

        let c = card(phase: .reading(done: 0, total: 148), read: false)
        let listing = card(phase: .ready).read
        func beat(_ t: Double) {
            switch t {
            case ..<0.8: break
            case ..<1.9:
                if model.cards.isEmpty { model.cards = [c] }
                c.phase = .reading(done: Int((t - 0.8) / 1.1 * 148), total: 148)
            case ..<2.55:
                c.read = listing
                c.isMatching = true
                c.phase = .reading(done: 148, total: 148)
            case ..<6.75:
                if c.phase != .copying { c.isMatching = false; c.phase = .copying; _ = shorter(named(c)) }
                copied(c, Int((t - 2.55) / 4.2 * 148))     // lands on 96 left, the word the README quotes
            case ..<7.5:
                c.liveBytes = c.totalBytes
                c.progress = IngestProgress(phase: .finishing, fileIndex: 148, fileCount: 148, verifiedFiles: 148, bytesCopied: bytes, bytesTotal: bytes, currentName: "")
            default:
                guard c.phase != .finished else { return }
                for f in listing?.listing.files ?? [] { c.states[f.relPath] = .verified(drivePath: "x", hash: "0", bytes: f.size) }
                c.progress = nil
                c.phase = .finished
                c.verdict = .safe
            }
        }

        film("demo", height: 412, length: 11, model: model, ui: PanelUI(), to: dir, beat: beat)
        filmSetup(to: dir)
        NSApp.terminate(nil)
    }

    /// An invented drive for setup to read: two clients, most shoots built one way, the oldest few with a folder of their own.
    private static func inventedDrive() -> DriveIndex {
        let work = [("Lantern Bakery Co.", ["Launch", "Menu", "Kitchen", "Bakers"]), ("Tidemark Rowing Club", ["Pool", "Regatta", "Crew"])]
        var dirs = ["Clients"] + work.map { "Clients/" + $0.0 }
        for n in 0..<38 {
            let (client, names) = work[n % 2]
            let shoot = String(format: "Clients/%@/%02d.%02d.%02d %@", client, 1 + n * 3 % 27, 1 + n % 12, 23 + n / 12, names[n % names.count])
            dirs += [shoot] + ["Photo", "Photo/RAW", "Photo/Exports", n < 5 ? "Video" : "Footage", "Project"].map { shoot + "/" + $0 }
        }
        return DriveIndex(entries: dirs.map { DriveEntry(path: $0, isDir: true, size: 0, mtime: 0) })
    }

    /// The real setup and the real learner on that drive. A scan marked as running only waits, so nothing is ever read from a disk.
    private static func filmSetup(to dir: String) {
        let model = AppModel(), ui = PanelUI()
        model.isDemo = true
        let d = DriveState(volume: volume("Field SSD", path: "/tmp/demo-ssdc"), ledger: Ledger(driveRoot: "/tmp/demo-ssd-none"), setup: nil)
        d.isScanning = true
        model.drives = [d]
        let index = inventedDrive()
        film("setup", height: 432, length: 7.6, model: model, ui: ui, to: dir) { t in
            switch t {
            case ..<0.6: break
            case ..<2.4:
                if ui.setup == nil { ui.isKey = true; ui.setup = SetupRequest(drive: d) }
                d.foldersRead = Int((t - 0.6) / 1.8 * Double(index.folderCount))
            case ..<6:
                guard d.isScanning else { return }
                d.install(index: index)
                d.foldersRead = index.folderCount
                d.isScanning = false
                let waiting = d.scanWaiters
                d.scanWaiters = []
                waiting.forEach { $0() }
            default:
                guard ui.setup != nil else { return }      // Use This, without the write to the drive
                d.setup = LayoutLearner.learn(entries: index.entries)
                d.install(index: index)
                model.workingDrive = d
                ui.setup = nil
            }
        }
    }

    /// Films `beat` as it plays, into `frames-<name>`. `beat` is told the time in the steps the app reads its counters.
    private static func film(_ name: String, height: CGFloat, length: Double, model: AppModel, ui: PanelUI, to dir: String, beat: (Double) -> Void) {
        let frames = "\(dir)/frames-\(name)", size = CGSize(width: 400, height: height)
        try? FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: Stage(size: size).environment(model).environment(ui).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = host.appearance
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = host.appearance
        w.contentView = host

        let rate = 15.0, start = Date()
        var shots: [(at: Double, rep: NSBitmapImageRep)] = []
        var now = 0.0
        while now < length {
            beat((now / 0.15).rounded(.down) * 0.15)
            RunLoop.main.run(until: start.addingTimeInterval((now * rate + 1).rounded(.down) / rate))
            now = Date().timeIntervalSince(start)
            if let rep = grab(host) { shots.append((now, rep)) }
        }
        for (i, s) in shots.enumerated() {
            let ms = Int(((i + 1 < shots.count ? shots[i + 1].at : length) - s.at) * 1000)
            try? png(s.rep)?.write(to: URL(fileURLWithPath: frames + String(format: "/%04d-%d.png", i, max(ms, 1))))
        }
    }
}
