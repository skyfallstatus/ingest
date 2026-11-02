import AppKit
import IngestCore
import SwiftUI

/// Writing a bug report or a suggestion, as a page of the widget. Nothing leaves until a person sends it from their
/// browser or pastes it somewhere, and they can read everything that goes with it first.
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
                                    sentence: "Opens on GitHub, ready to send. If GitHub says page not found, use Copy Details and send it to the person who gave you the app.")) {
                HStack(spacing: 6) {
                    Button("Copy Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.plainText, forType: .string)
                        copied = true
                    }
                    .buttonStyle(ActionStyle(kind: .quiet))
                    Button("Open GitHub") { if let url = report.issueURL { NSWorkspace.shared.open(url) } }
                        .buttonStyle(ActionStyle())
                }
            }
        }
        .onAppear { typing = true }
    }
}
