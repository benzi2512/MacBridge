import XCTest
@testable import MacBridgeObserver

/// Deterministic model-only workload. No windows, sockets, file reads, owner
/// jobs or wall-clock sleeps. Timings are evidence, not a 120 Hz claim.
final class ObserverFeedPerformanceTests: XCTestCase {
    @MainActor
    func testRepeatedSurfaceReads() throws {
        let model = ObserverModel()
        model.connected = true
        model.updateSnapshot(Self.fixture, now: Date(timeIntervalSince1970: 1000))
        model.workspace = "alpha"
        model.selection = "event:e62"
        XCTAssertEqual(model.allActivityFeed.items.count, 80)
        XCTAssertEqual(model.activityFeed.items.count, 40)
        XCTAssertEqual(model.allActivityFeed.groups.count, 32)
        XCTAssertEqual(model.allActivityFeed.contextGroups.count, 2)

        func burst() -> Int {
            var checksum = 0
            // The real dashboard/compact surfaces ask for both scopes and
            // selected detail independently during a SwiftUI update.
            for _ in 0..<60 {
                checksum += model.activityFeed.items.count
                checksum += model.activityFeed.groups.count
                checksum += model.allActivityFeed.contextGroups.count
                checksum += model.allActivityFeed.runningCount
                checksum += model.history.count
                checksum += model.selectedActivity?.id.count ?? 0
                checksum += model.selectedActivityWork?.children.count ?? 0
                checksum += model.activitySummary.count
            }
            return checksum
        }
        let expected = burst()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(burst(), expected)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "fixture_history": 64, "fixture_jobs": 16, "fixture_parents": 32,
            "bursts_per_sample": 60, "samples_ms": samples,
            "checksum": expected, "native_frame_pacing_measured": false
        ], options: [.sortedKeys])
        print("MB_FEED_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    private static var fixture: [String: Any] {
        let history: [[String: Any]] = (0..<64).map { index in
            let workspace = index.isMultiple(of: 2) ? "alpha" : "beta"
            var row: [String: Any] = ["id": "e\(index)", "tool": "file_read", "state": "returned",
                "workspace_id": workspace, "path": "/fixtures/Projects/\(workspace)/File\(index).swift",
                "started_ms": 990_000 + index, "finished_ms": 990_001 + index,
                "result": ["bytes": 256]]
            if index < 32 { row["work_id"] = "w\(index)" }
            return row
        }
        let jobs: [[String: Any]] = (0..<16).map { index in
            ["task_id": "j\(index)", "work_id": "w\(index)",
             "workspace_id": index.isMultiple(of: 2) ? "alpha" : "beta",
             "running": true, "started_milliseconds": 991_000 + index,
             "stdout_total_bytes": index * 128, "stderr_total_bytes": 0]
        }
        let work: [[String: Any]] = (0..<32).map { index in
            ["work_id": "w\(index)", "title": "Fixture task \(index)",
             "workspace_id": index.isMultiple(of: 2) ? "alpha" : "beta",
             "state": "active", "phase": index < 16 ? "executing" : "waiting_next_step",
             "job_ids": index < 16 ? ["j\(index)"] : [], "call_count": 1,
             "updated_ms": 992_000 + index]
        }
        return ["history": history, "jobs": jobs, "work_items": work, "workspaces": [
            ["workspace_id": "alpha", "display_name": "Alpha", "root_path": "/fixtures/Projects/alpha"],
            ["workspace_id": "beta", "display_name": "Beta", "root_path": "/fixtures/Projects/beta"]]]
    }
}
