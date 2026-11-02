import AppKit
import IngestCore

/// The system windows the widget has to borrow: the folder chooser and the quit warning. Everything else hangs from the mark.
@MainActor final class Windows {
    static let shared = Windows()
    weak var bar: StatusBar?

    func chooseFolder(card: CardSession, model: AppModel) {
        guard let drive = model.workingDrive else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: drive.path)
        panel.prompt = "Copy Here"
        guard FileManager.default.fileExists(atPath: card.volume.path) else { card.error = "\(card.name) isn't plugged in any more."; return }
        panel.message = "Choose where \(card.name) goes on \(drive.name). The card is kept whole, in its own folder."
        bar?.holdOpen = true
        defer { bar?.holdOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.path == drive.path || url.path.hasPrefix(drive.path + "/") else {
            card.error = "That folder isn't on \(drive.name)."
            return
        }
        var rel = String(url.path.dropFirst(drive.path.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        let base = card.probe.reel ?? (CardSession.friendlyName(card.volume.name) == "Card" ? "Card 1" : card.volume.name)
        var name = base, n = 2
        while drive.existing(rel.isEmpty ? name : rel + "/" + name) != nil { name = "\(base) \(n)"; n += 1 }
        model.start(card, destination: Destination(footageRoot: rel.isEmpty ? name : rel + "/" + name))
    }

    func mayQuit(model: AppModel) -> Bool {
        guard model.isCopying else { return true }
        let a = NSAlert()
        a.messageText = "A card is still copying"
        a.informativeText = "If you quit, it stops. Everything already checked stays safe, and you can finish later."
        a.addButton(withTitle: "Keep Copying")
        a.addButton(withTitle: "Quit Anyway")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { return false }
        for c in model.cards where c.isBusy { c.control.stop() }
        return true
    }
}
