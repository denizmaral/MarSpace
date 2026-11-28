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
/// `MissedChanges`). Unless the window server was blind (see `WindowServerBlindness`) since the last full sweep started, or during
/// the session: the windows come back after the unlock, and the apps don't notify about it.
///
/// The blind state is read only by full sweeps: the scoped sessions decide nothing with it
struct FullSweeps: Sendable {
    /// When the last full sweep ended, nil if none did
    private var last: ContinuousClock.Instant? = nil
    /// The lock epoch of the last full sweep, nil if the window server was blind during it, or none ran
    private var cleanEpoch: UInt64? = nil

    /// A session begins: its scope, and for a full sweep whether it reports what it finds of the apps that it wasn't
    /// asked for
    /// - Parameter blindness: reads the blind state (see `WindowServerBlindness.observeNow()`)
    func begin(_ requested: RefreshScope, now: ContinuousClock.Instant, blindness: () -> BlindPeriods.Snapshot) -> SessionPlan {
        let scope = requested.effective(lastFullSweep: last, now: now)
        switch scope {
            case .layout: return .layout
            case .apps(let pids): return .apps(pids)
            case .everything: break
        }
        let blind = blindness()
        guard scope != requested, let askedFor = requested.pids else {
            return .fullSweep(widenedFrom: nil, check: .off(.notWidened), blindAtStart: blind)
        }
        let check: MissedCheck = if cleanEpoch == nil {
            .off(.noCleanSweep)
        } else if blind.isBlind || cleanEpoch != blind.epoch {
            .off(.windowServerBlind)
        } else {
            .on
        }
        return .fullSweep(widenedFrom: askedFor, check: check, blindAtStart: blind)
    }

    /// The session ended without being canceled. A full sweep: whether its notices are reported (see
    /// `MissedChanges.report(_:to:)`). nil: a scoped session
    mutating func end(_ plan: SessionPlan, now: ContinuousClock.Instant, blindness: () -> BlindPeriods.Snapshot) -> MissedCheck? {
        guard case .fullSweep(_, let check, let blindAtStart) = plan else { return nil }
        let blind = blindness()
        let isClean = !blindAtStart.isBlind && !blind.isBlind && blindAtStart.epoch == blind.epoch
        last = now
        cleanEpoch = isClean ? blind.epoch : nil
        if check == .on && !isClean { return .off(.windowServerBlind) }
        return check
    }
}

/// What a complete refresh session runs with (see `FullSweeps.begin(_:now:blindness:)`)
enum SessionPlan: Sendable, Equatable {
    /// The layout only: the last full sweep is recent
    case layout
    /// These apps: the last full sweep is recent
    case apps(Set<pid_t>)
    /// Every app
    /// - widenedFrom: the apps that the session was asked for, nil if every app
    /// - blindAtStart: the blind state when it began
    case fullSweep(widenedFrom: Set<pid_t>?, check: MissedCheck, blindAtStart: BlindPeriods.Snapshot)

    var scope: RefreshScope {
        switch self {
            case .layout: .layout
            case .apps(let pids): .apps(pids)
            case .fullSweep: .everything
        }
    }
}

/// Whether a full sweep reports the changes of the apps that it wasn't asked for (see `FullSweeps`)
enum MissedCheck: Sendable, Equatable, CustomStringConvertible {
    case on
    case off(Reason)

    enum Reason: String, Sendable, Equatable {
        /// Asked for every app: it finds nothing beyond what it was asked for
        case notWidened
        /// No full sweep that the window server wasn't blind during, to compare with
        case noCleanSweep
        /// The window server was blind since the last full sweep started, or during the session
        case windowServerBlind
    }

    var description: String {
        switch self {
            case .on: "on"
            case .off(let reason): "off(\(reason.rawValue))"
        }
    }
}

/// The changes that a full sweep finds of the apps that it wasn't asked for (see `FullSweeps`). Collected during the
/// session whatever the check, decided once when it ends: the lock may come during it, and the suppressed ones are
/// counted
@MainActor
final class MissedChanges {
    /// The apps that the session was asked for, nil: it collects nothing (a scoped session, a full sweep asked for every
    /// app)
    private let askedFor: Set<pid_t>?
    private(set) var notices: [String] = []

    /// Outside of a complete refresh session (the tests): nothing is collected
    static var notCollected: MissedChanges { MissedChanges(askedFor: nil) }

    convenience init(_ plan: SessionPlan) {
        let askedFor: Set<pid_t>? = if case .fullSweep(let widenedFrom?, _, _) = plan { widenedFrom } else { nil }
        self.init(askedFor: askedFor)
    }

    private init(askedFor: Set<pid_t>?) { self.askedFor = askedFor }

    /// A change of the app with `pid`
    func note(_ pid: pid_t, _ change: @autoclosure () -> String) {
        guard let askedFor, !askedFor.contains(pid) else { return }
        notices.append("\(change()) of \(MacApp.allAppsMap[pid]?.name ?? "\(pid)")")
    }

    /// The session ended: logged as notices (kept) if `final` is on, the events of those apps need a look. A full sweep
    /// counts them on its perf line either way
    /// - Parameter final: see `FullSweeps.end(_:now:blindness:)`, nil for a scoped session
    func report(_ final: MissedCheck?, to cost: SessionAxCost) {
        guard let final else { return }
        cost.recordMissedCheck(final, notices: notices.count)
        guard final == .on else { return }
        for notice in notices {
            perfLogger.notice("missed by the scoped refresh sessions: \(notice, privacy: .public)")
        }
    }
}
