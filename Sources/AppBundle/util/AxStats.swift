import Common
import os
import Synchronization

/// Counts accessibility calls. Every AX call is an IPC round trip that also wakes up the main thread of the target app,
/// so AX calls are the main performance and energy cost of AeroSpace (in AeroSpace itself and in other apps).
///
/// A refresh session counts its own calls (``SessionAxCost``), also the ones that its jobs make on the threads of the
/// apps after it's over (frames are sent without waiting, see `MacApp.setAxFrame`). Sessions run side by side (a
/// hotkey while a complete refresh session waits for an app): each counts only its own calls. The calls outside of
/// sessions (the notifications of the apps, focus follows mouse, Mission Control) are counted together.
///
/// The counts are logged per refresh session at the debug level (zero cost unless the log is streamed):
///
///     log stream --level debug --predicate 'subsystem == "com.denizmaral.MarSpace" && category == "perf"'
enum AxStats {
    enum Call {
        /// An attribute, the window of an element, the element at a position
        case read
        /// An attribute
        case write
        /// E.g. raise a window, press its close button
        case action
        /// A notification is subscribed or unsubscribed
        case observer
    }

    struct Counters: Sendable, Equatable {
        var reads: Int = 0
        var writes: Int = 0
        var actions: Int = 0
        var observers: Int = 0

        var total: Int { reads + writes + actions + observers }

        mutating func record(_ call: Call) {
            switch call {
                case .read: reads += 1
                case .write: writes += 1
                case .action: actions += 1
                case .observer: observers += 1
            }
        }
    }

    /// The session that makes the call: its task, or a job that it sent to the thread of an app (see `RunLoopAction`)
    @TaskLocal static var session: SessionAxCost? = nil

    private static let outsideOfSessions = Mutex(Counters())

    static func record(_ call: Call) {
        if let session {
            session.record(call)
        } else {
            outsideOfSessions.withLock { $0.record(call) }
        }
    }

    /// Since MarSpace started
    static var callsOutsideOfSessions: Counters { outsideOfSessions.withLock { $0 } }

    /// A frame job fitted a window into its tile (see `TileFitting`): `asks` sizes after the first one, in `duration`
    static func recordSizeFitting(asks: Int, duration: Duration) {
        session?.recordSizeFitting(asks: asks, duration: duration)
    }
}

let perfLogger = Logger(subsystem: aeroSpaceAppId, category: "perf")
/// What the windows make of the sizes of their tiles, see Window.logFitting
let layoutLogger = Logger(subsystem: aeroSpaceAppId, category: "layout")

/// The accessibility calls and the duration of one refresh session. Logged when the session is over and every job that it
/// sent to the threads of the apps is done: the jobs keep it (so do the tasks that the session starts, e.g. of the focus
/// border: the log can come later). `ms` is the session, `jobsMs` until its last job was done (a busy app answers late),
/// `outsideOfSessions` the calls outside of sessions since MarSpace started
final class SessionAxCost: Sendable {
    private struct State {
        var counters = AxStats.Counters()
        var duration: Duration? = nil
        var jobsDuration: Duration? = nil
        var footprintMegabytes: Int? = nil
        /// See `AxStats.recordSizeFitting(asks:duration:)`
        var sizeFittings = 0
        var sizeFittingAsks = 0
        var sizeFittingDuration: Duration = .zero
    }

    private let name: String
    private let start = ContinuousClock.now
    private let state = Mutex(State())
    /// How long the session waited for the queue (see SessionQueue). nil: it didn't use it (a query)
    private let wait = SessionQueue.wait

    init(_ name: String) { self.name = name }

    var counters: AxStats.Counters { state.withLock { $0.counters } }

    func record(_ call: AxStats.Call) { state.withLock { $0.counters.record(call) } }

    func recordSizeFitting(asks: Int, duration: Duration) {
        state.withLock {
            $0.sizeFittings += 1
            $0.sizeFittingAsks += asks
            $0.sizeFittingDuration += duration
        }
    }

    /// A job of the session on the thread of an app is done
    func jobDidFinish() {
        let duration = ContinuousClock.now - start
        state.withLock { $0.jobsDuration = max($0.jobsDuration ?? duration, duration) }
    }

    /// The session is over, its jobs may still be under way
    func sessionDidFinish() {
        let duration = ContinuousClock.now - start
        let footprint = MemoryFootprint.megabytes
        state.withLock {
            $0.duration = $0.duration ?? duration
            $0.footprintMegabytes = $0.footprintMegabytes ?? footprint
        }
    }

    deinit {
        let now = ContinuousClock.now - start
        let (ax, duration, jobs, footprint, fittings, fittingAsks, fittingDuration) = state.withLock {
            ($0.counters, $0.duration ?? now, $0.jobsDuration, $0.footprintMegabytes, $0.sizeFittings, $0.sizeFittingAsks, $0.sizeFittingDuration)
        }
        let jobsDuration = max(duration, jobs ?? duration)
        let outside = AxStats.callsOutsideOfSessions.total
        let queue = wait.map { wait in
            " queuedMs=\(wait.queued.milliseconds) depth=\(wait.depth)" +
                (wait.coalesced.map { " coalesced=\($0)" } ?? "") + (wait.isRerun.map { " rerun=\($0)" } ?? "")
        } ?? ""
        // The frames sent on the screen are fitted into their tiles: asks for less, when a window rounds its tile up
        let fitting = fittings == 0 ? "" : " sizeFittings=\(fittings) sizeFittingAsks=\(fittingAsks) sizeFittingMs=\(fittingDuration.milliseconds)"
        perfLogger.debug(
            "session=\(self.name, privacy: .public) axReads=\(ax.reads) axWrites=\(ax.writes) axActions=\(ax.actions) axObservers=\(ax.observers) ms=\(duration.milliseconds) jobsMs=\(jobsDuration.milliseconds)\(queue, privacy: .public)\(fitting, privacy: .public) footprintMB=\(footprint ?? -1) outsideOfSessions=\(outside)",
        )
    }
}

extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
