@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SwapCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testSwap_swapWindows_Directional() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
                TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 3, parent: $0)
        }

        await parseCommand("swap right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(3), .window(2)]),
                               .window(1)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(1), .window(2)]),
                               .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(2), .window(1)]),
                               .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(1), .window(2)]),
                               .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)
    }

    @Test func testSwap_swapWindows_DfsRelative() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
                TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 3, parent: $0)
        }

        await parseCommand("swap dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(2), .window(1)]),
                               .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(2), .window(3)]),
                               .window(1)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap dfs-prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(2), .window(1)]),
                               .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap dfs-prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.v_tiles([.window(1), .window(2)]),
                               .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)
    }

    @Test func testSwap_DfsRelativeSkipsTombstones() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0).lifeStatus = .dead
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 3, parent: $0).lifeStatus = .invisible
                TestWindow.new(id: 4, parent: $0)
            }
            TestWindow.new(id: 5, parent: $0)
        }

        await parseCommand("swap dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.window(4), .window(2), .v_tiles([.window(3), .window(1)]), .window(5)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)

        await parseCommand("swap dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.window(4), .window(2), .v_tiles([.window(3), .window(5)]), .window(1)]))

        assertEquals(await parseCommand("swap dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 2)
        assertEquals(root.layoutDescription,
                     .h_tiles([.window(4), .window(2), .v_tiles([.window(3), .window(5)]), .window(1)]))

        await parseCommand("swap --wrap-around dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.window(1), .window(2), .v_tiles([.window(3), .window(5)]), .window(4)]))

        await parseCommand("swap --wrap-around dfs-prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.window(4), .window(2), .v_tiles([.window(3), .window(5)]), .window(1)]))

        await parseCommand("swap dfs-prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription,
                     .h_tiles([.window(4), .window(2), .v_tiles([.window(3), .window(1)]), .window(5)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
    }

    @Test func testSwap_DirectionalWrapping() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }

        await parseCommand("swap --wrap-around left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap --wrap-around right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)
    }

    @Test func testSwap_DfsRelativeWrapping() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }

        await parseCommand("swap --wrap-around dfs-prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)

        await parseCommand("swap --wrap-around dfs-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 1)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 1)
    }

    @Test func testSwap_SwapFocus() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
            TestWindow.new(id: 3, parent: $0)
        }

        await parseCommand("swap --swap-focus right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3), .window(2)]))
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
        assertEquals(root.mostRecentWindowRecursive?.windowId, 3)
    }

    /// The window that shares the most of the edge, not the most recent one of the other side: here 3 had the focus last
    @Test func testSwap_theWindowThatSharesTheMostOfTheEdge() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).then { column in
            let window1 = TestWindow.new(id: 1, parent: column)
            TestWindow.new(id: 4, parent: column)
            return window1
        }
        let window3 = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).then { column in
            TestWindow.new(id: 2, parent: column)
            return TestWindow.new(id: 3, parent: column)
        }
        assertEquals(window3.focusWindow(), true)
        assertEquals(window1.focusWindow(), true)

        await parseCommand("swap right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(2), .window(4)]), .v_tiles([.window(1), .window(3)])]))
    }

    /// Two windows share the same part of the edge: the top one
    @Test func testSwap_theTopOrLeftOneOfWindowsThatShareTheSame() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window3 = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).then { column in
            TestWindow.new(id: 2, parent: column)
            return TestWindow.new(id: 3, parent: column)
        }
        assertEquals(window3.focusWindow(), true)
        assertEquals(window1.focusWindow(), true)

        await parseCommand("swap right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .v_tiles([.window(1), .window(3)])]))
    }

    /// Right after a swap, the opposite direction swaps back: here 2 shares more of the edge than 1
    @Test func testSwap_theOppositeDirectionSwapsBack() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window3 = buildBigTileAndColumn(root)
        let original = root.layoutDescription
        assertEquals(window3.focusWindow(), true)

        await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .v_tiles([.window(2), .window(1), .h_tiles([.window(4), .window(5)])])]))
        await parseCommand("swap right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, original)
    }

    /// Once one of the two windows was moved, the opposite direction takes the window that shares the most of the edge
    @Test func testSwap_noSwapBackAfterTheOtherWindowMoved() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window3 = buildBigTileAndColumn(root)
        assertEquals(window3.focusWindow(), true)
        await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin)

        let window1 = root.allLeafWindowsRecursive.first { $0.windowId == 1 }.orDie()
        assertEquals(window1.focusWindow(), true)
        await parseCommand("swap down").cmdOrDie.run(.defaultEnv, .emptyStdin) // 1 and 4 change places
        assertEquals(window3.focusWindow(), true)
        await parseCommand("swap right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .v_tiles([.window(3), .window(4), .h_tiles([.window(1), .window(5)])])]))
    }

    /// An accordion shows one of its windows: that's the one
    @Test func testSwap_theWindowThatAnAccordionShows() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        let window1 = TestWindow.new(id: 1, parent: root)
        let window3 = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST).then { accordion in
            TestWindow.new(id: 2, parent: accordion)
            return TestWindow.new(id: 3, parent: accordion)
        }
        assertEquals(window3.focusWindow(), true)
        assertEquals(window1.focusWindow(), true)

        await parseCommand("swap right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.layoutDescription, .h_tiles([.window(3), .v_accordion([.window(2), .window(1)])]))
    }

    /// The action "Move the window": a swap, and at the edge of the workspace the window takes the whole edge
    @Test func testMoveAction_swapsAndTakesTheWholeEdgeAtTheEdge() async {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(window1.focusWindow(), true)

        await Action.move(.right).command.cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(2), .window(1)]))
        await Action.move(.down).command.cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(2), .window(1)]))
    }
}

/// The layout of workspace T on the owner's monitor: 1 is the left half, 2 takes the top half of the column on the right,
/// 3 a quarter, 4 and 5 share the bottom quarter. Returns window 3
@MainActor
private func buildBigTileAndColumn(_ root: TilingContainer) -> Window {
    TestWindow.new(id: 1, parent: root)
    return TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).then { column in
        TestWindow.new(id: 2, parent: column, adaptiveWeight: 2)
        let window3 = TestWindow.new(id: 3, parent: column)
        TilingContainer.newHTiles(parent: column, adaptiveWeight: 1).apply {
            TestWindow.new(id: 4, parent: $0)
            TestWindow.new(id: 5, parent: $0)
        }
        return window3
    }
}
