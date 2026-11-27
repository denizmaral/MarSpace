@testable import AppBundle
import Common
import Foundation
import Testing

/// The sessions that change the model run one at a time, see SessionQueue
@MainActor
@Suite(.serializedGlobally)
struct SessionQueueTest {
    @MainActor final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    @MainActor final class Log {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    private func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0 ..< 1000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    @Test func testLightSessionsRunOneAtATimeInTheirOrder() async throws {
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { _, _ in }
        let gate = Gate(), log = Log()
        let first = Task.startUnstructured { @MainActor in
            _ = try? await queue.exclusively(.light, "1") {
                log.append("1 starts")
                await gate.wait()
                log.append("1 ends")
            }
        }
        try await until { log.entries == ["1 starts"] }
        var others: [Task<(), Never>] = []
        for i in 2 ... 4 {
            others.append(Task.startUnstructured { @MainActor in _ = try? await queue.exclusively(.light, "\(i)") { log.append("\(i)") } })
            try await until { queue.waitingCount == i - 1 }
        }
        #expect(log.entries == ["1 starts"]) // They wait
        gate.open()
        await first.value
        for other in others { await other.value }
        #expect(log.entries == ["1 starts", "1 ends", "2", "3", "4"])
    }

    @Test func testALightSessionPreemptsARunningHeavyOneThatRunsAgainAfterIt() async throws {
        let log = Log()
        var runs = 0
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { event, _ in
            runs += 1
            log.append("heavy \(event) starts")
            guard runs == 1 else { return }
            do {
                try await Task.sleep(for: .seconds(5)) // Waits for an app
                log.append("heavy ends")
            } catch {
                log.append("heavy is canceled")
            }
        }
        queue.scheduleHeavy(.ax("moved"))
        try await until { log.entries.count == 1 }
        try await queue.exclusively(.light, "light") { log.append("light") }
        try await until { log.entries.count == 4 }
        #expect(log.entries == ["heavy ax(moved) starts", "heavy is canceled", "light", "heavy ax(moved) starts"])
    }

    @Test func testABurstOfEventsIsOneHeavySessionWithTheLastEvent() async throws {
        let log = Log()
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { event, _ in log.append("\(event)") }
        for i in 1 ... 10 { queue.scheduleHeavy(.ax("\(i)")) }
        try await until { !log.entries.isEmpty }
        try await Task.sleep(for: .milliseconds(100)) // No second one
        #expect(log.entries == ["ax(10)"])
    }

    @Test func testEventsThatKeepComingDontHoldOffTheHeavySessionLongerThanMaxWait() async throws {
        let log = Log()
        let start = ContinuousClock.now
        var firstRun: Duration? = nil
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { event, _ in
            firstRun = firstRun ?? ContinuousClock.now - start
            log.append("\(event)")
        }
        for i in 1 ... 40 { // Every 10 ms for 400 ms: the debounce alone would never let it run
            queue.scheduleHeavy(.ax("\(i)"))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let first = try #require(firstRun)
        #expect(first < .milliseconds(300), "\(first)")
        #expect(log.entries.count >= 2) // Not only once at the end
        #expect(log.entries.last == "ax(40)") // The last event isn't lost
    }

    @Test func testEventsWhileAHeavySessionRunsMakeOneMoreAndDontCancelIt() async throws {
        let gate = Gate(), log = Log()
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { event, _ in
            log.append("\(event) starts")
            if event.description == "ax(a)" {
                await gate.wait()
                log.append(Task.isCancelled ? "a is canceled" : "a ends")
            }
        }
        queue.scheduleHeavy(.ax("a"))
        try await until { log.entries == ["ax(a) starts"] }
        for event in ["b", "c", "d"] { queue.scheduleHeavy(.ax(event)) }
        try await Task.sleep(for: .milliseconds(100)) // Longer than the debounce: it still runs, nothing else starts
        #expect(log.entries == ["ax(a) starts"])
        gate.open()
        try await until { log.entries.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.entries == ["ax(a) starts", "a ends", "ax(d) starts"])
    }

    @Test func testACanceledSessionThatWaitsDoesntRun() async throws {
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { _, _ in }
        let gate = Gate(), log = Log()
        let holder = Task.startUnstructured { @MainActor in
            _ = try? await queue.exclusively(.light, "holder") {
                log.append("holder")
                await gate.wait()
            }
        }
        try await until { log.entries == ["holder"] }
        let waiting = Task.startUnstructured { @MainActor () throws in try await queue.exclusively(.light, "waiting") { log.append("waiting runs") } }
        try await until { queue.waitingCount == 1 }
        waiting.cancel()
        try await until { queue.waitingCount == 0 }
        let result = await waiting.result
        if case .failure(let error) = result { #expect(error is CancellationError) } else { Issue.record("It ran") }
        gate.open()
        await holder.value
        try await queue.exclusively(.light, "after") { log.append("after") } // The queue is free
        #expect(log.entries == ["holder", "after"])
    }

    @Test func testASessionInASessionRunsRightAway() async throws {
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { _, _ in }
        let log = Log()
        try await queue.exclusively(.light, "outer") {
            try await queue.exclusively(.light, "inner") { log.append("inner") }
            log.append("outer")
        }
        #expect(log.entries == ["inner", "outer"])
        #expect(queue.nestedRuns == 1)
    }

    @Test func testASessionThatThrowsReleasesTheQueue() async throws {
        struct Failure: Error {}
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { _, _ in }
        await #expect(throws: Failure.self) { try await queue.exclusively(.light, "throws") { throw Failure() } }
        let log = Log()
        try await queue.exclusively(.light, "next") { log.append("next") }
        #expect(log.entries == ["next"])
    }

    @Test func testAHeavySessionWaitsForTheLightOnes() async throws {
        let gate = Gate(), log = Log()
        let queue = SessionQueue(debounce: .milliseconds(10), maxWait: .milliseconds(50)) { event, _ in log.append("heavy \(event)") }
        let light = Task.startUnstructured { @MainActor in
            _ = try? await queue.exclusively(.light, "light") {
                log.append("light starts")
                await gate.wait()
                log.append("light ends")
            }
        }
        try await until { log.entries == ["light starts"] }
        queue.scheduleHeavy(.ax("a"))
        try await until { queue.waitingCount == 1 } // The heavy session waits for the queue
        #expect(log.entries == ["light starts"]) // Doesn't interleave
        gate.open()
        await light.value
        try await until { log.entries.count == 3 }
        #expect(log.entries == ["light starts", "light ends", "heavy ax(a)"])
    }

    @Test func testALightSessionDoesntPreemptTheStartup() async throws {
        let queue = SessionQueue(debounce: .milliseconds(10), maxWait: .milliseconds(50)) { _, _ in }
        let log = Log()
        let startup = Task.startUnstructured { @MainActor in
            _ = try? await queue.exclusively(.startup, "startup") {
                log.append("startup starts")
                try? await Task.sleep(for: .milliseconds(100)) // Not canceled
                log.append(Task.isCancelled ? "startup is canceled" : "startup ends")
            }
        }
        try await until { log.entries == ["startup starts"] }
        try await queue.exclusively(.light, "light") { log.append("light") }
        await startup.value
        #expect(log.entries == ["startup starts", "startup ends", "light"])
    }

    @Test func testThePreLayoutThatWasAskedForIsntLost() async throws {
        let log = Log()
        var runs = 0
        let queue = SessionQueue(debounce: .milliseconds(30), maxWait: .milliseconds(150)) { event, preLayout in
            runs += 1
            log.append("\(event) \(preLayout)")
            if runs == 1 { try? await Task.sleep(for: .seconds(5)) } // Preempted
        }
        // Coalesced: one of the events asked for it
        queue.scheduleHeavy(.ax("a"), optimisticallyPreLayoutWorkspaces: true)
        queue.scheduleHeavy(.ax("b"))
        try await until { log.entries.count == 1 }
        #expect(log.entries == ["ax(b) true"])
        // Preempted: it runs again with it
        try await queue.exclusively(.light, "light") {}
        try await until { log.entries.count == 2 }
        #expect(log.entries == ["ax(b) true", "ax(b) true"])
    }

    /// A session that holds the queue longer than the debounce asks for a heavy session: the heavy one waits for it
    @Test func testAHeavySessionThatASessionAsksForWaitsForIt() async throws {
        let log = Log()
        let queue = SessionQueue(debounce: .milliseconds(10), maxWait: .milliseconds(50)) { event, _ in log.append("heavy \(event)") }
        try await queue.exclusively(.light, "light") {
            queue.scheduleHeavy(.ax("a"))
            try await Task.sleep(for: .milliseconds(100))
            log.append("light ends")
        }
        try await until { log.entries.count == 2 }
        #expect(log.entries == ["light ends", "heavy ax(a)"])
    }

    /// Canceled right after it got the queue, before it resumed: it gives the queue back without running
    @Test func testASessionCanceledWhenItGetsTheQueueDoesntRun() async throws {
        let queue = SessionQueue(debounce: .milliseconds(10), maxWait: .milliseconds(50)) { _, _ in }
        let gate = Gate(), log = Log()
        var granted: Task<(), any Error>? = nil
        var holderEntered = false
        let holder = Task.startUnstructured { @MainActor in
            _ = try? await queue.exclusively(.light, "holder") {
                holderEntered = true
                await gate.wait()
                granted?.cancel() // Its cancellation comes after the queue is handed over to it, right below
            }
        }
        try await until { holderEntered } // It holds the queue
        granted = Task.startUnstructured { @MainActor () throws in try await queue.exclusively(.light, "granted") { log.append("granted runs") } }
        try await until { queue.waitingCount == 1 } // First in line
        let next = Task.startUnstructured { @MainActor in _ = try? await queue.exclusively(.light, "next") { log.append("next") } }
        try await until { queue.waitingCount == 2 }
        gate.open()
        await holder.value
        let result = try #require(await granted?.result)
        if case .failure(let error) = result { #expect(error is CancellationError) } else { Issue.record("It ran") }
        await next.value
        #expect(log.entries == ["next"])
    }
}
