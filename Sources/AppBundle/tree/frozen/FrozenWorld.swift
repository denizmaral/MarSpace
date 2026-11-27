import Common

struct FrozenWorld {
    let monitors: [FrozenMonitor]
    let windowIds: Set<OpaqueWindowId>
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [OpaqueWindowId] {
    var result = [OpaqueWindowId]()
    collectAllWindowIdsRecursive(node, into: &result)
    return result
}

/// Into one array: not an array per level of the tree, copied into the one above
private func collectAllWindowIdsRecursive(_ node: TreeNode, into result: inout [OpaqueWindowId]) {
    if let window = node as? Window {
        result.append(window.windowId)
        return
    }
    for child in node.children {
        collectAllWindowIdsRecursive(child, into: &result)
    }
}
