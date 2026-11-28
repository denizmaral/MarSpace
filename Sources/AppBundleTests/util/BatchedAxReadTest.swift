@testable import AppBundle
import AppKit
import Testing

/// The values of `AXUIElementCopyMultipleAttributeValues` (see `AXUIElement.get(_:_:)`)
@MainActor
@Suite(.serializedGlobally)
struct BatchedAxReadTest {
    init() { setUpWorkspacesForTests() }

    /// An attribute that the element doesn't have is an error value: nil, the getters of the attributes don't take it
    @Test func testAnErrorValueIsNoValue() throws {
        var error = AXError.attributeUnsupported
        let errorValue = try #require(unsafe AXValueCreate(.axError, &error))
        assertEquals(attributeValue(errorValue) == nil, true)
        assertEquals(attributeValue(NSNull()) == nil, true)
        assertEquals(attributeValue(kCFBooleanTrue).flatMap(Ax.minimizedAttr.getter), true)
        var point = CGPoint(x: 3, y: 4)
        let pointValue = try #require(unsafe AXValueCreate(.cgPoint, &point))
        assertEquals(attributeValue(pointValue).flatMap(Ax.topLeftCornerAttr.getter), point)
    }

    @Test func testABatchedReadIsOneRead() {
        var counters = AxStats.Counters()
        counters.record(.batchedRead(attributes: 2))
        counters.record(.read)
        assertEquals(counters.reads, 2)
        assertEquals(counters.readsSaved, 1)
        assertEquals(counters.total, 2)
    }
}
