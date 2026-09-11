import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

/// Synthetic source-only acceptance. No installed UI, owner, provider,
/// pointer events, timers, or real preference domains are used.
final class CodeNotchMotionTests: XCTestCase {
    func testMotionUsesOneReferenceAndBoundedStagger() {
        XCTAssertEqual(FloatingMotion.unfoldResponse, 0.42)
        XCTAssertEqual(FloatingMotion.unfoldDamping, 0.78)
        XCTAssertEqual(FloatingMotion.contentsResponse, 0.36)
        XCTAssertEqual(FloatingMotion.contentsDamping, 0.82)
        XCTAssertEqual(FloatingMotion.glideResponse, 0.50)
        XCTAssertEqual(FloatingMotion.glideDamping, 0.86)
        XCTAssertEqual(FloatingMotion.staggerDelay(index: -10), 0)
        XCTAssertEqual(FloatingMotion.staggerDelay(index: 3), 0.135, accuracy: 0.0001)
        XCTAssertEqual(FloatingMotion.staggerDelay(index: 1_000_000), 0.18)
        XCTAssertNil(FloatingMotion.unfold(reduced: true))
        XCTAssertNotNil(FloatingMotion.unfold(reduced: false))
        XCTAssertGreaterThan(MBMetrics.closeDuration, FloatingMotion.unfoldResponse)
        XCTAssertGreaterThan(MBMetrics.panelDuration, FloatingMotion.glideResponse)
    }

    func testSpringOvershootFitsReservedCanvasAndKeepsMarkAnchored() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let canvas = CGRect(origin: .zero, size: EdgeLayout.size(for: .rail, visibleFrame: screen))
        let logo = CGPoint(x: canvas.maxX - EdgeLayout.logoInset, y: canvas.midY - EdgeLayout.railLogoOffset)
        let rail = CGRect(x: canvas.maxX - MBMetrics.edgeRailWidth,
                          y: canvas.midY - MBMetrics.edgeRailHeight / 2,
                          width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight)
        for step in -40...1040 {
            let t = CGFloat(step) / 1000
            let path = AnchoredOrganicEdgeShape(expansion: t).path(in: rail)
            XCTAssertTrue(path.contains(logo), "Spring reversal must not move the logo out of the surface")
            XCTAssertGreaterThanOrEqual(path.boundingRect.minX, canvas.minX)
            XCTAssertGreaterThanOrEqual(path.boundingRect.minY, canvas.minY)
            XCTAssertLessThanOrEqual(path.boundingRect.maxX, canvas.maxX + 0.001)
            XCTAssertLessThanOrEqual(path.boundingRect.maxY, canvas.maxY)
            let hit = FloatingHitRegion(logoY: logo.y, expansion: t, panelSize: .zero).path(in: canvas)
            var expected = path.boundingRect.union(CGRect(x: logo.x - 16, y: logo.y - 19,
                                                          width: 32, height: 38).intersection(canvas))
            if t > 0 {
                for slot in 1...4 {
                    expected = expected.union(CGRect(x: logo.x - 16, y: logo.y + CGFloat(slot) * 35 - 16,
                                                     width: 32, height: 32).intersection(canvas))
                }
            }
            for (actual, expected) in zip([hit.boundingRect.minX, hit.boundingRect.minY, hit.boundingRect.maxX, hit.boundingRect.maxY],
                                         [expected.minX, expected.minY, expected.maxX, expected.maxY]) {
                XCTAssertEqual(actual, expected, accuracy: 0.0001, "Spring silhouette plus fixed button boxes, never the full transparent canvas")
            }
            XCTAssertTrue(EdgeLayout.isContained(hit.boundingRect, in: canvas, tolerance: 0.001),
                          "Allow only CoreGraphics subpixel rounding at the screen edge")
        }
        let overshoot = AnchoredOrganicEdgeShape(expansion: 1.02).path(in: rail).boundingRect
        XCTAssertGreaterThan(overshoot.height, MBMetrics.edgeRailHeight, "Do not clip the spring into an eased hard stop")
    }

    @MainActor
    func testExitGraceSurvivesBriefExcursionAndClosesOnlyAfterSettling() async throws {
        _ = NSApplication.shared
        let suite = "MacBridge.CodeNotchMotion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingTabController(model: ObserverModel(), preferences: ObserverPreferences(defaults: defaults),
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.show(.recentTasks, locked: false)
        controller.pointerChanged(true)
        controller.pointerChanged(false)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(controller.layer, .recentTasks, "A brief excursion must not fold the panel")
        controller.pointerChanged(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.layer, .recentTasks, "Re-entry cancels the stale close")
        controller.pointerChanged(false)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverExitGrace + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.layer, .idle)
        XCTAssertEqual(controller.windowLayer, .recentTasks, "Keep the departing canvas until spring settles")
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.closeDuration + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.windowLayer, .idle)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertFalse(controller.hasCreatedPanel)
        XCTAssertEqual(controller.model.directory, "")
    }

    @MainActor
    func testRepeatedStationaryHoverCreatesNoNewWork() throws {
        let suite = "MacBridge.CodeNotchIdle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingTabController(model: ObserverModel(), preferences: ObserverPreferences(defaults: defaults),
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        for _ in 0..<10_000 {
            controller.pointerChanged(false)
            controller.show(.idle)
        }
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertFalse(controller.hasCreatedPanel)
        controller.show(.taskDetail("fixture"), locked: true)
        controller.pointerChanged(true)
        for _ in 0..<10_000 {
            controller.pointerChanged(true)
            controller.show(.taskDetail("fixture"), locked: true)
        }
        XCTAssertEqual(controller.layer, .taskDetail("fixture"))
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertEqual(controller.model.directory, "")
    }
}
