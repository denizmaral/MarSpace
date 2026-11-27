@testable import AppBundle
import Foundation
import Testing

/// The settings window looks its rows up by id and its problems by location: the lookups find what a pass over the list
/// found
@MainActor
@Suite(.serializedGlobally)
struct SettingsLookupTest {
    @Test func testIdsFindTheirElementsAfterEveryChange() {
        var list: IdentifiedList<String> = ["a", "b", "c", "d"]
        func expectConsistent(_ step: String) {
            for (index, id) in list.ids.enumerated() {
                #expect(list.index(of: id) == index, "\(step)")
                #expect(list[id: id] == list[index], "\(step)")
            }
        }
        expectConsistent("init")
        let removedId = list.ids[1]
        list[id: removedId] = nil
        #expect(list.index(of: removedId) == nil)
        #expect(list[id: removedId] == nil)
        expectConsistent("remove by id")
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        expectConsistent("move")
        list.sort()
        expectConsistent("sort")
        list.swapAt(0, 2)
        expectConsistent("swap")
        list.reverse() // Through swapAt
        expectConsistent("reverse")
        list.append("e")
        list.insert("f", at: 0)
        expectConsistent("append and insert")
        let removed = list.ids[2]
        list.remove(at: 2)
        #expect(list.index(of: removed) == nil)
        expectConsistent("remove at")
        list.removeAll { $0 == "e" }
        expectConsistent("remove all")
        list[0] = "changed" // In place: keeps its id
        expectConsistent("change in place")
    }

    @Test func testProblemsAtALocationAreTheProblemsAtItAndBelowIt() {
        let problems = [
            "Window rules › 1 › Action 2",
            "Window rules › 12",
            "Window rules › 1",
            "Shortcuts › main › ⌥ A",
            "Shortcuts › main › ⌥ A › Action 1",
            "Workspaces",
            "a › › b", // Separators that share a space
        ].enumerated().map { SettingsProblem(location: $1, message: "\($0)") }
        let byLocation = SettingsStore.byLocation(problems)
        let queries = [
            "Window rules", "Window rules › 1", "Window rules › 12", "Window rules › 1 › Action 2", "Window rules › 2",
            "Shortcuts", "Shortcuts › main", "Shortcuts › main › ⌥ A", "Shortcuts › main › ⌥", "Workspaces", "Work", "",
            "a", "a ›", "a › ", "a › › b",
        ]
        for query in queries {
            let expected = problems.filter { $0.location == query || $0.location.hasPrefix(query + " › ") }
            #expect((byLocation[query] ?? []) == expected, "\(query)")
        }
    }
}
