@testable import AppBundle
import Common
import Testing

/// What the monitors show
@MainActor
@Suite(.serializedGlobally)
struct MonitorSpacesTest {
    init() { setUpWorkspacesForTests() }

    /// The focused window goes to macOS fullscreen and back, the focus stays: the monitor of the focus shows what it shows
    @Test func testTheFocusedWindowEntersAndLeavesMacosFullscreen() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        #expect(window.focusWindow())
        assertEquals(mainMonitorInfo.space, .desktop)

        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        assertEquals(mainMonitorInfo.space, .macosFullscreen(of: workspace))

        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        assertEquals(mainMonitorInfo.space, .desktop)
    }

    /// What the monitor showed when the focus left it lasts until MarSpace shows another workspace there
    @Test func testAnotherWorkspaceIsShown() {
        let container = mainMonitorInfo.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate()
        container.spaceWhenTheFocusLeft = .macosFullscreen(of: Workspace.get(byName: "B"))
        #expect(Workspace.get(byName: "C").focusWorkspace())
        assertEquals(container.spaceWhenTheFocusLeft, .desktop)
    }
}
