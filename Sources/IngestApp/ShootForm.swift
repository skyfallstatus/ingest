import AppKit
import IngestCore
import SwiftUI

/// A text field with AppKit underneath, so Return, Esc and Tab are handled in one place.
struct InputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var focusTick = 0                       // bump to take the keyboard
    var onFocus: (Bool) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    var onTab: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let c = context.coordinator
        c.parent = self
        if field.stringValue != text {
            if let editor = field.currentEditor() {
                if text != editor.string { field.stringValue = text; editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
            } else { field.stringValue = text }
        }
        if c.tick != focusTick {
            c.tick = focusTick
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InputField
        var tick = 0
        init(_ p: InputField) { parent = p; tick = p.focusTick }

        func controlTextDidBeginEditing(_ n: Notification) { parent.onFocus(true) }
        func controlTextDidEndEditing(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
            parent.onFocus(false)
        }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onReturn()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard let tab = parent.onTab else { return false }
                tab()
                return true
            default:
                return false
            }
        }
    }
}

/// Label in the field: a key on the left, its value beside it.
struct FieldBox<Field: View, Trailing: View>: View {
    let label: String
    let focused: Bool
    var labelWidth: CGFloat = 50
    @ViewBuilder var field: Field
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 0) {
            Text(label).font(.small12).foregroundStyle(Color.ink2).frame(width: labelWidth, alignment: .leading)
            field.frame(height: 18)
            trailing
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(shape.fill(focused ? Color.surface : Color.foot))
        .overlay(shape.strokeBorder(focused ? Color.focusRing : Color.line, lineWidth: focused ? 1.25 : 0.5))
        .background(shape.stroke(focused ? Color.line : .clear, lineWidth: 5))
    }
}

/// Everything naming a shoot needs to work out. A value, so the form and the bottom line's button agree.
@MainActor struct ShootComposer {
    let model: AppModel
    let card: CardSession
    let drive: DriveState
    let setup: DriveSetup

    var draft: ShootDraft { card.draft }
    var camera: CameraIdentity? { card.primaryCamera?.identity }
    var cardDay: CalendarDay? { card.probe.captureDays.last?.day }
    var offset: Int { model.clockOffset(for: camera) }
    var needsClient: Bool { setup.path.contains(.client) }

    /// The date a person would choose, given what this camera's clock is known to do.
    var suggestedDate: Date {
        guard let cardDay else { return Date() }
        return CalendarDay.gregorian.date(byAdding: .day, value: offset, to: cardDay.date()) ?? cardDay.date()
    }

    private func request(cardFolder: String) -> ShootRequest {
        ShootRequest(client: draft.client, shootName: draft.shootName.isEmpty ? "Shoot" : draft.shootName, day: CalendarDay(draft.date),
                     cameraFolder: draft.cameraFolder.isEmpty ? "Camera" : draft.cameraFolder, cardFolder: cardFolder,
                     hasVideo: card.probe.hasVideo || !(card.probe.hasStills || card.probe.hasAudio),
                     hasStills: card.probe.hasStills, hasAudio: card.probe.hasAudio && !card.probe.hasVideo)
    }

    private var baseCardFolder: String {
        if let reel = card.probe.reel, !reel.isEmpty { return ShootPlanner.cardLabel(reel) }
        let n = CardSession.friendlyName(card.volume.name)
        return n == "Card" ? "Card 1" : ShootPlanner.cardLabel(n)
    }

    /// A card never lands on top of another card with the same name, because clip names repeat. That includes a card
    /// still waiting in line, whose folder isn't on the drive yet.
    private func uniqueCardFolder() -> String {
        let base = baseCardFolder
        let taken = model.reserved(besides: card)
        func free(_ name: String) -> Bool {
            let p = ShootPlanner.plan(setup: setup, request: request(cardFolder: name), clients: drive.clients) { drive.existing($0) }
            // Footage, stills and audio each get the same card folder, so all of them must be free.
            return [p.footagePath, p.stillsPath, p.audioPath].compactMap { $0 }.allSatisfy { drive.existing($0) == nil && !taken.contains(matchKey($0)) }
        }
        for n in 1..<100 {
            let name = n == 1 ? base : "\(base) \(n)"
            if free(name) { return name }
        }
        while true {
            let name = base + " " + UUID().uuidString.prefix(8)
            if free(name) { return name }
        }
    }

    var plan: ShootPlan {
        ShootPlanner.plan(setup: setup, request: request(cardFolder: uniqueCardFolder()), clients: drive.clients) { drive.existing($0) }
    }

    var canCreate: Bool {
        let hasClient = !draft.client.trimmingCharacters(in: .whitespaces).isEmpty
        return (hasClient || !needsClient) && !draft.shootName.trimmingCharacters(in: .whitespaces).isEmpty && !draft.cameraFolder.isEmpty
    }

    /// The rest of a client's name, once what's typed starts one and nothing is exact yet.
    var completion: (name: String, rest: String)? {
        let typed = draft.client
        guard !typed.isEmpty else { return nil }
        guard !drive.clients.contains(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) else { return nil }
        guard let hit = drive.clients.first(where: { $0.name.lowercased().hasPrefix(typed.lowercased()) }) else { return nil }
        return (hit.name, String(hit.name.dropFirst(typed.count)))
    }

    func prefill() {
        guard !draft.prefilled else { return }
        draft.prefilled = true
        draft.date = suggestedDate
        draft.cameraFolder = model.folderName(for: camera)
        // Same job still running? Offer its client. Otherwise leave it blank rather than guess.
        if let last = setup.learned?.mostRecentClient, let lastDay = drive.clients.first?.lastShoot {
            let gap = abs(CalendarDay.gregorian.dateComponents([.day], from: lastDay.date(), to: draft.date).day ?? 99)
            if gap <= 3 { draft.client = last }
        }
    }

    func create() {
        guard canCreate else { return }
        let p = plan
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.createShoot(card, plan: p, cameraFolder: draft.cameraFolder, chosenDay: CalendarDay(draft.date))
        if card.isBusy {
            let shoot = (p.shootPath as NSString).lastPathComponent
            card.shootLabel = needsClient ? (p.existingClientName ?? draft.client) + " / " + shoot : shoot
        }
    }
}

/// The folder preview as three deliberate lines, so it never rewraps while someone types.
struct FolderPreview: Equatable {
    var above: [String]         // the folders over the shoot
    var shoot: String
    var below: [String]         // the shoot down to the card
    var skipped: String?

    init(plan: ShootPlan) {
        var above = plan.shootPath.split(separator: "/").map(String.init)
        shoot = above.popLast() ?? ""
        self.above = above
        below = plan.footagePath.split(separator: "/").map(String.init).dropFirst(above.count + 1).map { $0 }
        skipped = plan.skippedNote
    }
}

/// Naming the shoot opens on the line that needs it. Return starts the copy, Esc gives the keyboard back.
struct ShootForm: View {
    @Environment(PanelUI.self) private var ui
    @Environment(AppModel.self) private var model
    let composer: ShootComposer
    let existingShoot: String?
    var newFolderNote: String? = nil

    private enum Focus { case client, shoot }
    @State private var focus: Focus?
    @State private var clientTick = 0
    @State private var shootTick = 0
    @State private var pickingDate = false
    @State private var pickingFolder = false

    private var draft: ShootDraft { composer.draft }
    private var camera: CameraIdentity? { composer.camera }
    private var card: CardSession { composer.card }

    var body: some View {
        @Bindable var d = draft
        VStack(alignment: .leading, spacing: 4) {
            if composer.needsClient {
                FieldBox(label: "Client", focused: focus == .client) {
                    ZStack(alignment: .leading) {
                        if let c = composer.completion, focus == .client {
                            HStack(spacing: 0) {
                                Text(draft.client).hidden()
                                Text(c.rest).foregroundStyle(Color.ink3)
                            }
                            .font(.body13).padding(.leading, 2).lineLimit(1).allowsHitTesting(false)
                        }
                        InputField(text: $d.client, focusTick: clientTick,
                                   onFocus: { focus = $0 ? .client : (focus == .client ? nil : focus) },
                                   onReturn: clientReturn, onEscape: escape, onTab: acceptClient)
                            .accessibilityLabel("Client")
                    }
                } trailing: {
                    if composer.completion != nil, focus == .client { TabHint() }
                    else if draft.client.isEmpty, !composer.drive.clients.isEmpty { ClientList(clients: composer.drive.clients) { draft.client = $0; shootTick += 1 } }
                }
            }
            FieldBox(label: "Shoot", focused: focus == .shoot) {
                InputField(text: $d.shootName, placeholder: "What was filmed", focusTick: shootTick,
                           onFocus: { focus = $0 ? .shoot : (focus == .shoot ? nil : focus) },
                           onReturn: composer.create, onEscape: escape, onTab: composer.needsClient ? { clientTick += 1 } : nil)
                    .accessibilityLabel("Shoot name")
            } trailing: { EmptyView() }
            nearMatch
            facts.padding(.top, 3)
            links.padding(.top, 2)
        }
        .padding(.leading, Grid.text).padding(.top, 3).padding(.bottom, 8)
        .onAppear { composer.prefill(); takeKeyboard() }
        .onChange(of: ui.isKey) { _, key in if key { takeKeyboard() } }
    }

    @ViewBuilder private var nearMatch: some View {
        if !draft.client.isEmpty, composer.completion == nil, let near = ShootPlanner.nearMatch(for: draft.client, in: composer.drive.clients) {
            Button("Did you mean \(near.name)?") { draft.client = near.name }.buttonStyle(LinkStyle()).padding(.leading, 9).padding(.top, 2)
        }
    }

    private func fact<V: View>(_ key: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(key).foregroundStyle(Color.ink2).frame(width: 50, alignment: .leading)
            value()
        }
        .font(.small12).monospacedDigit()
        .padding(.horizontal, 9).padding(.vertical, 2)
    }

    private var dateWords: String {
        guard composer.cardDay != nil else { return "today" }
        return composer.offset == 0 ? "from the card" : "from the card, corrected"
    }

    private var serial: String { [camera?.displayModel ?? "Camera", camera?.serialTail.map { "serial \($0)" }].compactMap { $0 }.joined(separator: " · ") }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            fact("Date") {
                Button(draft.date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated))) { pickingDate = true }
                    .buttonStyle(FactStyle())
                    .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
                        DatePicker("Date", selection: Binding(get: { draft.date }, set: { draft.date = $0 }), displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.graphical).padding(12)
                    }
                    .accessibilityLabel("Shoot date")
                Text(" " + dateWords).foregroundStyle(Color.ink2).lineLimit(1)
            }
            fact("Camera") {
                Text(serial).lineLimit(1)
                Spacer(minLength: 4)
                Button("folder \(draft.cameraFolder.isEmpty ? "Camera" : draft.cameraFolder)") { pickingFolder = true }
                    .buttonStyle(LinkStyle())
                    .popover(isPresented: $pickingFolder, arrowEdge: .bottom) { folderPicker }
                    .accessibilityLabel("Camera folder")
            }
            let preview = FolderPreview(plan: composer.plan)
            fact("Folder") {
                VStack(alignment: .leading, spacing: 0) {
                    if !preview.above.isEmpty {
                        Text(preview.above.joined(separator: " / ") + " /").foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.head)
                    }
                    Text(preview.shoot + " /").fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text(preview.below.joined(separator: " / ")).foregroundStyle(Color.ink2).lineLimit(1).truncationMode(.middle)
                    if let skipped = preview.skipped { Text(skipped).foregroundStyle(Color.ink2).lineLimit(1) }
                }
                .accessibilityElement(children: .combine)
            }
            notes.padding(.horizontal, 9)
        }
    }

    @ViewBuilder private var links: some View {
        if let newFolderNote {
            Text(newFolderNote).font(.small12).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9)
        }
        HStack(spacing: 14) {
            // A reused card may hold a new shoot, so the fields above stay on offer beside this.
            if let existingShoot {
                Button("Add to \(CardSheet.homeLabel(existingShoot, setup: composer.setup).components(separatedBy: " / ").last ?? existingShoot)") {
                    model.add(card, to: existingShoot)
                }
                .lineLimit(1).help(existingShoot)
            }
            Button("Choose Folder…") { Windows.shared.chooseFolder(card: card, model: model) }
        }
        .buttonStyle(LinkStyle())
        .padding(.leading, 9)
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(camera.map { "\($0.displayModel) goes in this folder" } ?? "This camera goes in this folder").font(.small12.weight(.medium))
            InputField(text: Binding(get: { draft.cameraFolder }, set: { draft.cameraFolder = $0 }), placeholder: "Camera folder",
                       onReturn: { pickingFolder = false }, onEscape: { pickingFolder = false })
                .frame(height: 22).padding(.horizontal, 8)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.line))
            HStack(spacing: 10) {
                ForEach(cameraChoices, id: \.self) { n in Button(n) { draft.cameraFolder = n; pickingFolder = false }.buttonStyle(LinkStyle()) }
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private var cameraChoices: [String] {
        var out: [String] = []
        if let c = camera { out.append(c.displayModel) }
        for m in model.cameraMemory.values where !out.contains(m.folder) { out.append(m.folder) }
        for n in ["A Cam", "B Cam"] where !out.contains(n) { out.append(n) }
        return Array(out.prefix(4))
    }

    @ViewBuilder private var notes: some View {
        let gap = abs(Calendar.current.dateComponents([.day], from: draft.date, to: Date()).day ?? 0)
        let offset = composer.offset
        if offset != 0, let cam = camera {
            Text("This \(cam.displayModel)'s clock runs \(abs(offset)) days \(offset > 0 ? "behind" : "ahead"), so the date is corrected.")
                .font(.small12).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        } else if composer.cardDay != nil && gap > 30 {
            VStack(alignment: .leading, spacing: 2) {
                Text("That's \(gap) days ago. Is the camera's clock right?").font(.small12).fixedSize(horizontal: false, vertical: true)
                Button("Use Today") { draft.date = Date() }.buttonStyle(LinkStyle())
            }
            .padding(.top, 4).padding(.bottom, 2)
        }
        let others = card.probe.captureDays.dropLast().suffix(3)
        if !others.isEmpty {
            Text("This card also has clips from " + others.map { $0.day.date().formatted(date: .abbreviated, time: .omitted) }.joined(separator: ", ") + ".")
                .font(.small12).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        }
    }

    private func takeKeyboard() {
        guard ui.isKey, focus == nil else { return }
        if composer.needsClient && draft.client.isEmpty { clientTick += 1 } else { shootTick += 1 }
    }

    private func acceptClient() {
        if let c = composer.completion { draft.client = c.name }
        shootTick += 1
    }

    private func clientReturn() {
        if let c = composer.completion { draft.client = c.name }
        if draft.shootName.trimmingCharacters(in: .whitespaces).isEmpty { shootTick += 1 } else { composer.create() }
    }

    /// Leaves what's typed in place and steps out of the field. Esc again closes the widget.
    private func escape() {
        focus = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct TabHint: View {
    var body: some View {
        Text("tab").font(.system(size: 10)).foregroundStyle(Color.ink2).padding(.horizontal, 5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.ring, lineWidth: 0.75))
            .accessibilityHidden(true)
    }
}

/// Every client on the drive, for when typing isn't the way in.
struct ClientList: View {
    let clients: [ClientFolder]
    let pick: (String) -> Void
    var body: some View {
        PullDown(symbol: "chevron.down", color: .tertiaryLabelColor, size: 8, spoken: "Choose a client",
                 entries: { clients.prefix(40).map { c in .item(c.name) { pick(c.name) } } })
            .frame(width: 16, height: 16)
    }
}

/// A fact you can change: the same text, with a faint rule.
private struct FactStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.underline(color: Color.ink2.opacity(0.35)).opacity(c.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}
