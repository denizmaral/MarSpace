/// Stack with the most recent element on top. Pushing, raising and removing take constant time, however many elements
/// there are: the elements are in a doubly linked list, found by their identity (`TreeNode` is equal only to itself)
final class MruStack<T: AnyObject>: Sequence {
    typealias Element = T

    private var top: MruNode<T>? = nil
    private var nodes: [ObjectIdentifier: MruNode<T>] = [:]

    func makeIterator() -> MruStackIterator<T> {
        MruStackIterator(top)
    }

    var mostRecent: T? { top?.value }

    func pushOrRaise(_ value: T) {
        let node = unlink(value) ?? MruNode(value)
        node.next = top
        top?.previous = node
        top = node
        nodes[ObjectIdentifier(value)] = node
    }

    @discardableResult
    func remove(_ value: T) -> Bool {
        guard unlink(value) != nil else { return false }
        nodes[ObjectIdentifier(value)] = nil
        return true
    }

    /// - Parameter values: the most recent first, as the stack iterates
    func replaceAll(with values: [T]) {
        top = nil
        nodes = [:]
        for value in values.reversed() { pushOrRaise(value) }
    }

    /// Takes the node of `value` out of the list, nil if `value` isn't in the stack
    private func unlink(_ value: T) -> MruNode<T>? {
        guard let node = nodes[ObjectIdentifier(value)] else { return nil }
        if let previous = node.previous { previous.next = node.next } else { top = node.next }
        node.next?.previous = node.previous
        node.next = nil
        node.previous = nil
        return node
    }
}

struct MruStackIterator<T: AnyObject>: IteratorProtocol {
    typealias Element = T
    private var current: MruNode<T>?

    fileprivate init(_ current: MruNode<T>?) {
        self.current = current
    }

    mutating func next() -> T? {
        let result = current?.value
        current = current?.next
        return result
    }
}

private final class MruNode<T: AnyObject> {
    let value: T
    /// Less recent
    var next: MruNode<T>? = nil
    /// More recent. Weak: the list holds its nodes from the top down
    weak var previous: MruNode<T>? = nil

    init(_ value: T) {
        self.value = value
    }
}
