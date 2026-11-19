import AppKit
import Common

/// Draws the focus border (Settings › Appearance) around the focused window.
///
/// The border is drawn by a click-through panel that is `width` points bigger than the window on every side, so the
/// border lives in the gap around the window. The panel is right below the window, the border shows in the gap: nothing
/// of MarSpace covers the window. macOS hides the buttons of a secure dialog (the purchase sheet of App Store, a password
/// or permission prompt) while a window of another app is over it: they stayed hidden under a panel above the window.
///
/// The panel follows the observed frame of the window (``Window/observedFrame``, what the user sees, not the tile) and is
/// updated synchronously: at the end of every refresh session, and when the frame of the focused window is read back
/// after a session. There is no polling.
@MainActor
final class FocusBorderController {
    static let shared = FocusBorderController()

    private var panel: FocusBorderPanel? = nil
    private var drawnAppearance: Appearance? = nil
    /// A window is moved or resized with the mouse. The border is updated at the end of refresh sessions, it can't follow
    /// the window frame by frame: it's hidden until the mouse button is released
    private var isHiddenForMouseDrag = false
    /// See ``update()``
    private var stackingRecheck: Task<(), any Error>? = nil
    /// Updates for read backs of the focused window, see ``windowFrameDidChange(_:)``
    private(set) var readBackUpdates: UInt = 0
    /// The window and the panel frame for which the panel was found right below the window, and nothing happened since
    /// that can restack the windows (see ``stackingMayHaveChanged()``): the window server isn't asked again. Most
    /// refresh sessions (a command, a shortcut, a click) change neither the focus, nor the frame, nor the stacking
    private var verifiedStacking: (window: UInt32, frame: CGRect, placement: FocusBorderPlacement)? = nil

    // periphery:ignore - the properties are only compared (Equatable)
    private struct Appearance: Equatable {
        let size: CGSize
        let border: FocusBorder
    }

    private init() {}

    func update() { update(isStackingRecheck: false) }

    private func update(isStackingRecheck: Bool) {
        if isUnitTest { return }
        if isHiddenForMouseDrag && !isLeftMouseButtonDown {
            isHiddenForMouseDrag = false // The mouse up event was missed
        }
        let border = config.focusBorder
        guard border.enabled,
              !isHiddenForMouseDrag,
              !isHiddenForSpaceChange,
              TrayMenuModel.shared.isEnabled,
              !MissionControl.isActive,
              let window = globalFocus.windowOrNil as? MacWindow,
              let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId),
              let windowFrame = window.focusBorderRect
        else { return hide() }
        let windowRect = focusBorderWindowRect(windowFrame, monitor: window.nodeMonitorInfo?.rect, borderWidth: border.width)
        guard windowRect.width > 0, windowRect.height > 0 else { return hide() }
        let panel = getOrCreatePanel()
        let frame = focusBorderPanelFrame(windowRect: windowRect, borderWidth: border.width, mainMonitorHeight: mainMonitorInfo.height)
        let verified = isStackingRecheck || !panel.isVisible
            ? nil
            : verifiedStacking.flatMap { $0.window == nativeWindowId && $0.frame == frame ? $0.placement : nil }
        let stacking = verified.map { .onScreen($0, isPanelInPlace: true) } ?? windowStacking(
            of: nativeWindowId,
            pid: window.macApp.pid,
            panel: panel.isVisible ? CGWindowID(panel.windowNumber) : nil,
            windowFrame: CGRect(x: windowFrame.topLeftX, y: windowFrame.topLeftY, width: windowFrame.width, height: windowFrame.height),
            // A window beyond the edge of the monitor: the border follows the edge, over the window
            isBorderOverTheWindow: windowRect != windowFrame,
        )
        guard case .onScreen(let placement, let isPanelInPlace) = stacking else { return hide() }
        verifiedStacking = isPanelInPlace ? (nativeWindowId, frame, placement) : nil

        let appearance = Appearance(size: frame.size, border: border)
        if drawnAppearance != appearance {
            panel.draw(size: frame.size, border)
            drawnAppearance = appearance
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        // The panel must be right next to the window (see FocusBorderPlacement). The window server raises the window of a
        // newly activated app asynchronously: checked once more a moment later, the raise may still be under way
        if !isPanelInPlace {
            panel.order(placement == .below ? .below : .above, relativeTo: Int(nativeWindowId))
            if !isStackingRecheck {
                stackingRecheck?.cancel()
                stackingRecheck = Task.startUnstructured { @MainActor in
                    try await Task.sleep(for: .milliseconds(250))
                    self.update(isStackingRecheck: true) // The singleton
                }
            }
        }
    }

    /// Something happened that can change the order of the windows on the screen: an accessibility event of an app
    /// (a window was created, focused, moved, resized, closed), an app was activated, the Space changed, a click. The
    /// next update asks the window server where the panel is
    func stackingMayHaveChanged() {
        verifiedStacking = nil
    }

    /// The frame of a window was read back after the refresh session that sent it
    func windowFrameDidChange(_ window: Window) {
        guard window == globalFocus.windowOrNil else { return }
        readBackUpdates &+= 1
        update()
    }

    private var spaceChangeRecheck: Task<(), any Error>? = nil
    /// See ``hideAfterSpaceChange()``
    private var isHiddenForSpaceChange = false

    /// macOS posts the Space change before its animation ends: the refresh session right after it still sees the windows
    /// of the previous Space on screen and drew their border, and the panel followed into the new Space (e.g. the Space
    /// of a native fullscreen window). The border stays hidden during the animation and is checked when it's over
    func hideAfterSpaceChange() {
        isHiddenForSpaceChange = true
        hide()
        spaceChangeRecheck?.cancel()
        spaceChangeRecheck = Task.startUnstructured { @MainActor in
            for delay in [700, 800] { // ms: after the animation, and once more for slow transitions
                try await Task.sleep(for: .milliseconds(delay))
                self.isHiddenForSpaceChange = false // The singleton
                self.update()
            }
        }
    }

    /// See ``isHiddenForMouseDrag``
    func hideForMouseDrag() {
        isHiddenForMouseDrag = true
        hide()
    }

    /// The refresh session after the mouse up event draws the border again
    func showAfterMouseDrag() {
        isHiddenForMouseDrag = false
    }

    func hide() {
        verifiedStacking = nil
        stackingRecheck?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func getOrCreatePanel() -> FocusBorderPanel {
        if let panel { return panel }
        let panel = FocusBorderPanel()
        self.panel = panel
        return panel
    }
}

/// Where the border panel goes in the stacking of the window server
enum FocusBorderPlacement: Equatable {
    /// Right below the focused window: the border shows in the gap around the window, and nothing of MarSpace covers the
    /// window. macOS hides the buttons of a secure dialog (the purchase sheet of App Store, a password or permission
    /// prompt) while a window of another app is over it
    case below
    /// Right above the focused window: the border is over the window where the window reaches beyond the edge of the
    /// monitor (it follows the edge there). Only while nothing covers the window: a dialog or a sheet over it keeps its
    /// buttons, the border goes below
    case above
}

/// A window of the window server next to the focused window
struct StackedWindow: Equatable {
    let number: Int?
    let pid: Int32?
    let layer: Int?
    /// Top left origin
    let bounds: CGRect?

    init(number: Int?, pid: Int32?, layer: Int?, bounds: CGRect? = nil) {
        (self.number, self.pid, self.layer, self.bounds) = (number, pid, layer, bounds)
    }

    fileprivate init(_ info: [String: Any]) {
        self.init(
            number: info[kCGWindowNumber as String] as? Int,
            pid: info[kCGWindowOwnerPID as String] as? Int32,
            layer: info[kCGWindowLayer as String] as? Int,
            bounds: (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) },
        )
    }
}

/// - Parameter windowsAbove: the windows above the focused window, from the window up
func focusBorderPlacement(isBorderOverTheWindow: Bool, windowsAbove: [StackedWindow], windowFrame: CGRect, panel: CGWindowID?) -> FocusBorderPlacement {
    guard isBorderOverTheWindow else { return .below }
    let isCovered = windowsAbove.contains { window in
        window.number != panel.map(Int.init) && window.layer == 0 && window.bounds?.intersects(windowFrame) == true
    }
    return isCovered ? .below : .above
}

/// Where the focused window is in the stacking of the window server. No accessibility calls
private enum WindowStacking: Equatable {
    /// Not on the active macOS Space, e.g. a window of the desktop while a native fullscreen window has its own Space:
    /// AeroSpace may focus one of them, and the panel (it moves to the active Space) drew its border over the fullscreen
    /// window
    case offScreen
    /// - Parameter isPanelInPlace: the panel is right next to the window as `placement` says, no window of another app
    ///   is between them (an app may keep its own helper window right next to its window)
    case onScreen(FocusBorderPlacement, isPanelInPlace: Bool)
    /// The query failed
    case unknown
}

private func windowStacking(
    of nativeWindowId: UInt32,
    pid: pid_t,
    panel: CGWindowID?,
    windowFrame: CGRect,
    isBorderOverTheWindow: Bool,
) -> WindowStacking {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .optionIncludingWindow], CGWindowID(nativeWindowId))
        as? [[String: Any]] ?? []
    guard let own = infos.last else { return .unknown }
    // Front to back: the windows in front of the window, then the window itself. A window of another Space isn't listed
    guard (own[kCGWindowNumber as String] as? Int) == Int(nativeWindowId) else { return .offScreen }
    let windowsAbove = infos.dropLast().reversed().map(StackedWindow.init) // From the window up
    let placement = focusBorderPlacement(isBorderOverTheWindow: isBorderOverTheWindow, windowsAbove: windowsAbove, windowFrame: windowFrame, panel: panel)
    let windowsNext = switch placement {
        case .above: windowsAbove
        case .below: (CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], CGWindowID(nativeWindowId)) as? [[String: Any]] ?? [])
        .map(StackedWindow.init)
    }
    return .onScreen(placement, isPanelInPlace: isPanelRightNext(to: windowsNext, pid: pid, panel: panel))
}

/// - Parameter windows: the windows next to the window on the side of the panel, nearest first
/// - Returns: the panel is the nearest of them, apart from the window's own app (an app may keep a helper window right
///   next to its window). Only the normal layer counts (not the desktop, the menu bar or the Dock)
func isPanelRightNext(to windows: [StackedWindow], pid: pid_t, panel: CGWindowID?) -> Bool {
    guard let panel else { return false }
    for window in windows where window.layer == 0 {
        if window.number == Int(panel) { return true }
        if window.pid != pid { return false }
    }
    return false
}

/// Frame of the border panel in Cocoa coordinates (the origin is at the bottom left corner of the main monitor).
/// `windowRect` is in AeroSpace coordinates (the origin is at the top left corner of the main monitor)
func focusBorderPanelFrame(windowRect: Rect, borderWidth: Int, mainMonitorHeight: CGFloat) -> CGRect {
    let width = CGFloat(borderWidth)
    return CGRect(
        x: windowRect.topLeftX,
        y: mainMonitorHeight - windowRect.topLeftY - windowRect.height,
        width: windowRect.width,
        height: windowRect.height,
    ).insetBy(dx: -width, dy: -width)
}

/// The rect that the border surrounds. A window that refuses to shrink to its tile can reach beyond the monitor (it's
/// placed at the tile, App Store is at least 1000 wide): on that side the border follows the monitor edge, otherwise it's
/// off screen
func focusBorderWindowRect(_ window: Rect, monitor: Rect?, borderWidth: Int) -> Rect {
    guard let monitor else { return window }
    let width = CGFloat(borderWidth)
    let minX = window.minX < monitor.minX ? monitor.minX + width : window.minX
    let maxX = window.maxX > monitor.maxX ? monitor.maxX - width : window.maxX
    let minY = window.minY < monitor.minY ? monitor.minY + width : window.minY
    let maxY = window.maxY > monitor.maxY ? monitor.maxY - width : window.maxY
    return Rect(topLeftX: minX, topLeftY: minY, width: maxX - minX, height: maxY - minY)
}

extension MacWindow {
    /// The frame of the window that the focus border surrounds, or nil if the border must be hidden
    @MainActor
    fileprivate var focusBorderRect: Rect? {
        guard nodeWorkspace?.isVisible == true else { return nil }
        return switch windowParentCases {
            // Not the tile: the window can be bigger than its tile
            case .tilingContainer: observedFrame ?? lastAppliedLayoutPhysicalRect
            case .floatingWindowsContainer: observedFrame
            case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer,
                 .macosPopupWindowsContainer, nil: nil
        }
    }
}

private final class FocusBorderPanel: NSPanel {
    private let gradientLayer = CAGradientLayer()
    private let strokeMask = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        // Belong to a single Space at a time (otherwise it flashes on other Spaces, e.g. native fullscreen Spaces),
        // move to the active Space when ordered in, don't participate in cmd-` window cycling
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        contentView = view
        strokeMask.fillColor = nil
        strokeMask.strokeColor = CGColor(gray: 0, alpha: 1)
        gradientLayer.mask = strokeMask
        view.layer?.addSublayer(gradientLayer)
    }

    func draw(size: CGSize, _ border: FocusBorder) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = CGRect(origin: .zero, size: size)
        let lineWidth = CGFloat(border.width)
        let strokeRect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = min(CGFloat(border.radius) + lineWidth / 2, strokeRect.width / 2, strokeRect.height / 2)
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        gradientLayer.frame = bounds
        gradientLayer.contentsScale = scale
        strokeMask.frame = bounds
        strokeMask.contentsScale = scale
        strokeMask.lineWidth = lineWidth
        strokeMask.path = unsafe CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        switch border.color {
            case .solid(let color):
                gradientLayer.colors = [color.argbCgColor, color.argbCgColor]
            case .gradient(let start, let end, let fromTopLeft):
                gradientLayer.colors = [start.argbCgColor, end.argbCgColor]
                // Layer coordinates: the origin is at the bottom left corner
                gradientLayer.startPoint = fromTopLeft ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 1)
                gradientLayer.endPoint = fromTopLeft ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 0)
        }
    }
}
