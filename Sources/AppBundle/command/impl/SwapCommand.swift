import AppKit
import Common

struct SwapCommand: Command {
    let args: SwapCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else {
            return .fail
        }

        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }

        let targetWindow: Window?
        switch args.target.val {
            case .direction(let direction):
                switch currentWindow.closestParent(hasInhabitedChildrenInDirection: direction, withLayout: nil) {
                    case let (parent, _, neighborIndex)?:
                        targetWindow = currentWindow.swapTarget(in: parent.children[neighborIndex], direction)
                    case nil where args.wrapAround: // The windows on the other side of the workspace
                        targetWindow = currentWindow.swapTarget(in: target.workspace.rootTilingContainer, direction)
                    case nil:
                        return .fail
                }
            case .dfsNextPrev(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allInhabitedLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 == target.windowOrNil }) else {
                    return .fail
                }
                var targetIndex = switch nextPrev {
                    case .dfsNext: currentIndex + 1
                    case .dfsPrev: currentIndex - 1
                }
                if !(0 ..< windows.count).contains(targetIndex) {
                    if !args.wrapAround {
                        return .fail
                    }
                    targetIndex = (targetIndex + windows.count) % windows.count
                }
                targetWindow = windows[targetIndex]
        }

        guard let targetWindow else {
            return .fail
        }

        let pointer = PointerOnWindow(currentWindow)
        swapWindows(mruDominant: currentWindow, targetWindow)
        MoveFlash.shared.flashAfterLayout([currentWindow, targetWindow])
        pointer?.followAfterLayout()
        if case .direction(let direction) = args.target.val {
            currentWindow.lastDirectionalSwap = DirectionalSwap(of: currentWindow, with: targetWindow, direction)
        }

        if args.swapFocus {
            return .from(bool: targetWindow.focusWindow())
        }
        return .succ
    }
}

/// A swap of a window with its neighbor in a direction. Right after it, the opposite direction swaps the two windows back,
/// even if another window on that side shares more of the edge: a swap and its opposite undo each other
struct DirectionalSwap {
    private weak var partner: Window?
    private let direction: CardinalDirection
    private let windowBindingGeneration: UInt64
    private let partnerBindingGeneration: UInt64

    @MainActor
    init(of window: Window, with partner: Window, _ direction: CardinalDirection) {
        self.partner = partner
        self.direction = direction
        windowBindingGeneration = window.bindingGeneration
        partnerBindingGeneration = partner.bindingGeneration
    }

    /// The window that the swap traded places with, if `direction` undoes the swap: the opposite direction, and neither
    /// window was moved since
    @MainActor
    func partnerToSwapBack(_ window: Window, _ direction: CardinalDirection) -> Window? {
        guard direction == self.direction.opposite,
              let partner,
              window.bindingGeneration == windowBindingGeneration,
              partner.bindingGeneration == partnerBindingGeneration
        else { return nil }
        return partner
    }
}

extension Window {
    /// The window of `block` that `swap` trades places with. Of the windows of the block that face this window across the
    /// edge in `direction`, the one that shares the most of the edge: the nearest window, wherever the focus was before. The
    /// top or left one if several share the same. Right after a swap, the opposite direction takes the same window back
    /// (see ``DirectionalSwap``)
    @MainActor
    fileprivate func swapTarget(in block: TreeNode, _ direction: CardinalDirection) -> Window? {
        guard let span = estimatedTilingRect()?.span(across: direction) else {
            return block.findInhabitedLeafWindowRecursive(snappedTo: direction.opposite)
        }
        let sharing: [(window: Window, shared: CGFloat, start: CGFloat)] = block.windowsFacing(direction).compactMap { window in
            guard window !== self, let other = window.estimatedTilingRect()?.span(across: direction) else { return nil }
            let shared = min(span.upperBound, other.upperBound) - max(span.lowerBound, other.lowerBound)
            return shared > 1 ? (window, shared, other.lowerBound) : nil
        }
        if let partner = lastDirectionalSwap?.partnerToSwapBack(self, direction), sharing.contains(where: { $0.window === partner }) {
            return partner
        }
        guard let most = sharing.map(\.shared).max() else { return nil }
        return sharing.filter { most - $0.shared <= 1 }.min { $0.start < $1.start }?.window
    }
}

extension TreeNode {
    /// The windows of the node on the side that a neighbor in `direction` touches: e.g. for `.right`, its windows on the
    /// left side. Of an accordion, the window that it shows
    @MainActor
    fileprivate func windowsFacing(_ direction: CardinalDirection) -> [Window] {
        var result: [Window] = []
        collectWindowsFacing(direction, into: &result)
        return result
    }

    /// Into one array: not an array per level of the tree, copied into the one above
    @MainActor
    private func collectWindowsFacing(_ direction: CardinalDirection, into result: inout [Window]) {
        switch tilingTreeNodeCasesOrDie() {
            case .window(let window):
                if window.lifeStatus.isInhabited { result.append(window) }
            case .tilingContainer(let container):
                if container.layout == .accordion {
                    container.mostRecentInhabitedChild?.collectWindowsFacing(direction, into: &result)
                    return
                }
                let children = container.inhabitedChildren
                if container.orientation == direction.orientation {
                    (direction.isPositive ? children.first : children.last)?.collectWindowsFacing(direction, into: &result)
                    return
                }
                for child in children { child.collectWindowsFacing(direction, into: &result) }
        }
    }
}

extension Rect {
    /// The extent across the direction: e.g. from the top to the bottom for `.left` and `.right`
    fileprivate func span(across direction: CardinalDirection) -> ClosedRange<CGFloat> {
        direction.orientation == .h ? minY ... maxY : minX ... maxX
    }
}
