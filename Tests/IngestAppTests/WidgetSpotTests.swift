// Where the widget hangs, with two displays. The coordinates are a real external display above a real MacBook screen, and
// the status item's window as macOS reported it on each: it follows the pointer from one to the other, open widget or not.
import AppKit
import SwiftUI
import Testing
@testable import IngestApp

private let big = WidgetSpot.Screen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visible: CGRect(x: 0, y: 0, width: 2560, height: 1410))
private let laptop = WidgetSpot.Screen(frame: CGRect(x: 411, y: -1117, width: 1728, height: 1117), visible: CGRect(x: 411, y: -1117, width: 1728, height: 1084))
private let itemOnBig = CGRect(x: 2036, y: 1409, width: 17, height: 33)
private let itemOnLaptop = CGRect(x: 1615, y: -33, width: 17, height: 33)
private let width: CGFloat = 320

private func open(on screen: WidgetSpot.Screen, item: CGRect) throws -> WidgetSpot {
    try #require(WidgetSpot.next(held: nil, isOpen: false, screens: [big, laptop], opening: screen, item: item, width: width))
}

@Suite("Where the widget hangs") struct WidgetSpotTests {
    @Test func `It opens under the status item, on the screen it's told`() throws {
        let spot = try open(on: laptop, item: itemOnLaptop)
        #expect(spot.screen == laptop)
        #expect(spot.right == itemOnLaptop.maxX)
        #expect(spot.top == itemOnLaptop.minY - 6)
    }

    @Test func `Open, it stays put when the status item goes to the other screen`() throws {
        let spot = try open(on: big, item: itemOnBig)
        let later = WidgetSpot.next(held: spot, isOpen: true, screens: [big, laptop], opening: laptop, item: itemOnLaptop, width: width)
        #expect(later == spot)
    }

    @Test func `It only grows and shrinks downward`() throws {
        let m = StatusBar.margin
        let spot = try open(on: big, item: itemOnBig)
        let moved = try #require(WidgetSpot.next(held: spot, isOpen: true, screens: [big, laptop], opening: laptop, item: itemOnLaptop, width: width))
        let short = moved.frame(height: 200, width: width, margin: m), tall = moved.frame(height: 700, width: width, margin: m)
        #expect(short.maxY == tall.maxY)
        #expect(short.maxX == tall.maxX && short.minX == tall.minX)
        #expect(short.height + 500 == tall.height, "the bottom edge does the moving")
        #expect(tall.maxY == spot.top + m.top)
        #expect(tall.maxX == spot.right + m.right)
    }

    @Test func `A very tall widget stops at the screen's room`() throws {
        let spot = try open(on: big, item: itemOnBig)
        #expect(spot.room == 1394)
        #expect(spot.frame(height: 5000, width: width, margin: StatusBar.margin).height == 1394 + StatusBar.margin.top + StatusBar.margin.bottom)
    }

    @Test func `Closed and opened again, it goes where it's told`() throws {
        let spot = try open(on: big, item: itemOnBig)
        let again = try #require(WidgetSpot.next(held: spot, isOpen: false, screens: [big, laptop], opening: laptop, item: itemOnLaptop, width: width))
        #expect(again.screen == laptop)
        #expect(again.right == itemOnLaptop.maxX)
    }

    @Test func `A display going away moves it to what's left`() throws {
        let spot = try open(on: big, item: itemOnBig)
        let after = try #require(WidgetSpot.next(held: spot, isOpen: true, screens: [laptop], opening: laptop, item: itemOnLaptop, width: width))
        #expect(after.screen == laptop)
        #expect(after.right == itemOnLaptop.maxX)
        #expect(after.top == itemOnLaptop.minY - 6)
    }

    @Test func `A changed resolution finds its place again`() throws {
        let spot = try open(on: big, item: itemOnBig)
        let smaller = WidgetSpot.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visible: CGRect(x: 0, y: 0, width: 1920, height: 1050))
        let item = CGRect(x: 1500, y: 1049, width: 17, height: 33)
        let after = try #require(WidgetSpot.next(held: spot, isOpen: true, screens: [smaller, laptop], opening: smaller, item: item, width: width))
        #expect(after.screen == smaller)
        #expect(after.right == item.maxX)
    }

    @Test func `The Dock changing the room doesn't move it, and the room follows`() throws {
        let spot = try open(on: big, item: itemOnBig)
        var withDock = big
        withDock.visible = CGRect(x: 0, y: 80, width: 2560, height: 1330)
        let after = try #require(WidgetSpot.next(held: spot, isOpen: true, screens: [withDock, laptop], opening: laptop, item: itemOnLaptop, width: width))
        #expect(after.right == spot.right && after.top == spot.top)
        #expect(after.screen == withDock)
        #expect(after.room == 1314)
    }

    @Test func `It's never hung off the edge of a screen`() throws {
        let nearLeft = CGRect(x: laptop.visible.minX + 2, y: -33, width: 17, height: 33)
        #expect(try open(on: laptop, item: nearLeft).right == laptop.visible.minX + 8 + width)
        let pastRight = CGRect(x: big.visible.maxX - 3, y: 1409, width: 17, height: 33)
        #expect(try open(on: big, item: pastRight).right == big.visible.maxX - 8)
    }

    @Test func `A top that's above the visible area is brought down`() throws {
        let high = CGRect(x: 2036, y: 1500, width: 17, height: 33)
        #expect(try open(on: big, item: high).top == big.visible.maxY - 6)
    }

    // macOS can take a second to bring the status item across, and a click can get there first.
    @Test func `A click on the other menu bar opens there, wherever the item's window still is`() throws {
        let click = NSPoint(x: 1623, y: -15)
        let screen = try #require(WidgetSpot.screen(at: click, in: [big, laptop]))
        #expect(screen == laptop)
        let item = WidgetSpot.item(window: itemOnBig, on: screen, click: click)
        let spot = try open(on: screen, item: item)
        #expect(spot.screen == laptop)
        #expect(laptop.visible.contains(CGPoint(x: spot.right - 1, y: spot.top - 1)), "\(spot)")
        #expect(abs(spot.right - click.x) <= 8)
    }

    @Test func `With the item's window where it was clicked, its own place is used`() {
        #expect(WidgetSpot.item(window: itemOnBig, on: big, click: NSPoint(x: 2044, y: 1425)) == itemOnBig)
    }

    @Test func `A click on the very top pixel still finds its screen`() {
        #expect(WidgetSpot.screen(at: NSPoint(x: 2000, y: 1440), in: [laptop, big]) == big)
    }

    @Test func `No screens at all, no spot`() {
        #expect(WidgetSpot.next(held: nil, isOpen: false, screens: [], opening: nil, item: nil, width: width) == nil)
    }
}

@Suite("The menu behind the quiet control") @MainActor struct PullDownTests {
    private let entries: [PullDown.Entry] = [.item("History") {}, .separator, .item("Quit") {}]

    @Test func `The menu is only what's in it, with no face of its own`() {
        let items = PullDown.menu(entries).items
        #expect(items.count == 3)
        #expect(items.first?.title == "History", "a blank first item is what drew a second control over the first")
    }

    @Test func `It opens below the button, not over it`() {
        let b = PullDownButton(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        let below = b.isFlipped ? b.menuOrigin.y - b.bounds.maxY : b.bounds.minY - b.menuOrigin.y
        #expect(below == PullDownButton.gap)
        #expect(b.menuOrigin.x == 0, "lined up with the button's left edge")
    }

    @Test func `Pressing it opens that menu, from that button`() {
        let b = PullDownButton(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        let menu = PullDown.menu(entries)
        b.pullDown = menu
        var opened: (NSMenu, NSPoint, NSView)?
        b.present = { opened = ($0, $1, $2) }
        #expect(b.sendAction(b.action, to: b.target))
        #expect(opened?.0 === menu)
        #expect(opened?.1 == b.menuOrigin)
        #expect(opened?.2 === b)
    }

    @Test func `A press takes effect on the way down, as a menu does`() {
        let b = PullDownButton(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        #expect(UInt64(b.sendAction(on: .leftMouseDown)) == NSEvent.EventTypeMask.leftMouseDown.rawValue)
        #expect(b.title.isEmpty && !b.isBordered, "nothing drawn but the symbol")
    }
}
