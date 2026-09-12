import AppKit
import XCTest
@testable import MacBridgeObserver

/// Opt-in physical-pointer acceptance. No owner connection, commands or files.
/// Uses existing event-posting permission only; never requests a new permission.
final class CompactLiveHoverTests: XCTestCase {
    @MainActor
    func testRealPointerKeepsLogoAndPreviewStable() async throws {
        guard ProcessInfo.processInfo.environment["MB_OBSERVER_LIVE_HOVER"] == "1" else {
            throw XCTSkip("Opt in to the bounded real-pointer check")
        }
        guard CGPreflightPostEventAccess() else {
            throw XCTSkip("No existing permission to post pointer events")
        }
        _ = NSApplication.shared
        let suite = "MacBridge.LiveHover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedPointer = try XCTUnwrap(CGEvent(source: nil)).location
        func move(_ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        defer { move(savedPointer) }
        let preferences = ObserverPreferences(defaults: defaults)
        let controller = FloatingTabController(model: ObserverModel(), preferences: preferences,
            openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.start()
        let screen = try XCTUnwrap(controller.currentScreen)
        let mainTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        func pointerPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: mainTop - p.y) }
        let anchor = preferences.dockAnchor(for: controller.displayID)
        let idle = FloatingDockLayout.placement(visibleFrame: screen.visibleFrame, layer: .idle, anchor: anchor)
        let rail = FloatingDockLayout.placement(visibleFrame: screen.visibleFrame, layer: .rail, anchor: anchor)
        let screenLogo = CGPoint(x: idle.frame.minX + idle.logo.x, y: idle.frame.maxY - idle.logo.y)
        let outside = pointerPoint(CGPoint(x: idle.frame.minX - 450, y: screenLogo.y))
        let logo = pointerPoint(screenLogo)
        func action(_ index: Int) -> CGPoint {
            let local = FloatingDockLayout.actionCenter(index: index, logo: rail.logo, edge: .right,
                                                        direction: rail.direction)
            return pointerPoint(CGPoint(x: rail.frame.minX + local.x, y: rail.frame.maxY - local.y))
        }
        let recent = action(1)
        let settings = action(2)
        for _ in 0..<3 {
            move(outside)
            try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverExitGrace + MBMetrics.closeDuration + 0.12) * 1_000_000_000))
            XCTAssertEqual(controller.layer, .idle)
            move(logo)
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(controller.layer, .rail, "Stationary logo hover must not fall onto another icon")
            move(recent)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(controller.layer, .recentTasks)
            // Enter the attached panel, then stay still across several UI updates.
            move(CGPoint(x: recent.x - 120, y: recent.y))
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(controller.layer, .recentTasks)
            move(settings)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(controller.layer, .recentTasks, "Passing a click-only Settings icon must not switch panels")
            controller.activate(.recentTasks)
            move(settings)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(controller.layer, .recentTasks, "Pinned panel must survive actual icon hover")
            controller.closeDeepest()
        }
        move(outside)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverExitGrace + MBMetrics.closeDuration + 0.12) * 1_000_000_000))
        XCTAssertEqual(controller.layer, .idle)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertEqual(controller.model.directory, "")
    }
}
