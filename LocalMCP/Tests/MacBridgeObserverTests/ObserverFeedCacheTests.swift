import Combine
import XCTest
@testable import MacBridgeObserver

/// Pure model checks: derived data must not outlive its snapshot or health.
final class ObserverFeedCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private var fixture: [String: Any] {
        ["instance_id": "fixture-owner", "snapshot_ms": 1_000_000, "uptime_milliseconds": 0,
         "jobs": [["task_id": "job-a", "workspace_id": "a", "running": true,
                   "started_milliseconds": 990_000, "stdout_total_bytes": 0, "stderr_total_bytes": 0]],
         "history": [
            ["id": "a1", "tool": "file_read", "state": "returned", "work_id": "wa",
             "workspace_id": "a", "path": "/fixtures/projects/Alpha/a.swift", "started_ms": 990_000],
            ["id": "b1", "tool": "file_read", "state": "returned",
             "workspace_id": "b", "path": "/fixtures/projects/Beta/b.swift", "started_ms": 990_000]],
         "work_items": [["work_id": "wa", "workspace_id": "a", "title": "Fixture parent",
                         "state": "active", "phase": "executing", "job_ids": ["job-a"]]],
         "workspaces": [["workspace_id": "a", "display_name": "Alpha"],
                        ["workspace_id": "b", "display_name": "Beta"]]]
    }

    @MainActor
    func testScopesAndSelectionDoNotLeakAcrossRepeatedWorkspaceSwitches() {
        let model = ObserverModel()
        model.connected = true
        model.updateSnapshot(fixture, now: now)
        model.selection = "event:a1"
        for _ in 0..<100 {
            model.workspace = "a"
            XCTAssertEqual(Set(model.activityFeed.items.map(\.id)), ["event:a1", "job:job-a"])
            XCTAssertEqual(model.selectedActivityWork?.workID, "wa")
            model.workspace = "b"
            XCTAssertEqual(model.activityFeed.items.map(\.id), ["event:b1"])
            XCTAssertNil(model.selectedActivity)
            XCTAssertNil(model.selectedActivityWork)
            model.workspace = "missing"
            XCTAssertTrue(model.activityFeed.items.isEmpty)
            XCTAssertEqual(model.allActivityFeed.items.count, 3)
        }
        model.selectGlobalActivity("event:a1")
        XCTAssertEqual(model.workspace, "all")
        XCTAssertEqual(model.selectedActivity?.id, "event:a1")
    }

    @MainActor
    func testHealthChangesInvalidateBothScopesWithoutNeedingAnotherSnapshot() throws {
        let model = ObserverModel()
        model.connected = true
        model.workspace = "a"
        model.updateSnapshot(fixture, now: now)
        for _ in 0..<2 {
            XCTAssertEqual(model.activityFeed.runningCount, 1)
            XCTAssertEqual(model.allActivityFeed.runningCount, 1)
            model.busy = true
            XCTAssertFalse(model.activityFeed.jobsCurrent)
            XCTAssertFalse(model.allActivityFeed.jobsCurrent)
            XCTAssertFalse(try XCTUnwrap(model.activityFeed.groups.first).executing)
            XCTAssertEqual(model.allActivityFeed.runningCount, 0)
            XCTAssertFalse(model.canControl)
            model.busy = false
            XCTAssertEqual(model.activityFeed.runningCount, 1)
            model.connected = false
            XCTAssertFalse(model.activityFeed.connected)
            XCTAssertFalse(model.allActivityFeed.connected)
            XCTAssertEqual(model.allActivityFeed.runningCount, 0)
            XCTAssertFalse(try XCTUnwrap(model.activityFeed.groups.first).executing)
            model.connected = true
        }
        XCTAssertTrue(model.allActivityFeed.jobsCurrent)
        XCTAssertEqual(model.activityFeed.runningCount, 1)
    }

    @MainActor
    func testOutputChangeMissingJobsAndOwnerReplacementDiscardCachedPayloads() {
        let model = ObserverModel()
        model.connected = true
        model.workspace = "a"
        model.selection = "event:a1"
        var state = fixture
        model.updateSnapshot(state, now: now)
        XCTAssertEqual(model.allActivityFeed.items.count, 3)
        XCTAssertEqual(model.activityFeed.items.first?.raw["stdout_total_bytes"] as? Int, 0)
        var jobs = state["jobs"] as! [[String: Any]]
        jobs[0]["stdout_total_bytes"] = 128
        state["jobs"] = jobs
        model.updateSnapshot(state, now: now)
        XCTAssertEqual(model.activityFeed.items.first?.raw["stdout_total_bytes"] as? Int, 128)
        XCTAssertEqual(model.allActivityFeed.items.first?.raw["stdout_total_bytes"] as? Int, 128)
        state["snapshot_stale"] = true
        model.updateSnapshot(state, now: now)
        XCTAssertFalse(model.allActivityFeed.jobsCurrent)
        XCTAssertFalse(model.activityFeed.jobsCurrent)
        state.removeValue(forKey: "snapshot_stale")
        state.removeValue(forKey: "jobs")
        model.updateSnapshot(state, now: now)
        XCTAssertFalse(model.activityFeed.jobsCurrent)
        XCTAssertTrue(model.allActivityFeed.items.allSatisfy { $0.kind == .call })
        model.updateSnapshot(["instance_id": "replacement", "jobs": [], "history": [], "work_items": []], now: now)
        XCTAssertTrue(model.activityFeed.items.isEmpty)
        XCTAssertTrue(model.allActivityFeed.groups.isEmpty)
        XCTAssertNil(model.selectedActivity)
    }

    @MainActor
    func testClockMetadataStaysFreshWithoutChangingRowsOrPublishingEveryPoll() {
        let model = ObserverModel()
        model.connected = true
        model.workspace = "b"
        var state = fixture
        model.updateSnapshot(state, now: now)
        let ids = model.activityFeed.items.map(\.id)
        _ = model.allActivityFeed
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for seconds in 1...100 {
            state["snapshot_ms"] = 1_000_000 + seconds * 1000
            state["uptime_milliseconds"] = seconds * 1000
            model.updateSnapshot(state, now: now.addingTimeInterval(Double(seconds)))
            XCTAssertEqual(model.activityFeed.items.map(\.id), ids)
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.snapshot["uptime_milliseconds"] as? Int, 100_000)
        XCTAssertTrue(model.activityFeed.contextGroups.first?.recent == true)
        model.updateSnapshot(state, now: now.addingTimeInterval(110))
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(model.activityFeed.contextGroups.first?.recent == false)
        XCTAssertTrue(model.allActivityFeed.contextGroups.first?.recent == false)
    }

    @MainActor
    func testClockCorrectionAndFutureReceiptCrossingsUpdateWithoutExtraTimer() {
        let model = ObserverModel()
        model.connected = true
        model.workspace = "b"
        model.updateSnapshot(fixture, now: now)
        XCTAssertTrue(model.activityFeed.contextGroups.first?.recent == true)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        model.updateSnapshot(fixture, now: Date(timeIntervalSince1970: 980))
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(model.activityFeed.contextGroups.first?.recent == false)
        XCTAssertTrue(model.allActivityFeed.contextGroups.first?.recent == false)
        model.updateSnapshot(fixture, now: Date(timeIntervalSince1970: 989))
        XCTAssertEqual(changes, 1)
        model.updateSnapshot(fixture, now: Date(timeIntervalSince1970: 990))
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(model.activityFeed.contextGroups.first?.recent == true)
        XCTAssertTrue(model.allActivityFeed.contextGroups.first?.recent == true)
        model.updateSnapshot(fixture, now: Date(timeIntervalSince1970: 1110))
        XCTAssertEqual(changes, 3)
        XCTAssertTrue(model.activityFeed.contextGroups.first?.recent == false)
    }

    @MainActor
    func testSnapshotReplacementAndModelReleaseDoNotRetainOldPayloads() {
        var model: ObserverModel? = ObserverModel()
        weak var weakModel = model
        weak var retainedPayload: NSObject?
        autoreleasepool {
            let marker = NSObject()
            retainedPayload = marker
            var state = fixture
            var rows = state["history"] as! [[String: Any]]
            rows[0]["fixture_lifetime_marker"] = marker
            state["history"] = rows
            model?.updateSnapshot(state, now: now)
            model?.workspace = "a"
            _ = model?.activityFeed
            _ = model?.allActivityFeed
        }
        XCTAssertNotNil(retainedPayload)
        autoreleasepool { model?.updateSnapshot(["jobs": [], "history": []], now: now) }
        XCTAssertNil(retainedPayload, "No previous snapshot is kept as a cache history")
        model = nil
        XCTAssertNil(weakModel)
    }
}
