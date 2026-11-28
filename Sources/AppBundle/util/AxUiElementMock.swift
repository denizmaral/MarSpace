import AppKit
import Common

/// Alternative name: AttrAddressibleStorage
protocol AxUiElementMock {
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T?
    /// Several attributes at once: one round trip to the app for an `AXUIElement` (see `AxStats`). Each one is nil if
    /// the element doesn't have it, as with `get(_:)`
    func getAll<each Attr: ReadableAttr>(_ attrs: repeat each Attr) -> (repeat (each Attr).T?)
    func containingNativeWindowId() -> CGWindowID?
}

extension AxUiElementMock {
    func getAll<each Attr: ReadableAttr>(_ attrs: repeat each Attr) -> (repeat (each Attr).T?) { (repeat get(each attrs)) }

    var cast: AXUIElement { self as! AXUIElement }

    /// The window that the sheet is attached to (also a sheet over a sheet). nil: the element isn't a sheet, or it
    /// doesn't tell its window.
    ///
    /// A sheet (a file picker, "Do you want to keep the changes?") is a window of its own for the window server, and its app
    /// reports it as its focused window while it's open. But it's a part of the window that it's attached to: it moves
    /// with it, and the app doesn't list it among its windows. The focused window and the window under the mouse are the
    /// window with the sheet. Taken for itself, the sheet is a window that MarSpace doesn't manage: an app that was
    /// activated while its sheet was open (the Dock, cmd-tab, a notification) didn't get the focus of MarSpace, its
    /// window stayed in the corner of the screen with the workspace that wasn't shown
    var windowOfSheet: WindowIdAndAxUiElementMock? {
        guard get(Ax.roleAttr) == kAXSheetRole else { return nil }
        var element: any AxUiElementMock = self
        for _ in 0 ..< 8 { // No app nests sheets that deep. Not forever, whatever the app reports
            guard let parent = element.get(Ax.parentAttr), let role = parent.get(Ax.roleAttr) else { return nil }
            if role == kAXWindowRole { return parent.containingNativeWindowId().map { ($0, parent) } }
            guard role == kAXSheetRole else { return nil }
            element = parent
        }
        return nil
    }

    /// The focused window of the app (the element is the app): the focus in a sheet is the focus of the window that the
    /// sheet is attached to. A sheet that doesn't tell its window stays the focused window, as before
    var focusedWindowOfApp: WindowIdAndAxUiElementMock? {
        self.get(Ax.focusedWindowAttr).map { $0.ax.windowOfSheet ?? $0 }
    }
}
