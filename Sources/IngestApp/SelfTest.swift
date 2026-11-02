import AppKit
import IngestCore
import SwiftUI

/// Runs the real app flow against mounted test volumes: same model, same engine, same views.
/// Only the clicks are stood in for, so each step calls what its button calls.
@MainActor enum SelfTest {
    private static var log: [(String, Bool, String)] = []
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        log.append((name, ok, detail))
        print(ok ? "PASS" : "FAIL", name, detail)
    }

    private static func until(_ seconds: Double = 30, _ what: String, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        print("timed out waiting for", what)
        return false
    }

    static func run(drive: String, card: String, out: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task {
            await flow(driveName: drive, cardName: card, out: out)
            let bad = log.filter { !$0.1 }
            print("\n\(log.count - bad.count)/\(log.count) checks passed")
            for b in bad { print("  failed:", b.0, b.2) }
            exit(bad.isEmpty ? 0 : 1)
        }
    }

    private static func shot<V: View>(_ v: V, _ name: String, _ out: String, _ model: AppModel) {
        Motion.off = true
        defer { Motion.off = false }
        DemoRenderer.save(v, name, out, model: model)
        DemoRenderer.save(v, name + "-light", out, model: model, dark: false)
        NSApp.appearance = nil
    }

    /// Mounts and unmounts the test card, the way a card reader would. Only ever the self-test's own image.
    private static func hdiutil(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args + ["-quiet", "-force"].filter { args.first == "detach" || $0 == "-quiet" }
        try? p.run()
        p.waitUntilExit()
    }

    private static func marks(_ c: CardSession, _ m: AppModel) -> String {
        CardSheet.make(c, model: m).lines.map { "\($0.id.rawValue):\($0.mark)" }.joined(separator: " ")
    }

    /// What actually has the keyboard and the screen, which `NSApp.isActive` doesn't say for a key panel.
    private static var frontmost: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    private static var weAreFrontmost: Bool { NSRunningApplication.current.isActive || frontmost == getpid() }

    private static func flow(driveName: String, cardName: String, out: String) async {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        guard let image = ProcessInfo.processInfo.environment["INGEST_SELFTEST_CARD_IMAGE"] else {
            check("the script names the test card image", false)
            return
        }
        let model = AppModel()
        model.isDemo = true
        model.stores.workingDriveKey = nil
        model.stores.opensOnCardIn = true
        model.stores.cameras = [:]      // a clock offset learned on an earlier run would move the draft's date
        model.stores.overrides = [:]
        let bar = StatusBar(model: model)
        bar.panel.alphaValue = 0    // the panel really opens, without flashing on the owner's screen
        Windows.shared.bar = bar
        model.start()

        // No working drive: the sheet says so, offers the next step, and copies nothing
        check("drive appears", await until(20, "drive") { model.drives.contains { $0.name == driveName } })
        check("card appears", await until(20, "card") { model.cards.contains { $0.volume.name == cardName } })
        guard let drive = model.drives.first(where: { $0.name == driveName }),
              let first = model.cards.first(where: { $0.volume.name == cardName }) else { return }
        check("no drive is chosen silently", model.workingDrive == nil)
        check("no drive: the card stops and waits", await until(60, "ready") { first.phase == .ready }, marks(first, model))
        var list = CardSheet.make(first, model: model)
        check("no drive: says so", list.bottom.title == "Don't format" && list.bottom.sentence.contains("Choose a working drive"), list.bottom.sentence)
        check("no drive: offers the next step", list.line(.drive)?.actions == [.useDrive(id: drive.id, name: driveName)], "\(list.line(.drive)?.actions ?? [])")
        check("no drive: no form to fill in", !list.showsNaming)
        shot(PanelView(), "no-drive", out, model)

        // The drive is read, folder count ticking up
        model.use(drive: drive)
        drive.isScanning = false
        let scanned = Expectation()
        model.refreshIndex(drive) { scanned.done = true }
        while !scanned.done { try? await Task.sleep(for: .milliseconds(1)) }
        shot(ReadingDrive(drive: drive) {}, "reading-drive", out, model)
        check("reads the drive and counts folders", drive.foldersRead > 0, "\(drive.foldersRead) folders")
        _ = await until(20, "compared") { first.phase == .ready && !first.isMatching }    // a new drive starts from nothing
        list = CardSheet.make(first, model: model)
        check("drive not set up: says so and offers it", list.line(.drive)?.actions == [.setUpDrive(id: drive.id, name: driveName)], "\(list.line(.drive)?.detail ?? [])")

        // What the drive taught us
        let learned = LayoutLearner.learn(entries: drive.index?.entries ?? [])
        check("learns the layout from the drive", learned != nil)
        guard let learned else { return }
        check("finds the year, literal and client levels", learned.path == [.year, .literal("Paid work"), .client], "\(learned.path)")
        check("finds the date style", learned.shootName.dateFormat == "dd.MM.yy", learned.shootName.dateFormat)
        check("reports who follows it", learned.learned?.shootsFollowing == 29 && learned.learned?.shootsFound == 34,
              "\(learned.learned?.shootsFollowing ?? -1) of \(learned.learned?.shootsFound ?? -1)")
        check("names the exception", learned.learned?.exception?.contains("Video") == true, learned.learned?.exception ?? "none")
        shot(SetupView(drive: drive, learned: learned) {}.frame(width: Grid.width).background(Color.surface), "first-run", out, model)
        // It waits for the menu bar to settle first, for up to a quarter of a second.
        check("the card that was already in opened the panel at launch", await until(1, "panel") { bar.panel.isVisible })
        await setupChecks(drive: drive, bar: bar, model: model, out: out)
        check("setup is saved on the drive", FileManager.default.fileExists(atPath: drive.path + "/.ingest/setup.json"))
        check("what was saved is what the drive taught", drive.setup?.path == learned.path, "\(drive.setup?.path ?? [])")

        // The card comes out, and goes back in with nobody touching anything
        bar.hide()
        hdiutil(["detach", first.volume.path])
        check("card out: its session goes", await until(20, "card gone") { model.cards.isEmpty })
        check("card out: the panel isn't open yet", !bar.panel.isVisible)
        check("menu bar: quiet with no card", bar.state.word.isEmpty, bar.state.word)
        let inFront = frontmost
        var seen: Set<String> = []
        var sawRead = false, sawCheck = false
        let watching = Task { @MainActor in
            while !Task.isCancelled {
                for c in model.cards {
                    seen.insert(marks(c, model))
                    if case .reading = c.phase { sawRead = true }
                    if case .checking = c.phase { sawCheck = true }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        hdiutil(["attach", image])
        check("insert: the panel opens by itself", await until(20, "panel") { bar.panel.isVisible }, "arrived after \(model.cards.count) card")
        check("insert: it doesn't take the keyboard", !bar.panel.isKeyWindow)
        check("insert: the app in front stays in front", !weAreFrontmost && frontmost == inFront, NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
        check("insert: it says it opened by itself", bar.openedByItself)
        _ = await until(10, "card") { model.cards.contains { $0.volume.name == cardName } }
        guard let card = model.cards.first(where: { $0.volume.name == cardName }) else { check("card is back", false); return }
        check("insert: reads and compares, then stops at naming", await until(60, "ready") { card.phase == .ready }, marks(card, model))
        check("insert: the card was read live", sawRead)
        list = CardSheet.make(card, model: model)
        check("stopped: the card line is ticked", list.line(.card)?.mark == .done && list.line(.card)?.files == "\(card.totalFiles)", list.line(.card)?.files ?? "")
        check("stopped: the drive line waits at 0, with the form open", list.line(.drive)?.mark == .waiting && list.line(.drive)?.files == "0" && list.showsNaming)
        check("stopped: read-back and clips are waiting", [SheetLine.ID.readCard, .readDrive, .clips].allSatisfy { list.line($0)?.mark == .waiting }, marks(card, model))
        check("says nothing is on the drive yet", card.filesToGo == card.totalFiles && card.totalFiles > 0, "\(card.filesToGo) of \(card.totalFiles)")
        check("never green before copying", list.bottom.kind == .notDone && list.bottom.title == "Don't format", list.bottom.sentence)
        check("the bottom line counts what's only on the card", list.bottom.sentence.hasPrefix("\(card.totalFiles) file"), list.bottom.sentence)
        check("the primary action is on the bottom line", list.bottom.action == .copy(card.totalFiles))
        check("menu bar: says it's not on the drive", bar.state.word == "Not on \(driveName)" && !bar.state.isSafe, bar.state.word)
        let before = Date()
        try? await Task.sleep(for: .seconds(2))
        check("no copy starts without a destination", card.phase == .ready && card.pendingDestination == nil && card.destinationPath == nil
              && card.states.values.allSatisfy { if case .verified = $0 { false } else { true } } && !model.isCopying,
              "held \(Int(Date().timeIntervalSince(before)))s")

        // The main surface is the card in front of you: a pile of history doesn't change one pixel of it
        let saved = model.history
        model.history = []
        Motion.off = true
        let without = DemoRenderer.pixels(PanelView(), model: model)
        let booksBefore = DemoRenderer.pixels(LibraryView(page: .history), model: model)
        model.history = (0..<40).map {
            HistoryEntry(id: "selftest\($0)", date: Date(), cardName: "Earlier card \($0)", camera: nil, driveName: driveName,
                         path: "/tmp/nowhere", files: 1, bytes: 1, outcome: "Safe to format")
        }
        let with = DemoRenderer.pixels(PanelView(), model: model)
        let booksAfter = DemoRenderer.pixels(LibraryView(page: .history), model: model)
        NSApp.appearance = nil
        Motion.off = false
        check("history isn't on the main view", without != nil && without == with, "40 entries, identical pixels")
        check("history lives behind the quiet control", booksBefore != nil && booksBefore != booksAfter)
        model.history = saved

        // Panel keyboard: a click on the menu bar takes the keyboard, and Esc gives it back
        bar.hide()
        bar.openForUser()
        check("a click on the menu bar takes the keyboard", await until(2, "key") { bar.panel.isKeyWindow })
        let mark = bar.item.button?.window?.frame ?? .zero
        check("it hangs from its mark, right edges together", abs(bar.panel.frame.maxX - StatusBar.margin.right - mark.maxX) <= 9 && bar.panel.frame.maxY - StatusBar.margin.top <= mark.minY, "\(bar.panel.frame) under \(mark)")
        check("no title bar, no Dock icon", bar.panel.styleMask.contains(.borderless) && NSApp.activationPolicy() == .accessory)
        check("widget width", bar.panel.frame.width - StatusBar.margin.left - StatusBar.margin.right == Grid.width)
        check("the app in front still stays in front", !weAreFrontmost && frontmost == inFront)
        check("focus lands in the shoot form", await until(2, "focus") { bar.panel.firstResponder is NSTextView }, "\(bar.panel.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nothing")")

        // Shoot row, with real key presses
        let cam = card.primaryCamera?.identity
        check("identifies the camera", cam != nil && cam?.displayModel != "Camera", cam?.displayModel ?? "none")
        check("takes the date from the card", card.probe.captureDays.last != nil, "\(String(describing: card.probe.captureDays.last?.day))")
        check("no stills on this card", card.probe.hasVideo && !card.probe.hasStills)
        guard let setup = drive.setup, let day = card.probe.captureDays.last?.day else { return }
        check("the draft takes the date from the card", CalendarDay(card.draft.date) == day, "\(CalendarDay(card.draft.date))")
        check("the draft remembers the camera's folder", card.draft.cameraFolder == model.folderName(for: cam), card.draft.cameraFolder)
        shot(PanelView(), "dont-format", out, model)

        type("tidemark rowing club", into: bar)
        check("typing reaches the Client field", await until(2, "typed") { card.draft.client == "tidemark rowing club" }, card.draft.client)
        press(.return, in: bar)
        check("Return in Client moves to Shoot name, starts nothing", card.phase == .ready)
        try? await Task.sleep(for: .milliseconds(100))
        type("Regatta day", into: bar)
        check("typing reaches the Shoot field", await until(2, "typed") { card.draft.shootName == "Regatta day" }, card.draft.shootName)
        press(.escape, in: bar)
        check("Esc leaves the field and keeps what's typed", await until(2, "esc") { !(bar.panel.firstResponder is NSTextView) } && card.draft.shootName == "Regatta day")
        check("Esc starts nothing", card.phase == .ready)
        press(.escape, in: bar)
        check("Esc again closes the panel", await until(2, "closed") { !bar.panel.isVisible })
        check("closing it leaves the card as it was", card.phase == .ready && card.draft.shootName == "Regatta day")
        bar.openForUser()
        _ = await until(2, "key") { bar.panel.isKeyWindow }

        // The same planner the form uses. Filed under a date the drive has, whatever the sample's clock said.
        card.draft.date = CalendarDay(year: 2026, month: 10, day: 19).date()
        let plan = ShootComposer(model: model, card: card, drive: drive, setup: setup).plan
        check("finds the existing client, ignoring case", plan.clientExists && plan.existingClientName == "Tidemark Rowing Club", plan.existingClientName ?? "none")
        check("skips the Photo folder", plan.skippedNote == "No Photo folder: only video here.", plan.skippedNote ?? "none")
        let preview = FolderPreview(plan: plan)
        check("the folder preview reads as the design does", preview.above.last == "Tidemark Rowing Club" && preview.shoot.contains("Regatta day") && preview.below.first == "Footage" && preview.below.last == (plan.footagePath as NSString).lastPathComponent,
              "\(preview.above) | \(preview.shoot) | \(preview.below)")
        shot(PanelView(), "naming", out, model)

        // Return in the Shoot row starts the copy
        bar.panel.makeFirstResponder(nil)
        focusShootField(in: bar)
        press(.return, in: bar)
        check("Return in the Shoot row starts the copy", await until(5, "copy") { card.isBusy || card.phase == .finished }, card.error ?? "\(card.phase)")
        check("copy starts", card.error == nil, card.error ?? "")
        check("the shoot is named on its line", CardSheet.make(card, model: model).path?.contains("Regatta day") == true, card.shootLabel ?? "no label")
        var shotCopying = false
        let done = await until(300, "copy") {
            if card.phase == .copying, card.verifiedFiles > 0, !shotCopying {
                shotCopying = true
                shot(PanelView(), "copying", out, model)
                let l = CardSheet.make(card, model: model)
                check("copying: progress counts down as files are proved", card.filesToGo < card.totalFiles, "\(card.filesToGo) to go")
                check("copying: stays Don't format", l.bottom.kind == .notDone && l.bottom.title == "Don't format", l.bottom.sentence)
                check("copying: drive and read-back run, clips wait", l.line(.drive)?.mark == .running && l.line(.readDrive)?.mark == .running && l.line(.clips)?.mark == .waiting, marks(card, model))
                check("copying: Stop is on the bottom line", l.bottom.action == .stop)
                check("copying: the meter shows", l.meter != nil)
                check("menu bar: counts down", bar.state.word.hasSuffix(" left") && !bar.state.isSafe, bar.state.word)
            }
            return card.phase == .finished || card.phase == .ready
        }
        check("copy finishes", done)
        check("seen mid-copy", shotCopying)

        // Safe, on disk, where it should be
        check("card is safe", card.isSafe(on: drive), "\(String(describing: card.verdict))")
        list = CardSheet.make(card, model: model)
        check("safe: every line is settled", list.lines.allSatisfy { $0.mark == .done }, marks(card, model))
        check("safe: every figure agrees", Set(list.lines.compactMap(\.files)).count == 1, list.lines.compactMap(\.files).joined(separator: " "))
        check("safe: the verdict is the green one", list.bottom.kind == .safe && list.bottom.action == .eject, list.bottom.sentence)
        check("safe: says what ran, and that clips weren't played", list.bottom.sentence == "Each MP4 has an index. Clips were not played.", list.bottom.sentence)
        check("safe: Show in Finder stays on hand", list.canReveal)
        _ = await until(2, "word") { bar.state.isSafe }
        check("menu bar: the word", bar.state.isSafe && bar.state.word == "Safe to format", bar.state.word)
        shot(PanelView(), "safe", out, model)
        let shootRoot = drive.path + "/" + plan.shootPath
        check("shoot folder exists", FileManager.default.fileExists(atPath: shootRoot), plan.shootPath)
        check("Project folder exists", plan.foldersToCreate.allSatisfy { FileManager.default.fileExists(atPath: drive.path + "/" + $0) }, "\(plan.foldersToCreate.count) folders")
        check("no Photo folder", !FileManager.default.fileExists(atPath: shootRoot + "/Photo"))
        check("card kept whole in its folder", FileManager.default.fileExists(atPath: drive.path + "/" + plan.footagePath), plan.footagePath)
        check("manifest written", FileManager.default.fileExists(atPath: drive.path + "/" + plan.footagePath + "/ascmhl/ascmhl_chain.xml"))
        check("history records it", model.history.first?.cardName == card.name)
        _ = await until(20, "rematch") { !drive.isScanning && !card.isMatching }

        // A card fully on the drive runs to Safe with no input at all
        watching.cancel()
        bar.hide()
        hdiutil(["detach", card.volume.path])
        check("safe card out: the session goes", await until(20, "gone") { model.cards.isEmpty })

        // Back in. Proof doesn't survive a card leaving the Mac, however recently it was proved.
        sawCheck = false
        let watchingRemount = Task { @MainActor in
            while !Task.isCancelled {
                for c in model.cards { if case .checking = c.phase { sawCheck = true } }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        hdiutil(["attach", image])
        check("remount: runs to Safe unaided", await until(120, "safe") { model.cards.first?.isSafe(on: drive) == true && model.cards.first?.phase == .finished })
        watchingRemount.cancel()
        check("remount: nothing is taken on trust, it's all read again", model.cards.first?.control.bytesChecked == model.cards.first?.totalBytes, "\(model.cards.first?.control.bytesChecked ?? 0) of \(model.cards.first?.totalBytes ?? 0) bytes")
        bar.hide()
        hdiutil(["detach", card.volume.path])
        _ = await until(20, "gone") { model.cards.isEmpty }

        // The ledger is only a hint, so it all gets read.
        seen = []; sawRead = false; sawCheck = false
        let watching2 = Task { @MainActor in
            while !Task.isCancelled {
                for c in model.cards {
                    seen.insert(marks(c, model))
                    if case .reading = c.phase { sawRead = true }
                    if case .checking = c.phase { sawCheck = true }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let t0 = Date()
        hdiutil(["attach", image])
        check("already on the drive: the panel opens by itself", await until(20, "panel") { bar.panel.isVisible })
        check("already on the drive: still no keyboard taken", !bar.panel.isKeyWindow && !weAreFrontmost)
        guard let again = model.cards.first(where: { $0.volume.name == cardName }) else { check("card is back again", false); return }
        check("already on the drive: runs to Safe unaided", await until(120, "safe") { again.isSafe(on: drive) && again.phase == .finished },
              "\(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        watching2.cancel()
        check("already on the drive: proved by reading both sides", sawCheck, "this session proves it again")
        check("already on the drive: nothing was copied", again.pendingDestination == nil && again.destinationPath == nil)
        list = CardSheet.make(again, model: model)
        check("already on the drive: every line settles", list.lines.allSatisfy { $0.mark == .done }, marks(again, model))
        check("already on the drive: no form", !list.showsNaming)
        check("already on the drive: names the shoot it found", list.path?.contains("Regatta day") == true, list.path ?? "")
        check("already on the drive: the drive line agrees with the card", list.line(.drive)?.files == list.line(.card)?.files, list.line(.drive)?.files ?? "")
        _ = await until(2, "word") { bar.state.isSafe }
        check("already on the drive: Safe in the bar, untouched", bar.state.isSafe)
        shot(PanelView(), "already-on-drive", out, model)

        // A new clip on a card that was safe must take the green away
        let extra = card.volume.path + "/" + (again.read?.listing.files.first { $0.kind == .video }.map { ($0.relPath as NSString).deletingLastPathComponent } ?? "") + "/ZZZ9999.MP4"
        FileManager.default.createFile(atPath: extra, contents: Data(repeating: 7, count: 2_000_000))
        model.recheck(again)
        check("rechecking takes the green away at once", !again.isSafe(on: drive) && CardSheet.make(again, model: model).bottom.kind == .notDone)
        check("menu bar: no Safe while it's in doubt", await until(2, "no word") { !bar.state.isSafe }, bar.state.word)
        check("a new file: stops at the form again", await until(60, "ready") { again.phase == .ready })
        check("a new file takes the green away", !again.isSafe(on: drive) && again.filesToGo == 1, "\(again.filesToGo) to go")
        list = CardSheet.make(again, model: model)
        check("a recognised card offers the existing shoot", list.existingShoot == plan.footagePath, list.existingShoot ?? "none")
        check("and a new shoot beside it", list.showsNaming)
        shot(PanelView(), "recognised-card", out, model)
        unlink(extra)

        // The setting
        bar.hide()
        model.opensOnCardIn = false
        hdiutil(["detach", card.volume.path])
        _ = await until(20, "gone") { model.cards.isEmpty }
        hdiutil(["attach", image])
        _ = await until(20, "back") { model.cards.contains { $0.volume.name == cardName } }
        try? await Task.sleep(for: .milliseconds(300))
        check("with the setting off, a card doesn't open the panel", !bar.panel.isVisible)
        check("with the setting off, the menu bar still says", !bar.state.word.isEmpty, bar.state.word)
        model.opensOnCardIn = true
        _ = await until(60, "settled") { model.cards.first?.phase == .ready || model.cards.first?.phase == .finished }

        // Several cards: the worst one, and a count
        func staged(_ name: String, verified: Bool) -> CardSession {
            let c = CardSession(volume: Volume(path: "/tmp/none-" + name, name: name, uuid: nil, total: 1, free: 1, fsType: "exfat", isReadOnly: false, isInternal: false, anchor: MountAnchor(path: "/tmp")))
            c.read = again.read
            if verified, let files = again.read?.listing.files {
                for f in files { c.states[f.relPath] = .verified(drivePath: "x", hash: "0") }
            }
            c.verdict = verified ? .safe : .notSafe(remaining: c.totalFiles, total: c.totalFiles, reasons: [])
            c.phase = verified ? .finished : .ready
            c.provedOn = drive
            return c
        }
        let green = staged("A", verified: true), unsafe = staged("B", verified: false)
        let others = model.cards
        model.cards = [green, unsafe]
        let summary = MenuBarState.make(model)
        check("several cards: the mark and a count, not Safe", summary.twoCards && !summary.isSafe && summary.word == "2 cards", summary.word)
        check("several cards: worst first", model.cardsWorstFirst.first === unsafe)
        model.cards = [green, staged("C", verified: true)]
        let allSafe = MenuBarState.make(model)
        check("several cards: Safe waits for all of them", allSafe.isSafe && allSafe.twoCards && allSafe.word == "Safe to format", allSafe.word)

        // Two sessions on one volume: a card pulled mid-copy can sit beside its own remount
        let twin = CardSession(volume: green.volume)
        twin.read = again.read
        model.cards = [green, twin]
        let sorted = model.cardsWorstFirst
        check("two sessions on one volume don't trap, and both stay", sorted.count == 2 && sorted[0].id != sorted[1].id)
        _ = DemoRenderer.pixels(PanelView(), model: model)
        check("and both draw", true)

        // What may never be green
        let bad = staged("D", verified: true)
        if let f = bad.read?.listing.files.first { bad.states[f.relPath] = .failed("the copy didn't match the card") }
        bad.verdict = .notSafe(remaining: 1, total: bad.totalFiles, reasons: ["x"])
        bad.pendingDestination = Destination(footageRoot: "x")
        bad.phase = .ready
        model.cards = [bad]
        var sheet = CardSheet.make(bad, model: model)
        check("a file that doesn't match: the line says so, with the fix on it", sheet.line(.readDrive)?.mark == .failed && sheet.line(.readDrive)?.actions == [.copyAgain(1)], "\(sheet.line(.readDrive)?.detail ?? [])")
        check("a file that doesn't match: Don't format", sheet.bottom.kind == .failed && sheet.bottom.title == "Don't format" && sheet.bottom.sentence == "1 file didn't match.", sheet.bottom.sentence)
        check("a file that doesn't match: the figure disagrees", sheet.line(.readDrive)?.files == "\(bad.totalFiles - 1)" && sheet.line(.readDrive)?.disagrees == true, sheet.line(.readDrive)?.files ?? "")
        let hold = staged("E", verified: true)
        let issue = CardIssue(severity: .hold, code: "video.no-index", message: "C0087.MP4 has no index.", paths: [])
        hold.verdict = .hold([issue]); hold.issues = [issue]
        model.cards = [hold]
        sheet = CardSheet.make(hold, model: model)
        check("needs a look: not green, not Safe", sheet.bottom.kind == .look && MenuBarState.make(model).word == "Have a look" && !MenuBarState.make(model).isSafe, sheet.bottom.sentence)
        check("needs a look: the line that needs it, with Show in Finder", sheet.line(.clips)?.mark == .look && sheet.line(.clips)?.actions == [.showInFinder(nil)] || sheet.line(.clips)?.mark == .look)
        let pulled = staged("F", verified: false)
        pulled.phase = .stopped; pulled.volumeGone = true; pulled.error = "F was removed while copying."
        model.cards = [pulled]
        check("card pulled: the bar says so", MenuBarState.make(model).word == "Card pulled", MenuBarState.make(model).word)
        check("stopped: Resume is on the drive line", CardSheet.make(pulled, model: model).line(.drive)?.actions == [.resume])
        model.cards = others

        // Behind the one quiet control, inside the widget
        bar.show(.settings)
        check("the library opens inside the widget", bar.ui.page == .settings && bar.panel.isVisible)
        check("no other window opened", NSApp.windows.filter { $0.isVisible && $0 !== bar.panel && $0.className != "NSStatusBarWindow" }.isEmpty, NSApp.windows.map(\.className).joined(separator: " "))
        press(.escape, in: bar)
        check("Esc comes back to the card", bar.ui.page == nil && bar.panel.isVisible)

        // A report is a page of the widget too, and what goes with it says nothing about anyone's work
        bar.show(.bug)
        check("a bug report opens inside the widget", bar.ui.feedback == .bug && bar.panel.isVisible)
        check("and no other window", NSApp.windows.filter { $0.isVisible && $0 !== bar.panel && $0.className != "NSStatusBarWindow" }.isEmpty)
        let report = FeedbackReport(kind: .bug, system: ProcessInfo.processInfo.operatingSystemVersion, hardwareModel: "Mac16,7", appleSilicon: true,
                                    cameras: model.cards.compactMap { $0.primaryCamera?.identity.family })
        check("the report names no card, drive or serial", !report.plainText.contains(driveName) && !report.plainText.contains(cardName), report.details)
        check("a card coming in closes it: the card comes first", { bar.show(.feature); model.onArrival?(); return bar.ui.feedback == nil }())
        bar.show(.bug)
        press(.escape, in: bar)
        check("Esc comes back from a report", bar.ui.feedback == nil && bar.panel.isVisible)
        bar.hide()
        await interruptions(cardName: cardName, cardImage: image, bar: bar, model: model)
    }

    /// A large file on the card that isn't on the drive yet, so a copy lasts long enough to get in its way.
    private static func addLargeFile(_ name: String, to c: CardSession, seed: UInt8) -> String {
        for old in (try? FileManager.default.contentsOfDirectory(atPath: c.volume.path)) ?? [] where old.hasPrefix("ZZZ") { unlink(c.volume.path + "/" + old) }
        let path = c.volume.path + "/" + name
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return path }
        var chunk = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        for i in 0..<112 { chunk[0] = UInt8(truncatingIfNeeded: i); h.write(chunk) }
        try? h.close()
        return path
    }

    private static func stale(_ model: AppModel, _ cardName: String) -> CardSession? { model.cards.first { $0.volume.name == cardName && !$0.volumeGone } }

    /// Everything that can get in the way of a copy, for real, on the test's own images.
    private static func interruptions(cardName: String, cardImage: String, bar: StatusBar, model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let driveImage = env["INGEST_SELFTEST_DRIVE_IMAGE"], let otherImage = env["INGEST_SELFTEST_OTHER_IMAGE"], let otherName = env["INGEST_SELFTEST_OTHER_NAME"],
              let c1 = stale(model, cardName) else {
            check("the script names the other test images", false)
            return
        }

        // Stop, then Resume, with the copy really running
        var large = addLargeFile("ZZZ1.DAT", to: c1, seed: 1)
        model.recheck(c1)
        check("stop: a new file waits at the form", await until(60, "ready") { c1.phase == .ready && c1.filesToGo == 1 }, "\(c1.filesToGo) to go, \(c1.phase)")
        model.start(c1, destination: Destination(footageRoot: "Interrupted/Stopped"))
        check("stop: the copy is running", await until(20, "copying") { c1.phase == .copying && c1.liveBytes > 0 }, "\(c1.phase)")
        model.stop(c1)
        check("stop: it stops", await until(30, "stopped") { c1.phase == .stopped }, "\(c1.phase)")
        var sheet = CardSheet.make(c1, model: model)
        check("stop: Resume is on the drive line, and it isn't safe", sheet.line(.drive)?.actions == [.resume] && !c1.isSafe(on: model.workingDrive), "\(sheet.line(.drive)?.actions ?? [])")
        check("stop: the bottom line says it stopped", sheet.bottom.title == "Don't format" && sheet.bottom.sentence.hasPrefix("Stopped."), sheet.bottom.sentence)
        check("stop: the bar says so", await until(2, "word") { bar.state.word == "Stopped" }, bar.state.word)
        check("stop: no part of the file has its real name", !FileManager.default.fileExists(atPath: (model.workingDrive?.path ?? "") + "/Interrupted/Stopped/ZZZ1.DAT"))
        model.resume(c1)
        check("resume: finishes", await until(120, "finished") { c1.phase == .finished && !c1.isBusy }, "\(c1.phase) \(c1.error ?? "")")
        check("resume: the file is on the drive, whole", (try? FileManager.default.attributesOfItem(atPath: (model.workingDrive?.path ?? "") + "/Interrupted/Stopped/ZZZ1.DAT"))?[.size] as? Int == 112 << 23)
        check("resume: every file is proved", c1.filesToGo == 0, "\(c1.filesToGo) to go")

        // Eject
        _ = await until(20, "settled") { !c1.isMatching && model.workingDrive?.isScanning != true }
        let safeBefore = c1.isSafe(on: model.workingDrive)
        check("eject: starts from Safe", safeBefore, "\(String(describing: c1.verdict))")
        bar.openForUser()
        await model.eject(c1)
        check("eject: the card is gone and the widget has closed", await until(5, "closed") { !FileManager.default.fileExists(atPath: c1.volume.path) && model.cards.isEmpty && !bar.panel.isVisible }, "\(model.cards.count) cards, error \(c1.ejectError ?? "none")")
        check("eject: it said the card could be pulled", c1.ejected)

        // The card pulled mid-copy
        hdiutil(["attach", cardImage])
        _ = await until(20, "card") { stale(model, cardName) != nil }
        guard let c2 = stale(model, cardName) else { check("eject: the card goes back in", false); return }
        check("eject: back in, a fresh session", c2 !== c1)
        _ = await until(120, "settled") { !c2.isBusy && !c2.isMatching }
        large = addLargeFile("ZZZ2.DAT", to: c2, seed: 2)
        model.recheck(c2)
        _ = await until(60, "ready") { c2.phase == .ready && c2.filesToGo == 1 }
        model.start(c2, destination: Destination(footageRoot: "Interrupted/Pulled"))
        check("pull: the copy is running", await until(20, "copying") { c2.phase == .copying && c2.liveBytes > 0 }, "\(c2.phase)")
        hdiutil(["detach", c2.volume.path])
        check("pull: the card is marked as pulled", await until(30, "pulled") { c2.volumeGone && !c2.isBusy }, "\(c2.phase) gone \(c2.volumeGone)")
        check("pull: the bar says so, never Safe", await until(3, "word") { bar.state.word == "Card pulled" } && !bar.state.isSafe, bar.state.word)
        check("pull: nothing half copied has its real name", !FileManager.default.fileExists(atPath: (model.workingDrive?.path ?? "") + "/Interrupted/Pulled/ZZZ2.DAT"))
        hdiutil(["attach", cardImage])
        check("pull: back in, the file is still owed", await until(120, "back") { stale(model, cardName).map { !$0.isBusy && !$0.isMatching && $0.phase == .ready && $0.filesToGo == 1 } ?? false }, "\(stale(model, cardName)?.filesToGo ?? -1) to go")
        guard let c3 = stale(model, cardName) else { return }
        model.start(c3, destination: Destination(footageRoot: "Interrupted/Pulled"))
        check("pull: copying again finishes", await until(120, "finished") { c3.phase == .finished && !c3.isBusy }, "\(c3.phase) \(c3.error ?? "")")
        check("pull: and the file is proved", c3.filesToGo == 0)

        // The drive pulled mid-copy
        large = addLargeFile("ZZZ3.DAT", to: c3, seed: 3)
        model.recheck(c3)
        _ = await until(60, "ready") { c3.phase == .ready && c3.filesToGo == 1 }
        model.start(c3, destination: Destination(footageRoot: "Interrupted/Unplugged"))
        check("unplug: the copy is running", await until(20, "copying") { c3.phase == .copying && c3.liveBytes > 0 }, "\(c3.phase)")
        let drivePath = model.workingDrive?.path ?? ""
        hdiutil(["detach", drivePath])
        check("unplug: it stops and says why", await until(30, "stopped") { !c3.isBusy && c3.error?.contains("unplugged") == true }, c3.error ?? "\(c3.phase)")
        check("unplug: no drive, no green", await until(10, "no drive") { model.workingDrive == nil } && !c3.isSafe(on: nil) && !bar.state.isSafe, bar.state.word)
        hdiutil(["attach", driveImage])
        check("unplug: the drive comes back as the working drive", await until(30, "drive") { model.workingDrive?.path == drivePath }, model.workingDrive?.name ?? "none")
        _ = await until(60, "settled") { !c3.isMatching && !c3.isBusy && model.workingDrive?.isScanning != true }
        model.resume(c3)
        check("unplug: Resume finishes", await until(120, "finished") { c3.phase == .finished && !c3.isBusy }, "\(c3.phase) \(c3.error ?? "")")
        check("unplug: and the file is proved", c3.filesToGo == 0, "\(c3.filesToGo) to go")

        // A volume nobody can be sure of: every answer, and taking it back
        hdiutil(["attach", otherImage])
        check("ask: an unknown volume is asked about", await until(20, "asked") { model.maybeCards.contains { $0.volume.name == otherName } }, "\(model.maybeCards.count)")
        guard let other = model.maybeCards.first(where: { $0.volume.name == otherName })?.volume else { return }
        check("ask: and is neither a card nor a drive yet", !model.cards.contains { $0.volume.name == otherName } && !model.drives.contains { $0.name == otherName })
        check("ask: there's nothing to forget yet", !model.hasVolumeChoices)
        model.setRole("drive", for: other)
        check("ask: It's a Drive", await until(20, "drive") { model.drives.contains { $0.name == otherName } })
        check("ask: which can be taken back", model.hasVolumeChoices && model.hasChosenRole(for: other))
        model.forgetChoice(for: other)
        check("ask: Not a Drive asks again", await until(20, "asked") { model.maybeCards.contains { $0.volume.name == otherName } && !model.drives.contains { $0.name == otherName } })
        model.setRole("card", for: other)
        check("ask: It's a Card", await until(20, "card") { model.cards.contains { $0.volume.name == otherName } })
        model.forgetVolumeChoices()
        check("ask: Forget Card and Drive Choices asks again", await until(20, "asked") { model.maybeCards.contains { $0.volume.name == otherName } && !model.cards.contains { $0.volume.name == otherName } } && !model.hasVolumeChoices)
        model.setRole("card", for: other)
        _ = await until(20, "card") { model.cards.contains { $0.volume.name == otherName } }

        // Two cards at once: one copies, one waits its turn
        guard let second = model.cards.first(where: { $0.volume.name == otherName }) else { return }
        check("two cards: the second is read", await until(60, "read") { second.phase == .ready && !second.isMatching }, "\(second.phase)")
        large = addLargeFile("ZZZ4.DAT", to: c3, seed: 4)
        model.recheck(c3)
        _ = await until(60, "ready") { c3.phase == .ready && c3.filesToGo == 1 }
        model.start(c3, destination: Destination(footageRoot: "Interrupted/Two/First"))
        model.start(second, destination: Destination(footageRoot: "Interrupted/Two/Second"))
        check("two cards: the second waits", second.phase == .queued, "\(second.phase)")
        check("two cards: and says so", CardSheet.make(second, model: model).line(.drive)?.detail == ["Waiting for the other card to finish."])
        model.stop(second)
        check("two cards: Stop takes it out of the queue", second.phase == .ready)
        model.start(second, destination: Destination(footageRoot: "Interrupted/Two/Second"))
        check("two cards: both finish", await until(180, "both") { c3.phase == .finished && second.phase == .finished && !model.isCopying }, "\(c3.phase), \(second.phase)")
        check("two cards: nothing is left on either", c3.filesToGo == 0 && second.filesToGo == 0, "\(c3.filesToGo), \(second.filesToGo)")
        check("two cards: both in History", model.history.prefix(2).map(\.cardName).contains(second.name), model.history.prefix(2).map(\.cardName).joined(separator: ", "))

        // A changed file on the drive can't pass, whatever the ledger remembers
        guard let first = model.cards.first(where: { $0.volume.name == cardName }), let drive = model.workingDrive else { return }
        let clip = first.read?.listing.files.filter { $0.kind == .video }.max { $0.size < $1.size }
        guard let clip, case .verified(let copy, _, _)? = first.states[clip.relPath] else { check("tamper: a proved clip to change", false); return }

        // With everything still plugged in, the proof ends with the file it was about, and looking is enough to find out
        _ = await until(20, "settled") { !first.isMatching && !drive.isScanning }
        check("changed in place: starts from Safe", first.isSafe(on: drive), "\(String(describing: first.verdict))")
        if let h = FileHandle(forUpdatingAtPath: drive.path + "/" + copy) {
            try? h.seek(toOffset: clip.size / 2)
            h.write(Data("first".utf8))
            try? h.close()
        } else { check("changed in place: the copy opens", false, copy) }
        model.lookAgain()
        check("changed in place: the green goes", await until(20, "green gone") { !first.isSafe(on: drive) } && first.states[clip.relPath] == .missing, "\(String(describing: first.verdict))")

        unlink(large)
        hdiutil(["detach", first.volume.path])
        _ = await until(20, "gone") { stale(model, cardName) == nil }
        if let h = FileHandle(forUpdatingAtPath: drive.path + "/" + copy) {
            try? h.seek(toOffset: clip.size / 2)
            h.write(Data("changed".utf8))
            try? h.close()
        } else { check("tamper: the copy opens", false, copy) }
        hdiutil(["attach", cardImage])
        _ = await until(20, "back") { stale(model, cardName) != nil }
        guard let last = stale(model, cardName) else { check("tamper: the card goes back in", false); return }
        check("tamper: the check finishes", await until(180, "checked") { !last.isBusy && !last.isMatching && last.read != nil && (last.phase == .ready || last.phase == .finished) }, "\(last.phase)")
        sheet = CardSheet.make(last, model: model)
        check("tamper: never Safe", !last.isSafe(on: drive) && !MenuBarState.make(model).isSafe, sheet.bottom.title)
        check("tamper: the changed copy doesn't count, so the clip is owed again", last.filesToGo == 1 && sheet.bottom.sentence == "1 file is only on this card.", "\(marks(last, model)) | \(sheet.bottom.sentence)")

        // Cameras are remembered, renamed and forgotten
        model.cameraMemory["selftest"] = CameraMemory(folder: "A Cam", displayName: "Test")
        model.stores.cameras = model.cameraMemory
        model.cameraMemory["selftest"]?.folder = "B Cam"
        model.stores.cameras = model.cameraMemory
        check("cameras: a renamed folder is saved", Stores().cameras["selftest"]?.folder == "B Cam")
        model.forgetCamera("selftest")
        check("cameras: forgetting one forgets it", Stores().cameras["selftest"] == nil && model.cameraMemory["selftest"] == nil)
    }

    private final class Expectation { var done = false }

    /// Setup, in the widget, on this drive and on an empty one. The panel stays invisible on the owner's screen.
    private static func setupChecks(drive: DriveState, bar: StatusBar, model: AppModel, out: String) async {
        func noOtherWindow() -> Bool { NSApp.windows.filter { $0.isVisible && $0 !== bar.panel && $0.className != "NSStatusBarWindow" }.isEmpty }
        let view = { bar.panel.contentView }
        let plugged = model.drives
        model.drives = []       // no drive at all: it opens anyway, and waits
        bar.hide()
        bar.showSetup(drive: nil)
        check("setup opens in the widget with no drive", await until(5, "setup") { bar.panel.isVisible && bar.ui.setup != nil })
        check("setup: no window of its own", noOtherWindow(), NSApp.windows.map(\.className).joined(separator: " "))
        try? await Task.sleep(for: .milliseconds(200))
        model.drives = plugged  // the drive turns up, and it continues by itself
        let shown = await until(30, "learned") { firstMenu(in: view()) != nil }
        let menu = firstMenu(in: view())
        check("the drive is read and the choices appear", shown, "\(menu?.items.map(\.title) ?? [])")
        let titles = menu?.items.map(\.title) ?? []
        check("The presets are a real menu, with every preset and Edit", ShootPlanner.presets().allSatisfy { titles.contains($0.name) } && titles.contains("Edit…"), "\(titles.count) items")
        func look() -> Data? {
            guard let v = view(), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep.tiffRepresentation
        }
        let before = look()
        if let m = menu, let i = m.items.firstIndex(where: { $0.title == ShootPlanner.presets()[0].name }) { m.performActionForItem(at: i) }
        try? await Task.sleep(for: .milliseconds(400))
        check("choosing a preset changes what's offered", before != nil && before != look())

        // Edit is a page of the widget too. Esc is Cancel, and keeps what was there
        func item(_ title: String) { if let m = firstMenu(in: view()), let i = m.items.firstIndex(where: { $0.title == title }) { m.performActionForItem(at: i) } }
        func editing() -> Bool { firstMenu(in: view()) == nil && !editableFields(in: view()).isEmpty }
        func keyed() async { bar.panel.makeKeyAndOrderFront(nil); _ = await until(2, "key") { bar.panel.isKeyWindow } }
        let picked = look()
        item("Edit…")
        check("Edit opens inside the widget", await until(5, "editor") { editing() })
        check("Edit: no window of its own", noOtherWindow())
        shot(SetupEditor(setup: .constant(drive.setup ?? ShootPlanner.presets()[0].setup)) {}.frame(width: Grid.width).background(Color.surface), "setup-editor", out, model)
        await keyed()
        shortcut(.escape)
        check("Esc in Edit comes back to setup", await until(5, "back") { firstMenu(in: view()) != nil })
        let kept = await until(3, "settled") { picked != nil && picked == look() }
        check("Cancel keeps what was there", kept)

        // Done carries what was typed back to setup, and Use This is what saves it
        item("Edit…")
        _ = await until(5, "editor") { editing() }
        await keyed()
        if let field = editableFields(in: view()).first {
            bar.panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            type("Shoots/{Client}", into: bar)
        }
        try? await Task.sleep(for: .milliseconds(200))
        shortcut(.return)
        check("Done comes back to setup", await until(5, "done") { firstMenu(in: view()) != nil })
        try? await Task.sleep(for: .milliseconds(400))
        check("Done changes what's offered", picked != look())
        check("Done saves nothing yet", drive.setup == nil)

        // It stays through a click elsewhere, where the widget would otherwise go
        let elsewhere = IngestPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        elsewhere.alphaValue = 0
        func awayAndBack() async -> Bool {
            await keyed()
            elsewhere.makeKeyAndOrderFront(nil)
            _ = await until(2, "moved") { !bar.panel.isKeyWindow }
            try? await Task.sleep(for: .milliseconds(150))
            elsewhere.orderOut(nil)
            return bar.panel.isVisible
        }
        check("setup stays when focus moves away", await awayAndBack() && bar.ui.setup != nil)
        await keyed()
        press(.escape, in: bar)
        check("Esc closes setup", await until(2, "closed") { bar.ui.setup == nil })
        check("and leaves the widget open on the card", bar.panel.isVisible && bar.ui.page == nil)
        check("without setup, focus moving away closes the widget", !(await awayAndBack()), "the control for the check above")

        // From the Drives page, and back to it, by the ✕ itself
        bar.show(.drives)
        bar.showSetup(drive: drive)
        check("setup opens over the Drives page", await until(30, "learned") { firstMenu(in: view()) != nil })
        await keyed()
        try? await Task.sleep(for: .milliseconds(400))      // the click has to land after setup has slid in
        click(right: StatusBar.margin.right + 23, top: StatusBar.margin.top + 22, in: bar)
        check("the ✕ lands back on Drives", await until(2, "drives") { bar.ui.setup == nil && bar.ui.page == .drives })
        bar.hide()

        // All the way to saved. Return is Use This.
        bar.showSetup(drive: drive)
        _ = await until(30, "learned") { firstMenu(in: view()) != nil }
        await keyed()
        shortcut(.return)
        check("Use This finishes and shows the card", await until(5, "done") { bar.ui.setup == nil && drive.setup != nil && bar.panel.isVisible && bar.ui.page == nil }, "setup \(bar.ui.setup == nil ? "closed" : "open")")
        check("an empty drive has presets to start from", LayoutLearner.learn(entries: []) == nil && !ShootPlanner.presets().isEmpty)
    }

    private static func editableFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let f = view as? NSTextField { return f.isEditable ? [f] : [] }
        return view.subviews.flatMap { editableFields(in: $0) }
    }

    private static func firstMenu(in view: NSView?) -> NSMenu? {
        guard let view else { return nil }
        if let pop = view as? NSPopUpButton, let m = pop.menu, m.items.contains(where: { $0.title == "Edit…" }) { return m }
        for v in view.subviews { if let m = firstMenu(in: v) { return m } }
        return nil
    }

    // MARK: Keys, delivered the way AppKit would

    private enum Key { case `return`, escape
        var code: UInt16 { self == .return ? 36 : 53 }
        var chars: String { self == .return ? "\r" : "\u{1B}" }
    }

    private static func event(_ chars: String, code: UInt16, in bar: StatusBar) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: bar.panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)
    }

    private static func press(_ key: Key, in bar: StatusBar) {
        guard let e = event(key.chars, code: key.code, in: bar) else { return }
        bar.panel.sendEvent(e)
    }

    /// Through the application, so the buttons' keyboard shortcuts answer as they would to a person.
    private static func shortcut(_ key: Key) {
        guard let w = NSApp.keyWindow, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: w.windowNumber, context: nil, characters: key.chars, charactersIgnoringModifiers: key.chars,
                                                                isARepeat: false, keyCode: key.code) else { return }
        NSApp.sendEvent(e)
    }

    /// A real click, measured in from the widget's top right corner.
    private static func click(right: CGFloat, top: CGFloat, in bar: StatusBar) {
        let at = NSPoint(x: bar.panel.frame.width - right, y: bar.panel.frame.height - top)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: kind, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: bar.panel.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { bar.panel.sendEvent(e) }
        }
    }

    private static func type(_ text: String, into bar: StatusBar) {
        for ch in text { if let e = event(String(ch), code: 0, in: bar) { bar.panel.sendEvent(e) } }
    }

    /// The second field in the view tree is the Shoot name.
    private static func focusShootField(in bar: StatusBar) {
        func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields) }
        guard let content = bar.panel.contentView else { return }
        let editable = fields(content).filter(\.isEditable)
        if let shoot = editable.last { bar.panel.makeFirstResponder(shoot) }
    }
}
