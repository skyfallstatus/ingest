import AppKit
import IngestCore
import SwiftUI

/// Writing a bug report or a suggestion, as a page of the widget. Open GitHub puts it on the clipboard and opens a blank
/// page, so nothing leaves until a person pastes it there and sends it, and they can read all that goes with it first.
struct FeedbackPage: View {
    @Environment(AppModel.self) private var model
    @Environment(PanelUI.self) private var ui
    let kind: FeedbackReport.Kind
    @State private var copied = false
    @FocusState private var typing: Bool

    private var report: FeedbackReport {
        FeedbackReport(kind: kind, message: ui.feedbackDraft, system: ProcessInfo.processInfo.operatingSystemVersion,
                       hardwareModel: Self.hardwareModel, appleSilicon: Self.appleSilicon,
                       cameras: model.cards.compactMap { $0.primaryCamera?.identity.family })
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private static var appleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            SheetHead(title: kind.title, close: { ui.feedbackDraft = ""; ui.feedback = nil })
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $ui.feedbackDraft).font(.body13).focused($typing)
                        .accessibilityLabel(kind.prompt)
                    if ui.feedbackDraft.isEmpty {
                        Text(kind.prompt).font(.body13).foregroundStyle(Color.ink3).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .frame(height: 92).textBox()
                Text("Goes with it: \(report.details). No file names, paths, clients, serials or drive names.")
                    .font(.small12).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Grid.side).padding(.top, 6).padding(.bottom, 10)
            Foot(bottom: BottomLine(kind: .idle, title: copied ? "Copied" : "Send it",
                                    sentence: "Open GitHub copies this and opens a blank page: paste it there and send it. Nothing goes until you do. If GitHub says page not found, send it to the person who gave you the app.")) {
                HStack(spacing: 6) {
                    Button("Copy Details", action: copy).buttonStyle(ActionStyle(kind: .quiet))
                    Button("Open GitHub") {
                        copy()
                        if let url = report.issueURL { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(ActionStyle())
                }
            }
        }
        .onAppear { typing = true }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText, forType: .string)
        copied = true
    }
}
