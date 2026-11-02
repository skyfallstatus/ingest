// Reading who shot a clip, and when, from its bytes.
import Foundation
import ImageIO

struct ClipFacts {
    var identity: CameraIdentity?
    /// A second key for the same body, so samples read different ways still merge. Sony systemId.
    var altKey: String?
    var day: CalendarDay?
    var source: DateSource?
}

/// One per probe. Caches by path, and caches each Sony body's serial so `rtmd` is read only until found.
final class ClipReader {
    let ctx: CardContext
    private var memo: [String: ClipFacts] = [:]
    private var sonySerials: [String: String] = [:]
    /// Reading a 16 MiB MXF header is fine once or twice a card, not for every sampled clip.
    private var deepHeaderReads = 2
    private(set) var sonyMedia: [(root: String, profile: SonyProfile)] = []

    init(_ ctx: CardContext) {
        self.ctx = ctx
        sonyMedia = Sony.findProfiles(ctx)
    }

    func facts(_ unit: ClipUnit) -> ClipFacts {
        let key = unit.primary.relPath
        if let known = memo[key] { return known }
        var f = ClipFacts()
        if let file = ctx.open(key) {
            let ext = unit.primary.ext
            if unit.isStill {
                readStill(file, unit, &f)
            } else if Extensions.audio.contains(ext) {
                readAudio(file, unit, &f)
            } else {
                switch ext {
                case "r3d": readR3D(file, unit, &f)
                case "mxf": readMXF(file, unit, &f)
                case "ari", "arx":
                    f.identity = arri(unit, model: ARRIMetadata.modelInFrame(file), serial: nil)
                case "dng": readStill(file, unit, &f)
                case "braw2": break
                default: readQuickTime(file, unit, &f)
                }
            }
        }
        fallback(unit, &f)
        memo[key] = f
        return f
    }

    private func setDay(_ f: inout ClipFacts, _ day: CalendarDay?, _ source: DateSource) {
        guard f.day == nil, let day else { return }
        f.day = day
        f.source = source
    }

    // MARK: Last resorts

    private func fallback(_ unit: ClipUnit, _ f: inout ClipFacts) {
        let name = unit.primary.name
        let stem = CardContext.stem(of: name)
        let ext = unit.primary.ext

        if f.identity == nil { f.identity = sonyFromProfile(unit, &f) }
        if f.identity == nil, ext == "ari" || ext == "arx" || ext == "mxf", let id = arri(unit, model: nil, serial: nil) {
            f.identity = id
        }
        if f.identity == nil, let family = Self.familyOfExtension[ext] { f.identity = identity(family) }
        if f.identity?.family == .dji { setDay(&f, ClipName.djiDay(stem), .fileName) }
        if f.identity == nil, CardContext.components(unit.primary.relPath.lowercased()).dropLast().contains(where: { $0.hasSuffix(".rdc") }) {
            f.identity = identity(.red)
        }
        if f.identity == nil, isRecorderPath(unit.primary.relPath) {
            f.identity = CameraIdentity(family: .audioRecorder, displayModel: "Recorder", modelIsCertain: false)
        }
        if f.identity == nil, let hint = ctx.structureHint { f.identity = identity(hint) }

        if f.identity?.family != .blackmagic { setDay(&f, ClipName.cinemaDay(stem), .fileName) }
        if unit.primary.mtime > 0 { setDay(&f, WrittenDate.localDay(unix: unit.primary.mtime), .fileModified) }
    }

    /// Extensions only one family writes. The weakest evidence there is, so it comes last.
    private static let familyOfExtension: [String: CameraFamily] = [
        "braw": .blackmagic, "braw2": .blackmagic, "insv": .insta360, "osv": .dji, "nev": .nikon,
    ]

    private func isRecorderPath(_ relPath: String) -> Bool {
        CardContext.components(relPath.lowercased()).dropLast().contains {
            $0.hasSuffix(".take") || $0 == "false take" || $0 == "falsetakes"
        }
    }

    private func sonyFromProfile(_ unit: ClipUnit, _ f: inout ClipFacts) -> CameraIdentity? {
        let lower = unit.primary.relPath.lowercased()
        guard let hit = sonyMedia.first(where: { lower.hasPrefix($0.root.lowercased() + "/") }) else { return nil }
        f.altKey = hit.profile.systemId
        return Sony.identity(model: hit.profile.model, serial: nil, systemId: hit.profile.systemId)
    }

    // MARK: Sony

    private func sonyClip(_ xml: String, file: ByteFile?, qt: QTInfo?, mxfHead: [UInt8]? = nil, _ f: inout ClipFacts) {
        guard let clip = Sony.parseClipXML(xml) else { return }
        var serial = CameraNames.cleanSerial(clip.serial)
        let systemId = clip.systemId
        if serial == nil, let systemId { serial = sonySerials[systemId] }
        if serial == nil, let file, let qt, let model = clip.model { serial = Sony.rtmdSerial(file, qt, model: model) }
        if serial == nil, let mxfHead, let model = clip.model { serial = Sony.scanSerial(mxfHead, model: model) }
        if let serial, let systemId { sonySerials[systemId] = serial }
        f.altKey = systemId
        if let model = clip.model { f.identity = Sony.identity(model: model, serial: serial, systemId: systemId) }
        setDay(&f, clip.day, .cameraMetadata)
    }

    private func sidecarXML(_ unit: ClipUnit) -> String? {
        let stem = CardContext.stem(of: unit.primary.name)
        guard let rel = ctx.sibling(of: unit.primary.relPath, named: (stem + "M01.XML").lowercased()),
              let side = ctx.open(rel) else { return nil }
        let text = String(decoding: side.read(at: 0, count: 256 << 10), as: UTF8.self)
        return text.contains("<NonRealTimeMeta") ? text : nil
    }

    // MARK: MXF

    private func readMXF(_ file: ByteFile, _ unit: ClipUnit, _ f: inout ClipFacts) {
        guard let info = MXF.parse(file) else { return }

        if let xml = Sony.embeddedXML(inMXFHead: info.head) ?? sidecarXML(unit) {
            sonyClip(xml, file: nil, qt: nil, mxfHead: info.head, &f)
            if f.identity != nil { return }
        }
        let company = (info.company ?? "").lowercased()
        let product = info.product.flatMap { $0.isEmpty ? nil : $0 }
        let named = ["canon", "panasonic", "blackmagic", "sony"].contains { company.contains($0) }
        let isARRI = company.contains("arri") || (!named && ARRIMetadata.mentionsARRI(info.head))

        if isARRI {
            let deep = deepHeaderReads > 0
            let meta = ARRIMetadata.read(file, head: info.head, deep: deep)
            if deep, meta.model == nil { deepHeaderReads -= 1 }
            let model = meta.model ?? product.flatMap { $0.uppercased().contains("ALEXA") || $0.uppercased().contains("AMIRA") ? $0 : nil }
                ?? aleModel(unit)
            f.identity = arri(unit, model: model, serial: meta.serial, certainFamily: true)
        } else if company.contains("canon") {
            let model = product.map { $0.hasPrefix("Canon") ? $0 : "Canon " + $0 }
            f.identity = identity(.canon, model: model)
        } else if company.contains("panasonic") {
            f.identity = identity(.panasonic, model: product ?? p2Model(unit))
        } else if company.contains("blackmagic") {
            f.identity = identity(.blackmagic, model: product)
        } else if company.contains("sony") {
            f.identity = identity(.sony, model: Sony.cineModel(inHead: info.head))
        } else if ctx.byLowerPath["lastclip.txt"] != nil {
            f.identity = identity(.panasonic, model: p2Model(unit))
        }
        setDay(&f, ClipName.cinemaDay(CardContext.stem(of: unit.primary.name)), .fileName)
        setDay(&f, info.modified, .containerUTC)
    }

    /// P2 keeps one XML per clip in CONTENTS/CLIP. Field names are from memory of real files, so never trusted alone.
    private func p2Model(_ unit: ClipUnit) -> String? {
        let stem = CardContext.stem(of: unit.primary.name).lowercased()
        guard let rel = ctx.byLowerPath["contents/clip/\(stem).xml"], let file = ctx.open(rel) else { return nil }
        let text = String(decoding: file.read(at: 0, count: 64 << 10), as: UTF8.self)
        guard let open = text.range(of: "<ModelName>"), let close = text.range(of: "</ModelName>", range: open.upperBound ..< text.endIndex) else { return nil }
        let name = String(text[open.upperBound ..< close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The ALE in the reel folder holds the static metadata of every clip.
    private func aleModel(_ unit: ClipUnit) -> String? {
        var folder = CardContext.folder(of: unit.primary.relPath)
        for _ in 0 ..< 2 {
            if let ale = ctx.byFolder[folder]?.first(where: { $0.ext == "ale" }), let file = ctx.open(ale.relPath),
               let model = ARRIMetadata.modelInALE(file) { return model }
            guard !folder.isEmpty else { break }
            folder = CardContext.folder(of: folder)
        }
        return nil
    }

    /// Anything ARRI, whichever way it was recognised. Filename alone is the weakest route.
    private func arri(_ unit: ClipUnit, model: String?, serial: String?, certainFamily: Bool = false) -> CameraIdentity? {
        let ext = unit.primary.ext
        let stem = CardContext.stem(of: unit.primary.name)
        let name = ClipName.arri(stem)
        let inReelFolder = CardContext.components(unit.primary.relPath).dropLast().contains {
            ClipName.isARRIReelFolder($0) && $0 == name?.reelFolder
        }
        guard certainFamily || ext == "ari" || ext == "arx" || name != nil && (ext == "mxf" || inReelFolder) else { return nil }
        let model = model ?? aleModel(unit)
        let finalSerial = CameraNames.cleanSerial(serial) ?? name?.serial
        return CameraIdentity(family: .arri, make: "ARRI", model: model,
                              displayModel: model.map { CameraNames.display(family: .arri, model: $0) } ?? "ALEXA",
                              serial: finalSerial, bodyKey: finalSerial, modelIsCertain: model != nil)
    }

    private func identity(_ family: CameraFamily, make rawMake: String? = nil, model: String? = nil, serial: String? = nil, certain: Bool = true) -> CameraIdentity {
        let clean = CameraNames.cleanSerial(serial)
        let make = CameraNames.make(family) ?? rawMake
        guard let model, !model.isEmpty else {
            return CameraIdentity(family: family, make: make, displayModel: CameraNames.shortBrand(family), serial: clean, bodyKey: clean, modelIsCertain: false)
        }
        return CameraIdentity(family: family, make: make, model: model,
                              displayModel: CameraNames.display(family: family, model: model),
                              serial: clean, bodyKey: clean, modelIsCertain: certain)
    }

    // MARK: R3D

    private func readR3D(_ file: ByteFile, _ unit: ClipUnit, _ f: inout ClipFacts) {
        // The bytes decide, not the name: Nikon lets the owner change the DSC prefix.
        guard R3D.hasMagic(file) else {
            let atoms = QuickTime.startsWithAtom(file.read(at: 0, count: 8))
            let nikon = CardContext.isInDCIM(unit.primary.relPath) || Nikon.isNikonRaw(file)
            guard atoms || nikon else { return }
            readQuickTime(file, unit, &f)
            if f.identity == nil, nikon { f.identity = identity(.nikon) }
            return
        }
        let tags = R3D.tags(file)
        let brain = tags[0x10A0].flatMap { $0.isEmpty ? nil : $0 }
        let network = tags[0x1071].flatMap { $0.isEmpty ? nil : $0 }
        let looksNikon = (brain ?? network ?? "").uppercased().hasPrefix("NIKON")
        if looksNikon || CardContext.isInDCIM(unit.primary.relPath) {
            f.identity = identity(.nikon, model: brain ?? network, serial: tags[0x1006], certain: looksNikon)
        } else {
            let model = brain ?? network
            let pin = CameraNames.cleanSerial(tags[0x1006])
            f.identity = CameraIdentity(family: .red, make: "RED", model: model,
                                        displayModel: model.map { CameraNames.safeFolderName($0, fallback: "RED") } ?? "RED",
                                        serial: pin, bodyKey: pin, modelIsCertain: brain != nil)
        }
        setDay(&f, tags[0x1023].flatMap(WrittenDate.day), .cameraMetadata)
    }

    // MARK: QuickTime

    private func readQuickTime(_ file: ByteFile, _ unit: ClipUnit, _ f: inout ClipFacts) {
        let stem = CardContext.stem(of: unit.primary.name)
        let ext = unit.primary.ext
        let qt = QuickTime.inspect(file)

        if let qt {
            let embedded = Sony.nrtmXML(file, qt)
            if qt.major == "XAVC" || embedded != nil {
                if let xml = sidecarXML(unit) ?? embedded { sonyClip(xml, file: file, qt: qt, &f) }
                if f.identity == nil, let id = sonyFromProfile(unit, &f) { f.identity = id }
                if f.identity == nil { f.identity = identity(.sony) }
                setDay(&f, ClipName.cinemaDay(stem), .fileName)
                setDay(&f, qt.mvhdCreation.flatMap(WrittenDate.utcDay), .containerUTC)
                return
            }
            if isApple(qt) {
                let model = qt.key("com.apple.quicktime.model") ?? qt.udtaText(file, "©mod")
                f.identity = identity(.apple, model: model.map(CameraNames.apple))
            } else if isBlackmagic(qt) {
                readBlackmagic(qt, stem: stem, &f)
            } else if qt.keys.keys.contains(where: { $0.hasPrefix("com.arri.camera.") }) {
                let model = qt.key("com.arri.camera.CameraModel")
                f.identity = arri(unit, model: model, serial: qt.key("com.arri.camera.CameraSerialNumber"), certainFamily: true)
                setDay(&f, ClipName.cinemaDay(stem), .fileName)
            } else if Canon.isCanon(file, qt) {
                readCanon(file, qt, stem: stem, &f)
            } else if qt.udta["NCDT"] != nil {
                let tags = Nikon.tags(file, qt)
                f.identity = identity(.nikon, model: tags.model, serial: tags.serial)
                setDay(&f, tags.date, .cameraMetadata)
            } else if let dji = djiModel(file, qt) {
                let serial = DJI.serial(file, qt)
                f.identity = identity(.dji, model: dji.isEmpty ? nil : dji, serial: serial)
                setDay(&f, ClipName.djiDay(stem), .fileName)
            } else if isGoPro(qt) {
                let g = qt.udta["GPMF"].map { AtomWalker.payload(file, $0, cap: 64 << 10) } ?? []
                f.identity = identity(.gopro, model: GPMF.string(g, key: "MINF"), serial: GPMF.string(g, key: "CASN"))
            } else if let pana = qt.udta["PANA"] {
                let text = AtomWalker.payload(file, pana, cap: 4096)
                f.identity = identity(.panasonic, model: firstMatch(panaModel, text))
                setDay(&f, ClipName.cinemaDay(stem), .fileName)
            } else if let fuji = qt.udta["FFMV"] ?? qt.udta["MVTG"] ?? qt.udta["TAGS"] {
                let text = AtomWalker.payload(file, fuji, cap: 4096)
                f.identity = identity(.fujifilm, model: firstMatch(fujiModel, text))
            }
            setDay(&f, qt.key("com.apple.quicktime.creationdate").flatMap(WrittenDate.day), .cameraMetadata)
            if f.identity == nil { readGenericMake(file, qt, &f) }
        }

        if ext == "insv" || ext == "lrv" || f.identity == nil, let t = Insta360.trailer(file) {
            f.identity = identity(.insta360, model: t.model, serial: t.serial)
            f.identity?.displayModel = t.model.map { CameraNames.safeFolderName($0, fallback: "Insta360") } ?? "Insta360"
            setDay(&f, ClipName.instaDay(stem), .fileName)
        } else if ext == "insv" {
            setDay(&f, ClipName.instaDay(stem), .fileName)
        }
        setDay(&f, qt?.mvhdCreation.flatMap(WrittenDate.utcDay), .containerUTC)
    }

    /// The Blackmagic Cam app writes Blackmagic keys on an iPhone, so this is read from values, and first.
    private func isApple(_ qt: QTInfo) -> Bool {
        let make = qt.key("com.apple.quicktime.make") ?? ""
        let model = qt.key("com.apple.quicktime.model") ?? ""
        let pro = qt.key("com.apple.proapps.manufacturer") ?? ""
        return make.hasPrefix("Apple") || model.hasPrefix("Apple") || model.hasPrefix("iPhone")
            || model.hasPrefix("iPad") || pro.hasPrefix("Apple")
    }

    private func isBlackmagic(_ qt: QTInfo) -> Bool {
        (qt.key("manufacturer") ?? "").hasPrefix("Blackmagic")
            || (qt.key("com.apple.proapps.manufacturer") ?? "").hasPrefix("Blackmagic")
            || (qt.key("camera_type") ?? "").hasPrefix("Blackmagic")
    }

    private static let textbookUUID = "123e4567-e89b-12d3-a456-426655440000"

    private func readBlackmagic(_ qt: QTInfo, stem: String, _ f: inout ClipFacts) {
        let model = qt.key("camera_type") ?? qt.key("com.blackmagic-design.cameraType")
            ?? qt.key("com.apple.proapps.modelName") ?? qt.key("com.blackmagic-design.camera.cameraType")
        var id = identity(.blackmagic, model: model)
        if let uuid = qt.key("camera_id") ?? qt.key("com.blackmagic-design.cinemacamera.uuid"), uuid.lowercased() != Self.textbookUUID, CameraNames.cleanSerial(uuid) != nil {
            id.bodyKey = uuid
        }
        f.identity = id

        let written = qt.key("date_recorded") ?? qt.key("com.blackmagic-design.camera.dateRecorded")
        setDay(&f, written.flatMap(WrittenDate.day), .cameraMetadata)
        setDay(&f, qt.key("com.apple.quicktime.creationdate").flatMap(WrittenDate.day), .cameraMetadata)
        guard let utc = qt.mvhdCreation.flatMap(WrittenDate.utcDay) else { return }
        // The filename holds wall-clock month and day, mvhd the year. Within a day of each other, the filename wins.
        if let md = ClipName.blackmagicMonthDay(stem) {
            for year in [utc.year, utc.year - 1, utc.year + 1] {
                let named = CalendarDay(year: year, month: md.month, day: md.day)
                if WrittenDate.isValid(named), WrittenDate.daysApart(named, utc) <= 1 {
                    setDay(&f, named, .fileName)
                }
            }
        }
        setDay(&f, utc, .containerUTC)
    }

    private func readCanon(_ file: ByteFile, _ qt: QTInfo, stem: String, _ f: inout ClipFacts) {
        let c = Canon.read(file, qt)
        f.identity = identity(.canon, model: c.model, serial: c.serial)
        setDay(&f, c.date, .cameraMetadata)
        setDay(&f, ClipName.cinemaDay(stem), .fileName)
    }

    private func isGoPro(_ qt: QTInfo) -> Bool {
        if qt.udta["GPMF"] != nil { return true }
        return qt.tracks.contains { $0.handlerName.contains("GoPro") }
    }

    /// The DJI model from `©too`, the empty string for DJI with no readable model, nil when not DJI.
    private func djiModel(_ file: ByteFile, _ qt: QTInfo) -> String? {
        if let too = qt.ilst["©too"], too.hasPrefix("DJI") { return too == "DJI" ? "" : too }
        guard qt.tracks.contains(where: { $0.format == "djmd" || $0.handlerName.hasPrefix("DJI") }) else { return nil }
        return ""
    }

    private let panaModel = regex(#"\b(DC-[A-Z0-9]+|DMC-[A-Z0-9]+|AG-[A-Z0-9]+|AU-[A-Z0-9]+)\b"#)
    private let fujiModel = regex(#"\b(X-[A-Z0-9]+|GFX ?[0-9]+[A-Z0-9 ]*)"#)

    private func firstMatch(_ re: NSRegularExpression?, _ bytes: [UInt8]) -> String? {
        captures(re, bytes.printableLines)?.first?.trimmingCharacters(in: .whitespaces)
    }

    /// A clip from something else that still says what made it. `Lavf` and export tools say nothing here.
    private func readGenericMake(_ file: ByteFile, _ qt: QTInfo, _ f: inout ClipFacts) {
        let make = qt.key("com.apple.quicktime.make") ?? qt.udtaText(file, "©mak")
        let model = qt.key("com.apple.quicktime.model") ?? qt.udtaText(file, "©mod")
        guard let model, !model.isEmpty else { return }
        let family = make.flatMap(CameraNames.family(forMake:)) ?? .unknown
        f.identity = identity(family, make: make, model: model)
    }

    // MARK: Stills

    private func readStill(_ file: ByteFile, _ unit: ClipUnit, _ f: inout ClipFacts) {
        let url = URL(fileURLWithPath: file.path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            applyEXIF(source, &f)
        }
        // New Canon bodies can lag ImageIO, and a CR3 is QuickTime-shaped underneath.
        if f.identity == nil, unit.primary.ext == "cr3" { readQuickTime(file, unit, &f) }
    }

    private func applyEXIF(_ source: CGImageSource, _ f: inout ClipFacts) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any]
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        // Real Pocket 4K CinemaDNG has no TIFF Make or Model, only UniqueCameraModel.
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? (dng?[kCGImagePropertyDNGUniqueCameraModel] as? String)
        let serial = (exif?[kCGImagePropertyExifBodySerialNumber] as? String) ?? (dng?[kCGImagePropertyDNGCameraSerialNumber] as? String)
        if let model, !model.isEmpty {
            let family = make.flatMap(CameraNames.family(forMake:)) ?? CameraNames.family(forMake: model) ?? .unknown
            var id = identity(family, make: make, model: model, serial: serial)
            if family == .insta360 { id.displayModel = CameraNames.safeFolderName(model, fallback: "Insta360") }
            if family == .blackmagic { id.serial = nil }    // a UUID, as in BRAW: a body key, never a serial
            f.identity = id
        }
        setDay(&f, (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(WrittenDate.day), .cameraMetadata)
    }

    // MARK: Audio

    private func readAudio(_ file: ByteFile, _ unit: ClipUnit, _ f: inout ClipFacts) {
        guard let info = RIFF.parse(file) else { return }
        if let recorder = AudioRecorders.identify(info) {
            f.identity = CameraIdentity(family: .audioRecorder, make: recorder.make, model: recorder.model,
                                        displayModel: CameraNames.safeFolderName(recorder.model ?? recorder.make ?? "Recorder", fallback: "Recorder"),
                                        serial: recorder.serial, bodyKey: recorder.serial, modelIsCertain: recorder.model != nil)
        }
        setDay(&f, info.originationDate.flatMap(WrittenDate.day), .cameraMetadata)
    }
}

extension QTInfo {
    /// `moov/udta` text items such as `©mod`: u16 length, u16 language, text.
    func udtaText(_ file: ByteFile, _ type: FourCC) -> String? {
        guard let atom = udta[type] else { return nil }
        let b = AtomWalker.payload(file, atom, cap: 256)
        guard let length = b.be16(0), length > 0, Int(length) + 4 <= b.count else { return nil }
        let s = b.text(from: 4, length: Int(length))
        return s.isEmpty ? nil : s
    }
}
