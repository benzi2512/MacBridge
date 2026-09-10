import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

// Synthetic observer responses and private test preferences. No live owner,
// production preferences, tunnel, network, credential or login service is used.
final class LifecycleReliabilityTests: XCTestCase {
    private static let first = "11111111-2222-4333-8444-555555555555"
    private static let next = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @MainActor
    private final class Transport {
        var owner = LifecycleReliabilityTests.first
        var available = true
        var requests: [[String: Any]] = []

        func exchange(_ request: [String: Any]) throws -> [String: Any] {
            requests.append(request)
            if !available || (request["instance_id"] as? String).map({ $0 != owner }) == true {
                throw NSError(domain: "SyntheticLifecycle", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Owner offline or replaced"])
            }
            return ["instance_id": owner, "snapshot_stale": false, "busy": false,
                    "jobs": [], "history": [], "work_items": [], "transactions": []]
        }
    }

    @MainActor
    private func attached(_ transport: Transport) async -> ObserverModel {
        let model = ObserverModel(exchange: { try transport.exchange($0) })
        model.attach("/fixtures/observer-\(UUID().uuidString)")
        model.stopPolling()
        await model.refresh()
        return model
    }

    @MainActor
    func testMenuBarOnlyDetectsCoreReplacementWithoutOpeningAWindow() async {
        let transport = Transport()
        let model = await attached(transport)
        model.menuBarVisible = true
        transport.owner = Self.next
        let offlineDelay = await model.pollingCycle(refreshImmediately: false, visibleWindow: false)
        XCTAssertFalse(model.connected)
        XCTAssertEqual(offlineDelay, 30_000_000_000)
        let recoveryDelay = await model.pollingCycle(refreshImmediately: false, visibleWindow: false)
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.owner, Self.next)
        XCTAssertEqual(recoveryDelay, 30_000_000_000)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests.allSatisfy { $0["action"] as? String == "snapshot" })
    }

    @MainActor
    func testLateCoreStartupRecoversWhileOnlyMenuBarIsVisible() async {
        let transport = Transport()
        transport.available = false
        let model = await attached(transport)
        model.menuBarVisible = true
        XCTAssertFalse(model.connected)
        transport.available = true
        _ = await model.pollingCycle(refreshImmediately: false, visibleWindow: false)
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.owner, Self.first)
        XCTAssertEqual(transport.requests.count, 2)
    }

    @MainActor
    func testHiddenConnectedUIDoesNotPollWithoutAVisibleStatusSurface() async {
        let transport = Transport()
        let model = await attached(transport)
        for _ in 0..<20 {
            _ = await model.pollingCycle(refreshImmediately: false, visibleWindow: false)
        }
        XCTAssertEqual(transport.requests.count, 1)
        _ = await model.pollingCycle(refreshImmediately: false, visibleWindow: true)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testMenuBarOnlyCadenceStaysBoundedAcrossWorkPowerAndFailures() {
        for active in [true, false] {
            for work in [true, false] {
                for lowPower in [true, false] {
                    for failures in 0...8 {
                        XCTAssertEqual(ObserverPollingCadence.delayNanoseconds(appActive: active,
                            activeWork: work, lowPower: lowPower, consecutiveFailures: failures,
                            menuBarOnly: true), 30_000_000_000)
                    }
                }
            }
        }
    }

    @MainActor
    func testWakeRefreshDoesNotReplayOrInterruptPendingControls() async {
        let transport = Transport()
        let model = await attached(transport)
        model.commandInFlight = true
        model.resumeObservation()
        for _ in 0..<30 { await Task.yield() }
        model.stopPolling()
        XCTAssertTrue(model.commandInFlight)
        XCTAssertEqual(transport.requests.count, 1)
        model.commandInFlight = false
        _ = await model.pollingCycle(refreshImmediately: true, visibleWindow: false)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests.allSatisfy { $0["action"] as? String == "snapshot" })
    }

    @MainActor
    func testWakeRequestsOneReadEvenWithNoVisibleWindow() async {
        let transport = Transport()
        let model = await attached(transport)
        model.resumeObservation()
        for _ in 0..<100 where transport.requests.count < 2 { await Task.yield() }
        model.stopPolling()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(model.connected)
    }

    @MainActor
    func testRepeatedWakeAndActivationCoalesceWhileSnapshotIsInFlight() async {
        var requests = 0
        var suspended: CheckedContinuation<[String: Any], Error>?
        let model = ObserverModel(exchange: { request in
            requests += 1
            XCTAssertEqual(request["action"] as? String, "snapshot")
            return try await withCheckedThrowingContinuation { suspended = $0 }
        })
        model.attach("/fixtures/lifecycle-single-flight-\(UUID().uuidString)")
        for _ in 0..<100 where suspended == nil { await Task.yield() }
        XCTAssertNotNil(suspended)
        for _ in 0..<30 { model.resumeObservation() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(requests, 1)
        suspended?.resume(returning: ["instance_id": Self.first, "jobs": [], "history": []])
        for _ in 0..<100 where !model.connected { await Task.yield() }
        XCTAssertTrue(model.connected, "Activation must not cancel the only useful snapshot")
        XCTAssertEqual(requests, 1)
        model.stopPolling()
    }

    @MainActor
    func testShowWidgetMenuRoundTripDoesNotNeedTheCore() throws {
        _ = NSApplication.shared
        let suite = "MacBridge.Lifecycle.Menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.showMenuBar = false
        preferences.hideFloatingTab()
        XCTAssertTrue(preferences.showMenuBar)
        let model = ObserverModel()
        let controller = MenuBarController(model: model, preferences: preferences,
            openDashboard: { _ in XCTFail("Show Widget must not open Dashboard") },
            openSettings: { XCTFail("Show Widget must not open Settings") }, showFloating: { _ in })
        let menu = NSMenu()
        for _ in 0..<10 {
            controller.menuNeedsUpdate(menu)
            let show = try XCTUnwrap(menu.items.firstIndex { $0.title == "Show Widget" })
            menu.performActionForItem(at: show)
            XCTAssertTrue(preferences.showFloatingTab)
            controller.menuNeedsUpdate(menu)
            let hide = try XCTUnwrap(menu.items.firstIndex { $0.title == "Hide Widget" })
            menu.performActionForItem(at: hide)
            XCTAssertFalse(preferences.showFloatingTab)
            XCTAssertTrue(preferences.showMenuBar)
        }
        XCTAssertEqual(model.directory, "")
    }

    @MainActor
    func testExplicitReopenRestoresHiddenWidgetEvenWhenDashboardIsVisible() throws {
        let app = NSApplication.shared
        let suite = "MacBridge.Lifecycle.Reopen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.hideFloatingTab()
        let model = ObserverModel()
        let lifecycle = MacBridgeLifecycle(model: model, preferences: preferences)
        XCTAssertTrue(lifecycle.applicationShouldHandleReopen(app, hasVisibleWindows: true))
        XCTAssertTrue(preferences.showFloatingTab)
        XCTAssertEqual(model.directory, "")
        model.stopPolling()
    }

    @MainActor
    func testRecoveryButtonRendersOnlyWhenWidgetIsHidden() throws {
        _ = NSApplication.shared
        let suite = "MacBridge.Lifecycle.Button.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.hideFloatingTab()
        let hidden = NSHostingView(rootView: WidgetRecoveryButton(preferences: preferences))
        hidden.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hidden.fittingSize.width, 60)
        XCTAssertGreaterThan(hidden.fittingSize.height, 12)
        preferences.showFloatingTab = true
        let shown = NSHostingView(rootView: WidgetRecoveryButton(preferences: preferences))
        shown.layoutSubtreeIfNeeded()
        XCTAssertEqual(shown.fittingSize.height, 0, accuracy: 1)
    }
}
