import AppKit
import IngestCore

/// Asks GitHub for the latest release. This is the only network call in the app. It runs when a person clicks, or
/// at most once a day if they've turned that on in Settings, and it sends nothing but the request itself.
@MainActor @Observable final class UpdateChecker {
    enum State: Equatable { case idle, checking, upToDate, available(String), failed }

    private(set) var state = State.idle
    @ObservationIgnored private var lastCheck: Date?

    var line: String {
        switch state {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "This is the latest version."
        case .available(let version): "\(AppInfo.name) \(version) is out."
        case .failed: "Couldn't check. During the beta, new versions come from the person who gave you the app."
        }
    }

    func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 24 * 3600 { return }
        check()
    }

    func check() {
        guard state != .checking, let url = UpdateCheck.requestURL else { return }
        state = .checking
        lastCheck = Date()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        Task {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, reply) = try? await session.data(for: request), let http = reply as? HTTPURLResponse else {
                state = .failed
                return
            }
            switch UpdateCheck.read(status: http.statusCode, data: data) {
            case .upToDate: state = .upToDate
            case .available(let version): state = .available(version)
            case .failed: state = .failed
            }
        }
    }

    static func openReleasePage() {
        if let page = UpdateCheck.releasePage { NSWorkspace.shared.open(page) }
    }
}
