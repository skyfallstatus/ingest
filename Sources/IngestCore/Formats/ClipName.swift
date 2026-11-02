// What a clip name can say.
import Foundation

struct ARRIName {
    var cameraIndex: String     // "A_" or "A"
    var reel: String            // "0001" or "004"
    var date: String            // yymmdd
    var cameraID: String        // Base36 part: "12NR", or "N9O" with the user prefix dropped
    var prefix: String          // Mini LF user prefix, "R". Empty on ALEXA 35
    var isNewGeneration: Bool
    var serial: String? { Base36.decode(cameraID).map(String.init) }
    /// The folder the camera names after this reel.
    var reelFolder: String {
        isNewGeneration ? "\(cameraIndex)\(reel)_\(cameraID)" : "\(cameraIndex)\(reel)\(prefix)\(cameraID)"
    }
}

enum Base36 {
    static func decode(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 8 else { return nil }
        var v = 0
        for u in s.utf8 {
            switch u {
            case 48 ... 57: v = v * 36 + Int(u) - 48
            case 65 ... 90: v = v * 36 + Int(u) - 55
            default: return nil
            }
        }
        return v
    }
}

enum ClipName {
    private static let arriNew = regex(#"^([A-Z][A-Z_])([0-9]{4})C[0-9]{3}_([0-9]{6})_[0-9]{6}_[a-z]([0-9A-Z]{4})(?:_hde)?(?:[._][0-9]+)?$"#)
    private static let arriOld = regex(#"^([A-Z])([0-9]{3})C[0-9]{3}_([0-9]{6})_([A-Z])([0-9A-Z]{3})(?:[._][0-9]+)?$"#)

    static func arri(_ stem: String) -> ARRIName? {
        if let c = captures(arriNew, stem), c.count == 4 {
            return ARRIName(cameraIndex: c[0], reel: c[1], date: c[2], cameraID: c[3], prefix: "", isNewGeneration: true)
        }
        if let c = captures(arriOld, stem), c.count == 5 {
            return ARRIName(cameraIndex: c[0], reel: c[1], date: c[2], cameraID: c[4], prefix: c[3], isNewGeneration: false)
        }
        return nil
    }

    static let arriReelNew = regex("^[A-Z][A-Z_][0-9]{4}_[0-9A-Z]{4}$")
    static let arriReelOld = regex("^[A-Z][0-9]{3}[A-Z][0-9A-Z]{3}$")
    static func isARRIReelFolder(_ name: String) -> Bool {
        captures(arriReelNew, name) != nil || captures(arriReelOld, name) != nil
    }

    // "A082C001_260120DB", "C001L001_261022ZT". Letter + reel + position + clip.
    private static let reelClip = regex(#"^([A-Z][0-9]{3})[A-Z][0-9]{3}(?:_([0-9]{6}))?"#)
    // Canon R5 II and C400: two-character index, four-digit reel, clip, codec letter, date, time, random,
    // user field. "A_0089C378H261015_190547EJ_ABCDE", seen on real R5 II clips.
    private static let wideReelClip = regex(#"^([A-Z][A-Z_][0-9]{4})[CD][0-9]{3}(?:[A-Z]([0-9]{6})_[0-9]{6})?"#)
    // "A001_08151512_C001", "A001_C001_0213N4". The Blackmagic Cam app has a time with a space in the middle.
    private static let underscoreReel = regex(#"^([A-Z][0-9]{3})_(?:[^_]+_C[0-9]{3,4}|C[0-9]{3}_)"#)
    private static let blackmagicDate = regex(#"^[A-Z][0-9]{3}_([0-9]{2})([0-9]{2})[0-9]{4}_[CS][0-9]{3,4}"#)

    /// The reel a clip name carries. `C001L001` is camera C, reel 001, so "C001", not clip 1.
    static func reel(_ stem: String) -> String? {
        if let a = arri(stem), a.isNewGeneration { return a.reelFolder }
        if let c = captures(wideReelClip, stem), let reel = c.first { return reel }
        if let c = captures(reelClip, stem), let reel = c.first { return reel }
        if let c = captures(underscoreReel, stem), let reel = c.first { return reel }
        return nil
    }

    /// The yymmdd of a cinema-style clip name, which shares the camera clock.
    static func cinemaDay(_ stem: String) -> CalendarDay? {
        if let a = arri(stem) { return WrittenDate.yymmdd(a.date) }
        if let c = captures(wideReelClip, stem), c.count == 2, !c[1].isEmpty { return WrittenDate.yymmdd(c[1]) }
        if let c = captures(reelClip, stem), c.count == 2, !c[1].isEmpty { return WrittenDate.yymmdd(c[1]) }
        return nil
    }

    /// Month and day from `A001_08151512_C001`. No year, so never enough alone.
    static func blackmagicMonthDay(_ stem: String) -> (month: Int, day: Int)? {
        guard let c = captures(blackmagicDate, stem), c.count == 2, let m = Int(c[0]), let d = Int(c[1]) else { return nil }
        return (m, d)
    }

    // "DJI_20261022115458_0143_D", "VID_20260531_010338_00_001", "LRV_…", "IMG_…".
    private static let djiDate = regex("^(?:DJI|CAM)_([0-9]{8})[0-9]{6}")
    private static let instaDate = regex("^(?:VID|LRV|IMG|PRO_VID|PRO_LRV)_([0-9]{8})_[0-9]{6}")
    static func djiDay(_ stem: String) -> CalendarDay? { captures(djiDate, stem)?.first.flatMap(WrittenDate.day) }
    static func instaDay(_ stem: String) -> CalendarDay? { captures(instaDate, stem)?.first.flatMap(WrittenDate.day) }

    // Canon on SD and SDHC: "a stream number (001 to 999) will be added" (C400 manual p.48). Where it sits is
    // only in that manual's diagram, so either side of the 5-character user field is accepted. Both shapes
    // need that field or the wide index, which is what keeps Sony's `A082C001_260120DB` out.
    private static let canonWideStream = regex(#"^([A-Z][A-Z_][0-9]{4}[CD][0-9]{3}[A-Z][0-9]{6}_[0-9]{6}[0-9A-Z]{2})(?:_([0-9]{3})(_[0-9A-Z]{5})?|(_[0-9A-Z]{5})_([0-9]{3}))$"#)
    private static let canonNarrowStream = regex(#"^([A-Z][0-9]{3}[CD][0-9]{3}_[0-9]{6}[0-9A-Z]{2})(?:_([0-9]{3})(_[0-9A-Z]{5})|(_[0-9A-Z]{5})_([0-9]{3}))$"#)

    /// The clip a Canon stream belongs to, and which stream this is.
    static func canonStream(_ stem: String) -> (clip: String, stream: Int)? {
        guard let c = captures(canonWideStream, stem) ?? captures(canonNarrowStream, stem), c.count == 5,
              let n = Int(c[1].isEmpty ? c[4] : c[1]) else { return nil }
        return (c[0] + c[2] + c[3], n)
    }

    /// `GX011234.MP4`: encoding, chapter, video. Nil for any other name.
    static func goPro(_ name: String) -> (prefix: String, chapter: Int, video: Int)? {
        let u = Array(name.utf8)
        guard u.count == 12, u[0] == 71, u[1] == 88 || u[1] == 72,
              String(decoding: u[8 ..< 12], as: UTF8.self).lowercased() == ".mp4" else { return nil }
        let digits = u[2 ..< 8]
        guard digits.allSatisfy(\.isASCIIDigit),
              let chapter = Int(String(decoding: u[2 ..< 4], as: UTF8.self)),
              let video = Int(String(decoding: u[4 ..< 8], as: UTF8.self)) else { return nil }
        return (String(decoding: u[0 ..< 2], as: UTF8.self), chapter, video)
    }
}
