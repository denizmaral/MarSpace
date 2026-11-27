@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct AxStatsTest {
    /// A session counts the calls of the jobs that it sends to the thread of an app, not the calls outside of it
    @Test func testSessionCountsTheCallsOfItsJobs() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let cost = SessionAxCost("test")
        try await AxStats.$session.withValue(cost) {
            AxStats.record(.read)
            try await thread.runInLoop(.cancellable) { _ in
                AxStats.record(.write)
                AxStats.record(.action)
            }
        }
        AxStats.record(.observer) // Outside of the session
        try await thread.runInLoop(.cancellable) { _ in AxStats.record(.read) }
        assertEquals(cost.counters, AxStats.Counters(reads: 1, writes: 1, actions: 1))
    }

    /// A frame is sent without waiting for it: the job keeps the cost of its session, which is logged when the job is done
    @Test func testJobThatIsUnderWayKeepsTheCostOfItsSession() async throws {
        let thread = startRunLoopThread()
        defer { stop(thread) }
        let jobMayRun = DispatchSemaphore(value: 0)
        weak var weakCost: SessionAxCost?
        do {
            let cost = SessionAxCost("test")
            weakCost = cost
            AxStats.$session.withValue(cost) {
                thread.runInLoopAsync(job: RunLoopJob(.cancellable)) { _ in
                    jobMayRun.wait()
                    AxStats.record(.write)
                }
            }
            cost.sessionDidFinish()
        }
        assertNotNil(weakCost)
        jobMayRun.signal()
        try await thread.runInLoop(.cancellable) { _ in } // The run loop does the jobs in order
        for _ in 0 ..< 100 where weakCost != nil { try await Task.sleep(for: .milliseconds(10)) }
        assertNil(weakCost)
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
