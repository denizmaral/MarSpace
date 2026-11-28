import AppKit
import Common

/// What a complete refresh session asks the apps (see `runHeavyCompleteRefreshSession`). Every app is an IPC round trip
/// that wakes up its main thread: the list of its windows, the native state of each window that is shown (one more). An
/// accessibility notification of one app says that the windows of that app may have changed, not the others: its session
/// asks only that app. A window that answered its size changes only the layout.
///
/// Nothing is missed for long: a session is `everything` when the last one that was is older than
/// ``fullSweepInterval`` (the windows of an app that doesn't notify are seen then, see ``FullSweeps``).
/// The end of a command or a click asks the apps that it touched (see ``afterLightSession(focusBefore:focusAfter:)``,
/// ``afterClick(at:)``). The events that MarSpace doesn't know the app of (the launch of an app, a Space change, the
/// settings) are `everything`
enum RefreshScope: Sendable, Hashable, CustomStringConvertible {
    /// Only the layout may change: a window answered its size (see `RefreshSessionEvent.frameReadBack`)
    case layout
    /// The windows of these apps may have changed: their accessibility notifications
    case apps(Set<pid_t>)
    /// Anything may have changed: every app is asked
    case everything

    /// The scope of a notification of the app with `pid`: everything if the app isn't known (a destroyed element may
    /// not tell it)
    static func app(_ pid: pid_t?) -> RefreshScope {
        pid.map { .apps([$0]) } ?? .everything
    }

    /// A session for both: the events of a burst are one session (see `SessionQueue.scheduleHeavy`)
    func union(_ other: RefreshScope) -> RefreshScope {
        switch (self, other) {
            case (.everything, _), (_, .everything): .everything
            case (.layout, let other), (let other, .layout): other
            case (.apps(let a), .apps(let b)): .apps(a.union(b))
        }
    }

    /// The apps that the session asks, nil: every app. Empty for `layout`
    var pids: Set<pid_t>? {
        switch self {
            case .layout: []
            case .apps(let pids): pids
            case .everything: nil
        }
    }

    /// A session asks every app at least this often while events come: the windows of an app that doesn't notify about
    /// them are seen then
    static let fullSweepInterval: Duration = .seconds(5)

    /// The scope that a session runs with
    /// - Parameter lastFullSweep: when the last `everything` session ended, nil if none did
    func effective(lastFullSweep: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> RefreshScope {
        guard let lastFullSweep, now - lastFullSweep < Self.fullSweepInterval else { return .everything }
        return self
    }

    var description: String {
        switch self {
            case .layout: "layout"
            case .apps(let pids): "apps(\(pids.sorted().map(String.init).joined(separator: ",")))"
            case .everything: "everything"
        }
    }
}

extension RefreshScope {
    /// Whether a complete refresh session reads the native state (fullscreen, minimized) of a window: 2 accessibility
    /// reads (see `normalizeLayoutReason`). A window in a native state, or one that a notification asked for, always.
    /// Otherwise only the windows of the apps of the session, and the ones of workspaces that aren't shown only in the
    /// check every 5 seconds (they rarely change)
    ///
    /// - Parameter checksInvisible: the check of the windows of workspaces that aren't shown is due, in a session that
    ///   asks every app
    static func readsNativeState(
        of windowPid: pid_t,
        in pids: Set<pid_t>?,
        isWorkspaceVisible: Bool,
        checksInvisible: Bool,
        isInNativeState: Bool,
        isCheckRequested: Bool,
    ) -> Bool {
        if isInNativeState || isCheckRequested { return true }
        if let pids, !pids.contains(windowPid) { return false }
        return isWorkspaceVisible || checksInvisible
    }
}

extension RefreshScope {
    /// The complete refresh session after a light session (a command, a hotkey): the apps of the focus before and after
    /// it, and the frontmost app. What the command does to the windows of other apps (moves them, hides them in a corner)
    /// is the layout, it doesn't need their window lists: their notifications ask for them if they change. Every app
    /// if none is known
    ///
    /// - Parameter event: the startup sessions ask every app
    @MainActor
    static func afterLightSession(_ event: RefreshSessionEvent, focusBefore: Window?, focusAfter: Window?) -> RefreshScope {
        if event.isStartup { return .everything }
        return of([focusBefore?.app.pid, focusAfter?.app.pid, RunningApps.frontmost?.pid])
    }

    /// The complete refresh session after a click: the apps of the windows under the mouse (the close button of a window
    /// that isn't focused, a new window that its app opens), and the frontmost app. The window that the click closed is
    /// gone from the screen at the mouse up: the windows under the mouse are also the ones that MarSpace has there (no
    /// accessibility calls)
    /// - Parameter location: of the mouse, in the coordinates of the accessibility API (the origin at the top left)
    @MainActor
    static func afterClick(at location: CGPoint) -> RefreshScope {
        of(windowsOnTheScreen(at: location).map(\.app.pid) + [topmostWindow(at: location)?.pid, RunningApps.frontmost?.pid])
    }

    /// The windows of the workspaces that are shown whose frame (as MarSpace knows it) contains `location`
    @MainActor
    static func windowsOnTheScreen(at location: CGPoint) -> [Window] {
        Workspace.all.filter(\.isVisible).flatMap(\.allLeafWindowsRecursive)
            .filter { $0.observedFrame?.contains(location) == true }
    }

    /// An app was activated: the windows of the app that got the focus, and of the one that had it
    @MainActor
    static func afterActivation(of pid: pid_t?) -> RefreshScope {
        guard let pid else { return .everything }
        let history = RunningApps.frontmostHistory // It may follow the notification or not yet
        return of([pid, history.pid, history.previousPid])
    }

    /// The apps that are known among §pids§, every app if none is
    static func of(_ pids: [pid_t?]) -> RefreshScope {
        let known = Set(pids.compactMap(\.self))
        return known.isEmpty ? .everything : .apps(known)
    }
}

/// The complete refresh sessions that asked every app (full sweeps). A session that was asked for some apps asks every
/// app when the last full sweep is too long ago (see `RefreshScope.effective(lastFullSweep:now:)`). What it finds of the
/// other apps wasn't notified by them: it would have been missed without the full sweep, it's reported (see
/// `MissedChanges`). Unless the screen was locked (see `ScreenLock`) since the last full sweep started: the windows
/// come back after the unlock, and the apps don't notify about it
struct FullSweeps: Sendable {
    /// When the last full sweep ended, nil if none did
    private var last: ContinuousClock.Instant? = nil
    /// The lock epoch of the last full sweep, nil if the screen was locked during it, or none ran
    private var cleanEpoch: UInt64? = nil

    /// A session begins: its scope, and whether it reports what it finds of the apps that it wasn't asked for
    func begin(_ requested: RefreshScope, now: ContinuousClock.Instant, lock: LockPeriods.Snapshot) -> SessionPlan {
        let scope = requested.effective(lastFullSweep: last, now: now)
        let check: MissedCheck = switch requested.pids {
            case _ where scope == requested: .off(.notWidened)
            case nil: .off(.notWidened)
            case _ where cleanEpoch == nil: .off(.noCleanSweep)
            case _ where lock.isLocked || cleanEpoch != lock.epoch: .off(.screenLocked)
            case let askedFor?: .on(askedFor: askedFor)
        }
        return SessionPlan(scope: scope, check: check, lockAtStart: lock)
    }

    /// The session ended without being canceled: whether its notices are reported (see `MissedChanges.report(_:)`)
    mutating func end(_ plan: SessionPlan, now: ContinuousClock.Instant, lock: LockPeriods.Snapshot) -> MissedCheck {
        let isClean = !plan.lockAtStart.isLocked && !lock.isLocked && plan.lockAtStart.epoch == lock.epoch
        if plan.scope == .everything {
            last = now
            cleanEpoch = isClean ? lock.epoch : nil
        }
        if case .on = plan.check, !isClean { return .off(.screenLocked) }
        return plan.check
    }
}

/// What a complete refresh session runs with (see `FullSweeps.begin(_:now:lock:)`)
struct SessionPlan: Sendable, Equatable {
    let scope: RefreshScope
    let check: MissedCheck
    let lockAtStart: LockPeriods.Snapshot
}

/// Whether a complete refresh session reports the changes of the apps that it wasn't asked for (see `FullSweeps`)
enum MissedCheck: Sendable, Equatable, CustomStringConvertible {
    case on(askedFor: Set<pid_t>)
    case off(Reason)

    enum Reason: Sendable, Equatable {
        /// The session asks what it was asked for: nothing beyond it
        case notWidened
        /// No full sweep that wasn't behind a lock to compare with
        case noCleanSweep
        /// The screen was locked since the last full sweep started, or during the session
        case screenLocked
    }

    var description: String {
        switch self {
            case .on: "on"
            case .off(.notWidened): "off"
            case .off(.noCleanSweep): "off(noCleanSweep)"
            case .off(.screenLocked): "off(screenLocked)"
        }
    }
}

/// The changes that a complete refresh session finds of the apps that it wasn't asked for (see `FullSweeps`). Collected
/// during the session, decided once when it ends: the lock may come during it
@MainActor
final class MissedChanges {
    private let check: MissedCheck
    private(set) var notices: [String] = []

    init(_ check: MissedCheck) { self.check = check }

    /// A change of the app with `pid`
    func note(_ pid: pid_t, _ change: @autoclosure () -> String) {
        guard case .on(let askedFor) = check, !askedFor.contains(pid) else { return }
        notices.append("\(change()) of \(MacApp.allAppsMap[pid]?.name ?? "\(pid)")")
    }

    /// The session ended: logged as notices (kept) if `final` is on, the events of those apps need a look. Counted on the
    /// perf line of the session either way
    func report(_ final: MissedCheck) {
        AxStats.session?.recordMissedCheck(final, notices: notices.count)
        guard case .on = final else { return }
        for notice in notices {
            perfLogger.notice("missed by the scoped refresh sessions: \(notice, privacy: .public)")
        }
    }
}
