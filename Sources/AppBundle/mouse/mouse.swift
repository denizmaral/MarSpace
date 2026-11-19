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

/// One of the windows of MarSpace (`ownWindowNumbers`: the ones at `location`, top left origin) is in front there: one behind
/// the windows of other apps doesn't count. The window server lists only the windows above each of them (no accessibility
/// calls, any thread)
func isOwnWindowInFront(at location: CGPoint, ownWindowNumbers own: some Sequence<Int>) -> Bool {
    let ownPid = ProcessInfo.processInfo.processIdentifier
    return own.contains { number in
        // AppKit gives some windows a number that isn't a window of the window server (the button of the menu bar has a
        // negative one): nothing to ask about, as before it's MarSpace's window under the mouse
        guard let windowId = CGWindowID(exactly: number), windowId != kCGNullWindowID else { return true }
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowId) as? [[String: Any]] ?? []
        return isInFront(at: location, windowsAbove: infos.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return nil }
            return WindowAbove(isOwn: info[kCGWindowOwnerPID as String] as? Int32 == ownPid, layer: layer, bounds: bounds)
        })
    }
}

/// A window that the window server shows above a window of MarSpace
struct WindowAbove: Equatable {
    /// Of MarSpace (e.g. the focus border)
    let isOwn: Bool
    let layer: Int
    /// Top left origin
    let bounds: CGRect
}

/// The window of MarSpace with `windowsAbove` is in front at `location`: no window of another app in the normal layer covers
/// it there. Other layers (the menu bar, the Dock) and MarSpace's other windows (the focus border) don't cover it
func isInFront(at location: CGPoint, windowsAbove: [WindowAbove]) -> Bool {
    !windowsAbove.contains { !$0.isOwn && $0.layer == 0 && $0.bounds.contains(location) }
}
