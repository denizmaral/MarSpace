import AppKit
import Common

/// Where a tiling window that is dragged with the mouse goes when the mouse button is released (see ``WindowDrag``)
enum WindowDrop: Equatable {
    /// The two windows trade places: a quick drag
    case swap(Window)
    /// Next to the window, on that side: the dragged window takes half of the tile of the window. In a container along
    /// that side the window gives half of its weight (and takes it back when the dragged window leaves again, like a
    /// dwindle split), otherwise the two windows share its tile in a new container. On a scrolling workspace the left and
    /// the right side make a column of its own next to the column of the window
    case beside(Window, CardinalDirection)
    /// Along the whole edge of the workspace: a column at the left or the right, a row at the top or the bottom
    case edge(Workspace, CardinalDirection)
    /// The whole workspace, which has no tiling windows (it's shown on another monitor)
    case into(Workspace)
}

extension WindowDrop {
    /// The part of the screen at each of its edges where a drop that rearranges goes along the whole edge of the workspace:
    /// of the width of the screen at the left and the right, of the height at the top and the bottom
    static let edgeShare: CGFloat = 1.0 / 12

    /// The drop at `point`. A quick drag swaps the window with the window under the mouse. A drag that rearranges (the
    /// mouse was held still, see ``WindowDrag``) puts it next to the window under the mouse, on the side that the mouse is
    /// nearest to, or along the whole edge of the workspace near an edge of the screen.
    ///
    /// - Returns: nil over the tile of the dragged window itself, out of the workspaces, and on floating workspaces: the
    ///   window goes back to its tile
    @MainActor
    static func at(_ point: CGPoint, dragging window: Window, isRearranging: Bool) -> WindowDrop? {
        let monitor = point.monitorApproximation
        let visibleRect = monitor.visibleRect
        guard visibleRect.contains(point) else { return nil }
        let workspace = monitor.visibleWorkspace
        guard !workspace.isFloatingLayout else { return nil }
        let root = workspace.rootTilingContainer
        guard root.allLeafWindowsRecursive.contains(where: { $0 != window && $0.lifeStatus.isInhabited }) else {
            return workspace == window.nodeWorkspace ? nil : .into(workspace)
        }
        if isRearranging, root.layout == .tiles, let edge = visibleRect.edge(near: point, share: edgeShare) {
            // A window that already lies along the whole edge stays where it is
            return window.liesAlongTheWholeEdge(edge, of: root) ? nil : .edge(workspace, edge)
        }
        // The virtual rects leave no gaps between the tiles: the target doesn't flicker on the way across a gap. The dragged
        // window keeps the virtual rect of its tile during the drag (the layout leaves it alone)
        guard let target = point.findWindowRecursively(in: root, virtual: true, fullscreenCoversAll: false),
              target != window,
              let tile = target.lastAppliedLayoutVirtualRect
        else { return nil }
        return isRearranging ? .beside(target, tile.nearestEdge(to: point)) : .swap(target)
    }

    var isSwap: Bool {
        if case .swap = self { true } else { false }
    }

    /// The workspace that the dragged window goes to
    @MainActor
    var workspace: Workspace? {
        switch self {
            case .swap(let target), .beside(let target, _): target.nodeWorkspace
            case .edge(let workspace, _), .into(let workspace): workspace
        }
    }

    /// The windows that the drop puts elsewhere: the dragged window, and the window that it trades places with
    func movedWindows(_ window: Window) -> [Window] {
        if case .swap(let target) = self { [window, target] } else { [window] }
    }

    /// The windows are still in the tiling trees: one may have been closed, or moved by a shortcut, during the drag
    @MainActor
    func canApply(to window: Window) -> Bool {
        guard window.lifeStatus.isInhabited, case .tilingContainer = window.windowParentCases else { return false }
        switch self {
            case .swap(let target), .beside(let target, _):
                guard target != window, target.lifeStatus.isInhabited, case .tilingContainer = target.windowParentCases else { return false }
                return true
            case .edge(let workspace, _), .into(let workspace):
                return workspace.isBound && !workspace.isFloatingLayout
        }
    }

    /// The window takes its new place. The trees of both workspaces are normalized, as the refresh session does next
    @MainActor
    func apply(to window: Window) {
        let from = window.nodeWorkspace
        let to = workspace
        switch self {
            case .swap(let target):
                swapWindows(mruDominant: window, target)
            case .beside(let target, let side):
                window.leaveTilingTree()
                window.bind(beside: target, side)
            case .edge(let workspace, let side):
                window.leaveTilingTree()
                let root = workspace.rootTilingContainer
                if root.orientation == side.orientation || root.layout != .tiles || root.inhabitedChildren.isEmpty {
                    window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: side.isPositive ? INDEX_BIND_LAST : 0)
                } else {
                    createImplicitContainerAndMoveWindow(window, workspace, side)
                }
            case .into(let workspace):
                window.leaveTilingTree()
                window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
        }
        from?.normalizeContainers()
        if let to, to != from { to.normalizeContainers() }
    }

    /// The places that the moved windows go to (see ``movedWindows(_:)``): the tiles that the layout gives them after the
    /// drop. The drop is tried and taken back (see `tryOut`): nothing changes, nothing is sent.
    ///
    /// - Returns: empty for a floating workspace, where the window would float
    @MainActor
    func tiles(of window: Window) -> [Rect] {
        guard let to = workspace, let from = window.nodeWorkspace, !to.isFloatingLayout else { return [] }
        let workspaces = to == from ? [to] : [to, from]
        let tiles = tryOut(workspaces) {
            // The layout leaves the dragged window alone while it's dragged: here it's laid out too
            let manipulated = currentlyManipulatedWithMouseWindowId
            currentlyManipulatedWithMouseWindowId = nil
            defer { currentlyManipulatedWithMouseWindowId = manipulated }
            apply(to: window)
            return workspaces.filter(\.isVisible).reduce(into: [Window: Rect]()) { tiles, workspace in
                tiles.merge(workspace.tilesOnTheScreen()) { _, new in new }
            }
        }
        return movedWindows(window).compactMap { tiles[$0] }
    }
}

extension Window {
    /// The window is the first (or the last) child of the root along §edge§: it takes the whole edge already
    @MainActor
    fileprivate func liesAlongTheWholeEdge(_ edge: CardinalDirection, of root: TilingContainer) -> Bool {
        let children = root.inhabitedChildren
        return parent === root && root.orientation == edge.orientation && (edge.isPositive ? children.last : children.first) === self
    }

    /// The window leaves its place in the tiling tree for another one: its dwindle split anchor takes its weight back, and
    /// the container that it leaves is normalized (e.g. flattened, if one child is left) before it's put elsewhere
    @MainActor
    fileprivate func leaveTilingTree() {
        returnWeightToDwindleSplitAnchor()
        let workspace = nodeWorkspace
        unbindFromParent()
        workspace?.normalizeContainers()
    }

    /// See ``WindowDrop/beside(_:_:)``
    @MainActor
    fileprivate func bind(beside target: Window, _ side: CardinalDirection) {
        guard let (parent, index) = target.nearestAliveTilingParent() else { return }
        if let root = target.nodeWorkspace?.rootTilingContainer,
           root.layout == .scrolling,
           side.orientation == root.orientation,
           let column = target.parentsWithSelf.first(where: { $0.parent === root }),
           let columnIndex = column.ownIndex(in: .all)
        {
            bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: columnIndex + side.insertionOffset)
            return
        }
        let node = parent.children[index] // The target, or a container that holds only it
        if parent.orientation == side.orientation {
            if parent.layout == .tiles {
                let half = node.getWeight(side.orientation) / 2
                node.setWeight(side.orientation, half)
                bind(to: parent, adaptiveWeight: half, index: index + side.insertionOffset)
                dwindleSplitAnchor = node // It takes its weight back when this window leaves
            } else {
                bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index + side.insertionOffset)
            }
        } else {
            let binding = node.unbindFromParent()
            let container = TilingContainer(parent: parent, adaptiveWeight: binding.adaptiveWeight, side.orientation, .tiles, index: binding.index)
            node.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: 0)
            bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: side.insertionOffset)
        }
    }
}

extension Rect {
    /// How far `point` is from each edge, in parts of the width or the height
    private func relativeDistances(to point: CGPoint) -> [(edge: CardinalDirection, distance: CGFloat)] {
        guard width > 0, height > 0 else { return [] }
        return [
            (.left, (point.x - minX) / width),
            (.right, (maxX - point.x) / width),
            (.up, (point.y - minY) / height),
            (.down, (maxY - point.y) / height),
        ]
    }

    /// The edge that `point` is within `share` of the width or the height of. The nearest one in a corner
    fileprivate func edge(near point: CGPoint, share: CGFloat) -> CardinalDirection? {
        relativeDistances(to: point).filter { $0.distance < share }.min { $0.distance < $1.distance }?.edge
    }

    /// The edge nearest to `point`, relative to the width and the height: the diagonals divide the rect into the parts of
    /// the four edges
    fileprivate func nearestEdge(to point: CGPoint) -> CardinalDirection {
        relativeDistances(to: point).min { $0.distance < $1.distance }?.edge ?? .right
    }
}
