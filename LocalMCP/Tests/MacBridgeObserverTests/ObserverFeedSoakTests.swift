import Combine
import Darwin
import XCTest
@testable import MacBridgeObserver

/// Accelerated model-only churn, not a wall-clock/native compositor test. No
/// owner transport, windows, pointer events, project files or preferences.
final class ObserverFeedSoakTests: XCTestCase {
    private final class Payload: NSObject {
        let bytes: Data
        init(generation: Int) { bytes = Data(repeating: UInt8(generation % 251 + 1), count: 65_536) }
    }
    private final class WeakPayload {
        weak var value: Payload?
        init(_ value: Payload) { self.value = value }
    }

    @MainActor
    func testSustainedSnapshotChurnReleasesOldPayloadsAndKeepsScopesAccurate() throws {
        guard ProcessInfo.processInfo.environment["MB_OBSERVER_FEED_SOAK"] == "1" else {
            throw XCTSkip("Opt-in release-mode model memory/churn qualification")
        }
        var model: ObserverModel? = ObserverModel()
        weak var weakModel = model
        var previous: WeakPayload?
        var changes = 0
        var subscription: AnyCancellable? = model?.objectWillChange.sink { changes += 1 }
        var samples: [[String: Any]] = []
        var released = 0, scopeChecks = 0, quietRefreshes = 0
        let start = DispatchTime.now().uptimeNanoseconds
        let cycles = 2048, blockSize = 128

        for generation in 0..<cycles {
            let old = previous
            previous = try autoreleasepool {
                let model = try XCTUnwrap(model)
                let payload = Payload(generation: generation)
                let now = Date(timeIntervalSince1970: 1_000 + Double(generation) * 5)
                var state = Self.fixture(generation: generation, now: now, payload: payload)
                let hasJobs = !generation.isMultiple(of: 23)
                let jobsRunning = !generation.isMultiple(of: 3)
                model.connected = !generation.isMultiple(of: 17)
                model.busy = generation.isMultiple(of: 11)
                model.workspace = "all"
                model.selection = "event:anchor"
                model.updateSnapshot(state, now: now)
                let current = model.connected && !model.busy && !generation.isMultiple(of: 19) && hasJobs
                XCTAssertEqual(model.allActivityFeed.items.count, hasJobs ? 80 : 64)
                XCTAssertEqual(model.allActivityFeed.groups.count, 32)
                XCTAssertEqual(model.allActivityFeed.contextGroups.count, 16)
                XCTAssertEqual(model.allActivityFeed.runningCount, current && jobsRunning ? 16 : 0)
                XCTAssertEqual(model.allActivityFeed.jobsCurrent, current)
                XCTAssertEqual(model.allActivityFeed.displayCount(filter: .ungrouped), 16)
                XCTAssertEqual(model.allActivityFeed.matching(query: "orphan", filter: .ungrouped).count, 8)
                XCTAssertEqual(model.selectedActivity?.id, "event:anchor")

                // Rotate through many distinct keys, including never-present
                // scopes. Reusing a workspace cache must not expose another.
                for scope in ["space-\(generation % 16)", "space-\((generation + 7) % 16)", "absent-\(generation)"] {
                    model.workspace = scope
                    let feed = model.activityFeed
                    let absent = scope.hasPrefix("absent-")
                    XCTAssertEqual(feed.items.count, absent ? 0 : hasJobs ? 5 : 4)
                    XCTAssertEqual(feed.groups.count, absent ? 0 : 2)
                    XCTAssertEqual(feed.contextGroups.count, absent ? 0 : 1)
                    XCTAssertTrue(feed.items.allSatisfy { $0.workspaceID == scope })
                    XCTAssertEqual(feed.displayCount(filter: .ungrouped), absent ? 0 : 1)
                    XCTAssertEqual(model.allActivityFeed.items.count, hasJobs ? 80 : 64)
                    scopeChecks += 1
                }
                model.workspace = "all"
                XCTAssertEqual(model.selectedActivity?.id, "event:anchor")
                XCTAssertEqual(model.selectedActivity?.raw["generation"] as? Int, generation)
                XCTAssertEqual(model.directory, "")
                XCTAssertNil(model.owner)

                // Same snapshot with only fresher clock metadata must not
                // redraw the dashboard. Stay before the next context expiry.
                if (generation + 1).isMultiple(of: blockSize) {
                    let published = changes
                    for tick in 1...10 {
                        state["snapshot_ms"] = now.timeIntervalSince1970 * 1000 + Double(tick)
                        state["uptime_milliseconds"] = generation * 5000 + tick
                        model.updateSnapshot(state, now: now.addingTimeInterval(Double(tick) / 1000))
                        XCTAssertEqual(changes, published)
                        quietRefreshes += 1
                    }
                }
                return WeakPayload(payload)
            }
            XCTAssertNotNil(previous?.value, "The current snapshot retains its payload")
            if old != nil {
                XCTAssertNil(old?.value, "An evicted snapshot must not survive through a cached scope")
                released += 1
            }
            if (generation + 1).isMultiple(of: blockSize) {
                var sample = try Self.ownMemory()
                sample["snapshots"] = generation + 1
                sample["elapsed_ms"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                samples.append(sample)
            }
        }
        autoreleasepool { model?.updateSnapshot(["history": [], "jobs": [], "work_items": []]) }
        XCTAssertNil(previous?.value, "Final snapshot release must discard the last test payload")
        released += 1
        subscription?.cancel(); subscription = nil
        model = nil
        XCTAssertNil(weakModel)
        let afterRelease = try Self.ownMemory()
        XCTAssertEqual(released, cycles)
        XCTAssertEqual(scopeChecks, cycles * 3)
        XCTAssertEqual(quietRefreshes, 160)
        XCTAssertEqual(samples.count, 16)
        let report: [String: Any] = [
            "snapshots": cycles, "workspace_scope_checks": scopeChecks,
            "quiet_clock_refreshes": quietRefreshes, "released_payloads": released,
            "payload_bytes_per_generation": 65_536, "samples": samples,
            "after_model_release": afterRelease, "owner_connected": false,
            "accelerated_model_test": true, "whole_app_energy_measured": false,
            "native_frame_pacing_measured": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("MB_FEED_SOAK " + String(decoding: data, as: UTF8.self))
    }

    private static func ownMemory() throws -> [String: Any] {
        // TASK_VM_INFO is queried only for this test process; no other task's
        // memory, permission or content is inspected. Report both metrics:
        // resident bytes alone omit compressed/other charged physical memory.
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.phys_footprint > 0, info.resident_size > 0 else {
            throw NSError(domain: "MacBridgeModelMemoryFixture", code: Int(result))
        }
        return ["physical_footprint_bytes": info.phys_footprint, "resident_bytes": info.resident_size]
    }

    private static func fixture(generation: Int, now: Date, payload: Payload) -> [String: Any] {
        let milliseconds = Int(now.timeIntervalSince1970 * 1000)
        let history: [[String: Any]] = (0..<64).map { index in
            let space = "space-\(index % 16)"
            var row: [String: Any] = ["id": index == 0 ? "anchor" : "e\(generation)-\(index)",
                "generation": generation, "tool": "file_read", "state": "returned",
                "workspace_id": space, "started_ms": milliseconds - 10, "finished_ms": milliseconds - 1]
            if index < 56 { row["path"] = "/fixtures/Projects/\(space)/\(index >= 48 ? "orphan" : "File")\(index).swift" }
            if index < 32 { row["work_id"] = "w\(generation)-\(index)" }
            if (48..<56).contains(index) { row["work_id"] = "missing-\(generation)-\(index)" }
            if index == 0 { row["fixture_lifetime_marker"] = payload }
            return row
        }
        let running = !generation.isMultiple(of: 3)
        let jobs: [[String: Any]] = (0..<16).map { index in
            var row: [String: Any] = ["task_id": "j\(generation)-\(index)", "work_id": "w\(generation)-\(index)",
                "workspace_id": "space-\(index)", "running": running, "started_milliseconds": milliseconds - 20,
                "stdout_total_bytes": generation * 128 + index, "stderr_total_bytes": 0]
            if !running { row["exit_code"] = 0 }
            return row
        }
        let work: [[String: Any]] = (0..<32).map { index in
            ["work_id": "w\(generation)-\(index)", "title": "Fixture task \(index)",
             "workspace_id": "space-\(index % 16)", "state": "active",
             "phase": index < 16 && running ? "executing" : "waiting_next_step",
             "job_ids": index < 16 ? ["j\(generation)-\(index)"] : [], "updated_ms": milliseconds - 1]
        }
        var state: [String: Any] = ["history": history, "work_items": work,
            "snapshot_stale": generation.isMultiple(of: 19), "snapshot_ms": milliseconds,
            "workspaces": (0..<16).map { ["workspace_id": "space-\($0)", "display_name": "Space \($0)",
                "root_path": "/fixtures/Projects/space-\($0)"] }]
        if !generation.isMultiple(of: 23) { state["jobs"] = jobs }
        return state
    }
}
