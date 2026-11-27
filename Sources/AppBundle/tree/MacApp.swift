import AppKit
import Common
import os

private let windowsLogger = Logger(subsystem: aeroSpaceAppId, category: "windows")

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since #macos14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    /// Key-value observed (see ``RunningApp``): `activationPolicy`, `isHidden` and `isTerminated` are up to date and
    /// free to read. Its other properties ask Launch Services: not in a refresh session
    let nsApp: NSRunningApplication
    // periphery:ignore - keeps the observations of `nsApp`
    private let running: RunningApp
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private var windowsCount = 0
    var lastFocusedNativeWindowOpaqueId: OpaqueWindowId? = nil
    private var thread: Thread?
    private var setFrameJobs: [OpaqueWindowId: RunLoopJob] = [:]
    // Never pruned: while the screen is locked, AX reports windows as gone, and closedWindowsCache matches
    // the windows re-detected after unlock by their OpaqueWindowId
    // todo: start prunning after we get rid of closedWindowsCache
    private var windowIdMapping = BiDictionary<OpaqueWindowId, UInt32>()
    @MainActor private static var focusJob: RunLoopJob? = nil

    /// Asked when the app is registered, when it's activated and when it opens a window (see ``refreshName()``)
    /*conforms*/ private(set) var name: String?
    let bundleUrl: URL?
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { bundleUrl?.path }

    // todo think if it's possible to integrate this global mutable state to AeroSpace issue #1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(
        _ running: RunningApp,
        bundleId: String?,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread,
    ) {
        self.running = running
        self.nsApp = running.nsApp
        self.axApp = .init(axApp)
        self.pid = running.pid
        self.rawAppBundleId = bundleId
        self.appId = bundleId.flatMap { KnownBundleId.init(rawValue: $0) }
        self.name = running.nsApp.localizedName
        self.bundleUrl = running.nsApp.bundleURL
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    /// - Parameter running: not MarSpace itself: AX requests crash if you send them to yourself (see ``RunningApps``)
    @MainActor @discardableResult static func getOrRegister(_ running: RunningApp) async throws -> MacApp? {
        let pid = running.pid
        if let existing = allAppsMap[pid] { return existing }
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        let bundleId = running.bundleId
        if bundleId == lockScreenAppBundleId { return nil }
        let nsApp = running.nsApp
        let idForDebug = "PID: \(pid) ID: \(bundleId ?? nsApp.executableURL?.description ?? "")"
        try checkCancellation()
        if let wip = wipPids[pid] {
            try await wip.await(.cancellable)
            return allAppsMap[pid]
        }
        let wip = AwaitableOneTimeBroadcastLatch()
        wipPids[pid] = wip

        // The thread keeps its closure while the app runs: a weak reference, or the session would never be logged (see
        // SessionAxCost). The session waits for the subscriptions below
        let axCost = AxStats.session
        let thread = Thread { [weak axCost] in
            $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: idForDebug)) {
                let axApp = AXUIElementCreateApplication(pid)
                let handlers: HandlerToNotifKeyMapping = unsafe [
                    (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]),
                ]
                let job = RunLoopJob(.cancellable)
                let subscriptions = AxStats.$session.withValue(axCost) {
                    (try? unsafe AxSubscription.bulkSubscribe(pid, axApp, job, handlers)) ?? []
                }
                let isGood = !subscriptions.isEmpty
                let app = isGood ? MacApp(running, bundleId: bundleId, axApp, subscriptions, Thread.current) : nil

                let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                let windowsThreadGuarded = app?.windows
                let axAppThreadGuarded = app?.axApp

                Task.startUnstructured { @MainActor in
                    allAppsMap[pid] = app
                    wipPids[pid] = nil
                    await wip.signalToAll()
                }
                if isGood {
                    CFRunLoopRun()

                    // Destroy AX objects in reverse order of their creation
                    appAxSubscriptionsThreadGuarded?.destroy()
                    windowsThreadGuarded?.destroy()
                    axAppThreadGuarded?.destroy()
                }
            }
        }
        thread.name = "AxAppThread \(idForDebug)"
        thread.start()

        try await wip.await(.cancellable)
        return allAppsMap[pid]
    }

    /// The name is a round trip to Launch Services: asked when something happens to the app, not in the refresh
    /// sessions and the queries (the menu bar and `list-windows` show it). An app can change its name after it was
    /// launched
    @MainActor func refreshName() { name = nsApp.localizedName }

    func nativeWindowId(of windowId: OpaqueWindowId) -> UInt32? { windowIdMapping.forward[windowId] }

    func opaqueWindowId(of nativeWindowId: UInt32) -> OpaqueWindowId? { windowIdMapping.backward[nativeWindowId] }

    @MainActor private func getOrRegisterOpaqueWindowId(_ nativeWindowId: UInt32) -> OpaqueWindowId {
        if let existing = windowIdMapping.backward[nativeWindowId] { return existing }
        let windowId = OpaqueWindowId.nextUniqId()
        windowIdMapping.put(windowId, nativeWindowId)
        return windowId
    }

    func closeAndUnregisterAxWindow(_ windowId: OpaqueWindowId) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return }
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if closeButton.cast.perform(kAXPressAction) {
                windows.threadGuarded.removeValue(forKey: nativeWindowId)
            }
        }
    }

    /// Not waited for longer than ``answerDeadline``: the size as it was observed last
    @MainActor
    func getAxSize(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> CGSize? {
        try await answer(cm, orElse: { _ in Window.get(byId: windowId)?.observedFrame?.size }) {
            try await $0.withWindow(windowId, cm) { window, job in
                window.get(Ax.sizeAttr)
            }
        }
    }

    /// Not waited for longer than ``answerDeadline``: the window that the app had focused, as far as MarSpace knows
    @MainActor
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        try await answer(cm, orElse: { MainActorRef($0.lastFocusedNativeWindowOpaqueId.flatMap(Window.get(byId:))) }) {
            MainActorRef(try await $0.askFocusedWindow(cm))
        }.value
    }

    // todo merge together with detectNewWindows
    @MainActor
    private func askFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let nativeWindowId = try await thread?.runInLoop(cm) { [pid, axApp, windows] job in
            try axApp.threadGuarded.focusedWindowOfApp // The focus in a sheet is the focus of its window
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, pid, job) }?
                .windowId
        }
        guard let nativeWindowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: getOrRegisterOpaqueWindowId(nativeWindowId), macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: OpaqueWindowId) {
        if serverArgs.isReadOnly { return }
        MacApp.focusJob?.cancel()
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: AeroSpace issue #101
        if (!NSScreen.screensHaveSeparateSpaces || globalUnsortedMonitorInfos.count == 1) &&
            (lastFocusedNativeWindowOpaqueId == windowId || windowsCount == 1)
        {
            nsApp.activate(options: []) // .activateIgnoringOtherApps has no effect since macOS 14
        } else {
            MacApp.focusJob = withWindowAsync(windowId, .cancellable) { [nsApp] window, job in
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                window.set(Ax.isMainAttr, true)
                window.perform(kAXRaiseAction)
                nsApp.activate(options: []) // .activateIgnoringOtherApps has no effect since macOS 14
            }
        }
    }

    /// - Parameter readBack: see ``Window/sendAxFrame(_:_:readBack:)``
    func setAxFrame(_ windowId: OpaqueWindowId, _ topLeft: CGPoint?, _ size: CGSize?, readBack generation: UInt?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { [axApp] window, job in
            let isApplied = try disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
            if !isApplied { // E.g. the app is busy. Make the next layout send the frame again
                Task.startUnstructured { @MainActor in Window.get(byId: windowId)?.invalidateSentFrame() }
                return
            }
            // What the app made of it, in the same job: it may refuse the size
            guard let generation, let frame = try AppBundle::getAxRect(window: window, job: job) else { return }
            Task.startUnstructured { @MainActor in Window.get(byId: windowId)?.frameWasReadBack(frame, generation: generation) }
        }
    }

    /// The frame of the window before MarSpace quits. Nobody waits for the app here: `done` is left when the frame is
    /// set, or when it can't be (the window is gone)
    ///
    /// - Parameter frame: the frame for the window, by where it is now. Called on the thread of the app
    func setAxFrameForTermination(
        _ windowId: OpaqueWindowId,
        _ done: DispatchGroup,
        _ frame: @escaping @Sendable (Rect?) -> (topLeft: CGPoint, size: CGSize)?,
    ) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        guard let thread, let nativeWindowId = windowIdMapping.forward[windowId] else { return }
        done.enter()
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { [axApp, windows] job in
            defer { done.leave() }
            guard let window = windows.threadGuarded[nativeWindowId]?.ax,
                  let (topLeft, size) = frame(try? AppBundle::getAxRect(window: window, job: job))
            else { return }
            _ = try? disableAnimations(app: axApp.threadGuarded, job) {
                try setFrame(window, topLeft, size, job)
            }
        }
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        try await thread?.runInLoop(cm) { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    /// Not waited for longer than ``answerDeadline``: the frame as it was observed last
    @MainActor
    func getAxRect(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Rect? {
        try await answer(cm, orElse: { _ in Window.get(byId: windowId)?.observedFrame }) {
            try await $0.withWindow(windowId, cm) { window, job in
                try AppBundle::getAxRect(window: window, job: job)
            }
        }
    }

    func isWindowHeuristic(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: OpaqueWindowId, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: OpaqueWindowId, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: OpaqueWindowId, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await thread?.runInLoop(cm) { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    /// Not waited for longer than ``answerDeadline``: the state that the window is in for MarSpace (its container), so
    /// that nothing changes until the app answers
    @MainActor
    func getMacosWindowNativeState(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> MacosWindowNativeState? {
        try await answer(cm, orElse: { _ in (Window.get(byId: windowId) as? MacWindow).map(\.nativeStateAsKnown) }) {
            try await $0.withWindow(windowId, cm) { window, job in
                if window.get(Ax.isFullscreenAttr) == true { return .nativeFullscreen }
                try job.checkCancellation()
                if window.get(Ax.minimizedAttr) == true { return .nativeMinimized }
                return .normal
            }
        }
    }

    @MainActor func getWindowLevel(_ windowId: OpaqueWindowId, _ cm: CancellationMode) async throws -> MacOsWindowLevel? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        return try await AppBundle::getWindowLevel(forNativeId: nativeWindowId, cm)
    }

    @MainActor static func refreshAllAndGetAliveWindowIds(
        frontmostAppBundleId: String?,
    ) async throws -> [MacApp: [OpaqueWindowId: WindowLifeStatus]] {
        for app in MacApp.allAppsMap.values { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(
            of: (MainActorRef<MacApp>, [OpaqueWindowId: WindowLifeStatus])?.self,
            returning: [MacApp: [OpaqueWindowId: WindowLifeStatus]].self,
        ) { group in
            @MainActor func refreshTheApp(_ app: MacApp) {
                let app = MainActorRef(app)
                group.addTask { @Sendable @MainActor in
                    return (app, try await app.value.aliveWindowIdsOrKnown(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps, each one in its own task: an app that doesn't answer doesn't hold up the others (see
            // registerWithinDeadline)
            for running in RunningApps.regular {
                try checkCancellation()
                let running = MainActorRef(running)
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.registerWithinDeadline(running.value, .cancellable) else { return nil }
                    return (MainActorRef(app), try await app.aliveWindowIdsOrKnown(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            for app in MacApp.allAppsMap.values {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular {
                    refreshTheApp(app)
                }
            }
            var result: [MacApp: [OpaqueWindowId: WindowLifeStatus]] = [:]
            for try await case let (macAppRef, windowIds)? in group {
                result[macAppRef.value] = windowIds
            }
            return result
        }
    }

    /// Not waited for longer than ``answerDeadline``: the windows of the app as MarSpace has them, with their life
    /// statuses. Not none: they would be garbage collected as closed
    @MainActor private func aliveWindowIdsOrKnown(frontmostAppBundleId: String?) async throws -> [OpaqueWindowId: WindowLifeStatus] {
        try await answer(.cancellable, orElse: { $0.knownWindows }) {
            try await $0.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId)
        }
    }

    @MainActor private var knownWindows: [OpaqueWindowId: WindowLifeStatus] {
        var result: [OpaqueWindowId: WindowLifeStatus] = [:]
        for window in MacWindow.allWindowsMap.values where window.macApp === self { result[window.windowId] = window.lifeStatus }
        return result
    }

    @MainActor private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [OpaqueWindowId: WindowLifeStatus] {
        if nsApp.isTerminated {
            await destroy()
            return [:]
        }
        guard let thread else { return [:] }
        var aliveOrInvisible = try await thread
            .runInLoop(.cancellable) { [pid, windows, axApp, bgTabsScheduledForPrune] (job) -> [UInt32: WindowLifeStatus] in
                var aliveOrInvisible: [UInt32: AxWindow] = windows.threadGuarded.filter { !bgTabsScheduledForPrune.contains($0.key) }
                var aliveWindowIds: Set<UInt32> = []
                // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
                // Second and third lines of defence are technically needed only to avoid potential flickering
                let listed = axApp.threadGuarded.get(Ax.windowsAttr) ?? []
                if frontmostAppBundleId != lockScreenAppBundleId {
                    aliveOrInvisible = try aliveOrInvisible.filterExisting(listed: Set(listed.map(\.windowId))) {
                        try job.checkCancellation()
                        return $0.ax.containingNativeWindowId() != nil
                    }
                }

                for (id, window) in listed {
                    try job.checkCancellation()
                    try aliveOrInvisible.getOrRegisterAxWindow(windowId: id, window, pid, job)
                    aliveWindowIds.insert(id)
                }

                windows.threadGuarded = aliveOrInvisible
                return aliveOrInvisible.keys.associate(with: { it in aliveWindowIds.contains(it) ? .alive : .invisible })
            }
        bgTabsScheduledForPrune = []
        windowsCount = aliveOrInvisible.count

        nonidempotentNativeTabSwapHeuristic(&aliveOrInvisible)

        var aliveOrInvisibleMap: [OpaqueWindowId: WindowLifeStatus] = [:]
        for (id, lifeStatus) in aliveOrInvisible {
            aliveOrInvisibleMap[getOrRegisterOpaqueWindowId(id)] = lifeStatus
        }
        for windowId in setFrameJobs.keys {
            if !aliveOrInvisibleMap.keys.contains(windowId) {
                setFrameJobs.removeValue(forKey: windowId)?.cancel()
            }
        }
        return aliveOrInvisibleMap
    }

    private var bgTabsScheduledForPrune: Set<UInt32> = []
    private var lifeStatusesOfLastRefresh: [UInt32: WindowLifeStatus] = [:]
    @MainActor private func nonidempotentNativeTabSwapHeuristic(_ aliveOrInvisible: inout [UInt32: WindowLifeStatus]) {
        let noLongerAlive = lifeStatusesOfLastRefresh.filter { (id, lifeStatus) in lifeStatus == .alive && aliveOrInvisible[id] != .alive }
        let becameAlive = aliveOrInvisible.filter { (id, lifeStatus) in lifeStatus == .alive && lifeStatusesOfLastRefresh[id] != .alive }
        lifeStatusesOfLastRefresh = aliveOrInvisible
        if let backgroundTabId = noLongerAlive.singleOrNil()?.key,
           let frontmostTabId = becameAlive.singleOrNil()?.key
        {
            // A tab swap hands the place of the window that went away over to the one that appeared. A window that isn't
            // managed as a window has no place: e.g. the window that an app shows only while its window goes fullscreen (a
            // popup, gone before the frames can be compared) took the id of the window in fullscreen, which was registered
            // again as a new window
            guard let backgroundWindow = windowIdMapping.backward[backgroundTabId].flatMap({ Window.get(byId: $0) }),
                  !(backgroundWindow.parent is MacosPopupWindowsContainer)
            else {
                windowsLogger.info("not a native tab swap (not a managed window): \(backgroundTabId) -> \(frontmostTabId)")
                return
            }
            guard mayBeTabsOfOneGroup(backgroundTabId, frontmostTabId) else {
                windowsLogger.info("not a native tab swap (different frames): \(backgroundTabId) -> \(frontmostTabId)")
                return
            }
            windowsLogger.info("native tab swap: \(backgroundTabId) -> \(frontmostTabId)")
            let tabGroupWindowId = getOrRegisterOpaqueWindowId(backgroundTabId)
            windowIdMapping.put(tabGroupWindowId, frontmostTabId)
            aliveOrInvisible[backgroundTabId] = nil
            bgTabsScheduledForPrune.insert(backgroundTabId)
        }
    }

    /// The tabs of a native tab group share the frame. A window that goes native fullscreen (to its own Space) and the
    /// other window of the app (on the previous Space) swap their visibility the same way, but their frames differ: they
    /// must not be merged into one window (the fullscreen window was registered again as a new window when it came back)
    private func mayBeTabsOfOneGroup(_ first: UInt32, _ second: UInt32) -> Bool {
        let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        func bounds(_ id: UInt32) -> CGRect? {
            guard let info = infos.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(id) }),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        guard let a = bounds(first), let b = bounds(second) else { return true } // Unknown: a tab swap, as before
        return abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    private func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in _ = MacApp.allAppsMap.removeValue(forKey: pid) }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        thread = nil // Disallow all future job submissions
    }

    // MARK: An app that doesn't answer

    /// How long a session waits for an app (see ``AppAnswers``). Measured on 2026-11-27: a healthy app answers in
    /// milliseconds (the complete refresh sessions took 3-19 ms), one that launches within about a second (Chess
    /// registered in 1 s). A hung app answers only after the timeout of the accessibility API, about 1.5 s for each
    /// request: a hotkey waited 1.5-4.5 s while the frontmost app was stopped
    static let answerDeadline: Duration = .seconds(1)

    /// Whether the app answers in time, see ``answer(_:orElse:_:)``
    @MainActor private lazy var answers = AppAnswers(
        deadline: Self.answerDeadline,
        appName: { [weak self] in self.map { $0.name ?? "pid \($0.pid)" } ?? "an app that quit" },
        probe: { [weak self] in self?.startProbe() },
        didRecover: { scheduleCancellableCompleteRefreshSession(.appAnswered) },
    )

    /// The apps that launched and weren't registered within ``answerDeadline`` (their accessibility subscriptions): a
    /// session follows when they are, see ``registerWithinDeadline(_:_:)``
    @MainActor private static var lateRegistrations: Set<pid_t> = []

    /// What a session asks the app for, through ``AppAnswers``: every request that a session waits for goes through
    /// here. `fallback`: what MarSpace knows without asking, the answer while the app doesn't answer in time
    @MainActor
    private func answer<T: Sendable>(
        _ cm: CancellationMode,
        orElse fallback: @MainActor (MacApp) -> T,
        _ request: @escaping @MainActor @Sendable (MacApp) async throws -> T,
    ) async throws -> T {
        let app = MainActorRef(self)
        return try await answers.answer(cm, orElse: { fallback(self) }) { try await request(app.value) }
    }

    /// The request that missed the deadline waits behind the job that the app is busy with: a probe after it tells when
    /// the app answers again (see ``probeUntilItAnswers(_:pid:)``)
    @MainActor
    private func startProbe() {
        let pid = pid
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable), autoCheckCancelled: false) { [axApp] _ in
            MacApp.probeUntilItAnswers(axApp, pid: pid)
        }
    }

    /// On the thread of the app: asks it for something that it always has, its role. That the thread got to the probe
    /// doesn't mean that the app answers: the request that it was busy with may have timed out (the accessibility API
    /// gives up after about 1.5 s), the app may still be hung. While the app doesn't answer, it's asked again, once its
    /// request timed out
    private static func probeUntilItAnswers(_ axApp: ThreadGuardedValue<AXUIElement>, pid: pid_t) {
        if axApp.threadGuarded.get(Ax.roleAttr) != nil {
            Task.startUnstructured { @MainActor in MacApp.allAppsMap[pid]?.answers.didAnswerAgain() }
            return
        }
        Thread.sleep(forTimeInterval: 0.25) // It may fail right away (e.g. it quits): not in a loop that keeps the thread busy
        Thread.current.runInLoopAsync(job: RunLoopJob(.nonCancellable), autoCheckCancelled: false) { _ in
            probeUntilItAnswers(axApp, pid: pid)
        }
    }

    /// The app, registered within ``answerDeadline``. An app that launched and doesn't answer its accessibility
    /// subscriptions in time isn't waited for: its registration goes on, and a session follows when it's done. No deadline
    /// for the same requests as in ``AppAnswers``
    @MainActor
    static func registerWithinDeadline(_ running: RunningApp, _ cm: CancellationMode) async throws -> MacApp? {
        let pid = running.pid
        if let existing = allAppsMap[pid] { return existing }
        if cm == .nonCancellable || isStartup { return try await getOrRegister(running) }
        if lateRegistrations.contains(pid) { return nil }
        let runningRef = MainActorRef(running)
        switch try await withDeadline(answerDeadline, { try await getOrRegister(runningRef.value).map(MainActorRef.init) }) {
            case .answered(let app): return app?.value
            case .deadlinePassed:
                lateRegistrations.insert(pid)
                perfLogger.error("pid \(pid) isn't registered within \(String(describing: answerDeadline), privacy: .public): the sessions go on without it until it is")
                Task.startUnstructured { @MainActor in
                    defer { lateRegistrations.remove(pid) }
                    // The registration that is under way (see wipPids)
                    if (try? await getOrRegister(runningRef.value)) != nil { scheduleCancellableCompleteRefreshSession(.appAnswered) }
                }
                return nil
        }
    }

    private func withWindow<T>(
        _ windowId: OpaqueWindowId,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return nil }
        return try await thread?.runInLoop(cm) { [windows] job in
            guard let window = windows.threadGuarded[nativeWindowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(_ windowId: OpaqueWindowId, _ cm: CancellationMode, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> ()) -> RunLoopJob {
        guard let nativeWindowId = windowIdMapping.forward[windowId] else { return .cancelled }
        return thread?.runInLoopAsync(job: RunLoopJob(cm)) { [windows] job in
            guard let window = windows.threadGuarded[nativeWindowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ pid: pid_t, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(pid, ax, job, handlers)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult fileprivate mutating func getOrRegisterAxWindow(
        windowId id: UInt32,
        _ axWindow: AXUIElement,
        _ pid: pid_t,
        _ job: RunLoopJob,
    ) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // AeroSpace issue #1001
        // Not when MarSpace starts: the windows that are there aren't new, and only the startup session puts them back
        // into the layout of the previous run (with the button down, it found no windows: they all came later, as new
        // windows in an arbitrary order)
        if isLeftMouseButtonDown && !isStartup { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, pid, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

extension Dictionary where Key == UInt32 {
    /// The windows (by their native id) that still exist: a window that its app lists does, only the others are asked
    /// (a window on another macOS Space or a background tab isn't listed). Asking is an accessibility call per window,
    /// in every refresh session
    func filterExisting(listed: Set<UInt32>, isWindow: (Value) throws -> Bool) rethrows -> [UInt32: Value] {
        try filter { try listed.contains($0.key) || isWindow($0.value) }
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

/// Returns false if any of the AX writes failed
private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws -> Bool {
    // Set size and then the position. The order is important AeroSpace issue #143
    //                                                        AeroSpace issue #335
    var isApplied = true
    if let size { isApplied = window.set(Ax.sizeAttr, size) && isApplied }
    try job.checkCancellation()
    if let topLeft { isApplied = window.set(Ax.topLeftCornerAttr, topLeft) && isApplied } else { return isApplied }
    try job.checkCancellation()
    if let size { isApplied = window.set(Ax.sizeAttr, size) && isApplied }
    return isApplied
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}

final class MainActorRef<T>: Sendable {
    @MainActor var value: T
    @MainActor public init(_ value: T) { self.value = value }
}
