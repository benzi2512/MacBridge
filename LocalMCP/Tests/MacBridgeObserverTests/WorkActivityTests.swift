import XCTest
@testable import MacBridgeObserver

/// Synthetic, bounded observer snapshots; no process, network or owner access.
final class WorkActivityTests: XCTestCase {
    private func work(_ id: String = "w1", state: String = "active", phase: String = "waiting_next_step",
                      jobs: [String] = []) -> [String: Any] {
        ["work_id": id, "title": "Repair plugin", "chat_label": "Plugin check", "workspace_id": "a",
         "state": state, "phase": phase, "started_ms": 1000, "updated_ms": 2000, "call_count": 65,
         "error_count": 0, "active_call_count": 0, "job_ids": jobs, "stale": false]
    }
    private func call(_ id: String = "call1", workID: String? = "w1", state: String = "returned") -> [String: Any] {
        var row: [String: Any] = ["id": id, "tool": "file_read", "workspace_id": "a", "path": "Sources/Plugin.swift",
                                 "state": state, "started_ms": 1100, "finished_ms": 1150]
        row["work_id"] = workID
        return row
    }
    private func feed(works: [[String: Any]], history: [[String: Any]] = [], jobs: [[String: Any]] = [],
                      workspace: String = "all", connected: Bool = true, stale: Bool = false) -> ActivityFeed {
        ActivityFeed(history: history, jobs: jobs, workItems: works,
                     workspaces: [["workspace_id": "a", "display_name": "App"], ["workspace_id": "b", "display_name": "Other"]],
                     workspace: workspace, connected: connected, stale: stale)
    }

    func testParentRemainsActiveAfterShortCallReturnsAndAfterHistoryEviction() throws {
        for history in [[call()], []] {
            let current = feed(works: [work()], history: history)
            let parent = try XCTUnwrap(current.matchingGroups(filter: .running).first)
            XCTAssertEqual(current.displayCount(filter: .running), 1)
            XCTAssertEqual(parent.status, "Waiting for the next step")
            XCTAssertTrue(parent.active)
            XCTAssertFalse(parent.executing)
            XCTAssertEqual(parent.callCount, 65)
            XCTAssertTrue(parent.explanation.contains("no process is implied"))
            XCTAssertTrue(current.matchingUngrouped().isEmpty)
        }
    }

    func testMultipleParentsGroupOnlyExplicitIDsAndDoNotDuplicateJobsOrReceipts() throws {
        var start = call("start"); start["tool"] = "command_start"
        start["result"] = ["task_id": "job1", "running": true]
        let job: [String: Any] = ["task_id": "job1", "workspace_id": "a", "running": true]
        let current = feed(works: [work(jobs: ["job1"]), work("w2")],
                           history: [start, call("second", workID: "w2"), call("legacy", workID: nil)], jobs: [job])
        let first = try XCTUnwrap(current.groups.first { $0.workID == "w1" })
        XCTAssertEqual(first.visibleChildren.map(\.id), ["job:job1"])
        XCTAssertEqual(current.groups.first { $0.workID == "w2" }?.visibleChildren.map(\.id), ["event:second"])
        XCTAssertEqual(current.matchingUngrouped().map(\.id), ["event:legacy"])
        XCTAssertEqual(current.displayCount(), 3)
    }

    func testJobAssociationSurvivesReceiptDropAndIgnoresLaterStatusCaller() throws {
        var poll = call("poll", workID: "w2")
        poll["tool"] = "process_status"; poll["task_id"] = "job1"
        let current = feed(works: [work(jobs: ["job1"]), work("w2")], history: [poll],
                           jobs: [["task_id": "job1", "running": true]], workspace: "a")
        XCTAssertEqual(current.groups.first { $0.workID == "w1" }?.visibleChildren.map(\.id), ["job:job1"])
        XCTAssertEqual(current.groups.first { $0.workID == "w2" }?.visibleChildren.map(\.id), ["event:poll"])
        XCTAssertTrue(current.matchingUngrouped().isEmpty)
    }

    func testSearchAndWorkspaceFilterParentAndChildrenWithoutGuessingIdentity() {
        let current = feed(works: [work()], history: [call(), call("legacy", workID: nil)])
        XCTAssertEqual(current.matchingGroups(query: "Plugin check").count, 1)
        XCTAssertEqual(current.matchingGroups(query: "Sources/Plugin.swift").count, 1)
        XCTAssertTrue(current.matchingGroups(query: "missing").isEmpty)
        XCTAssertEqual(current.matchingUngrouped(query: "Plugin.swift").map(\.id), ["event:legacy"])
        XCTAssertTrue(feed(works: [work()], history: [call()], workspace: "b").groups.isEmpty)
        XCTAssertEqual(feed(works: [work()], history: [], workspace: "a").groups.count, 1)
        XCTAssertTrue(feed(works: [], history: [call(workID: nil)]).groups.isEmpty)
    }

    func testProcessReceiptInheritsOnlyItsExplicitParentWorkspace() throws {
        var poll = call("poll")
        poll.removeValue(forKey: "workspace_id")
        poll.removeValue(forKey: "path")
        poll["tool"] = "process_output"; poll["task_id"] = "job1"
        poll["state"] = "failed"; poll["result"] = ["error": "fixture output error"]
        let scoped = feed(works: [work(jobs: ["job1"])], history: [poll], workspace: "a")
        XCTAssertEqual(scoped.groups.first?.visibleChildren.map(\.id), ["event:poll"])
        XCTAssertEqual(scoped.items.first?.workspaceName, "App")
        XCTAssertEqual(scoped.matchingGroups(filter: .issues).count, 1)
        XCTAssertTrue(feed(works: [work()], history: [poll], workspace: "b").items.isEmpty)
        poll.removeValue(forKey: "work_id")
        XCTAssertTrue(feed(works: [work()], history: [poll], workspace: "a").items.isEmpty)
        XCTAssertEqual(feed(works: [work()], history: [poll]).matchingUngrouped().map(\.id), ["event:poll"])
    }

    func testWaitingUserStaleDisconnectedAndTerminalHaveHonestStates() throws {
        var overdue = work(phase: "executing"); overdue["stale"] = true
        let parent = try XCTUnwrap(feed(works: [overdue]).groups.first)
        XCTAssertTrue(parent.active)
        XCTAssertFalse(parent.executing)
        XCTAssertTrue(parent.status.contains("Update overdue"))
        XCTAssertTrue(parent.issue)
        let offline = try XCTUnwrap(feed(works: [work()], connected: false).groups.first)
        XCTAssertTrue(offline.active)
        XCTAssertFalse(offline.executing)
        XCTAssertTrue(offline.status.contains("Offline"))
        XCTAssertTrue(offline.explanation.contains("cannot be confirmed"))
        XCTAssertEqual(feed(works: [work(state: "waiting_user", phase: "waiting_user")]).displayCount(filter: .running), 1)
        for state in ["completed", "failed"] {
            let done = feed(works: [work(state: state, phase: state)])
            XCTAssertEqual(done.displayCount(filter: .running), 0)
            XCTAssertEqual(done.displayCount(), 1)
            for unavailable in [feed(works: [work(state: state, phase: state)], connected: false),
                                feed(works: [work(state: state, phase: state)], stale: true)] {
                let terminal = try XCTUnwrap(unavailable.groups.first)
                XCTAssertFalse(terminal.explanation.contains("has not been marked complete"))
                XCTAssertTrue(terminal.explanation.contains("finished task status"))
                XCTAssertFalse(terminal.active)
            }
        }
    }

    func testSafeDetailIsConcreteButRequestedEditsDoNotClaimAppliedChanges() throws {
        var event = call()
        event["tool"] = "command_run"
        event["detail"] = ["command_preview": "swift test --filter Observer", "targets": ["Sources/Plugin.swift"],
                           "edit_count": 2, "edit_count_scope": "requested", "start_line": 10, "maximum_lines": 20]
        event["arguments"] = ["DO_NOT_DISPLAY"]
        event["result"] = ["mutation_performed": false, "edits_applied": 2]
        let item = try XCTUnwrap(feed(works: [], history: [event]).items.first)
        XCTAssertTrue(item.title.contains("swift test --filter Observer"))
        XCTAssertTrue(item.matches(query: "swift Observer", filter: .all))
        XCTAssertFalse(item.matches(query: "DO_NOT_DISPLAY", filter: .all))
        var fields = DetailPresentation.fields(event, kind: .event)
        XCTAssertEqual(fields.first { $0.label == "Requested edits" }?.value, "2 · not an applied-change count")
        XCTAssertNil(fields.first { $0.label == "Applied edits" })
        event["result"] = ["mutation_performed": true, "edits_applied": 2]
        fields = DetailPresentation.fields(event, kind: .event)
        XCTAssertEqual(fields.first { $0.label == "Applied edits" }?.value, "2")
    }

    @MainActor
    func testSelectingParentNeverSelectsJobOrTransactionOrCarriesOldOutput() throws {
        let model = ObserverModel()
        model.connected = true
        model.updateSnapshot(["work_items": [work(jobs: ["job1"])], "history": [call()],
                              "jobs": [["task_id": "job1", "running": true]],
                              "transactions": [["transaction_id": "undo1"]], "snapshot_stale": false])
        model.selection = "job:job1"
        model.detailResult = ["stdout": "OLD OUTPUT"]
        model.selection = "work:w1"
        XCTAssertNotNil(model.selectedWork)
        XCTAssertNil(model.selectedJob)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertTrue(model.detailResult.isEmpty)
        XCTAssertTrue(model.activitySummary.contains("1 active task"))
        model.updateSnapshot(["work_items": [work()], "history": [], "jobs": [], "snapshot_stale": false])
        XCTAssertEqual(model.selectedWork?.workID, "w1")
    }

    @MainActor
    func testGroupedProcessReceiptSelectionUsesInheritedWorkspaceScope() throws {
        var poll = call("poll")
        poll.removeValue(forKey: "workspace_id")
        poll["tool"] = "process_output"; poll["task_id"] = "job1"
        let model = ObserverModel()
        model.connected = true
        model.updateSnapshot(["work_items": [work()], "history": [poll], "jobs": [], "snapshot_stale": false])
        model.workspace = "a"; model.selection = "event:poll"
        XCTAssertEqual(model.selectedActivity?.id, "event:poll")
        XCTAssertEqual(model.history.first?["id"] as? String, "poll")
        XCTAssertEqual(model.selectedActivityWork?.workID, "w1")
        model.workspace = "b"
        XCTAssertNil(model.selectedActivity)
        XCTAssertTrue(model.history.isEmpty)
    }
}
