import Common
import Foundation
import Synchronization

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob,
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T>(
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (RunLoopJob) throws -> T,
    ) async throws -> T { // todo try to convert to typed throws
        try checkCancellation(cm)
        let job = RunLoopJob(cm)
        let waiter = RunLoopWaiter<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiter.wait(cont)
                // Canceled before the continuation was kept: the cancellation found nothing to resume
                if job.isCancelled {
                    waiter.resume(throwing: CancellationError())
                    return
                }
                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    do {
                        try job.checkCancellation()
                        let result = try body(job)
                        waiter.resume(returning: result)
                    } catch {
                        if cm == .nonCancellable { die() }
                        waiter.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
            // A canceled task doesn't wait until the thread gets to the job: the app may be busy, or hung. The job does
            // nothing when it runs (see checkCancellation above), or its answer is dropped
            if cm == .cancellable { waiter.resume(throwing: CancellationError()) }
        }
    }
}

/// The task that waits for a job: resumed exactly once, by the job or by the cancellation of the task, whichever comes
/// first (a continuation that is resumed twice traps)
private final class RunLoopWaiter<T>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func wait(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(returning value: sending T) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        continuation.withLock { $0.take() }?.resume(throwing: error)
    }
}

/// What a request that is given a deadline came to, see ``withDeadline(_:_:)``
enum DeadlineOutcome<T: Sendable>: Sendable {
    case answered(T)
    case deadlinePassed
}

/// `request`, unless it takes longer than `deadline`: it's canceled then (a job of an app thread is dropped, see
/// `runInLoop`). Throws `CancellationError` if the task itself is canceled, not when the deadline passes
@MainActor
func withDeadline<T: Sendable>(
    _ deadline: Duration,
    _ request: @escaping @MainActor @Sendable () async throws -> T,
) async throws -> DeadlineOutcome<T> {
    try await withThrowingTaskGroup(of: DeadlineOutcome<T>.self) { group in
        group.addTask { @Sendable @MainActor in
            let value = try await request()
            return .answered(value)
        }
        group.addTask { @Sendable in
            try await Task.sleep(for: deadline) // Throws when the task is canceled
            return .deadlinePassed
        }
        let first = try await group.next() ?? .deadlinePassed
        group.cancelAll() // The other one: the group waits for it, a canceled request returns right away
        return first
    }
}

private final class RunLoopAction: NSObject, Sendable {
    private let _action: @Sendable (RunLoopJob) -> ()
    let job: RunLoopJob
    private let autoCheckCancelled: Bool
    private let _refreshSessionEvent: RefreshSessionEvent?
    /// Kept until the job is done: the session is logged afterwards (see `SessionAxCost`)
    private let axCost: SessionAxCost?
    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
        _refreshSessionEvent = refreshSessionEvent
        axCost = AxStats.session
    }
    @objc func action() {
        defer { axCost?.jobDidFinish() } // Also a canceled job: it waited behind the jobs before it (a busy app)
        if autoCheckCancelled && job.isCancelled { return }
        $refreshSessionEvent.withValue(_refreshSessionEvent) {
            AxStats.$session.withValue(axCost) {
                _action(job)
            }
        }
    }
}

final class RunLoopJob: Sendable, AeroAny {
    /// Set by the task that waits for the job, read on the thread of the app
    private let _isCancelled = Mutex(false)
    var isCancelled: Bool { _isCancelled.withLock { $0 } }
    func cancel() {
        if cm == .nonCancellable { return }
        _isCancelled.withLock { $0 = true }
    }

    let cm: CancellationMode
    public init(_ cm: CancellationMode) { self.cm = cm }

    static let cancelled: RunLoopJob = RunLoopJob(.cancellable).also { $0.cancel() }

    func checkCancellation() throws {
        if cm == .cancellable && isCancelled {
            throw CancellationError()
        }
    }
}
