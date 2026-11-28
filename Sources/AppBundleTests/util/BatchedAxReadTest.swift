@testable import AppBundle
import AppKit
import Testing

/// Several attributes in one round trip to the app (see `AxUiElementMock.getAll(_:)`)
@MainActor
@Suite(.serializedGlobally)
struct BatchedAxReadTest {
    init() { setUpWorkspacesForTests() }

    /// An attribute that the element doesn't have is an error value: nil, the getters of the attributes don't take it
    @Test func testAnErrorValueIsNoValue() throws {
        var error = AXError.attributeUnsupported
        let errorValue = try #require(unsafe AXValueCreate(.axError, &error))
        assertEquals(Ax.batchedValue(errorValue) == nil, true)
        assertEquals(Ax.batchedValue(NSNull()) == nil, true)
        assertEquals(Ax.batchedValue(kCFBooleanTrue).flatMap(Ax.minimizedAttr.getter), true)
        var point = CGPoint(x: 3, y: 4)
        let pointValue = try #require(unsafe AXValueCreate(.cgPoint, &point))
        assertEquals(Ax.batchedValue(pointValue).flatMap(Ax.topLeftCornerAttr.getter), point)
    }

    @Test func testABatchedReadIsOneRead() {
        var counters = AxStats.Counters()
        counters.record(.batchedRead(attributes: 2))
        counters.record(.read)
        counters.record(.batchedReadFailure)
        assertEquals(counters.reads, 2)
        assertEquals(counters.attributesCoalesced, 1)
        assertEquals(counters.batchedReadFailures, 1)
        assertEquals(counters.total, 2)
    }

    /// The frame is the position and the size in one round trip, nil without one of them
    @Test func testTheFrameIsOneRoundTrip() {
        let window = CountingAxElement([kAXPositionAttribute: CGPoint(x: 1, y: 2), kAXSizeAttribute: CGSize(width: 30, height: 40)])
        assertEquals(axRect(of: window), Rect(topLeftX: 1, topLeftY: 2, width: 30, height: 40))
        assertEquals(window.roundTrips, 1)
        assertEquals(axRect(of: CountingAxElement([kAXPositionAttribute: CGPoint(x: 1, y: 2)])), nil)
    }

    /// The native state is fullscreen and minimized in one round trip
    @Test func testTheNativeStateIsOneRoundTrip() {
        let fullscreen = CountingAxElement(["AXFullScreen": true, kAXMinimizedAttribute: false])
        assertEquals(nativeState(of: fullscreen), .nativeFullscreen)
        assertEquals(fullscreen.roundTrips, 1)
        assertEquals(nativeState(of: CountingAxElement([kAXMinimizedAttribute: true])), .nativeMinimized)
        assertEquals(nativeState(of: CountingAxElement([:])), .normal)
    }
}

/// The attributes of a window, and how many round trips to its app were made: each `get`, and each `getAll`
private final class CountingAxElement: AxUiElementMock {
    private let attributes: [String: Any]
    private(set) var roundTrips = 0

    init(_ attributes: [String: Any]) { self.attributes = attributes }

    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? {
        roundTrips += 1
        return value(attr)
    }

    func getAll<each Attr: ReadableAttr>(_ attrs: repeat each Attr) -> (repeat (each Attr).T?) {
        roundTrips += 1
        return (repeat value(each attrs))
    }

    private func value<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? {
        switch attributes[attr.key] {
            case var point as CGPoint: unsafe AXValueCreate(.cgPoint, &point).flatMap(attr.getter)
            case var size as CGSize: unsafe AXValueCreate(.cgSize, &size).flatMap(attr.getter)
            case let value?: attr.getter(value as AnyObject)
            case nil: nil
        }
    }

    func containingNativeWindowId() -> CGWindowID? { nil }
}
