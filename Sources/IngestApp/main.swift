import AppKit
import IngestCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel()
    private var bar: StatusBar?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.keyboardMenu()
        let bar = StatusBar(model: Self.model)
        self.bar = bar
        Windows.shared.bar = bar
        // A new person meets setup. Anyone with a drive already set up never sees it.
        Self.model.onFirstLook = {
            let model = Self.model
            guard !model.stores.sawFirstRun, !model.drives.contains(where: { $0.setup != nil }) else { return }
            model.stores.sawFirstRun = true
            // One drive is read straight away. With several, the person says which: it could be camera media.
            Windows.shared.bar?.showSetup(drive: model.drives.count == 1 ? model.drives[0] : nil)
        }
        Self.model.start()
        #if UPDATE_TEST
        UpdateEndToEnd.run(model: Self.model)
        #endif
    }

    /// Never on screen in an accessory app, but it's what makes Cmd+Q, Cmd+W and text editing keys work.
    private static func keyboardMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: AppInfo.name, action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        return main
    }

    /// Opening the app again from Applications. A full menu bar can hide the mark, and this is the way back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.shared.bar?.openForUser()
        return false
    }

    /// Every way of quitting lands here, Cmd+Q included.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.mayQuit() else {
            Self.model.updates.restartRefused()
            return .terminateCancel
        }
        guard Self.model.isCopying else { return .terminateNow }
        // A stopped job still has to end properly. One that's killed never seals, and holds until a later check finishes it.
        Task { @MainActor in
            for _ in 0..<600 where Self.model.isCopying { try? await Task.sleep(for: .milliseconds(50)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func mayQuit() -> Bool {
        #if UPDATE_TEST
        if UpdateEndToEnd.answersKeepCopying() { return false }
        #endif
        return Windows.shared.mayQuit(model: model)
    }

    func applicationWillTerminate(_ n: Notification) {
        for c in Self.model.cards { c.control.stop() }
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { DemoRenderer.run(to: CommandLine.arguments[i + 1]) }
} else if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 3 < CommandLine.arguments.count {
    let a = CommandLine.arguments
    MainActor.assumeIsolated { SelfTest.run(drive: a[i + 1], card: a[i + 2], out: a[i + 3]) }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
