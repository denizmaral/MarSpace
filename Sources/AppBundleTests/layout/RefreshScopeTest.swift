@testable import AppBundle
import AppKit
import Testing

/// What a complete refresh session asks the apps, see RefreshScope
@MainActor
@Suite(.serializedGlobally)
struct RefreshScopeTest {
    init() { setUpWorkspacesForTests() }

    @Test func testUnion() {
        assertEquals(RefreshScope.layout.union(.layout), .layout)
        assertEquals(RefreshScope.layout.union(.apps([1])), .apps([1]))
        assertEquals(RefreshScope.apps([1]).union(.apps([2])), .apps([1, 2]))
        assertEquals(RefreshScope.apps([1]).union(.everything), .everything)
        assertEquals(RefreshScope.everything.union(.layout), .everything)
    }

    @Test func testAnUnknownAppIsEverything() {
        assertEquals(RefreshScope.app(nil), .everything)
        assertEquals(RefreshScope.app(7), .apps([7]))
    }

    /// A session asks every app when the last one that did is older than the interval, or there was none
    @Test func testEveryAppIsAskedAtLeastEveryInterval() {
        let now = ContinuousClock.now
        assertEquals(RefreshScope.apps([1]).effective(lastFullSweep: nil, now: now), .everything)
        assertEquals(RefreshScope.apps([1]).effective(lastFullSweep: now - .seconds(1), now: now), .apps([1]))
        assertEquals(RefreshScope.layout.effective(lastFullSweep: now - .seconds(1), now: now), .layout)
        assertEquals(RefreshScope.layout.effective(lastFullSweep: now - RefreshScope.fullSweepInterval, now: now), .everything)
    }

    @Test func testNativeStatesThatAreRead() {
        func reads(_ pid: pid_t, in pids: Set<pid_t>?, visible: Bool = true, checksInvisible: Bool = false, inNativeState: Bool = false, requested: Bool = false) -> Bool {
            RefreshScope.readsNativeState(of: pid, in: pids, isWorkspaceVisible: visible, checksInvisible: checksInvisible, isInNativeState: inNativeState, isCheckRequested: requested)
        }
        assertEquals(reads(1, in: nil), true) // Every app: the windows that are shown
        assertEquals(reads(1, in: nil, visible: false), false) // Not shown: every 5 seconds
        assertEquals(reads(1, in: nil, visible: false, checksInvisible: true), true)
        assertEquals(reads(1, in: [1]), true) // The app of the session
        assertEquals(reads(2, in: [1]), false) // Another app
        assertEquals(reads(2, in: [1], inNativeState: true), true) // It can leave the native state
        assertEquals(reads(2, in: [], requested: true), true) // A notification asked for it
    }

    /// A window that answers its size changes only the layout
    @Test func testReadBackAsksForTheLayoutOnly() async throws {
        let workspace = Workspace.get(byName: "RefreshScopeTest")
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(completeRefreshSessionsAskedForInTests.count { if case .frameReadBack = $0 { true } else { false } } > 0, true)
        assertEquals(Set(completeRefreshScopesAskedForInTests), [.layout])
    }

    /// The session after a command asks the apps of the focus before and after it, and the frontmost one. The startup
    /// asks every app
    @Test func testAfterACommandTheAppsOfTheFocusAreAsked() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "RefreshScopeTest").rootTilingContainer)
        let scope = RefreshScope.afterLightSession(.hotkeyBinding, focusBefore: nil, focusAfter: window)
        guard case .apps(let pids) = scope else { Issue.record("\(scope)"); return }
        assertEquals(pids.contains(TestApp.shared.pid), true)
        if let frontmost = RunningApps.frontmost?.pid { assertEquals(pids.contains(frontmost), true) }
        assertEquals(RefreshScope.afterLightSession(.startup, focusBefore: window, focusAfter: window), .everything)
    }

    /// The apps that are known, every app if none is
    @Test func testTheKnownAppsAreAsked() {
        assertEquals(RefreshScope.of([1, nil, 2, 1]), .apps([1, 2]))
        assertEquals(RefreshScope.of([nil, nil]), .everything)
    }

    /// The window that a click closed isn't on the screen anymore at the mouse up: MarSpace still has it there, its app
    /// is asked
    @Test func testAfterAClickTheAppsOfTheWindowsUnderTheMouseAreAsked() async throws {
        let workspace = Workspace.get(byName: "RefreshScopeTest")
        #expect(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let frame = try #require(window.observedFrame)
        let inside = CGPoint(x: frame.topLeftX + 5, y: frame.topLeftY + 5)
        assertEquals(RefreshScope.windowsOnTheScreen(at: inside).map(\.windowId), [1])
        guard case .apps(let pids) = RefreshScope.afterClick(at: inside) else { Issue.record("not apps"); return }
        assertEquals(pids.contains(TestApp.shared.pid), true)
        assertEquals(RefreshScope.windowsOnTheScreen(at: CGPoint(x: -100, y: -100)).isEmpty, true)
    }

    /// The session after an activation asks the app that got the focus
    @Test func testAfterAnActivationTheActivatedAppIsAsked() {
        assertEquals(RefreshScope.afterActivation(of: nil), .everything)
        guard case .apps(let pids) = RefreshScope.afterActivation(of: 12345) else { Issue.record("not apps"); return }
        assertEquals(pids.contains(12345), true)
        let history = RunningApps.frontmostHistory
        for pid in [history.pid, history.previousPid].compactMap(\.self) { assertEquals(pids.contains(pid), true) }
    }
}
