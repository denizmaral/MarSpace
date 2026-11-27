@testable import AppBundle
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MruStackTest {
    final class Item {
        let name: String
        init(_ name: String) { self.name = name }
    }

    @Test func testPushRaiseRemoveAndReplaceKeepTheOrderOfUse() {
        let (a, b, c, d) = (Item("a"), Item("b"), Item("c"), Item("d"))
        let stack = MruStack<Item>()
        #expect(stack.mostRecent == nil)
        for item in [a, b, c] { stack.pushOrRaise(item) }
        #expect(stack.map(\.name) == ["c", "b", "a"])
        stack.pushOrRaise(a) // From the bottom
        #expect(stack.map(\.name) == ["a", "c", "b"])
        stack.pushOrRaise(c) // From the middle
        #expect(stack.map(\.name) == ["c", "a", "b"])
        stack.pushOrRaise(c) // Already on top
        #expect(stack.map(\.name) == ["c", "a", "b"])
        #expect(stack.remove(a)) // From the middle
        #expect(!stack.remove(a))
        #expect(!stack.remove(d))
        #expect(stack.map(\.name) == ["c", "b"])
        #expect(stack.remove(c)) // From the top
        #expect(stack.mostRecent === b)
        #expect(stack.remove(b)) // The last one
        #expect(stack.mostRecent == nil)
        #expect(Array(stack).isEmpty)
        stack.pushOrRaise(d)
        stack.replaceAll(with: [b, a, c])
        #expect(stack.map(\.name) == ["b", "a", "c"])
        stack.pushOrRaise(c)
        #expect(stack.map(\.name) == ["c", "b", "a"])
        #expect(!stack.remove(d)) // Replaced
    }

    @Test func testAnElementLeavesNoReferenceBehind() {
        let stack = MruStack<Item>()
        weak var removed: Item? = nil
        do {
            let item = Item("removed")
            removed = item
            stack.pushOrRaise(Item("kept"))
            stack.pushOrRaise(item)
            stack.pushOrRaise(Item("on top"))
            stack.remove(item)
        }
        #expect(removed == nil)
        #expect(stack.map(\.name) == ["on top", "kept"])
    }
}
