import XCTest
@testable import MacBridgeObserver

/// Synthetic retained receipts only. Context grouping never inspects disk or
/// treats a folder, supplied chat label or command text as a verified chat ID.
final class ContextActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func item(_ id: String, path: String? = nil, cwd: String? = nil,
                      tool: String = "file_read", workID: String? = nil,
                      targets: [String] = [], targetCount: Int? = nil,
                      milliseconds: Double = 990_000, running: Bool = false,
                      issue: Bool = false, workspace: String = "mac") -> ActivityItem {
        var raw: [String: Any] = ["id": id, "tool": tool, "state": running ? "running" : "returned",
                                  "started_ms": milliseconds, "workspace_id": workspace]
        raw["path"] = path; raw["cwd"] = cwd; raw["work_id"] = workID
        if !targets.isEmpty || targetCount != nil {
            raw["detail"] = ["targets": targets, "target_count": targetCount ?? targets.count]
        }
        return ActivityItem(id: "event:" + id, kind: .call, raw: raw, origin: raw,
            presentation: ActivityPresentation(title: "Read a file", subtitle: "Returned", icon: "doc",
                running: running, failed: issue, partial: false), workspaceID: workspace,
            workspaceName: "Mac", issue: issue)
    }
    private func groups(_ items: [ActivityItem], workspaces: [[String: Any]] = [],
                        connected: Bool = true, stale: Bool = false) -> [ContextActivity] {
        ContextActivity.make(items: items, workspaces: workspaces, connected: connected, stale: stale, now: now)
    }

    func testGenericProjectsAcrossInterleavedCallsAndSingleActivity() {
        let rows = [item("a", cwd: "/Users/example/Chat/Projects/Orchid/automation", tool: "command_run"),
                    item("b", path: "/Users/example/repos/Birch/src/App.swift"),
                    item("c", path: "/Users/example/Chat/Projects/Orchid/receipts/latest.json"),
                    item("d", path: "/Users/example/plugins/Maple/plugin.json")]
        let contexts = groups(rows)
        XCTAssertEqual(Set(contexts.map(\.title)), Set(["Orchid", "Birch", "Maple"]))
        XCTAssertEqual(contexts.first { $0.title == "Orchid" }?.children.map(\.id), ["event:a", "event:c"])
        XCTAssertEqual(contexts.first { $0.title == "Birch" }?.children.count, 1)
        XCTAssertEqual(groups(Array(rows.reversed())).map(\.id), contexts.map(\.id))
        XCTAssertTrue(rows.allSatisfy { $0.workID == nil })
    }

    func testTwoChatsInOneFolderAreOneContextNotTwoInventedTasks() {
        let rows = [item("chat-a", path: "/fixtures/projects/Shared/a.swift"),
                    item("chat-b", path: "/fixtures/projects/Shared/b.swift")]
        let contexts = groups(rows)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].title, "Shared")
        XCTAssertTrue(contexts[0].id.hasPrefix("context:"))
        XCTAssertFalse(contexts[0].id.contains("chat-a"))
        XCTAssertEqual(contexts[0].children.count, 2)
        XCTAssertTrue(contexts[0].children.allSatisfy { $0.raw["work_id"] == nil && $0.origin["work_id"] == nil })
    }

    func testMostSpecificRegisteredRootAndPathComponentBoundary() {
        let workspaces: [[String: Any]] = [["root_path": "/"], ["root_path": "/Users/example"],
            ["root_path": "/fixtures/source"], ["root_path": "/fixtures/source/foo"],
            ["root_hash": "not-a-path", "display_name": "Never inferred"]]
        let contexts = groups([item("a", path: "/fixtures/source/foo/sub/file.swift"),
                               item("b", path: "/fixtures/source/foo2/file.swift")], workspaces: workspaces)
        XCTAssertEqual(Set(contexts.map(\.rootPath)), Set(["/fixtures/source/foo", "/fixtures/source"]))
        XCTAssertTrue(groups([item("home", cwd: "/Users/example", tool: "command_run")], workspaces: workspaces).isEmpty)
    }

    func testMultiTargetCrossRootAndUnretainedTargetsRemainUngrouped() {
        let same = item("same", tool: "file_read_many",
                        targets: ["/fixtures/Projects/A/one", "/fixtures/Projects/A/sub/two"])
        let cross = item("cross", tool: "file_read_many",
                         targets: ["/fixtures/Projects/A/one", "/fixtures/Projects/B/two"])
        let hidden = item("hidden", tool: "file_read_many", targets: ["/fixtures/Projects/A/one"], targetCount: 4)
        let disagreement = item("subject", path: "/fixtures/Projects/A/one", targets: ["/fixtures/Projects/B/two"])
        XCTAssertEqual(groups([same, cross, hidden, disagreement]).flatMap(\.children).map(\.id), ["event:same"])
    }

    func testUnknownTruncatedRelativeTraversalAndBroadPathsAreNotGuessed() {
        let invalid = ["relative/file.swift", "/fixtures/projects/A/../B/file", "/fixtures//file",
                       "/fixtures/./file", "/fixtures/Projects/A/file\nname", "/fixtures/Projects/A/file… [truncated]",
                       "[path omitted]", "/Users/example/file.txt", "/file.txt", "/fixtures/repos"]
        XCTAssertTrue(groups(invalid.enumerated().map { item(String($0.offset), path: $0.element) }).isEmpty)
        XCTAssertTrue(groups([item("cwd", cwd: "/Users/example", tool: "command_run")]).isEmpty)
        // No symlink resolution or disk access: an alias-looking path stays
        // lexical and never acquires the identity of some filesystem target.
        XCTAssertEqual(groups([item("link", path: "/fixtures/link/to/file.swift")])[0].rootPath, "/fixtures/link/to")
    }

    func testTrailingDirectorySlashKeepsStableIdentityWithoutRewritingInteriorPaths() {
        let normal = item("normal", cwd: "/fixtures/Projects/A", tool: "command_run")
        let trailing = item("trailing", cwd: "/fixtures/Projects/A/", tool: "command_run")
        XCTAssertEqual(groups([normal])[0].id, groups([trailing])[0].id)
        XCTAssertEqual(groups([normal])[0].id,
                       groups([item("slashes", cwd: "/fixtures/Projects/A///", tool: "command_run")])[0].id)
        XCTAssertEqual(groups([normal, trailing])[0].children.count, 2)
        let registered = groups([item("registered", path: "/fixtures/source/App/child/file.swift")],
                                workspaces: [["root_path": "/fixtures/source/App/"]])
        XCTAssertEqual(registered.first?.rootPath, "/fixtures/source/App")
        XCTAssertTrue(groups([item("double", cwd: "/fixtures//Projects/A/", tool: "command_run")]).isEmpty)
        XCTAssertTrue(groups([item("traversal", cwd: "/fixtures/Projects/A/../", tool: "command_run")]).isEmpty)
    }

    func testExplicitOwnershipAndWorkspaceScopesAreNeverRewritten() {
        let explicit = item("explicit", path: "/fixtures/Projects/A/file", workID: "declared-task")
        let implicit = item("implicit", path: "/fixtures/Projects/A/file")
        let separate = item("second", path: "/fixtures/Projects/A/file", workspace: "other")
        let contexts = groups([explicit, implicit, separate])
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(Set(contexts.flatMap(\.children).map(\.id)), Set(["event:implicit", "event:second"]))
        XCTAssertEqual(explicit.workID, "declared-task")
        XCTAssertEqual(explicit.raw["work_id"] as? String, "declared-task")
    }

    func testRecentRunningIdleOfflineAndStaleAreDistinct() {
        let path = "/fixtures/Projects/A/file"
        let recent = groups([item("recent", path: path)])[0]
        XCTAssertEqual(recent.status, "Recent"); XCTAssertTrue(recent.active); XCTAssertFalse(recent.executing)
        XCTAssertTrue(recent.matches(query: "A", filter: .running))
        let idle = groups([item("old", path: path, milliseconds: 879_999)])[0]
        XCTAssertEqual(idle.status, "Idle"); XCTAssertFalse(idle.active)
        XCTAssertFalse(groups([item("edge", path: path, milliseconds: 880_000)])[0].recent)
        XCTAssertTrue(groups([item("inside", path: path, milliseconds: 880_001)])[0].recent)
        XCTAssertFalse(idle.matches(query: "", filter: .running))
        let running = item("running", path: path, milliseconds: 100, running: true)
        XCTAssertEqual(groups([running])[0].status, "Running")
        XCTAssertTrue(groups([running], stale: true)[0].executing)
        let offline = groups([running], connected: false)[0]
        XCTAssertEqual(offline.status, "Offline"); XCTAssertFalse(offline.active)
        let stale = groups([item("stale", path: path)], stale: true)[0]
        XCTAssertEqual(stale.status, "Snapshot not current"); XCTAssertFalse(stale.active)
        XCTAssertFalse(groups([item("future", path: path, milliseconds: 1_100_000)])[0].recent)
    }

    func testStartReceiptDeduplicatesOnlyItsExactJobAndSearchUsesBoundedDetails() {
        var start = item("start", cwd: "/fixtures/Projects/A", tool: "command_start")
        var origin = start.origin
        origin["result"] = ["task_id": "job-a", "stdout": "SECRET_OUTPUT"]
        origin["arguments"] = ["SECRET_ARGUMENT"]
        start = ActivityItem(id: start.id, kind: .call, raw: origin, origin: origin, presentation: start.presentation,
                             workspaceID: start.workspaceID, workspaceName: start.workspaceName, issue: false)
        let job = ActivityItem(id: "job:job-a", kind: .job,
            raw: ["task_id": "job-a", "started_milliseconds": 991_000], origin: origin,
            presentation: start.presentation, workspaceID: start.workspaceID, workspaceName: start.workspaceName, issue: true)
        let context = groups([start, job])[0]
        XCTAssertEqual(context.visibleChildren.map(\.id), ["job:job-a"])
        XCTAssertEqual(context.currentAction?.id, "job:job-a")
        XCTAssertEqual(context.issueCount, 1)
        XCTAssertTrue(context.matches(query: "A", filter: .issues))
        XCTAssertFalse(context.matches(query: "SECRET_OUTPUT", filter: .all))
        XCTAssertFalse(context.matches(query: "SECRET_ARGUMENT", filter: .all))
    }

    func testInputBoundDoesNotAccumulateUnboundedContextHistory() {
        let rows = (0..<520).map { item(String($0), path: "/fixtures/Projects/Bounded/\($0).txt") }
        XCTAssertEqual(groups(rows)[0].children.count, 512)
    }

    func testPathlessPollUsesOnlyExactUnambiguousRetainedJob() {
        func replace(_ item: ActivityItem, with raw: [String: Any]) -> ActivityItem {
            ActivityItem(id: item.id, kind: item.kind, raw: raw, origin: raw, presentation: item.presentation,
                         workspaceID: item.workspaceID, workspaceName: item.workspaceName, issue: item.issue)
        }
        let base = item("start", cwd: "/fixtures/Projects/A", tool: "command_start")
        var start = base.raw; start["result"] = ["task_id": "job-a"]
        let poll = item("poll", tool: "process_output")
        var pollRaw = poll.raw; pollRaw["task_id"] = "job-a"
        let unknown = item("unknown", tool: "process_status")
        var unknownRaw = unknown.raw; unknownRaw["task_id"] = "job-unknown"
        let rows = [replace(poll, with: pollRaw), replace(base, with: start), replace(unknown, with: unknownRaw)]
        XCTAssertEqual(groups(rows)[0].children.map(\.id), ["event:poll", "event:start"])
        XCTAssertNil(groups(rows)[0].children[0].subject)
        XCTAssertNil(groups(rows)[0].children[0].workID)
        var conflicting = start; conflicting["id"] = "conflict"; conflicting["cwd"] = "/fixtures/Projects/B"
        XCTAssertFalse(groups(rows + [replace(item("conflict"), with: conflicting)]).flatMap(\.children).contains { $0.id == "event:poll" })
        XCTAssertTrue(groups([replace(poll, with: pollRaw)]).isEmpty)
        var contradictory = pollRaw; contradictory["detail"] = ["cwd": "[path omitted]"]
        XCTAssertFalse(groups([replace(base, with: start), replace(poll, with: contradictory)])
            .flatMap(\.children).contains { $0.id == "event:poll" })
    }
}
