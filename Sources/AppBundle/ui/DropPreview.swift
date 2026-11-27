import AppKit
import Common

/// Shows where a window that is dragged with the mouse goes (see ``WindowDrag``): the space that it gets, in the colors of
/// the focus border (Settings › Appearance, also while the border is off). A swap outlines the places of both windows,
/// dashed and with ⇄. A change of the layout fills the space that the window gets. The panels are right below the dragged
/// window, over the other windows
@MainActor
final class DropPreview {
    static let shared = DropPreview()

    private var panels: [DropPreviewPanel] = []

    private init() {}

    /// The panels on the screen: right below the dragged window, they don't count where the focus border checks that its
    /// panel is right next to the focused window
    var shownPanelNumbers: Set<Int> { Set(panels.lazy.filter(\.isVisible).map(\.windowNumber)) }

    /// - Parameter rects: top left origin
    func show(_ rects: [Rect], isSwap: Bool, below window: Window) {
        if isUnitTest { return }
        guard !rects.isEmpty,
              let window = window as? MacWindow,
              let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId)
        else { return hide() }
        while panels.count < rects.count { panels.append(DropPreviewPanel()) }
        let mainMonitorHeight = mainMonitorInfo.height
        for (panel, rect) in zip(panels, rects) {
            let frame = CGRect(x: rect.topLeftX, y: mainMonitorHeight - rect.maxY, width: rect.width, height: rect.height)
            panel.draw(size: frame.size, isSwap: isSwap, config.focusBorder)
            panel.setFrame(frame, display: true)
            panel.order(.below, relativeTo: Int(nativeWindowId))
        }
        for panel in panels.dropFirst(rects.count) where panel.isVisible { panel.orderOut(nil) }
    }

    func hide() {
        for panel in panels where panel.isVisible { panel.orderOut(nil) }
    }
}

private final class DropPreviewPanel: NSPanel {
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let outline = CAGradientLayer()
    private let outlineMask = CAShapeLayer()
    private let badge = CALayer()
    private let symbol = CALayer()

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
        // Like the focus border: on a single Space at a time, not in cmd-` window cycling
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        contentView = view
        fillMask.fillColor = CGColor(gray: 0, alpha: 1)
        fill.mask = fillMask
        outlineMask.fillColor = nil
        outlineMask.strokeColor = CGColor(gray: 0, alpha: 1)
        outline.mask = outlineMask
        badge.backgroundColor = CGColor(gray: 0, alpha: 0.5)
        symbol.contentsGravity = .resizeAspect
        badge.addSublayer(symbol)
        for layer in [fill, outline, badge] { view.layer?.addSublayer(layer) }
    }

    func draw(size: CGSize, isSwap: Bool, _ border: FocusBorder) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = CGRect(origin: .zero, size: size)
        let lineWidth = CGFloat(max(border.width, 3))
        let outlineRect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = max(0, min(CGFloat(border.radius), outlineRect.width / 2, outlineRect.height / 2))
        let path = CGMutablePath()
        path.addRoundedRect(in: outlineRect, cornerWidth: radius, cornerHeight: radius)
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [fill, fillMask, outline, outlineMask, badge, symbol] { layer.contentsScale = scale }
        for layer in [fill, fillMask, outline, outlineMask] { layer.frame = bounds }
        fillMask.path = path
        outlineMask.path = path
        outlineMask.lineWidth = lineWidth
        outlineMask.lineDashPattern = isSwap ? [NSNumber(value: Double(lineWidth * 4)), NSNumber(value: Double(lineWidth * 2))] : nil
        fill.opacity = isSwap ? 0.12 : 0.3
        border.color.paint(fill)
        border.color.paint(outline)

        badge.isHidden = !isSwap
        if isSwap {
            let diameter = min(56, size.width / 2, size.height / 2)
            badge.frame = CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter, height: diameter)
            badge.cornerRadius = diameter / 2
            symbol.frame = badge.bounds.insetBy(dx: diameter / 4, dy: diameter / 4)
            symbol.contents = swapSymbol
        }
    }
}

/// ⇄, white
@MainActor
private let swapSymbol: NSImage? = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .semibold).applying(.init(paletteColors: [.white])))

extension FocusBorderColor {
    /// The colors of `layer`: in layer coordinates, the origin is at the bottom left corner
    func paint(_ layer: CAGradientLayer) {
        switch self {
            case .solid(let color):
                layer.colors = [color.argbCgColor, color.argbCgColor]
            case .gradient(let start, let end, let fromTopLeft):
                layer.colors = [start.argbCgColor, end.argbCgColor]
                layer.startPoint = fromTopLeft ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 1)
                layer.endPoint = fromTopLeft ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 0)
        }
    }
}
