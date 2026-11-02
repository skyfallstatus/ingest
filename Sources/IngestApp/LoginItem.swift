import ServiceManagement

/// Opening at login, as macOS reports it. Right after `register()` the status can still read "not registered", and it
/// has been seen to reach enabled only by nine seconds later, so a click is held until macOS agrees or ten seconds pass.
@MainActor @Observable final class LoginItem {
    private(set) var isOn = false
    private(set) var needsApproval = false
    private(set) var problem: String?
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// macOS reports `.notFound` for an app that has never asked, so it reads as off and not as a fault.
    func refresh() {
        guard settling == nil else { return }
        read()
    }

    private func read() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        settling?.cancel()
        settling = nil
        problem = nil
        isOn = on
        needsApproval = false
        var failure: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { failure = error.localizedDescription }    // asking for what's already so lands here too
        settling = Task { [weak self] in
            for _ in 0..<40 {
                let status = SMAppService.mainApp.status
                if on ? status == .enabled || status == .requiresApproval : status == .notRegistered || status == .notFound { break }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.settling = nil
            self.read()
            guard !self.needsApproval, self.isOn != on else { return }
            self.problem = "macOS wouldn't change this" + (failure.map { ": \($0)" } ?? ". Check Login Items in System Settings.")
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
