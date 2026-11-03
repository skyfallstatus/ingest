import Foundation

/// The app has no final name yet. Every user-visible use of the name goes through here.
public enum AppInfo {
    public static let name = "Ingest"
    public static let bundleID = "com.skyfallstatus.ingest"
    public static let version = "0.2"
    /// Which build this is, so a report can say. `scripts/build-app.sh` writes it into the bundle.
    public static var fullVersion: String {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "IngestBuild") as? String else { return version }
        return "\(version) (\(build))"
    }
    /// The version as it's shown, which is what a report and an update compare, and the number Sparkle compares.
    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? version
    }
    /// Bug reports, suggestions and updates all start here. Change it once, here. `scripts/build-app.sh` and `scripts/release.sh`
    /// read it from this file.
    public static let repoURL = "https://github.com/skyfallstatus/ingest"
    /// Where updates are announced: the newest GitHub Release of that repo.
    public static var feedURL: String { repoURL + "/releases/latest/download/appcast.xml" }
    /// Hidden folder this app keeps on a working drive.
    public static let driveFolder = ".ingest"
}
