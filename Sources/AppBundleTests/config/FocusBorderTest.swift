@testable import AppBundle
import Common
import CoreGraphics
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FocusBorderTest {
    init() { setUpWorkspacesForTests() }

    @Test func testArgbCgColor() {
        let color = UInt32(0x80FF_0000).argbCgColor
        assertEquals(color.components?.map { ($0 * 255).rounded() }, [255, 0, 0, 128])
    }

    @Test func testPanelFrameSurroundsTheWindowInCocoaCoordinates() {
        // A window 100pt from the top of a 1169pt high main monitor
        let windowRect = Rect(topLeftX: 20, topLeftY: 100, width: 800, height: 600)
        assertEquals(
            focusBorderPanelFrame(windowRect: windowRect, borderWidth: 4, mainMonitorHeight: 1169),
            CGRect(x: 16, y: 465, width: 808, height: 608), // y = 1169 - 100 - 600 - 4
        )
    }

    @Test func testBorderSurroundsTheWindowInsideTheMonitor() {
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169)
        let window = Rect(topLeftX: 10, topLeftY: 49, width: 960, height: 1110)
        assertEquals(focusBorderWindowRect(window, monitor: monitor, borderWidth: 4), window)
        // Touching the monitor edge is not beyond it
        let fullscreen = Rect(topLeftX: 0, topLeftY: 39, width: 1800, height: 1130)
        assertEquals(focusBorderWindowRect(fullscreen, monitor: monitor, borderWidth: 4), fullscreen)
        assertEquals(focusBorderWindowRect(window, monitor: nil, borderWidth: 4), window)
    }

    /// App Store (at least 1000 wide) placed at its 885 wide tile reaches 105 beyond the right edge of the monitor
    @Test func testBorderFollowsTheMonitorEdgeWhereTheWindowIsBeyondIt() {
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169)
        assertEquals(
            focusBorderWindowRect(Rect(topLeftX: 905, topLeftY: 49, width: 1000, height: 1110), monitor: monitor, borderWidth: 4),
            Rect(topLeftX: 905, topLeftY: 49, width: 891, height: 1110), // The right edge at 1800 - 4
        )
        assertEquals(
            focusBorderWindowRect(Rect(topLeftX: -50, topLeftY: -20, width: 2000, height: 1300), monitor: monitor, borderWidth: 4),
            Rect(topLeftX: 4, topLeftY: 4, width: 1792, height: 1161),
        )
    }

    /// The panel is right next to the focused window, apart from the app's own helper windows
    @Test func testThePanelIsRightNextToTheWindow() {
        let app: Int32 = 100
        let other: Int32 = 200
        let panel: CGWindowID = 9
        let border = StackedWindow(number: 9, pid: 1, layer: 0)
        #expect(isPanelRightNext(to: [border], pid: app, panel: panel))
        #expect(isPanelRightNext(to: [StackedWindow(number: 5, pid: app, layer: 0), border], pid: app, panel: panel)) // A helper window of the app
        #expect(!isPanelRightNext(to: [StackedWindow(number: 6, pid: other, layer: 0), border], pid: app, panel: panel)) // It would cover the border
        #expect(isPanelRightNext(to: [StackedWindow(number: 7, pid: other, layer: 20), border], pid: app, panel: panel)) // The Dock doesn't count
        #expect(!isPanelRightNext(to: [StackedWindow(number: 6, pid: other, layer: 0)], pid: app, panel: panel))
        #expect(!isPanelRightNext(to: [border], pid: app, panel: nil)) // Not shown
        #expect(isPanelRightNext(to: [StackedWindow(number: 8, pid: 1, layer: 0), border], pid: app, panel: panel, ignoring: [8])) // The move flash
    }

    /// The panel is below the focused window: nothing of MarSpace covers the window (macOS hides the buttons of a secure
    /// dialog, e.g. the purchase sheet of App Store, while a window of another app is over it). Above only where the window
    /// reaches beyond the monitor (the border follows the edge, over the window), and only while nothing covers the window
    @Test func testTheBorderGoesOverTheWindowOnlyWhereItMustAndNothingCoversIt() {
        let window = CGRect(x: 905, y: 49, width: 1000, height: 1110)
        let panel: CGWindowID = 9
        let dialog = StackedWindow(number: 5, pid: 100, layer: 0, bounds: CGRect(x: 1200, y: 400, width: 400, height: 300))
        let elsewhere = StackedWindow(number: 6, pid: 200, layer: 0, bounds: CGRect(x: 0, y: 49, width: 895, height: 1110))
        let border = StackedWindow(number: 9, pid: 1, layer: 0, bounds: window.insetBy(dx: -4, dy: -4))
        assertEquals(focusBorderPlacement(isBorderOverTheWindow: false, windowsAbove: [], windowFrame: window, panel: panel), .below)
        assertEquals(focusBorderPlacement(isBorderOverTheWindow: true, windowsAbove: [], windowFrame: window, panel: panel), .above)
        assertEquals(focusBorderPlacement(isBorderOverTheWindow: true, windowsAbove: [border, elsewhere], windowFrame: window, panel: panel), .above)
        assertEquals(focusBorderPlacement(isBorderOverTheWindow: true, windowsAbove: [border, dialog], windowFrame: window, panel: panel), .below)
    }
}
