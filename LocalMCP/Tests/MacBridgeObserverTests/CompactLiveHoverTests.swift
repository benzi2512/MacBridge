import XCTest
@testable import MacBridgeObserver

/// Deterministic hover integration over the same controller entry points used by
/// SwiftUI's onHover handlers. It needs no global event-posting permission and
/// therefore cannot silently skip on an otherwise healthy build machine.
final class CompactLiveHoverTests: XCTestCase {
    @MainActor
    func testHoverKeepsLogoAndBothPreviewsStable() async throws {
        let suite = "MacBridge.LiveHover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        let controller = FloatingTabController(model: ObserverModel(), preferences: preferences,
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.start()
        for _ in 0..<3 {
            controller.pointerChanged(false)
            try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverExitGrace + MBMetrics.closeDuration + 0.12) * 1_000_000_000))
            XCTAssertEqual(controller.layer, .idle)
            controller.pointerChanged(true)
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(controller.layer, .rail, "Stationary logo hover must not fall onto another icon")
            controller.preview(.recentTasks, inside: true)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(controller.layer, .recentTasks)
            controller.preview(.recentTasks, inside: false)
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(controller.layer, .recentTasks)
            controller.preview(.settings, inside: true)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(controller.layer, .settings, "Settings must use the same smooth hover preview as Recent Tasks")
            controller.activate(.settings)
            controller.preview(.recentTasks, inside: true)
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(controller.layer, .settings, "Pinned panel must survive another icon hover")
            controller.closeDeepest()
            controller.pointerChanged(false)
        }
        controller.pointerChanged(false)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.hoverExitGrace + MBMetrics.closeDuration + 0.12) * 1_000_000_000))
        XCTAssertEqual(controller.layer, .idle)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertEqual(controller.model.directory, "")
    }
}
