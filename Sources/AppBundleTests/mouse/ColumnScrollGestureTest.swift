@testable import AppBundle
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
            _ = shared.handle(.began, dx: 0, dy: 0, at: center, modifiers: [], isContinuous: true, ownWindowsGeneration: 0, isOwnWindowInFront: false)
            assertEquals(shared.handle(.changed, dx: -120, dy: 2, at: center, modifiers: [], isContinuous: true, ownWindowsGeneration: 0, isOwnWindowInFront: false)?.columns, columns)
        }
    }

    /// Only over a scrolling workspace, from a trackpad, with exactly the modifiers of the settings
    @Test func testTheScreenTheDeviceAndTheModifiersDecide() {
        let screen = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let floating = Rect(topLeftX: 100, topLeftY: 100, width: 400, height: 300)
        func columns(at location: CGPoint, modifiers: CGEventFlags = .maskAlternate, isContinuous: Bool = true) -> Int {
            var shared = TrackpadColumnScrolling.Shared(screens: [screen], excluded: [floating], modifiers: .maskAlternate)
            _ = shared.handle(.began, dx: 0, dy: 0, at: location, modifiers: modifiers, isContinuous: isContinuous, ownWindowsGeneration: 0, isOwnWindowInFront: false)
            return shared.handle(.changed, dx: -120, dy: 0, at: location, modifiers: modifiers, isContinuous: isContinuous, ownWindowsGeneration: 0, isOwnWindowInFront: false)?.columns ?? 0
        }
        assertEquals(columns(at: CGPoint(x: 960, y: 540)), 1)
        assertEquals(columns(at: CGPoint(x: 960, y: 540), modifiers: []), 0)
        assertEquals(columns(at: CGPoint(x: 960, y: 540), modifiers: [.maskAlternate, .maskShift]), 0)
        assertEquals(columns(at: CGPoint(x: 960, y: 540), isContinuous: false), 0) // A mouse wheel
        assertEquals(columns(at: CGPoint(x: 200, y: 200)), 0) // Over a floating window
        assertEquals(columns(at: CGPoint(x: 2500, y: 540)), 0) // Another monitor
    }

    /// A window of MarSpace keeps the gestures where it's in front: the settings window behind the windows of another app
    /// would take them over most of the screen. The window server is asked only when a gesture begins over one of them
    @Test func testOwnWindowsKeepTheGesturesWhereTheyAreInFront() {
        let screen = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let settings = TrackpadColumnScrolling.OwnWindow(number: 7, rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600))
        let over = CGPoint(x: 400, y: 300)
        func swipe(at location: CGPoint, inFront: Bool) -> (columns: Int?, asked: [TrackpadColumnScrolling.OwnWindow]) {
            var shared = TrackpadColumnScrolling.Shared(screens: [screen], ownWindows: [settings])
            let (asked, generation) = shared.ownWindowsToAsk(.began, at: location)
            _ = shared.handle(.began, dx: 0, dy: 0, at: location, modifiers: [], isContinuous: true, ownWindowsGeneration: generation, isOwnWindowInFront: inFront)
            assertEquals(shared.ownWindowsToAsk(.changed, at: location).windows, []) // Decided at the beginning
            let columns = shared.handle(.changed, dx: -120, dy: 0, at: location, modifiers: [], isContinuous: true, ownWindowsGeneration: generation, isOwnWindowInFront: inFront)?.columns
            return (columns, asked)
        }
        // A part of the settings window that is in front: its own
        assertEquals(swipe(at: over, inFront: true).columns, 0)
        assertEquals(swipe(at: over, inFront: true).asked, [settings])
        // Covered by the window of another app: the columns move
        assertEquals(swipe(at: over, inFront: false).columns, 1)
        // Beyond the settings window: nothing to ask the window server
        let elsewhere = swipe(at: CGPoint(x: 1500, y: 800), inFront: true)
        assertEquals(elsewhere.columns, 1)
        assertEquals(elsewhere.asked, [])
    }

    /// The settings window moves while the window server is asked (outside the lock): the answer is about the old place,
    /// the tap asks again
    @Test func testTheWindowServerIsAskedAgainWhenTheOwnWindowsChangedMeanwhile() {
        let screen = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let location = CGPoint(x: 1000, y: 300)
        var shared = TrackpadColumnScrolling.Shared(screens: [screen], ownWindows: [])
        let (asked, generation) = shared.ownWindowsToAsk(.began, at: location)
        assertEquals(asked, []) // Not over the settings window yet
        shared.ownWindows = [TrackpadColumnScrolling.OwnWindow(number: 7, rect: Rect(topLeftX: 600, topLeftY: 0, width: 800, height: 600))]
        #expect(shared.handle(.began, dx: 0, dy: 0, at: location, modifiers: [], isContinuous: true, ownWindowsGeneration: generation, isOwnWindowInFront: false) == nil)
        // Asked again: the settings window is in front there, the gesture is its own
        let again = shared.ownWindowsToAsk(.began, at: location)
        assertEquals(again.windows.map(\.number), [7])
        _ = shared.handle(.began, dx: 0, dy: 0, at: location, modifiers: [], isContinuous: true, ownWindowsGeneration: again.generation, isOwnWindowInFront: true)
        assertEquals(shared.handle(.changed, dx: -120, dy: 0, at: location, modifiers: [], isContinuous: true, ownWindowsGeneration: again.generation, isOwnWindowInFront: true)?.columns, 0)
        // Later events don't decide anything: a change of the windows doesn't matter to them
        shared.ownWindows = []
        assertEquals(shared.handle(.changed, dx: -120, dy: 0, at: location, modifiers: [], isContinuous: true, ownWindowsGeneration: again.generation, isOwnWindowInFront: true)?.columns, 0)
    }

    /// The windows that the window server shows above a window of MarSpace: only the ones of other apps in the normal layer
    /// cover it
    @Test func testWhatCoversAWindowOfMarSpace() {
        let location = CGPoint(x: 400, y: 300)
        let terminal = WindowAbove(isOwn: false, layer: 0, bounds: CGRect(x: 0, y: 0, width: 960, height: 1080))
        let elsewhere = WindowAbove(isOwn: false, layer: 0, bounds: CGRect(x: 960, y: 0, width: 960, height: 1080))
        let dock = WindowAbove(isOwn: false, layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let focusBorder = WindowAbove(isOwn: true, layer: 0, bounds: CGRect(x: 0, y: 0, width: 960, height: 1080))
        #expect(isInFront(at: location, windowsAbove: [])) // Nothing above it
        #expect(!isInFront(at: location, windowsAbove: [terminal]))
        #expect(!isInFront(at: location, windowsAbove: [focusBorder, dock, terminal]))
        #expect(isInFront(at: location, windowsAbove: [elsewhere])) // Not at the location
        #expect(isInFront(at: location, windowsAbove: [dock, focusBorder])) // Another layer, MarSpace's own window
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
