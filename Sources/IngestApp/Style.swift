import AppKit
import SwiftUI

/// The design's tokens. White and light grey; Cobalt on the primary action only; green only on a proved card.
extension Color {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
    }

    static let ink = dynamic(hex(0x1D1D1F), hex(0xEDEDEE))
    static let ink2 = dynamic(hex(0x5F6063), hex(0xADADB1))     // solid: `.secondary` measures under 4.5:1 on white
    static let ink3 = dynamic(hex(0x8E8E93), hex(0x7C7C82))     // placeholders only
    static let surface = dynamic(hex(0xFFFFFF), hex(0x26262A))
    static let foot = dynamic(hex(0xF4F4F6), hex(0x1C1C1F))
    static let line = dynamic(hex(0x000000, 0.08), hex(0xFFFFFF, 0.10))
    static let disc = dynamic(hex(0xE7E7EC), hex(0x3A3A40))
    static let tick = dynamic(hex(0x3A3A3C), hex(0xEDEDEE))
    static let ring = dynamic(hex(0xC9C9CE), hex(0x55555C))
    static let track = dynamic(hex(0xE9E9EE), hex(0x3A3A40))
    static let meter = dynamic(hex(0x6E6E73), hex(0xA0A0A6))
    static let focusRing = dynamic(hex(0x8A8A90), hex(0x9A9AA0))
    static let cobalt = dynamic(hex(0x2563EB), hex(0x2F6FE6))
    static let bad = dynamic(hex(0xC9281C), hex(0xFF6A5F))
    static let safe = Color(nsColor: hex(0x15803D))
}

extension Font {
    static let reel = Font.system(size: 15, weight: .semibold)
    static let body13 = Font.system(size: 13)
    static let small12 = Font.system(size: 12)
    static let column = Font.system(size: 10.5)
    static let verdict = Font.system(size: 17, weight: .semibold)
}

/// The pitch of everything in the widget.
enum Grid {
    static let width: CGFloat = 320
    static let side: CGFloat = 16
    static let mark: CGFloat = 14
    static let markGap: CGFloat = 8
    static var text: CGFloat { mark + markGap }      // the label column, from the sheet's edge
    static let files: CGFloat = 36
    static let gb: CGFloat = 46
    static let rowHeight: CGFloat = 26
    static let radius: CGFloat = 14
}

/// The widget's one button. `primary` is Cobalt; `onSafe` is white on the green foot, so two colours never meet.
struct ActionStyle: ButtonStyle {
    enum Kind { case primary, quiet, onSafe }
    var kind: Kind = .primary
    var small = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration c: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return c.label
            .font(.system(size: small ? 11.5 : 12.5, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(kind == .primary ? Color.white : kind == .onSafe ? Color.safe : Color.ink)
            .padding(.horizontal, small ? 9 : 11)
            .frame(height: small ? 24 : 26)
            .background(shape.fill(fill).opacity(kind == .primary && !isEnabled ? 0.36 : 1))
            .scaleEffect(c.isPressed ? 0.97 : 1)
            .contentShape(shape)
    }
    private var fill: Color {
        switch kind {
        case .primary: .cobalt
        case .quiet: .track
        case .onSafe: .white
        }
    }
}

/// Quiet words that do something: Choose Folder, Add to, Did you mean.
struct LinkStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.small12).foregroundStyle(Color.ink2)
            .underline(color: Color.ink2.opacity(0.35))
            .opacity(c.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}

/// A glyph in a 22 by 20 target. `.trailing` puts its ink on the column's edge rather than the target's middle.
struct IconStyle: ButtonStyle {
    var edge: Alignment = .center
    var tint: Color = .ink2
    func makeBody(configuration c: Configuration) -> some View {
        c.label.foregroundStyle(tint).frame(width: 22, height: 20, alignment: edge)
            .opacity(c.isPressed ? 0.5 : 1).contentShape(Rectangle())
    }
}

/// Grey ring, turning arc, grey tick, and the same disc green once the whole card is proved. One 14 pt box throughout,
/// so text never shifts. A failed or looked-at line has its own shape and is never green.
struct MarkView: View {
    let mark: LineMark
    var proved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch mark {
            case .waiting: Circle().strokeBorder(Color.ring, lineWidth: 1.4)
            case .running: Spinner()
            case .done:
                Circle().fill(proved ? Color.safe : Color.disc)
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(proved ? Color.white : Color.tick)
            case .skipped: Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Color.ink2)
            case .look: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.ink)
            case .failed: Image(systemName: "xmark.octagon.fill").font(.system(size: 14)).foregroundStyle(Color.bad)
            }
        }
        .frame(width: Grid.mark, height: Grid.mark)
        .animation(reduceMotion || Motion.off ? nil : .easeInOut(duration: 0.2), value: proved)
        .accessibilityHidden(true)
    }
}

/// An arc in the waiting ring. Still, under Reduce Motion, and still legible.
struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.ring, lineWidth: 1.4)
            Circle().inset(by: 0.7).trim(from: 0, to: 0.28)
                .stroke(Color.ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .rotationEffect(.degrees(turning ? 270 : -90))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

/// A menu hanging from its own button. AppKit, so it works in a key-less panel and the self-test can press it.
struct PullDown: NSViewRepresentable {
    enum Entry {
        case item(String, @MainActor () -> Void)
        case header(String)
        case separator
    }
    var symbol: String? = nil
    var color: NSColor = .secondaryLabelColor
    var size: CGFloat = 12.5
    var spoken: String
    var entries: @MainActor () -> [Entry]       // read on each press: what's in a menu can change with nothing here looking at it

    func makeNSView(context: Context) -> PullDownButton {
        let b = PullDownButton(frame: .zero)
        b.setAccessibilityLabel(spoken)
        return b
    }

    func updateNSView(_ b: PullDownButton, context: Context) {
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .bold))
        }
        b.imagePosition = symbol == nil ? .noImage : .imageOnly
        b.entries = entries
        b.contentTintColor = color
    }

    /// The whole of what it's put in. It has no title, so on its own it would ask for no width at all.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PullDownButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    static func menu(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.add(entries)
        return menu
    }
}

/// Opens its menu just below itself. A pull-down `NSPopUpButton` needs a blank first item as its face, and macOS draws that
/// item at the top of the menu, over the button, so the control appears twice.
final class PullDownButton: NSButton {
    static let gap: CGFloat = 8      // the menu's rounded edge sits a little above its first row
    var entries: @MainActor () -> [PullDown.Entry] = { [] }
    var present: (NSMenu, NSPoint, NSView) -> Void = { menu, at, view in menu.popUp(positioning: nil, at: at, in: view) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(open)
        sendAction(on: .leftMouseDown)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A symbol's own insets would leave the button shorter than what it's put in, and a click at the edge of that would miss it.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// Where the menu's top left goes, in this button's coordinates.
    var menuOrigin: NSPoint { NSPoint(x: 0, y: isFlipped ? bounds.maxY + Self.gap : bounds.minY - Self.gap) }

    @objc private func open() {
        present(PullDown.menu(entries()), menuOrigin, self)
    }
}

extension NSMenu {
    func add(_ entries: [PullDown.Entry]) {
        for e in entries {
            switch e {
            case .item(let t, let run): addItem(ClosureItem(t, run))
            case .header(let t): addItem(.sectionHeader(title: t))
            case .separator: addItem(.separator())
            }
        }
    }
}

/// Off for stills, which must land on the finished frame.
@MainActor enum Motion { static var off = false }

extension View {
    /// A place to type more than a line.
    func textBox() -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return scrollContentBackground(.hidden)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .background(shape.fill(Color.foot))
            .overlay(shape.strokeBorder(Color.line, lineWidth: 0.5))
    }

    /// Animates a change unless someone has asked for less of it.
    @MainActor func quietAnimation<V: Equatable>(_ value: V, reduceMotion: Bool, duration: Double = 0.26) -> some View {
        animation(reduceMotion || Motion.off ? nil : .smooth(duration: duration), value: value)
    }
}
