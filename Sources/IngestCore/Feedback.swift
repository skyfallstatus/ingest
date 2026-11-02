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
