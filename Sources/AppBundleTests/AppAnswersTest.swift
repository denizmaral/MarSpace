@testable import AppBundle
import Common
import Foundation
import Synchronization
import Testing

/// An app that misses the deadline isn't asked and isn't waited for until it answers again, see AppAnswers
@MainActor
@Suite(.serializedGlobally)
struct AppAnswersTest {
    final class Events {
        var probes = 0
        var recoveries = 0
    }

    @Test func testAnAppThatMissesTheDeadlineIsntAskedUntilItAnswersAgain() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let events = Events()
        let answers = AppAnswers(deadline: .milliseconds(100), appName: { "test" }, probe: { events.probes += 1 }, didRecover: { events.recoveries += 1 })
        let asked = Mutex(0)
        let request: @MainActor @Sendable () async throws -> Int = {
            try await thread.runInLoop(.cancellable) { _ -> Int in
                asked.withLock { $0 += 1 }
                return 1
            }
        }
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() } // The app hangs

        var start = ContinuousClock.now
        #expect(try await answers.answer(.cancellable, orElse: { -1 }, request) == -1) // The fallback, at the deadline
        #expect(ContinuousClock.now - start < .milliseconds(600))
        #expect(answers.isDegraded)
        #expect(events.probes == 1)

        start = ContinuousClock.now
        #expect(try await answers.answer(.cancellable, orElse: { -2 }, request) == -2) // Not asked, not waited for
        #expect(ContinuousClock.now - start < .milliseconds(50))
        #expect(events.probes == 1) // One probe

        busy.signal()
        try await thread.runInLoop(.cancellable) { _ in } // The jobs run in order
        #expect(asked.withLock { $0 } == 0) // The canceled request did nothing
        #expect(answers.isDegraded) // The thread is free, but the app answers only when it answers the probe

        answers.didAnswerAgain()
        answers.didAnswerAgain() // Once
        #expect(!answers.isDegraded)
        #expect(events.recoveries == 1)
        #expect(try await answers.answer(.cancellable, orElse: { -3 }, request) == 1) // Asked again
        #expect(asked.withLock { $0 } == 1)
    }

    @Test func testRequestsThatCantBeCanceledHaveNoDeadline() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let events = Events()
        let answers = AppAnswers(deadline: .milliseconds(50), appName: { "test" }, probe: { events.probes += 1 }, didRecover: {})
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { busy.signal() }
        let answer = try await answers.answer(.nonCancellable, orElse: { -1 }) { try await thread.runInLoop(.nonCancellable) { _ -> Int in 1 } }
        #expect(answer == 1)
        #expect(!answers.isDegraded)
        #expect(events.probes == 0)
    }

    /// The apps that launch with the login are slow: the startup session waits for them
    @Test func testTheStartupSessionHasNoDeadline() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let events = Events()
        let answers = AppAnswers(deadline: .milliseconds(50), appName: { "test" }, probe: { events.probes += 1 }, didRecover: {})
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { busy.signal() }
        let answer = try await $refreshSessionEvent.withValue(.startup) {
            try await answers.answer(.cancellable, orElse: { -1 }) { try await thread.runInLoop(.cancellable) { _ -> Int in 1 } }
        }
        #expect(answer == 1)
        #expect(!answers.isDegraded)
        #expect(events.probes == 0)
    }

    /// A request that was asked before the app answered again, and missed its deadline after it, doesn't degrade the app
    /// again
    @Test func testAMissFromBeforeARecoveryDoesntDegradeAgain() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let events = Events()
        let answers = AppAnswers(deadline: .milliseconds(100), appName: { "test" }, probe: { events.probes += 1 }, didRecover: { events.recoveries += 1 })
        let busy = DispatchSemaphore(value: 0)
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in busy.wait() }
        defer { busy.signal() }
        let first = Task.startUnstructured { @MainActor () throws in
            _ = try await answers.answer(.cancellable, orElse: { -1 }) { try await thread.runInLoop(.cancellable) { _ -> Int in 1 } }
        }
        try await Task.sleep(for: .milliseconds(50))
        // Asked before the app answers again, misses its deadline after it
        let lateIsAsked = Mutex(false)
        let late = Task.startUnstructured { @MainActor () throws in
            _ = try await answers.answer(.cancellable, orElse: { -1 }) {
                lateIsAsked.withLock { $0 = true }
                return try await thread.runInLoop(.cancellable) { _ -> Int in 1 }
            }
        }
        for _ in 0 ..< 1000 where !lateIsAsked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        // Asked while the app wasn't degraded yet: else it would get the fallback, and nothing here would be tested
        #expect(lateIsAsked.withLock { $0 })
        #expect(events.probes == 0)
        try await first.value // Missed: degraded
        #expect(answers.isDegraded)
        answers.didAnswerAgain() // As if the probe got its answer
        #expect(!answers.isDegraded)
        try await late.value
        #expect(!answers.isDegraded)
        #expect(events.probes == 1)
        #expect(events.recoveries == 1)
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
