import AppKit
import Common
import os

/// The drops of dragged windows next to their previews (see `WindowDrag.finish()`): a notice when the window didn't land
/// where the preview showed it. `log stream --predicate 'subsystem == "com.denizmaral.MarSpace" && category == "drag"'`
let dragLogger = Logger(subsystem: aeroSpaceAppId, category: "drag")

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let nativeWindowId = ax.containingNativeWindowId()
    let notif = notif as String
    let pid = ax.pid
    Task.startUnstructured { @MainActor in
        FocusBorderController.shared.stackingMayHaveChanged()
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        if let nativeWindowId, let pid {
            // The window may be moved or resized by somebody else (the user, the app). See Window.setAxFrame
            Window.get(byNativeId: nativeWindowId, pid: pid)?.invalidateSentFrame()
        }
        guard let nativeWindowId,
              let pid,
              let window = Window.get(byNativeId: nativeWindowId, pid: pid),
              try await isManipulatedWithMouse(window)
        else {
            scheduleCancellableCompleteRefreshSession(.ax(notif), scope: .app(pid))
            return
        }
        FocusBorderController.shared.hideForMouseDrag()
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            try await moveTilingWindow(window)
        case nil: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.visibleWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

/// The tiling window is dragged: it takes its new place when the mouse button is released (see ``WindowDrag``). The layout
/// leaves it alone meanwhile
@MainActor
private func moveTilingWindow(_ window: Window) async throws {
    // The left or the top edge of a window that is resized moves the window too: that's no drag (see resizeWithMouse)
    var isResized = false
    if WindowDrag.shared.window !== window, let size = try await window.getAxSize(.cancellable) {
        isResized = window.isResized(to: size)
    }
    // The last session of a drag may run after the mouse button was released: the drag doesn't start again (see
    // refreshModel_nonCancellable)
    guard isLeftMouseButtonDown else { return }
    windowIsMovedWithMouse(window, isResized: isResized)
}

/// The layout leaves the window alone while the mouse moves it. It keeps its tile (`lastAppliedLayoutPhysicalRect`): a
/// resize of the left or the top edge, which moves the window too, is measured from it (see `resizeWithMouse`)
@MainActor
func windowIsMovedWithMouse(_ window: Window, isResized: Bool) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    if !isResized { WindowDrag.shared.begin(window) }
}

/// A tiling window that the user drags with the mouse. Nothing changes during the drag: the window takes its new place
/// when the mouse button is released (``WindowDrop``, see `endManipulationWithMouse`), and ``DropPreview`` shows the place
/// meanwhile.
///
/// A quick drag swaps the window with the window under the mouse. Once the mouse was held still for a moment
/// (`Config.dragRearrangeDelay`, ¾ of a second by default), the drag rearranges the layout until the button is released:
/// the window goes next to the window under the mouse, or along the whole edge of the workspace near an edge of the
/// screen. No accessibility notification comes while the mouse is still: the mouse is polled during the drag
@MainActor
final class WindowDrag {
    static let shared = WindowDrag()

    /// How far the mouse may move while it's held still: a hand isn't steady
    static let stillDistance: CGFloat = 8
    private static let pollInterval: Duration = .milliseconds(30)

    /// The dragged window
    private(set) var window: Window? = nil
    /// What the release does
    private(set) var drop: WindowDrop? = nil
    /// The places that the preview shows: of the dragged window, and of the window that it swaps with
    private(set) var preview: [Rect] = []
    private(set) var isRearranging = false
    /// Where the mouse came to rest, and when. nil until the first poll of the drag
    private var still: (point: CGPoint, since: ContinuousClock.Instant)? = nil
    /// The tiles of the windows when the preview was made: a layout that changes them during the drag (a window was
    /// closed) changes the preview too
    private var previewedLayout: [Rect?] = []
    /// Where the mouse button is released, in unit tests
    var releasePointerForTest: CGPoint? = nil
    /// Counts the drags: the poll of a drag that is over stops
    private var generation: UInt = 0
    private var poll: Task<(), any Error>? = nil

    private init() {}

    /// The window is dragged. Nothing happens if it's already dragged
    func begin(_ window: Window) {
        guard self.window !== window else { return }
        end()
        self.window = window
        if isUnitTest { return } // The tests move the mouse with update(pointer:at:)
        let generation = generation
        // Not a part of the session that began the drag, which may still hold the queue of the sessions when the drop
        // comes: the session of the drop waits for it (see SessionQueue)
        poll = SessionQueue.$holderId.withValue(nil) { Task.startUnstructured { @MainActor in
            while self.generation == generation { // The singleton
                guard isLeftMouseButtonDown else {
                    // The release wasn't seen (the global monitor doesn't see it over MarSpace's own windows)
                    try await resetManipulatedWithMouseIfPossible()
                    return
                }
                self.update(pointer: mouseLocation, at: .now)
                try await Task.sleep(for: Self.pollInterval)
            }
        } }
    }

    /// Where the mouse is now: the preview shows the drop there
    func update(pointer: CGPoint, at now: ContinuousClock.Instant) {
        guard let window else { return }
        // The monitors as the screens are now. A session refreshes them after the screens changed, but every step of the
        // drag runs a light session that cancels it: the preview would show the layout of the screen before, and the
        // window would land there and move again after the release
        gcMonitors()
        if let still, (pointer - still.point).vectorLength <= Self.stillDistance {
            if now - still.since >= config.dragRearrangeDelay { isRearranging = true } // Until the button is released
        } else {
            still = (pointer, now)
        }
        let drop = WindowDrop.at(pointer, dragging: window, isRearranging: isRearranging)
        let layout = laidOutTiles(window, drop)
        guard drop != self.drop || layout != previewedLayout else { return }
        self.drop = drop
        previewedLayout = layout
        preview = drop?.tiles(of: window) ?? []
        DropPreview.shared.show(preview, isSwap: drop?.isSwap == true, below: window)
    }

    /// The tiles of the workspaces that the drop changes, as the last layout left them, and their screens. Cheap: no
    /// layout is tried
    private func laidOutTiles(_ window: Window, _ drop: WindowDrop?) -> [Rect?] {
        guard let drop else { return [] }
        let workspaces = [window.nodeWorkspace, drop.workspace].compactMap { $0 }
        return (workspaces.first == workspaces.last ? Array(workspaces.prefix(1)) : workspaces).flatMap { workspace in
            let tiles = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.lastAppliedLayoutVirtualRect)
            return [workspace.workspaceMonitorInfo.visibleRect] + tiles
        }
    }

    /// The mouse button was released: the window takes its place there. The mouse may have moved since the last poll
    /// (back onto the tile of the window, out of the workspaces), so the place is where the mouse is now, with the mode
    /// that the preview showed. Only a drag that a poll saw while the button was down (``still``) drops the window: the
    /// last session of a drag may start one after the release
    func finish() {
        guard let window else { return }
        let pointer = isUnitTest ? releasePointerForTest : mouseLocation
        let drop = still == nil ? nil : pointer.map { WindowDrop.at($0, dragging: window, isRearranging: isRearranging) } ?? drop
        let preview = drop == self.drop ? preview.first : nil // Released over another place than the last poll saw
        end()
        guard let drop, drop.canApply(to: window) else { return }
        drop.apply(to: window)
        MoveFlash.shared.flashAfterLayout(drop.movedWindows(window))
        logLanding(of: window, drop, preview: preview)
    }

    /// Where the window is after the sessions that follow the release, next to the preview
    private func logLanding(of window: Window, _ drop: WindowDrop, preview: Rect?) {
        if isUnitTest { return }
        Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .seconds(1))
            let tile = window.lastAppliedLayoutPhysicalRect
            let message = "drop \(drop.logDescription) of \(window.windowId.description): preview \(String(describing: preview)), " +
                "tile \(String(describing: tile)), frame \(String(describing: window.observedFrame)), " +
                "screen \(String(describing: window.nodeMonitorInfo?.visibleRect))"
            if preview == nil || tile == preview {
                dragLogger.debug("\(message, privacy: .public)")
            } else {
                dragLogger.notice("not where the preview showed it: \(message, privacy: .public)")
            }
        }
    }

    /// The drag is over, or it's a resize after all
    func end() {
        generation &+= 1
        poll = nil // It stops by itself, also if it's running the session after a release that it saw
        window = nil
        drop = nil
        preview = []
        isRearranging = false
        still = nil
        previewedLayout = []
        releasePointerForTest = nil
        DropPreview.shared.hide()
    }
}

extension Window {
    /// The window has another size than the one it had after the last layout: it's resized, not moved
    @MainActor
    func isResized(to size: CGSize) -> Bool {
        guard let before = observedFrame?.size else { return false }
        return abs(size.width - before.width) >= 1 || abs(size.height - before.height) >= 1
    }
}

@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) {
    if window1 == window2 { return }

    let binding2 = window2.unbindFromParent()
    let binding1 = window1.unbindFromParent()

    window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
    window1.swapDwindleSplitAnchors(with: window2)
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles, .scrolling:
                tree.inhabitedChildren.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentInhabitedChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
