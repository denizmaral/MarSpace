import AppKit
import Common

/// Where the mouse pointer is on a window, as a part of its frame. With focus-follows-mouse, the pointer goes along with
/// the focused window that a command moves elsewhere (`swap`, `move`) if it was over the window: otherwise the first move
/// of the mouse afterwards would focus the window that took the place under the pointer
struct PointerOnWindow {
    private let window: Window
    private let fraction: CGPoint
    /// Where the pointer was: if the user moves it meanwhile, it stays where they put it
    private let location: CGPoint

    /// nil if the pointer isn't over the window, the window isn't focused, or the focus doesn't follow the mouse
    @MainActor
    init?(_ window: Window) {
        guard config.focusFollowsMouse, window == globalFocus.windowOrNil,
              let frame = window.observedFrame ?? window.lastAppliedLayoutPhysicalRect,
              frame.width > 0, frame.height > 0
        else { return nil }
        let mouse = mouseLocation
        guard frame.contains(mouse) else { return nil }
        self.window = window
        location = mouse
        fraction = CGPoint(x: (mouse.x - frame.minX) / frame.width, y: (mouse.y - frame.minY) / frame.height)
    }

    /// The pointer goes to the same part of the window when the refresh session has laid it out (see
    /// ``movePointerAlongWithMovedWindow()``)
    @MainActor
    func followAfterLayout() { pendingPointerMove = self }

    @MainActor
    fileprivate func move() {
        let mouse = mouseLocation
        guard !isUnitTest, window == globalFocus.windowOrNil,
              abs(mouse.x - location.x) <= 1, abs(mouse.y - location.y) <= 1,
              let frame = window.observedFrame ?? window.lastAppliedLayoutPhysicalRect,
              !frame.contains(mouse)
        else { return }
        let point = CGPoint(x: frame.minX + fraction.x * frame.width, y: frame.minY + fraction.y * frame.height)
        // A mouse move, like the move-mouse command: focus-follows-mouse sees the pointer over the focused window
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

@MainActor private var pendingPointerMove: PointerOnWindow? = nil

/// At the end of a refresh session: the moved window is where the layout put it
@MainActor
func movePointerAlongWithMovedWindow() {
    guard let pointer = pendingPointerMove else { return }
    pendingPointerMove = nil
    pointer.move()
}
