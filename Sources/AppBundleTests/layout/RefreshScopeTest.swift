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

    /// A period begins when the window server goes blind: the epoch changes once for it
    @Test func testTheLockPeriodsAreCounted() {
        var periods = LockPeriods()
        assertEquals(periods.observe(isBlind: false), LockPeriods.Snapshot(epoch: 0, isBlind: false))
        assertEquals(periods.observe(isBlind: true), LockPeriods.Snapshot(epoch: 1, isBlind: true))
        assertEquals(periods.observe(isBlind: true), LockPeriods.Snapshot(epoch: 1, isBlind: true)) // The same period
        assertEquals(periods.observe(isBlind: false), LockPeriods.Snapshot(epoch: 1, isBlind: false))
        assertEquals(periods.observe(isBlind: true), LockPeriods.Snapshot(epoch: 2, isBlind: true))
    }

    /// The notifications start a period; the ones of the unlock and the wake read the window server: awake isn't unlocked
    @Test func testTheNotificationsOfTheLockAndTheWake() {
        var isBlind = false
        let lock = ScreenLock(readsWindowServer: { isBlind })
        assertEquals(lock.observeNow(), LockPeriods.Snapshot(epoch: 0, isBlind: false))
        lock.handle(.blind) // The displays sleep: the window server would say so as well
        isBlind = true
        lock.handle(.mayBeBack) // Awake, still locked
        assertEquals(lock.observeNow(), LockPeriods.Snapshot(epoch: 1, isBlind: true))
        isBlind = false
        lock.handle(.mayBeBack) // Unlocked
        assertEquals(lock.observeNow(), LockPeriods.Snapshot(epoch: 1, isBlind: false))
        lock.handle(.blind) // A lock between two sessions that read nothing in between: still a period
        lock.handle(.mayBeBack)
        assertEquals(lock.observeNow(), LockPeriods.Snapshot(epoch: 2, isBlind: false))
    }

    /// A session that asks every app because the last full sweep is too long ago reports what it finds of the other
    /// apps, also when no other session ran since: they didn't notify. Only full sweeps read the lock state
    @Test func testAWidenedSessionReportsTheOtherApps() {
        let start = ContinuousClock.now
        let late = start + RefreshScope.fullSweepInterval
        let unlocked = LockPeriods.Snapshot(epoch: 0, isBlind: false)
        var reads = 0
        let lock = { reads += 1; return unlocked }
        var sweeps = FullSweeps()
        let first = sweeps.begin(.apps([1]), now: start, lock: lock)
        assertEquals(first, .fullSweep(widenedFrom: [1], check: .off(.noCleanSweep), lockAtStart: unlocked)) // Nothing to compare with
        assertEquals(sweeps.end(first, now: start, lock: lock), .off(.noCleanSweep))
        assertEquals(reads, 2)

        let scoped = sweeps.begin(.apps([1]), now: start + .seconds(1), lock: lock)
        assertEquals(scoped, .apps([1]))
        assertEquals(sweeps.end(scoped, now: start + .seconds(1), lock: lock), nil)
        assertEquals(reads, 2) // A scoped session doesn't read it
        assertEquals(sweeps.begin(.everything, now: late, lock: lock), .fullSweep(widenedFrom: nil, check: .off(.notWidened), lockAtStart: unlocked))

        let widened = sweeps.begin(.apps([1]), now: late, lock: lock)
        assertEquals(widened, .fullSweep(widenedFrom: [1], check: .on, lockAtStart: unlocked))
        assertEquals(sweeps.end(widened, now: late, lock: lock), .on)
        assertEquals(sweeps.begin(.layout, now: late + RefreshScope.fullSweepInterval, lock: lock), .fullSweep(widenedFrom: [], check: .on, lockAtStart: unlocked))
    }

    /// The windows come back after the lock, the apps don't notify: nothing is reported
    @Test func testNothingIsReportedAcrossALock() {
        let start = ContinuousClock.now
        let late = start + RefreshScope.fullSweepInterval
        let unlocked = { LockPeriods.Snapshot(epoch: 0, isBlind: false) }
        let locked = { LockPeriods.Snapshot(epoch: 1, isBlind: true) }
        let unlockedAgain = { LockPeriods.Snapshot(epoch: 1, isBlind: false) }
        func check(_ plan: SessionPlan) -> MissedCheck? { if case .fullSweep(_, let check, _) = plan { check } else { nil } }
        var clean = FullSweeps()
        _ = clean.end(clean.begin(.everything, now: start, lock: unlocked), now: start, lock: unlocked)

        // Blind since the last full sweep: at the start of the session, or unlocked again before it
        assertEquals(check(clean.begin(.apps([1]), now: late, lock: locked)), .off(.windowServerBlind))
        assertEquals(check(clean.begin(.apps([1]), now: late, lock: unlockedAgain)), .off(.windowServerBlind))

        // Locked during the session that reports: decided when it ends
        var during = clean
        let plan = during.begin(.apps([1]), now: late, lock: unlocked)
        assertEquals(check(plan), .on)
        assertEquals(during.end(plan, now: late, lock: unlockedAgain), .off(.windowServerBlind))
        // That full sweep saw the lock: no clean one to compare with until the next one
        assertEquals(check(during.begin(.apps([1]), now: late + RefreshScope.fullSweepInterval, lock: unlockedAgain)), .off(.noCleanSweep))

        // A full sweep that started behind the lock and ended after the unlock isn't clean either
        var behind = FullSweeps()
        _ = behind.end(behind.begin(.everything, now: start, lock: locked), now: start, lock: unlockedAgain)
        assertEquals(check(behind.begin(.apps([1]), now: late, lock: unlockedAgain)), .off(.noCleanSweep))

        // The next full sweep after the unlock is clean again
        _ = behind.end(behind.begin(.everything, now: late, lock: unlockedAgain), now: late, lock: unlockedAgain)
        assertEquals(check(behind.begin(.apps([1]), now: late + RefreshScope.fullSweepInterval, lock: unlockedAgain)), .on)
    }

    /// A widened full sweep collects the changes of the apps that it wasn't asked for whatever the check: logged if the
    /// end decides so, counted on the perf line of the session either way
    @Test func testTheMissedChangesAreCollectedAndCounted() {
        let unlocked = LockPeriods.Snapshot(epoch: 0, isBlind: false)
        let widened = MissedChanges(.fullSweep(widenedFrom: [1], check: .off(.windowServerBlind), lockAtStart: unlocked))
        widened.note(1, "window 1 appeared")
        widened.note(2, "window 2 appeared")
        assertEquals(widened.notices, ["window 2 appeared of 2"])
        let cost = SessionAxCost("test")
        widened.report(.off(.windowServerBlind), to: cost) // Outside of the task of the session too
        assertEquals(cost.missedCheck?.check, .off(.windowServerBlind))
        assertEquals(cost.missedCheck?.notices, 1)

        let scoped = MissedChanges.notCollected
        scoped.note(2, "window 2 appeared")
        assertEquals(scoped.notices, [])
        let scopedCost = SessionAxCost("test")
        scoped.report(nil, to: scopedCost)
        assertEquals(scopedCost.missedCheck == nil, true)
        assertEquals(MissedChanges(.fullSweep(widenedFrom: nil, check: .off(.notWidened), lockAtStart: unlocked)).notices, [])
    }

    /// The fields of the perf line of a full sweep
    @Test func testThePerfLineOfTheMissedCheck() {
        assertEquals(SessionAxCost.missedCheckFields((.on, 2)), " missedCheck=on missed=2")
        assertEquals(SessionAxCost.missedCheckFields((.off(.windowServerBlind), 8)), " missedCheck=off(windowServerBlind) missedSuppressed=8")
        assertEquals(SessionAxCost.missedCheckFields((.off(.notWidened), 0)), " missedCheck=off(notWidened) missedSuppressed=0")
        assertEquals(SessionAxCost.missedCheckFields(nil), "")
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
