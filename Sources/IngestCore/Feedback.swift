import Foundation

/// A bug report or a suggestion, ready for a person to read before sending. It leaves the Mac only when they paste it
/// somewhere and send it themselves. Beyond what they typed it carries versions
/// and words from closed lists, so a path, a file name, a client, a serial or a drive name has no way in.
public struct FeedbackReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bug, feature

        public var title: String { self == .bug ? "Report a Bug" : "Suggest a Feature" }
        public var prompt: String { self == .bug ? "What happened?" : "What would make it better for you?" }
        var label: String { self == .bug ? "bug" : "enhancement" }
    }

    public var kind: Kind
    public var message: String
    private let appVersion: String, macOS: String, mac: String, cameras: [String]

    /// `hardwareModel` is the Mac's model identifier: only its family survives. `cameras` is reduced to makers.
    public init(kind: Kind, message: String = "", appVersion: String = AppInfo.fullVersion, system: OperatingSystemVersion,
                hardwareModel: String, appleSilicon: Bool, cameras: [CameraFamily] = []) {
        self.kind = kind
        self.message = message
        self.appVersion = appVersion
        macOS = system.patchVersion == 0 ? "\(system.majorVersion).\(system.minorVersion)"
            : "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        mac = Self.family(ofModel: hardwareModel) + (appleSilicon ? ", Apple silicon" : ", Intel")
        self.cameras = Array(Set(cameras.compactMap(\.makerName))).sorted()
    }

    /// "MacBookPro" from "MacBookPro18,3", "Mac" from "Mac16,7". The letters name the family, and the digits aren't needed.
    static func family(ofModel model: String) -> String {
        let letters = model.prefix { $0.isASCII && $0.isLetter }
        return letters.isEmpty ? "Mac" : String(letters)
    }

    /// One line, shown to the person before anything leaves.
    public var details: String {
        var parts = ["\(AppInfo.name) \(appVersion)", "macOS \(macOS)", mac]
        if !cameras.isEmpty { parts.append(cameras.joined(separator: ", ") + " card") }
        return parts.joined(separator: " · ")
    }

    private func body(_ text: String) -> String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (typed.isEmpty ? kind.prompt + "\n\n" : typed + "\n\n") + "---\n" + details
    }

    /// For Copy Details: everything, however long.
    public var plainText: String { "\(kind.title)\n\n" + body(message) }

    /// A blank issue on GitHub. Whatever goes in an address reaches GitHub the moment the page opens, even a page that says
    /// not found, and stays in the browser's history, so nothing typed goes in it. A person pastes `plainText` and sends that.
    public var issueURL: URL? {
        guard var parts = URLComponents(string: AppInfo.repoURL + "/issues/new") else { return nil }
        parts.queryItems = [URLQueryItem(name: "labels", value: kind.label)]
        return parts.url
    }
}

extension CameraFamily {
    /// The maker, for a report. Nil when the card didn't say.
    var makerName: String? {
        switch self {
        case .sony: "Sony"
        case .canon: "Canon"
        case .blackmagic: "Blackmagic"
        case .red: "RED"
        case .arri: "ARRI"
        case .panasonic: "Panasonic"
        case .nikon: "Nikon"
        case .fujifilm: "Fujifilm"
        case .dji: "DJI"
        case .gopro: "GoPro"
        case .insta360: "Insta360"
        case .apple: "iPhone"
        case .audioRecorder: "Audio recorder"
        case .unknown: nil
        }
    }
}

/// Is there a newer release? The answer is either a version or nothing to report, so a failure is never dressed up
/// as being up to date. A private repo answers 404 to anyone without a token, which lands here as a failed check.
/// GitHub's "latest" skips drafts and pre-releases, so a build testers should hear about needs a normal release.
public enum UpdateCheck {
    public enum Answer: Equatable, Sendable {
        case upToDate, available(String), failed
    }

    public static var requestURL: URL? {
        URL(string: AppInfo.repoURL.replacingOccurrences(of: "https://github.com/", with: "https://api.github.com/repos/") + "/releases/latest")
    }

    /// Where a person goes to read about it. It comes from `AppInfo`, not from the reply.
    public static var releasePage: URL? { URL(string: AppInfo.repoURL + "/releases/latest") }

    public static func read(status: Int, data: Data, current: String = AppInfo.version) -> Answer {
        guard status == 200,
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = reply["tag_name"] as? String,
              let latest = numbers(in: tag), let mine = numbers(in: current) else { return .failed }
        return isNewer(latest, than: mine) ? .available(latest.map(String.init).joined(separator: ".")) : .upToDate
    }

    /// "v1.2.0-beta.1" reads as [1, 2, 0]. Nil for a tag that isn't a version.
    private static func numbers(in tag: String) -> [Int]? {
        let bare = tag.hasPrefix("v") || tag.hasPrefix("V") ? tag.dropFirst() : Substring(tag)
        let parts = (bare.split(separator: "-").first ?? "").split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
