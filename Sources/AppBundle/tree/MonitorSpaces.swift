import AppKit
import Common

/// What a monitor shows: its desktop, or the Space of a window in macOS fullscreen. Such a window has a Space of its own:
/// its workspace is the visible workspace of the monitor while the Space is shown, but the desktop isn't. The pinned
/// windows stay on the desktop with their workspace (see ``Workspace/movePinnedWindowsToVisibleWorkspaces()``)
enum MonitorSpace: Equatable {
    case desktop
    case macosFullscreen(of: Workspace)

    /// macOS doesn't tell which Space a monitor shows, the focus does: a window in macOS fullscreen has it, its Space is
    /// shown
    @MainActor init(of focus: LiveFocus) {
        self = focus.windowOrNil?.parent is MacosFullscreenWindowsContainer ? .macosFullscreen(of: focus.workspace) : .desktop
    }
}

extension MonitorInfo {
    /// The monitor of the focus shows what the focus shows. Another monitor shows what it showed when the focus left it
    /// (see ``setFocus(to:)``), until MarSpace shows another workspace there
    @MainActor var space: MonitorSpace {
        let focus = globalFocus
        return focus.workspace.workspaceMonitorInfo.rect.topLeftCorner == rect.topLeftCorner
            ? MonitorSpace(of: focus)
            : toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate().spaceWhenTheFocusLeft
    }
}
