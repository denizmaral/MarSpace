@testable import AppBundle
import AppKit
import Testing

/// A sheet is a part of the window that it's attached to. Its app reports the sheet as its focused window, the focus of
/// MarSpace is the window. See windowOfSheet
@MainActor
@Suite
struct SheetTest {
    private static let window: [String: Any] = ["AXRole": kAXWindowRole, "AXSubrole": kAXStandardWindowSubrole, "Aero.windowId_native": 10506]

    private func element(_ raw: [String: Any]) -> [String: Json] { Json.newOrDieRecursive(raw).asDictOrDie }

    /// The file picker of a chat app: the app is activated from another workspace while the picker is open
    @Test func testSheetBelongsToItsWindow() {
        let sheet = element(["AXRole": kAXSheetRole, "AXParent": Self.window, "Aero.windowId_native": 11312])
        assertEquals(sheet.windowOfSheet?.windowId, 10506)
    }

    /// E.g. "Replace the file?" over a save sheet
    @Test func testSheetOverSheetBelongsToTheWindow() {
        let save: [String: Any] = ["AXRole": kAXSheetRole, "AXParent": Self.window, "Aero.windowId_native": 11312]
        let alert = element(["AXRole": kAXSheetRole, "AXParent": save, "Aero.windowId_native": 11313])
        assertEquals(alert.windowOfSheet?.windowId, 10506)
    }

    /// What a refresh session takes as the focused window of the app (MacApp.getFocusedWindow)
    @Test func testFocusInSheetIsTheFocusOfItsWindow() {
        let sheet: [String: Any] = ["AXRole": kAXSheetRole, "AXParent": Self.window, "Aero.windowId_native": 11312]
        assertEquals(element(["AXFocusedWindow": sheet]).focusedWindowOfApp?.windowId, 10506)
        assertEquals(element(["AXFocusedWindow": Self.window]).focusedWindowOfApp?.windowId, 10506)
        // A sheet that doesn't tell its window is the focused window, as before
        let alone: [String: Any] = ["AXRole": kAXSheetRole, "Aero.windowId_native": 11312]
        assertEquals(element(["AXFocusedWindow": alone]).focusedWindowOfApp?.windowId, 11312)
        assertNil(element([:]).focusedWindowOfApp?.windowId) // E.g. an app without windows
    }

    @Test func testWindowIsNotASheet() {
        assertNil(element(Self.window).windowOfSheet?.windowId)
        // A panel of its own (the "Open" panel of an app without a window): its parent is the app
        let panel = element(["AXRole": kAXWindowRole, "AXSubrole": kAXDialogSubrole, "AXParent": ["AXRole": kAXApplicationRole], "Aero.windowId_native": 7])
        assertNil(panel.windowOfSheet?.windowId)
    }

    /// The sheet stays what it is for MarSpace, as before
    @Test func testSheetThatDoesNotTellItsWindow() {
        assertNil(element(["AXRole": kAXSheetRole, "Aero.windowId_native": 11312]).windowOfSheet?.windowId)
        let ofTheApp = element(["AXRole": kAXSheetRole, "AXParent": ["AXRole": kAXApplicationRole], "Aero.windowId_native": 11312])
        assertNil(ofTheApp.windowOfSheet?.windowId)
    }
}
