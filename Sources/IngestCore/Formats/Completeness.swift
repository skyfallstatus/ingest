// Card-level problems that must stop a false "Safe to format".
// Holds are for things a checksum cannot see: a clip that copied perfectly and is still not all there.
import Foundation

enum Completeness {
    /// The problems, and an account of what was looked at to find them.
    static func check(_ ctx: CardContext, units: [ClipUnit]) -> (issues: [CardIssue], report: ClipCheckReport) {
        var tally = ClipCheckTally()
        let (redIssues, nikonFiles) = red(ctx, &tally)
        var issues = redIssues
        issues += quickTimeFiles(ctx, units: units, extra: nikonFiles, &tally)
        issues += mxfFiles(ctx, units: units, &tally)
        issues += redProResParts(ctx, &tally)
        issues += canonStreams(ctx, &tally)
        issues += frameSequences(ctx, &tally)
        issues += goProChapters(ctx, &tally)
        issues += insta360(ctx)
        issues += arriReels(ctx)
        issues += codex(ctx)
        return (issues, tally.report(files: ctx.files))
    }

    // MARK: RED

    private enum PartFooter: Sendable { case atoms, unreadable, ok(R3DFooter, size: UInt64) }

    /// Parts must run from `_001`, the last ending in REOC, or a single file in REOB, each footer's size
    /// matching its file. An .R3D with no RED magic and valid atoms is Nikon's R3D NE: it is returned for
    /// the index check instead, whatever its name, because the prefix can be changed in camera.
    static func red(_ ctx: CardContext, _ tally: inout ClipCheckTally) -> (issues: [CardIssue], notRED: [CardFile]) {
        let parts = ctx.files.filter { $0.ext == "r3d" }
        guard !parts.isEmpty else { return ([], []) }
        let paths = parts.map { (absolute: ctx.absolute($0.relPath), dcim: CardContext.isInDCIM($0.relPath)) }
        let footers: [PartFooter] = concurrentMap(paths) { path in
            guard let file = ByteFile(path: path.absolute) else { return .unreadable }
            guard R3D.hasMagic(file) else {
                let head = file.read(at: 0, count: 8)
                return QuickTime.startsWithAtom(head) || path.dcim || Nikon.isNikonRaw(file) ? .atoms : .unreadable
            }
            guard let footer = R3D.footer(file) else { return .unreadable }
            return .ok(footer, size: file.size)
        }

        struct Part { var number: Int?; var file: CardFile; var footer: PartFooter }
        var clips: [String: [Part]] = [:]
        var notRED: [CardFile] = []
        for (i, f) in parts.enumerated() {
            if case .atoms = footers[i] {
                notRED.append(f)
                continue
            }
            let stem = CardContext.stem(of: f.name)
            let p = ClipUnits.part(of: stem)
            let key = CardContext.folder(of: f.relPath) + "/" + (p?.stem ?? stem)
            clips[key, default: []].append(Part(number: p?.number, file: f, footer: footers[i]))
            let concluded = if case .ok = footers[i] { true } else { false }
            tally.add(.redParts, f, concluded: concluded)
        }

        var issues: [CardIssue] = []
        for key in clips.keys.sorted() {
            guard let found = clips[key] else { continue }
            let list = found.sorted { ($0.number ?? 1) < ($1.number ?? 1) }
            let clip = (key as NSString).lastPathComponent
            let paths = list.map(\.file.relPath)
            // RED magic in DCIM is a Nikon file. Whether R3D NE keeps RED's footers isn't known, so a note.
            let nikon = paths.contains(where: CardContext.isInDCIM)
            func report(_ sentence: String) {
                issues.append(CardIssue(severity: nikon ? .note : .hold, code: nikon ? "nikon.r3d-ending" : "red.missing-part",
                                        message: sentence, paths: paths))
                for part in list { if case .ok = part.footer { tally.fail(.redParts, part.file) } }
            }
            let numbers = list.map { $0.number ?? 1 }
            if let missing = firstMissing(numbers) {
                report("RED clip \(clip) is missing part \(String(format: "%03d", missing)), so it would play short.")
                continue
            }
            var problem: String?
            for (i, part) in list.enumerated() {
                let isLast = i == list.count - 1
                switch part.footer {
                case .ok(let footer, let size):
                    let endsClip = list.count == 1
                        ? footer.kind == "REOB" || (footer.kind == "REOC" && part.number != nil)
                        : footer.kind == "REOC"
                    if footer.declaredSize != size {
                        problem = "RED clip \(clip) has a cut-short part, \(part.file.name)."
                    } else if isLast, !endsClip {
                        problem = "RED clip \(clip) ends at \(part.file.name) with later parts missing, so it would play short."
                    } else if !isLast, footer.kind != "REOF" {
                        problem = "RED clip \(clip) has a part out of sequence, \(part.file.name)."
                    }
                default:
                    problem = "RED clip \(clip) has a part whose ending can't be read, \(part.file.name), so it may be cut short."
                }
                if problem != nil { break }
            }
            if let problem { report(problem) }
        }
        return (issues, notRED)
    }

    /// The lowest number from 1 up that a run of parts lacks.
    private static func firstMissing(_ numbers: [Int], from start: Int = 1) -> Int? {
        guard let highest = numbers.max(), highest >= start else { return nil }
        let present = Set(numbers)
        return (start ... highest).first { !present.contains($0) }
    }

    /// RED ProRes spans like R3D. No footers here, so the numbers are all there is. A .mov beside
    /// R3D parts is a proxy, and a gap in those loses nothing.
    static func redProResParts(_ ctx: CardContext, _ tally: inout ClipCheckTally) -> [CardIssue] {
        var issues: [CardIssue] = []
        for folder in ctx.byFolder.keys.sorted() where folder.lowercased().hasSuffix(".rdc") {
            guard let files = ctx.byFolder[folder], !files.contains(where: { $0.ext == "r3d" }) else { continue }
            var clips: [String: [(number: Int, file: CardFile)]] = [:]
            for f in files where f.ext == "mov" {
                let stem = CardContext.stem(of: f.name)
                let part = ClipUnits.part(of: stem)
                clips[part?.stem ?? stem, default: []].append((part?.number ?? 1, f))
                tally.add(.redParts, f, concluded: true, format: "RED")
            }
            for clip in clips.keys.sorted() {
                guard let list = clips[clip], let missing = firstMissing(list.map(\.number)) else { continue }
                issues.append(CardIssue(severity: .hold, code: "red.missing-part",
                                        message: "RED clip \(clip) is missing part \(String(format: "%03d", missing)), so it would play short.",
                                        paths: list.map(\.file.relPath).sorted()))
                for item in list { tally.fail(.redParts, item.file, format: "RED") }
            }
        }
        return issues
    }

    // MARK: Canon

    /// A hole between streams is loss. Streams starting late could be a relay from another card,
    /// which no manual settles, so that is only worth saying.
    static func canonStreams(_ ctx: CardContext, _ tally: inout ClipCheckTally) -> [CardIssue] {
        var clips: [String: [(stream: Int, file: CardFile)]] = [:]
        for f in ctx.files where f.ext == "mp4" {
            guard let s = ClipName.canonStream(CardContext.stem(of: f.name)) else { continue }
            clips[CardContext.folder(of: f.relPath) + "/" + s.clip, default: []].append((s.stream, f))
            tally.add(.streams, f, concluded: true)
        }
        var issues: [CardIssue] = []
        for key in clips.keys.sorted() {
            guard let list = clips[key] else { continue }
            let clip = (key as NSString).lastPathComponent
            let found = runIssue(list.map(\.stream), code: "canon.missing-stream", paths: list.map(\.file.relPath).sorted(),
                                 hole: { "Canon clip \(clip) is missing stream \(String(format: "%03d", $0)), so it would play short." },
                                 lateStart: { "Canon clip \(clip) starts at stream \(String(format: "%03d", $0)), so the earlier streams may be on another card." })
            if !found.isEmpty { for item in list { tally.fail(.streams, item.file) } }
            issues += found
        }
        return issues
    }

    /// A hole between the numbers present is loss: a hold. Numbers that start late can be normal: a note.
    private static func runIssue(_ numbers: [Int], code: String, paths: [String],
                                 hole: (Int) -> String, lateStart: (Int) -> String) -> [CardIssue] {
        guard let lowest = numbers.min() else { return [] }
        if let missing = firstMissing(numbers, from: lowest) {
            return [CardIssue(severity: .hold, code: code, message: hole(missing), paths: paths)]
        }
        return lowest > 1 ? [CardIssue(severity: .note, code: code, message: lateStart(lowest), paths: paths)] : []
    }

    // MARK: MXF

    private struct MXFCheck: Sendable { var relPath: String; var absolute: String; var sidecar: String? }
    private enum MXFVerdict: Sendable { case finished, cutShort(String, String), unfinished(String) }

    /// A cut MXF keeps its header, so identification still works and only the end shows the damage.
    /// Healthy files cost three small reads. Only a file that fails has its XML read, to see whose it is.
    static func mxfFiles(_ ctx: CardContext, units: [ClipUnit], _ tally: inout ClipCheckTally) -> [CardIssue] {
        var checks: [MXFCheck] = []
        var mxf: [CardFile] = []
        for unit in units where !unit.isStill {
            for f in unit.members where f.ext == "mxf" {
                let stem = CardContext.stem(of: f.name)
                let sidecar = ctx.sibling(of: f.relPath, named: (stem + "M01.XML").lowercased())
                checks.append(MXFCheck(relPath: f.relPath, absolute: ctx.absolute(f.relPath), sidecar: sidecar.map(ctx.absolute)))
                mxf.append(f)
            }
        }
        let verdicts: [MXFVerdict] = concurrentMap(checks) { check in
            guard let file = ByteFile(path: check.absolute) else { return .unfinished(check.relPath) }
            let ending = MXF.ending(file)
            if ending.isFinished { return .finished }
            // Header state is proven on Sony only. 53 of 72 real ARRI MXF have an open header and a sound RIP.
            let head = file.read(at: 0, count: MXF.headSize)
            let side = check.sidecar.flatMap { ByteFile(path: $0) }.map { String(decoding: $0.read(at: 0, count: 256 << 10), as: UTF8.self) }
            let xml = Sony.embeddedXML(inMXFHead: head) ?? side
            if let xml, Sony.hasProvenEnding(xml) { return .cutShort(check.relPath, "Sony") }
            if ending.hasRandomIndex { return .finished }
            // All 72 ALEXA 35 and Mini LF MXF in ARRI's public samples end in a RIP and a footer.
            if (MXF.parse(file)?.company ?? "").uppercased().contains("ARRI") { return .cutShort(check.relPath, "ARRI") }
            return .unfinished(check.relPath)
        }
        var issues: [CardIssue] = []
        var unproven: [String] = []
        for (i, verdict) in verdicts.enumerated() {
            let concluded = if case .unfinished = verdict { false } else { true }
            tally.add(.mxfEnding, mxf[i], concluded: concluded)
            switch verdict {
            case .finished: break
            case .unfinished(let path): unproven.append(path)
            case .cutShort(let path, let brand):
                tally.fail(.mxfEnding, mxf[i])
                let name = (path as NSString).lastPathComponent
                issues.append(CardIssue(severity: .hold, code: "mxf.cut-short",
                                        message: "\(name) stops before the end a finished \(brand) clip has, so it is cut short.",
                                        paths: [path]))
            }
        }
        if !unproven.isEmpty {
            issues.append(CardIssue(severity: .note, code: "mxf.unconfirmed-ending",
                                    message: "\(unproven.count) MXF file\(unproven.count == 1 ? " doesn't" : "s don't") end the way proven Sony clips do, which may be normal for this camera or may mean a clip cut short, so check the last clips play to the end.",
                                    paths: unproven.sorted()))
        }
        return issues
    }

    // MARK: QuickTime files: BRAW striping and missing indexes

    private enum Finding: Sendable { case noIndex(String), cutShort(String), striped(String), possiblyStriped(String), unknown }

    /// The cameras whose manuals offer "Record RAW on 2 cards".
    private static func canStripe(_ cameraType: String) -> Bool {
        cameraType.contains("URSA Cine") || cameraType.contains("URSA Mini Pro 12K")
    }

    static func quickTimeFiles(_ ctx: CardContext, units: [ClipUnit], extra: [CardFile] = [], _ tally: inout ClipCheckTally) -> [CardIssue] {
        var issues: [CardIssue] = []
        let checks = units.filter { !$0.isStill }.flatMap(\.members).filter { Extensions.quickTime.contains($0.ext) } + extra
        let root = ctx.rootPath

        let found: [[Finding]] = concurrentMap(checks) { f in
            guard let file = ByteFile(path: root + "/" + f.relPath) else { return [.unknown] }
            let state = QuickTime.indexState(file)
            switch state {
            case .missing: return [.noIndex(f.relPath)]
            case .cutShort: return [.cutShort(f.relPath)]
            case .otherContainer: return [.unknown]
            case .present: break
            }
            // `present` also stands for "nothing to judge by". Only the bytes of an index count as a check.
            if file.size == 0 || file.read(at: 0, count: 16).isEmpty { return [.unknown] }
            guard f.ext == "braw", let qt = QuickTime.inspect(file) else { return [] }
            // Proof of a partner is a count above one. `multicard_volume_count` is a name in the BRAW API,
            // not yet seen in a real striped clip, and real clips may not carry it at all.
            if let count = qt.keys["multicard_volume_count"] {
                if let n = count.string.flatMap({ Int($0) }) {
                    if n > 1 { return [.striped(f.relPath)] }
                    if n == 1 { return [] }
                }
                return [.possiblyStriped(f.relPath)]
            }
            return canStripe(qt.key("camera_type") ?? "") ? [.possiblyStriped(f.relPath)] : []
        }

        for (i, findings) in found.enumerated() {
            let unknown = findings.contains { if case .unknown = $0 { true } else { false } }
            tally.add(.index, checks[i], concluded: !unknown)
            for case .noIndex in findings { tally.fail(.index, checks[i]) }
            for case .cutShort in findings { tally.fail(.index, checks[i]) }
        }

        var striped: Set<String> = []
        var possible: [String] = []
        for finding in found.flatMap({ $0 }) {
            switch finding {
            case .unknown: break
            case .noIndex(let path):
                let name = (path as NSString).lastPathComponent
                issues.append(CardIssue(severity: .hold, code: "video.no-index",
                                        message: "\(name) has no index, probably from a recording cut short, so it won't play as it is.",
                                        paths: [path]))
            case .cutShort(let path):
                let name = (path as NSString).lastPathComponent
                issues.append(CardIssue(severity: .hold, code: "video.cut-short",
                                        message: "\(name) ends before its own index says it should, so it is cut short.",
                                        paths: [path]))
            case .striped(let path): striped.insert(path)
            case .possiblyStriped(let path):
                let partner = CardProber.stripedPartnerName(of: path)?.lowercased() ?? ""
                if ctx.sibling(of: path, named: partner) == nil { possible.append(path) }
            }
        }
        for f in ctx.files where f.ext == "braw2" { striped.insert(f.relPath) }
        for path in striped.sorted() {
            let name = (path as NSString).lastPathComponent
            issues.append(CardIssue(severity: .hold, code: "braw.striped",
                                    message: "\(name) is half of a clip recorded across two cards, so both cards must be on the drive in one folder.",
                                    paths: [path]))
        }
        if !possible.isEmpty {
            issues.append(CardIssue(severity: .note, code: "braw.maybe-striped",
                                    message: "If this was recorded across two cards, the second card's .braw2 files must go in the same folder, because a lone .braw plays at half the frame rate with no error and one card alone can't show which case this is.",
                                    paths: possible.sorted()))
        }
        return issues
    }

    // MARK: ARRI

    /// One clip as many files, so one missing frame is a hole. Numbers run contiguous from the first, not from 1.
    /// `.ari` and `.arx` on real ALEXA material, and CinemaDNG, which `kind` has already told from photos.
    static func frameSequences(_ ctx: CardContext, _ tally: inout ClipCheckTally) -> [CardIssue] {
        var clips: [String: [(frame: Int, file: CardFile)]] = [:]
        for f in ctx.files where f.ext == "ari" || f.ext == "arx" || (f.ext == "dng" && f.kind == .video) {
            guard let (prefix, frame) = frameNumber(CardContext.stem(of: f.name)) else { continue }
            clips[CardContext.folder(of: f.relPath) + "/" + prefix, default: []].append((frame, f))
            tally.add(.frameRun, f, concluded: true)
        }
        var issues: [CardIssue] = []
        for key in clips.keys.sorted() {
            guard let frames = clips[key]?.sorted(by: { $0.frame < $1.frame }),
                  let first = frames.first, let last = frames.last else { continue }
            // Uncompressed .ari frames are all one size: 482 real ALEXA LF frames of 12,603,304 bytes. HDE sizes vary.
            if first.file.ext == "ari", let odd = oddFrame(frames.map(\.file)) {
                issues.append(CardIssue(severity: .hold, code: "arri.frame-size",
                                        message: "\(odd.name) is a different size from the other frames of its clip, so it is probably cut short.",
                                        paths: [odd.relPath]))
                tally.fail(.frameRun, odd)
            }
            let distinct = Set(frames.map(\.frame)).count
            guard last.frame - first.frame + 1 != distinct else { continue }
            var missingAt = first.frame
            var before = first
            for f in frames where f.frame >= missingAt {
                if f.frame > missingAt { break }
                before = f
                missingAt += 1
            }
            // Real ALEXA LF frames sit in a resolution folder, so the clip's name comes from the file.
            let clip = frameNumber(CardContext.stem(of: first.file.name))?.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "._")) ?? first.file.name
            let isDNG = first.file.ext == "dng"
            issues.append(CardIssue(severity: .hold, code: isDNG ? "dng.frame-gap" : "arri.frame-gap",
                                    message: "\(isDNG ? "CinemaDNG" : "ARRI") clip \(clip) has missing frames, starting at frame \(missingAt).",
                                    paths: [before.file.relPath]))
            tally.fail(.frameRun, before.file)
        }
        return issues
    }

    /// The first frame that isn't the size most frames are.
    private static func oddFrame(_ frames: [CardFile]) -> CardFile? {
        var counts: [UInt64: Int] = [:]
        for f in frames { counts[f.size, default: 0] += 1 }
        guard counts.count > 1, let usual = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return frames.first { $0.size != usual }
    }

    /// The last run of digits in a stem: `A001C001_140711_R0Z3.0027301` → 27301.
    private static func frameNumber(_ stem: String) -> (prefix: String, frame: Int)? {
        let u = Array(stem.utf8)
        var i = u.count
        while i > 0, u[i - 1].isASCIIDigit { i -= 1 }
        guard i < u.count, u.count - i <= 12, let n = Int(String(decoding: u[i...], as: UTF8.self)) else { return nil }
        return (String(decoding: u[..<i], as: UTF8.self), n)
    }

    static func arriReels(_ ctx: CardContext) -> [CardIssue] {
        var reels: Set<String> = []
        for f in ctx.files {
            guard let top = f.relPath.split(separator: "/").first, f.relPath.contains("/"),
                  ClipName.isARRIReelFolder(String(top)), ClipName.arri(CardContext.stem(of: f.name)) != nil
                    || f.ext == "ale" else { continue }
            reels.insert(String(top))
        }
        guard reels.count > 1 else { return [] }
        return [CardIssue(severity: .note, code: "arri.multiple-reels",
                          message: "This drive holds \(reels.count) ARRI reels: \(reels.sorted().joined(separator: ", ")).",
                          paths: reels.sorted())]
    }

    // MARK: GoPro

    /// Sorted by video number, then chapter: on the card, chapters of different videos are intertwined.
    /// Looping overwrites the oldest chapters, so later chapters alone can be normal: a note.
    /// A hole between chapters that are present can't come from looping, so that is loss: a hold.
    static func goProChapters(_ ctx: CardContext, _ tally: inout ClipCheckTally) -> [CardIssue] {
        var videos: [String: [(chapter: Int, file: CardFile)]] = [:]
        for f in ctx.files {
            guard let g = ClipName.goPro(f.name) else { continue }
            let key = "\(CardContext.folder(of: f.relPath))/\(g.prefix)|\(String(format: "%04d", g.video))"
            videos[key, default: []].append((g.chapter, f))
            tally.add(.chapters, f, concluded: true)
        }
        var issues: [CardIssue] = []
        for key in videos.keys.sorted() {
            guard let chapters = videos[key]?.sorted(by: { $0.chapter < $1.chapter }) else { continue }
            let video = key.split(separator: "|").last.map(String.init) ?? ""
            let found = runIssue(chapters.map(\.chapter), code: "gopro.chapter-gap", paths: chapters.map(\.file.relPath),
                                 hole: { "GoPro video \(video) is missing chapter \(String(format: "%02d", $0))." },
                                 lateStart: { "GoPro video \(video) starts at chapter \(String(format: "%02d", $0)), which is normal after looping and a loss otherwise." })
            if !found.isEmpty { for item in chapters { tally.fail(.chapters, item.file) } }
            issues += found
        }
        return issues
    }

    // MARK: Insta360

    static func insta360(_ ctx: CardContext) -> [CardIssue] {
        var lens0: [String: String] = [:]
        var lens1: Set<String> = []
        for f in ctx.files where f.ext == "insv" {
            let stem = CardContext.stem(of: f.name)
            let folder = CardContext.folder(of: f.relPath)
            if stem.contains("_00_") {
                lens0[folder + "/" + stem] = f.relPath
            } else if stem.contains("_10_") {
                lens1.insert(folder + "/" + stem.replacingOccurrences(of: "_10_", with: "_00_"))
            }
        }
        let single = lens0.filter { !lens1.contains($0.key) }.map(\.value).sorted()
        guard !single.isEmpty else { return [] }
        return [CardIssue(severity: .note, code: "insta360.single-lens",
                          message: "\(single.count) Insta360 clip\(single.count == 1 ? " has" : "s have") one lens file only, which is normal on some bodies and half a sphere on others.",
                          paths: single)]
    }

    // MARK: Codex

    static func codex(_ ctx: CardContext) -> [CardIssue] {
        let marker = ctx.rootPath + "/.codexvfs"
        guard FileManager.default.fileExists(atPath: marker) else { return [] }
        var issues: [CardIssue] = []
        let json = ByteFile(path: marker).map { $0.read(at: 0, count: 256 << 10) } ?? []
        let info = (try? JSONSerialization.jsonObject(with: Data(json))) as? [String: Any]
        let label = info?["volume_label"] as? String
        let volume = (ctx.rootPath as NSString).lastPathComponent

        if volume.lowercased().hasSuffix("_hde") || (label ?? "").lowercased().hasSuffix("_hde") {
            issues.append(CardIssue(severity: .blocker, code: "codex.hde",
                                    message: "This is the HDE view of a Codex drive, so copy the original volume instead.",
                                    paths: []))
        }
        guard let logPath = info?["log_file"] as? String, let log = ByteFile(path: logPath) else {
            issues.append(CardIssue(severity: .hold, code: "codex.crc-unknown",
                                    message: "The Codex log for this drive can't be read, so its CRC errors can't be checked.",
                                    paths: []))
            return issues
        }
        let span = UInt64(32 << 20)
        let start = log.size > span ? log.size - span : 0
        let text = String(decoding: log.read(at: start, count: Int(min(span, log.size))), as: UTF8.self)
        let names = [volume, label ?? volume].map { $0.replacingOccurrences(of: "_hde", with: "", options: .caseInsensitive) }
        let reels = Set(ctx.files.compactMap { $0.relPath.split(separator: "/").first.map(String.init) })
        var bad: [String] = []
        text.enumerateLines { line, _ in
            guard let hit = line.range(of: "CRC ERROR") else { return }
            let tail = line[hit.upperBound...].drop { $0 == ":" || $0 == " " }
            let path = String(tail).trimmingCharacters(in: .whitespaces)
            // A log can name several volumes. A line naming none is counted, rather than dropped.
            let first = path.split(separator: "/").first.map(String.init) ?? ""
            if !path.contains("/") || names.contains(first) || reels.contains(first) { bad.append(path) }
        }
        if !bad.isEmpty {
            issues.append(CardIssue(severity: .blocker, code: "codex.crc",
                                    message: "The Codex log reports \(bad.count) CRC error\(bad.count == 1 ? "" : "s") on this drive, so a copy of it would not be clean.",
                                    paths: bad.filter { $0.contains("/") }))
        }
        return issues
    }
}
