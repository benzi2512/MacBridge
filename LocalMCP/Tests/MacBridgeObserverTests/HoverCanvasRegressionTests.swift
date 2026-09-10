import AppKit
import XCTest
@testable import MacBridgeObserver

/// Controller-only regressions with synthetic tasks and disposable preferences.
/// These do not create a panel, connect an owner, or prove compositor smoothness.
final class HoverCanvasRegressionTests: XCTestCase {
    @MainActor
    private func fixture(taskCount: Int = 0) throws ->
        (controller: FloatingTabController, defaults: UserDefaults, suite: String) {
        _ = NSApplication.shared
        let suite = "MacBridge.HoverCanvas.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = ObserverModel()
        let workItems: [[String: Any]] = (0..<taskCount).map { index in
            ["work_id": "fixture-\(index)", "title": "Fixture task \(index)",
             "workspace_id": "fixture", "state": "active", "phase": "executing",
             "updated_ms": 20_000 + index, "call_count": 1, "error_count": 0,
             "active_call_count": 1, "job_ids": [], "stale": false]
        }
        model.updateSnapshot([
            "snapshot_stale": false,
            "workspaces": [["workspace_id": "fixture", "display_name": "Fixture"]],
            "work_items": workItems, "jobs": [], "history": [], "transactions": [],
        ])
        let controller = FloatingTabController(model: model,
            preferences: ObserverPreferences(defaults: defaults), presentsWindow: false,
            openDashboard: { _ in }, openSettings: {})
        return (controller, defaults, suite)
    }

    @MainActor
    func testRecentTasksToDetailExpandsWindowImmediately() throws {
        for count in [0, 1, 6, 64] {
            let fixture = try fixture(taskCount: count)
            defer {
                fixture.controller.stop()
                fixture.defaults.removePersistentDomain(forName: fixture.suite)
            }
            let controller = fixture.controller
            controller.show(.recentTasks, locked: false)
            controller.show(.taskDetail("fixture"), locked: false)

            XCTAssertEqual(controller.readingOrder.ids.count, count)
            XCTAssertEqual(controller.windowLayer, .taskDetail("fixture"),
                "The wider incoming detail must fit immediately even after a long scrollable task list")
            XCTAssertEqual(controller.pendingTransitionCount, 0)
            XCTAssertFalse(controller.hasCreatedPanel)
            XCTAssertEqual(controller.model.directory, "")
        }
    }

    @MainActor
    func testSettingsToRecentTasksRetainsWindowUntilPanelCloses() async throws {
        for count in [0, 1, 6, 64] {
            let fixture = try fixture(taskCount: count)
            defer {
                fixture.controller.stop()
                fixture.defaults.removePersistentDomain(forName: fixture.suite)
            }
            let controller = fixture.controller
            controller.show(.settings, locked: false)
            controller.show(.recentTasks, locked: false)
            XCTAssertEqual(controller.windowLayer, .settings)
            XCTAssertEqual(controller.pendingTransitionCount, 1)

            try await Task.sleep(nanoseconds: 280_000_000)
            XCTAssertEqual(controller.windowLayer, .recentTasks)
            XCTAssertEqual(controller.pendingTransitionCount, 0)
            XCTAssertFalse(controller.hasCreatedPanel)
        }
    }

    @MainActor
    func testReenteringSettingsCancelsPendingRecentTasksShrink() async throws {
        for count in [0, 1, 6, 64] {
            let fixture = try fixture(taskCount: count)
            defer {
                fixture.controller.stop()
                fixture.defaults.removePersistentDomain(forName: fixture.suite)
            }
            let controller = fixture.controller
            controller.show(.settings, locked: false)
            controller.show(.recentTasks, locked: false)
            XCTAssertEqual(controller.pendingTransitionCount, 1)
            controller.show(.settings, locked: false)
            XCTAssertEqual(controller.windowLayer, .settings)
            XCTAssertEqual(controller.pendingTransitionCount, 0)

            try await Task.sleep(nanoseconds: 280_000_000)
            XCTAssertEqual(controller.layer, .settings)
            XCTAssertEqual(controller.windowLayer, .settings)
            XCTAssertEqual(controller.pendingTransitionCount, 0)
            XCTAssertFalse(controller.hasCreatedPanel)
        }
    }

    @MainActor
    func testDisablingHoverPreviewsDuringDwellCancelsPendingPreview() async throws {
        let fixture = try fixture()
        defer {
            fixture.controller.stop()
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
        }
        let controller = fixture.controller
        controller.show(.rail, locked: false)
        controller.pointerChanged(true)
        controller.preview(.recentTasks, inside: true)
        XCTAssertEqual(controller.pendingTransitionCount, 1)
        controller.preferences.hoverPreviews = false

        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(controller.layer, .rail)
        XCTAssertEqual(controller.windowLayer, .rail)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertFalse(controller.hasCreatedPanel)
        XCTAssertEqual(controller.model.directory, "")
    }

    @MainActor
    func testHideWidgetCancelsPendingWorkAndKeepsMenuBarRecovery() async throws {
        let fixture = try fixture(taskCount: 64)
        defer {
            fixture.controller.stop()
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
        }
        let controller = fixture.controller
        controller.preferences.showMenuBar = false
        controller.show(.recentTasks, locked: false)
        XCTAssertEqual(controller.readingOrder.ids.count, 64)
        controller.pointerChanged(true)
        controller.preview(.settings, inside: true)
        XCTAssertGreaterThan(controller.pendingTransitionCount, 0)

        controller.hideWidget()
        XCTAssertFalse(controller.preferences.showFloatingTab)
        XCTAssertTrue(controller.preferences.showMenuBar, "Hide must leave an accessible way to restore the widget")
        XCTAssertEqual(controller.layer, .idle)
        XCTAssertEqual(controller.windowLayer, .idle)
        XCTAssertFalse(controller.machine.locked)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertTrue(controller.readingOrder.ids.isEmpty, "Hidden widget must release its reading snapshot")

        try await Task.sleep(nanoseconds: 280_000_000)
        XCTAssertEqual(controller.layer, .idle, "An old hover callback must not reopen the hidden widget")
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertFalse(controller.hasCreatedPanel)
        XCTAssertEqual(controller.model.directory, "", "The test never starts or connects the core")
        let restored = ObserverPreferences(defaults: fixture.defaults)
        XCTAssertFalse(restored.showFloatingTab)
        XCTAssertTrue(restored.showMenuBar)
    }
}
