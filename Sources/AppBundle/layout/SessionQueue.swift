import Common

/// The sessions that change the model run one at a time: a light session (a command, a hotkey, a click) or a complete
/// refresh session ("heavy"). Before, they interleaved at every `await`: a session could see the half-applied change
/// of another one, and two layouts could be under way at once
///
/// - A session holds the queue in its own task: it keeps its task-locals, and its task can cancel it (a newer mouse
///   move drops the session of the previous one)
/// - Light sessions wait in their order, before a heavy one that waits. A light session that comes while a heavy one runs
///   cancels it (a canceled wait for an app returns right away), the heavy one runs again after it
/// - Heavy sessions are asked for with an event (see ``scheduleHeavy(_:scope:optimisticallyPreLayoutWorkspaces:)``): one at
///   a time. A burst of events is one session, `debounce` after the last event, but not later than `maxWait` after the
///   first one (a window that keeps moving doesn't hold it off forever). The events that come while it runs don't cancel
///   it: one more session follows, with the last event
/// - A session in a session (e.g. a command that runs another one) runs right away, in the one that holds the queue
/// - Read-only sessions (queries) don't use it: status bars poll them
///
/// Every session reports how long it waited and how many sessions were ahead of it (see SessionAxCost); a wait longer
/// than `slowWait` is logged as an error, with the session that held the queue
@MainActor
final class SessionQueue {
    static let shared = SessionQueue(debounce: .milliseconds(16), maxWait: .milliseconds(100)) { event, preLayout, scope in
        await runHeavyCompleteRefreshSession(event, scope: scope, assumeCancellable: true, optimisticallyPreLayoutWorkspaces: preLayout)
    }

    enum Kind: Sendable {
        case light
        /// Can be canceled by a light session
        case heavy
        /// The startup sessions: not canceled
        case startup
    }

    /// What a session knows about its wait in the queue, for the perf log (see SessionAxCost)
    struct Wait: Sendable {
        let queued: Duration
        /// The sessions ahead of it when it asked: the one that held the queue and the ones that waited
        let depth: Int
        /// Heavy: the events that this session stands for
        var coalesced: Int? = nil
        /// Heavy: it runs because events came while the previous one ran, or because a light session canceled it
        var isRerun: Bool? = nil
    }

    /// The holder of the queue in this task, see ``exclusively(_:_:_:)``
    @TaskLocal nonisolated static var holderId: UInt64? = nil
    /// For the perf log of the session that holds the queue
    @TaskLocal nonisolated static var wait: Wait? = nil

    private let debounce: Duration
    private let maxWait: Duration
    private let slowWait: Duration
    private let runHeavy: @MainActor (RefreshSessionEvent, Bool, RefreshScope) async -> Void

    private struct Holder {
        let id: UInt64
        let kind: Kind
        let name: String
    }
    private struct Waiter {
        let id: UInt64
        let kind: Kind
        let name: String
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var holder: Holder? = nil
    private var waiters: [Waiter] = []
    private var nextId: UInt64 = 0
    /// How often a session ran in the one that held the queue, see ``exclusively(_:_:_:)``
    private(set) var nestedRuns = 0
    /// The sessions that wait for the queue
    var waitingCount: Int { waiters.count }

    private struct HeavyRequest {
        var event: RefreshSessionEvent
        var preLayout: Bool
        /// Of all the events that it stands for (see RefreshScope)
        var scope: RefreshScope
        var coalesced: Int
        let firstAskedAt: ContinuousClock.Instant
        var isRerun: Bool
    }
    /// The next heavy session: in its debounce, or waiting for the queue
    private var pendingHeavy: HeavyRequest? = nil
    private var heavyTimer: Task<(), Never>? = nil
    /// The task of the heavy session: waiting for the queue, or running
    private var heavyTask: Task<(), Never>? = nil
    private var runningHeavy: HeavyRequest? = nil
    private var isRunningHeavyPreempted = false

    init(
        debounce: Duration,
        maxWait: Duration,
        slowWait: Duration = MacApp.answerDeadline,
        runHeavy: @escaping @MainActor (RefreshSessionEvent, Bool, RefreshScope) async -> Void,
    ) {
        self.debounce = debounce
        self.maxWait = maxWait
        self.slowWait = slowWait
        self.runHeavy = runHeavy
    }

    // MARK: Holding the queue

    /// `body` while this session holds the queue. Throws `CancellationError` if the task is canceled while it waits:
    /// the body doesn't run then
    func exclusively<T>(_ kind: Kind, _ name: String, _ body: @MainActor () async throws -> T) async throws -> T {
        if let id = Self.holderId, id == holder?.id { // In the session that holds the queue: it would wait for itself
            nestedRuns += 1
            perfLogger.debug("session=\(name, privacy: .public) runs in the session that holds the queue (\(self.nestedRuns) so far)")
            return try await body()
        }
        try checkCancellation()
        let askedAt = ContinuousClock.now
        let depth = (holder == nil ? 0 : 1) + waiters.count
        let id = try await acquire(kind, name)
        defer { release(id) }
        try checkCancellation() // Canceled after it got the queue, before it resumed: it gives it back without running
        let queued = ContinuousClock.now - askedAt
        if queued > slowWait {
            perfLogger.error("session=\(name, privacy: .public) waited \(queued.milliseconds) ms for the queue (\(depth) ahead of it)")
        }
        return try await Self.$holderId.withValue(id) {
            try await Self.$wait.withValue(Wait(queued: queued, depth: depth)) {
                try await body()
            }
        }
    }

    private func acquire(_ kind: Kind, _ name: String) async throws -> UInt64 {
        nextId &+= 1
        let id = nextId
        guard let current = holder else {
            holder = Holder(id: id, kind: kind, name: name)
            return id
        }
        if kind != .heavy, current.kind == .heavy, runningHeavy != nil, !isRunningHeavyPreempted {
            isRunningHeavyPreempted = true
            perfLogger.debug("session=\(name, privacy: .public) preempts session=\(current.name, privacy: .public)")
            heavyTask?.cancel() // A canceled wait for an app returns right away: the queue is free soon
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = Waiter(id: id, kind: kind, name: name, continuation: continuation)
                // Light sessions before the heavy ones, each kind in its order
                if kind == .heavy {
                    waiters.append(waiter)
                } else {
                    waiters.insert(waiter, at: waiters.firstIndex { $0.kind == .heavy } ?? waiters.endIndex)
                }
            }
        } onCancel: {
            // After the waiter is there: the operation adds it before it suspends, this runs on the main actor after
            Task.startUnstructured { @MainActor in self.cancelWaiting(id) }
        }
        return id
    }

    private func cancelWaiting(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return } // It holds the queue, or it's done
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UInt64) {
        check(holder?.id == id, "The queue is released by the session that holds it")
        holder = nil
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        holder = Holder(id: next.id, kind: next.kind, name: next.name)
        next.continuation.resume()
    }

    // MARK: Heavy sessions

    func scheduleHeavy(_ event: RefreshSessionEvent, scope: RefreshScope = .everything, optimisticallyPreLayoutWorkspaces preLayout: Bool = false) {
        if var request = pendingHeavy {
            request.event = event // The last event
            request.preLayout = request.preLayout || preLayout
            request.scope = request.scope.union(scope) // What any of the events may have changed
            request.coalesced += 1
            pendingHeavy = request
        } else {
            pendingHeavy = HeavyRequest(event: event, preLayout: preLayout, scope: scope, coalesced: 1, firstAskedAt: .now, isRerun: heavyTask != nil)
        }
        // A heavy session that waits for the queue takes the request when it gets it, one that runs is followed by one
        if heavyTask == nil { armHeavyTimer() }
    }

    private func armHeavyTimer() {
        guard let request = pendingHeavy else { return }
        heavyTimer?.cancel()
        let due = min(ContinuousClock.now + debounce, request.firstAskedAt + maxWait)
        // Not a part of the session that asked for it, which may still hold the queue: the heavy session waits for it
        heavyTimer = Self.$holderId.withValue(nil) { Task.startUnstructured { @MainActor in
            try? await Task.sleep(until: due)
            if Task.isCancelled { return }
            self.heavyTimer = nil
            if self.heavyTask == nil { self.startHeavy() }
        } }
    }

    private func startHeavy() {
        // Not a part of the session that asked for it: it counts its own accessibility calls (see SessionAxCost), and it
        // waits for the queue like any other session, also if that session still holds it
        heavyTask = Self.$holderId.withValue(nil) { AxStats.$session.withValue(nil) { Task.startUnstructured { @MainActor in
            let name = "heavy \(self.pendingHeavy?.event.description ?? "")"
            _ = try? await self.exclusively(.heavy, name) {
                guard let request = self.pendingHeavy else { return }
                self.pendingHeavy = nil
                self.runningHeavy = request
                self.isRunningHeavyPreempted = false
                await Self.$wait.withValue(Wait(
                    queued: Self.wait?.queued ?? .zero,
                    depth: Self.wait?.depth ?? 0,
                    coalesced: request.coalesced,
                    isRerun: request.isRerun,
                )) {
                    await self.runHeavy(request.event, request.preLayout, request.scope)
                }
            }
            self.heavyDidEnd()
        } } }
    }

    private func heavyDidEnd() {
        let ended = runningHeavy
        let wasPreempted = isRunningHeavyPreempted
        runningHeavy = nil
        isRunningHeavyPreempted = false
        heavyTask = nil
        if wasPreempted, let ended { // Canceled by a light session: again, after it
            if var request = pendingHeavy {
                request.preLayout = request.preLayout || ended.preLayout
                request.scope = request.scope.union(ended.scope) // What the canceled one didn't see yet
                pendingHeavy = request
            } else {
                pendingHeavy = HeavyRequest(event: ended.event, preLayout: ended.preLayout, scope: ended.scope, coalesced: 1, firstAskedAt: .now, isRerun: true)
            }
        }
        if pendingHeavy != nil { armHeavyTimer() } // The events that came while it ran
    }
}
