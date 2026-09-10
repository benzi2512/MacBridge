import XCTest
@testable import MacBridgeObserver

// Synthetic transport and controller state only: no sockets, windows, processes,
// credentials, live owner, or external service are used by these regressions.
final class ObserverOwnerRecoveryTests: XCTestCase {
    private static let oldOwner = "11111111-2222-4333-8444-555555555555"
    private static let newOwner = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @MainActor
    private final class Transport {
        var state: [String: Any]
        var requests: [[String: Any]] = []
        var failNextSnapshot = false
        var holdNextSnapshot = false
        var holdControl = false
        var snapshotReply: CheckedContinuation<Void, Error>?
        var controlReply: CheckedContinuation<[String: Any], Error>?

        init(owner: String, works: [String] = []) {
            state = Self.snapshot(owner: owner, works: works)
        }

        static func snapshot(owner: String, works: [String]) -> [String: Any] {
            ["instance_id": owner, "busy": false, "snapshot_stale": false,
             "jobs": [], "transactions": [], "history": [],
             "workspaces": [["workspace_id": "fixture", "display_name": "Fixture"]],
             "work_items": works.enumerated().map { index, id in
                 ["work_id": id, "title": id, "workspace_id": "fixture", "state": "active",
                  "phase": "waiting_next_step", "updated_ms": 1000 + index,
                  "active_call_count": 0, "job_ids": [], "stale": false] as [String: Any]
             }]
        }

        func exchange(_ request: [String: Any]) async throws -> [String: Any] {
            requests.append(request)
            if request["action"] as? String == "snapshot" {
                if failNextSnapshot {
                    failNextSnapshot = false
                    throw Self.failure()
                }
                if let pinned = request["instance_id"] as? String,
                   pinned != state["instance_id"] as? String { throw Self.failure() }
                if holdNextSnapshot {
                    holdNextSnapshot = false
                    try await withCheckedThrowingContinuation { snapshotReply = $0 }
                }
                return state
            }
            if holdControl {
                return try await withCheckedThrowingContinuation { controlReply = $0 }
            }
            return ["operation": "process_cancel", "cancelled": true]
        }

        static func failure() -> NSError {
            NSError(domain: "SyntheticObserver", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Fixture owner unavailable"])
        }
    }

    @MainActor
    private func model(_ transport: Transport) async -> ObserverModel {
        let model = ObserverModel(exchange: { try await transport.exchange($0) })
        model.attach("/fixtures/macbridge-observer-\(UUID().uuidString)")
        model.stopPolling()
        await model.refresh()
        return model
    }

    @MainActor
    func testRestartRediscoveryClearsOldNavigationAndNeverReplaysControl() async throws {
        let transport = Transport(owner: Self.oldOwner, works: ["old-task"])
        let model = await model(transport)
        XCTAssertTrue(model.connected)
        model.selection = "work:old-task"
        model.workspace = "fixture"
        model.detail = "Old output"
        model.detailResult = ["stdout": "Old output"]
        model.selectedFilePreview = SelectedFilePreview([
            "instance_id": Self.oldOwner, "event_id": "event", "workspace_id": "fixture",
            "path": "/fixtures/file.txt", "version": "v1", "total_bytes": 3,
            "truncated": false, "preview_limit_bytes": 16384, "text": "old",
        ], expectedOwner: Self.oldOwner, expectedEvent: "event", previous: nil)
        transport.state = Transport.snapshot(owner: Self.newOwner, works: ["new-task"])

        await model.refresh()
        XCTAssertFalse(model.connected)
        XCTAssertEqual(model.owner, Self.oldOwner)
        XCTAssertTrue(model.detailResult.isEmpty)
        XCTAssertNil(model.selectedFilePreview)
        XCTAssertEqual(transport.requests.last?["instance_id"] as? String, Self.oldOwner)

        await model.refresh()
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertNil(transport.requests.last?["instance_id"])
        XCTAssertEqual(model.owner, Self.newOwner)
        XCTAssertTrue(model.connected)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.workspace, "all")
        XCTAssertTrue(model.detail.isEmpty)
        XCTAssertTrue(model.detailResult.isEmpty)
        XCTAssertNil(model.selectedFilePreview)

        await model.control(PendingControl(kind: "cancel", owner: Self.oldOwner, id: "old-job"))
        XCTAssertEqual(transport.requests.count, 3, "An old-owner control must never be sent or replayed")
        XCTAssertTrue(transport.requests.allSatisfy { $0["action"] as? String == "snapshot" })
    }

    @MainActor
    func testCompactReadingOrderSurvivesSameOwnerFailureButResetsForReplacement() async throws {
        let transport = Transport(owner: Self.oldOwner, works: ["first", "second"])
        let model = await model(transport)
        let suite = "MacBridge.OwnerReadingOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingTabController(model: model, preferences: ObserverPreferences(defaults: defaults),
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.show(.recentTasks)
        let originalIDs = controller.readingOrder.ids
        let selected = try XCTUnwrap(model.compactSummary.tasks.first)
        controller.openTask(selected)
        transport.failNextSnapshot = true
        await model.refresh()
        transport.state = Transport.snapshot(owner: Self.oldOwner, works: ["second", "first", "new"])
        await model.refresh()

        XCTAssertTrue(model.connected)
        XCTAssertEqual(controller.readingOrder.ids, originalIDs)
        XCTAssertEqual(controller.layer, .taskDetail(selected.id))
        XCTAssertEqual(controller.readingOrder.pendingCount(model.compactSummary.tasks), 1)

        transport.state = Transport.snapshot(owner: Self.newOwner, works: ["replacement"])
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(controller.layer, .recentTasks)
        XCTAssertEqual(controller.readingOrder.ids, model.compactSummary.tasks.map(\.id))
        XCTAssertTrue(Set(controller.readingOrder.ids).isDisjoint(with: originalIDs))
        XCTAssertFalse(controller.hasCreatedPanel)
    }

    @MainActor
    func testMalformedDiscoveryIdentityCannotReplaceOwner() async {
        let transport = Transport(owner: Self.oldOwner)
        let model = await model(transport)
        transport.state = Transport.snapshot(owner: "not-an-owner-uuid", works: [])
        await model.refresh()
        await model.refresh()
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.owner, Self.oldOwner)
        XCTAssertNil(transport.requests.last?["instance_id"])

        transport.state = Transport.snapshot(owner: Self.newOwner, works: [])
        await model.refresh()
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.owner, Self.newOwner)
    }

    @MainActor
    func testPendingSnapshotCannotAdoptOwnerWhileAControlIsInFlight() async throws {
        let transport = Transport(owner: Self.oldOwner)
        let model = await model(transport)
        transport.failNextSnapshot = true
        await model.refresh()
        transport.holdNextSnapshot = true
        let pending = Task { await model.refresh() }
        for _ in 0..<100 where transport.snapshotReply == nil { await Task.yield() }
        let reply = try XCTUnwrap(transport.snapshotReply)
        model.commandInFlight = true
        transport.state = Transport.snapshot(owner: Self.newOwner, works: [])
        reply.resume()
        transport.snapshotReply = nil
        await pending.value
        XCTAssertEqual(model.owner, Self.oldOwner)
        XCTAssertFalse(model.connected)
        let count = transport.requests.count
        await model.refresh()
        XCTAssertEqual(transport.requests.count, count, "No discovery dispatch during a pending control")
        model.commandInFlight = false
        await model.refresh()
        XCTAssertEqual(model.owner, Self.newOwner)
        XCTAssertTrue(model.connected)
    }

    @MainActor
    func testUncertainControlFinishesBeforeReadOnlyRecoveryAndIsSentOnce() async throws {
        let transport = Transport(owner: Self.oldOwner)
        let model = await model(transport)
        transport.holdControl = true
        let pending = Task { await model.control(PendingControl(kind: "cancel", owner: Self.oldOwner, id: "fixture-job")) }
        for _ in 0..<100 where transport.controlReply == nil { await Task.yield() }
        let reply = try XCTUnwrap(transport.controlReply)
        XCTAssertTrue(model.commandInFlight)
        let directory = model.directory
        model.attach("/fixtures/different-owner")
        XCTAssertEqual(model.directory, directory, "Choosing another owner cannot redirect a pending action")
        transport.state = Transport.snapshot(owner: Self.newOwner, works: [])
        await model.refresh()
        XCTAssertEqual(transport.requests.count, 2)
        reply.resume(throwing: Transport.failure())
        transport.controlReply = nil
        await pending.value
        XCTAssertFalse(model.commandInFlight)
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.receipt?.contains("outcome is unknown") == true)
        await model.refresh()
        XCTAssertEqual(model.owner, Self.newOwner)
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.receipt?.hasPrefix("Previous owner · ") == true)
        XCTAssertTrue(model.receipt?.contains("outcome is unknown") == true,
                      "Read-only recovery must not erase an uncertain action receipt")
        XCTAssertEqual(transport.requests.filter { $0["action"] as? String == "cancel" }.count, 1)
        XCTAssertEqual(transport.requests.dropFirst(2).compactMap { $0["action"] as? String }, ["snapshot", "snapshot"])
    }

    @MainActor
    func testSettingsPositionFollowsFloatingDisplayIncludingDisplayReplacement() throws {
        let suite = "MacBridge.SettingsDisplay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        var floatingDisplay = "floating-A"
        let position = ObserverSettingsPosition(preferences: preferences, displayID: { floatingDisplay })
        preferences.setNormalizedY(0.31, for: "focused-B")
        position.setNormalizedY(0.65)
        XCTAssertEqual(position.displayID, "floating-A")
        XCTAssertEqual(preferences.normalizedY(for: "floating-A"), 0.65, accuracy: 0.0001)
        XCTAssertEqual(preferences.normalizedY(for: "focused-B"), 0.31, accuracy: 0.0001)
        floatingDisplay = "replacement-C"
        position.setNormalizedY(0.75)
        XCTAssertEqual(position.displayID, "replacement-C")
        XCTAssertEqual(preferences.normalizedY(for: "replacement-C"), 0.75, accuracy: 0.0001)
        XCTAssertEqual(preferences.normalizedY(for: "floating-A"), 0.65, accuracy: 0.0001)
    }
}
