@testable import AppBundle
import Common
import Foundation
import Synchronization
import Testing

/// A task that waits for the thread of an app is resumed when it's canceled, without waiting for the thread to get to the
/// job (the app may be hung), and exactly once
@MainActor
@Suite(.serializedGlobally)
struct RunLoopWaiterTest {
    @Test func testCanceledWaiterDoesntWaitForABusyThread() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() } // A hung app
        let ran = Mutex(false)
        let waiter = Task.startUnstructured { @MainActor () throws in
            try await thread.runInLoop(.cancellable) { _ in ran.withLock { $0 = true } }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let start = ContinuousClock.now
        #expect(await isCancellation(waiter.result))
        #expect(ContinuousClock.now - start < .seconds(1))
        busy.signal()
        try await thread.runInLoop(.cancellable) { _ in } // The jobs run in order: the canceled one is done
        #expect(!ran.withLock { $0 }) // It did nothing
    }

    @Test func testJobOfACanceledWaiterDropsItsAnswer() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let inJob = Mutex(false), mayFinish = DispatchSemaphore(value: 0)
        let answer = Mutex<Int?>(nil)
        let waiter = Task.startUnstructured { @MainActor () throws in
            let value = try await thread.runInLoop(.cancellable) { _ -> Int in
                inJob.withLock { $0 = true }
                mayFinish.wait() // The app is slow to answer
                return 42
            }
            answer.withLock { $0 = value }
        }
        while !inJob.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        waiter.cancel()
        #expect(await isCancellation(waiter.result))
        mayFinish.signal() // The answer comes: it isn't delivered a second time
        try await thread.runInLoop(.cancellable) { _ in }
        #expect(answer.withLock { $0 } == nil)
    }

    @Test func testCanceledBeforeTheJobIsSent() async {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let waiter = Task.startUnstructured { @MainActor () throws in
            await Task.yield() // Canceled meanwhile
            _ = try await thread.runInLoop(.cancellable) { _ -> Int in 1 }
        }
        waiter.cancel()
        #expect(await isCancellation(waiter.result))
    }

    @Test func testEveryWaiterIsResumedOnceWhenItsCanceled() async {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let answers = Mutex<[Int: Int]>([:])
        var waiters: [Task<(), any Error>] = []
        for i in 0 ..< 300 {
            let waiter = Task.startUnstructured { @MainActor () throws in
                let value = try await thread.runInLoop(.cancellable) { _ -> Int in
                    if i % 3 == 0 { Thread.sleep(forTimeInterval: 0.0002) }
                    return i
                }
                answers.withLock { $0[i] = value }
            }
            if i % 2 == 0 { waiter.cancel() } // Before, while or after the thread does the job
            waiters.append(waiter)
            if i % 7 == 0 { await Task.yield() }
        }
        for (i, waiter) in waiters.enumerated() {
            switch await waiter.result {
                case .success: #expect(answers.withLock { $0[i] } == i)
                case .failure(let error): #expect(error is CancellationError)
            }
        }
    }

    @Test func testDeadlinePassesWhileTheThreadIsBusy() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() }
        let start = ContinuousClock.now
        let outcome = try await withDeadline(.milliseconds(100)) { try await thread.runInLoop(.cancellable) { _ -> Int in 1 } }
        #expect(ContinuousClock.now - start < .milliseconds(600))
        guard case .deadlinePassed = outcome else { Issue.record("answered: \(outcome)"); return }
        busy.signal()
        let answered = try await withDeadline(.seconds(5)) { try await thread.runInLoop(.cancellable) { _ -> Int in 2 } }
        guard case .answered(2) = answered else { Issue.record("\(answered)"); return }
    }

    @Test func testCanceledTaskIsntADeadline() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() }
        defer { busy.signal() }
        let task = Task.startUnstructured { @MainActor () throws in
            _ = try await withDeadline(.seconds(10)) { try await thread.runInLoop(.cancellable) { _ -> Int in 1 } }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let start = ContinuousClock.now
        #expect(await isCancellation(task.result))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    private func isCancellation(_ result: Result<(), any Error>) -> Bool {
        if case .failure(let error) = result { error is CancellationError } else { false }
    }

    private func startRunLoopThread() -> Thread {
        let thread = Thread {
            RunLoop.current.add(Port(), forMode: .default) // A run loop without a source returns right away
            CFRunLoopRun()
        }
        thread.start()
        return thread
    }

    private func stop(_ thread: Thread) {
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}
