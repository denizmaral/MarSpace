import AppKit
import Common

/// What a complete refresh session asks the apps (see `runHeavyCompleteRefreshSession`). Every app is an IPC round trip
/// that wakes up its main thread: the list of its windows, the native state of each window that is shown (2 reads). An
/// accessibility notification of one app says that the windows of that app may have changed, not the others: its session
/// asks only that app. A window that answered its size changes only the layout.
///
/// Nothing is missed for long: a session is `everything` when the last one that was is older than
/// ``fullSweepInterval`` (the windows of an app that doesn't notify are seen then, see `RefreshScope.logMissedChanges`).
/// The events that MarSpace doesn't know the app of (NSWorkspace, the mouse, the settings, the end of a command) are
/// `everything` too
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
