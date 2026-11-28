@testable import AppBundle
import AppKit
import Testing

/// What a window makes of its tile, and what it's asked for to fit into it (see ``SizeFit``). The apps are functions
/// from the size that they are asked for to the size that they take
@MainActor
@Suite
struct SizeFitTest {
    private let gaps = CGSize(width: 10, height: 10)

    /// Lines of 14 from 1, rounded up: Terminal answered 785 for a tile of 777.5 (two tabs)
    private static func linesRoundedUp(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: ((size.height - 1) / 14).rounded(.up) * 14 + 1)
    }

    /// Lines of 14 from 7, rounded to the nearest one
    private static func nearestLines(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: ((size.height - 7) / 14).rounded() * 14 + 7)
    }

    /// - Parameter minOffset: the tile is far from the edges of the screen by default
    private func fitting(_ tile: CGSize, known: SizeFit? = nil, centersX: Bool = true, minOffset: CGPoint = CGPoint(x: -1000, y: -1000)) -> TileFitting {
        TileFitting(tile: tile, origin: CGPoint(x: 10, y: 41), gaps: gaps, centersX: centersX, centersY: true, minOffset: minOffset, known: known)
    }

    /// Sends what the layout sends, and runs the asks of the frame job against `app`
    private func negotiate(_ tile: CGSize, known: SizeFit? = nil, _ app: (CGSize) -> CGSize) -> SizeFitNegotiation {
        let request = known.flatMap { $0.isSettled ? $0.request : nil } ?? tile
        return fitting(tile, known: known).negotiate(sent: request, got: app(request)) { app($0) }!
    }

    @Test func testWindowThatRoundsUpIsAskedForLessAndFitsIntoItsTile() {
        let tile = CGSize(width: 1265, height: 777.5)
        let negotiation = negotiate(tile, Self.linesRoundedUp)
        assertEquals(negotiation.answers.map(\.got.height), [785, 771])
        assertEquals(negotiation.fit.request, CGSize(width: 1265, height: 770))
        assertEquals(negotiation.fit.got, CGSize(width: 1265, height: 771))
        assertEquals(negotiation.fit.height, .roundedDown)
        assertEquals(negotiation.fit.width, .fits)
        // Centered: as much of the tile free above and below
        assertEquals(fitting(tile).topLeft(for: negotiation.fit), CGPoint(x: 10, y: 41 + 3.25))
    }

    /// The excess is subtracted, then twice and four times as much: a request a little below the tile still goes to the
    /// nearest line above
    @Test func testSmallExcessIsSubtractedTwiceAsMuchEachTime() {
        let negotiation = negotiate(CGSize(width: 500, height: 788), Self.nearestLines)
        assertEquals(negotiation.answers.map(\.request.height), [788, 785, 779])
        assertEquals(negotiation.answers.map(\.got.height), [791, 791, 777])
        assertEquals(negotiation.fit.height, .roundedDown)
    }

    @Test func testWindowThatRoundsDownIsntAskedAgain() {
        let tile = CGSize(width: 500, height: 783)
        let negotiation = negotiate(tile, Self.nearestLines)
        assertEquals(negotiation.answers.count, 1)
        assertEquals(negotiation.fit.height, .smaller)
        assertEquals(fitting(tile).topLeft(for: negotiation.fit), CGPoint(x: 10, y: 44))
    }

    /// A minimum of the app just above the tile: asking for less doesn't help, the window covers a part of the gaps
    @Test func testMinimumWithinAGapIsAskedForLessThreeTimes() {
        let tile = CGSize(width: 945, height: 1059)
        let negotiation = negotiate(tile) { CGSize(width: max($0.width, 951), height: $0.height) }
        assertEquals(negotiation.answers.map(\.request.width), [945, 939, 927, 903])
        assertEquals(negotiation.fit.width, .notSmaller)
        assertEquals(negotiation.fit.height, .fits)
        assertEquals(fitting(tile).topLeft(for: negotiation.fit), CGPoint(x: 7, y: 41))
    }

    /// App Store is at least 1000 wide: not a rounding, windows are moved off each other around it
    @Test func testRefusedSizeIsntAskedForLess() {
        let tile = CGSize(width: 945, height: 1059)
        let negotiation = negotiate(tile) { CGSize(width: max($0.width, 1000), height: $0.height) }
        assertEquals(negotiation.answers.count, 1)
        assertEquals(negotiation.fit.width, .refused)
        assertEquals(negotiation.fit.isBiggerThanTile, true)
        assertEquals(fitting(tile).topLeft(for: negotiation.fit), CGPoint(x: 10, y: 41))
    }

    /// Up to a point is the rounding of the tile: the window fits, it isn't asked for less
    @Test func testAPointMoreFits() {
        let tile = CGSize(width: 1265, height: 777.5)
        let negotiation = negotiate(tile) { CGSize(width: 1266, height: $0.height) }
        assertEquals(negotiation.answers.count, 1)
        assertEquals(negotiation.fit.width, .fits)
        assertEquals(negotiation.fit.size, tile)
    }

    /// Terminal rounds the width to characters and the height to lines
    @Test func testTheAxesAreFittedEachOnItsOwn() {
        let negotiation = negotiate(CGSize(width: 633, height: 777.5)) {
            CGSize(width: ($0.width / 7).rounded(.up) * 7, height: Self.linesRoundedUp($0).height)
        }
        assertEquals(negotiation.fit.got, CGSize(width: 630, height: 771))
        assertEquals(negotiation.fit.width, .roundedDown)
        assertEquals(negotiation.fit.height, .roundedDown)
    }

    /// The next layout sends what fits: the window answers the same, nothing more is asked
    @Test func testKnownFitIsntAskedAgain() {
        let tile = CGSize(width: 1265, height: 777.5)
        let known = negotiate(tile, Self.linesRoundedUp).fit
        let again = negotiate(tile, known: known, Self.linesRoundedUp)
        assertEquals(again.answers, [])
        assertEquals(again.fit, known)
    }

    /// The app answers otherwise than before (e.g. a tab bar appeared): it's asked for the tile again, and for less
    @Test func testChangedAnswerStartsOver() {
        let tile = CGSize(width: 1265, height: 777.5)
        let known = negotiate(tile, Self.linesRoundedUp).fit
        let negotiation = negotiate(tile, known: known, Self.nearestLines)
        assertEquals(negotiation.answers.map(\.request.height), [770, 777.5])
        assertEquals(negotiation.fit.request, tile)
        assertEquals(negotiation.fit.got.height, 777)
    }

    /// In a corner of the screen the window isn't asked for less: the layout asks when it's shown
    @Test func testFirstAnswerThatRoundsUpIsntSettled() {
        let tile = CGSize(width: 1265, height: 777.5)
        let fit = SizeFit.firstAnswer(tile: tile, got: CGSize(width: 1265, height: 785), gaps: gaps)
        assertEquals(fit.height, .roundsUp)
        assertEquals(fit.isSettled, false)
        let negotiation = negotiate(tile, known: fit, Self.linesRoundedUp)
        assertEquals(negotiation.fit.height, .roundedDown)
    }

    /// Along the orientation of a container that moves its children off each other, and not out of the screen
    @Test func testCenteringIsLimitedByTheContainerAndTheScreen() {
        let tile = CGSize(width: 945, height: 1059)
        let fit = SizeFit(tile: tile, request: tile, got: CGSize(width: 951, height: 1065), width: .notSmaller, height: .notSmaller, gaps: gaps)
        assertEquals(fitting(tile, centersX: false, minOffset: CGPoint(x: 0, y: -1)).topLeft(for: fit), CGPoint(x: 10, y: 40))
    }

    /// An app can answer another length along an axis that was done when the other one changes: every answer is
    /// classified along both
    @Test func testBothAxesAreClassifiedAtEveryAnswer() {
        let negotiation = negotiate(CGSize(width: 1000, height: 800)) { size in
            size.height < 800 ? CGSize(width: 1015, height: size.height) : CGSize(width: size.width, height: 806)
        }
        assertEquals(negotiation.fit.width, .refused)
        assertEquals(negotiation.fit.isBiggerThanTile, true)
    }

    /// A fit is known with the gaps that it was classified with: with a gap of 0, 5 more is a minimum of the app, with a
    /// gap of 10 it's asked for less
    @Test func testFitOfOtherGapsIsntReused() {
        let tile = CGSize(width: 1000, height: 1059)
        let app: (CGSize) -> CGSize = { CGSize(width: $0.width, height: max($0.height, 1064)) }
        let withoutGaps = SizeFit.firstAnswer(tile: tile, got: app(tile), gaps: .zero)
        assertEquals(withoutGaps.height, .refused)
        let negotiation = negotiate(tile, known: withoutGaps, app)
        assertEquals(negotiation.fit.height, .notSmaller)
        assertEquals(negotiation.fit.gaps, gaps)
    }
}
