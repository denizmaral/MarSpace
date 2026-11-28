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

    /// What a full sweep finds was missed only after scoped sessions, and not after the lock screen
    @Test func testMissedChangesAfterScopedSessionsOnly() {
        let start = ContinuousClock.now
        let late = start + RefreshScope.fullSweepInterval
        var sweeps = FullSweeps()
        assertEquals(sweeps.scope(for: .apps([1]), now: start).scope, .everything) // None yet
        assertEquals(sweeps.scope(for: .apps([1]), now: start).missed, nil)
        sweeps.sessionDidSucceed(.everything, locksAtStart: 0, now: start, isScreenLocked: false)
        assertEquals(sweeps.scope(for: .apps([1]), now: start + .seconds(1)).scope, .apps([1]))
        assertEquals(sweeps.scope(for: .apps([1]), now: late).missed, nil) // No scoped session ran: nothing missed

        sweeps.sessionDidSucceed(.apps([1]), locksAtStart: 0, now: start + .seconds(1), isScreenLocked: false)
        assertEquals(sweeps.scope(for: .apps([1]), now: late).scope, .everything)
        assertEquals(sweeps.scope(for: .apps([1]), now: late).missed, MissedChanges(askedFor: [1], locks: 0))
        assertEquals(sweeps.scope(for: .layout, now: late).missed, MissedChanges(askedFor: [], locks: 0))
        assertEquals(sweeps.scope(for: .everything, now: late).missed, nil) // Asked for every app
    }

    /// The windows come back after the lock screen, the apps don't notify: that wasn't missed
    @Test func testNothingIsMissedAfterTheLockScreen() {
        let start = ContinuousClock.now
        let late = start + RefreshScope.fullSweepInterval
        func scopedThenLate(_ sweeps: FullSweeps) -> MissedChanges? {
            var sweeps = sweeps
            sweeps.sessionDidSucceed(.apps([1]), locksAtStart: sweeps.locks, now: start, isScreenLocked: false)
            return sweeps.scope(for: .apps([1]), now: late).missed
        }
        var unlocked = FullSweeps()
        unlocked.sessionDidSucceed(.everything, locksAtStart: 0, now: start, isScreenLocked: false)
        assertEquals(scopedThenLate(unlocked) != nil, true)

        var activated = unlocked // The lock screen was activated
        activated.screenDidLock()
        assertEquals(scopedThenLate(activated), nil)

        var behind = FullSweeps() // A full sweep ended behind the lock screen
        behind.sessionDidSucceed(.everything, locksAtStart: 0, now: start, isScreenLocked: true)
        assertEquals(scopedThenLate(behind), nil)

        var during = FullSweeps() // Locked during a full sweep, unlocked before its end
        let locksAtStart = during.locks
        during.screenDidLock()
        during.sessionDidSucceed(.everything, locksAtStart: locksAtStart, now: start, isScreenLocked: false)
        assertEquals(scopedThenLate(during), nil)

        var scopedBehind = unlocked // A scoped session behind the lock screen, its activation wasn't seen
        scopedBehind.sessionDidSucceed(.apps([1]), locksAtStart: scopedBehind.locks, now: start, isScreenLocked: true)
        assertEquals(scopedBehind.scope(for: .apps([1]), now: late).missed, nil)

        var next = during // The next full sweep after the unlock is a clean start again
        next.sessionDidSucceed(.everything, locksAtStart: next.locks, now: late, isScreenLocked: false)
        next.sessionDidSucceed(.apps([1]), locksAtStart: next.locks, now: late, isScreenLocked: false)
        assertEquals(next.scope(for: .apps([1]), now: late + RefreshScope.fullSweepInterval).missed, MissedChanges(askedFor: [1], locks: next.locks))
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
