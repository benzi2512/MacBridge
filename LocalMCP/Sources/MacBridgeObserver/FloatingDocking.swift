import AppKit
import SwiftUI

enum FloatingDockEdge: String, Codable, CaseIterable, Sendable {
    case right, bottom
    var label: String { rawValue.capitalized }
}

struct FloatingDockAnchor: Codable, Equatable, Sendable {
    var edge: FloatingDockEdge
    var position: Double

    init(edge: FloatingDockEdge, position: Double) {
        self.edge = edge
        self.position = position.isFinite ? min(1, max(0, position)) : 0.5
    }

    var sanitized: Self { Self(edge: edge, position: position) }
}

/// A click never becomes a drag because the window itself moved. All points
/// come from this control's own AppKit events in screen coordinates.
struct FloatingLogoDrag: Equatable {
    static let threshold: CGFloat = 6
    let start: CGPoint
    private(set) var isDragging = false

    mutating func move(to point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        if hypot(point.x - start.x, point.y - start.y) >= Self.threshold { isDragging = true }
        return isDragging
    }
}

enum FloatingDockLayout {
    static let edgeHysteresis: CGFloat = 20

    static func anchor(at point: CGPoint, visibleFrame: CGRect,
                       previousEdge: FloatingDockEdge) -> FloatingDockAnchor {
        guard point.x.isFinite, point.y.isFinite, visibleFrame.width > 0,
              visibleFrame.height > 0 else { return .init(edge: previousEdge, position: 0.5) }
        let right = abs(visibleFrame.maxX - point.x)
        let bottom = abs(point.y - visibleFrame.minY)
        let edge: FloatingDockEdge
        switch previousEdge {
        case .right: edge = bottom + edgeHysteresis < right ? .bottom : .right
        case .bottom: edge = right + edgeHysteresis < bottom ? .right : .bottom
        }
        let position = edge == .bottom ? (point.x - visibleFrame.minX) / visibleFrame.width
            : (visibleFrame.maxY - point.y) / visibleFrame.height
        return .init(edge: edge, position: Double(position))
    }

    static func size(for layer: FloatingLayer, visibleFrame: CGRect,
                     taskCount: Int = 3, edge: FloatingDockEdge) -> CGSize {
        if edge == .right { return EdgeLayout.size(for: layer, visibleFrame: visibleFrame, taskCount: taskCount) }
        let card = EdgeLayout.panelSize(for: layer, taskCount: taskCount)
        let requested: CGSize
        switch layer {
        case .idle: requested = CGSize(width: MBMetrics.edgeIdleHeight, height: MBMetrics.edgeIdleWidth)
        case .rail:
            requested = CGSize(width: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack,
                               height: MBMetrics.edgeRailWidth + MBMetrics.edgeMotionHorizontalSlack)
        default:
            requested = CGSize(width: max(MBMetrics.edgeRailHeight, card.width),
                               height: card.height + MBMetrics.panelGap + MBMetrics.edgeRailWidth)
        }
        return CGSize(width: min(requested.width, max(1, visibleFrame.width - 16)),
                      height: min(requested.height, max(1, visibleFrame.height - 16)))
    }

    static func frame(visibleFrame: CGRect, layer: FloatingLayer, anchor: FloatingDockAnchor,
                      taskCount: Int = 3) -> CGRect {
        let anchor = anchor.sanitized
        if anchor.edge == .right {
            return EdgeLayout.frame(visibleFrame: visibleFrame, layer: layer,
                                    normalizedFromTop: CGFloat(anchor.position), taskCount: taskCount)
        }
        let size = size(for: layer, visibleFrame: visibleFrame, taskCount: taskCount, edge: .bottom)
        // Reserve horizontal room for the widest card, keeping the logo fixed
        // when the rail/card opens. Bottom follows visibleFrame, above the Dock.
        let maximumWidth = self.size(for: .taskDetail("anchor"), visibleFrame: visibleFrame, edge: .bottom).width
        let railCenter = min(visibleFrame.maxX - maximumWidth / 2 - EdgeLayout.outerInset,
                             max(visibleFrame.minX + maximumWidth / 2 + EdgeLayout.outerInset,
                                 visibleFrame.minX + visibleFrame.width * anchor.position + EdgeLayout.railLogoOffset))
        let center = railCenter - (layer == .idle ? EdgeLayout.railLogoOffset : 0)
        let inset = min(EdgeLayout.outerInset, max(0, (visibleFrame.width - size.width) / 2))
        let x = min(visibleFrame.maxX - size.width - inset, max(visibleFrame.minX + inset, center - size.width / 2))
        return CGRect(x: x, y: visibleFrame.minY, width: size.width, height: size.height)
    }

    static func logo(in size: CGSize, layer: FloatingLayer, edge: FloatingDockEdge) -> CGPoint {
        let offset = layer == .idle ? 0 : EdgeLayout.railLogoOffset
        return edge == .right
            ? CGPoint(x: size.width - EdgeLayout.logoInset, y: size.height / 2 - offset)
            : CGPoint(x: size.width / 2 - offset, y: size.height - EdgeLayout.logoInset)
    }

    static func actionCenter(index: Int, logo: CGPoint, edge: FloatingDockEdge) -> CGPoint {
        let distance = CGFloat(index + 1) * (MBMetrics.edgeTargetSize + MBMetrics.edgeRailSpacing)
        return edge == .right ? CGPoint(x: logo.x, y: logo.y + distance)
            : CGPoint(x: logo.x + distance, y: logo.y)
    }

    // Align the first (logo) slot with the separately hosted drag control.
    // A one-point mismatch would overlap the logo and Refresh click targets.
    static var railContentOffset: CGFloat {
        2 * (MBMetrics.edgeTargetSize + MBMetrics.edgeRailSpacing) - EdgeLayout.railLogoOffset
    }
}

/// A floating nonactivating panel must perform the first click, not consume it
/// just to focus the hosting view. This does not activate any other application.
final class FloatingFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Transpose only the surface silhouette. Text, badge and action icons remain
/// upright when the rail moves from the right edge to the bottom.
struct DockedOrganicEdgeShape: Shape {
    let edge: FloatingDockEdge
    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }
    func path(in rect: CGRect) -> Path {
        if edge == .right { return AnchoredOrganicEdgeShape(expansion: expansion).path(in: rect) }
        return AnchoredOrganicEdgeShape(expansion: expansion)
            .path(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
            .applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: rect.minX, ty: rect.minY))
    }
}

/// Local mouse events only: no global event tap, polling, Accessibility grant
/// or input-monitoring permission. Preference persistence happens on drop.
struct FloatingLogoControl: NSViewRepresentable {
    let summary: CompactSummary
    let showCount: Bool
    let edge: FloatingDockEdge
    let controller: FloatingTabController
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> LogoView { LogoView() }
    func updateNSView(_ view: LogoView, context: Context) {
        view.controller = controller
        let identity = "\(summary.runningBadgeText)|\(summary.runningBadgeHelp)|\(showCount)|\(edge)|\(colorScheme)"
        guard view.renderedIdentity != identity else { return }
        view.renderedIdentity = identity
        view.host.rootView = AnyView(CompactBrandBadge(summary: summary, showCount: showCount, horizontal: edge == .bottom)
            .environment(\.colorScheme, colorScheme))
        view.setAccessibilityLabel("Open MacBridge Dashboard")
        view.setAccessibilityHelp("Click to open. Drag the logo along the right or bottom edge. \(summary.runningBadgeHelp)")
        view.setAccessibilityValue(summary.runningBadgeHelp)
        view.setAccessibilityIdentifier("floating-running-count")
    }

    final class LogoView: NSView {
        weak var controller: FloatingTabController?
        var renderedIdentity: String?
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        override init(frame: NSRect) {
            super.init(frame: frame)
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { controller?.logoPressBegan(at: NSEvent.mouseLocation) }
        override func mouseDragged(with event: NSEvent) { controller?.logoDragged(to: NSEvent.mouseLocation) }
        override func mouseUp(with event: NSEvent) { controller?.logoPressEnded(at: NSEvent.mouseLocation) }
        override func accessibilityPerformPress() -> Bool { controller?.openDashboard(); return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { controller?.cancelLogoDrag() }
            else if event.keyCode == 36 || event.keyCode == 49 { controller?.openDashboard() }
            else { super.keyDown(with: event) }
        }
    }
}
