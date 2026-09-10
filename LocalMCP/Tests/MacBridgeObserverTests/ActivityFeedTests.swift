import XCTest
@testable import MacBridgeObserver

// Synthetic receipts only: no runtime, window, process or network access.
final class ActivityFeedTests: XCTestCase {
    private let start: [String: Any] = ["id": "start", "tool": "command_start", "state": "returned",
        "workspace_id": "a", "cwd": "/fixtures/App/LocalMCP", "started_ms": 1000, "finished_ms": 1010,
        "result": ["task_id": "job-a", "running": true]]
    private let active: [String: Any] = ["task_id": "job-a", "running": true,
        "started_milliseconds": 1005, "stdout_total_bytes": 128, "stderr_total_bytes": 0]

    private func feed(history: [[String: Any]]? = nil, jobs: [[String: Any]]? = nil,
                      workspace: String = "all", connected: Bool = true, stale: Bool = false) -> ActivityFeed {
        ActivityFeed(history: history ?? [start], jobs: jobs ?? [active],
            workspaces: [["workspace_id": "a", "display_name": "App"], ["workspace_id": "b", "display_name": "Other"]],
            workspace: workspace, connected: connected, stale: stale)
    }

    func testRunningIncludesBackgroundJobAfterStartToolReturned() {
        let items = feed().matching(filter: .running)
        XCTAssertEqual(items.map(\.id), ["job:job-a"])
        XCTAssertEqual(items.first?.title, "Background command · LocalMCP")
        XCTAssertEqual(items.first?.workspaceName, "App")
        XCTAssertTrue(items.first!.presentation.subtitle.hasPrefix("Running now"))
        XCTAssertTrue(items.first!.explanation.contains("does not retain the command"))
        XCTAssertEqual(feed().runningCount, 1)
    }

    func testCompletedJobDoesNotStayRunningFromOldStartReceipt() {
        let done: [String: Any] = ["task_id": "job-a", "running": false, "exit_code": 0,
                                  "started_milliseconds": 1005, "ended_milliseconds": 2000]
        XCTAssertTrue(feed(jobs: [done]).matching(filter: .running).isEmpty)
        XCTAssertTrue(feed(jobs: [done]).matching(filter: .issues).isEmpty)
        XCTAssertTrue(feed(jobs: [done]).items[0].presentation.subtitle.contains("Exited · 0"))
        XCTAssertNotNil(feed(jobs: [done]).items[0].finished)
        XCTAssertTrue(feed(jobs: []).matching(filter: .running).isEmpty)
    }

    func testBusyHistoryIsCurrentButCachedJobsAreNot() {
        let call: [String: Any] = ["id": "sync", "tool": "file_search", "state": "running", "workspace_id": "a"]
        let busy = feed(history: [call, start], stale: true)
        XCTAssertEqual(busy.matching(filter: .running).map(\.id), ["event:sync"])
        XCTAssertEqual(busy.matching(filter: .issues).map(\.id), ["job:job-a"])
        XCTAssertTrue(busy.items[0].presentation.subtitle.contains("not current"))
    }

    func testDisconnectedNeverClaimsWorkStoppedOrStillRunning() {
        let offline = feed(connected: false)
        XCTAssertEqual(offline.runningCount, 0)
        XCTAssertTrue(offline.emptyMessage(filter: .running, query: "").contains("do not assume"))
        XCTAssertFalse(offline.items[0].presentation.running)
    }

    func testWorkspaceUsesStartingReceiptNotLaterPollOrGuessedPath() {
        let poll: [String: Any] = ["id": "poll", "tool": "process_status", "state": "returned",
                                  "workspace_id": "b", "task_id": "job-a", "result": ["running": true]]
        XCTAssertEqual(feed(history: [poll, start], workspace: "a").matching(filter: .running).map(\.id), ["job:job-a"])
        XCTAssertTrue(feed(history: [poll, start], workspace: "b").matching(filter: .running).isEmpty)
        XCTAssertTrue(feed(history: [], workspace: "a").matching(filter: .running).isEmpty)
        let orphan = feed(history: []).matching(filter: .running)[0]
        XCTAssertEqual(orphan.workspaceName, "Workspace not retained")
        XCTAssertTrue(orphan.explanation.contains("no longer"))
        XCTAssertFalse(orphan.title.contains("App"))
    }

    func testSearchMatchesJobContextButNeverOutputOrSecretArguments() {
        var unsafe = start
        unsafe["arguments"] = ["SECRET_ARGUMENT"]
        unsafe["content"] = "SECRET_CONTENT"
        unsafe["result"] = ["task_id": "job-a", "running": true, "stdout": "SECRET_OUTPUT"]
        let items = feed(history: [unsafe])
        XCTAssertEqual(items.matching(query: "App LocalMCP", filter: .running).count, 1)
        for text in ["SECRET_ARGUMENT", "SECRET_CONTENT", "SECRET_OUTPUT"] {
            XCTAssertTrue(items.matching(query: text).isEmpty)
            XCTAssertFalse(items.items[0].explanation.contains(text))
        }
    }

    func testDescriptionsShowFileAndRepositoryTargets() {
        let read: [String: Any] = ["id": "read", "tool": "file_read", "state": "returned",
                                  "workspace_id": "a", "path": "Sources/Café.swift"]
        let git: [String: Any] = ["id": "git", "tool": "git_status", "state": "returned", "cwd": "/fixtures/App"]
        let rows = feed(history: [read, git], jobs: []).items
        XCTAssertEqual(rows[0].title, "Read a file · Café.swift")
        XCTAssertEqual(rows[0].presentation.subtitle, "Tool returned")
        XCTAssertEqual(rows[1].title, "Checked Git changes · App")
        XCTAssertTrue(rows[1].explanation.contains("untracked"))
        XCTAssertTrue(rows[0].matches(query: "café", filter: .all))
    }

    func testFailedCancelledAndUnknownJobsAreIssues() {
        for result: [String: Any] in [
            ["running": false, "exit_code": 2], ["running": false, "cancelled": true],
            ["running": false, "timed_out": true], ["running": false], [:],
        ] {
            var job = result; job["task_id"] = "job-a"
            XCTAssertEqual(feed(jobs: [job]).matching(filter: .issues).map(\.id), ["job:job-a"])
            XCTAssertTrue(feed(jobs: [job]).matching(filter: .running).isEmpty)
        }
    }

    func testShortCallsFinishAndEmptyStateExplainsChatMayStillWork() {
        let call: [String: Any] = ["id": "read", "tool": "file_read", "state": "running"]
        XCTAssertEqual(feed(history: [call], jobs: []).runningCount, 1)
        var done = call; done["state"] = "returned"
        let idle = feed(history: [done], jobs: [])
        XCTAssertTrue(idle.matching(filter: .running).isEmpty)
        XCTAssertTrue(idle.emptyMessage(filter: .running, query: "").contains("ChatGPT may still"))
        XCTAssertTrue(idle.emptyMessage(filter: .all, query: "missing").contains("Clear the search"))
    }

    @MainActor
    func testModelScopesSummaryAndSelectsJobContext() {
        let model = ObserverModel()
        model.connected = true
        model.updateSnapshot(["history": [start], "jobs": [active], "snapshot_stale": false])
        model.workspace = "a"
        model.selection = "job:job-a"
        XCTAssertEqual(model.selectedActivity?.subject, "/fixtures/App/LocalMCP")
        XCTAssertEqual(model.activitySummary, "1 in progress")
        model.workspace = "b"
        XCTAssertNil(model.selectedActivity)
        XCTAssertTrue(model.activitySummary.contains("No MB work running in this workspace"))
    }
}
