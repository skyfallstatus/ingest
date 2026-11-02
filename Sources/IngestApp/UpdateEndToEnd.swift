#if UPDATE_TEST
import AppKit
import IngestCore

/// Only in the builds `scripts/update-e2e.sh` makes: this presses Restart for it. Real Sparkle, real relaunch, a real job.
@MainActor enum UpdateEndToEnd {
    private static var keepCopying = false

    /// Answers Keep Copying once, at the quit a restart sends.
    static func answersKeepCopying() -> Bool {
        defer { keepCopying = false }
        return keepCopying
    }

    static func run(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        UpdateLog.write("launched at \(Bundle.main.bundlePath) opensOnCardIn=\(model.stores.opensOnCardIn)")
        Task {
            // Just after a relaunch Sparkle looks for an unfinished install, and ignores a check while it does, so this asks until
            // something happens. A refused update goes back to idle, and is asked for again, which is what a real Mac would do.
            while true {
                if env["INGEST_UPDATE_MODE"] == "asked" {
                    if model.updates.state != .checking { model.updates.check() }    // pressed by hand, so a refusal says why
                } else if model.updates.state == .idle {
                    (model.updates.engine as? SparkleEngine)?.checkQuietly()
                }
                try? await Task.sleep(for: .seconds(2))
                if case .ready = model.updates.state { break }
            }
            UpdateLog.write("ready: \(model.updates.readyLine ?? "")")
            if env["INGEST_UPDATE_MODE"] == "job" {
                await startJob(model, env)          // the update is here first, so Restart is pressed in the middle of the job
                model.updates.restart()
                UpdateLog.write("refused during a job on \(model.cardInTheWay ?? "nothing"): \(model.updates.readyLine ?? "") state \(model.updates.state)")
                while model.cardInTheWay != nil { try? await Task.sleep(for: .milliseconds(100)) }
                UpdateLog.write("the job is done")
            }
            if env["INGEST_UPDATE_MODE"] == "keepCopying" {
                keepCopying = true
                model.updates.restart()
                while keepCopying { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                UpdateLog.write("kept copying: \(model.updates.line)")
            }
            UpdateLog.write("restarting")
            model.updates.restart()
        }
    }

    /// A real copy between two folders, long enough for the update to land in the middle of it.
    private static func startJob(_ model: AppModel, _ env: [String: String]) async {
        guard let card = env["INGEST_UPDATE_CARD"], let drive = env["INGEST_UPDATE_DRIVE"] else { return }
        func volume(_ path: String, _ id: String) -> Volume {
            Volume(path: path, name: id, uuid: id, total: 40_000_000_000, free: 30_000_000_000, fsType: "exfat", isReadOnly: false, isInternal: false, anchor: MountAnchor(path: path))
        }
        let plugged: [(Volume, VolumeRole)] = [(volume(card, "CARD"), .card), (volume(drive, "DRIVE"), .drive)]
        model.isDemo = true
        model.findVolumes = { _, _ in plugged }
        await model.refresh()
        guard let d = model.drives.first else { UpdateLog.write("no drive"); return }
        model.use(drive: d)
        guard let c = model.cards.first else { UpdateLog.write("no card"); return }
        while c.phase != .ready || c.isMatching { try? await Task.sleep(for: .milliseconds(50)) }
        model.start(c, destination: Destination(footageRoot: "S"))
        while c.phase != .copying { try? await Task.sleep(for: .milliseconds(10)) }
        UpdateLog.write("job running")
    }
}
#endif
