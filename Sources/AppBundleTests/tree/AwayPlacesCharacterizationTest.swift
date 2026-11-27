@testable import AppBundle
import Common
import Foundation
import Testing

/// The places of the floating windows that remember their tiles, as the snapshots of the trees hold them, on two
/// workspaces: a window whose tile is on another workspace, a container that the normalization removed after its
/// windows left, nested containers. Recorded from the code before it looked the away windows up instead of scanning them
/// (`AwayWindowPlaces`, `awayNodes`, `restoredWeight`, `insertionIndex`): the lookups find what the scans found
@MainActor
@Suite(.serializedGlobally)
struct AwayPlacesCharacterizationTest {
    init() { setUpWorkspacesForTests() }

    private func nativeId(_ window: Window) -> UInt32? { UInt32(window.windowId.rawId) }

    private func window(_ id: OpaqueWindowId) -> Window { Window.get(byId: id).orDie() }

    private func run(_ command: String) async {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    private func normalize() {
        for workspace in Workspace.all { workspace.normalizeContainers() }
    }

    private func popOut(_ id: OpaqueWindowId) async {
        #expect(window(id).focusWindow())
        await run("pop-out")
        normalize()
    }

    @Test func testSnapshotsAndRestoresOfTwoWorkspaces() async throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let a = Workspace.get(byName: "a"), b = Workspace.get(byName: "b")
        a.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 3, parent: $0)
                    TestWindow.new(id: 4, parent: $0)
                }
            }
            TestWindow.new(id: 5, parent: $0, adaptiveWeight: 3)
        }
        b.rootTilingContainer.apply {
            TestWindow.new(id: 6, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 7, parent: $0)
                TestWindow.new(id: 8, parent: $0)
            }
        }
        normalize()
        await popOut(3) // Its container is flattened: 4 is left alone
        await popOut(2)
        await popOut(7)
        await popOut(1)
        #expect(window(1).focusWindow())
        await run("move-node-to-workspace b") // Floating on b, its tile is on a
        normalize()

        let trees = [a, b].compactMap { $0.tilingTreeSnapshot(windowId: nativeId) }
        #expect(String(describing: trees) == #"[AppBundle.TilingTreeSnapshot<Swift.UInt32>(workspace: "a", mostRecentWindow: Optional(4), root: AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.h, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.away(id: 3, weight: 5.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.container(AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.v, layout: AppBundle.Layout.tiles, weight: 2.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.away(id: 2, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 4, weight: 1.0)])), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 5, weight: 3.0)])), AppBundle.TilingTreeSnapshot<Swift.UInt32>(workspace: "b", mostRecentWindow: Optional(8), root: AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.h, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 6, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.container(AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.v, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.away(id: 7, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 8, weight: 1.0)]))]))]"#)
        let file = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode([], trees: trees, bootSession: 1)))
        #expect(file.trees == trees)

        // A restart: the trees are restored, then the floating windows are made tiles again
        for workspace in [a, b] {
            for window in workspace.floatingWindowsIfAny { window.tilingSlot = nil }
            let tiles = workspace.rootTilingContainer.allLeafWindowsRecursive
            workspace.rootTilingContainer.unbindFromParent()
            for tile in tiles.reversed() {
                tile.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
        for tree in file.trees {
            Workspace.get(byName: tree.workspace).restoreTilingTree(tree, windowId: nativeId)
        }
        normalize()
        #expect(String(describing: [a, b].map(\.rootTilingContainer.layoutDescription)) == #"[AppBundleTests.LayoutDescription.h_tiles([AppBundleTests.LayoutDescription.window(4), AppBundleTests.LayoutDescription.window(5)]), AppBundleTests.LayoutDescription.h_tiles([AppBundleTests.LayoutDescription.window(6), AppBundleTests.LayoutDescription.window(8)])]"#)
        for id: OpaqueWindowId in [3, 2, 7, 1] {
            #expect(window(id).focusWindow())
            await run("pop-out") // Back to its tile
            normalize()
        }
        #expect(String(describing: [a, b].map(\.rootTilingContainer.layoutDescription)) == #"[AppBundleTests.LayoutDescription.h_tiles([AppBundleTests.LayoutDescription.window(3), AppBundleTests.LayoutDescription.v_tiles([AppBundleTests.LayoutDescription.window(2), AppBundleTests.LayoutDescription.window(4)]), AppBundleTests.LayoutDescription.window(5)]), AppBundleTests.LayoutDescription.h_tiles([AppBundleTests.LayoutDescription.window(6), AppBundleTests.LayoutDescription.v_tiles([AppBundleTests.LayoutDescription.window(7), AppBundleTests.LayoutDescription.window(8)]), AppBundleTests.LayoutDescription.window(1)])]"#)
        #expect(String(describing: [a, b].map { $0.tilingTreeSnapshot(windowId: nativeId) }) == #"[Optional(AppBundle.TilingTreeSnapshot<Swift.UInt32>(workspace: "a", mostRecentWindow: Optional(2), root: AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.h, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 3, weight: 5.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.container(AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.v, layout: AppBundle.Layout.tiles, weight: 2.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 2, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 4, weight: 1.0)])), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 5, weight: 3.0)]))), Optional(AppBundle.TilingTreeSnapshot<Swift.UInt32>(workspace: "b", mostRecentWindow: Optional(1), root: AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.h, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 6, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.container(AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.v, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 7, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 8, weight: 1.0)])), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 1, weight: 1.0)])))]"#)
    }

    /// Pinned, a window that remembers its tile on one workspace floats on another one: the tree of the first one holds its
    /// place
    @Test func testTheTileOfAWindowOnAnotherWorkspace() async {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let a = Workspace.get(byName: "a")
        a.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3)
                TestWindow.new(id: 4, parent: $0)
            }
        }
        #expect(a.focusWorkspace())
        await popOut(3)
        await run("pin")
        await popOut(1)
        await run("workspace b")
        Workspace.movePinnedWindowsToVisibleWorkspaces()
        normalize()
        let b = Workspace.get(byName: "b")
        #expect(window(3).nodeWorkspace === b)
        #expect(String(describing: [a, b].map { $0.tilingTreeSnapshot(windowId: nativeId) }) == #"[Optional(AppBundle.TilingTreeSnapshot<Swift.UInt32>(workspace: "a", mostRecentWindow: Optional(4), root: AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.h, layout: AppBundle.Layout.tiles, weight: 1.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.away(id: 1, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.container(AppBundle.TilingTreeSnapshot<Swift.UInt32>.Container(orientation: Common.Orientation.v, layout: AppBundle.Layout.tiles, weight: 2.0, children: [AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 2, weight: 1.0), AppBundle.TilingTreeSnapshot<Swift.UInt32>.Node.window(id: 4, weight: 1.0)]))]))), nil]"#)
        await run("workspace a")
        Workspace.movePinnedWindowsToVisibleWorkspaces()
        await popOut(3) // Back to its tile
        await popOut(1)
        #expect(String(describing: a.rootTilingContainer.layoutDescription) == #"h_tiles([AppBundleTests.LayoutDescription.window(1), AppBundleTests.LayoutDescription.v_tiles([AppBundleTests.LayoutDescription.window(2), AppBundleTests.LayoutDescription.window(3), AppBundleTests.LayoutDescription.window(4)])])"#)
    }
}
