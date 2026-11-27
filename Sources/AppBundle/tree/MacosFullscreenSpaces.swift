import AppKit
import Common

/// The monitors that show the Space of a window in macOS fullscreen, instead of their desktop. A window in macOS
/// fullscreen has a Space of its own: its workspace is the visible workspace of its monitor while the Space is shown, but
/// the desktop of the monitor isn't. The pinned windows stay on the desktop with their workspace (see
/// ``Workspace/movePinnedWindowsToVisibleWorkspaces()``).
///
/// macOS doesn't tell which Space a monitor shows. The focus does: a window in macOS fullscreen got it, the monitor shows
/// its Space. It shows its desktop again when a window or an empty workspace of the monitor got the focus, or another
/// workspace is visible there. The focus may go to another monitor meanwhile: the Space is still shown
struct MacosFullscreenSpaces: Equatable {
    /// The workspace of the window in macOS fullscreen, by the top left corner of its monitor
    private var workspaces: [CGPoint: String] = [:]

    /// - Parameters:
    ///   - monitor: the top left corner of the monitor of the focus
    ///   - visibleWorkspaces: the visible workspace of every monitor, by its top left corner
    mutating func focusChanged(to workspace: String, monitor: CGPoint, isMacosFullscreen: Bool, visibleWorkspaces: [CGPoint: String]) {
        workspaces[monitor] = isMacosFullscreen ? workspace : nil
        workspaces = workspaces.filter { monitor, workspace in visibleWorkspaces[monitor] == workspace }
    }

    /// The monitor of the workspace shows the Space of its window in macOS fullscreen
    func isShown(_ workspace: String) -> Bool { workspaces.values.contains(workspace) }
}

@MainActor private(set) var macosFullscreenSpaces = MacosFullscreenSpaces()

/// Called with every focus that a refresh session sees, see ``MacosFullscreenSpaces``
@MainActor func updateMacosFullscreenSpaces() {
    let focus = globalFocus
    macosFullscreenSpaces.focusChanged(
        to: focus.workspace.name,
        monitor: focus.workspace.workspaceMonitorInfo.rect.topLeftCorner,
        isMacosFullscreen: focus.windowOrNil?.parent is MacosFullscreenWindowsContainer,
        visibleWorkspaces: Dictionary(globalUnsortedMonitorInfos.map { ($0.rect.topLeftCorner, $0.visibleWorkspace.name) }) { first, _ in first },
    )
}
