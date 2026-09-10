import Combine
import XCTest
@testable import MacBridgeObserver

/// Synthetic observer snapshots only. Context grouping is a presentation aid,
/// not chat identity, ownership, or permission to act on a parent row.
final class ContextFeedIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_001)
    private let workspaces: [[String: Any]] = [
        ["workspace_id": "mac", "display_name": "Mac", "root_path": "/fixtures"]
    ]

    private func call(_ id: String, project: String, relativePath: String = "src/main.swift",
                      started: Int = 1_000_000, workID: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "tool": "file_read", "state": "returned", "workspace_id": "mac",
            "path": "/fixtures/Projects/\(project)/\(relativePath)",
            "started_ms": started, "finished_ms": started + 1,
            "result": ["text": "synthetic file preview"]
        ]
        value["work_id"] = workID
        return value
    }

    private func feed(_ history: [[String: Any]], workItems: [[String: Any]] = [],
                      jobs: [[String: Any]] = [], at date: Date? = nil) -> ActivityFeed {
        ActivityFeed(history: history, jobs: jobs, workItems: workItems, workspaces: workspaces,
                     workspace: "all", connected: true, stale: false, now: date ?? now)
    }

    private func reading(_ feed: ActivityFeed) -> ActivityReadingOrder {
        ActivityReadingOrder(feed: feed, transactions: [], owner: "owner", workspace: "all", query: "", filter: .all)
    }

    private func snapshot(_ history: [[String: Any]]) -> [String: Any] {
        ["instance_id": "owner", "jobs": [], "work_items": [], "transactions": [],
         "workspaces": workspaces, "history": history, "snapshot_stale": false,
         "observer_file_preview": true, "snapshot_ms": 1_001_000]
    }

    func testInterleavedProjectsFormSeparateContextRowsWithoutLosingRawItems() throws {
        let rows = [call("a2", project: "Alpha", started: 1_000_900),
                    call("b2", project: "Beta", started: 1_000_800),
                    call("a1", project: "Alpha", started: 1_000_700),
                    call("b1", project: "Beta", started: 1_000_600)]
        let current = feed(rows)
        let held = reading(current)
        XCTAssertEqual(current.contextGroups.count, 2)
        XCTAssertEqual(current.displayCount(), 2, "Four calls are presented beneath two context rows")
        XCTAssertTrue(current.groups.isEmpty, "An inferred context is not an explicit task")
        XCTAssertTrue(current.matchingUngrouped().isEmpty)
        XCTAssertEqual(current.items.count, rows.count)
        let children = held.contextIDs.compactMap { held.childIDs[$0] }.map(Set.init)
        XCTAssertTrue(children.contains(Set(["event:a1", "event:a2"])))
        XCTAssertTrue(children.contains(Set(["event:b1", "event:b2"])))
        for row in rows {
            let item = try XCTUnwrap(current.items.first { $0.id == "event:" + (row["id"] as! String) })
            XCTAssertTrue(NSDictionary(dictionary: item.raw).isEqual(to: row))
            XCTAssertTrue(NSDictionary(dictionary: item.origin).isEqual(to: row))
            XCTAssertNil(item.workID)
        }
    }

    func testDifferentFoldersInOneProjectShareOneContextButNotAChatIdentity() throws {
        var command = call("command", project: "Alpha")
        command["tool"] = "command_run"
        command.removeValue(forKey: "path")
        command["cwd"] = "/fixtures/Projects/Alpha/automation/dedicated"
        command["detail"] = ["command_preview": "swift test --filter Synthetic"]
        let current = feed([command,
                            call("source", project: "Alpha", relativePath: "Sources/main.swift"),
                            call("receipt", project: "Alpha", relativePath: "outputs/receipts/check.json")])
        let parent = try XCTUnwrap(current.contextGroups.first)
        XCTAssertEqual(current.contextGroups.count, 1)
        XCTAssertEqual(Set(reading(current).childIDs[parent.id] ?? []),
                       Set(["event:command", "event:source", "event:receipt"]))
        XCTAssertEqual(current.matchingContexts(query: "Alpha").count, 1)
        XCTAssertEqual(current.matchingContexts(query: "swift Synthetic").count, 1)
        XCTAssertEqual(current.matchingContexts(query: "receipts/check.json").count, 1)
        XCTAssertTrue(current.matchingContexts(query: "Another chat name").isEmpty)
        XCTAssertTrue(current.items.allSatisfy { $0.workID == nil })
    }

    func testExplicitWorkIsNeverMergedIntoInferredContextOrAssignedToItsOtherCalls() throws {
        let work: [String: Any] = ["work_id": "explicit", "title": "Synthetic task", "workspace_id": "mac",
                                   "state": "active", "phase": "waiting_next_step", "updated_ms": 1_000_800]
        let current = feed([call("explicit", project: "Alpha", workID: "explicit"),
                            call("unlabelled", project: "Alpha"),
                            call("orphan", project: "Alpha", workID: "owner-task-not-retained")], workItems: [work])
        XCTAssertEqual(current.groups.count, 1)
        XCTAssertEqual(current.groups.first?.visibleChildren.map(\.id), ["event:explicit"])
        XCTAssertEqual(current.contextGroups.count, 1)
        let inferred = try XCTUnwrap(current.contextGroups.first)
        XCTAssertEqual(reading(current).childIDs[inferred.id], ["event:unlabelled"])
        XCTAssertEqual(current.matchingUngrouped().map(\.id), ["event:orphan"],
                       "An explicit work ID remains authoritative even after its parent is evicted")
        XCTAssertNil(current.items.first { $0.id == "event:unlabelled" }?.workID)
        XCTAssertEqual(current.items.first { $0.id == "event:orphan" }?.workID, "owner-task-not-retained")
        XCTAssertEqual(current.displayCount(), 3)
    }

    @MainActor
    func testSelectingContextNeverGrantsJobTransactionOrPreviewControls() throws {
        let model = ObserverModel()
        model.connected = true
        var state = snapshot([call("read", project: "Alpha")])
        state["jobs"] = [["task_id": "job", "running": true, "workspace_id": "mac"]]
        state["transactions"] = [["transaction_id": "undo", "workspace_id": "mac"]]
        model.updateSnapshot(state, now: now)
        let contextID = try XCTUnwrap(model.activityFeed.contextGroups.first?.id)
        model.selection = "job:job"
        model.detailResult = ["stdout": "OLD OUTPUT"]
        model.selection = contextID
        XCTAssertEqual(model.selectedContext?.id, contextID)
        XCTAssertNil(model.selectedActivity)
        XCTAssertNil(model.selectedActivityContext)
        XCTAssertNil(model.selectedWork)
        XCTAssertNil(model.selectedJob)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertNil(model.selectedPreviewEventID)
        XCTAssertFalse(model.canOpenPreview)
        XCTAssertTrue(model.detailResult.isEmpty, "A context must not carry controls or output from the previous selection")
    }

    @MainActor
    func testContextChildKeepsItsExactReceiptPathAndPreviewEligibility() throws {
        let model = ObserverModel()
        model.connected = true
        let row = call("read", project: "Alpha", relativePath: "Sources/File.swift")
        model.updateSnapshot(snapshot([row]), now: now)
        let contextID = try XCTUnwrap(model.activityFeed.contextGroups.first?.id)
        model.selection = "event:read"
        let child = try XCTUnwrap(model.selectedActivity)
        XCTAssertEqual(child.subject, "/fixtures/Projects/Alpha/Sources/File.swift")
        XCTAssertTrue(NSDictionary(dictionary: child.raw).isEqual(to: row))
        XCTAssertTrue(NSDictionary(dictionary: child.origin).isEqual(to: row))
        XCTAssertEqual(model.selectedActivityContext?.id, contextID)
        XCTAssertEqual(model.selectedPreviewEventID, "read")
        XCTAssertNil(model.selectedContext)
        XCTAssertNil(model.selectedWork)
        XCTAssertNil(model.selectedJob)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertEqual(model.history.first?["id"] as? String, "read")
    }

    func testReadingContextOrderAndChildrenStayFixedWhenAnotherContextRises() throws {
        let initial = feed([call("a1", project: "Alpha", started: 1_000_800),
                            call("b1", project: "Beta", started: 1_000_700)])
        let held = reading(initial)
        let originalContextIDs = held.contextIDs
        let updated = feed([call("c1", project: "Gamma", started: 1_000_950),
                            call("b2", project: "Beta", started: 1_000_900),
                            call("a1", project: "Alpha", started: 1_000_800),
                            call("b1", project: "Beta", started: 1_000_700)])
        let latest = reading(updated)
        XCTAssertEqual(held.contextIDs, originalContextIDs)
        XCTAssertEqual(held.contextIDs.count, 2)
        XCTAssertEqual(latest.contextIDs.count, 3)
        let betaID = try XCTUnwrap(held.contextIDs.first { held.childIDs[$0] == ["event:b1"] })
        XCTAssertEqual(held.childIDs[betaID], ["event:b1"], "New child rows must not push the reader down")
        XCTAssertEqual(latest.childIDs[betaID], ["event:b2", "event:b1"], "Show latest captures new children")
        XCTAssertEqual(updated.displayCount(), 3, "Fresh counts are independent of held reading positions")
    }

    @MainActor
    func testRecentContextExpiresOnExistingClockRefreshWithoutContinuousRedrawOrFakeCompletion() throws {
        let model = ObserverModel()
        model.connected = true
        let lastActivity = Date(timeIntervalSince1970: 1_000)
        var state = snapshot([call("read", project: "Alpha", started: 999_999)])
        model.updateSnapshot(state, now: lastActivity)
        let contextID = try XCTUnwrap(model.activityFeed.contextGroups.first?.id)
        XCTAssertEqual(model.activityFeed.matchingContexts(filter: .running).map(\.id), [contextID])
        XCTAssertEqual(model.activityFeed.runningCount, 0, "Recent context activity does not mean a process is running")
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for seconds in [1.0, 30.0, 60.0, 119.0] {
            state["snapshot_ms"] = Int((lastActivity.timeIntervalSince1970 + seconds) * 1_000)
            model.updateSnapshot(state, now: lastActivity.addingTimeInterval(seconds))
        }
        XCTAssertEqual(changes, 0, "Clock metadata alone must not redraw unchanged context state")
        XCTAssertEqual(model.activityFeed.matchingContexts(filter: .running).map(\.id), [contextID])
        model.updateSnapshot(state, now: lastActivity.addingTimeInterval(120))
        XCTAssertEqual(changes, 1, "Only the visible Recent-to-Inactive boundary should publish")
        XCTAssertTrue(model.activityFeed.matchingContexts(filter: .running).isEmpty)
        XCTAssertEqual(model.activityFeed.matchingContexts().map(\.id), [contextID], "Expiry retains history in All")
        XCTAssertEqual(model.activityFeed.displayCount(), 1)
        XCTAssertEqual(model.activityFeed.displayCount(filter: .running), 0)
        XCTAssertTrue(model.workItems.isEmpty, "A presentation timeout must not synthesize a completed task")
        XCTAssertEqual(model.activityFeed.items.first?.raw["state"] as? String, "returned")
        model.updateSnapshot(state, now: lastActivity.addingTimeInterval(121))
        model.updateSnapshot(state, now: lastActivity.addingTimeInterval(180))
        XCTAssertEqual(changes, 1, "Inactive contexts must not cause continued clock-only redraws")
    }

    @MainActor
    func testWorkspaceSwitchKeepsHiddenContextExpiryScheduledAcrossClockOnlyRefresh() throws {
        let model = ObserverModel()
        model.connected = true
        model.workspace = "empty"
        let lastActivity = Date(timeIntervalSince1970: 1_000)
        var row = call("read", project: "Alpha", started: 999_999)
        row["workspace_id"] = "hidden"
        var state = snapshot([row])
        state["workspaces"] = [
            ["workspace_id": "empty", "display_name": "Empty workspace"],
            ["workspace_id": "hidden", "display_name": "Hidden workspace"]
        ]
        model.updateSnapshot(state, now: lastActivity)
        XCTAssertTrue(model.activityFeed.contextGroups.isEmpty)
        model.workspace = "hidden"
        let contextID = try XCTUnwrap(model.activityFeed.contextGroups.first?.id)
        XCTAssertEqual(model.activityFeed.matchingContexts(filter: .running).map(\.id), [contextID])
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        state["snapshot_ms"] = 1_119_000
        model.updateSnapshot(state, now: lastActivity.addingTimeInterval(119))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.activityFeed.matchingContexts(filter: .running).map(\.id), [contextID])
        state["snapshot_ms"] = 1_120_000
        model.updateSnapshot(state, now: lastActivity.addingTimeInterval(120))
        XCTAssertEqual(changes, 1, "A context hidden during the initial snapshot must still publish its expiry after switching scope")
        XCTAssertTrue(model.activityFeed.matchingContexts(filter: .running).isEmpty)
        XCTAssertEqual(model.activityFeed.matchingContexts().map(\.id), [contextID])
        XCTAssertEqual(model.activityFeed.contextGroups.first?.status, "Idle")
        model.updateSnapshot(state, now: lastActivity.addingTimeInterval(121))
        XCTAssertEqual(changes, 1)
    }
}
