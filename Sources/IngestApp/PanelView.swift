import AppKit
import IngestCore
import SwiftUI

/// What the widget knows about its own window.
@MainActor @Observable final class PanelUI {
    var isKey = false
    var maxBodyHeight: CGFloat = 4000
    var page: LibraryView.Page?             // nil is the card in front of you
    var setup: SetupRequest?                // over whichever of those is showing, until it's done
    var feedback: FeedbackReport.Kind?      // a report being written, also over whichever is showing
    var feedbackDraft = ""                  // survives the widget closing: going to the browser closes it
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?
}

/// Someone setting up a drive. Each one starts fresh, even for the same drive.
struct SetupRequest: Identifiable {
    let id = UUID()
    let drive: DriveState?
}

/// The widget. Only ever about the cards in front of you; History and the rest slide in behind one quiet control.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUI.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        .frame(height: min(contentHeight, ui.maxBodyHeight))
        .frame(width: Grid.width)
        .background(Color.surface)
        .foregroundStyle(Color.ink)
        .quietAnimation(contentHeight, reduceMotion: reduceMotion, duration: 0.3)
        .onPreferenceChange(ContentHeight.self) { h in
            contentHeight = h
            ui.onHeight?(min(h, ui.maxBodyHeight))
        }
    }

    @ViewBuilder private var content: some View {
        if let setup = ui.setup {
            SetupHost(start: setup.drive) { ui.setup = nil }.id(setup.id)
        } else if let feedback = ui.feedback {
            FeedbackPage(kind: feedback)
        } else if let page = ui.page {
            LibraryView(page: page)
        } else {
            let cards = model.cardsWorstFirst
            VStack(spacing: 0) {
                if cards.isEmpty && model.maybeCards.isEmpty && model.unreadable.isEmpty { IdleSheet() }
                ForEach(model.unreadable) { v in UnreadableSheet(volume: v, first: v.id == model.unreadable.first?.id) }
                ForEach(model.maybeCards, id: \.volume.id) { m in
                    MaybeCardSheet(volume: m.volume, reason: m.reason, first: model.unreadable.isEmpty && m.volume.id == model.maybeCards.first?.volume.id)
                }
                ForEach(cards) { c in SheetView(card: c, first: model.unreadable.isEmpty && model.maybeCards.isEmpty && c === cards.first) }
            }
        }
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The one quiet control. Everything that isn't the card lives here and on a right-click of the mark.
struct MoreMenu: View {
    var body: some View {
        PullDown(symbol: "ellipsis", color: .tertiaryLabelColor, size: 12, spoken: "History, Cameras, Drives, Settings, updates, feedback and Quit",
                 entries: Windows.shared.bar?.entries ?? [])
            .frame(width: 22, height: 20)
    }
}

struct SheetHead: View {
    let title: String
    var detail: String? = nil
    var first = true        // one quiet control, however many cards are in
    var close: (() -> Void)? = nil      // takes that control's place in setup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).font(.reel).kerning(-0.18).lineLimit(1).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.small12).monospacedDigit().foregroundStyle(Color.ink2).lineLimit(1) }
            Spacer(minLength: 0)
            if let close {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(IconStyle(tint: .ink3)).accessibilityLabel("Close")
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            } else if first { MoreMenu().alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 } }
        }
        .padding(.top, 13).padding(.bottom, 3)
        .padding(.leading, Grid.side).padding(.trailing, 12)
    }
}

/// Label left, real value right, in columns every line shares: the eye reads straight down the 148s.
private struct LineRow: View {
    let line: SheetLine
    var proved = false

    var body: some View {
        HStack(spacing: 0) {
            MarkView(mark: line.mark, proved: proved).padding(.trailing, Grid.markGap)
            Text(line.label).foregroundStyle(line.mark == .waiting ? Color.ink2 : Color.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let tally = line.tally {
                Text(tally).monospacedDigit().foregroundStyle(Color.ink2)
            } else {
                value(line.files).frame(width: Grid.files, alignment: .trailing)
                value(line.gb).frame(width: Grid.gb, alignment: .trailing).padding(.leading, 8)
            }
        }
        .font(.body13).kerning(-0.08)
        .frame(height: Grid.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.label), \(proved ? "proved" : line.mark.spoken)")
        .accessibilityValue([line.files.map { "\($0) files" }, line.gb.map { "\($0) gigabytes" }, line.tally].compactMap { $0 }.joined(separator: ", "))
    }

    private func value(_ text: String?) -> some View {
        Text(text ?? "").monospacedDigit()
            .fontWeight(line.disagrees ? .semibold : .regular)
            .foregroundStyle(line.disagrees ? Color.bad : Color.ink)
    }
}

/// What a line has to say for itself, with the fix on the same line.
private struct LineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUI.self) private var ui
    let card: CardSession
    let line: SheetLine

    var body: some View {
        if !line.detail.isEmpty || !line.actions.isEmpty {
            // Beside the fix when the two fit on a line, over it when they don't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { words.fixedSize(); Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: 6) {
                    words
                    if !line.actions.isEmpty { HStack(spacing: 6) { Spacer(minLength: 0); actions } }
                }
            }
            .padding(.leading, Grid.text).padding(.top, 1).padding(.bottom, 7)
            .transition(.opacity)
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(line.detail.enumerated()), id: \.offset) { _, t in
                Text(t).font(.small12).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(line.mark == .failed || line.mark == .look ? Color.ink : Color.ink2)
            }
        }
    }

    private var actions: some View {
        ForEach(line.actions, id: \.self) { a in
            Button(a.title) { perform(a) }
                .buttonStyle(ActionStyle(kind: a.isFix ? .primary : .quiet, small: true))
        }
    }

    private func perform(_ action: LineAction) {
        switch action {
        case .resume: model.resume(card)
        case .copyAgain: model.retry(card)
        case .checkAgain: model.recheck(card)
        case .chooseFolder: Windows.shared.chooseFolder(card: card, model: model)
        case .showInFinder(let rel): model.reveal(rel, of: card)
        case .notACard: model.forgetChoice(for: card.volume)
        case .dismiss: model.dismiss(card)
        case .useDrive(let id, _):
            guard let d = model.drives.first(where: { $0.id == id }) else { return }
            model.use(drive: d)
            if d.setup == nil { ui.setup = SetupRequest(drive: d) }
        case .setUpDrive(let id, _):
            if let d = model.drives.first(where: { $0.id == id }) { ui.setup = SetupRequest(drive: d) }
        }
    }
}

/// The bottom line. One container in every state: the words change, and only a proved card fills it.
struct Foot<Action: View>: View {
    let bottom: BottomLine
    var green = false
    @ViewBuilder var action: Action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String? {
        switch bottom.kind {
        case .idle: nil
        case .notDone, .failed: "nosign"
        case .look: "exclamationmark.triangle"
        case .safe: green ? "checkmark.seal.fill" : nil
        }
    }

    /// Don't format never appears on green: the old words leave first, then the fill.
    private var words: (title: String, sentence: String) {
        bottom.kind == .safe && !green ? ("", "") : (bottom.title, bottom.sentence)
    }

    private var swap: AnyTransition {
        reduceMotion ? .opacity.animation(.easeOut(duration: 0.15))
            : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)), removal: .opacity.animation(.easeOut(duration: 0.09)))
    }

    var body: some View {
        let idle = bottom.kind == .idle
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                if !idle {
                    Image(systemName: symbol ?? "circle").font(.system(size: 16, weight: .semibold)).frame(width: 18, height: 20)
                        .padding(.leading, -2).frame(width: Grid.text, alignment: .leading)
                        .opacity(symbol == nil ? 0 : 1)
                        .accessibilityHidden(true)
                }
                ZStack(alignment: .leading) {
                    Text(words.title).id(words.title).transition(swap)
                        .font(idle ? .reel : .verdict).kerning(idle ? -0.18 : -0.37).lineLimit(1)
                }
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                action
            }
            .frame(height: 26)
            ZStack(alignment: .leading) {
                Text(words.sentence).id(bottomKey).transition(swap)
                    .font(.small12).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(idle ? Color.ink2 : green ? Color.white : Color.ink)
            }
            .padding(.leading, idle ? 0 : Grid.text)
            .frame(minHeight: 16, alignment: .leading)
        }
        .padding(.top, 10).padding(.bottom, 12)
        .padding(.horizontal, Grid.side)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(green ? Color.white : Color.ink)
        .background(green ? Color.safe : Color.foot)
        .overlay(alignment: .top) { if !green { Rectangle().fill(Color.line).frame(height: 0.5) } }
        .animation(reduceMotion || Motion.off ? nil : .easeInOut(duration: 0.24), value: green)
        .animation(reduceMotion || Motion.off ? nil : .easeOut(duration: 0.2), value: words.title)
    }

    /// A falling count changes in place. A new sentence swaps.
    private var bottomKey: String { String(words.sentence.drop { $0.isNumber }) }
}

private struct IdleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUI.self) private var ui

    var body: some View {
        let drive = model.workingDrive ?? model.drives.first
        let bottom = CardSheet.idle(model: model)
        VStack(spacing: 0) {
            SheetHead(title: "No card")
            if let drive {
                HStack {
                    Text(drive.name)
                    Spacer()
                    Text(drive.volume.freeText).monospacedDigit()
                }
                .font(.body13).kerning(-0.08)
                .padding(.horizontal, Grid.side).padding(.top, 5).padding(.bottom, 11)
                .accessibilityElement(children: .combine)
            } else { Color.clear.frame(height: 8) }
            Foot(bottom: bottom) {
                if bottom.action == .setUp {
                    Button("Set Up…") {
                        if let drive, model.workingDrive !== drive { model.use(drive: drive) }
                        ui.setup = SetupRequest(drive: drive)
                    }
                    .buttonStyle(ActionStyle())
                }
            }
        }
    }
}

/// A volume that isn't a card yet: its first line says why, with the way out under it. The bottom line stays Don't format.
private struct VolumeSheet<Actions: View>: View {
    let volume: Volume
    let first: Bool
    let line: SheetLine
    let words: String
    let bottom: BottomLine
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHead(title: volume.name, first: first)
            LineRow(line: line).padding(.horizontal, Grid.side)
            VStack(alignment: .trailing, spacing: 6) {
                Text(words).font(.small12).foregroundStyle(line.mark == .failed ? Color.ink : Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.leading, Grid.side + Grid.text).padding(.trailing, Grid.side).padding(.bottom, 9)
            Foot(bottom: bottom) { EmptyView() }
        }
    }
}

/// A denied permission isn't a card and isn't empty, so it fails on the first line, with the way out.
private struct UnreadableSheet: View {
    let volume: Volume
    let first: Bool

    var body: some View {
        VolumeSheet(volume: volume, first: first, line: SheetLine(id: .card, mark: .failed, label: "Can't read \(volume.name)"),
                    words: "\(AppInfo.name) couldn't open it. If it isn't allowed to, allow it in System Settings › Privacy & Security › Files & Folders.",
                    bottom: BottomLine(kind: .failed, title: "Don't format", sentence: "\(volume.name) can't be read.")) {
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(ActionStyle(small: true))
        }
    }
}

/// An unknown volume: the first line asks.
private struct MaybeCardSheet: View {
    @Environment(AppModel.self) private var model
    let volume: Volume
    let reason: String
    let first: Bool

    var body: some View {
        VolumeSheet(volume: volume, first: first, line: SheetLine(id: .card, mark: .waiting, label: "Is this a camera card?"), words: reason,
                    bottom: BottomLine(kind: .notDone, title: "Don't format", sentence: "\(volume.name) might be a camera card.")) {
            HStack(spacing: 6) {
                Button("It's a Drive") { model.setRole("drive", for: volume) }.buttonStyle(ActionStyle(kind: .quiet, small: true))
                Button("It's a Card") { model.setRole("card", for: volume) }.buttonStyle(ActionStyle(small: true))
            }
        }
    }
}

/// One card: what the app really did, line by line, and the bottom line.
struct SheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: CardSession
    var first = true
    @State private var waved = 0     // how far green has run down the column

    var body: some View {
        let sheet = CardSheet.make(card, model: model)
        let safe = sheet.bottom.kind == .safe
        let green = safe && waved >= sheet.lines.count
        let composer = composer(sheet)
        VStack(spacing: 0) {
            SheetHead(title: sheet.reel, detail: sheet.camera, first: first)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    Text("Files").frame(width: Grid.files, alignment: .trailing)
                    Text("GB").frame(width: Grid.gb, alignment: .trailing).padding(.leading, 8)
                }
                .font(.column).foregroundStyle(Color.ink2).padding(.bottom, 2).accessibilityHidden(true)
                ForEach(Array(sheet.lines.enumerated()), id: \.element.id) { i, line in
                    LineRow(line: line, proved: safe && i < waved)
                    if line.id == .drive { destination(sheet) }
                    LineDetail(card: card, line: line)
                    if line.id == .drive { work(sheet, composer: composer) }
                }
                if let why = card.ejectError {
                    Text(why).font(.small12).fixedSize(horizontal: false, vertical: true).padding(.leading, Grid.text).padding(.top, 2)
                }
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 9)
            Foot(bottom: sentence(sheet.bottom), green: green) { action(sheet.bottom, composer: composer, green: green) }
        }
        .quietAnimation(Layout(sheet), reduceMotion: reduceMotion, duration: 0.3)
        .onAppear { if safe { waved = sheet.lines.count } }
        .onChange(of: safe) { _, now in Task { await wave(now, count: sheet.lines.count) } }
    }

    /// Everything that changes height, so the rows below travel with it.
    private struct Layout: Equatable {
        let naming: Bool, path: Bool, copying: Bool, details: Int
        init(_ s: CardSheet) { naming = s.showsNaming; path = s.path != nil; copying = s.meter != nil; details = s.lines.reduce(0) { $0 + $1.detail.count + $1.actions.count } }
    }

    /// Down the column, into the bottom line. Under Reduce Motion the order holds, without the run.
    private func wave(_ safe: Bool, count: Int) async {
        guard safe else { waved = 0; return }
        if reduceMotion || Motion.off { waved = count; return }
        for i in 1...count {
            waved = i
            try? await Task.sleep(for: .milliseconds(70))
        }
    }

    private func sentence(_ b: BottomLine) -> BottomLine {
        guard card.ejected else { return b }
        var out = b
        out.sentence = "\(card.probe.reel ?? card.name) ejected. You can pull the card."
        out.action = nil
        return out
    }

    private func composer(_ sheet: CardSheet) -> ShootComposer? {
        guard sheet.showsNaming, let drive = model.workingDrive, let setup = drive.setup else { return nil }
        return ShootComposer(model: model, card: card, drive: drive, setup: setup)
    }

    /// One height, so nothing below moves when Show in Finder arrives.
    @ViewBuilder private func destination(_ sheet: CardSheet) -> some View {
        if let path = sheet.path {
            HStack(spacing: 4) {
                Text(path).font(.small12).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if sheet.canReveal {
                    Button { model.revealDestination(of: card) } label: { Image(systemName: "folder").font(.system(size: 11)) }
                        .buttonStyle(IconStyle(edge: .trailing)).help("Show in Finder").accessibilityLabel("Show in Finder")
                }
            }
            .frame(height: 20)
            .padding(.leading, Grid.text).padding(.top, -3).padding(.bottom, 3)
            .transition(.opacity)
        }
    }

    @ViewBuilder private func work(_ sheet: CardSheet, composer: ShootComposer?) -> some View {
        if let composer { ShootForm(composer: composer, existingShoot: sheet.existingShoot).transition(.opacity) }
        if let meter = sheet.meter {
            VStack(spacing: 5) {
                ProgressView(value: meter).progressViewStyle(MeterStyle()).accessibilityLabel("Progress")
                HStack {
                    Text(sheet.rate ?? " ")
                    Spacer()
                    Text(sheet.timeLeft ?? "")
                }
                .font(.small12).monospacedDigit().foregroundStyle(Color.ink2)
            }
            .padding(.leading, Grid.text).padding(.top, 3).padding(.bottom, 7)
            .transition(.opacity)
        }
    }

    @ViewBuilder private func action(_ b: BottomLine, composer: ShootComposer?, green: Bool) -> some View {
        switch card.ejected ? nil : b.action {
        case .copy(let n)?:
            Button(n == 1 ? "Copy 1 File" : "Copy \(n) Files") { composer?.create() }
                .buttonStyle(ActionStyle())
                .disabled(composer?.canCreate != true)
                .keyboardShortcut(.defaultAction)
        case .stop?:
            Button("Stop") { model.stop(card) }.buttonStyle(ActionStyle(kind: .quiet))
        case .eject?:
            if b.kind != .safe || green {
                Button("Eject") { Task { await model.eject(card) } }
                    .buttonStyle(ActionStyle(kind: green ? .onSafe : .quiet))
                    .accessibilityLabel("Eject \(card.name)")
                    .transition(.opacity)
            }
        default:
            EmptyView()
        }
    }
}

/// A hairline meter in grey: progress never looks like success. `ProgressView` keeps its value for VoiceOver.
struct MeterStyle: ProgressViewStyle {
    func makeBody(configuration c: Configuration) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule().fill(Color.meter).frame(width: g.size.width * (c.fractionCompleted ?? 0))
            }
        }
        .frame(height: 4)
    }
}
