import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MacBridgeObserver

/// Pure geometry/local controller tests; no pointer injection, live owner,
/// production preferences, commands, file transactions or new OS permission.
final class FloatingDockingTests: XCTestCase {
    func testClickToleranceAndDragLatch() {
        var drag = FloatingLogoDrag(start: CGPoint(x: 100, y: 200))
        XCTAssertFalse(drag.move(to: CGPoint(x: 103, y: 202)))
        XCTAssertTrue(drag.move(to: CGPoint(x: 106, y: 200)))
        XCTAssertTrue(drag.move(to: CGPoint(x: 100, y: 200)), "Returning to start must not turn a drag back into a click")
        XCTAssertFalse(drag.move(to: CGPoint(x: CGFloat.nan, y: 200)))
        XCTAssertTrue(drag.isDragging)
    }

    func testNearestEdgeUsesHysteresisAtTheCorner() {
        let screen = CGRect(x: -1920, y: 50, width: 1920, height: 1030)
        XCTAssertEqual(FloatingDockLayout.anchor(at: CGPoint(x: -3, y: 600), visibleFrame: screen, previousEdge: .bottom).edge, .right)
        XCTAssertEqual(FloatingDockLayout.anchor(at: CGPoint(x: -960, y: 53), visibleFrame: screen, previousEdge: .right).edge, .bottom)
        for previous in FloatingDockEdge.allCases {
            XCTAssertEqual(FloatingDockLayout.anchor(at: CGPoint(x: -30, y: 80), visibleFrame: screen, previousEdge: previous).edge, previous)
        }
    }

    func testNormalizedCoordinatesUseEachDisplaysOrigin() {
        let screen = CGRect(x: -1500, y: 1000, width: 1500, height: 900)
        let bottom = FloatingDockLayout.anchor(at: CGPoint(x: -1125, y: 1002), visibleFrame: screen, previousEdge: .right)
        XCTAssertEqual(bottom.edge, .bottom)
        XCTAssertEqual(bottom.position, 0.25, accuracy: 0.00001)
        let right = FloatingDockLayout.anchor(at: CGPoint(x: -2, y: 1450), visibleFrame: screen, previousEdge: .bottom)
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
                        let frame = FloatingDockLayout.frame(visibleFrame: screen, layer: layer, anchor: anchor, taskCount: 64)
                        XCTAssertTrue(EdgeLayout.isContained(frame, in: screen), "\(edge) \(layer) \(frame)")
                        let local = FloatingDockLayout.logo(in: frame.size, layer: layer, edge: edge)
                        let logo = CGPoint(x: frame.minX + local.x, y: frame.maxY - local.y)
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

    func testBottomIdleAndRailAreNarrowAndTaskViewportIsBounded() {
        let screen = CGRect(x: 0, y: 40, width: 1512, height: 920)
        let idle = FloatingDockLayout.size(for: .idle, visibleFrame: screen, edge: .bottom)
        XCTAssertEqual(idle, CGSize(width: 58, height: 30))
        let rail = FloatingDockLayout.size(for: .rail, visibleFrame: screen, edge: .bottom)
        XCTAssertEqual(rail, CGSize(width: 212, height: 40))
        XCTAssertEqual(FloatingDockLayout.size(for: .recentTasks, visibleFrame: screen, taskCount: 6, edge: .bottom),
                       FloatingDockLayout.size(for: .recentTasks, visibleFrame: screen, taskCount: 64, edge: .bottom))
    }

    func testBottomHitRegionHasUprightCardAndNoInvisibleLargeHotZone() {
        let size = FloatingDockLayout.size(for: .recentTasks, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920), edge: .bottom)
        let logo = FloatingDockLayout.logo(in: size, layer: .recentTasks, edge: .bottom)
        let region = FloatingHitRegion(logoY: logo.y, expansion: 1,
            panelSize: EdgeLayout.panelSize(for: .recentTasks, taskCount: 3), dockEdge: .bottom, logoX: logo.x)
            .path(in: CGRect(origin: .zero, size: size))
        XCTAssertTrue(region.contains(logo))
        XCTAssertTrue(region.contains(CGPoint(x: size.width / 2, y: 70)))
        XCTAssertFalse(region.contains(CGPoint(x: 1, y: size.height - 1)))
    }

    func testFullControlTargetsRemainClickableInBothDockOrientations() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 920)
        for edge in FloatingDockEdge.allCases {
            for layer: FloatingLayer in [.rail, .recentTasks, .settings] {
                let size = FloatingDockLayout.size(for: layer, visibleFrame: screen, edge: edge)
                let canvas = CGRect(origin: .zero, size: size)
                let logo = FloatingDockLayout.logo(in: size, layer: layer, edge: edge)
                for expansion: CGFloat in [0.01, 0.5, 1] {
                    let region = FloatingHitRegion(logoY: logo.y, expansion: expansion,
                        panelSize: EdgeLayout.panelSize(for: layer, taskCount: 3), dockEdge: edge, logoX: logo.x).path(in: canvas)
                    for index in 0..<4 {
                        let center = FloatingDockLayout.actionCenter(index: index, logo: logo, edge: edge)
                        // Test blank space around each symbol, not just its center.
                        for dx: CGFloat in [-15.5, 0, 15.5] {
                            for dy: CGFloat in [-15.5, 0, 15.5] {
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
        XCTAssertEqual(MBMetrics.edgeTargetSize, 32)
        XCTAssertEqual(MBMetrics.edgeRailWidth, 36)
        for edge in FloatingDockEdge.allCases {
            let logo = CGPoint(x: 200, y: 200)
            let brandSize = edge == .right ? CGSize(width: 32, height: 38) : CGSize(width: 38, height: 32)
            var previous = CGRect(x: logo.x - brandSize.width / 2, y: logo.y - brandSize.height / 2,
                                  width: brandSize.width, height: brandSize.height)
            for index in 0..<4 {
                let center = FloatingDockLayout.actionCenter(index: index, logo: logo, edge: edge)
                let target = CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)
                let overlap = previous.intersection(target)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0,
                              "\(edge): neighboring controls must not compete for one click")
                previous = target
            }
        }
        // The stack's logo placeholder matches the separately hosted logo.
        let halfStack = (5 * MBMetrics.edgeTargetSize + 4 * MBMetrics.edgeRailSpacing) / 2
        XCTAssertEqual(EdgeLayout.railLogoOffset - halfStack + MBMetrics.edgeTargetSize / 2
                       + FloatingDockLayout.railContentOffset, 0, accuracy: 0.001)
    }

    @MainActor
    func testFloatingHostAndLogoAcceptTheFirstClickWithoutFocusingAnotherApp() {
        let host = FloatingFirstClickHostingView(rootView: Text("Fixture"))
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertNil(host.window, "This check must not show or focus a production window")
        let logo = FloatingLogoControl.LogoView(frame: CGRect(x: 0, y: 0, width: 32, height: 38))
        XCTAssertTrue(logo.acceptsFirstMouse(for: nil))
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 31.5, y: 37.5), CGPoint(x: 16, y: 19)] {
            XCTAssertTrue(logo.hitTest(point) === logo, "The whole logo box must receive clicks and drags")
        }
        XCTAssertNil(logo.hitTest(CGPoint(x: -1, y: 19)))
        XCTAssertNil(logo.hitTest(CGPoint(x: 33, y: 19)))
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
        XCTAssertEqual(controller.dockAnchor.edge, .bottom)
        XCTAssertEqual(controller.layer, .idle)
        controller.pointerChanged(true)
        controller.preview(.recentTasks, inside: true)
        XCTAssertEqual(controller.pendingTransitionCount, 0, "Hover must not race a drag")
        controller.logoPressEnded(at: bottom)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(preferences.dockAnchor(for: controller.displayID).edge, .bottom)
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
}
