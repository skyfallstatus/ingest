// The rules of an update, through the real model. Sparkle itself is run for real by scripts/update-e2e.sh.
import Foundation
import Testing
@testable import IngestApp
@testable import IngestCore

@MainActor private final class FakeEngine: UpdateEngine {
    var checksByItself = true
    var started = 0, checks = 0
    var ignoresChecks = false
    func start() { started += 1 }
    func check() -> Bool { checks += 1; return !ignoresChecks }
}

@MainActor private func updates(busy: String? = nil) -> (Updates, FakeEngine) {
    let u = Updates(), e = FakeEngine()
    u.engine = e
    u.busy = { busy }
    return (u, e)
}

@Suite("Updates") @MainActor struct UpdatesTests {
    @Test func `An update found by itself downloads quietly, with nothing to press yet`() {
        let (u, _) = updates()
        var downloads = 0
        u.found(version: "0.2", stage: .notDownloaded) { downloads += 1 }
        #expect(downloads == 1, "the download needs no one")
        #expect(u.state == .downloading("0.2"))
        #expect(u.readyLine == nil, "nothing is said in the widget until it's ready")
    }

    @Test func `Ready, it says one quiet line and waits`() {
        let (u, _) = updates()
        u.found(version: "0.2", stage: .notDownloaded) {}
        var installs = 0
        u.readyToInstall { installs += 1 }
        #expect(u.readyLine == "Ingest 0.2 is ready")
        #expect(installs == 0, "it never restarts by itself")
    }

    @Test func `A check that's ignored doesn't stay on Checking`() {
        let (u, e) = updates()
        e.ignoresChecks = true
        u.check()
        #expect(u.state == .failed, "just after a relaunch Sparkle takes no checks, and it never says")
        e.ignoresChecks = false
        u.check()
        #expect(u.state == .checking, "and it can be pressed again")
        #expect(e.checks == 2)
    }

    @Test func `A session that ends with nothing to say doesn't stay on Checking`() {
        let (u, _) = updates()
        u.check()
        u.dismissed()
        #expect(u.state == .idle)
    }

    @Test func `Keep Copying at a restart leaves Restart to press again`() {
        let (u, _) = updates()
        var asks = 0
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.readyToInstall { asks += 1 }
        u.restart()
        #expect(u.state == .installing("0.2"))
        u.installing(retry: { asks += 10 })
        u.restartRefused()
        #expect(u.state == .ready("0.2"), "it mustn't stay on Installing")
        #expect(u.readyLine == "Ingest 0.2 is ready")
        u.restart()
        #expect(asks == 11, "the second press asks to quit again")
        #expect(u.state == .installing("0.2"))
    }

    @Test func `Keep Copying can come before Sparkle says it's installing`() {
        let (u, _) = updates()
        var asks = 0
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.readyToInstall { asks += 1 }
        u.restart()
        u.restartRefused()
        u.installing(retry: { asks += 10 })
        #expect(u.state == .ready("0.2"))
        u.restart()
        #expect(asks == 11)
    }

    @Test func `A quit that's refused with no restart pressed changes nothing`() {
        let (u, _) = updates()
        var asks = 0
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.readyToInstall { asks += 1 }
        u.restartRefused()
        #expect(u.state == .ready("0.2"))
        u.restart()
        #expect(asks == 1)
    }

    @Test func `An app already gone has nothing to ask again`() {
        let (u, _) = updates()
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.readyToInstall {}
        u.restart()
        u.installing(retry: nil)
        u.restartRefused()
        #expect(u.state == .ready("0.2"))
    }

    @Test func `An update already installing waits for Restart too`() {
        let (u, _) = updates()
        var installs = 0
        u.found(version: "0.2", stage: .installing) { installs += 1 }
        #expect(installs == 0, "this reply is what would restart the app")
        #expect(u.readyLine == "Ingest 0.2 is ready")
        u.restart()
        #expect(installs == 1)
    }

    @Test func `Restart installs once`() {
        let (u, _) = updates()
        u.found(version: "0.2", stage: .notDownloaded) {}
        var installs = 0
        u.readyToInstall { installs += 1 }
        u.restart()
        u.restart()
        #expect(installs == 1)
        #expect(u.state == .installing("0.2"))
        #expect(u.readyLine == nil)
    }

    @Test func `With a card busy, Restart says why and doesn't install`() {
        let u = Updates()
        var card: String? = "A082"
        u.busy = { card }
        u.found(version: "0.2", stage: .notDownloaded) {}
        var installs = 0
        u.readyToInstall { installs += 1 }
        #expect(u.readyLine == "Ingest 0.2 is ready", "it only says so if someone asks")
        u.restart()
        #expect(installs == 0)
        #expect(u.readyLine == "Ingest 0.2 is ready. It can restart once A082 is done.")
        card = nil
        #expect(u.readyLine == "Ingest 0.2 is ready", "the reason goes with the card")
        #expect(installs == 0, "a Safe card isn't taken away because a job ended: it's still a press")
        u.restart()
        #expect(installs == 1)
    }

    @Test func `Nothing to install, Restart does nothing`() {
        let (u, _) = updates()
        u.restart()
        #expect(u.state == .idle)
    }

    @Test func `A check someone asked for says how it went, and one that ran by itself stays quiet`() {
        let (u, e) = updates()
        u.check()
        #expect(e.checks == 1)
        #expect(u.state == .checking)
        u.noUpdate()
        #expect(u.line == "This is the latest version.")
        let (quiet, _) = updates()
        quiet.noUpdate()
        #expect(quiet.line.isEmpty)
        quiet.failed()
        #expect(quiet.line.isEmpty, "a failed check nobody asked for isn't news")
        u.check()
        u.failed()
        #expect(u.line.hasPrefix("Couldn't check"))
    }

    @Test func `A check can't start while one is running, or once something's on its way`() {
        let (u, e) = updates()
        u.check()
        u.check()
        #expect(e.checks == 1)
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.check()
        #expect(e.checks == 1)
    }

    @Test func `The switch reaches the engine, and starts on`() {
        let (u, e) = updates()
        #expect(u.checksByItself)
        u.checksByItself = false
        #expect(!e.checksByItself)
    }

    @Test func `An update that fails after it was found goes quiet`() {
        let (u, _) = updates()
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.failed()
        #expect(u.state == .idle)
        #expect(u.readyLine == nil)
    }

    @Test func `Dismissed before it was ready, nothing is left waiting`() {
        let (u, _) = updates()
        u.found(version: "0.2", stage: .notDownloaded) {}
        u.dismissed()
        #expect(u.state == .idle)
    }

    @Test func `Dismissed once it's ready, Restart still works`() {
        let (u, _) = updates()
        u.found(version: "0.2", stage: .notDownloaded) {}
        var installs = 0
        u.readyToInstall { installs += 1 }
        u.dismissed()
        #expect(u.readyLine == "Ingest 0.2 is ready")
        u.restart()
        #expect(installs == 1)
    }

    @Test func `A card reading, checking or copying is in the way, and a settled one isn't`() async {
        let model = AppModel()
        model.isDemo = true
        let c = CardSession(volume: Volume(path: "/x", name: "A082", uuid: nil, total: 1, free: 1, fsType: "exfat", isReadOnly: false, isInternal: false, anchor: nil))
        model.cards = [c]
        for phase: CardSession.Phase in [.reading(done: 0, total: 0), .checking(done: 0, total: 1), .queued, .copying] {
            c.phase = phase
            #expect(model.cardInTheWay == "A082", "\(phase)")
        }
        for phase: CardSession.Phase in [.ready, .stopped, .finished] {
            c.phase = phase
            #expect(model.cardInTheWay == nil, "\(phase)")
        }
        c.phase = .finished
        c.isMatching = true
        #expect(model.cardInTheWay == "A082", "a look is a read")
    }

    @Test func `The model holds an update back while a card is busy`() {
        let model = AppModel()
        model.isDemo = true
        let c = CardSession(volume: Volume(path: "/x", name: "A082", uuid: nil, total: 1, free: 1, fsType: "exfat", isReadOnly: false, isInternal: false, anchor: nil))
        c.phase = .copying
        model.cards = [c]
        model.updates.found(version: "0.2", stage: .notDownloaded) {}
        var installs = 0
        model.updates.readyToInstall { installs += 1 }
        model.updates.restart()
        #expect(installs == 0)
        c.phase = .finished
        model.updates.restart()
        #expect(installs == 1)
    }
}
