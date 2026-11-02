import AppKit
import IngestCore
import Sparkle

/// What finds and fetches updates. Sparkle in the app, a stand-in in tests.
@MainActor protocol UpdateEngine: AnyObject {
    var checksByItself: Bool { get set }
    func start()
    func check()
}

/// Updates, in the widget and nowhere else. An update downloads by itself and then waits: nothing installs until someone presses
/// Restart, and that's refused while a card is busy. It doesn't wait and restart later, because restarting ends a card's proof,
/// so a job finishing mustn't take a fresh Safe away from someone who isn't looking.
@MainActor @Observable final class Updates {
    enum State: Equatable { case idle, checking, upToDate, failed, downloading(String), ready(String), installing(String) }
    enum Stage { case notDownloaded, downloaded, installing }

    private(set) var state = State.idle
    private var pressedWhileBusy = false
    var checksByItself = true { didSet { engine?.checksByItself = checksByItself } }
    @ObservationIgnored var engine: UpdateEngine?
    /// The card a restart would get in the way of, if any.
    @ObservationIgnored var busy: (() -> String?)?
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var version = ""
    @ObservationIgnored private var asked = false

    func start(_ engine: UpdateEngine) {
        self.engine = engine
        checksByItself = engine.checksByItself
        engine.start()
    }

    /// The line in Settings.
    var line: String {
        switch state {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "This is the latest version."
        case .failed: "Couldn't check. Try again later."
        case .downloading(let v): "Getting \(AppInfo.name) \(v)…"
        case .ready: readyLine ?? ""
        case .installing(let v): "Installing \(AppInfo.name) \(v)…"
        }
    }

    /// The one quiet line in the widget and the right-click menu, when there's something to press.
    var readyLine: String? {
        guard case .ready(let v) = state else { return nil }
        if pressedWhileBusy, let card = busy?() { return "\(AppInfo.name) \(v) is ready. It can restart once \(card) is done." }
        return "\(AppInfo.name) \(v) is ready"
    }

    func check() {
        switch state {
        case .checking, .downloading, .ready, .installing: return
        default: break
        }
        asked = true
        state = .checking
        engine?.check()
    }

    func restart() {
        guard case .ready(let v) = state, let install else { return }
        if busy?() != nil { pressedWhileBusy = true; return }
        pressedWhileBusy = false
        self.install = nil
        state = .installing(v)
        install()
    }

    // What the engine reports.

    /// `go` carries on. For an update not yet here that's only a download, which nobody needs to agree to. For one already
    /// installing, it's what restarts the app, so it waits for Restart like any other.
    func found(version: String, stage: Stage, go: @escaping () -> Void) {
        self.version = version
        if stage == .installing {
            install = go
            state = .ready(version)
        } else {
            state = .downloading(version)
            go()
        }
    }

    func readyToInstall(go: @escaping () -> Void) {
        install = go
        state = .ready(version)
    }

    func noUpdate() {
        state = asked ? .upToDate : .idle
        asked = false
    }

    func failed() {
        state = asked ? .failed : .idle
        asked = false
    }

    func installing() {
        if case .ready = state { return }
        if case .installing = state { return }
        state = .installing(version)
    }

    /// Sparkle's session ended. One that's ready is still waiting for its press.
    func dismissed() {
        if case .ready = state { return }
        if case .downloading = state { state = .idle }
        if case .installing = state { state = .idle }
    }
}

/// Sparkle, with everything it would show going to `Updates`. It never opens a window.
final class SparkleEngine: NSObject, UpdateEngine, SPUUserDriver {
    private unowned let updates: Updates
    private var updater: SPUUpdater!

    init(updates: Updates) {
        self.updates = updates
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
    }

    var checksByItself: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    func start() { try? updater.start() }
    func check() { updater.checkForUpdates() }
    #if UPDATE_TEST
    func checkQuietly() { updater.checkForUpdatesInBackground() }
    #endif

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let stage: Updates.Stage = switch state.stage {
        case .installing: .installing
        case .downloaded: .downloaded
        default: .notDownloaded
        }
        UpdateLog.write("found \(appcastItem.displayVersionString)")
        updates.found(version: appcastItem.displayVersionString, stage: stage) { reply(.install) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        updates.noUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        UpdateLog.write("error: \(error.localizedDescription)")
        updates.failed()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { UpdateLog.write("downloaded") }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updates.readyToInstall { reply(.install) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        updates.installing()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        UpdateLog.write("dismissed")
        updates.dismissed()
    }
}

/// Where the end-to-end test reads what happened. Off in every real build.
enum UpdateLog {
    static func write(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["INGEST_UPDATE_LOG"] else { return }
        let text = "\(AppInfo.bundleVersion) pid \(ProcessInfo.processInfo.processIdentifier) \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); h.closeFile()
        } else { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
