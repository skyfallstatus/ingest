import AppKit
import IngestCore
import SwiftUI

/// Setup, in the widget like everything else: lines, then the bottom line. Whatever is plugged in, it has something to say.
struct SetupHost: View {
    @Environment(AppModel.self) private var model
    @State private var drive: DriveState?
    @State private var learned: DriveSetup??
    let close: () -> Void

    init(start: DriveState?, close: @escaping () -> Void) {
        _drive = State(initialValue: start)
        self.close = close
    }

    var body: some View {
        Group {
            if let drive {
                if let learned { SetupView(drive: drive, learned: learned, saved: drive.setup, close: close) }
                else { ReadingDrive(drive: drive, close: close) }
            } else { WaitingForDrive(close: close) { pick($0) } }
        }
        .task(id: drive?.id) { read() }
        .onChange(of: model.drives.map(\.id)) { _, _ in
            if let d = drive, !model.drives.contains(where: { $0 === d }) { drive = nil; learned = nil }
            else if drive == nil, model.drives.count == 1 { drive = model.drives[0] }
        }
        .onAppear { if drive == nil, model.drives.count == 1 { drive = model.drives[0] } }
    }

    /// A drive that only turned up is read but not used: it could be camera media, so it takes Use This to make it the working drive.
    private func pick(_ d: DriveState) {
        if model.workingDrive !== d, !model.isCopying { model.use(drive: d) }
        drive = d
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

/// Nothing to read yet, or a choice of drives.
struct WaitingForDrive: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    let pick: (DriveState) -> Void

    var body: some View {
        let waiting = model.drives.isEmpty
        VStack(spacing: 0) {
            SheetHead(title: "Your working drive", close: close)
            VStack(alignment: .leading, spacing: 0) {
                if waiting {
                    SetupLine(label: "Waiting for a drive", value: "", mark: .running)
                    ForEach(model.ignored) { v in
                        HStack(spacing: 8) {
                            Text(v.name).font(.body13).kerning(-0.08).lineLimit(1)
                            Spacer(minLength: 0)
                            if !v.isReadOnly { Button("It's a Drive") { model.setRole("drive", for: v) }.buttonStyle(ActionStyle(kind: .quiet, small: true)) }
                        }
                        .frame(height: 30)
                    }
                } else {
                    ForEach(model.drives) { d in
                        HStack(spacing: 8) {
                            Text(model.label(of: d)).font(.body13).kerning(-0.08).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(d.volume.freeText).font(.small12).monospacedDigit().foregroundStyle(Color.ink2).lineLimit(1)
                            Button("Use This") { pick(d) }.buttonStyle(ActionStyle(kind: .quiet, small: true))
                        }
                        .frame(height: 30)
                    }
                }
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 9)
            Foot(bottom: CardSheet.waitingForDrive(model: model)) { EmptyView() }
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
                SetupLine(label: "Built the same way", value: "", mark: .waiting)
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

    @State private var setup: DriveSetup
    @State private var editing = false
    @State private var saveError: String?

    init(drive: DriveState, learned: DriveSetup?, saved: DriveSetup? = nil, close: @escaping () -> Void) {
        self.drive = drive; self.learned = learned; self.close = close
        _setup = State(initialValue: saved ?? learned ?? ShootPlanner.presets().first?.setup ?? DriveSetup(path: [.client], shootName: ShootNameStyle(), inner: [InnerFolder(name: "Footage", role: .footage)], footage: .perCamera))
    }

    private var stats: LearnedStats? { setup.learned ?? learned?.learned }

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
        if case .perCamera = setup.footage { add("Camera", bold: true) }
        var card = Text("Card").fontWeight(.semibold).foregroundColor(.ink)
        if case .perCard(let prefix) = setup.footage { card = Text(prefix).foregroundColor(.ink2) + card }
        return out + card
    }

    /// A real shoot of this client's, from the most recent day, when the drive has one.
    private var example: String {
        let client = setup.learned?.mostRecentClient ?? drive.clients.first?.name ?? "Client name"
        let day = setup.learned?.mostRecentDay ?? CalendarDay(Date())
        let date = ShootPlanner.shootFolderName(setup: setup, shootName: "", day: day)
        var shoot = ShootPlanner.shootFolderName(setup: setup, shootName: "Shoot name", day: day)
        if let root = drive.clients.first(where: { $0.name == client })?.path, let index = drive.index,
           let hit = index.entries.first(where: { $0.isDir && ($0.path as NSString).deletingLastPathComponent == root && ($0.path as NSString).lastPathComponent.contains(date) }) {
            shoot = (hit.path as NSString).lastPathComponent
        }
        var parts: [String] = setup.path.map { level in
            switch level {
            case .year: String(day.year)
            case .literal(let s): s
            case .client: client
            }
        }
        parts.append(shoot)
        parts.append(setup.inner.first { $0.role == .footage }?.name ?? "Footage")
        if case .perCamera = setup.footage { parts.append(model.cameraMemory.values.map(\.folder).sorted().first ?? "Camera") }
        return parts.joined(separator: " / ")
    }

    private var inside: String {
        "Inside each shoot: " + setup.inner.map { f in
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
                if let s = stats { SetupLine(label: "Built the same way", value: String(s.shootsFollowing)) }
                VStack(alignment: .leading, spacing: 3) {
                    pattern.lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Group {
                        Text(example).lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                        Text(inside).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.small12).foregroundStyle(Color.ink2)
                }
                .font(.body13)
                .padding(.leading, Grid.text).padding(.top, 5)
                Text("Change Layout…").font(.small12).foregroundStyle(Color.ink2).underline(color: Color.ink2.opacity(0.35))
                    .overlay { PullDown(spoken: "Change the folder layout: a preset, or edit it", entries: { choices }) }
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
        if let learned { out.append(.item("What I learned from \(drive.name)") { setup = learned }) }
        out += [.separator, .item("Edit…") { editing = true }]
        return out
    }

    private var footLine: BottomLine {
        if let saveError { return BottomLine(kind: .idle, title: "That didn't save", sentence: saveError) }
        if stats == nil || stats?.shootsFound == 0 {
            return BottomLine(kind: .idle, title: "How should it be organised?", sentence: "No shoots on it yet. This is a starting point.")
        }
        return BottomLine(kind: .idle, title: "This is how you work", sentence: setup.learned?.exception ?? "The next shoot goes the same way.")
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
            Foot(bottom: BottomLine(kind: .idle, title: "Not saved yet", sentence: "Use This, on the page before, saves it.")) {
                HStack(spacing: 6) {
                    Button("Cancel", role: .cancel, action: close).buttonStyle(ActionStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                    Button("Done", action: done).buttonStyle(ActionStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .tint(Color.ink2)
        .onAppear { load(); ui.editingLayout = true }
        .onDisappear { ui.editingLayout = false }
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
