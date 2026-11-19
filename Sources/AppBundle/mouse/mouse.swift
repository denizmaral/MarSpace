import AppKit
import Common

@MainActor var currentlyManipulatedWithMouseWindowId: OpaqueWindowId? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }

/// One of the windows of MarSpace (`ownWindowNumbers`) is the front most window at `location` (top left origin): one behind
/// the windows of other apps doesn't count. One query of the window server, no accessibility calls; any thread
func isOwnWindowInFront(at location: CGPoint, ownWindowNumbers own: Set<Int>) -> Bool {
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in infos { // Front to back
        guard let number = info[kCGWindowNumber as String] as? Int,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(location)
        else { continue }
        if own.contains(number) { return true }
        // Another app's window in the normal layer is in front. Other layers (the menu bar, the Dock) and MarSpace's
        // other windows (the focus border) don't decide
        if info[kCGWindowOwnerPID as String] as? Int32 != ownPid, info[kCGWindowLayer as String] as? Int == 0 { return false }
    }
    return true // Not in the list (yet): as before, MarSpace's window is under the mouse
}
