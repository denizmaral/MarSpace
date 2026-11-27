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
}

let perfLogger = Logger(subsystem: aeroSpaceAppId, category: "perf")

/// The accessibility calls and the duration of one refresh session. Logged when the session is over and every job that it
/// sent to the threads of the apps is done: the jobs keep it. `ms` is the session, `jobsMs` until its last job was done
/// (a busy app answers late), `outsideOfSessions` the calls outside of sessions since MarSpace started
final class SessionAxCost: Sendable {
    private struct State {
        var counters = AxStats.Counters()
        var duration: Duration? = nil
    }

    private let name: String
    private let start = ContinuousClock.now
    private let state = Mutex(State())

    init(_ name: String) { self.name = name }

    var counters: AxStats.Counters { state.withLock { $0.counters } }

    func record(_ call: AxStats.Call) { state.withLock { $0.counters.record(call) } }

    /// The session is over, its jobs may still be under way
    func sessionDidFinish() {
        let duration = ContinuousClock.now - start
        state.withLock { $0.duration = $0.duration ?? duration }
    }

    deinit {
        let jobsDuration = ContinuousClock.now - start
        let (ax, duration) = state.withLock { ($0.counters, $0.duration ?? jobsDuration) }
        let outside = AxStats.callsOutsideOfSessions.total
        perfLogger.debug(
            "session=\(self.name, privacy: .public) axReads=\(ax.reads) axWrites=\(ax.writes) axActions=\(ax.actions) axObservers=\(ax.observers) ms=\(duration.milliseconds) jobsMs=\(jobsDuration.milliseconds) outsideOfSessions=\(outside)",
        )
    }
}

extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
