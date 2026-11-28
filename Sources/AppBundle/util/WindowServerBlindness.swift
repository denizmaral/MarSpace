import AppKit
import CoreGraphics

/// While the screen is locked, the displays sleep or the session isn't on the console (another user), the
/// accessibility API doesn't tell the windows (see `closedWindowsCache`): what MarSpace sees then isn't what the apps
/// have. The periods of it are counted (an epoch): what one complete refresh session saw is comparable to what another
/// one saw only if both saw the same epoch, not blind (see `FullSweeps`).
///
/// The one owner of it. The truth is the window server (`isWindowServerBlind`), read by the full sweeps, the only
/// sessions that decide something with it. Between two full sweeps, the notifications start a period: sleep and the
/// session leaving the console (public), and the lock (`screenIsLocked`, undocumented). A lock that doesn't sleep the
/// displays (Ctrl-Cmd-Q) and ends before the next full sweep is seen only through that undocumented notification. The
/// notifications of the unlock and of the wake read the truth again (awake isn't unlocked). The frontmost app isn't it:
/// a lock after the displays went to sleep doesn't activate the lock screen
@MainActor
final class WindowServerBlindness {
    static let shared = WindowServerBlindness(readsWindowServer: WindowServerBlindness.isWindowServerBlind)
    private var periods = BlindPeriods()
    private let readsWindowServer: () -> Bool

    init(readsWindowServer: @escaping () -> Bool) { self.readsWindowServer = readsWindowServer }

    /// Reads the window server: the state now
    func observeNow() -> BlindPeriods.Snapshot {
        let state = signposter.beginInterval(#function)
        defer { signposter.endInterval(#function, state) }
        return observe(isBlind: readsWindowServer())
    }

    func handle(_ event: BlindnessEvent) {
        switch event {
            case .blind: _ = observe(isBlind: true) // Whatever the window server says yet: the period begins
            case .mayBeBack: _ = observeNow()
        }
    }

    func observeNotifications() {
        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [(Self.screenIsLocked, BlindnessEvent.blind), (Self.screenIsUnlocked, .mayBeBack)] {
            distributed.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowServerBlindness.shared.handle(event) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, BlindnessEvent)] = [
            (NSWorkspace.willSleepNotification, .blind), (NSWorkspace.didWakeNotification, .mayBeBack),
            (NSWorkspace.screensDidSleepNotification, .blind), (NSWorkspace.screensDidWakeNotification, .mayBeBack),
            (NSWorkspace.sessionDidResignActiveNotification, .blind), (NSWorkspace.sessionDidBecomeActiveNotification, .mayBeBack),
        ]
        for (name, event) in events {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowServerBlindness.shared.handle(event) }
            }
        }
    }

    private func observe(isBlind: Bool) -> BlindPeriods.Snapshot {
        let before = periods.epoch
        let snapshot = periods.observe(isBlind: isBlind)
        if snapshot.epoch != before { perfLogger.notice("blind period \(snapshot.epoch) began: the windows aren't comparable across it") }
        return snapshot
    }

    /// Posted by loginwindow when the screen locks and unlocks. Undocumented distributed notifications: the only signal of
    /// a lock without sleep between two full sweeps (see above). If macOS stops posting them, such a lock is missed and
    /// the next widened full sweep reports the windows that came back
    private static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    /// A key of `CGSessionCopyCurrentDictionary`: true while the screen is locked, absent otherwise (read as not locked).
    /// Undocumented, next to the public signals: the session on the console, the displays asleep
    private nonisolated static let sessionScreenIsLockedKey = "CGSSessionScreenIsLocked"

    /// The screen is locked, every display sleeps, or the session isn't on the console. No session of the window server:
    /// blind too
    nonisolated static func isWindowServerBlind() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if session[kCGSessionOnConsoleKey] as? Bool == false || session[sessionScreenIsLockedKey] as? Bool == true { return true }
        var count: UInt32 = 0
        guard unsafe CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard unsafe CGGetOnlineDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }
}

/// What a notification says about the window server (see `WindowServerBlindness.handle(_:)`)
enum BlindnessEvent: Sendable {
    /// The screen locks, the displays or the Mac go to sleep, the session leaves the console
    case blind
    /// The opposite: it may be back, the window server tells
    case mayBeBack
}

/// The periods while the window server is blind (see `WindowServerBlindness`)
struct BlindPeriods: Sendable {
    /// Counts the periods: it changes once when one begins
    private(set) var epoch: UInt64 = 0
    private var isBlind = false

    struct Snapshot: Sendable, Equatable {
        let epoch: UInt64
        let isBlind: Bool
    }

    mutating func observe(isBlind: Bool) -> Snapshot {
        if isBlind && !self.isBlind { epoch += 1 }
        self.isBlind = isBlind
        return Snapshot(epoch: epoch, isBlind: isBlind)
    }
}
