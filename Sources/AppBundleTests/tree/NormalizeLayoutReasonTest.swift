@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct NormalizeLayoutReasonTest {
    init() { setUpWorkspacesForTests() }

    /// A round trip per window per refresh session is saved for windows of invisible workspaces
    @Test func testWindowsOfInvisibleWorkspacesAreCheckedAtMostEvery5Seconds() async throws {
        let workspace = Workspace.get(byName: "invisible")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.isMacosFullscreenForTest = true
        #expect(!workspace.isVisible)

        lastInvisibleWindowsNativeStateCheck = .now // They were checked just now
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        assertEquals(window.layoutReason, .standard)

        lastInvisibleWindowsNativeStateCheck = .now - .seconds(6)
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        assertEquals(window.layoutReason, .macos(prevParentKind: .tilingContainer))
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
    }

    /// E.g. "Minimize All": AX notifies about the native state change of a window of an invisible workspace. The window
    /// must be handled before the workspace is shown (otherwise it gets a tile and leaves a hole)
    @Test func testNotifiedWindowOfInvisibleWorkspaceIsCheckedRightAway() async throws {
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let workspace = Workspace.get(byName: "invisible")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        lastInvisibleWindowsNativeStateCheck = .now // The periodic check was just now

        window.isMacosFullscreenForTest = true
        window.isNativeStateCheckRequested = true // refreshObs: kAXWindowMiniaturizedNotification etc.
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(window.isNativeStateCheckRequested, false)

        #expect(workspace.focusWorkspace())
        try await workspace.layoutWorkspace()
        assertEquals(window2.sentFrames.last?.size?.width, 1920)
    }

    /// A notification during the AX reads requests a new check. The running check must not clear it
    @Test func testNotificationDuringTheCheckIsKept() async throws {
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "invisible").rootTilingContainer)
        lastInvisibleWindowsNativeStateCheck = .now
        window.isNativeStateCheckRequested = true
        window.onNativeStateReadForTest = { window.isNativeStateCheckRequested = true } // E.g. kAXWindowMiniaturizedNotification
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        assertEquals(window.isNativeStateCheckRequested, true)
    }

    /// The session is canceled during the AX reads (e.g. by a newer event). The requested check must not be lost
    @Test func testCanceledCheckKeepsTheRequest() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "invisible").rootTilingContainer)
        lastInvisibleWindowsNativeStateCheck = .now
        window.isNativeStateCheckRequested = true
        window.onNativeStateReadForTest = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything))) }
        assertEquals(window.isNativeStateCheckRequested, true)
    }

    /// Bursts of events cancel sessions all the time. The periodic check of invisible windows must not be postponed
    /// until the burst ends (notified windows are checked anyway)
    @Test func testPeriodicCheckIsRecordedEvenIfTheSessionIsCanceled() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "invisible").rootTilingContainer)
        let start = ContinuousClock.now
        lastInvisibleWindowsNativeStateCheck = start - .seconds(6)
        window.onNativeStateReadForTest = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything))) }
        #expect(try #require(lastInvisibleWindowsNativeStateCheck) >= start)
    }

    /// The closed windows cache is restored after a window went native fullscreen (MarSpace was turned off, a window of
    /// the cache came back): the restore binds the window into its old tile, still marked as away in the native state.
    /// The window must leave the tile again. Brave stayed a tile in its fullscreen Space, the focus border drawn over it
    @Test func testAWindowThatARestoredLayoutPutIntoATileGoesBackToItsNativeState() async throws {
        resetClosedWindowsCache()
        defer { resetClosedWindowsCache() }
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let fullscreen = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let reappearing = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        cacheClosedWindowIfNeeded() // A window closed: the layout of all windows is cached

        fullscreen.isMacosFullscreenForTest = true
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        #expect(fullscreen.parent === workspace.macOsNativeFullscreenWindowsContainer)

        #expect(try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: reappearing))
        #expect(fullscreen.parent is TilingContainer) // The cached layout

        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        #expect(fullscreen.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))

        fullscreen.isMacosFullscreenForTest = false // Back to the tile it was put into
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(fullscreen.layoutReason, .standard)
    }

    /// The same for a window that is no longer in the native state: it stays where the restore put it
    @Test func testAWindowThatARestoredLayoutPutIntoATileStaysThere() async throws {
        resetClosedWindowsCache()
        defer { resetClosedWindowsCache() }
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let reappearing = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        cacheClosedWindowIfNeeded()
        window.isMacosFullscreenForTest = true
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        #expect(try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: reappearing))

        window.isMacosFullscreenForTest = false
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(window.layoutReason, .standard)
    }

    @Test func testWindowsOfVisibleWorkspacesAreAlwaysChecked() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.isMacosFullscreenForTest = true

        lastInvisibleWindowsNativeStateCheck = .now
        try await normalizeLayoutReason(missed: MissedChanges(.scoped(.everything)))
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
    }

    /// A session of other apps (see RefreshScope) doesn't read the windows that are shown, only a window that a
    /// notification asked for. The app of the session is read
    @Test func testScopedSessionReadsOnlyItsAppsAndTheRequestedWindows() async throws {
        let workspace = Workspace.get(byName: "shown")
        #expect(workspace.focusWorkspace())
        let other = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let requested = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        var reads: [OpaqueWindowId] = []
        for window in [other, requested] {
            window.isMacosFullscreenForTest = true
            window.onNativeStateReadForTest = { reads.append(window.windowId) }
        }
        requested.isNativeStateCheckRequested = true
        let anotherApp = TestApp.shared.pid + 1

        try await normalizeLayoutReason([anotherApp], missed: MissedChanges(.scoped(.apps([anotherApp]))))
        assertEquals(reads, [2])
        assertEquals(other.layoutReason, .standard)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))

        other.onNativeStateReadForTest = { reads.append(other.windowId) }
        try await normalizeLayoutReason([TestApp.shared.pid], missed: MissedChanges(.scoped(.apps([TestApp.shared.pid]))))
        assertEquals(other.layoutReason, .macos(prevParentKind: .tilingContainer))
    }

    /// A scoped session that is canceled during the reads keeps the request, and doesn't check the windows of workspaces
    /// that aren't shown, nor take their turn
    @Test func testCanceledScopedSessionKeepsTheRequest() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "invisible").rootTilingContainer)
        let before = ContinuousClock.now - .seconds(10)
        lastInvisibleWindowsNativeStateCheck = before
        window.isNativeStateCheckRequested = true
        window.onNativeStateReadForTest = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await normalizeLayoutReason([], missed: MissedChanges(.scoped(.layout))) }
        assertEquals(window.isNativeStateCheckRequested, true)
        assertEquals(lastInvisibleWindowsNativeStateCheck, before)
    }
}
