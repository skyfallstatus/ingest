import IngestCore
import SwiftUI

/// What a line can say about itself. Ticks stay grey on every run: only a proved card turns them green.
enum LineMark: Equatable {
    case waiting, running, done, skipped, look, failed

    var spoken: String {
        switch self {
        case .waiting: "not done yet"
        case .running: "in progress"
        case .done: "done"
        case .skipped: "not checked"
        case .look: "needs a look"
        case .failed: "failed"
        }
    }
}

enum LineAction: Hashable {
    case resume, copyAgain(Int), addFolders(Int), checkAgain, chooseFolder, showInFinder(String?), notACard, dismiss, useDrive(id: String, name: String), setUpDrive(id: String, name: String)

    var title: String {
        switch self {
        case .resume: "Resume"
        case .copyAgain(let n): n == 1 ? "Copy Again" : "Copy \(n) Again"
        case .addFolders(let n): n == 1 ? "Add Folder" : "Add \(n) Folders"
        case .checkAgain: "Check Again"
        case .chooseFolder: "Choose Folder…"
        case .showInFinder: "Show in Finder"
        case .notACard: "Not a Card"
        case .dismiss: "Dismiss"
        case .useDrive(_, let name): "Use \(name)"
        case .setUpDrive(_, let name): "Set Up \(name)…"
        }
    }

    /// The fix for what's wrong, on its own line. Everything else stays quiet.
    var isFix: Bool {
        switch self {
        case .resume, .copyAgain, .addFolders, .checkAgain, .useDrive, .setUpDrive: true
        case .chooseFolder, .showInFinder, .notACard, .dismiss: false
        }
    }
}

struct SheetLine: Identifiable, Equatable {
    enum ID: String { case card, drive, readCard, readDrive, clips }
    var id: ID
    var mark: LineMark
    var label: String
    var files: String? = nil
    var gb: String? = nil
    var tally: String? = nil    // "6 of 6": not every file is a clip, so this figure stays out of the column
    var detail: [String] = []
    var actions: [LineAction] = []
    var disagrees = false       // this line's figure is the one that doesn't add up
}

enum BottomKind: Equatable { case idle, notDone, look, failed, safe }
enum FootAction: Equatable { case copy(Int), stop, eject, setUp }

struct BottomLine: Equatable {
    var kind: BottomKind
    var title: String
    var sentence: String
    var action: FootAction? = nil
}

/// The widget's arithmetic for one card. Pure: every word and figure comes from here, so the self-test reads what
/// a person would, and no view gets to decide anything. The same figure has to come out on every line, and the
/// verdict is the bottom line.
struct CardSheet: Equatable {
    var reel: String
    var camera: String?
    var bottom: BottomLine
    var lines: [SheetLine]
    var path: String? = nil
    var canReveal = false
    var showsNaming = false
    var existingShoot: String? = nil
    var newFolderNote: String? = nil
    var meter: Double? = nil
    var rate: String? = nil
    var timeLeft: String? = nil

    func line(_ id: SheetLine.ID) -> SheetLine? { lines.first { $0.id == id } }

    private static func plural(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
    private static func onlyHere(_ n: Int) -> String { n == 1 ? "1 file is only on this card." : "\(n) files are only on this card." }

    /// "61.2", read under the column's unit. A small card keeps a figure that isn't zero.
    static func gb(_ bytes: UInt64) -> String {
        let v = Double(bytes) / 1e9
        return v < 1 && bytes > 0 ? String(format: "%.2f", v) : String(format: "%.1f", v)
    }

    /// Higher is worse. Reading a card is no comfort: it counts as not done.
    @MainActor static func severity(of c: CardSession, in model: AppModel) -> Int {
        if c.isEmpty && c.phase == .finished { return 0 }
        switch make(c, model: model).bottom.kind {
        case .safe, .idle: return 1
        case .look: return 2
        case .notDone: return 3
        case .failed: return 4
        }
    }

    @MainActor static func idle(model: AppModel) -> BottomLine {
        guard let d = model.workingDrive else {
            if let d = model.drives.first { return BottomLine(kind: .idle, title: "Set up \(d.name)", sentence: "Then plug in a card.", action: .setUp) }
            if let v = model.ignored.first {
                return BottomLine(kind: .idle, title: "Plug in your working drive", sentence: "\(v.name) can't be one yet: \(model.whyIgnored(v)) See Drives.", action: .setUp)
            }
            return BottomLine(kind: .idle, title: "Plug in your working drive", sentence: "Then plug in a card.", action: .setUp)
        }
        if d.setup == nil { return BottomLine(kind: .idle, title: "Set up \(d.name)", sentence: "Then plug in a card.", action: .setUp) }
        return BottomLine(kind: .idle, title: "Plug in a card", sentence: "This opens by itself.")
    }

    @MainActor static func make(_ c: CardSession, model: AppModel) -> CardSheet {
        let s = Facts(card: c, model: model)
        let id = c.primaryCamera?.identity
        let camera = [id?.displayModel == "Camera" ? nil : id?.displayModel, id?.serialTail].compactMap { $0 }.joined(separator: " · ")
        let reel = c.probe.reel.flatMap { $0.isEmpty ? nil : $0 } ?? c.name
        if s.isEmptyCard {
            return CardSheet(reel: reel, camera: nil, bottom: BottomLine(kind: .notDone, title: "Don't format", sentence: "There's nothing on this card.", action: .eject),
                             lines: [SheetLine(id: .card, mark: .done, label: "On the card", files: "0", gb: gb(0))])
        }
        var sheet = CardSheet(reel: reel, camera: camera.isEmpty ? nil : camera, bottom: bottom(s),
                              lines: [cardLine(s), driveLine(s), readLine(s, .readCard), readLine(s, .readDrive), clipsLine(s)])
        sheet.path = path(s)
        sheet.canReveal = c.phase == .finished && c.home(on: model.workingDrive) != nil
        sheet.showsNaming = s.canName
        // Add to would need a name that's taken, by a bad copy or by the index a camera has since rewritten.
        let canJoin = c.canJoinHome && !c.states.values.contains { $0.isBadCopyOnDrive }
        sheet.existingShoot = s.canName && canJoin ? c.existingHome : nil
        if s.canName, !canJoin, c.existingHome != nil { sheet.newFolderNote = "This card has changed since it was copied, so it gets a new folder beside the old one." }
        if c.phase == .copying, !finishing(c) {
            // Every file is read from the card twice, so that's the whole of the work.
            let total = max(c.progress?.bytesTotal ?? c.totalBytes, 1)
            show(done: max(c.liveBytes, c.progress?.bytesCopied ?? 0) + c.liveChecked, of: 2 * total, since: c.startedAt, on: &sheet)
        } else if case .checking = c.phase {
            show(done: c.liveChecked, of: max(c.checkBytes, 1), since: c.checkStarted, on: &sheet)
        }
        return sheet
    }

    /// The average since the start, so a pause or a run of small files can't swing the estimate.
    @MainActor private static func show(done: UInt64, of total: UInt64, since start: Date?, on sheet: inout CardSheet) {
        let bytes = min(done, total)
        sheet.meter = Double(bytes) / Double(total)
        guard let start, bytes > 0 else { return }
        let seconds = max(Date().timeIntervalSince(start), 0.1)
        let speed = Double(bytes) / seconds
        sheet.rate = String(format: "%.0f MB/s", speed / 1e6)
        guard seconds > 3 else { return }
        let left = Double(total - bytes) / max(speed, 1)
        sheet.timeLeft = left < 60 ? "Under a minute left" : "About \(Int((left / 60).rounded(.up))) min left"
    }

    /// Everything the lines and the bottom line must agree on.
    @MainActor private struct Facts {
        let card: CardSession
        let model: AppModel
        let driveName: String
        let shortDrive: String          // what fits on a line beside its figures
        let working: Bool               // reading, comparing or proving
        let total: Int, toGo: Int, verified: Int
        let verifiedBytes: UInt64       // settled, before this run
        let settledFiles: Int
        let isSafe: Bool, isEmptyCard: Bool
        let readProblems: [ListingError]
        let copyFailures: [(file: CardFile, why: String)]
        let checkFailures: [(file: CardFile, why: String)]
        let blockers: [CardIssue]
        let clipHolds: [CardIssue]
        let driveHolds: [CardIssue]
        let folderHold: CardIssue?      // empty folders a copy left out, which belong to the copy and not to any clip
        let notes: [CardIssue]
        let split: CardIssue?           // proved across folders, which is about the copy and not about any clip
        let cardChanged: Bool
        let copyError: String?, nameError: String?
        let everythingProved: Bool
        let hasDestination: Bool
        let canName: Bool

        init(card c: CardSession, model: AppModel) {
            card = c
            self.model = model
            driveName = model.workingDrive.map(model.label) ?? "your drive"
            shortDrive = driveName.count > 10 ? "your drive" : driveName
            switch c.phase {
            case .reading, .checking: working = true
            default: working = false
            }
            total = c.totalFiles
            toGo = c.filesToGo
            verified = c.verifiedFiles
            isSafe = c.isSafe(on: model.workingDrive)
            isEmptyCard = c.isEmpty && c.phase == .finished
            readProblems = (c.read?.listing.errors ?? []) + (c.read?.unreadable ?? [])

            var copying: [(file: CardFile, why: String)] = [], checking: [(file: CardFile, why: String)] = []
            var bytes: UInt64 = 0, settled = 0
            for f in c.read?.listing.files ?? [] {
                if case .verified? = c.states[f.relPath] { bytes += f.size; settled += 1 }
                guard case .failed(let why)? = c.states[f.relPath], c.read?.quick[f.relPath] != nil else { continue }
                // A file whose bytes arrived and didn't hold up failed the check. Anything else never got there.
                if why.contains("match") || why.hasPrefix("checking") { checking.append((f, why)) } else { copying.append((f, why)) }
            }
            verifiedBytes = bytes
            settledFiles = settled
            copyFailures = copying
            checkFailures = checking

            blockers = c.issues.filter { $0.severity == .blocker }
            let holds = c.issues.filter { $0.severity == .hold }
            driveHolds = holds.filter { $0.code == "drive.weak-verify" }
            folderHold = holds.first { $0.code == Pipeline.emptyFoldersCode }
            clipHolds = holds.filter { $0.code != "drive.weak-verify" && $0.code != Pipeline.emptyFoldersCode }
            notes = c.issues.filter { $0.severity == .note && $0.code != Pipeline.splitCode }
            split = c.issues.first { $0.code == Pipeline.splitCode }
            cardChanged = c.failureReasons.contains { $0.hasPrefix("The card changed") }

            let onCopyLine = c.pendingDestination != nil || c.volumeGone
            copyError = onCopyLine ? c.error : nil
            nameError = onCopyLine ? nil : c.error

            everythingProved = c.read != nil && c.filesToGo == 0 && c.totalFiles > 0 && c.phase != .copying && c.phase != .queued
            hasDestination = c.pendingDestination != nil
            canName = c.phase == .ready && c.filesToGo > 0 && !hasDestination && !c.volumeGone
                && model.workingDrive?.setup != nil
        }

        /// Nothing else stands between this card and Safe.
        var onlyFoldersMissing: Bool { folderHold != nil && driveHolds.isEmpty && clipHolds.isEmpty && !failed }

        /// What a job hasn't done yet. Files it took on from another folder aren't only on the card.
        var stillToGo: String { card.keptElsewhere ? "\(plural(toGo)) still to copy." : onlyHere(toGo) }

        var failed: Bool {
            guard !working else { return false }
            return !readProblems.isEmpty || !copyFailures.isEmpty || !checkFailures.isEmpty || !blockers.isEmpty
                || cardChanged || copyError != nil
        }

        /// Files read back so far, and their bytes. The engine proves them in card order, one at a time.
        var provedNow: (files: Int, bytes: UInt64) {
            var extra = max(verified - settledFiles, 0), bytes = verifiedBytes
            if case .checking(let done, _) = card.phase { extra = done }
            guard extra > 0, let files = card.read?.listing.files else { return (settledFiles + extra, bytes) }
            var n = extra
            for f in files where n > 0 {
                if case .verified? = card.states[f.relPath] { continue }
                bytes += f.size
                n -= 1
            }
            return (settledFiles + extra, bytes)
        }
    }

    @MainActor private static func finishing(_ c: CardSession) -> Bool {
        guard let p = c.progress, p.phase == .finishing else { return false }
        return p.verifiedFiles >= p.fileCount
    }

    @MainActor private static func bottom(_ s: Facts) -> BottomLine {
        let c = s.card, d = s.driveName
        func no(_ sentence: String, _ kind: BottomKind = .notDone, _ action: FootAction? = nil) -> BottomLine {
            BottomLine(kind: kind, title: "Don't format", sentence: sentence, action: action)
        }
        switch c.phase {
        case .reading:
            return no(c.read != nil ? "Comparing with \(d)." : "Not checked yet.")
        case .checking(let done, let total):
            return no("Checking \(done) of \(total) already on \(d).", .notDone, .stop)
        case .queued:
            return no(s.stillToGo, .notDone, .stop)
        case .copying:
            return no(s.toGo == 0 ? "Making sure \(d) has finished writing." : s.stillToGo, .notDone, .stop)
        case .stopped:
            // With the card or the drive gone, all that can be said is what's not proved. Most of it may well be on the drive.
            let gone = c.volumeGone || s.model.workingDrive == nil
            let unread = c.states.values.reduce(0) { if case .likely = $1 { $0 + 1 } else { $0 } }
            if !gone, unread > 0 { return no("Stopped. \(plural(unread)) still to check.", s.failed ? .failed : .notDone) }
            return no(gone ? "Stopped. \(plural(s.toGo)) not proved yet." : "Stopped. \(s.stillToGo)", s.failed ? .failed : .notDone)
        case .ready, .finished:
            break
        }
        if s.isSafe {
            return BottomLine(kind: .safe, title: "Safe to format", sentence: clipSentence(c.probe.clipChecks), action: .eject)
        }
        if s.failed {
            if !s.checkFailures.isEmpty, s.copyFailures.isEmpty {
                // A bad copy already on the drive is exactly when a real one is needed, so the form keeps its button.
                return no("\(plural(s.checkFailures.count)) didn't match.", .failed, s.canName ? .copy(s.total) : nil)
            }
            // What can be read can still be rescued, so the form that's open keeps its button.
            // With nowhere it was going, or no drive to go on, what failed may well be a copy that's there.
            let there = !s.hasDestination || s.model.workingDrive == nil
            if s.toGo > 0 { return no(there ? "\(plural(s.toGo)) not proved yet." : s.stillToGo, .failed, s.canName ? .copy(s.total) : nil) }
            return no(c.failureReasons.first ?? "Something stopped this card being safe.", .failed)
        }
        if s.onlyFoldersMissing, let n = s.folderHold?.paths.count {
            return no("Every file is on \(d). \(n == 1 ? "1 empty folder isn't." : "\(n) empty folders aren't.")", .look, c.phase == .finished ? .eject : nil)
        }
        if c.isHold { return no("On \(d) and checked, but take a look first.", .look, c.phase == .finished ? .eject : nil) }
        if s.model.workingDrive == nil {
            return no("\(plural(s.total)) on this card. \(s.model.drives.isEmpty ? "Plug in your working drive." : "Choose a working drive.")")
        }
        return no(s.stillToGo, .notDone, s.canName ? .copy(s.total) : nil)     // the form starts a new folder, so that's the whole card
    }

    /// What ran, in the verdict's own sentence. Nothing here claims a clip was played.
    static func clipSentence(_ report: ClipCheckReport) -> String {
        if report.checkedNothing { return "Clips were not checked or played." }
        return report.sentence.replacingOccurrences(of: "Not played.", with: "Clips were not played.")
    }

    @MainActor private static func cardLine(_ s: Facts) -> SheetLine {
        let c = s.card
        var line = SheetLine(id: .card, mark: .done, label: "On the card")
        if case .reading(let done, let total) = c.phase, c.read == nil {
            line.mark = .running
            line.files = total == 0 ? nil : String(done)
            return line
        }
        line.files = String(s.total)
        line.gb = gb(c.totalBytes)
        if let first = s.readProblems.first, !s.working {
            line.mark = .failed
            let more = s.readProblems.count - 1
            line.detail = ["\((first.path as NSString).lastPathComponent)\(more > 0 ? " and \(more) more" : ""): \(first.reason)"]
            line.actions = [.checkAgain]
        } else if s.model.stores.overrides[c.volume.key] == "card", !c.isBusy {
            line.actions = [.notACard]
        }
        return line
    }

    @MainActor private static func driveLine(_ s: Facts) -> SheetLine {
        let c = s.card
        var line = SheetLine(id: .drive, mark: .waiting, label: "On \(s.shortDrive)")
        guard let drive = s.model.workingDrive else {
            let unset = s.model.drives.prefix(2)
            line.label = "On your drive"
            if c.volumeGone, !s.working {           // no drive can carry a card on that's out of the Mac
                line.detail = c.error.map { [$0] } ?? []
                line.actions = [.dismiss]
            } else if c.read != nil, !s.working {
                line.detail = [c.error ?? (unset.isEmpty ? "No working drive. Plug it in to carry on." : "No working drive yet. Choose one to carry on.")]
                line.actions = unset.map { .useDrive(id: $0.id, name: s.model.label(of: $0)) }
            }
            return line
        }
        if c.read == nil { return line }
        func show(_ files: Int, _ bytes: UInt64) { line.files = String(files); line.gb = gb(bytes) }
        switch c.phase {
        case .reading:
            line.mark = .running
            return line
        case .checking(_, let total):
            line.mark = .running
            let likely = (c.read?.listing.files ?? []).reduce(UInt64(0)) { sum, f in
                if case .likely? = c.states[f.relPath] { sum + f.size } else { sum }
            }
            show(s.settledFiles + total, s.verifiedBytes + likely)
            return line
        case .queued:
            show(s.settledFiles, s.verifiedBytes)
            line.detail = ["Waiting for the other card to finish."]
            return line
        case .copying:
            let p = c.progress
            let done = (p?.phase == .copying ? (p?.fileIndex ?? 1) - 1 : (p?.fileIndex ?? 0))
            line.mark = finishing(c) ? .done : .running
            show(s.settledFiles + max(done, p?.verifiedFiles ?? 0), s.verifiedBytes + max(c.liveBytes, p?.bytesCopied ?? 0))
            return line
        case .stopped:
            show(s.settledFiles, s.verifiedBytes)
            if let e = s.copyError { line.detail = [e]; line.mark = .failed }   // the bottom line already says it stopped
            line.actions = c.volumeGone ? [.dismiss] : [.resume]    // nothing can resume with the card gone, and it can't stay for ever
            return line
        case .ready, .finished:
            break
        }
        show(s.settledFiles, s.verifiedBytes)
        if s.working { return line }
        if s.everythingProved {
            line.mark = .done
            if s.shortDrive != s.driveName { line.detail = [s.driveName] }  // whatever the line had room for, the name is said
            if let note = c.badCopyNote { line.detail.append(note) }
            if let split = s.split { line.detail.append(split.message) }
        }
        if drive.setup == nil, !s.hasDestination, s.toGo > 0 {
            line.detail = ["\(drive.name) isn't set up yet."]
            line.actions = [.setUpDrive(id: drive.id, name: s.model.label(of: drive))]
        } else if let e = s.nameError {
            line.mark = .failed
            line.detail = [e]
        } else if let e = s.copyError {
            line.mark = .failed
            line.detail = [e]
            line.actions = c.pendingDestination != nil ? [.copyAgain(max(s.toGo, 1))] : []
        } else if let first = s.copyFailures.first {
            let more = s.copyFailures.count - 1
            line.mark = .failed
            line.disagrees = true
            line.detail = ["\(first.file.name)\(more > 0 ? " and \(more) more" : ""): \(first.why)"]
            line.actions = s.hasDestination ? [.copyAgain(s.toGo)] : []     // with nowhere to go, Copy Again would do nothing
            if s.hasDestination, c.phase == .ready, first.why == FileState.nameTaken {
                line.detail.append("Choose another folder, or remove that file if it's a bad copy, and copy again.")
            }
        } else if s.hasDestination, s.toGo > 0, s.checkFailures.isEmpty {
            line.actions = [.copyAgain(s.toGo)]     // a copy that ended short continues where it was going
        }
        if let hold = s.folderHold, s.everythingProved {
            line.mark = .look
            line.detail.append(hold.message)
            if let e = c.folderError { line.detail.append(e) }
            line.actions = [.showInFinder(nil)]
            if s.onlyFoldersMissing, let read = c.read, Pipeline.home(read: read, states: c.states) != nil {
                let n = hold.paths.count
                if IngestEngine.isReadOnly(driveRoot: drive.path) { line.detail.append("This drive is read-only, so \(n == 1 ? "it" : "they") can't be added here.") }
                else { line.actions.insert(.addFolders(n), at: 0) }
            }
        }
        if s.hasDestination, c.phase == .ready, s.toGo > 0 { line.actions.append(.chooseFolder) }  // or goes somewhere else, and a bad copy holding the name leaves nothing else
        return line
    }

    @MainActor private static func readLine(_ s: Facts, _ id: SheetLine.ID) -> SheetLine {
        let c = s.card, onDrive = id == .readDrive
        var line = SheetLine(id: id, mark: .waiting, label: onDrive ? "Read back from \(s.shortDrive)" : "Read back from card")
        func show() { let p = s.provedNow; line.files = String(p.files); line.gb = gb(p.bytes) }
        switch c.phase {
        case .reading:
            return line
        case .checking:
            line.mark = .running
            show()
            return line
        case .copying:
            line.mark = finishing(c) ? .done : .running
            show()
            return line
        case .queued, .stopped, .ready, .finished:
            break
        }
        if s.verified > 0 { show() }
        if onDrive, let first = s.checkFailures.first {
            let more = s.checkFailures.count - 1
            line.mark = .failed
            line.disagrees = true
            let names = "\(first.file.name)\(more > 0 ? " and \(more) more" : "")"
            line.detail = [first.why.hasPrefix("checking") ? "\(names) couldn't be read back, from the card or the drive." : "\(names) doesn't match."]
            if s.hasDestination, c.phase == .ready, s.checkFailures.contains(where: { $0.why == FileState.badCopy }) {
                line.detail.append("Choose another folder, or remove the bad copy and copy again.")
            }
            line.actions = s.copyFailures.isEmpty && c.pendingDestination != nil ? [.copyAgain(s.toGo)] : []
        } else if !onDrive, s.cardChanged {
            line.mark = .failed
            line.detail = ["The card changed while it was being checked."]
            line.actions = [.checkAgain]
        } else if s.everythingProved {
            line.mark = .done
            if onDrive, let hold = s.driveHolds.first {
                line.mark = .look
                line.detail = [hold.message]
                line.actions = [.showInFinder(nil)]
            }
        }
        return line
    }

    /// Names the check that really ran, for the format on this card.
    private static func clipsLabel(_ r: ClipCheckReport) -> String {
        guard r.counts.count == 1, let c = r.counts.first else { return "Clips checked" }
        switch c.kind {
        case .index: return "\(c.format)s with an index"
        case .mxfEnding: return "\(c.format)s with an ending"
        case .redParts: return "RED clips with all parts"
        case .redNumbers: return "RED clips with no gaps"
        case .frameRun: return "Frame runs with no gap"
        case .chapters: return "GoPro chapters with no gap"
        case .streams: return "Canon streams with no gap"
        }
    }

    @MainActor private static func clipsLine(_ s: Facts) -> SheetLine {
        let c = s.card, report = c.probe.clipChecks
        var line = SheetLine(id: .clips, mark: .waiting, label: c.read == nil ? "Clips" : clipsLabel(report))
        if c.read != nil, report.checkedNothing { line.label = "Clips not checked" }
        if !s.blockers.isEmpty, !s.working {
            line.mark = .failed
            line.detail = s.blockers.prefix(3).map(\.message)
            line.actions = [.checkAgain]
            return line
        }
        if c.phase == .copying, finishing(c) { line.mark = .running; return line }
        guard s.everythingProved, !s.working, !s.failed else { return line }
        let passed = report.counts.reduce(0) { $0 + max($1.checked - $1.failed, 0) }
        let all = report.counts.reduce(0) { $0 + $1.checked + $1.unconfirmed }
        line.tally = report.checkedNothing ? nil : "\(passed) of \(all)"
        if let first = s.clipHolds.first {
            line.mark = .look
            line.detail = s.clipHolds.prefix(3).map(\.message)
            if s.clipHolds.count > 3 { line.detail.append("And \(s.clipHolds.count - 3) more.") }
            line.actions = [.showInFinder(first.paths.first)]
        } else {
            line.mark = report.checkedNothing ? .skipped : .done
        }
        line.detail += s.notes.prefix(2).map(\.message)
        return line
    }

    /// Setup's last line while it waits. With a drive plugged in that can't be used, waiting is the wrong thing to say.
    @MainActor static func waitingForDrive(model: AppModel) -> BottomLine {
        if !model.drives.isEmpty { return BottomLine(kind: .idle, title: "Choose your working drive", sentence: "It's where your footage goes.") }
        if let v = model.ignored.first {
            return BottomLine(kind: .idle, title: "Plug in your working drive", sentence: "\(v.name) can't be one yet: \(model.whyIgnored(v))")
        }
        return BottomLine(kind: .idle, title: "Plug in your working drive", sentence: "It's where your footage goes.")
    }

    @MainActor private static func path(_ s: Facts) -> String? {
        let c = s.card
        if let split = s.split { return "In \(split.paths.count) folders" }
        let drive = s.model.workingDrive
        if c.wentTo(drive), let label = c.shootLabel { return label }
        guard s.hasDestination || (s.everythingProved && !s.working), let home = c.home(on: drive) else { return nil }
        return homeLabel(home, setup: drive?.setup)
    }

    /// "Lantern Bakery Co. / 22.10.26 Spring menu", read back off a folder path.
    @MainActor static func homeLabel(_ path: String, setup: DriveSetup?) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let setup, parts.count > setup.path.count {
            let shoot = parts[setup.path.count]
            if let i = setup.path.firstIndex(of: .client) { return parts[i] + " / " + shoot }
            return shoot
        }
        return parts.suffix(2).joined(separator: " / ")
    }
}

/// The mark and the word in the menu bar. The word "format" appears there only on a proved card.
struct MenuBarState: Equatable {
    var word: String
    var spoken: String
    var isSafe = false
    var twoCards = false

    @MainActor static func make(_ model: AppModel) -> MenuBarState {
        let waiting = model.maybeCards.count + model.unreadable.count
        let total = model.cards.count + waiting
        let several = total > 1
        guard let worst = model.cardsWorstFirst.first else {
            if !model.unreadable.isEmpty {
                return MenuBarState(word: several ? "\(total) cards" : "Can't read", spoken: "\(AppInfo.name) can't read a volume", twoCards: several)
            }
            if !model.maybeCards.isEmpty {
                return MenuBarState(word: several ? "\(total) cards" : "A card?", spoken: "\(AppInfo.name) has a question about a volume", twoCards: several)
            }
            return MenuBarState(word: "", spoken: "\(AppInfo.name), no card plugged in")
        }
        let sheet = CardSheet.make(worst, model: model)
        let name = worst.name
        let drive = model.workingDrive.map(model.label)
        switch sheet.bottom.kind {
        case .safe:
            if !model.unreadable.isEmpty { return MenuBarState(word: "Can't read", spoken: "\(AppInfo.name) can't read a volume", twoCards: several) }
            if !model.maybeCards.isEmpty { return MenuBarState(word: "A card?", spoken: "\(AppInfo.name) has a question about a volume", twoCards: several) }
            let onDrive = drive.map { " on \($0)" } ?? ""
            return MenuBarState(word: "Safe to format", spoken: several ? "All \(total) cards are safe to format\(onDrive)" : "\(name) is safe to format\(onDrive)", isSafe: true, twoCards: several)
        case .look:
            return MenuBarState(word: "Have a look", spoken: "Don't format \(name). It needs a look.", twoCards: several)
        case .failed:
            let word = worst.volumeGone ? "Card pulled" : worst.phase == .stopped ? "Stopped" : "Have a look"
            return MenuBarState(word: word, spoken: "Don't format \(name). \(sheet.bottom.sentence)", twoCards: several)
        case .notDone, .idle:
            if worst.isEmpty && worst.phase == .finished {
                return MenuBarState(word: "Empty", spoken: "\(name) is empty", twoCards: several)
            }
            let word: String
            switch worst.phase {
            case .reading: word = "Reading"
            case .checking: word = "Checking"
            case .copying, .queued: word = worst.filesToGo == 0 ? "Checking" : "\(worst.filesToGo) left"
            case .stopped: word = "Stopped"
            // A menu bar that's out of room hides the item, so a long name stays out of it.
            default: word = several ? "\(total) cards" : drive.map { $0.count > 16 ? "Not on drive" : "Not on \($0)" } ?? "No drive"
            }
            return MenuBarState(word: word, spoken: "Don't format \(name). \(sheet.bottom.sentence)", twoCards: several)
        }
    }
}
