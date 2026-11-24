@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// A tiling window that is dragged with the mouse takes its new place when the button is released, and a preview shows
/// the place meanwhile (see WindowDrag). A quick drag swaps it with the window under the mouse, a drag that held the mouse
/// still for a moment (¾ of a second by default, Settings › General) rearranges the layout. The preview is the tile that
/// the window gets: the drop is tried on the trees and taken back, nobody sees it. The test monitor is 1920x1080, with
/// the owner's settings: both normalizations, 10 pt gaps
@MainActor
@Suite(.serializedGlobally)
struct WindowDragTest {
    init() {
        setUpWorkspacesForTests()
        // The normalizations destroy containers and flip orientations: the drop and its preview must agree on it
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 10, bottom: 10, top: 10, right: 10))
    }

    private let start = ContinuousClock.now
    private var drag: WindowDrag { WindowDrag.shared }

    private func shownWorkspace() -> Workspace {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        return workspace
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Rect {
        Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    }

    /// What moveTilingWindow does when a drag starts
    private func startDragging(_ window: Window) {
        windowIsMovedWithMouse(window, isResized: false)
        #expect(drag.window === window)
    }

    /// The mouse is held still at `point` long enough: the drag rearranges
    private func rearrange(at point: CGPoint) {
        drag.update(pointer: point, at: start)
        drag.update(pointer: point, at: start + config.dragRearrangeDelay)
        #expect(drag.isRearranging)
    }

    /// What the session after the mouse up does: the manipulation ends when the model is refreshed (the button is up in
    /// tests), the tree is normalized and laid out
    private func release(_ workspace: Workspace) async throws {
        await refreshModel_nonCancellable()
        assertEquals(currentlyManipulatedWithMouseWindowId, nil)
        try await workspace.layoutWorkspace()
    }

    /// A point in `window`'s tile, in parts of its width and height from its top left corner
    private func point(in window: Window, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let tile = window.lastAppliedLayoutVirtualRect.orDie()
        return CGPoint(x: tile.minX + tile.width * x, y: tile.minY + tile.height * y)
    }

    // MARK: Swap

    @Test func testQuickDragSwapsAndShowsBothPlaces() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let windows = (1 ... 3).map { TestWindow.new(id: OpaqueWindowId($0), parent: root) }
        try await workspace.layoutWorkspace()
        let tiles = windows.map(\.lastAppliedLayoutPhysicalRect)

        startDragging(windows[0])
        drag.update(pointer: point(in: windows[2], 0.5, 0.5), at: start)
        #expect(drag.drop == .swap(windows[2]))
        #expect(!drag.isRearranging)
        // Where the dragged window goes, and where the other one goes
        assertEquals(drag.preview, [tiles[2].orDie(), tiles[0].orDie()])
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)])) // Nothing changed yet

        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        assertEquals(windows[0].lastAppliedLayoutPhysicalRect, tiles[2])
        assertEquals(windows[2].lastAppliedLayoutPhysicalRect, tiles[0])
        assertEquals(drag.window, nil)
    }

    /// A drag that keeps moving never rearranges, however long it takes
    @Test func testDragThatKeepsMovingStaysASwap() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        for step in 0 ..< 10 {
            let x = CGFloat(step) * (WindowDrag.stillDistance + 1)
            drag.update(pointer: point(in: second, 0.1, 0.5) + CGPoint(x: x, y: 0), at: start + .milliseconds(300 * step))
        }
        #expect(!drag.isRearranging)
        #expect(drag.drop == .swap(second))
    }

    @Test func testHoldingTheMouseStillRearrangesUntilTheRelease() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        let resting = point(in: third, 0.1, 0.5)
        drag.update(pointer: resting, at: start)
        // A hand isn't steady
        drag.update(pointer: resting + CGPoint(x: 5, y: 0), at: start + .milliseconds(400))
        #expect(drag.drop == .swap(third))
        drag.update(pointer: resting + CGPoint(x: 3, y: 2), at: start + config.dragRearrangeDelay)
        #expect(drag.isRearranging)
        #expect(drag.drop == .beside(third, .left))
        // It rearranges until the release: the side follows the mouse
        drag.update(pointer: point(in: third, 0.7, 0.5), at: start + config.dragRearrangeDelay + .milliseconds(100))
        #expect(drag.drop == .beside(third, .right))
        drag.update(pointer: point(in: third, 0.5, 0.7), at: start + config.dragRearrangeDelay + .milliseconds(200))
        #expect(drag.drop == .beside(third, .down))
        // Near the edge of the screen: along the whole edge of the workspace
        drag.update(pointer: point(in: third, 0.95, 0.5), at: start + config.dragRearrangeDelay + .milliseconds(300))
        #expect(drag.drop == .edge(workspace, .right))
    }

    /// The settings choose how long the mouse rests before the drag rearranges
    @Test func testHowLongTheMouseRestsIsASetting() async throws {
        var settings = Settings()
        assertEquals(settings.compile().config.dragRearrangeDelay, .milliseconds(750))
        settings.general.dragRearrangeDelay = 400
        config = settings.compile().config
        assertEquals(config.dragRearrangeDelay, .milliseconds(400))
        settings.general.dragRearrangeDelay = 10 // Too short to tell from a quick drag
        assertEquals(settings.compile().config.dragRearrangeDelay, .milliseconds(250))

        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        startDragging(first)
        let resting = point(in: second, 0.3, 0.5)
        drag.update(pointer: resting, at: start)
        drag.update(pointer: resting, at: start + .milliseconds(399))
        #expect(!drag.isRearranging)
        drag.update(pointer: resting, at: start + .milliseconds(400))
        #expect(drag.drop == .beside(second, .left))
    }

    /// A move whose first step changed the size of the window is a resize of its left or top edge: the size that it had after
    /// the last layout tells (see moveTilingWindow)
    @Test func testFirstStepThatChangesTheSizeIsAResize() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let window = TestWindow.new(id: 1, parent: root)
        #expect(!window.isResized(to: CGSize(width: 500, height: 500))) // Never laid out: nothing to tell
        try await workspace.layoutWorkspace()
        let size = window.observedFrame.orDie().size
        #expect(!window.isResized(to: size))
        #expect(!window.isResized(to: CGSize(width: size.width + 0.5, height: size.height - 0.5))) // Rounding
        #expect(window.isResized(to: CGSize(width: size.width + 1, height: size.height)))
        #expect(window.isResized(to: CGSize(width: size.width, height: size.height - 1)))
    }

    @Test func testReleaseOverItsOwnTileChangesNothing() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        let tile = first.lastAppliedLayoutPhysicalRect

        startDragging(first)
        drag.update(pointer: point(in: second, 0.5, 0.5), at: start)
        drag.update(pointer: point(in: first, 0.5, 0.5), at: start + .milliseconds(100)) // Changed its mind
        assertEquals(drag.drop, nil)
        assertEquals(drag.preview, [])
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(first.lastAppliedLayoutPhysicalRect, tile)
    }

    /// The last session of a drag may mark the window again after the release: no drop is made that the mouse didn't show
    @Test func testDragThatStartsAfterTheReleaseDropsNothing() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        startDragging(first)
        drag.update(pointer: point(in: second, 0.5, 0.5), at: start)
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))

        startDragging(first)
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    /// The mouse may move between two polls: the window goes where the mouse is when the button is released
    @Test func testReleaseBetweenTwoPollsDropsWhereTheMouseIs() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        drag.update(pointer: point(in: second, 0.5, 0.5), at: start)
        #expect(drag.drop == .swap(second))
        drag.releasePointerForTest = point(in: first, 0.5, 0.5) // Back on its own tile
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))

        startDragging(first)
        drag.update(pointer: point(in: first, 0.5, 0.5), at: start)
        assertEquals(drag.drop, nil)
        drag.releasePointerForTest = point(in: second, 0.5, 0.5)
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
    }

    /// A layout during the drag that changes the tiles (a window was closed) changes the preview
    @Test func testPreviewFollowsALayoutDuringTheDrag() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        let pointer = point(in: third, 0.5, 0.5)
        drag.update(pointer: pointer, at: start)
        assertEquals(drag.preview, [third.lastAppliedLayoutPhysicalRect.orDie(), first.lastAppliedLayoutPhysicalRect.orDie()])

        second.closeAxWindow()
        try await workspace.layoutWorkspace()
        drag.update(pointer: pointer, at: start + .milliseconds(30))
        #expect(drag.drop == .swap(third))
        assertEquals(drag.preview, [rect(965, 10, 945, 1059), rect(10, 10, 945, 1059)])
    }

    /// The screen changed its size (the external display took the place of the built-in one), and no session refreshed the
    /// monitors yet: the steps of the drag run light sessions, which cancel the session that would. The preview shows
    /// the layout of the screen as it is now, and the window stays where the preview showed it after the sessions that
    /// follow the release
    @Test func testPreviewAfterTheScreenChangedItsSize() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        setTestMonitorSize(CGSize(width: 2560, height: 1707))
        startDragging(first)
        drag.update(pointer: CGPoint(x: 1800, y: 500), at: start) // The third window, on the screen before and after
        #expect(drag.drop == .swap(third))
        let preview = drag.preview
        assertEquals(preview.first, rect(1708.3333333333333, 10, 841.6666666666666, 1686))

        try await release(workspace)
        gcMonitors() // The complete refresh session that follows
        try await workspace.layoutWorkspace()
        assertEquals(first.lastAppliedLayoutPhysicalRect, preview.first)

        // The screen changes during the drag while the mouse rests: the preview follows
        startDragging(first)
        drag.update(pointer: CGPoint(x: 300, y: 500), at: start)
        #expect(drag.drop == .swap(third))
        setTestMonitorSize(CGSize(width: 1920, height: 1080))
        drag.update(pointer: CGPoint(x: 300, y: 500), at: start + .milliseconds(30))
        assertEquals(drag.preview.first, rect(10, 10, 628.3333333333334, 1059))
    }

    // MARK: Rearrange

    /// The window takes half of the tile of the window: the window gives half of its weight, the others keep their tiles
    @Test func testBesideAWindowTakesHalfOfItsTile() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        rearrange(at: point(in: third, 0.1, 0.5))
        #expect(drag.drop == .beside(third, .left))
        // The first window leaves: the second and the third share the screen, the first takes the left half of the third
        assertEquals(drag.preview, [rect(965, 10, 465, 1059)])
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))

        let preview = drag.preview
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1), .window(3)]))
        assertEquals(preview, [first.lastAppliedLayoutPhysicalRect.orDie()])
        assertEquals(first.lastAppliedLayoutPhysicalRect, rect(965, 10, 465, 1059))
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(10, 10, 945, 1059))
        assertEquals(third.lastAppliedLayoutPhysicalRect, rect(1440, 10, 470, 1059))
        // It gives the half back when the window leaves again (like a dwindle split)
        #expect(first.dwindleSplitAnchor === third)
    }

    /// Across its container the window shares the tile in a new container
    @Test func testBesideAcrossTheContainerSharesTheTile() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        rearrange(at: point(in: second, 0.5, 0.1))
        #expect(drag.drop == .beside(second, .up))
        let preview = drag.preview
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))
        assertEquals(preview, [first.lastAppliedLayoutPhysicalRect.orDie()])
        assertEquals(first.lastAppliedLayoutPhysicalRect, rect(10, 10, 945, 524.5))
        _ = third
    }

    /// The container that the window leaves is flattened first: the window that is left in it is in the root then
    @Test func testContainerThatTheWindowLeavesIsFlattenedFirst() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 1, parent: column)
        let second = TestWindow.new(id: 2, parent: column)
        TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(first)
        rearrange(at: point(in: second, 0.9, 0.5))
        #expect(drag.drop == .beside(second, .right))
        let preview = drag.preview
        try await release(workspace)
        // Not a column of 2 and 1 that the normalization flips into a row
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1), .window(3)]))
        assertEquals(preview, [first.lastAppliedLayoutPhysicalRect.orDie()])
        // The first window took half of the tile of the second one
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(10, 10, 470, 1059))
        assertEquals(first.lastAppliedLayoutPhysicalRect, rect(490, 10, 465, 1059))
    }

    /// Near an edge of the screen the window goes along the whole edge of the workspace, also over its own tile
    @Test func testEdgeOfTheScreenTakesTheWholeEdge() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)
        try await workspace.layoutWorkspace()

        startDragging(second)
        rearrange(at: CGPoint(x: 960, y: 40))
        #expect(drag.drop == .edge(workspace, .up))
        let preview = drag.preview
        try await release(workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .h_tiles([.window(1), .window(3)])]))
        assertEquals(preview, [second.lastAppliedLayoutPhysicalRect.orDie()])
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(10, 10, 1900, 524.5))

        // The root takes the orientation of the row that is left when the window leaves (the normalization): along the
        // root, a column at the left of all
        startDragging(second)
        rearrange(at: CGPoint(x: 40, y: 900))
        #expect(drag.drop == .edge(workspace, .left))
        let left = drag.preview
        try await release(workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(1), .window(3)]))
        assertEquals(left, [second.lastAppliedLayoutPhysicalRect.orDie()])
    }

    /// A window that already lies along the whole edge stays where it is: neither its place nor its weight changes
    @Test func testWindowAlongTheEdgeStaysThere() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root, adaptiveWeight: 0.6)
        TestWindow.new(id: 2, parent: root, adaptiveWeight: 1.4)
        try await workspace.layoutWorkspace()
        let tile = first.lastAppliedLayoutPhysicalRect

        startDragging(first)
        rearrange(at: CGPoint(x: 40, y: 500))
        assertEquals(drag.drop, nil)
        assertEquals(drag.preview, [])
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(first.getWeight(.h), 0.6)
        assertEquals(first.lastAppliedLayoutPhysicalRect, tile)
    }

    /// The left or the top edge of a window that is resized moves the window too: that's no drag, and the tile next to it
    /// follows the edge every step of the way (the window keeps its tile while it's resized)
    @Test func testResizeOfTheLeftEdgeIsNoDrag() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(965, 10, 945, 1059))

        windowIsMovedWithMouse(second, isResized: true)
        assertEquals(drag.window, nil)
        second.axRectForTest = rect(865, 10, 1045, 1059)
        try await resizeWithMouse(second)
        second.axRectForTest = rect(815, 10, 1095, 1059)
        try await resizeWithMouse(second)
        try await release(workspace)
        let rounded = { (rect: Rect?) in rect.map { [$0.minX, $0.minY, $0.width, $0.height].map { ($0 * 100).rounded() / 100 } } }
        assertEquals(rounded(first.lastAppliedLayoutPhysicalRect), [10, 10, 795, 1059])
        assertEquals(rounded(second.lastAppliedLayoutPhysicalRect), [815, 10, 1095, 1059])
    }

    /// The left and the right side make a column of its own, the top and the bottom stack the window in the column
    @Test func testScrollingWorkspaceMakesColumnsAndStacks() async throws {
        let workspace = shownWorkspace()
        let root = workspace.rootTilingContainer
        root.layout = .scrolling
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: column)
        let second = TestWindow.new(id: 2, parent: column)
        let third = TestWindow.new(id: 3, parent: column)
        try await workspace.layoutWorkspace()

        startDragging(third)
        rearrange(at: point(in: second, 0.9, 0.5))
        #expect(drag.drop == .beside(second, .right))
        var preview = drag.preview
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_scrolling([.v_tiles([.window(1), .window(2)]), .window(3)]))
        assertEquals(preview, [third.lastAppliedLayoutPhysicalRect.orDie()])

        startDragging(third)
        rearrange(at: point(in: second, 0.5, 0.9))
        #expect(drag.drop == .beside(second, .down))
        preview = drag.preview
        try await release(workspace)
        assertEquals(root.layoutDescription, .h_scrolling([.v_tiles([.window(1), .window(2), .window(3)])]))
        assertEquals(preview, [third.lastAppliedLayoutPhysicalRect.orDie()])
    }

    // MARK: The previews are invisible

    /// Every preview tries the drop on the trees and takes it back: the trees are exactly as they were, and the drop that
    /// follows makes the same tree as on a twin that never showed a preview
    @Test func testPreviewsChangeNothing() async throws {
        let workspace = shownWorkspace()
        let windows = buildTree(in: workspace, firstId: 1)
        try await workspace.layoutWorkspace()
        let twin = Workspace.get(byName: name + " twin")
        let twinWindows = buildTree(in: twin, firstId: 11)

        startDragging(windows[0])
        let before = fingerprint(workspace)
        var now = start
        for isRearranging in [false, true] {
            if isRearranging { rearrange(at: CGPoint(x: 5, y: 5)) }
            for x in stride(from: 15.0, through: 1905, by: 63) {
                for y in stride(from: 15.0, through: 1065, by: 71) {
                    now += .milliseconds(10)
                    drag.update(pointer: CGPoint(x: x, y: y), at: now)
                    assertEquals(fingerprint(workspace), before)
                }
            }
        }
        drag.update(pointer: point(in: windows[3], 0.5, 0.7), at: now)
        #expect(drag.drop == .beside(windows[3], .down))
        try await release(workspace)

        WindowDrop.beside(twinWindows[3], .down).apply(to: twinWindows[0])
        try await twin.layoutWorkspace()
        assertEquals(
            fingerprint(workspace.rootTilingContainer, ignoringRects: true),
            fingerprint(twin.rootTilingContainer, idOffset: 10, ignoringRects: true),
        )
        for (window, twinWindow) in zip(windows, twinWindows) {
            assertEquals(window.lastAppliedLayoutPhysicalRect, twinWindow.lastAppliedLayoutPhysicalRect)
        }
    }

    /// h[1, v[2, h[3, 4]], 5], with weights that aren't the same, the most recent child somewhere in the middle and a
    /// dwindle split anchor
    private func buildTree(in workspace: Workspace, firstId: UInt64) -> [TestWindow] {
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: OpaqueWindowId(firstId), parent: root, adaptiveWeight: 0.7)
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1.3, index: INDEX_BIND_LAST)
        let second = TestWindow.new(id: OpaqueWindowId(firstId + 1), parent: column, adaptiveWeight: 2)
        let row = TilingContainer.newHTiles(parent: column, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let third = TestWindow.new(id: OpaqueWindowId(firstId + 2), parent: row)
        let fourth = TestWindow.new(id: OpaqueWindowId(firstId + 3), parent: row, adaptiveWeight: 0.5)
        let fifth = TestWindow.new(id: OpaqueWindowId(firstId + 4), parent: root)
        fourth.dwindleSplitAnchor = third
        third.markAsMostRecentChild()
        first.markAsMostRecentChild()
        return [first, second, third, fourth, fifth]
    }

    /// Everything of the tree that a drop, the normalization and the layout can change
    private func fingerprint(_ node: TreeNode, idOffset: UInt64 = 0, ignoringRects: Bool = false) -> String {
        var parts: [String] = []
        switch node {
            case let window as Window:
                parts.append("window \(window.windowId.rawId - idOffset)")
                parts.append("anchor \((window.dwindleSplitAnchor as? Window).map { $0.windowId.rawId - idOffset }.map(String.init) ?? "-")")
                parts.append("fullscreen \(window.isFullscreen) parked \(window.isParkedOffTheScreen)")
            case let container as TilingContainer:
                parts.append("\(container.orientation) \(container.layout) \(container.lifeStatus)")
                parts.append("scroll \(container.scrollOffset) \(container.lastLayoutLength.map(String.init(describing:)) ?? "-")")
            default:
                parts.append("\(type(of: node))")
        }
        if let parent = node.parent as? TilingContainer { parts.append("weight \(node.getWeight(parent.orientation))") }
        parts.append("generation \(node.bindingGeneration)")
        parts.append("most recent \(node._mruChildren.map { child in node.children.firstIndex(of: child) ?? -1 })")
        if !ignoringRects {
            parts.append("rects \(String(describing: node.lastAppliedLayoutPhysicalRect)) \(String(describing: node.lastAppliedLayoutVirtualRect))")
        }
        let children = node.children.map { fingerprint($0, idOffset: idOffset, ignoringRects: ignoringRects) }
        return "(" + parts.joined(separator: ", ") + (children.isEmpty ? "" : " [" + children.joined(separator: " ") + "]") + ")"
    }
}
