import Combine
import XCTest
@testable import MacBridgeObserver

// Model-only: no IPC, child process, window, filesystem or network access.
final class SnapshotPublicationTests: XCTestCase {
    @MainActor
    func testClockOnlyPollingKeepsFreshMetadataWithoutPublishing() {
        let model = ObserverModel()
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        model.updateSnapshot(["instance_id": "owner", "snapshot_ms": 1,
                              "uptime_milliseconds": 10, "jobs": [], "busy": false])
        XCTAssertEqual(changes, 1)
        for clock in 2...100 {
            model.updateSnapshot(["instance_id": "owner", "snapshot_ms": clock,
                                  "uptime_milliseconds": clock * 10, "jobs": [], "busy": false])
        }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.snapshot["snapshot_ms"] as? Int, 100)
        XCTAssertEqual(model.snapshot["uptime_milliseconds"] as? Int, 1000)
    }

    @MainActor
    func testVisibleChangesAndResetStillPublish() {
        let model = ObserverModel()
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        var state: [String: Any] = ["instance_id": "owner", "jobs": [], "snapshot_stale": false]
        model.updateSnapshot(state)
        state["jobs"] = [["task_id": "job", "running": true, "stdout_total_bytes": 0]]
        model.updateSnapshot(state)
        state["jobs"] = [["task_id": "job", "running": true, "stdout_total_bytes": 10]]
        model.updateSnapshot(state)
        state["snapshot_stale"] = true
        model.updateSnapshot(state)
        state["instance_id"] = "other-owner"
        model.updateSnapshot(state)
        state["jobs"] = []
        model.updateSnapshot(state)
        model.updateSnapshot([:])
        XCTAssertEqual(changes, 7)
        XCTAssertTrue(model.snapshot.isEmpty)
    }
}
