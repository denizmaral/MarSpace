@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    /// What the accessibility API reports as the frame of the window. A sent frame changes it like an app does
    var axRectForTest: Rect?
    /// The app refuses a smaller size, e.g. App Store is at least 1000 wide
    var minimumSizeForTest: CGSize? = nil
    /// The app refuses a bigger size, e.g. System Settings is at most 740 wide
    var maximumSizeForTest: CGSize? = nil
    /// Terminal takes whole lines and characters: the size is rounded to whole cells of this size
    var characterGridForTest: CGSize? = nil
    /// A whole frame is rounded up to the next line, the same size asked alone to the nearest one (Terminal answered 785
    /// to MarSpace's frame for 777.5, and 771 to the size)
    var frameAnswersALineMoreForTest = false
    /// The frames read back after sends, delivered by ``deliverReadBacksForTest()``. nil: delivered right away
    var heldReadBacksForTest: [(frame: Rect, generation: UInt, fitted: FittedFrame?)]? = nil
    /// When the frames are read back. nil: now
    var readBackInstantForTest: ContinuousClock.Instant? = nil
    var isMacosFullscreenForTest = false

    @MainActor
    private init(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        axRectForTest = rect
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: OpaqueWindowId, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }


    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    /// Frames that actually reached the window (unchanged frames are filtered by ``Window/setAxFrame(_:_:readBack:fitting:)``)
    private(set) var sentFrames: [(topLeft: CGPoint?, size: CGSize?)] = []

    override func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: UInt?, fitting: TileFitting?) {
        sentFrames.append((topLeft, size))
        let origin = topLeft ?? axRectForTest?.topLeftCorner ?? .zero
        var applied = apply(size ?? axRectForTest?.size ?? .zero)
        if frameAnswersALineMoreForTest, let size, let cell = characterGridForTest { applied.height = (size.height / cell.height).rounded(.up) * cell.height }
        var frame = Rect(topLeftX: origin.x, topLeftY: origin.y, width: applied.width, height: applied.height)
        var fitted: FittedFrame? = nil
        // Like the frame job of MacApp: the asks for less, and the place for what the window took
        if readBack != nil, let fitting, let size, let negotiation = fitting.negotiate(sent: size, got: applied, { request in
            sizeAsksForTest.append(request)
            applied = apply(request)
            return applied
        }) {
            let placed = fitting.topLeft(for: negotiation.fit)
            frame = Rect(topLeftX: placed.x, topLeftY: placed.y, width: applied.width, height: applied.height)
            fitted = FittedFrame(negotiation: negotiation, topLeft: placed, duration: .zero)
        }
        axRectForTest = frame
        guard let readBack else { return }
        if heldReadBacksForTest != nil {
            heldReadBacksForTest?.append((frame, readBack, fitted))
        } else {
            frameWasReadBack(frame, generation: readBack, fitted: fitted, at: readBackInstantForTest ?? .now)
        }
    }

    /// The sizes that the window was asked for after the first one of a frame, to fit into its tile (see ``TileFitting``)
    private(set) var sizeAsksForTest: [CGSize] = []

    /// What the app makes of `size`
    private func apply(_ size: CGSize) -> CGSize {
        var applied = size
        if let minimum = minimumSizeForTest {
            applied = CGSize(width: max(applied.width, minimum.width), height: max(applied.height, minimum.height))
        }
        if let maximum = maximumSizeForTest {
            applied = CGSize(width: min(applied.width, maximum.width), height: min(applied.height, maximum.height))
        }
        if let cell = characterGridForTest {
            applied = CGSize(
                width: (applied.width / cell.width).rounded() * cell.width,
                height: (applied.height / cell.height).rounded() * cell.height,
            )
        }
        return applied
    }

    @MainActor
    func deliverReadBacksForTest() {
        let readBacks = heldReadBacksForTest ?? []
        heldReadBacksForTest = []
        for (frame, generation, fitted) in readBacks { frameWasReadBack(frame, generation: generation, fitted: fitted, at: readBackInstantForTest ?? .now) }
    }

    override func closeAxWindow() {
        unbindAsClosed() // The same as MacWindow.garbageCollect
    }

    /// The title is an accessibility round trip to the app
    private(set) var titleReadsForTest = 0

    override func getTitle(_ cm: CancellationMode) async throws -> String {
        titleReadsForTest += 1
        return description
    }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        axRectForTest
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        axRectForTest.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Runs at the await point of the next native state read (e.g. a notification arrives, or the session is canceled)
    var onNativeStateReadForTest: (@MainActor () throws -> Void)? = nil

    @MainActor override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool {
        if let hook = onNativeStateReadForTest {
            onNativeStateReadForTest = nil
            try hook()
        }
        return isMacosFullscreenForTest
    }
}

extension OpaqueWindowId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}
