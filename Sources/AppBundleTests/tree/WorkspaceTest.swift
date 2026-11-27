@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WorkspaceTest {
    init() { setUpWorkspacesForTests() }

    @Test func testGarbageCollectedWorkspaceIsUnbound() {
        let garbage = Workspace.get(byName: "a")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(garbage.parent == nil)
        #expect(Workspace.get(byName: "a") !== garbage)
    }

    @Test func testGarbageCollectAndForceAssignDontDuplicateWorkspaces() {
        config.workspaceToMonitorForceAssignment = ["a": [.main]]
        for _ in 1 ... 3 {
            Workspace.garbageCollectUnusedWorkspaces()
            Workspace.forceAssignWorkspaces()
        }
        let container = mainMonitorInfo.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate()
        #expect(container.children.filterIsInstance(of: Workspace.self).count { $0.name == "a" } == 1)
    }

    @Test func testUpdateTrayTextAfterGarbageCollection() {
        _ = Workspace.get(byName: "a")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(Workspace.get(byName: "a").focusWorkspace())
        updateTrayText()
        #expect(mainMonitorInfo.visibleWorkspace === globalFocus.workspace)
    }

    @Test func testAllIsSortedByNameWhateverTheOrderOfCreation() {
        for (id, name) in zip([1, 2, 3, 4] as [OpaqueWindowId], ["b", "10", "a", "2"]) {
            TestWindow.new(id: id, parent: Workspace.get(byName: name).rootTilingContainer)
        }
        _ = Workspace.get(byName: "c") // Empty: garbage
        #expect(Workspace.all.map(\.name) == ["2", "10", "a", "b", "c", "setUpWorkspacesForTests"])
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(Workspace.all.map(\.name) == ["2", "10", "a", "b", "setUpWorkspacesForTests"])
    }
}
