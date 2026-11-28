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

    /// One value per attribute, or none: values that aren't one per attribute could land on the wrong attributes
    @Test func testTheValuesAreOnePerAttributeOrNone() throws {
        var error = AXError.noValue
        let errorValue = try #require(unsafe AXValueCreate(.axError, &error))
        let values = try Ax.batchedValues(.success, [kCFBooleanTrue, errorValue], count: 2).get()
        assertEquals(values.map { $0 == nil }, [false, true])
        func failure(_ error: AXError, _ values: [AnyObject]?) -> BatchedReadFailure? {
            if case .failure(let failure) = Ax.batchedValues(error, values, count: 2) { failure } else { nil }
        }
        assertEquals(failure(.success, [kCFBooleanTrue]), .wrongCount(1))
        assertEquals(failure(.success, nil), .wrongCount(0))
        assertEquals(failure(.invalidUIElement, nil), .elementGone)
        assertEquals(failure(.cannotComplete, [kCFBooleanTrue, kCFBooleanTrue]), .other(.cannotComplete))
    }

    @Test func testABatchedReadIsOneRead() {
        var counters = AxStats.Counters()
        counters.record(.batchedRead(additionalAttributes: 1))
        counters.record(.read)
        counters.record(.batchedReadFailure(.elementGone))
        counters.record(.batchedReadFailure(.other(.cannotComplete)))
        assertEquals(counters.reads, 2)
        assertEquals(counters.attributesCoalesced, 1)
        assertEquals(counters.batchedReadsOfGoneElements, 1)
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

    func getAll<First: ReadableAttr, each Rest: ReadableAttr>(_ first: First, _ rest: repeat each Rest) -> (First.T?, repeat (each Rest).T?) {
        roundTrips += 1
        return (value(first), repeat value(each rest))
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
