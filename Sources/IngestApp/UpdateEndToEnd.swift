#if UPDATE_TEST
import AppKit
import IngestCore

/// Only in the builds `scripts/update-e2e.sh` makes: this presses Restart for it. Real Sparkle, real relaunch, a real job.
@MainActor enum UpdateEndToEnd {
    static func run(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        UpdateLog.write("launched at \(Bundle.main.bundlePath) opensOnCardIn=\(model.stores.opensOnCardIn)")
        guard env["INGEST_UPDATE_MODE"] != "stay" else { return }
        var job: Task<Void, Never>?
        if env["INGEST_UPDATE_MODE"] == "job" { job = Task { await startJob(model, env) } }
        Task {
            _ = await job?.value
            (model.updates.engine as? SparkleEngine)?.checkQuietly()
            var pressed = false, refused = false
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard case .ready = model.updates.state else { continue }
                if !pressed { UpdateLog.write("ready: \(model.updates.readyLine ?? "")"); pressed = true }
                if let card = model.cardInTheWay {
                    guard !refused else { continue }
                    model.updates.restart()
                    UpdateLog.write("refused during a job on \(card): \(model.updates.readyLine ?? "") state \(model.updates.state)")
                    refused = true
                    continue
                }
                UpdateLog.write("restarting")
                model.updates.restart()
                return
            }
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
