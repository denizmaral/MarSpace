import AppKit
import Common

/// The startup session (see initAppBundle) registers the windows that are there and puts them back into the layout of
/// the previous run. No other complete refresh session is started before it's over: the two would take turns (the
/// settings are applied right before, which asks for a session), and the other one registered windows as new ones,
/// laid them out before they were back at their places and persisted that layout. The session that follows the
/// startup session sees whatever happened meanwhile
@MainActor
private var isStartupSessionOver = false

/// The complete refresh sessions that were asked for in unit tests, which don't run them
@MainActor var completeRefreshSessionsAskedForInTests: [RefreshSessionEvent] = []
/// The scopes of ``completeRefreshSessionsAskedForInTests``
@MainActor var completeRefreshScopesAskedForInTests: [RefreshScope] = []

/// When the last complete refresh session that asked every app ended (see ``RefreshScope/effective(lastFullSweep:now:)``)
@MainActor
private var lastFullSweep: ContinuousClock.Instant? = nil

/// - Parameter scope: what may have changed, see ``RefreshScope``
@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    scope: RefreshScope = .everything,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    if isUnitTest { // Complete refresh sessions talk to the real apps via accessibility
        completeRefreshSessionsAskedForInTests.append(event)
        completeRefreshScopesAskedForInTests.append(scope)
        return
    }
    if !isStartupSessionOver { return }
    // A burst of events is one session, one that runs isn't canceled by them: see SessionQueue
    SessionQueue.shared.scheduleHeavy(event, scope: scope, optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces)
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    scope requested: RefreshScope = .everything,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    defer { if event.isStartup { isStartupSessionOver = true } }
    if !TrayMenuModel.shared.isEnabled { return }
    let scope = requested.effective(lastFullSweep: lastFullSweep, now: .now)
    // Asked for some apps and asks every app, because the last time is too long ago: what it finds of the other apps
    // was missed (see logMissedChange)
    let missedOutside = scope != requested ? requested.pids : nil
    let axCost = SessionAxCost("heavy \(event) scope=\(scope)\(scope != requested ? " asked=\(requested)" : "")")
    defer { axCost.sessionDidFinish() }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) { try await AxStats.$session.withValue(axCost) {
            if scope != .layout { // The focus changes with the windows and the apps
                let nativeFocused = try await getNativeFocusedWindow(.cancellable)
                if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
                updateFocusCache(nativeFocused)
            }

            if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            if scope != .layout { try await refresh(scope.pids, missedOutside: missedOutside) }
            // The windows were registered one by one, in an arbitrary order: back to their places of the previous run (when
            // the first windows of the previous run are there: the screen may be locked when MarSpace starts)
            WindowPlacementStore.restoreTilingTreesOfPreviousRunIfPending()
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            if scope != .layout { try await normalizeLayoutReason(scope.pids, missedOutside: missedOutside) }
            // New windows (after the window rules) and windows back from macOS native states
            Workspace.applyFloatingLayouts()
            normalizeContainers()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
            FocusBorderController.shared.update()
            WindowPlacementStore.persistIfChanged()
        } }
    }
    switch res {
        case .success(()): if scope == .everything { lastFullSweep = .now }
        case .failure(let err as CancellationError): check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

/// - Parameter readOnly: The body doesn't change the model (e.g. list-* queries that status bars poll every second).
///   The session only refreshes the native focus (which may register a newly focused window), then runs the body. It
///   skips refreshModel (normalization, garbage collection, callbacks), layout, focus synchronization and the
///   follow-up complete refresh session, and it doesn't cancel a running complete refresh session
@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    readOnly: Bool = false,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if readOnly { return try await lightSession(event, readOnly: true, body: body) }
    // One at a time with the other sessions that change the model; it cancels a heavy one that runs (see SessionQueue)
    return try await SessionQueue.shared.exclusively(event.isStartup ? .startup : .light, "light \(event)") {
        try await lightSession(event, readOnly: false, body: body)
    }
}

@MainActor
private func lightSession<T>(_ event: RefreshSessionEvent, readOnly: Bool, body: @MainActor () async throws -> T) async throws -> T {
    let axCost = SessionAxCost(readOnly ? "query \(event)" : "light \(event)")
    defer { axCost.sessionDidFinish() }
    return try await $refreshSessionEvent.withValue(event) { try await AxStats.$session.withValue(axCost) {
        let nativeFocused = try await getNativeFocusedWindow(.cancellable)
        if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
        updateFocusCache(nativeFocused)
        let focusBefore = globalFocus.windowOrNil

        // Read-only sessions don't cancel a running complete refresh session, they may interleave with it at await
        // points. So they don't normalize the tree, garbage collect or run callbacks
        if readOnly { return try await body() }
        await refreshModel_nonCancellable()
        let result = try await body()
        await refreshModel_nonCancellable()

        let focusAfter = globalFocus.windowOrNil

        updateTrayText()
        SecureInputPanel.shared.refresh()
        if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }
        FocusBorderController.shared.update()
        MoveFlash.shared.flashPending()
        movePointerAlongWithMovedWindow()
        WindowPlacementStore.persistIfChanged()
        if !event.isFocusFollowsMouse {
            // The apps that the session touched (see RefreshScope.afterLightSession)
            scheduleCancellableCompleteRefreshSession(event, scope: .afterLightSession(event, focusBefore: focusBefore, focusAfter: focusAfter))
        }
        return result
    } }
}

enum RunSessionGuard: Sendable {
    case forceRun

    @MainActor
    static var isServerEnabled: Self? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> Self? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(fileId: MyFileId = #myFileId) -> Self {
        .isServerEnabled ?? dieT("server is disabled", fileId: fileId)
    }
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        // The mouse up after a drag can be missed: the global monitor doesn't see it in MarSpace's own windows, and the
        // last session of the drag may be still under way and mark the window again. A window that stayed marked wasn't
        // laid out, and the layout changes weren't persisted until the next click: a restart brought an old layout back
        if currentlyManipulatedWithMouseWindowId != nil && !isLeftMouseButtonDown { endManipulationWithMouse() }
        Workspace.garbageCollectUnusedWorkspaces()
        Workspace.forceAssignWorkspaces()
        Workspace.movePinnedWindowsToVisibleWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        Workspace.applyFloatingLayouts() // E.g. a command moved a window to a floating workspace
        normalizeContainers()
    }
}

/// - Parameter pids: the apps that are asked for their windows, nil: every app. The windows of the others are what
///   MarSpace knows of them
/// - Parameter missedOutside: see ``logMissedChange(_:_:missedOutside:)``
@MainActor
private func refresh(_ pids: Set<pid_t>?, missedOutside: Set<pid_t>?) async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp
        .refreshAllAndGetAliveWindowIds(frontmostAppBundleId: RunningApps.frontmost?.bundleId, only: pids)
    let aliveWindowIds = mapping.values.flatMap(\.keys).toSet()

    // The first closed window caches the world: the others are in it (see cacheClosedWindowIfNeeded), it isn't gathered
    // again for each of them
    var isWorldCached = false
    for window in MacWindow.allWindows where !aliveWindowIds.contains(window.windowId) {
        logMissedChange(window.macApp.pid, "window \(window.windowId) closed", missedOutside: missedOutside)
        window.lifeStatus = .dead
        if window.garbageCollect(skipClosedWindowsCache: isWorldCached) { isWorldCached = true }
    }
    for (app, windows) in mapping {
        for (windowId, lifeStatus) in windows {
            if MacWindow.allWindowsMap[windowId] == nil {
                logMissedChange(app.pid, "window \(windowId) appeared", missedOutside: missedOutside)
            }
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app, lifeStatus: lifeStatus).lifeStatus = lifeStatus
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func refreshObs(_: AXObserver, _ ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let isNativeStateChange = notif == kAXWindowMiniaturizedNotification || notif == kAXWindowDeminiaturizedNotification
    let nativeWindowId = isNativeStateChange ? ax.containingNativeWindowId() : nil
    let pid = ax.pid // The app whose windows may have changed (see RefreshScope)
    Task.startUnstructured { @MainActor in
        FocusBorderController.shared.stackingMayHaveChanged()
        if !TrayMenuModel.shared.isEnabled { return }
        if let nativeWindowId, let pid { // See normalizeLayoutReason
            Window.get(byNativeId: nativeWindowId, pid: pid)?.isNativeStateCheckRequested = true
        }
        if pid == nil { perfLogger.debug("notification \(notif, privacy: .public) without the app: everything is refreshed") }
        scheduleCancellableCompleteRefreshSession(.ax(notif), scope: .app(pid))
    }
}

/// A complete refresh session that asks every app, because the last one is too long ago, found a change of an app that
/// the scoped sessions before it didn't ask (see ``RefreshScope``): the app didn't notify about it. Logged as a notice
/// (kept): the events of that app need a look
///
/// - Parameter missedOutside: the apps that the session was asked for, nil if it wasn't asked for some apps only
@MainActor
func logMissedChange(_ pid: pid_t, _ change: @autoclosure () -> String, missedOutside: Set<pid_t>?) {
    guard let missedOutside, !missedOutside.contains(pid) else { return }
    let app = MacApp.allAppsMap[pid]?.name ?? "\(pid)"
    let change = change()
    perfLogger.notice("missed by the scoped refresh sessions: \(change, privacy: .public) of \(app, privacy: .public)")
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
private func layoutWorkspaces() async throws {
    defer { TrackpadColumnScrolling.update() } // The monitors that show a scrolling workspace, also while disabled
    if !TrayMenuModel.shared.isEnabled {
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    let monitors = globalUnsortedMonitorInfos
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = optimalHideCorner(of: monitor, among: monitors)
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.visibleWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    for workspace in Workspace.all where !workspace.isVisible {
        let monitor = workspace.workspaceMonitorInfo
        let corner = monitorToOptimalHideCorner[monitor.rect.topLeftCorner] ?? .bottomRightCorner
        let tiles = workspace.tileSizesWhileHidden()
        for window in workspace.windowsToHideInCorner {
            try await (window as! MacWindow).hideInCorner(corner, tile: tiles[window], on: monitor) // todo as!
        }
    }
}

/// The corner of the monitor where the windows that aren't shown wait: the one that no other monitor is next to (the
/// window would be seen there)
@MainActor
func optimalHideCorner(of monitor: MonitorInfo, among monitors: [MonitorInfo]) -> OptimalHideCorner {
    let xOff = monitor.width * 0.1
    let yOff = monitor.height * 0.1
    // brc = bottomRightCorner
    let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
    let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
    let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

    // blc = bottomLeftCorner
    let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
    let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
    let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

    func contains(_ monitor: MonitorInfo, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
    let important = 10

    return monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
        monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
        ? .bottomLeftCorner
        : .bottomRightCorner
}

extension Workspace {
    /// The windows that are moved to a corner of the screen while the workspace isn't shown. Not the windows that can't
    /// be moved: a window in macOS fullscreen, on another macOS Space or closed (its tombstone) refuses the position.
    /// A refused frame is sent again by the next layout (see ``Window/setAxFrame(_:_:readBack:)``): every refresh
    /// session made accessibility calls to the app of such a window (Zen in macOS fullscreen: its enhanced user
    /// interface switched off and on, and a position that it refused, for every command and every window event)
    @MainActor
    var windowsToHideInCorner: [Window] {
        allLeafWindowsRecursive.filter { $0.lifeStatus == .alive && !($0.parent is MacosFullscreenWindowsContainer) }
    }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
