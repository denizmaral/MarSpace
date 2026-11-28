import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: OpaqueWindowId
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    /// In a column of a scrolling workspace that is off the screen: it waits in the bottom right corner of the screen with
    /// a pixel of it on the screen, next to the Dock (see ``Layout/scrolling``). Not a target of the mouse. Set by the
    /// layout of the tiling tree
    var isParkedOffTheScreen: Bool = false
    /// A pinned floating window is on the workspace that its monitor shows. See ``PinCommand``
    var isPinned: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    var lifeStatus: WindowLifeStatus = .alive
    /// The sibling that gave half of its weight to this window (see `applyDwindleSplit`). It takes the weight back on close
    weak var dwindleSplitAnchor: TreeNode? = nil
    /// The last `swap` of the window in a direction: the opposite direction right after it swaps the windows back
    var lastDirectionalSwap: DirectionalSwap? = nil
    /// See ``setAxFrame(_:_:readBack:fitting:)``
    private var sentFrame: SentFrame? = nil
    /// Where the window is on the screen, as far as AeroSpace knows, without accessibility calls. Unlike the tile
    /// (``lastAppliedLayoutPhysicalRect``: the place in the tree), it's what the user sees: a window refuses a size
    /// smaller than its minimum (App Store is at least 1000 wide), or snaps to its character grid (Terminal).
    ///
    /// The frame that was sent, corrected when it's read back in the same accessibility job (``frameWasReadBack(_:generation:)``).
    /// Floating windows are read by every layout (``observeFrame(_:)``). Code that deals with the screen (the focus
    /// border, focus-follows-mouse) uses it, the layout and the tree commands use the tile
    private(set) var observedFrame: Rect? = nil
    /// What the window made of the last tiles that it was given, and what it's asked for in them (see ``SizeFit``): an
    /// app can refuse a size (App Store is at least 1000 wide, System Settings at most 740), or round it (Terminal). The
    /// same tile gets the same answer again, wherever the window is (e.g. after a workspace switch hid it in a corner of
    /// the screen). A few: the size of its tile comes back after macOS fullscreen, or after a window was opened next to
    /// it and closed again. The most recent first
    private var fits: [SizeFit] = []
    private static let rememberedFits = 4
    /// The fittings in a row that asked the window for less and ended at the fit that was known: it answered the whole
    /// frame otherwise than the asks for less. See ``searchesFit(inTile:)``
    private var refits: (tile: CGSize, count: Int)? = nil
    private static let maxRefits = 2
    /// The refresh sessions that were asked for in a row because of what the window made of its tile. See
    /// ``learn(_:isFitted:at:)``
    private var layoutRequestsAfterReadBack: (count: Int, last: ContinuousClock.Instant)? = nil
    /// Identifies the latest knowledge about the frame: a read back of an older send is stale
    private var frameGeneration: UInt = 0
    /// The native state (minimized, fullscreen) may have changed. See normalizeLayoutReason
    var isNativeStateCheckRequested: Bool = false
    /// The place in the tiling tree before a macOS native state. See ``enterMacosNativeState(_:prevParentKind:adaptiveWeight:)``
    var tilingSlot: TilingSlot? = nil
    /// The window floats because its workspace floats (see ``WorkspaceLayout/floating``): it's a tile again when the
    /// workspace tiles or scrolls, or when it's moved to a workspace that does. Not a window that floats on its own
    /// account (a dialog, `layout floating`)
    var isFloatedByWorkspaceLayout = false
    /// The user made the window a tile on this floating workspace (`layout tiling`): it stays a tile there
    weak var tiledOnFloatingWorkspace: Workspace? = nil
    /// The frame that the floating layout gives the window when its workspace is shown, see ``floatByWorkspaceLayout(on:)``
    var floatingFrameToApply: Rect? = nil
    /// Where the window was when its workspace stopped floating: it goes back there when the workspace floats again
    var floatingFrameOfWorkspaceLayout: Rect? = nil
    /// The window is popped out (`pop-out`): what it was before
    var poppedOut: PoppedOutOrigin? = nil
    /// Where the window was the last time it was popped out: it pops out there again
    var lastPoppedOutFrame: Rect? = nil

    @MainActor
    init(id: OpaqueWindowId, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: OpaqueWindowId) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor static func get(byNativeId nativeWindowId: UInt32, pid: pid_t) -> Window? {
        MacApp.allAppsMap[pid]?.opaqueWindowId(of: nativeWindowId).flatMap { get(byId: $0) }
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    @MainActor
    @discardableResult
    override func bind(to newParent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> BindingData? {
        // Placed somewhere else (e.g. moved by a command) while in a macOS native state: it doesn't go back to its old place
        if tilingSlot != nil,
           !(newParent is MacosFullscreenWindowsContainer || newParent is MacosHiddenAppsWindowsContainer || newParent is MacosMinimizedWindowsContainer)
        {
            tilingSlot = nil
        }
        if newParent is TilingContainer { // Tiled: it has its place in the layout of one workspace
            isPinned = false
            poppedOut = nil
        }
        return super.bind(to: newParent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// Unbinds the window that was closed
    @MainActor
    @discardableResult
    final func unbindAsClosed() -> BindingData {
        returnWeightToDwindleSplitAnchor()
        return unbindFromParent()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    @MainActor func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }

    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false }
    @MainActor func getMacosWindowNativeState(_ cm: CancellationMode) async throws -> MacosWindowNativeState {
        if try await isMacosFullscreen(cm) { return .nativeFullscreen }
        if try await isMacosMinimized(cm) { return .nativeMinimized }
        return .normal
    }

    var isHiddenInCorner: Bool { die("Not implemented") }

    /// Where the top left corner of the window goes to hide it in `corner` of `visibleRect` (see `MacWindow.hideInCorner`)
    /// - Parameter width: of the window, for the bottom left corner: its right edge is at the left edge of the screen
    func topLeftHidden(in corner: OptimalHideCorner, width: CGFloat, of visibleRect: Rect) -> CGPoint {
        switch corner {
            case .bottomLeftCorner: visibleRect.bottomLeftCorner + CGPoint(x: 1 - width, y: -1)
            case .bottomRightCorner: visibleRect.bottomRightCorner - CGPoint(x: 1, y: 1)
        }
    }
    @MainActor func nativeFocus() { die("Not implemented") }
    @MainActor func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    /// Sends the frame to the window, unless exactly the same frame was already sent.
    ///
    /// The layout runs at the end of every refresh session, and most of the time nothing changes. Each send costs
    /// several accessibility round trips to the app (and wakes the app up), so unchanged frames are skipped. The sent
    /// frame is forgotten (``invalidateSentFrame()``) whenever the window may have been moved or resized by somebody
    /// else: AX moved/resized notifications, failed AX writes, app activation, Space/display changes, wake, etc.
    ///
    /// - Parameter readBack: read the frame back after it's applied, see ``observedFrame``. Not needed for a window that
    ///   is hidden in a corner of the screen
    /// - Parameter fitting: the window is a tile on the screen: the job of its app fits it into its tile (see
    ///   ``TileFitting``), `size` is what it's asked for first (``request(forTile:)``)
    @MainActor
    final func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: Bool = true, fitting: TileFitting? = nil) {
        // Placed by something else (e.g. hidden with its workspace, made floating): a slide doesn't take it back
        if !ScrollAnimation.isWriting { ScrollAnimation.stop(self) }
        let frame = SentFrame(topLeft: topLeft, size: size)
        if frame == sentFrame { return }
        sentFrame = frame
        frameGeneration &+= 1
        // Until it's read back: what the window is expected to make of it
        // The layout runs in a refresh session, which updates the focus border at its end
        if let origin = topLeft ?? observedFrame?.topLeftCorner, let size = size.map(expectedSize(of:)) ?? observedFrame?.size {
            setObservedFrame(Rect(topLeftX: origin.x, topLeftY: origin.y, width: size.width, height: size.height), updatesFocusBorder: false)
        }
        sendAxFrame(topLeft, size, readBack: readBack ? frameGeneration : nil, fitting: readBack ? fitting : nil)
    }

    /// What the window makes of `request`, as far as it's known: its answer the last time, otherwise `request` itself
    /// (most windows accept it)
    private func expectedSize(of request: CGSize) -> CGSize {
        fits.first(where: { $0.request == request })?.got ?? request
    }

    private func remember(_ fit: SizeFit) {
        fits.removeAll(where: { $0.tile == fit.tile })
        fits.insert(fit, at: 0)
        if fits.count > Self.rememberedFits { fits.removeLast() }
    }

    /// What the window made of `tile` the last time, nil if it's not known
    final func fit(forTile tile: CGSize) -> SizeFit? {
        fits.first(where: { $0.tile == tile })
    }

    /// What the window is asked for in `tile`: the size that fits into it, as far as it's known, otherwise the tile
    final func request(forTile tile: CGSize) -> CGSize {
        fit(forTile: tile).flatMap { $0.isSettled ? $0.request : nil } ?? tile
    }

    /// The window is asked for less in `tile` if it rounds it up (see ``TileFitting/searches``). Not after
    /// ``maxRefits`` fittings in a row that ended at the known fit: the window answers the whole frame otherwise than
    /// the asks for less (Terminal answered 785 to a frame with a height of 777.5, and 771 to the same size alone). Every
    /// layout would ask again, and the asks move the window, which lays it out again (its notifications). It's placed for
    /// what it makes of the frame then, until its tile changes
    final func searchesFit(inTile tile: CGSize) -> Bool {
        guard let refits, refits.tile == tile else { return true }
        return refits.count < Self.maxRefits
    }

    /// See ``searchesFit(inTile:)``
    @MainActor
    private func countRefit(_ negotiation: SizeFitNegotiation, known: SizeFit?) {
        let tile = negotiation.fit.tile
        guard searchesFit(inTile: tile) else { return }
        guard negotiation.askedAgain, let known, known.isSettled, negotiation.fit == known else {
            if refits?.tile == tile { refits = nil } // It answered as known, or something new
            return
        }
        let count = (refits?.tile == tile ? refits?.count ?? 0 : 0) + 1
        refits = (tile, count)
        if count == Self.maxRefits {
            layoutLogger.notice("window \(self.windowId, privacy: .public) of \(self.app.name ?? "?", privacy: .public) answers the frame otherwise than the asks for less in tile \(tile.debugDescription, privacy: .public): it isn't asked for less there anymore")
        }
    }

    /// The size of the window in `tile`, as far as it's known (see ``SizeFit/size``)
    final func size(inTile tile: CGSize) -> CGSize {
        (fit(forTile: tile) ?? .assumed(tile)).size
    }

    /// The window reaches beyond the gap after its tile, as far as it's known: it covers a part of the tile next to it.
    /// Windows are moved off each other only then (see `TilingContainer.layoutTiles`). A window that reaches only into
    /// the gap covers nothing
    @MainActor
    final var isBiggerThanTile: Bool {
        guard let tile = lastAppliedLayoutPhysicalRect?.size else { return false }
        return (fit(forTile: tile) ?? .assumed(tile)).isBiggerThanTile(gaps: config.gaps.inner.size)
    }

    /// The next ``setAxFrame(_:_:readBack:fitting:)`` sends the frame even if it's the same as the previous one
    @MainActor
    final func invalidateSentFrame() {
        sentFrame = nil
        frameGeneration &+= 1 // The window may have moved since a read back that is under way
    }

    /// - Parameter generation: the send that the frame was read back for
    /// - Parameter fitted: the job of the app fitted the window into its tile (see ``TileFitting``)
    @MainActor
    final func frameWasReadBack(_ frame: Rect, generation: UInt, fitted: FittedFrame? = nil, at now: ContinuousClock.Instant = .now) {
        // What the window makes of its tile is the app's: learned also if the window was sent another frame or moved
        // meanwhile (the asks for less move it, macOS reports that)
        if let fitted {
            logFitting(fitted)
            countRefit(fitted.negotiation, known: fit(forTile: fitted.negotiation.fit.tile))
            learn(fitted.negotiation.fit, at: now)
        }
        guard generation == frameGeneration else { return } // Sent again or moved meanwhile: a newer read back follows
        if let fitted { // Where the job put it: the next layout with the same fit sends nothing
            sentFrame = SentFrame(topLeft: fitted.topLeft, size: fitted.negotiation.fit.request)
        } else if let asked = sentFrame?.size, !fits.contains(where: { $0.isSettled && $0.request == asked && $0.request != $0.tile }) {
            // E.g. in a corner of the screen: what it made of the size of its tile. A size that fits it into a tile stays
            // what it is, the window is asked again when it's shown
            learn(.firstAnswer(tile: asked, got: frame.size, gaps: config.gaps.inner.size), at: now)
        }
        // It arrives after the session that sent the frame (it doesn't matter if another session is running)
        setObservedFrame(frame, updatesFocusBorder: true)
    }

    /// An app is expected to make the same of the same size every time. A window that doesn't isn't followed forever:
    /// every layout that moves it would ask for the next one. After a quiet second, it's followed again
    private static let maxLayoutRequestsAfterReadBack = 3
    private static let layoutRequestsAfterReadBackQuietInterval: Duration = .seconds(1)

    /// The layout that sent the frame didn't know the fit yet, or the window changed its mind: the windows are laid out
    /// again if that can move one of them. A window on the screen was put at its place by the job of its app (see
    /// ``TileFitting``), and windows are moved off each other only around a window that is bigger than its tile. So a
    /// window that only rounds the size of its tile doesn't cost a refresh session.
    ///
    /// Only a changed fit for a tile counts towards ``maxLayoutRequestsAfterReadBack``: the layout that the first fit
    /// asks for knows it. The tiles change many times a second while a key repeats a resize or a border is dragged,
    /// and the last fit counts
    @MainActor
    private func learn(_ fit: SizeFit, at now: ContinuousClock.Instant) {
        let known = self.fit(forTile: fit.tile)
        if known == fit { return }
        let wasBiggerThanTile = isBiggerThanTile
        remember(fit)
        guard lastAppliedLayoutPhysicalRect?.size == fit.tile, fit.size != (known ?? .assumed(fit.tile)).size else { return }
        guard wasBiggerThanTile ||
            nodeWorkspace?.rootTilingContainer.allLeafWindowsRecursive
            .contains(where: { $0.lifeStatus.isInhabited && $0.isBiggerThanTile }) == true
        else { return }
        if known != nil {
            let inARow = layoutRequestsAfterReadBack
                .flatMap { now - $0.last < Self.layoutRequestsAfterReadBackQuietInterval ? $0.count : nil } ?? 0
            guard inARow < Self.maxLayoutRequestsAfterReadBack else { return }
            layoutRequestsAfterReadBack = (inARow + 1, now)
        }
        scheduleCancellableCompleteRefreshSession(.frameReadBack)
    }

    /// A fitting longer than this is logged as an error: the app was slow to answer its asks
    private static let slowFitting: Duration = .milliseconds(100)

    /// A fitting that asked the window for another size than the first one (the first time it got a tile, or the app
    /// changed its mind) is logged with every ask. At the debug level (zero cost unless the log is streamed: a dragged
    /// border gives the window next to it a new tile many times a second), as a notice (kept: `log show` finds it) if it
    /// didn't get the window into its tile: it reaches into the gaps
    @MainActor
    private func logFitting(_ fitted: FittedFrame) {
        let negotiation = fitted.negotiation
        guard negotiation.askedAgain else { return }
        let fit = negotiation.fit
        let asks = negotiation.answers.lazy.map { "\($0.request.debugDescription) got \($0.got.debugDescription)" }.joined(separator: ", ")
        let line = "window \(windowId) of \(app.name ?? "?") in tile \(fit.tile.debugDescription): width \(fit.width), height \(fit.height) after \(negotiation.answers.count) asks (\(asks)) in \(fitted.duration.milliseconds) ms"
        if fit.width == .notSmaller || fit.height == .notSmaller {
            layoutLogger.notice("\(line, privacy: .public): it reaches into the gaps")
        } else {
            layoutLogger.debug("\(line, privacy: .public)")
        }
        if fitted.duration > Self.slowFitting { perfLogger.error("slow size fitting: \(line, privacy: .public)") }
    }

    /// - Parameter frame: read from the window just now
    @MainActor
    final func observeFrame(_ frame: Rect) {
        frameGeneration &+= 1 // Newer than a read back that is under way
        setObservedFrame(frame, updatesFocusBorder: false) // Read by the layout, in a refresh session
    }

    @MainActor
    private func setObservedFrame(_ frame: Rect, updatesFocusBorder: Bool) {
        if frame == observedFrame { return }
        observedFrame = frame
        if updatesFocusBorder { FocusBorderController.shared.windowFrameDidChange(self) }
    }

    /// Use ``setAxFrame(_:_:readBack:fitting:)``
    ///
    /// - Parameter readBack: the generation to report the frame with to ``frameWasReadBack(_:generation:fitted:at:)``,
    ///   nil if it's not needed
    /// - Parameter fitting: see ``TileFitting``, only with `readBack`
    @MainActor
    func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: UInt?, fitting: TileFitting?) { die("Not implemented") }
}

private struct SentFrame: Equatable {
    // periphery:ignore - only compared (Equatable)
    let topLeft: CGPoint?
    /// What the window was asked for, see `Window.expectedSize(of:)`
    let size: CGSize?
}

enum MacosWindowNativeState: Sendable {
    case normal
    case nativeMinimized
    case nativeFullscreen
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: WindowParentCases.Kind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case nil: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}

/// What a floating window is on its own account: pinned, popped out. A binding as a tile ends it (see
/// ``Window/bind(to:adaptiveWeight:index:)``): a window that is a tile only for a moment gets it back (the focus commands
/// see the floating windows as tiles, a restore of a tree puts them at their places in it)
struct FloatingOwnState {
    fileprivate let isPinned: Bool
    fileprivate let poppedOut: PoppedOutOrigin?
}

extension Window {
    var floatingOwnState: FloatingOwnState {
        get { FloatingOwnState(isPinned: isPinned, poppedOut: poppedOut) }
        set {
            isPinned = newValue.isPinned
            poppedOut = newValue.poppedOut
        }
    }
}

extension Window {
    /// What a change of the tree and a layout can change of the window besides its node (see `tryOut`)
    struct PlaceState {
        fileprivate let isFullscreen: Bool
        fileprivate let isParkedOffTheScreen: Bool
        fileprivate let floatingOwnState: FloatingOwnState
        fileprivate let dwindleSplitAnchor: TreeNode?
        fileprivate let tilingSlot: TilingSlot?
    }

    var placeState: PlaceState {
        PlaceState(
            isFullscreen: isFullscreen,
            isParkedOffTheScreen: isParkedOffTheScreen,
            floatingOwnState: floatingOwnState,
            dwindleSplitAnchor: dwindleSplitAnchor,
            tilingSlot: tilingSlot,
        )
    }

    func restore(_ state: PlaceState) {
        isFullscreen = state.isFullscreen
        isParkedOffTheScreen = state.isParkedOffTheScreen
        floatingOwnState = state.floatingOwnState
        dwindleSplitAnchor = state.dwindleSplitAnchor
        tilingSlot = state.tilingSlot
    }
}
