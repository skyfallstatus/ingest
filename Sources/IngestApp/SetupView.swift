import AppKit
import IngestCore
import SwiftUI

/// Setup, in the widget like everything else: where copies go, then the layout, then the bottom line. Nothing is saved until
/// Use This, and ✕ anywhere leaves everything as it was.
struct SetupHost: View {
    @Environment(AppModel.self) private var model
    @State private var drive: DriveState?           // being read and set up, once Continue is pressed
    @State private var choice: DriveState?          // ticked on the first page
    @State private var folder: DriveState?          // the folder on this Mac picked there, ticked or not
    @State private var touched = false              // someone chose: nothing is preselected over them
    @State private var learned: DriveSetup??
    let close: () -> Void

    /// With `choosing`, the first page opens with `start` ticked. Without, setup goes straight to `start`'s layout.
    init(start: DriveState?, choosing: Bool = false, close: @escaping () -> Void) {
        _drive = State(initialValue: choosing ? nil : start)
        _choice = State(initialValue: start)
        _folder = State(initialValue: start?.volume.isFolder == true ? start : nil)
        _touched = State(initialValue: start != nil)
        self.close = close
    }

    var body: some View {
        Group {
            if let drive {
                if let learned { SetupView(drive: drive, learned: learned, saved: drive.setup, close: close) { chooseAgain(drive) } }
                else { ReadingDrive(drive: drive, close: close) }
            } else {
                WhereCopiesGo(choice: $choice, folder: $folder, touched: $touched, close: close) { drive = $0 }
            }
        }
        .task(id: drive.map(ObjectIdentifier.init)) { read() }
        // By object, not path: another drive can come back at the same mount path in one look.
        .onChange(of: model.drives.map(ObjectIdentifier.init)) { _, _ in
            if let d = drive, !model.drives.contains(where: { $0 === d }) { drive = nil; learned = nil }
            if let c = choice, !model.drives.contains(where: { $0 === c }) { choice = nil; touched = false }     // what was chosen went: what's there is ticked again
            if let f = folder, !model.drives.contains(where: { $0 === f }) { folder = nil }
        }
        .onDisappear { model.dropPendingFolder() }
    }

    /// Back to the first page, with this one ticked.
    private func chooseAgain(_ d: DriveState) {
        choice = d
        if d.volume.isFolder { folder = d }
        touched = true
        learned = nil
        drive = nil
    }

    /// Reading a large drive takes a while, and the index usually has it already. A drive that's set up opens from what's
    /// known, even mid-scan. A new one waits for a scan that's running, or starts one if there's nothing to go on.
    private func read() {
        guard let drive else { return }
        if drive.index != nil, !drive.isScanning || drive.setup != nil { learn(from: drive) }
        else { model.refreshIndex(drive) { learn(from: drive) } }
    }

    private func learn(from drive: DriveState) {
        let entries = drive.index?.entries ?? []
        Task {
            let found = await Task.detached(priority: .userInitiated) { LayoutLearner.learn(entries: entries) }.value
            guard self.drive === drive else { return }      // pulled while it was being read
            if drive.setup == nil, let found, let index = drive.index { drive.clients = LayoutLearner.clients(in: found, entries: index.entries) }
            learned = .some(found)
        }
    }
}

private struct SetupLine: View {
    let label: String
    let value: String
    var mark: LineMark = .done
    var body: some View {
        HStack(spacing: 0) {
            MarkView(mark: mark).padding(.trailing, Grid.markGap)
            Text(label).foregroundStyle(mark == .waiting ? Color.ink2 : Color.ink)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.body13).kerning(-0.08)
        .frame(height: Grid.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// One choice in a list, the whole row its target. The tick sits in the mark column, so the label lines up with the next page's lines.
struct ChoiceRow: View {
    let label: String
    let value: String
    let selected: Bool
    var checking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ZStack {
                    if checking { Spinner() }
                    else if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink) }
                }
                .frame(width: Grid.mark, height: Grid.mark)
                .padding(.trailing, Grid.markGap)
                Text(label).font(.body13).kerning(-0.08).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value).font(.small12).monospacedDigit().foregroundStyle(Color.ink2).lineLimit(1)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChoiceStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private struct ChoiceStyle: ButtonStyle {
        func makeBody(configuration c: Configuration) -> some View { c.label.opacity(c.isPressed ? 0.6 : 1) }
    }
}

/// The first page: where copies go. A drive that's plugged in, or a folder on this Mac.
struct WhereCopiesGo: View {
    @Environment(AppModel.self) private var model
    @Binding var choice: DriveState?
    @Binding var folder: DriveState?
    @Binding var touched: Bool
    let close: () -> Void
    let next: (DriveState) -> Void
    @State private var refusal: String?
    @State private var checking = false

    private var plugged: [DriveState] { model.drives.filter { !$0.volume.isFolder } }
    private var copying: CardSession? { model.cards.first { $0.isBusy } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHead(title: "Where copies go", close: close)
            VStack(alignment: .leading, spacing: 0) {
                if plugged.isEmpty {
                    SetupLine(label: "Waiting for a drive", value: "", mark: .running).frame(height: 30)
                    ForEach(model.ignored) { v in
                        HStack(spacing: 8) {
                            Text(v.name).font(.body13).kerning(-0.08).lineLimit(1)
                            Spacer(minLength: 0)
                            if !v.isReadOnly { Button("It's a Drive") { model.setRole("drive", for: v) }.buttonStyle(ActionStyle(kind: .quiet, small: true)) }
                        }
                        .padding(.leading, Grid.text)
                        .frame(height: 30)
                        Text(Self.note(for: v, model: model)).font(.small12).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Grid.text).padding(.top, -4).padding(.bottom, 7)
                    }
                }
                ForEach(plugged) { d in
                    ChoiceRow(label: model.label(of: d), value: d.volume.freeText, selected: choice === d) { choose(d) }
                }
                ChoiceRow(label: folder.map { "\($0.name) on this Mac" } ?? "A folder on this Mac…",
                          value: folder?.volume.freeText ?? ByteFormat.string(model.macFree) + " free",
                          selected: choice != nil && choice === folder, checking: checking) { pickFolder() }
                if let refusal {
                    Text(refusal).font(.small12).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Grid.text).padding(.top, 1).padding(.bottom, 7)
                }
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 9)
            Foot(bottom: Self.bottom(model: model, choice: choice)) {
                Button("Continue") { if let choice { next(choice) } }
                    .buttonStyle(ActionStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || copying != nil || checking)
            }
        }
        .onAppear(perform: preselect)
        .onChange(of: model.drives.map(ObjectIdentifier.init)) { _, _ in preselect() }
    }

    /// The bottom line: what Continue would do, or why it can't yet.
    static func bottom(model: AppModel, choice: DriveState?) -> BottomLine {
        func line(_ title: String, _ sentence: String) -> BottomLine { BottomLine(kind: .idle, title: title, sentence: sentence) }
        if let c = model.cards.first(where: { $0.isBusy }) { return line("\(c.name) is copying", "Change this once it's done.") }
        if let c = choice {
            if c.volume.isFolder { return line("Copies go to \(c.name)", "On this Mac, in \(c.volume.parentName).") }
            return line("Copies go to \(model.label(of: c))", "Next, its folders are read. Nothing on it changes.")
        }
        if !model.drives.contains(where: { !$0.volume.isFolder }) { return line("Plug in your working drive", "Or choose a folder on this Mac.") }
        return line("Choose where copies go", "A drive, or a folder on this Mac.")
    }

    /// Why a volume that's plugged in isn't offered, under its name. With a drive that can't be used, waiting alone is the wrong thing to say.
    static func note(for v: Volume, model: AppModel) -> String { "It can't be one yet: \(model.whyIgnored(v))" }

    /// One drive plugged in is ticked. With several, the one already set up, if only one is. This Mac never is: that's a choice.
    private func preselect() {
        guard !touched else { return }
        let set = plugged.filter { $0.setup != nil }
        choice = plugged.count == 1 ? plugged[0] : set.count == 1 ? set[0] : nil
    }

    private func choose(_ d: DriveState) {
        choice = d
        touched = true
        refusal = nil
    }

    private func pickFolder() {
        guard !checking, let path = Windows.shared.chooseDestinationFolder() else { return }
        refusal = nil
        checking = true
        Task {
            let found = await model.pick(folder: path)
            checking = false
            if let d = found.drive { folder = d; choose(d) } else { refusal = found.problem }
        }
    }
}

/// While the drive is read: the same lines, counting.
struct ReadingDrive: View {
    let drive: DriveState
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            SheetHead(title: drive.name, detail: drive.volume.freeText, close: close)
            VStack(alignment: .leading, spacing: 0) {
                SetupLine(label: "Folders read", value: String(drive.foldersRead), mark: .running)
                SetupLine(label: "Shoots found", value: "", mark: .waiting)
                SetupLine(label: "Match this layout", value: "", mark: .waiting)
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 9)
            Foot(bottom: BottomLine(kind: .idle, title: "Reading \(drive.name)", sentence: "Nothing on it changes.")) { EmptyView() }
        }
    }
}

/// What the drive taught us, or a place to start on an empty one.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    let drive: DriveState
    let learned: DriveSetup?
    let close: () -> Void
    var changeDrive: (() -> Void)? = nil

    @State private var setup: DriveSetup
    @State private var editing = false
    @State private var saveError: String?

    init(drive: DriveState, learned: DriveSetup?, saved: DriveSetup? = nil, close: @escaping () -> Void, changeDrive: (() -> Void)? = nil) {
        self.drive = drive; self.learned = learned; self.close = close; self.changeDrive = changeDrive
        _setup = State(initialValue: saved ?? learned ?? ShootPlanner.presets().first?.setup ?? DriveSetup(path: [.client], shootName: ShootNameStyle(), inner: [InnerFolder(name: "Footage", role: .footage)], footage: .perCamera))
    }

    /// What's on the drive now. A saved setup's figures are from the day it was saved.
    private var stats: LearnedStats? { learned?.learned }

    /// "Clients / Client / Date Shoot / Footage / Camera / Card", with what changes in the heavier weight.
    private var pattern: Text {
        var out = Text("")
        func add(_ s: String, bold: Bool) {
            out = out + Text(s).fontWeight(bold ? .semibold : .regular).foregroundColor(bold ? .ink : .ink2) + Text(" / ").foregroundColor(.ink2)
        }
        for level in setup.path {
            switch level {
            case .year: add("Year", bold: true)
            case .literal(let s): add(s, bold: false)
            case .client: add("Client", bold: true)
            }
        }
        add(setup.shootName.position == .prefix ? "Date Shoot" : "Shoot Date", bold: true)
        add(setup.inner.first { $0.role == .footage }?.name ?? "Footage", bold: false)
        switch setup.footage {
        case .perCamera:
            add("Camera", bold: true)
            return out + Text("Card").fontWeight(.semibold).foregroundColor(.ink)
        case .perCard(let prefix):
            return out + Text(prefix).foregroundColor(.ink2) + Text("01").fontWeight(.semibold).foregroundColor(.ink)
        }
    }

    /// What else is in each shoot. The footage folder is in the line above.
    static func also(_ setup: DriveSetup) -> String? {
        var rest = setup.inner
        if let footage = rest.firstIndex(where: { $0.role == .footage }) { rest.remove(at: footage) }
        guard !rest.isEmpty else { return nil }
        return "Also: " + rest.map { f in
            f.children.isEmpty ? f.name : f.name + " (" + f.children.map(\.name).joined(separator: ", ") + ")"
        }.joined(separator: ", ")
    }

    var body: some View {
        if editing { SetupEditor(setup: $setup) { editing = false } } else { summary }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            SheetHead(title: drive.name, detail: drive.volume.freeText, close: close)
            VStack(alignment: .leading, spacing: 0) {
                SetupLine(label: "Folders read", value: String(stats?.foldersRead ?? drive.foldersRead))
                SetupLine(label: "Shoots found", value: String(stats?.shootsFound ?? 0))
                if let s = stats, let learned, setup.sameLayout(as: learned) { SetupLine(label: "Match this layout", value: String(s.shootsFollowing)) }
                VStack(alignment: .leading, spacing: 3) {
                    pattern.lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    if let also = Self.also(setup) {
                        Text(also).foregroundStyle(Color.ink2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.small12)
                .padding(.leading, Grid.text).padding(.top, 5)
                HStack(spacing: 12) {
                    Text("Change Layout…").font(.small12).foregroundStyle(Color.ink2).underline(color: Color.ink2.opacity(0.35))
                        .overlay { PullDown(spoken: "Change the folder layout: a preset, or edit it", entries: { choices }) }
                    if let changeDrive {
                        Button(drive.volume.isFolder ? "Change Folder…" : "Change Drive…", action: changeDrive).buttonStyle(LinkStyle())
                    }
                }
                .padding(.leading, Grid.text).padding(.top, 6)
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 10)
            Foot(bottom: footLine) {
                Button("Use This") {
                    if let why = model.accept(setup: setup, for: drive) { saveError = why } else { close() }
                }
                .buttonStyle(ActionStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var choices: [PullDown.Entry] {
        var out: [PullDown.Entry] = [.header("Presets")]
        out += ShootPlanner.presets().map { p in .item(p.name) { setup = p.setup } }
        if let learned { out.append(.item("Layout found on \(drive.name)") { setup = learned }) }
        out += [.separator, .item("Edit…") { editing = true }]
        return out
    }

    private var footLine: BottomLine {
        if let saveError { return BottomLine(kind: .idle, title: "Couldn't save the layout", sentence: saveError) }
        return Self.foot(showing: setup, learned: learned, saved: drive.setup, drive: drive.name)
    }

    /// What the layout on screen is, next to what's on the drive. The exception comes from this read of the drive: a saved
    /// setup holds the words of the day it was saved.
    static func foot(showing setup: DriveSetup, learned: DriveSetup?, saved: DriveSetup?, drive: String) -> BottomLine {
        func line(_ title: String, _ sentence: String) -> BottomLine { BottomLine(kind: .idle, title: title, sentence: sentence) }
        if let learned, setup.sameLayout(as: learned) { return line("Layout found", learned.learned?.exception ?? "New shoots follow it.") }
        if let saved, setup.sameLayout(as: saved) { return line("Current layout", "New shoots follow it.") }
        if learned == nil, saved == nil { return line("Choose a layout", "No shoots found on \(drive).") }
        return line("A different layout", "Only new shoots use it. Nothing on \(drive) moves.")
    }
}

/// Everything about the layout, as a page of the widget. Nothing counts until Done.
struct SetupEditor: View {
    @Environment(PanelUI.self) private var ui
    @Binding var target: DriveSetup
    let close: () -> Void
    @State private var setup: DriveSetup
    @State private var pathText = ""
    @State private var innerText = ""
    @State private var perCard = false
    @State private var prefix = "CARD "
    @State private var opened: DriveSetup?
    @State private var typedBefore = false

    init(setup: Binding<DriveSetup>, close: @escaping () -> Void) {
        _target = setup
        self.close = close
        _setup = State(initialValue: setup.wrappedValue)
    }

    private let formats = ["dd.MM.yy", "dd-MM-yy", "dd.MM.yyyy", "yyyy-MM-dd", "yyMMdd", "yyyyMMdd", "yyyy-MM", "MM.dd.yy"]

    private func note(_ words: String) -> some View {
        Text(words).font(.small12).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true).padding(.leading, 9)
    }

    private func heading(_ words: String) -> some View {
        Text(words).font(.column).foregroundStyle(Color.ink2).padding(.top, 10).padding(.bottom, 3).accessibilityAddTraits(.isHeader)
    }

    /// A choice in the key column's grammar: what it is, then what it's set to.
    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.body13).kerning(-0.08)
            Spacer(minLength: 0)
            control()
        }
        .frame(height: Grid.rowHeight)
    }

    private func menu<Value: Hashable>(_ label: String, _ selection: Binding<Value>, @ViewBuilder _ options: () -> some View) -> some View {
        Picker(label, selection: selection, content: options).labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHead(title: "Edit the layout", first: false)
            VStack(alignment: .leading, spacing: 0) {
                heading("Path to each shoot").padding(.top, -6)
                FieldBox(label: "", focused: false, labelWidth: 0) {
                    InputField(text: $pathText, placeholder: "{Year}/Paid work/{Client}", onReturn: done, onEscape: close).accessibilityLabel("Folders")
                } trailing: { EmptyView() }
                note("Use {Year} and {Client} for what changes.").padding(.top, 4)

                heading("Shoot folder name")
                row("Date") {
                    menu("Date", $setup.shootName.dateFormat) { ForEach(formats, id: \.self) { Text($0.uppercased()).tag($0) } }
                }
                row("Date goes") {
                    menu("Date goes", $setup.shootName.position) {
                        Text("Before the name").tag(ShootNameStyle.Position.prefix)
                        Text("After the name").tag(ShootNameStyle.Position.suffix)
                    }
                }
                row("Capitals") {
                    Toggle("Write shoot names in capitals", isOn: $setup.shootName.uppercase).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }

                heading("Inside each shoot")
                TextEditor(text: $innerText).font(.system(size: 12).monospaced())
                    .frame(height: 92).textBox()
                    .accessibilityLabel("Inside each shoot")
                note("One folder per line. Two spaces puts it inside the one above.").padding(.top, 4)

                heading("Inside the footage folder")
                row("Organise by") {
                    menu("Organise by", $perCard) {
                        Text("Camera, then card").tag(false)
                        Text("Card").tag(true)
                    }
                }
                if perCard {
                    FieldBox(label: "Prefix", focused: false) {
                        InputField(text: $prefix, placeholder: "CARD ", onReturn: done, onEscape: close).accessibilityLabel("Card folder prefix")
                    } trailing: { EmptyView() }
                }
                note("A card is always copied whole, in its own folder.").padding(.top, 4)
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 10)
            Foot(bottom: BottomLine(kind: .idle, title: "Not saved yet", sentence: "Done keeps it here. Use This saves it.")) {
                HStack(spacing: 6) {
                    Button("Cancel", role: .cancel, action: close).buttonStyle(ActionStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                    Button("Done", action: done).buttonStyle(ActionStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .tint(Color.ink2)
        .onAppear {
            load()
            opened = target
            typedBefore = ui.setup?.typing == true
            ui.setup?.typing = true
        }
        .onDisappear { ui.setup?.typing = typedBefore || target != opened }     // Done kept it, and Use This hasn't saved it yet
    }

    private func done() { apply(); close() }

    private func load() {
        pathText = setup.path.map { l in
            switch l {
            case .year: "{Year}"
            case .client: "{Client}"
            case .literal(let s): s
            }
        }.joined(separator: "/")
        func lines(_ f: [InnerFolder], _ depth: Int) -> [String] {
            f.flatMap { [String(repeating: "  ", count: depth) + $0.name] + lines($0.children, depth + 1) }
        }
        innerText = lines(setup.inner, 0).joined(separator: "\n")
        if case .perCard(let p) = setup.footage { perCard = true; prefix = p }
    }

    private func apply() {
        let levels: [PathLevel] = pathText.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map {
            switch $0.lowercased() {
            case "{year}": .year
            case "{client}": .client
            default: .literal($0)
            }
        }
        if !levels.isEmpty { setup.path = levels }
        setup.footage = perCard ? .perCard(prefix: prefix) : .perCamera
        var roles: [String: FolderRole] = [:]
        func collect(_ f: [InnerFolder]) { for x in f { roles[x.name] = x.role; collect(x.children) } }
        collect(setup.inner)
        var top: [InnerFolder] = []
        for raw in innerText.split(separator: "\n") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let f = InnerFolder(name: name, role: roles[name] ?? .plain)
            if raw.hasPrefix("  "), !top.isEmpty { top[top.count - 1].children.append(f) } else { top.append(f) }
        }
        if !top.isEmpty {
            if !top.contains(where: { $0.role == .footage }), let i = top.firstIndex(where: { $0.role == .plain }) { top[i].role = .footage }
            setup.inner = top
        }
        target = setup
    }
}
