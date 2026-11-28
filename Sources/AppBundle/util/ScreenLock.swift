import AppKit
import CoreGraphics

/// While the screen is locked, asleep or the session isn't on the console (another user), the accessibility API doesn't
/// tell the windows (see `closedWindowsCache`): what MarSpace sees then isn't what the apps have. The periods of it are
/// counted (an epoch): what one complete refresh session saw is comparable to what another one saw only if both saw the
/// same epoch, unlocked (see `FullSweeps`).
///
/// The one owner of it. The truth is the session of the window server (`CGSessionCopyCurrentDictionary`), read when a
/// session starts and ends; the notifications of the lock and of sleep start a period between the sessions. The
/// frontmost app isn't it: a lock after the display went to sleep doesn't activate the lock screen
@MainActor
final class ScreenLock {
    static let shared = ScreenLock()
    private var periods = LockPeriods()

    private init() {}

    /// The state now, from the window server
    func now() -> LockPeriods.Snapshot { observe(isLocked: Self.isLockedNow) }

    func observeNotifications() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = ScreenLock.shared.observe(isLocked: true) }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = ScreenLock.shared.now() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = ScreenLock.shared.observe(isLocked: true) }
            }
        }
        // Awake isn't unlocked: the window server tells
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = ScreenLock.shared.now() }
            }
        }
    }

    private func observe(isLocked: Bool) -> LockPeriods.Snapshot {
        let before = periods.epoch
        let snapshot = periods.observe(isLocked: isLocked)
        if snapshot.epoch != before { perfLogger.info("lock period \(snapshot.epoch) began: the windows aren't comparable across it") }
        return snapshot
    }

    private static var isLockedNow: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true } // No session of the window server
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session[kCGSessionOnConsoleKey] as? Bool == false
    }
}

/// The periods while the screen is locked (see `ScreenLock`)
struct LockPeriods: Sendable {
    /// Counts the periods: it changes once when one begins
    private(set) var epoch: UInt64 = 0
    private var isLocked = false

    struct Snapshot: Sendable, Equatable {
        let epoch: UInt64
        let isLocked: Bool
    }

    mutating func observe(isLocked: Bool) -> Snapshot {
        if isLocked && !self.isLocked { epoch += 1 }
        self.isLocked = isLocked
        return Snapshot(epoch: epoch, isLocked: isLocked)
    }
}
