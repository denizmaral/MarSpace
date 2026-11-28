import AppKit
import Common

/// What a window makes of the size of its tile, and what it's asked for to fit into it.
///
/// An app decides the size of its window, MarSpace can only ask for one: App Store is at least 1000 wide, System
/// Settings at most 740, Terminal takes whole lines and characters. A window doesn't cover the gaps around its tile
/// unless the app refuses to be that small (like a tiled window of Hyprland: it's clamped only by the minimum and the
/// maximum of the app). A window that rounds the size of its tile up is asked for less until it fits
/// (``SizeFitSearch``), and it's centered on its tile: it leaves as much of it free on both sides. What it took is
/// remembered (`Window.fits`): the next layout with the same tile sends the size that fits right away.
///
/// The axes are independent: Terminal rounds the width to characters and the height to lines.
struct SizeFit: Sendable, Equatable {
    /// What the window makes of the length of its tile along one axis
    enum Axis: Sendable, Equatable {
        /// The length of the tile, within ``SizeFit/tolerance``
        case fits
        /// Smaller than the tile when it's asked for the tile: a maximum of the app (System Settings is at most 740
        /// wide), or it rounds the tile down
        case smaller
        /// It rounded the tile up, and a smaller ask gave a length in the tile: it snaps to a grid (Terminal)
        case roundedDown
        /// Bigger than the tile by at most a gap, and asking for less didn't help: a minimum of the app just above the tile
        case notSmaller
        /// Bigger than the tile by at most a gap, nothing smaller was asked yet: it was read back in a corner of the
        /// screen. The layout asks for less when the window is shown
        case roundsUp
        /// Bigger than the tile by more than a gap: a minimum of the app (App Store is at least 1000 wide). Windows are
        /// moved off each other around it (see `TilingContainer.packingShifts`)
        case refused
    }

    let tile: CGSize
    /// What the window is asked for in this tile
    let request: CGSize
    /// What the window made of `request`
    let got: CGSize
    let width: Axis
    let height: Axis
    /// The gaps that the axes were classified with: a fit is known only with the same gaps (another gap can make a
    /// refused length a rounding)
    let gaps: CGSize

    /// A difference of up to a point is the rounding of a tile (tiles aren't whole points), not of the window
    static let tolerance: CGFloat = 1
    /// How many times a window that rounds the length of its tile up is asked for less
    static let maxLowerings = 3

    /// Nothing is known about the window: most windows take the size of their tile
    static func assumed(_ tile: CGSize, gaps: CGSize) -> SizeFit {
        SizeFit(tile: tile, request: tile, got: tile, width: .fits, height: .fits, gaps: gaps)
    }

    /// What a window made of `request` in its tile, nothing smaller asked (it waits in a corner of the screen, or it
    /// isn't asked for less in this tile anymore: see ``TileFitting/searches``)
    static func firstAnswer(tile: CGSize, request: CGSize? = nil, got: CGSize, gaps: CGSize) -> SizeFit {
        SizeFit(
            tile: tile,
            request: request ?? tile,
            got: got,
            width: classify(got.width, tile: tile.width, gap: gaps.width),
            height: classify(got.height, tile: tile.height, gap: gaps.height),
            gaps: gaps,
        )
    }

    /// See ``firstAnswer(tile:request:got:gaps:)``
    fileprivate static func classify(_ got: CGFloat, tile: CGFloat, gap: CGFloat) -> Axis {
        let excess = got - tile
        if abs(excess) <= tolerance { return .fits }
        if excess < 0 { return .smaller }
        return excess > gap ? .refused : .roundsUp
    }

    /// The window was asked for less wherever it rounded the tile up: the fit holds while the window answers the same
    var isSettled: Bool { width != .roundsUp && height != .roundsUp }

    /// The size of the window in its tile, as the layout counts it: exactly the tile where it fits (tiles aren't whole
    /// points, a window that fits never moves a sibling by a rounding error)
    var size: CGSize {
        CGSize(width: width == .fits ? tile.width : got.width, height: height == .fits ? tile.height : got.height)
    }

    /// Where the window goes on its tile, from the top left corner of the tile. A window that rounds the size of its tile
    /// is centered on it: it leaves as much of it free on both sides (or covers as much of the gaps, when the app
    /// refuses to be smaller). A window that is smaller than its tile by more than a gap at the first ask (a maximum
    /// of the app), or bigger by more than a gap (a minimum), stays at the start of its tile, where windows are moved
    /// off each other (see `TilingContainer.layoutTiles`)
    var centering: CGPoint {
        func centering(_ axis: Axis, _ length: CGFloat, _ tileLength: CGFloat, gap: CGFloat) -> CGFloat {
            let difference = length - tileLength
            return switch axis {
                case .fits, .refused: 0
                case .roundedDown, .notSmaller, .roundsUp: -difference / 2
                case .smaller: -difference <= gap ? -difference / 2 : 0
            }
        }
        let size = size
        return CGPoint(
            x: centering(width, size.width, tile.width, gap: gaps.width),
            y: centering(height, size.height, tile.height, gap: gaps.height),
        )
    }

    /// The window covers a part of the tile next to it, beyond the gap: windows are moved off each other around it
    var isBiggerThanTile: Bool {
        let size = size
        return size.width - tile.width > gaps.width || size.height - tile.height > gaps.height
    }
}

/// What a window made of a size that it was asked for
struct SizeAnswer: Sendable, Equatable {
    let request: CGSize
    let got: CGSize
}

/// Asks a window for less, along each axis where it rounds the length of its tile up, until the length is in the tile:
/// the excess, then twice and four times as much (an app that rounds to the nearest line goes to the line below once
/// the request is more than half a line below the line above). An app that answers the same to every smaller ask has a
/// minimum there (``SizeFit/Axis/notSmaller``): it's asked for at most ``SizeFit/maxLowerings`` smaller sizes.
struct SizeFitSearch: Sendable {
    let tile: CGSize
    let gaps: CGSize
    private(set) var request: CGSize
    private(set) var answers: [SizeAnswer] = []
    private var width: AxisSearch
    private var height: AxisSearch

    /// The window is asked for the size of the tile first
    init(tile: CGSize, gaps: CGSize) {
        self.tile = tile
        self.gaps = gaps
        request = tile
        width = AxisSearch(tile: tile.width, gap: gaps.width)
        height = AxisSearch(tile: tile.height, gap: gaps.height)
    }

    /// The window made `got` of `request`
    /// - Returns: the size to ask for next, nil if the fit is known (``result``)
    mutating func answer(_ got: CGSize) -> CGSize? {
        answers.append(SizeAnswer(request: request, got: got))
        let nextWidth = width.answer(got.width, request: request.width)
        let nextHeight = height.answer(got.height, request: request.height)
        guard nextWidth != nil || nextHeight != nil else { return nil }
        request = CGSize(width: nextWidth ?? request.width, height: nextHeight ?? request.height)
        return request
    }

    /// The last ask and its answer
    var result: SizeFit {
        SizeFit(
            tile: tile,
            request: answers.last?.request ?? tile,
            got: answers.last?.got ?? tile,
            width: width.axis ?? .notSmaller,
            height: height.axis ?? .notSmaller,
            gaps: gaps,
        )
    }
}

private struct AxisSearch: Sendable {
    let tile: CGFloat
    let gap: CGFloat
    /// nil while the window is asked for less
    private(set) var axis: SizeFit.Axis? = nil
    private var lowerings = 0

    init(tile: CGFloat, gap: CGFloat) {
        self.tile = tile
        self.gap = gap
    }

    /// Every answer is classified, also along an axis that is done: an app can answer another length along it when the
    /// other one changes
    ///
    /// - Returns: the next request, nil if the axis is done
    mutating func answer(_ got: CGFloat, request: CGFloat) -> CGFloat? {
        switch SizeFit.classify(got, tile: tile, gap: gap) {
            case .fits:
                axis = .fits
            case .smaller:
                axis = lowerings == 0 ? .smaller : .roundedDown
            case .refused: // Also after a smaller ask: what the app does, not a rounding
                axis = .refused
            case .roundsUp where lowerings == SizeFit.maxLowerings:
                axis = .notSmaller
            case .roundsUp:
                let next = max(1, request - (got - tile) * CGFloat(1 << lowerings))
                lowerings += 1
                return next
            case .roundedDown, .notSmaller:
                die("SizeFit.classify gives no such axis")
        }
        return nil
    }
}

/// What the frame job of a tiling window needs to fit it into its tile on the thread of its app (see ``SizeFit``): the
/// asks for less and the final position don't wait for the main thread, or for another refresh session
struct TileFitting: Sendable, Equatable {
    let tile: CGSize
    /// The top left corner of the tile, moved by its container (see `TilingContainer.packingShifts`)
    let origin: CGPoint
    let gaps: CGSize
    /// Along the orientation of a container that moves its children off each other, the windows aren't centered: they
    /// are next to each other then, at the gap
    let centersX: Bool
    let centersY: Bool
    /// The least offset from the tile: a window isn't centered out of the screen where its tile is at the edge (macOS
    /// keeps windows below the menu bar, a part of the window would show on the monitor next to it)
    let minOffset: CGPoint
    /// What the window made of this tile the last time, nil if it's not known
    let known: SizeFit?
    /// The window is asked for less if it rounds the tile up. Not a window that answers the whole frame otherwise than
    /// the asks for less, every time (see `Window.searchesFit(inTile:)`): every layout would ask again
    var searches = true

    /// Where the window goes with `fit`
    func topLeft(for fit: SizeFit) -> CGPoint {
        let centering = fit.centering
        return CGPoint(
            x: origin.x + (centersX ? max(centering.x, minOffset.x) : 0),
            y: origin.y + (centersY ? max(centering.y, minOffset.y) : 0),
        )
    }

    /// The fit of the window in the tile: the known one, unless the window answers otherwise now. Then it's asked for
    /// the tile again, and for less (see ``SizeFitSearch``)
    ///
    /// - Parameter request: what was sent
    /// - Parameter got: what the window made of it
    /// - Parameter ask: sends a size to the window and reads what it made of it, nil if it can't
    /// - Returns: nil if an ask failed
    func negotiate(sent request: CGSize, got: CGSize, _ ask: (CGSize) throws -> CGSize?) rethrows -> SizeFitNegotiation? {
        if let known, known.isSettled, known.gaps == gaps, known.request == request, got.isClose(to: known.got) {
            return SizeFitNegotiation(fit: known, answers: [])
        }
        guard searches else { // It's placed for what it made of the frame
            return SizeFitNegotiation(fit: .firstAnswer(tile: tile, request: request, got: got, gaps: gaps), answers: [])
        }
        var search = SizeFitSearch(tile: tile, gaps: gaps)
        var answer = got
        var asks: [SizeAnswer] = []
        if request != tile { // A smaller size was sent, and the window answered otherwise than before: it starts over
            asks.append(SizeAnswer(request: request, got: got))
            guard let got = try ask(tile) else { return nil }
            answer = got
        }
        while let next = search.answer(answer) {
            guard let got = try ask(next) else { return nil }
            answer = got
        }
        return SizeFitNegotiation(fit: search.result, answers: asks + search.answers)
    }
}

/// The outcome of ``TileFitting/negotiate(sent:got:_:)``
struct SizeFitNegotiation: Sendable, Equatable {
    let fit: SizeFit
    /// Every ask of the frame job and its answer, the first one too. Empty if the window answered as known
    let answers: [SizeAnswer]

    /// The window was asked for another size than the first one: it's moved to its place for the fit
    var askedAgain: Bool { answers.count > 1 }
}

extension CGSize {
    /// Within half a point
    fileprivate func isClose(to other: CGSize) -> Bool {
        abs(width - other.width) <= 0.5 && abs(height - other.height) <= 0.5
    }
}

/// What the frame job of the app reports of a fitting (see ``TileFitting``)
struct FittedFrame: Sendable {
    let negotiation: SizeFitNegotiation
    /// Where the job put the window
    let topLeft: CGPoint?
    /// Of the asks after the first answer
    let duration: Duration
}

extension Gaps.Inner {
    /// The gap between two windows side by side (width), and between two above each other (height)
    var size: CGSize { CGSize(width: horizontal, height: vertical) }
}
