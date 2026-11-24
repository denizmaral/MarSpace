import AppKit
import Common

/// Runs `change` on the trees of `workspaces` and takes it back: afterwards the trees are exactly as they were, the same
/// nodes with the same weights, the same most recent children and binding generations, and the rects of the last layout.
/// A drop of a dragged window is tried this way to show where the window goes (see `WindowDrop.tiles(of:)`): with the
/// change, the normalization and the layout that the drop gets, not with something that only looks like them.
///
/// `change` can't await: no session sees the trees that are tried. It must not send frames (lay out with
/// `Workspace.tilesOnTheScreen()`, not with `layoutWorkspace()`), and it changes only the nodes of the workspaces and the
/// minimized windows (a window that leaves its place gives its weight back to its dwindle split anchor, which may be
/// minimized, see `returnWeightToDwindleSplitAnchor()`)
@MainActor
func tryOut<T>(_ workspaces: [Workspace], _ change: () -> T) -> T {
    var nodes: [TreeNode] = []
    var seen: Set<ObjectIdentifier> = []
    func collect(_ node: TreeNode) {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return }
        nodes.append(node)
        for child in node.children { collect(child) }
    }
    for workspace in workspaces {
        collect(workspace)
        // A window that is bound is the most recent child up to the monitor
        for parent in workspace.parents where seen.insert(ObjectIdentifier(parent)).inserted { nodes.append(parent) }
    }
    collect(macosMinimizedWindowsContainer)
    let trees = nodes.map { ($0, $0.treeState) }
    let shapes = nodes.compactMap { $0 as? TilingContainer }.map { ($0, $0.shapeState) }
    let places = nodes.compactMap { $0 as? Window }.map { ($0, $0.placeState) }
    defer {
        // The nodes that the change created aren't referenced by these anymore, and go away
        for (node, state) in trees { node.restore(state) }
        for (container, state) in shapes { container.restore(state) }
        for (window, state) in places { window.restore(state) }
    }
    return change()
}
