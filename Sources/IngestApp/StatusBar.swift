import AppKit
import IngestCore
import SwiftUI

/// A panel that can take the keyboard without making the app in front give it up.
final class IngestPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// The first click in a panel that isn't key still lands on what was clicked.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the widget hangs: a screen, the widget's right edge and its top. Worked out once when it opens, then held, because
/// macOS moves a status item's window to whichever display the pointer is on, up to a few seconds later, open widget or not.
struct WidgetSpot: Equatable {
    struct Screen: Equatable { var frame: CGRect; var visible: CGRect }
    var screen: Screen
    var right: CGFloat
    var top: CGFloat

    /// An open widget keeps its spot for as long as its screen is there with the same frame. Otherwise, and on opening, it
    /// hangs from `item` on `opening`. A word changing in the menu bar moves the item too, which is another reason to hold.
    static func next(held: WidgetSpot?, isOpen: Bool, screens: [Screen], opening: Screen?, item: CGRect?, width: CGFloat) -> WidgetSpot? {
        if isOpen, let held, let same = screens.first(where: { $0.frame == held.screen.frame }) {
            return WidgetSpot(screen: same, right: held.right, top: held.top)
        }
        guard let screen = opening ?? screens.first else { return nil }
        let v = screen.visible
        let right = min(max(item?.maxX ?? v.maxX, v.minX + 8 + width), v.maxX - 8)
        return WidgetSpot(screen: screen, right: right, top: min(item?.minY ?? v.maxY, v.maxY) - 6)
    }

    /// The screen a click landed on. The very top of the top display reads as just outside it.
    static func screen(at p: NSPoint, in screens: [Screen]) -> Screen? {
        screens.first { $0.frame.contains(p) } ?? screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }
    }

    /// What a click hangs the widget from: the item's window if it's on that screen, and if it hasn't got there yet, the click.
    static func item(window: CGRect?, on screen: Screen, click: NSPoint) -> CGRect {
        if let window, window.intersects(screen.frame) { return window }
        return CGRect(x: click.x - 8, y: screen.visible.maxY, width: 16, height: 0)
    }

    var room: CGFloat { screen.visible.height - 16 }

    /// The top and the sides stay where they are: only the bottom edge moves.
    func frame(height: CGFloat, width: CGFloat, margin m: NSEdgeInsets) -> CGRect {
        let h = min(height, room) + m.top + m.bottom, w = width + m.left + m.right
        return CGRect(x: right + m.right - w, y: top + m.top - h, width: w, height: h)
    }
}

/// The verdict in the menu bar, and the widget hanging from it.
@MainActor final class StatusBar: NSObject, NSWindowDelegate {
    /// Room around the widget for its own shadow, which has to travel with it as it resizes.
    static let margin = NSEdgeInsets(top: 4, left: 30, bottom: 44, right: 30)

    let model: AppModel
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let panel: IngestPanel
    let ui = PanelUI()
    private(set) var state = MenuBarState(word: "", spoken: "")
    /// True for a widget that opened by itself and hasn't been touched: it stays until told otherwise.
    private(set) var openedByItself = false
    var holdOpen = false
    private var spot: WidgetSpot?
    private var height: CGFloat = 200
    private var shrink: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        panel = IngestPanel(contentRect: NSRect(x: 0, y: 0, width: Grid.width + 60, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }
        panel.contentView = host()
        ui.onHeight = { [weak self] h in self?.fit(height: h) }
        // A display can go, or change size, with nothing in the widget changing.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel.isVisible == true { self?.place() } }
        }

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onArrival = { [weak self] in self?.arrival() }
        model.onEjected = { [weak self] in if self?.model.cards.isEmpty == true, self?.ui.setup == nil { self?.hide() } }
        track()
    }

    private func host() -> NSView {
        let m = Self.margin
        let shape = RoundedRectangle(cornerRadius: Grid.radius, style: .continuous)
        let root = PanelView()
            .environment(model)
            .environment(ui)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.2), radius: 22, y: 12)
            .padding(EdgeInsets(top: m.top, leading: m.left, bottom: m.bottom, trailing: m.right))
            .frame(maxHeight: .infinity, alignment: .top)
        let view = FirstClickHostingView(rootView: root)
        view.sizingOptions = []
        return view
    }

    // MARK: The menu bar

    /// Redraws whenever anything the verdict depends on changes.
    private func track() {
        let next = withObservationTracking { MenuBarState.make(model) } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if openedByItself, ui.setup == nil, model.cards.isEmpty, model.maybeCards.isEmpty, model.unreadable.isEmpty { hide() }
        guard next != state || item.button?.image == nil else { return }
        let wasSafe = state.isSafe
        state = next
        item.button?.image = MenuBarArt.image(for: next)
        item.button?.setAccessibilityLabel(next.spoken)
        item.button?.toolTip = next.spoken
        if next.isSafe != wasSafe {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: next.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu(); return }
        if panel.isVisible { hide() } else { openForUser(clickedAt: NSEvent.mouseLocation) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.add(entries)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Everything behind the one quiet control, the same from `···` and from a right-click on the mark.
    var entries: [PullDown.Entry] {
        var out: [PullDown.Entry] = model.cardsToCheckAgain.map { c in .item("Check \(c.name) Again") { [weak self] in self?.model.recheck(c) } }
        if !out.isEmpty { out.append(.separator) }
        out += LibraryView.Page.allCases.map { p in .item(p == .settings ? "Settings…" : p.rawValue) { [weak self] in self?.show(p) } }
        out.append(.separator)
        if case .available(let version) = model.updates.state {
            out.append(.item("Update to \(version)…") { UpdateChecker.openReleasePage() })
        } else {
            out.append(.item("Check for Updates…") { [weak self] in self?.show(.settings); self?.model.updates.check() })
        }
        out.append(.item(FeedbackReport.Kind.bug.title + "…") { [weak self] in self?.show(.bug) })
        out.append(.item(FeedbackReport.Kind.feature.title + "…") { [weak self] in self?.show(.feature) })
        out += [.separator, .item("Quit \(AppInfo.name)") { NSApp.terminate(nil) }]
        return out
    }

    // MARK: The widget

    /// A card went in. The widget shows, and the app in front keeps the keyboard.
    private func arrival() {
        guard model.opensOnCardIn else { return }
        ui.page = nil               // whatever was open, the card comes first
        ui.feedback = nil
        guard !panel.isVisible else { return }
        openedByItself = true
        // The menu bar is still fitting the new word, so the mark isn't where it will end up yet.
        afterMenuBarSettles { [self] in
            guard openedByItself, !panel.isVisible else { return }
            place()
            panel.orderFrontRegardless()
            item.button?.highlight(true)
        }
    }

    /// Waits until the status item has held its position for a few frames, for no more than a quarter of a second.
    private func afterMenuBarSettles(_ then: @escaping () -> Void) {
        var last = item.button?.window?.frame
        var still = 0, waited = 0
        func check() {
            let now = item.button?.window?.frame
            still = now == last ? still + 1 : 0
            last = now
            waited += 1
            if still >= 3 || waited >= 15 { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: check)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: check)
    }

    /// A click on the menu bar means someone wants it, so it takes the keyboard. The other app stays active.
    func openForUser(clickedAt click: NSPoint? = nil) {
        openedByItself = false
        ui.page = nil
        ui.feedback = nil
        place(clickedAt: click)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        if !model.unreadable.isEmpty { Task { await model.refresh() } }
        model.lookAgain()
        if model.checksForUpdates, !model.isDemo { model.updates.checkIfDue() }
    }

    func show(_ page: LibraryView.Page) {
        if !panel.isVisible { openForUser() }
        ui.feedback = nil
        ui.page = page
    }

    func show(_ feedback: FeedbackReport.Kind) {
        if !panel.isVisible { openForUser() }
        ui.feedback = feedback
    }

    /// Setup opens here, on first launch and from wherever it's asked for, and stays until it's finished or closed.
    func showSetup(drive: DriveState?) {
        if !panel.isVisible { openForUser() }
        ui.setup = SetupRequest(drive: drive)
    }

    func hide() {
        openedByItself = false
        spot = nil
        ui.page = nil
        ui.feedback = nil
        ui.setup = nil
        panel.orderOut(nil)
        item.button?.highlight(false)
    }

    private func escape() {
        if ui.setup != nil { ui.setup = nil } else if ui.feedback != nil { ui.feedback = nil } else if ui.page != nil { ui.page = nil } else { hide() }
    }

    /// The window grows at once and shrinks late, so the widget animates inside it, never cut by its edge.
    private func fit(height h: CGFloat) {
        guard h > 1, abs(h - height) > 0.5 else { return }
        let grew = h > height
        height = h
        shrink?.cancel()
        // This arrives in the middle of a SwiftUI update, which mustn't resize the window under itself.
        let work = DispatchWorkItem { [weak self] in if self?.panel.isVisible == true { self?.place() } }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (grew || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.34), execute: work)
    }

    /// Puts the widget where it hangs. It's the only thing that moves the window, and an open widget only changes height.
    private func place(clickedAt click: NSPoint? = nil) {
        func described(_ s: NSScreen) -> WidgetSpot.Screen { WidgetSpot.Screen(frame: s.frame, visible: s.visibleFrame) }
        let screens = NSScreen.screens.map(described)
        var opening = (item.button?.window?.screen ?? NSScreen.main).map(described)
        var anchor = item.button?.window?.frame
        if let click, let clicked = WidgetSpot.screen(at: click, in: screens) {
            opening = clicked
            anchor = WidgetSpot.item(window: anchor, on: clicked, click: click)
        }
        guard let next = WidgetSpot.next(held: spot, isOpen: panel.isVisible, screens: screens, opening: opening, item: anchor, width: Grid.width) else { return }
        spot = next
        if ui.maxBodyHeight != next.room { ui.maxBodyHeight = next.room }
        panel.setFrame(next.frame(height: height, width: Grid.width, margin: Self.margin), display: true)
    }

    func windowDidBecomeKey(_ n: Notification) {
        openedByItself = false      // touched: from here it behaves like anything else opened from the menu bar
        ui.isKey = true
    }

    func windowDidResignKey(_ n: Notification) {
        ui.isKey = false
        // A date picker or a menu is part of the widget. Anything else means someone has moved on.
        DispatchQueue.main.async { [self] in
            guard !holdOpen, ui.setup == nil, !panel.isKeyWindow, panel.attachedSheet == nil, panel.childWindows?.isEmpty ?? true else { return }
            hide()
        }
    }
}

/// An `NSMenuItem` that runs a closure.
final class ClosureItem: NSMenuItem {
    private let run: @MainActor () -> Void
    init(_ title: String, _ action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { MainActor.assumeIsolated { run() } }
}

/// The word, then an SD card at 16 pt: one template image the system tints for any menu bar.
/// A status item grows to the left, so with the card last it never moves as the word changes.
enum MenuBarArt {
    private static let height: CGFloat = 18

    @MainActor static func image(for s: MenuBarState) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let text = NSAttributedString(string: s.word, attributes: [.font: font, .foregroundColor: NSColor.black])
        let side: CGFloat = 16
        let gap: CGFloat = s.word.isEmpty ? 0 : 5
        let word = ceil(text.size().width)
        let size = NSSize(width: word + gap + side, height: height)
        let two = s.twoCards
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.set()
            text.draw(at: NSPoint(x: 0, y: (height - text.size().height) / 2))
            NSGraphicsContext.current?.cgContext.translateBy(x: word + gap, y: 1)
            two ? twoCards() : card()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = s.spoken
        return image
    }

    private static func stroke(_ p: NSBezierPath, _ width: CGFloat, round: Bool = false) {
        p.lineWidth = width
        p.lineJoinStyle = .round
        if round { p.lineCapStyle = .round }
        p.stroke()
    }

    private static func card() {
        let b = NSBezierPath()
        b.move(to: NSPoint(x: 3.5, y: 1.5))
        b.line(to: NSPoint(x: 9.7, y: 1.5))
        b.line(to: NSPoint(x: 12.5, y: 4.3))
        b.line(to: NSPoint(x: 12.5, y: 13))
        b.appendArc(withCenter: NSPoint(x: 11, y: 13), radius: 1.5, startAngle: 0, endAngle: 90)
        b.line(to: NSPoint(x: 3.5, y: 14.5))
        b.appendArc(withCenter: NSPoint(x: 3.5, y: 13), radius: 1.5, startAngle: 90, endAngle: 180)
        b.line(to: NSPoint(x: 2, y: 3))
        b.appendArc(withCenter: NSPoint(x: 3.5, y: 3), radius: 1.5, startAngle: 180, endAngle: 270)
        b.close()
        stroke(b, 1.4)
        for x in [4.5, 6.3, 8.1] as [CGFloat] {
            let pin = NSBezierPath()
            pin.move(to: NSPoint(x: x, y: 3.2))
            pin.line(to: NSPoint(x: x, y: 5.2))
            stroke(pin, 1.2, round: true)
        }
    }

    private static func twoCards() {
        let front = NSBezierPath()
        front.move(to: NSPoint(x: 1.5, y: 4))
        front.line(to: NSPoint(x: 6.5, y: 4))
        front.line(to: NSPoint(x: 8.5, y: 6))
        front.line(to: NSPoint(x: 8.5, y: 13.5))
        front.appendArc(withCenter: NSPoint(x: 7.5, y: 13.5), radius: 1, startAngle: 0, endAngle: 90)
        front.line(to: NSPoint(x: 1.5, y: 14.5))
        front.appendArc(withCenter: NSPoint(x: 1.5, y: 13.5), radius: 1, startAngle: 90, endAngle: 180)
        front.line(to: NSPoint(x: 0.5, y: 5))
        front.appendArc(withCenter: NSPoint(x: 1.5, y: 5), radius: 1, startAngle: 180, endAngle: 270)
        front.close()
        stroke(front, 1.3)
        let back = NSBezierPath()
        back.move(to: NSPoint(x: 7.5, y: 1.5))
        back.line(to: NSPoint(x: 12.5, y: 1.5))
        back.line(to: NSPoint(x: 14.5, y: 3.5))
        back.line(to: NSPoint(x: 14.5, y: 11))
        back.appendArc(withCenter: NSPoint(x: 13.5, y: 11), radius: 1, startAngle: 0, endAngle: 90)
        back.line(to: NSPoint(x: 9, y: 12))
        stroke(back, 1.3)
    }
}
