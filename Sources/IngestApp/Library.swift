import IngestCore
import SwiftUI

/// History, Cameras, Drives and Settings: everything that isn't the card in front of you, in the widget's own width.
struct LibraryView: View {
    enum Page: String, CaseIterable, Identifiable {
        case history = "History", cameras = "Cameras", drives = "Drives", settings = "Settings"
        var id: String { rawValue }
    }

    @Environment(PanelUI.self) private var ui
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button { ui.page = nil } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(IconStyle()).accessibilityLabel("Back to the card")
                ForEach(Page.allCases) { p in
                    Button(p.rawValue) { ui.page = p }.buttonStyle(TabStyle(selected: page == p))
                        .accessibilityAddTraits(page == p ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
            Rectangle().fill(Color.line).frame(height: 0.5)
            Group {
                switch page {
                case .history: HistoryPage()
                case .cameras: CamerasPage()
                case .drives: DrivesPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 6)
        }
    }
}

private struct TabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.ink : Color.ink2)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.foot : .clear))
            .contentShape(Rectangle())
            .opacity(c.isPressed ? 0.6 : 1)
    }
}

/// A row with no mark: words left, what you can do about them right.
private struct PlainRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body13).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.small12).monospacedDigit().foregroundStyle(Color.ink2).lineLimit(2).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing
        }
        .frame(minHeight: 30)
        .padding(.vertical, 4)
        .padding(.horizontal, Grid.side)
    }
}

extension PlainRow where Trailing == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

private struct HistoryPage: View {
    @Environment(AppModel.self) private var model

    private func detail(_ e: HistoryEntry) -> String {
        let parts = e.path.split(separator: "/").map(String.init).suffix(5)
        let shoot = parts.first { $0.first?.isNumber == true && $0.contains(" ") } ?? parts.last ?? ""
        return [shoot, e.outcome].joined(separator: " · ")
    }

    var body: some View {
        if model.history.isEmpty {
            PlainRow(title: "No cards yet", subtitle: "Cards you copy appear here.")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.history.prefix(60)) { e in
                    PlainRow(title: "\(e.cardName) · \(e.date.formatted(date: .abbreviated, time: .omitted))", subtitle: detail(e)) {
                        Button { model.reveal(path: e.path) } label: { Image(systemName: "folder").font(.system(size: 12)) }
                            .buttonStyle(IconStyle(edge: .trailing)).help("Show in Finder").accessibilityLabel("Show \(e.cardName) in Finder")
                    }
                }
            }
        }
    }
}

private struct CamerasPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.cameraMemory.isEmpty {
            PlainRow(title: "No cameras yet", subtitle: "Each camera body is remembered the first time its card is read.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.cameraMemory.keys.sorted(), id: \.self) { key in
                    if let m = model.cameraMemory[key] {
                        PlainRow(title: m.displayName ?? m.folder, subtitle: [m.serialTail.map { "Serial \($0)" }, m.clockOffsetDays.map { "Clock off by \(abs($0)) days" }].compactMap { $0 }.joined(separator: " · ")) {
                            TextField("Folder", text: Binding(
                                get: { model.cameraMemory[key]?.folder ?? "" },
                                set: { model.cameraMemory[key]?.folder = $0; model.stores.cameras = model.cameraMemory }
                            ))
                            .textFieldStyle(.plain).font(.small12).frame(width: 84)
                            .padding(.horizontal, 7).frame(height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.line))
                            .accessibilityLabel("Folder for \(m.displayName ?? m.folder)")
                            Button { model.forgetCamera(key) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                                .buttonStyle(IconStyle(edge: .trailing)).help("Forget this camera").accessibilityLabel("Forget \(m.displayName ?? m.folder)")
                        }
                    }
                }
            }
        }
    }
}

private struct DrivesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUI.self) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.drives.isEmpty {
                PlainRow(title: "No drive plugged in", subtitle: "Plug in your working drive.")
            }
            ForEach(model.drives) { d in
                PlainRow(title: model.label(of: d), subtitle: "\(d.volume.freeText) · \(d.volume.fsType)\(model.workingDrive === d ? " · Working drive" : "")") {
                    if model.workingDrive !== d {
                        Button("Use") {
                            model.use(drive: d)
                            if d.setup == nil { ui.setup = SetupRequest(drive: d) }
                        }
                        .buttonStyle(ActionStyle(kind: .quiet, small: true)).disabled(model.isCopying)
                    }
                    if model.hasChosenRole(for: d.volume) {
                        Button("Not a Drive") { model.forgetChoice(for: d.volume) }
                            .buttonStyle(ActionStyle(kind: .quiet, small: true)).disabled(model.isCopying)
                    }
                    Button(d.setup == nil ? "Set Up…" : "Folder Setup…") { ui.setup = SetupRequest(drive: d) }
                        .buttonStyle(ActionStyle(kind: .quiet, small: true))
                }
            }
            ForEach(model.ignored) { v in
                PlainRow(title: v.name, subtitle: "Not a working drive: \(model.whyIgnored(v))") {
                    if !v.isReadOnly {
                        Button("It's a Drive") { model.setRole("drive", for: v) }.buttonStyle(ActionStyle(kind: .quiet, small: true))
                    }
                }
            }
            // Here whenever there's an answer to take back, even with nothing plugged in: it's how a wrong "It's a Card" gets undone.
            if model.hasVolumeChoices {
                Button("Forget Card and Drive Choices") { model.forgetVolumeChoices() }
                    .buttonStyle(LinkStyle())
                    .padding(.horizontal, Grid.side).padding(.vertical, 4)
            }
        }
    }
}

private struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 0) {
            PlainRow(title: "Open when a card goes in", subtitle: "Without taking the keyboard.") {
                Toggle("Open when a card goes in", isOn: $m.opensOnCardIn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            LoginRow(login: m.loginItem)
            PlainRow(title: "Check for updates by itself", subtitle: "At most once a day. It only asks GitHub for the latest version.") {
                Toggle("Check for updates by itself", isOn: $m.checksForUpdates).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            PlainRow(title: "Verification", subtitle: "XXH64, card and drive read in full")
            VersionRow(updates: m.updates)
            Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
                .buttonStyle(LinkStyle())
                .padding(.horizontal, Grid.side).padding(.vertical, 6)
        }
        .tint(Color.cobalt)
        .onAppear { m.loginItem.refresh() }
    }
}

/// The switch shows what macOS says, not what was last clicked, and anything macOS wants is said right under it.
private struct LoginRow: View {
    let login: LoginItem

    var body: some View {
        PlainRow(title: "Open at login", subtitle: "") {
            Toggle("Open at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        if let words = login.needsApproval ? "macOS is waiting for your OK in Login Items." : login.problem {
            HStack(spacing: 8) {
                Text(words).font(.small12).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open Login Items") { LoginItem.openSystemSettings() }.buttonStyle(ActionStyle(kind: .quiet, small: true))
            }
            .padding(.horizontal, Grid.side).padding(.bottom, 4)
        }
    }
}

/// The version, and the quiet line about whether there's a newer one.
private struct VersionRow: View {
    let updates: UpdateChecker

    var body: some View {
        PlainRow(title: "Version \(AppInfo.fullVersion)", subtitle: updates.line) {
            if case .available = updates.state {
                Button("See Release") { UpdateChecker.openReleasePage() }.buttonStyle(ActionStyle(kind: .quiet, small: true))
            } else {
                Button("Check for Updates") { updates.check() }
                    .buttonStyle(ActionStyle(kind: .quiet, small: true))
                    .disabled(updates.state == .checking)
            }
        }
    }
}
