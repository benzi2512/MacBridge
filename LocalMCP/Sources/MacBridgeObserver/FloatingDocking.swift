import AppKit
import SwiftUI

enum FloatingDockEdge: String, Codable, CaseIterable, Sendable {
    case right, bottom
    var label: String { rawValue.capitalized }
}

enum FloatingRailDirection: CGFloat, Equatable, Sendable {
    case reverse = -1
    case forward = 1
    var sign: CGFloat { rawValue }
}

struct FloatingDockPlacement: Equatable, Sendable {
    let frame: CGRect
    let logo: CGPoint
    let direction: FloatingRailDirection
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
    static func anchor(at point: CGPoint, visibleFrame: CGRect,
                       previousEdge: FloatingDockEdge) -> FloatingDockAnchor {
        guard point.x.isFinite, point.y.isFinite, visibleFrame.width > 0,
              visibleFrame.height > 0 else { return .init(edge: previousEdge, position: 0.5) }
        // Dragging moves along the selected edge only. In particular, the
        // bottom-right corner is a valid end position for the vertical rail;
        // it must not unexpectedly rotate the widget onto the bottom edge.
        let edge = previousEdge
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
        case .idle:
            requested = CGSize(width: max(MBMetrics.edgeIdleHeight, MBMetrics.edgeTargetSize),
                               height: max(MBMetrics.edgeIdleWidth, MBMetrics.edgeTargetSize))
        case .rail:
            requested = CGSize(width: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack,
                               height: MBMetrics.edgeRailWidth + MBMetrics.edgeMotionHorizontalSlack)
        default:
            requested = CGSize(width: max(MBMetrics.edgeRailHeight,
                                          card.width + MBMetrics.panelShadowMargin * 2),
                               height: card.height + MBMetrics.panelGap + MBMetrics.edgeRailWidth
                                   + MBMetrics.panelShadowMargin)
        }
        return CGSize(width: min(requested.width, max(1, visibleFrame.width - 16)),
                      height: min(requested.height, max(1, visibleFrame.height - 16)))
    }

    static func frame(visibleFrame: CGRect, layer: FloatingLayer, anchor: FloatingDockAnchor,
                      taskCount: Int = 3) -> CGRect {
        placement(visibleFrame: visibleFrame, layer: layer, anchor: anchor,
                  taskCount: taskCount).frame
    }

    static func placement(visibleFrame: CGRect, layer: FloatingLayer, anchor: FloatingDockAnchor,
                          taskCount: Int = 3) -> FloatingDockPlacement {
        let anchor = anchor.sanitized
        if anchor.edge == .right {
            let frame = EdgeLayout.frame(visibleFrame: visibleFrame, layer: layer,
                                         normalizedFromTop: CGFloat(anchor.position), taskCount: taskCount)
            let logo = CGPoint(x: frame.width - EdgeLayout.logoInset,
                y: EdgeLayout.rightLogoY(frame: frame, visibleFrame: visibleFrame,
                                         normalizedFromTop: CGFloat(anchor.position)))
            let direction: FloatingRailDirection = logo.y <= frame.height / 2 ? .forward : .reverse
            return FloatingDockPlacement(frame: frame, logo: logo, direction: direction)
        }
        let size = size(for: layer, visibleFrame: visibleFrame, taskCount: taskCount, edge: .bottom)
        let targetInset = min(visibleFrame.width / 2,
                              EdgeLayout.outerInset + MBMetrics.edgeTargetSize / 2)
        let usable = max(0, visibleFrame.width - targetInset * 2)
        let desiredLogoX = visibleFrame.minX + targetInset + usable * anchor.position
        let preferredLogoX = anchor.position <= 0.5
            ? MBMetrics.edgeTargetSize / 2
            : size.width - MBMetrics.edgeTargetSize / 2
        let inset = min(EdgeLayout.outerInset, max(0, (visibleFrame.width - size.width) / 2))
        let minimumX = visibleFrame.minX + inset
        let maximumX = visibleFrame.maxX - size.width - inset
        let x = min(maximumX, max(minimumX, desiredLogoX - preferredLogoX))
        let frame = CGRect(x: x, y: visibleFrame.minY, width: size.width, height: size.height)
        let logoX = min(size.width - MBMetrics.edgeTargetSize / 2,
                        max(MBMetrics.edgeTargetSize / 2, desiredLogoX - frame.minX))
        let logo = CGPoint(x: logoX, y: size.height - EdgeLayout.logoInset)
        let direction: FloatingRailDirection = logoX <= size.width / 2 ? .forward : .reverse
        return FloatingDockPlacement(frame: frame, logo: logo, direction: direction)
    }

    static func actionCenter(index: Int, logo: CGPoint, edge: FloatingDockEdge,
                             direction: FloatingRailDirection = .forward) -> CGPoint {
        let distance = direction.sign * CGFloat(index + 1)
            * (MBMetrics.edgeTargetSize + MBMetrics.edgeRailSpacing)
        return edge == .right ? CGPoint(x: logo.x, y: logo.y + distance)
            : CGPoint(x: logo.x + distance, y: logo.y)
    }

    static func railActionPosition(index: Int, edge: FloatingDockEdge,
                                   direction: FloatingRailDirection) -> CGPoint {
        let alongLength = MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack
        let along = alongLength / 2 + direction.sign
            * (CGFloat(index + 1) * (MBMetrics.edgeTargetSize + MBMetrics.edgeRailSpacing)
               - EdgeLayout.railLogoOffset)
        return edge == .right
            ? CGPoint(x: MBMetrics.edgeTargetSize / 2, y: along)
            : CGPoint(x: along, y: MBMetrics.edgeTargetSize / 2)
    }

}

/// A floating nonactivating panel must perform the first click, not consume it
/// just to focus the hosting view. This does not activate any other application.
final class FloatingFirstClickHostingView<Content: View>: NSHostingView<Content> {
    /// SwiftUI can temporarily report no hit while its visual content shape is
    /// morphing. Fall back only for the controller's explicit interactive path
    /// so a visible button never clicks through to the app behind the panel.
    var acceptsInteractivePoint: ((CGPoint) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        // AppKit supplies `point` in the receiver's superview coordinates.
        // Convert it exactly once before comparing it with the controller's
        // canvas path. Otherwise a non-zero frame origin shifts the hot region
        // and the click can fall through to the app underneath.
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(localPoint), acceptsInteractivePoint?(localPoint) == true else { return nil }
        return self
    }
}

/// Transpose only the surface silhouette. Text, badge and action icons remain
/// upright when the rail moves from the right edge to the bottom.
struct DockedOrganicEdgeShape: Shape {
    let edge: FloatingDockEdge
    var expansion: CGFloat
    var direction: FloatingRailDirection = .forward
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }
    func path(in rect: CGRect) -> Path {
        if edge == .right {
            return AnchoredOrganicEdgeShape(expansion: expansion, direction: direction,
                                            endCapShoulder: MBMetrics.verticalEndCapShoulder).path(in: rect)
        }
        return AnchoredOrganicEdgeShape(expansion: expansion, direction: direction,
                                        endCapShoulder: MBMetrics.horizontalEndCapShoulder)
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
    let direction: FloatingRailDirection
    let controller: FloatingTabController
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> LogoView { LogoView() }
    func updateNSView(_ view: LogoView, context: Context) {
        view.controller = controller
        let identity = "\(summary.runningBadgeText)|\(summary.runningBadgeHelp)|\(showCount)|\(edge)|\(direction)|\(colorScheme)"
        guard view.renderedIdentity != identity else { return }
        view.renderedIdentity = identity
        view.host.rootView = AnyView(
            CompactBrandBadge(summary: summary, showCount: showCount, horizontal: edge == .bottom)
                .offset(x: edge == .right
                            ? EdgeLayout.logoInset - EdgeLayout.brandVisualInset
                            : direction.sign * EdgeLayout.horizontalBrandVisualAlongOffset,
                        y: edge == .bottom
                            ? EdgeLayout.logoInset - EdgeLayout.brandVisualInset
                            : direction.sign * EdgeLayout.brandVisualAlongOffset)
                .environment(\.colorScheme, colorScheme)
        )
        view.setAccessibilityLabel("Open MacBridge Dashboard")
        view.setAccessibilityHelp("Click to open. Drag along the current screen edge; choose another edge in Settings. \(summary.runningBadgeHelp)")
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
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(localPoint) ? self : nil
        }
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
