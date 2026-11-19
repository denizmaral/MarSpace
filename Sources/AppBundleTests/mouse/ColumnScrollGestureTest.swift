@testable import AppBundle
import AppKit
import CoreGraphics
import Testing

/// Two fingers sideways on the trackpad move through the columns of a scrolling workspace (see TrackpadColumnScrolling).
/// A column per 110 points of the fingers
@Suite
struct ColumnScrollGestureTest {
    @Test func testSidewaysMovesColumns() {
        var gesture = ColumnScrollGesture()
        assertEquals(gesture.handle(.began, dx: 0, dy: 0, isWanted: true).verdict, .pass)
        // Too short to tell the direction: the app gets it
        assertEquals(gesture.handle(.changed, dx: -3, dy: 0, isWanted: true).verdict, .pass)
        // Sideways: the app saw the beginning, it gets the end of a canceled gesture
        assertEquals(gesture.handle(.changed, dx: -4, dy: 1, isWanted: true).verdict, .cancelForApp)
        // The fingers go left: the columns on the right come in
        assertEquals(gesture.handle(.changed, dx: -60, dy: 0, isWanted: true).columns, 0)
        assertEquals(gesture.handle(.changed, dx: -60, dy: 0, isWanted: true).columns, 1)
        assertEquals(gesture.handle(.changed, dx: -230, dy: 0, isWanted: true).columns, 2)
        // It moved columns: the rest isn't a flick
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true).verdict, .take)
        // Its momentum doesn't reach the app either, and doesn't move columns
        assertEquals(gesture.handle(.momentum, dx: -80, dy: 0, isWanted: true).verdict, .take)
        assertEquals(gesture.handle(.momentum, dx: -80, dy: 0, isWanted: true).columns, 0)
    }

    @Test func testTheFingersGoingRightBringTheColumnsOnTheLeft() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 120, dy: 2, isWanted: true).columns, -1)
    }

    /// Settings › General › Reverse direction: the fingers going left bring the columns on the left
    @Test func testTheDirectionCanBeReversed() {
        let screen = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let center = CGPoint(x: 960, y: 540)
        for (isReversed, columns) in [(false, 1), (true, -1)] {
            var shared = TrackpadColumnScrolling.Shared(screens: [screen], isReversed: isReversed)
            _ = shared.handle(.began, dx: 0, dy: 0, at: center, modifiers: [], isContinuous: true)
            assertEquals(shared.handle(.changed, dx: -120, dy: 2, at: center, modifiers: [], isContinuous: true).columns, columns)
        }
    }

    /// Only over a scrolling workspace, from a trackpad, with exactly the modifiers of the settings
    @Test func testTheScreenTheDeviceAndTheModifiersDecide() {
        let screen = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let floating = Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300)
        func columns(at location: CGPoint, modifiers: CGEventFlags = .maskAlternate, isContinuous: Bool = true) -> Int {
            var shared = TrackpadColumnScrolling.Shared(screens: [screen], excluded: [floating], modifiers: .maskAlternate)
            _ = shared.handle(.began, dx: 0, dy: 0, at: location, modifiers: modifiers, isContinuous: isContinuous)
            return shared.handle(.changed, dx: -120, dy: 0, at: location, modifiers: modifiers, isContinuous: isContinuous).columns
        }
        assertEquals(columns(at: CGPoint(x: 960, y: 540)), 1)
        assertEquals(columns(at: CGPoint(x: 960, y: 540), modifiers: []), 0)
        assertEquals(columns(at: CGPoint(x: 960, y: 540), modifiers: [.maskAlternate, .maskShift]), 0)
        assertEquals(columns(at: CGPoint(x: 960, y: 540), isContinuous: false), 0) // A mouse wheel
        assertEquals(columns(at: CGPoint(x: 200, y: 200)), 0) // Over a floating window
        assertEquals(columns(at: CGPoint(x: 2500, y: 540)), 0) // Another monitor
    }

    /// The settings window keeps the gestures only while it's in front: behind the windows of another app it would take
    /// them over the whole screen
    @MainActor
    @Test func testOwnWindowsKeepTheGesturesOnlyInFront() {
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        let border = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        border.ignoresMouseEvents = true
        border.isReleasedWhenClosed = false
        for window in [settings, panel, border] { window.orderFrontRegardless() }
        defer { for window in [settings, panel, border] { window.orderOut(nil) } }

        assertEquals(TrackpadColumnScrolling.ownWindowsInFront([settings, panel, border], isAppActive: true), [settings, panel])
        assertEquals(TrackpadColumnScrolling.ownWindowsInFront([settings, panel, border], isAppActive: false), [panel])
    }

    /// A quick flick is shorter than a column: it moves one anyway
    @Test func testAFlickMovesAColumn() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: -25, dy: 0, isWanted: true), (.cancelForApp, 0))
        assertEquals(gesture.handle(.changed, dx: -30, dy: 0, isWanted: true), (.take, 0))
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.take, 1))

        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        _ = gesture.handle(.changed, dx: 40, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.take, -1))

        // The fingers only brushed the trackpad
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        _ = gesture.handle(.changed, dx: 12, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.take, 0))
    }

    @Test func testUpAndDownStaysWithTheApp() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 3, dy: -12, isWanted: true).verdict, .pass)
        // Later sideways in the same gesture: still the app's
        assertEquals(gesture.handle(.changed, dx: 300, dy: 0, isWanted: true).verdict, .pass)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.pass, 0))
        assertEquals(gesture.handle(.momentum, dx: 50, dy: 0, isWanted: true).verdict, .pass)
        // A new gesture decides again
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 20, dy: 0, isWanted: true).verdict, .cancelForApp)
    }

    @Test func testNotWanted() {
        // Over a tiling workspace or a floating window, without the key of the settings, or a mouse wheel
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: false)
        assertEquals(gesture.handle(.changed, dx: 300, dy: 0, isWanted: true).verdict, .pass)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.pass, 0))
        assertEquals(gesture.handle(.none, dx: 300, dy: 0, isWanted: true).verdict, .pass)
    }
}

private func assertEquals(
    _ actual: (verdict: ColumnScrollGesture.Verdict, columns: Int),
    _ expected: (ColumnScrollGesture.Verdict, Int),
    sourceLocation: SourceLocation = #_sourceLocation,
) {
    #expect(actual.verdict == expected.0 && actual.columns == expected.1, "\(actual)", sourceLocation: sourceLocation)
}
