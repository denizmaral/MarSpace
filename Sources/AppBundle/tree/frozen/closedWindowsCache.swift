import AppKit
import Common

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks AeroSpace into thinking that all windows were closed.
/// That's why every time a window dies AeroSpace caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, AeroSpace could restore windows to where they were
@MainActor private var closedWindowsCache = FrozenWorld(monitors: [], windowIds: [])

struct FrozenMonitor {
    let visibleWorkspace: String
    let topLeftCorner: CGPoint
    let workspaces: [FrozenWorkspace]

    @MainActor init(_ monitor: Monitor) {
        self.topLeftCorner = monitor.info.rect.topLeftCorner
        self.workspaces = monitor.getWorkspacesContainerOrCreate().children.map { FrozenWorkspace($0 as! Workspace) }
        self.visibleWorkspace = monitor.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: monitor).name
    }
}

struct FrozenWorkspace {
    let name: String
    /// Also the places of the floating windows that remember their tiles (see ``TilingSlot``): the restore builds new
    /// containers, the places that the windows remember are in the old ones. nil: the workspace has no tiling windows
    let tilingTree: TilingTreeSnapshot<OpaqueWindowId>?
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [OpaqueWindowId]

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        tilingTree = workspace.tilingTreeSnapshot { $0.windowId }
        floatingWindows = workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            (workspace.macOsNativeHiddenAppsWindowsContainer.children + workspace.macOsNativeFullscreenWindowsContainer.children)
                .map { ($0 as! Window).windowId }
    }
}

/// A floating window, and what it knows about itself. A window that macOS reported gone and that comes back is registered
/// again as a new window, it gets that back: a popped out window came back floating, but not pinned and popped out
struct FrozenWindow {
    let id: OpaqueWindowId
    /// The window when the world was frozen. Another one with the same id was registered again
    private weak var window: Window?
    private let ownState: FloatingOwnState
    private let lastPoppedOutFrame: Rect?
    private let isFloatedByWorkspaceLayout: Bool

    @MainActor init(_ window: Window) {
        id = window.windowId
        self.window = window
        ownState = window.floatingOwnState
        lastPoppedOutFrame = window.lastPoppedOutFrame
        isFloatedByWorkspaceLayout = window.isFloatedByWorkspaceLayout
    }

    /// The window with the id, with what it knew when the world was frozen
    @MainActor func restoredWindow() -> Window? {
        guard let window = Window.get(byId: id) else { return nil }
        if window !== self.window { // Registered again: it knows nothing
            window.floatingOwnState = ownState
            window.lastPoppedOutFrame = lastPoppedOutFrame
            window.isFloatedByWorkspaceLayout = isFloatedByWorkspaceLayout
        }
        return window
    }
}

@MainActor func cacheClosedWindowIfNeeded() {
    let allWs = Workspace.all
    let allWindowIds = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
    if allWindowIds.isSubset(of: closedWindowsCache.windowIds) {
        return // already cached
    }
    closedWindowsCache = FrozenWorld(
        monitors: Monitor.all.map(FrozenMonitor.init),
        windowIds: allWindowIds,
    )
}

@MainActor func restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    if !closedWindowsCache.windowIds.contains(newlyDetectedWindow.windowId) {
        return false
    }
    let monitors = globalUnsortedMonitorInfos
    let topLeftCornerToMonitorInfo = monitors.grouped { $0.rect.topLeftCorner }

    // The floating windows first: the tree of a workspace has the places of floating windows of the others too (a pinned
    // window came along to another workspace)
    for monitor in closedWindowsCache.monitors {
        for frozenWorkspace in monitor.workspaces {
            let workspace = Workspace.get(byName: frozenWorkspace.name)
            _ = topLeftCornerToMonitorInfo[monitor.topLeftCorner]?
                .singleOrNil()?
                .bindWorkspace(workspace)
            for frozenWindow in frozenWorkspace.floatingWindows {
                frozenWindow.restoredWindow()?.bindAsFloatingWindow(to: workspace)
            }
            for windowId in frozenWorkspace.macosUnconventionalWindows { // Will get fixed by normalizations
                Window.get(byId: windowId)?.bindAsFloatingWindow(to: workspace)
            }
        }
    }
    // Before the roots are unbound
    let windows = Dictionary(Workspace.all.flatMap(\.allLeafWindowsRecursive).map { ($0.windowId, $0) }) { first, _ in first }
    for monitor in closedWindowsCache.monitors {
        for frozenWorkspace in monitor.workspaces {
            let workspace = Workspace.get(byName: frozenWorkspace.name)
            let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
            let potentialOrphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()
            if let tree = frozenWorkspace.tilingTree { workspace.restoreFrozenTilingTree(tree, windows) }
            for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
                try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
            }
        }

        _ = topLeftCornerToMonitorInfo[monitor.topLeftCorner]?
            .singleOrNil()?
            .setVisibleWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
    return true
}

// Consider the following case:
// 1. Close window
// 2. The previous step lead to caching the whole world
// 3. Change something in the layout
// 4. Lock the screen
// 5. The cache won't be updated because all alive windows are already cached
// 6. Unlock the screen
// 7. The wrong cache is used
//
// That's why we have to reset the cache every time layout changes. The layout can only be changed by running commands
// and with mouse manipulations
@MainActor func resetClosedWindowsCache() {
    closedWindowsCache = FrozenWorld(monitors: [], windowIds: [])
}
