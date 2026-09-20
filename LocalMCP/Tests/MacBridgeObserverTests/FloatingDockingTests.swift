import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MacBridgeObserver

/// Pure geometry/local controller tests; no pointer injection, live owner,
/// production preferences, commands, file transactions or new OS permission.
final class FloatingDockingTests: XCTestCase {
    func testOutsideClickDismissalFlipsScreenCoordinatesAndKeepsInteractiveClicksOpen() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 400)
        let acceptsTopLeftTarget: (CGPoint) -> Bool = {
            CGRect(x: 0, y: 0, width: 44, height: 44).contains($0)
        }

        XCTAssertFalse(FloatingTabController.shouldDismissForOutsideClick(
            at: CGPoint(x: 122, y: 578), panelFrame: frame,
            acceptsInteractivePoint: acceptsTopLeftTarget),
            "A click on the visible control must stay inside the MacBridge widget")
        XCTAssertTrue(FloatingTabController.shouldDismissForOutsideClick(
            at: CGPoint(x: 122, y: 222), panelFrame: frame,
            acceptsInteractivePoint: acceptsTopLeftTarget),
            "Transparent canvas inside the NSWindow is still outside the painted widget")
        XCTAssertTrue(FloatingTabController.shouldDismissForOutsideClick(
            at: CGPoint(x: 80, y: 578), panelFrame: frame,
            acceptsInteractivePoint: acceptsTopLeftTarget),
            "A click outside the panel frame must dismiss the open widget")
    }

    @MainActor
    func testLocalOutsideClickUsesTheEventsCapturedLocation() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 120, y: 240, width: 300, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let localPoint = CGPoint(x: 33, y: 47)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: localPoint, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))

        XCTAssertEqual(FloatingTabController.screenPoint(forLocalMouseEvent: event),
                       window.convertPoint(toScreen: localPoint))
    }

    func testClickToleranceAndDragLatch() {
        var drag = FloatingLogoDrag(start: CGPoint(x: 100, y: 200))
        XCTAssertFalse(drag.move(to: CGPoint(x: 103, y: 202)))
        XCTAssertTrue(drag.move(to: CGPoint(x: 106, y: 200)))
        XCTAssertTrue(drag.move(to: CGPoint(x: 100, y: 200)), "Returning to start must not turn a drag back into a click")
        XCTAssertFalse(drag.move(to: CGPoint(x: CGFloat.nan, y: 200)))
        XCTAssertTrue(drag.isDragging)
    }

    func testDragStaysOnTheSelectedEdgeIncludingCorners() {
        let screen = CGRect(x: -1920, y: 50, width: 1920, height: 1030)
        for point in [CGPoint(x: -3, y: 600), CGPoint(x: -960, y: 53),
                      CGPoint(x: -30, y: 80), CGPoint(x: screen.maxX, y: screen.minY)] {
            for previous in FloatingDockEdge.allCases {
                XCTAssertEqual(FloatingDockLayout.anchor(at: point, visibleFrame: screen,
                                                         previousEdge: previous).edge, previous)
            }
        }
        XCTAssertEqual(FloatingDockLayout.anchor(at: CGPoint(x: screen.maxX, y: screen.minY),
            visibleFrame: screen, previousEdge: .right), .init(edge: .right, position: 1))
    }

    func testNormalizedCoordinatesUseEachDisplaysOrigin() {
        let screen = CGRect(x: -1500, y: 1000, width: 1500, height: 900)
        let bottom = FloatingDockLayout.anchor(at: CGPoint(x: -1125, y: 1002), visibleFrame: screen, previousEdge: .bottom)
        XCTAssertEqual(bottom.edge, .bottom)
        XCTAssertEqual(bottom.position, 0.25, accuracy: 0.00001)
        let right = FloatingDockLayout.anchor(at: CGPoint(x: -2, y: 1450), visibleFrame: screen, previousEdge: .right)
        XCTAssertEqual(right.edge, .right)
        XCTAssertEqual(right.position, 0.5, accuracy: 0.00001)
    }

    func testAllDockFramesStayOnscreenAndLogoDoesNotJumpAcrossLayers() {
        let layers: [FloatingLayer] = [.idle, .rail, .recentTasks, .settings, .taskDetail("fixture")]
        for screen in [CGRect(x: 0, y: 40, width: 1512, height: 920),
                       CGRect(x: -1920, y: -800, width: 1920, height: 1080),
                       CGRect(x: 1512, y: 200, width: 800, height: 600)] {
            for edge in FloatingDockEdge.allCases {
                for index in 0...100 {
                    let anchor = FloatingDockAnchor(edge: edge, position: Double(index) / 100)
                    var firstLogo: CGPoint?
                    for layer in layers {
                        let placement = FloatingDockLayout.placement(visibleFrame: screen, layer: layer,
                                                                    anchor: anchor, taskCount: 64)
                        let frame = placement.frame
                        XCTAssertTrue(EdgeLayout.isContained(frame, in: screen), "\(edge) \(layer) \(frame)")
                        let logo = CGPoint(x: frame.minX + placement.logo.x,
                                           y: frame.maxY - placement.logo.y)
                        if let firstLogo {
                            XCTAssertEqual(logo.x, firstLogo.x, accuracy: 0.001)
                            XCTAssertEqual(logo.y, firstLogo.y, accuracy: 0.001)
                        } else { firstLogo = logo }
                        if edge == .bottom { XCTAssertEqual(frame.minY, screen.minY, accuracy: 0.001) }
                    }
                }
            }
        }
    }

    func testRightEdgeEndpointsKeepTheCompleteLogoTargetInsideTheVerticalSafeArea() {
        let screen = CGRect(x: 0, y: 40, width: 1512, height: 920)
        for position in [0.0, 1.0] {
            for layer: FloatingLayer in [.idle, .rail, .recentTasks, .settings, .taskDetail("fixture")] {
                let placement = FloatingDockLayout.placement(visibleFrame: screen, layer: layer,
                    anchor: .init(edge: .right, position: position), taskCount: 64)
                let screenLogoY = placement.frame.maxY - placement.logo.y
                let target = CGRect(x: 0,
                    y: screenLogoY - MBMetrics.edgeTargetSize / 2,
                    width: MBMetrics.edgeTargetSize,
                    height: MBMetrics.edgeTargetSize)
                XCTAssertGreaterThanOrEqual(target.minY, screen.minY + EdgeLayout.outerInset - 0.001)
                XCTAssertLessThanOrEqual(target.maxY, screen.maxY - EdgeLayout.outerInset + 0.001)
            }
        }
    }

    func testIdleOrganicOutlineFitsItsBackingWindowAtEveryEndpoint() {
        let screen = CGRect(x: 0, y: 40, width: 1512, height: 920)
        for edge in FloatingDockEdge.allCases {
            for position in [0.0, 1.0] {
                let placement = FloatingDockLayout.placement(visibleFrame: screen, layer: .idle,
                    anchor: .init(edge: edge, position: position), taskCount: 0)
                let canvas = CGRect(origin: .zero, size: placement.frame.size)
                let handleSize = edge == .right
                    ? CGSize(width: MBMetrics.edgeTargetSize,
                             height: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack)
                    : CGSize(width: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack,
                             height: MBMetrics.edgeTargetSize)
                let center = edge == .right
                    ? CGPoint(x: canvas.maxX - MBMetrics.edgeTargetSize / 2,
                              y: placement.logo.y + placement.direction.sign * EdgeLayout.railLogoOffset)
                    : CGPoint(x: placement.logo.x + placement.direction.sign * EdgeLayout.railLogoOffset,
                              y: canvas.maxY - MBMetrics.edgeTargetSize / 2)
                let handleFrame = CGRect(x: center.x - handleSize.width / 2,
                                         y: center.y - handleSize.height / 2,
                                         width: handleSize.width, height: handleSize.height)
                let bounds = DockedOrganicEdgeShape(edge: edge, expansion: 0,
                    direction: placement.direction)
                    .path(in: CGRect(origin: .zero, size: handleSize))
                    .applying(CGAffineTransform(translationX: handleFrame.minX, y: handleFrame.minY))
                    .boundingRect
                XCTAssertGreaterThanOrEqual(bounds.minX, canvas.minX - 0.001,
                    "\(edge) \(position) clipped the leading idle shoulder: \(bounds) in \(canvas)")
                XCTAssertGreaterThanOrEqual(bounds.minY, canvas.minY - 0.001,
                    "\(edge) \(position) clipped the top idle shoulder: \(bounds) in \(canvas)")
                XCTAssertLessThanOrEqual(bounds.maxX, canvas.maxX + 0.001,
                    "\(edge) \(position) clipped the trailing idle shoulder: \(bounds) in \(canvas)")
                XCTAssertLessThanOrEqual(bounds.maxY, canvas.maxY + 0.001,
                    "\(edge) \(position) clipped the bottom idle shoulder: \(bounds) in \(canvas)")
            }
        }
    }

    func testSettledRailKeepsEveryActionGlyphOnGlassInBothDirections() {
        let canvas = CGRect(x: 0, y: 0,
            width: MBMetrics.edgeTargetSize,
            height: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack)
        for direction in [FloatingRailDirection.forward, .reverse] {
            let glass = DockedOrganicEdgeShape(edge: .right, expansion: 1, direction: direction)
                .path(in: canvas)
            for index in 0..<4 {
                let center = FloatingDockLayout.railActionPosition(index: index, edge: .right,
                                                                   direction: direction)
                for dx: CGFloat in [-8, 0, 8] {
                    for dy: CGFloat in [-8, 0, 8] {
                        XCTAssertTrue(glass.contains(CGPoint(x: center.x + dx, y: center.y + dy)),
                                      "\(direction) action \(index) escaped the painted glass")
                    }
                }
            }
        }
    }

    func testPanelCanvasIncludesARealShadowGutter() {
        let screen = CGRect(x: 0, y: 40, width: 1512, height: 920)
        let panel = EdgeLayout.panelSize(for: .recentTasks, taskCount: 6)
        let canvas = FloatingDockLayout.size(for: .recentTasks, visibleFrame: screen,
                                             taskCount: 6, edge: .right)
        XCTAssertEqual(canvas.width - MBMetrics.edgeRailWidth - panel.width,
                       MBMetrics.panelShadowMargin, accuracy: 0.001)
        XCTAssertEqual(canvas.height - panel.height,
                       MBMetrics.panelShadowMargin * 2, accuracy: 0.001)
    }

    func testBottomIdleAndRailAreNarrowAndTaskViewportIsBounded() {
        let screen = CGRect(x: 0, y: 40, width: 1512, height: 920)
        let idle = FloatingDockLayout.size(for: .idle, visibleFrame: screen, edge: .bottom)
        XCTAssertEqual(idle, CGSize(width: 58, height: 44))
        let rail = FloatingDockLayout.size(for: .rail, visibleFrame: screen, edge: .bottom)
        XCTAssertEqual(rail, CGSize(width: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack,
                                    height: 44))
        XCTAssertEqual(MBMetrics.edgeIdleWidth, 30, "The painted idle material did not grow")
        XCTAssertEqual(MBMetrics.edgeRailWidth, 36, "The painted rail did not grow")
        XCTAssertEqual(FloatingDockLayout.size(for: .recentTasks, visibleFrame: screen, taskCount: 6, edge: .bottom),
                       FloatingDockLayout.size(for: .recentTasks, visibleFrame: screen, taskCount: 64, edge: .bottom))
    }

    func testBottomHitRegionHasUprightCardAndNoInvisibleLargeHotZone() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 920)
        let placement = FloatingDockLayout.placement(visibleFrame: screen, layer: .recentTasks,
            anchor: .init(edge: .bottom, position: 0.5), taskCount: 3)
        let size = placement.frame.size
        let logo = placement.logo
        let region = FloatingHitRegion(logoY: logo.y, expansion: 1,
            panelSize: EdgeLayout.panelSize(for: .recentTasks, taskCount: 3), dockEdge: .bottom,
            logoX: logo.x, direction: placement.direction)
            .path(in: CGRect(origin: .zero, size: size))
        XCTAssertTrue(region.contains(logo))
        XCTAssertTrue(region.contains(CGPoint(x: size.width / 2, y: 70)))
        XCTAssertFalse(region.contains(CGPoint(x: size.width - 1, y: size.height - 1)),
                       "The transparent corner beyond the horizontal rail is not a hot zone")
    }

    func testFullControlTargetsRemainClickableInBothDockOrientations() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 920)
        for edge in FloatingDockEdge.allCases {
            for layer: FloatingLayer in [.rail, .recentTasks, .settings] {
                let placement = FloatingDockLayout.placement(visibleFrame: screen, layer: layer,
                    anchor: .init(edge: edge, position: 0.5), taskCount: 3)
                let size = placement.frame.size
                let canvas = CGRect(origin: .zero, size: size)
                let logo = placement.logo
                for expansion: CGFloat in [0.01, 0.5, 1] {
                    let region = FloatingHitRegion(logoY: logo.y, expansion: expansion,
                        panelSize: EdgeLayout.panelSize(for: layer, taskCount: 3), dockEdge: edge,
                        logoX: logo.x, direction: placement.direction).path(in: canvas)
                    for index in 0..<4 {
                        let center = FloatingDockLayout.actionCenter(index: index, logo: logo, edge: edge,
                                                                     direction: placement.direction)
                        // Test blank space around each symbol, not just its center.
                        for dx: CGFloat in [-21.5, 0, 21.5] {
                            for dy: CGFloat in [-21.5, 0, 21.5] {
                                let point = CGPoint(x: center.x + dx, y: center.y + dy)
                                if canvas.contains(point) {
                                    XCTAssertTrue(region.contains(point), "\(edge) \(layer) \(index) \(point)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testLargerTargetsKeepRailNarrowAndNeverOverlapTheLogoOrAnotherAction() {
        XCTAssertEqual(MBMetrics.edgeTargetSize, 44)
        XCTAssertEqual(MBMetrics.edgeRailWidth, 36)
        for edge in FloatingDockEdge.allCases {
            for direction in [FloatingRailDirection.forward, .reverse] {
                let logo = CGPoint(x: 200, y: 200)
                var previous = CGRect(x: logo.x - 22, y: logo.y - 22, width: 44, height: 44)
                for index in 0..<4 {
                    let center = FloatingDockLayout.actionCenter(index: index, logo: logo, edge: edge,
                                                                 direction: direction)
                    let target = CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
                    let overlap = previous.intersection(target)
                    XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0,
                                  "\(edge): neighboring controls must not compete for one click")
                    previous = target
                }
            }
        }
        XCTAssertEqual(EdgeLayout.railLogoOffset, 2 * MBMetrics.edgeTargetSize)
        XCTAssertEqual(MBMetrics.edgeBrandWidth, 28)
        XCTAssertEqual(MBMetrics.edgeBrandHeight, 34)
    }

    @MainActor
    func testFloatingHostAndLogoAcceptTheFirstClickWithoutFocusingAnotherApp() {
        let host = FloatingFirstClickHostingView(rootView: Text("Fixture"))
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertNil(host.window, "This check must not show or focus a production window")
        let logo = FloatingLogoControl.LogoView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        XCTAssertTrue(logo.acceptsFirstMouse(for: nil))
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 43.5, y: 43.5), CGPoint(x: 22, y: 22)] {
            XCTAssertTrue(logo.hitTest(point) === logo, "The whole logo box must receive clicks and drags")
        }
        XCTAssertNil(logo.hitTest(CGPoint(x: -1, y: 22)))
        XCTAssertNil(logo.hitTest(CGPoint(x: 45, y: 22)))
    }

    @MainActor
    func testPresentedNonactivatingPanelRetainsEveryDeclaredTargetAndRejectsTransparentCanvas() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 220, height: 260),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 260))
        let host = FloatingFirstClickHostingView(rootView: EmptyView())
        host.sizingOptions = []
        host.frame = NSRect(x: 120, y: 20, width: 80, height: 220)
        let declaredTargets = (0..<5).map { index in
            NSRect(x: 24, y: CGFloat(index) * MBMetrics.edgeTargetSize,
                   width: MBMetrics.edgeTargetSize, height: MBMetrics.edgeTargetSize)
        }
        host.acceptsInteractivePoint = { point in declaredTargets.contains { $0.contains(point) } }
        container.addSubview(host)
        panel.contentView = container
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        container.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(panel.isVisible, "The acceptance fixture must be a presented AppKit panel")
        XCTAssertFalse(panel.isKeyWindow, "The floating widget must not take application focus")
        for target in declaredTargets {
            let pointInHost = NSPoint(x: target.midX, y: target.midY)
            let pointInContainer = host.convert(pointInHost, to: container)
            XCTAssertNotNil(host.hitTest(pointInContainer),
                            "Every complete 44-point rail target must stay inside the presented panel")
        }
        let transparentPointInHost = NSPoint(x: 4, y: 4)
        let transparentPointInContainer = host.convert(transparentPointInHost, to: container)
        XCTAssertNil(host.hitTest(transparentPointInContainer),
                     "Transparent backing canvas must not consume a click intended for the app underneath")
    }

    @MainActor
    func testLogoHitTestingConvertsFromSuperviewCoordinatesExactlyOnce() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let logo = FloatingLogoControl.LogoView(frame: NSRect(x: 120, y: 80, width: 44, height: 44))
        container.addSubview(logo)

        XCTAssertTrue(logo.hitTest(NSPoint(x: 142, y: 102)) === logo,
                      "A click at the visual center must reach the logo when its frame origin is non-zero")
        XCTAssertNil(logo.hitTest(NSPoint(x: 60, y: 60)),
                     "A point outside the visual target must not become an invisible hot zone")
    }

    @MainActor
    func testSavedBottomAnchorReloadsAndLegacyRightAnchorSurvives() throws {
        let suite = "MacBridge.Docking.Persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.setNormalizedY(0.31, for: "legacy")
        XCTAssertEqual(preferences.dockAnchor(for: "legacy"), .init(edge: .right, position: 0.31))
        preferences.setDockAnchor(.init(edge: .bottom, position: 0.73), for: "bottom-screen")
        let restored = ObserverPreferences(defaults: defaults)
        XCTAssertEqual(restored.dockAnchor(for: "bottom-screen"), .init(edge: .bottom, position: 0.73))
        XCTAssertEqual(restored.preferredDisplayID, "bottom-screen")
        XCTAssertEqual(restored.dockAnchor(for: "replacement-display"), .init(edge: .bottom, position: 0.73))
        XCTAssertEqual(restored.dockAnchor(for: "legacy"), .init(edge: .right, position: 0.31))
        XCTAssertEqual(restored.normalizedY(for: "legacy"), 0.31, accuracy: 0.00001)
        XCTAssertEqual(restored.glassOpacity, preferences.glassOpacity)
    }

    @MainActor
    func testPreferenceStorageIsBoundedAndRetainsTheCurrentDisplay() throws {
        let suite = "MacBridge.Docking.Bound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        for index in 0..<100 { preferences.setDockAnchor(.init(edge: .bottom, position: 0.5), for: "display-\(index)") }
        preferences.setDockAnchor(.init(edge: .right, position: -2), for: "000-current")
        XCTAssertEqual(preferences.dockAnchors.count, 16)
        XCTAssertEqual(preferences.dockAnchor(for: "000-current"), .init(edge: .right, position: 0))
        XCTAssertEqual(ObserverPreferences(defaults: defaults).dockAnchors.count, 16)
        XCTAssertEqual(FloatingDockAnchor(edge: .bottom, position: .nan).position, 0.5)
    }

    @MainActor
    func testControllerClickOpensOnceButDragOnlySavesOnDrop() throws {
        let suite = "MacBridge.Docking.Controller.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        var opened = 0
        let model = ObserverModel()
        let controller = FloatingTabController(model: model, preferences: preferences, presentsWindow: false,
            openDashboard: { _ in opened += 1 }, openSettings: {})
        defer { controller.stop() }
        let screen = try XCTUnwrap(controller.currentScreen).visibleFrame
        let start = CGPoint(x: screen.maxX - 2, y: screen.midY)
        controller.logoPressBegan(at: start)
        controller.logoPressEnded(at: start)
        controller.logoPressEnded(at: start)
        XCTAssertEqual(opened, 1)
        controller.show(.recentTasks)
        controller.logoPressBegan(at: start)
        let bottom = CGPoint(x: screen.midX, y: screen.minY + 2)
        controller.logoDragged(to: bottom)
        XCTAssertTrue(preferences.dockAnchors.isEmpty, "Mouse moves must not write preferences")
        XCTAssertEqual(controller.dockAnchor.edge, .right)
        XCTAssertEqual(controller.dockAnchor.position, 1, accuracy: 0.01)
        XCTAssertEqual(controller.layer, .idle)
        controller.pointerChanged(true)
        controller.preview(.recentTasks, inside: true)
        XCTAssertEqual(controller.pendingTransitionCount, 0, "Hover must not race a drag")
        controller.logoPressEnded(at: bottom)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(preferences.dockAnchor(for: controller.displayID).edge, .right)
        XCTAssertEqual(preferences.dockAnchor(for: controller.displayID).position, 1, accuracy: 0.01)
        XCTAssertFalse(controller.isDraggingLogo)
        XCTAssertFalse(controller.hasCreatedPanel)
        XCTAssertEqual(model.directory, "")
    }

    @MainActor
    func testEscapeCancelsUnsavedDragAndCannotOpenDashboard() throws {
        let suite = "MacBridge.Docking.Cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        var opened = 0
        let controller = FloatingTabController(model: ObserverModel(), preferences: preferences, presentsWindow: false,
            openDashboard: { _ in opened += 1 }, openSettings: {})
        let screen = try XCTUnwrap(controller.currentScreen).visibleFrame
        let start = CGPoint(x: screen.maxX - 1, y: screen.midY)
        let end = CGPoint(x: screen.midX, y: screen.minY + 1)
        controller.logoPressBegan(at: start)
        controller.logoDragged(to: end)
        controller.closeDeepest()
        controller.logoPressEnded(at: end)
        XCTAssertTrue(preferences.dockAnchors.isEmpty)
        XCTAssertEqual(controller.dockAnchor.edge, .right)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        controller.stop()
    }

    @MainActor
    func testUnpinnedRailCanPreviewRecentTasksAndSettingsOnHover() async throws {
        let suite = "MacBridge.Docking.HoverPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.hoverPreviews = true
        let controller = FloatingTabController(model: ObserverModel(), preferences: preferences,
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }

        controller.show(.rail, locked: false)
        controller.preview(.recentTasks, inside: true)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverDelay + 0.05) * 1_000_000_000))
        XCTAssertEqual(controller.layer, .recentTasks)
        XCTAssertFalse(controller.machine.locked)

        controller.preview(.settings, inside: true)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverDelay + 0.05) * 1_000_000_000))
        XCTAssertEqual(controller.layer, .settings)
        XCTAssertFalse(controller.machine.locked)
    }
}
