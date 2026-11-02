// The module's front door: what a card is, and what must stop a false "Safe to format".
import Foundation

public enum CardProber {
    /// How a mounted volume looks from its root. Markers are read ONLY at the volume root, compared case-insensitively.
    public static func look(atRoot root: URL) -> VolumeLook { VolumeProbe.look(atRoot: root) }

    /// `files` is every non-junk file on the card. `focus`, when given, is the subset not yet proved on the drive:
    /// capture dates come from those, because reused cards hold old shoots.
    public static func probe(root: URL, files: [CardFile], focus: Set<String>?) -> ProbeResult {
        let ctx = CardContext(root: root, files: files)
        var result = ProbeResult()
        result.hasVideo = files.contains { $0.kind == .video }
        result.hasStills = files.contains { $0.kind == .still }
        result.hasAudio = files.contains { $0.kind == .audio }

        let units = ClipUnits.build(ctx)
        let reader = ClipReader(ctx)
        result.cameras = Cameras.tally(units, reader)

        let wanted = focus.map { f in units.filter { $0.members.contains { f.contains($0.relPath) } } } ?? units
        result.captureDays = CaptureDays.build(wanted, reader)
        result.reel = Reels.pick(wanted) ?? Reels.pick(units)
        (result.issues, result.clipChecks) = Completeness.check(ctx, units: units)
        return result
    }

    /// Classifies a card-relative path. Pure, and cheap enough for every file on a card.
    public static func kind(ofRelativePath path: String) -> FileKind { FileKinds.kind(path) }

    /// The file a striped BRAW clip needs beside it: `.braw` ↔ `.braw2`, keeping case. nil for anything
    /// else. A path alone can't show whether a lone `.braw` was striped, so call this on the paths of a
    /// `braw.striped` issue.
    static func stripedPartnerName(of relPath: String) -> String? {
        let name = (relPath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        switch ext.lowercased() {
        case "braw": return "\(stem).\(ext)2"
        case "braw2": return "\(stem).\(ext.dropLast())"
        default: return nil
        }
    }

    /// True for a Codex virtual volume.
    public static func isCodexVirtual(root: URL) -> Bool {
        var st = stat()
        return lstat(root.path + "/.codexvfs", &st) == 0
    }
}
