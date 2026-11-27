import AppKit
import Common

/// The workspaces by name, and in the order of their names: a workspace is in both or in neither. `Workspace.all` is
/// read many times per session, it isn't sorted every time
@MainActor private enum Registry {
    private static var byName: [String: Workspace] = [:]
    private(set) static var sorted: [Workspace] = []

    static subscript(name: String) -> Workspace? { byName[name] }

    static func insert(_ workspace: Workspace) {
        check(byName.updateValue(workspace, forKey: workspace.name) == nil, "\(workspace.name) is already registered")
        // After the workspaces of an equal name (logical segments: "1" and "01"), in the order they were created
        sorted.insert(workspace, at: sorted.firstIndex { workspace < $0 } ?? sorted.endIndex)
    }

    /// All at once: one pass over `sorted`, however many there are
    static func remove(_ workspaces: [Workspace]) {
        for workspace in workspaces {
            check(byName.removeValue(forKey: workspace.name) != nil, "\(workspace.name) isn't registered")
        }
        let removed = Set(workspaces.map(ObjectIdentifier.init))
        sorted.removeAll { removed.contains(ObjectIdentifier($0)) }
    }
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    let name: String
    nonisolated private let nameLogicalSegments: StringLogicalSegments

    @MainActor private init(_ name: String) {
        self.name = name
        self.nameLogicalSegments = name.toLogicalSegments()
        let container = mainMonitorInfo.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate()
        super.init(parent: container, adaptiveWeight: 0, index: 0)
        check(forceAssignedMonitorInfo?.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate().bindWorkspace(self) != false)
    }

    /// Sorted by name
    @MainActor static var all: [Workspace] { Registry.sorted }

    @MainActor static func get(byName name: String) -> Workspace {
        if let existing = Registry[name] {
            return existing
        } else {
            let workspace = Workspace(name)
            Registry.insert(workspace)
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nameLogicalSegments < rhs.nameLogicalSegments
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        tilingRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): \(String(describing: $0.1).singleQuoted)" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor static func forceAssignWorkspaces() {
        for wsName in config.workspaceToMonitorForceAssignment.keys {
            let ws = Workspace.get(byName: wsName)
            check(ws.forceAssignedMonitorInfo?.bindWorkspace(ws) != false)
        }
    }

    @MainActor static func garbageCollectUnusedWorkspaces() {
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        let focus = globalFocus
        let garbage = Registry.sorted.filter { workspace in
            !config.persistentWorkspaces.contains(workspace.name) &&
                workspace.isEffectivelyEmpty &&
                !workspace.isVisible &&
                workspace.name != focus.workspace.name
        }
        Registry.remove(garbage)
        for workspace in garbage {
            workspace.unbindFromParent()
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        check((lhs === rhs) == (lhs.name == rhs.name), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(name) }
}
