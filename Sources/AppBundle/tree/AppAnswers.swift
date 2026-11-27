import Common

/// Whether an app answers the requests that the sessions wait for in time (`deadline`). An app that misses it is
/// degraded: a hung or very busy app doesn't hold up the sessions. It isn't asked, and the answers are what MarSpace
/// knows without asking (the fallbacks of ``answer(_:orElse:_:)``), until it answers a probe again
@MainActor
final class AppAnswers {
    let deadline: Duration
    /// The app missed the deadline and hasn't answered since: it isn't asked, and isn't waited for
    private(set) var isDegraded = false
    /// Counts the recoveries: a request that was asked before the app answered again and misses its deadline after it
    /// doesn't degrade the app again (it doesn't rely on the order in which the main actor runs the two)
    private var recoveries = 0
    private let appName: () -> String
    /// Sent once when the app misses the deadline: tells when the app answers again, with ``didAnswerAgain()``
    private let probe: () -> Void
    /// The app answers again: e.g. its windows are refreshed
    private let didRecover: () -> Void

    init(deadline: Duration, appName: @escaping () -> String, probe: @escaping () -> Void, didRecover: @escaping () -> Void) {
        self.deadline = deadline
        self.appName = appName
        self.probe = probe
        self.didRecover = didRecover
    }

    /// The answer to `request` within `deadline`, else `fallback`, also while the app is degraded
    ///
    /// No deadline in the startup session (the apps that launch with the login are slow, and their windows find their
    /// places of the previous run only while it runs), and for requests that can't be canceled
    func answer<T: Sendable>(
        _ cm: CancellationMode,
        orElse fallback: () -> T,
        _ request: @escaping @MainActor @Sendable () async throws -> T,
    ) async throws -> T {
        if isDegraded { return fallback() }
        if cm == .nonCancellable || isStartup { return try await request() }
        let recoveriesBefore = recoveries
        switch try await withDeadline(deadline, request) {
            case .answered(let value): return value
            case .deadlinePassed:
                if recoveries == recoveriesBefore { didMissDeadline() }
                return fallback()
        }
    }

    private func didMissDeadline() {
        if isDegraded { return }
        isDegraded = true
        perfLogger.error("\(self.appName(), privacy: .public) doesn't answer within \(String(describing: self.deadline), privacy: .public): the sessions go on without it until it answers")
        // Not a part of the session that missed the deadline: the session is logged when it's over, not when the app
        // answers again (see SessionAxCost), and the probe doesn't count towards it
        AxStats.$session.withValue(nil) { $refreshSessionEvent.withValue(nil) { probe() } }
    }

    func didAnswerAgain() {
        guard isDegraded else { return }
        isDegraded = false
        recoveries += 1
        perfLogger.info("\(self.appName(), privacy: .public) answers again")
        didRecover()
    }
}
