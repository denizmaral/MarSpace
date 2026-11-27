@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// Which monitors show the Space of a window in macOS fullscreen, by the focus
@MainActor
@Suite(.serializedGlobally)
struct MacosFullscreenSpacesTest {
    private let left = CGPoint(x: 0, y: 0)
    private let right = CGPoint(x: 1920, y: 0)

    @Test func testTheFocusGoesToAnotherMonitor() {
        var spaces = MacosFullscreenSpaces()
        spaces.focusChanged(to: "B", monitor: left, isMacosFullscreen: true, visibleWorkspaces: [left: "B", right: "2"])
        #expect(spaces.isShown("B"))
        // The Space of the fullscreen window is still shown on the left monitor
        spaces.focusChanged(to: "2", monitor: right, isMacosFullscreen: false, visibleWorkspaces: [left: "B", right: "2"])
        #expect(spaces.isShown("B"))
        #expect(!spaces.isShown("2"))
    }

    @Test func testTheDesktopOfTheMonitorIsShownAgain() {
        var spaces = MacosFullscreenSpaces()
        spaces.focusChanged(to: "B", monitor: left, isMacosFullscreen: true, visibleWorkspaces: [left: "B"])
        spaces.focusChanged(to: "B", monitor: left, isMacosFullscreen: false, visibleWorkspaces: [left: "B"]) // A window of B
        #expect(!spaces.isShown("B"))

        spaces.focusChanged(to: "B", monitor: left, isMacosFullscreen: true, visibleWorkspaces: [left: "B", right: "2"])
        spaces.focusChanged(to: "2", monitor: right, isMacosFullscreen: false, visibleWorkspaces: [left: "T", right: "2"]) // T shown
        #expect(!spaces.isShown("B"))
    }
}
