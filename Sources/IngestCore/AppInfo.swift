import Foundation

/// The app has no final name yet. Every user-visible use of the name goes through here.
public enum AppInfo {
    public static let name = "Ingest"
    public static let bundleID = "com.skyfallstatus.ingest"
    public static let version = "0.1"
    /// Which build this is, so a report can say. `scripts/build-app.sh` writes it into the bundle.
    public static var fullVersion: String {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "IngestBuild") as? String else { return version }
        return "\(version) (\(build))"
    }
    /// Bug reports, suggestions and the update check all start here. Change it once, here.
    public static let repoURL = "https://github.com/skyfallstatus/ingest"
    /// Hidden folder this app keeps on a working drive.
    public static let driveFolder = ".ingest"
}
