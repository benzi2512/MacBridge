import XCTest
@testable import MacBridgeObserver

/// Retained synthetic metadata only; never connects to the owner or reads a project.
final class UngroupedActivityTests: XCTestCase {
    private let spaces: [[String: Any]] = [
        ["workspace_id": "first", "display_name": "First"],
        ["workspace_id": "second", "display_name": "Second"]
    ]
    private let parent: [String: Any] = ["work_id": "parent", "title": "Declared task", "workspace_id": "first",
        "state": "active", "phase": "waiting_next_step", "updated_ms": 1_000_000]

    private func call(_ id: String, workspace: String = "first", work: String? = nil,
                      path: String? = nil, running: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["id": id, "workspace_id": workspace, "tool": "file_read",
            "state": running ? "running" : "returned", "started_ms": 1_000_000, "finished_ms": 1_000_001]
        row["work_id"] = work; row["path"] = path
        return row
    }

    private var history: [[String: Any]] {
        [call("grouped", work: "parent", path: "/fixtures/Projects/Alpha/file.swift"),
         call("context", path: "/fixtures/Projects/Alpha/file.swift"),
         call("orphan", work: "missing-parent", path: "/fixtures/Projects/Alpha/file.swift"),
         call("unknown"), call("other", workspace: "second"), call("running", running: true)]
    }
    private var jobs: [[String: Any]] {
        [["task_id": "live", "workspace_id": "first", "running": true],
         ["task_id": "done", "workspace_id": "second", "running": false, "exit_code": 0]]
    }
    private func feed(_ rows: [[String: Any]]? = nil, workspace: String = "all", connected: Bool = true) -> ActivityFeed {
        ActivityFeed(history: rows ?? history, jobs: jobs, workItems: [parent], workspaces: spaces,
            workspace: workspace, connected: connected, stale: !connected, now: Date(timeIntervalSince1970: 1_001))
    }
    private func reading(_ current: ActivityFeed) -> ActivityReadingOrder {
        ActivityReadingOrder(feed: current, transactions: [["transaction_id": "not-an-ungrouped-task"]],
            owner: "fixture-owner", workspace: "all", query: "", filter: .ungrouped)
    }

    func testFourthTabCountsOnlyUngroupedRowsNotDeclaredOrContextChildren() {
        XCTAssertEqual(ActivityPresentation.Filter.allCases.map(\.rawValue), ["All", "Active", "Issues", "Ungrouped"])
        let current = feed()
        XCTAssertEqual(current.groups.count, 1)
        XCTAssertEqual(current.contextGroups.count, 1)
        let expected = Set(["event:orphan", "event:unknown", "event:other", "event:running", "job:live", "job:done"])
        XCTAssertEqual(Set(current.matching(filter: .ungrouped).map(\.id)), expected)
        XCTAssertEqual(Set(current.matchingUngrouped(filter: .ungrouped).map(\.id)), expected)
        XCTAssertTrue(current.matchingGroups(filter: .ungrouped).isEmpty)
        XCTAssertTrue(current.matchingContexts(filter: .ungrouped).isEmpty)
        XCTAssertEqual(current.displayCount(filter: .ungrouped), 6)
        XCTAssertEqual(current.displayCount(filter: .all), 8)
    }

    func testUngroupedRespectsWorkspaceAndSearchIncludingMissingParents() {
        XCTAssertEqual(feed(workspace: "first").displayCount(filter: .ungrouped), 4)
        XCTAssertEqual(feed(workspace: "second").displayCount(filter: .ungrouped), 2)
        XCTAssertEqual(feed(workspace: "absent").displayCount(filter: .ungrouped), 0)
        XCTAssertEqual(feed().matching(query: "orphan", filter: .ungrouped).map(\.id), ["event:orphan"])
        XCTAssertEqual(feed().displayCount(query: "context", filter: .ungrouped), 0)
        XCTAssertEqual(feed().displayCount(query: "Alpha", filter: .ungrouped), 1,
                       "An evicted explicit parent stays ungrouped, even when a path could suggest a context")
    }

    func testUngroupedIncludesLiveAndRetainedProcessesWithoutSavedChangesOrGroups() {
        let order = reading(feed())
        XCTAssertTrue(order.groupIDs.isEmpty)
        XCTAssertTrue(order.contextIDs.isEmpty)
        XCTAssertTrue(order.childIDs.isEmpty)
        XCTAssertTrue(order.transactionIDs.isEmpty)
        XCTAssertEqual(Set(order.liveIDs), Set(["event:running", "job:live"]))
        XCTAssertEqual(Set(order.recentIDs), Set(["event:orphan", "event:unknown", "event:other"]))
        XCTAssertEqual(order.retainedIDs, ["job:done"])
    }

    func testUngroupedReadingSlotsSurviveNewActivityAndKeepFreshState() throws {
        let initial = feed()
        let held = reading(initial)
        var updated = history
        updated.insert(call("newer", running: true), at: 0)
        let next = feed(updated)
        XCTAssertEqual(held.recentIDs, reading(initial).recentIDs)
        XCTAssertFalse(held.liveIDs.contains("event:newer"))
        XCTAssertTrue(reading(next).liveIDs.contains("event:newer"))
        XCTAssertEqual(next.displayCount(filter: .ungrouped), 7)
        XCTAssertTrue(held.matches(owner: "fixture-owner", workspace: "all", query: "", filter: .ungrouped))
        XCTAssertFalse(held.matches(owner: "fixture-owner", workspace: "all", query: "", filter: .all))
        let offline = feed(connected: false)
        let item = try XCTUnwrap(offline.items.first { $0.id == "job:live" })
        XCTAssertFalse(item.presentation.running)
        XCTAssertEqual(offline.displayCount(filter: .ungrouped), 6)
    }

    func testEmptyCopyDescribesOnlyUngroupedAndDoesNotClaimNoWork() {
        let empty = feed(workspace: "absent")
        XCTAssertEqual(empty.emptyMessage(filter: .ungrouped, query: ""),
                       "No ungrouped activity in the retained history for this workspace.")
        XCTAssertEqual(empty.emptyMessage(filter: .ungrouped, query: "missing"),
                       "No ungrouped activity matches this search in the selected workspace.")
    }
}
