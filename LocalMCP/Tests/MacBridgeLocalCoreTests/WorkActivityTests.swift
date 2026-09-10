import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class WorkActivityTests: XCTestCase {
    private func begin(_ store: WorkActivity, title: String = "Audit", workspace: String? = nil,
                       now: Int64 = 1_000) throws -> String {
        var arguments: JSONObject = ["action": "begin", "title": title, "chat_label": "Declared chat"]
        if let workspace { arguments["workspace_id"] = workspace }
        let result = try store.manage(arguments, validWorkspaces: Set([workspace].compactMap { $0 }), jobs: [], now: now)
        return try XCTUnwrap(result["work_id"] as? String)
    }

    func testLifecycleKeepsParentBetweenCallsAndExplicitlyFinishes() throws {
        let store = WorkActivity(), id = try begin(store)
        XCTAssertEqual(store.list(jobs: [])[0]["phase"] as? String, "waiting_next_step")
        let admitted = try store.beginCall(name: "file_read", arguments: ["work_id": id], now: 1_001)
        XCTAssertEqual(admitted, id)
        XCTAssertEqual(store.list(jobs: [])[0]["phase"] as? String, "executing")
        XCTAssertThrowsError(try store.manage(["action": "finish", "work_id": id], validWorkspaces: [], jobs: []))
        store.finishCall(id, name: "file_read", result: [:], failed: false, now: 1_002)
        let after = store.list(jobs: [], now: 1_003)[0]
        XCTAssertEqual(after["phase"] as? String, "waiting_next_step")
        XCTAssertEqual(after["state"] as? String, "active")
        XCTAssertEqual(after["call_count"] as? Int, 1)
        XCTAssertEqual(after["active_call_count"] as? Int, 0)
        XCTAssertEqual(try store.manage(["action": "update", "work_id": id, "status": "waiting_user"], validWorkspaces: [], jobs: [])["phase"] as? String, "waiting_user")
        XCTAssertThrowsError(try store.beginCall(name: "file_write", arguments: ["work_id": id]))
        _ = try store.manage(["action": "update", "work_id": id, "status": "active"], validWorkspaces: [], jobs: [])
        XCTAssertEqual(try store.manage(["action": "finish", "work_id": id], validWorkspaces: [], jobs: [])["phase"] as? String, "completed")
        XCTAssertThrowsError(try store.beginCall(name: "file_write", arguments: ["work_id": id]))
    }

    func testSeparateParentsAndOriginalJobOwnershipArePreserved() throws {
        let store = WorkActivity(), a = try begin(store, title: "A"), b = try begin(store, title: "B")
        let job = UUID().uuidString.lowercased()
        _ = try store.beginCall(name: "command_start", arguments: ["work_id": a])
        store.finishCall(a, name: "command_start", result: ["task_id": job, "running": true], failed: false)
        let jobs: [JSONObject] = [["task_id": job, "running": true]]
        XCTAssertEqual(store.list(jobs: jobs)[0]["phase"] as? String, "executing")
        XCTAssertEqual(store.list(jobs: jobs)[1]["phase"] as? String, "waiting_next_step")
        XCTAssertThrowsError(try store.manage(["action": "finish", "work_id": a], validWorkspaces: [], jobs: jobs))
        XCTAssertThrowsError(try store.beginCall(name: "process_cancel", arguments: ["task_id": job, "work_id": b]))
        XCTAssertThrowsError(try store.beginCall(name: "process_status_many", arguments: ["task_ids": [job], "work_id": b]))
        XCTAssertThrowsError(try store.beginCall(name: "process_output_many", arguments: ["jobs": [["task_id": job]], "work_id": b]))
        XCTAssertEqual(try store.beginCall(name: "process_status", arguments: ["task_id": job]), a)
        store.finishCall(a, name: "process_status", result: ["task_id": job, "running": false], failed: false)
        _ = try store.manage(["action": "finish", "work_id": a], validWorkspaces: [], jobs: [])
        // Finishing a parent does not deny read/drain of its completed job.
        XCTAssertEqual(try store.beginCall(name: "process_output", arguments: ["task_id": job]), a)
        store.finishCall(a, name: "process_output", result: ["task_id": job, "running": false], failed: false)
        XCTAssertEqual(store.list(jobs: [])[0]["state"] as? String, "completed")
        XCTAssertEqual(store.list(jobs: [])[1]["call_count"] as? Int, 0)
    }

    func testFailedJobIsCountedOnceAcrossReadsAfterParentFinishes() throws {
        let store = WorkActivity(), id = try begin(store), job = UUID().uuidString.lowercased()
        let stopped: JSONObject = ["task_id": job, "running": false, "exit_code": 7]
        _ = try store.beginCall(name: "command_run", arguments: ["work_id": id])
        store.finishCall(id, name: "command_run", result: stopped, failed: false)
        _ = try store.manage(["action": "finish", "work_id": id, "status": "failed"], validWorkspaces: [], jobs: [])
        for name in ["process_status", "process_output", "process_wait", "process_output_tail"] {
            let inherited = try store.beginCall(name: name, arguments: ["task_id": job.uppercased()])
            XCTAssertEqual(inherited, id)
            store.finishCall(inherited, name: name, result: stopped, failed: false)
            XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 1, name)
        }
        let parent = store.list(jobs: nil)[0]
        XCTAssertEqual(parent["state"] as? String, "failed")
        XCTAssertEqual(parent["call_count"] as? Int, 5)
        XCTAssertEqual(parent["active_call_count"] as? Int, 0)
    }

    func testBatchCountsDistinctFailedJobsNotRepeatedPolls() throws {
        let store = WorkActivity(), id = try begin(store)
        let jobs = (0..<2).map { _ in UUID().uuidString.lowercased() }
        for job in jobs {
            _ = try store.beginCall(name: "command_start", arguments: ["work_id": id])
            store.finishCall(id, name: "command_start", result: ["task_id": job, "running": true], failed: false)
        }
        let rows: [JSONObject] = jobs.map {
            ["task_id": $0.uppercased(), "status": "ok", "result":
                ["task_id": $0, "running": false, "exit_code": 7] as JSONObject]
        }
        for _ in 0..<3 {
            let inherited = try store.beginCall(name: "process_status_many", arguments: ["task_ids": jobs])
            store.finishCall(inherited, name: "process_status_many", result: ["results": rows], failed: false)
            XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 2)
        }
        // A failed batch item is still a new failed call, not a repeated exit.
        let inherited = try store.beginCall(name: "process_output_many", arguments: ["jobs": jobs.map { ["task_id": $0] }])
        store.finishCall(inherited, name: "process_output_many", result: ["results": [rows[0],
            ["requested_id_or_path": jobs[1], "status": "error", "message": "Output no longer retained"]]], failed: false)
        XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 3)
    }

    func testActualCallFailuresRemainCountedIndependently() throws {
        let store = WorkActivity(), id = try begin(store)
        for _ in 0..<2 {
            _ = try store.beginCall(name: "file_read", arguments: ["work_id": id])
            store.finishCall(id, name: "file_read", result: [:], failed: true)
        }
        _ = try store.beginCall(name: "file_write_many", arguments: ["work_id": id])
        store.finishCall(id, name: "file_write_many", result: ["error_count": 2], failed: false)
        XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 3)
    }

    func testListAndObserverOnlyFailureIsCountedOnceBeforeStatusRead() throws {
        for firstObservation in ["observer", "process_list", "work_task"] {
            let store = WorkActivity(), id = try begin(store), job = UUID().uuidString.lowercased()
            _ = try store.beginCall(name: "command_start", arguments: ["work_id": id])
            store.finishCall(id, name: "command_start", result: ["task_id": job, "running": true], failed: false)
            let stopped: JSONObject = ["task_id": job, "running": false, "exit_code": 7]
            let jobs = [stopped, ["task_id": UUID().uuidString.lowercased(), "running": false, "exit_code": 7]]
            switch firstObservation {
            case "process_list": store.finishCall(nil, name: "process_list", result: ["processes": jobs], failed: false)
            case "work_task": _ = try store.manage(["action": "list"], validWorkspaces: [], jobs: jobs, now: 2000)
            default: _ = store.list(jobs: jobs, now: 2000)
            }
            XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 1, firstObservation)
            for _ in 0..<3 {
                XCTAssertEqual(store.list(jobs: jobs)[0]["error_count"] as? Int, 1)
            }
            XCTAssertEqual(store.list(jobs: [])[0]["error_count"] as? Int, 1, "Missing rows do not invent or erase failures")
            let inherited = try store.beginCall(name: "process_status", arguments: ["task_id": job])
            store.finishCall(inherited, name: "process_status", result: stopped, failed: false)
            XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 1)
        }
    }

    func testFailedEnvelopeAndNonterminalStatusDoNotInventJobFailures() throws {
        let store = WorkActivity(), id = try begin(store), job = UUID().uuidString.lowercased()
        _ = try store.beginCall(name: "command_start", arguments: ["work_id": id])
        store.finishCall(id, name: "command_start", result: ["task_id": job, "running": true], failed: false)
        for failed in [true, false] {
            let inherited = try store.beginCall(name: "process_status", arguments: ["task_id": job])
            store.finishCall(inherited, name: "process_status", result:
                ["task_id": job, "running": !failed, "exit_code": 7], failed: failed)
        }
        // Only the failed tool call counts; neither response proves a child exit.
        XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 1)
        XCTAssertEqual(store.list(jobs: nil)[0]["phase"] as? String, "executing")
        let inherited = try store.beginCall(name: "process_status", arguments: ["task_id": job])
        store.finishCall(inherited, name: "process_status", result:
            ["task_id": job, "running": false, "exit_code": 7], failed: false)
        XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 2)
    }

    func testUpdateAndFinishAcceptRepeatedWorkspaceWithoutChangingScope() throws {
        let store = WorkActivity(), workspace = UUID().uuidString.lowercased()
        let id = try begin(store, workspace: workspace)
        let updated = try store.manage(["action": "update", "work_id": id,
            "workspace_id": workspace.uppercased(), "status": "waiting_user", "title": "Ready for review"],
            validWorkspaces: [workspace], jobs: [], now: 2_000)
        XCTAssertEqual(updated["state"] as? String, "waiting_user")
        XCTAssertEqual(updated["title"] as? String, "Ready for review")
        XCTAssertEqual(updated["workspace_id"] as? String, workspace)
        let finished = try store.manage(["action": "finish", "work_id": id,
            "workspace_id": workspace, "status": "completed"], validWorkspaces: [workspace], jobs: [], now: 3_000)
        XCTAssertEqual(finished["state"] as? String, "completed")
        XCTAssertEqual(finished["workspace_id"] as? String, workspace)
    }

    func testWorkspaceMismatchRejectsUpdateAndFinishAtomically() throws {
        let store = WorkActivity(), workspace = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        let id = try begin(store, title: "Original", workspace: workspace)
        for action in ["update", "finish"] {
            var arguments: JSONObject = ["action": action, "work_id": id, "workspace_id": other,
                "status": action == "update" ? "waiting_user" : "failed"]
            if action == "update" { arguments["title"] = "Must not apply"; arguments["chat_label"] = "Must not apply" }
            XCTAssertThrowsError(try store.manage(arguments, validWorkspaces: [workspace, other], jobs: [], now: 2_000))
            let unchanged = store.list(jobs: nil, now: 2_000)[0]
            XCTAssertEqual(unchanged["state"] as? String, "active")
            XCTAssertEqual(unchanged["title"] as? String, "Original")
            XCTAssertEqual(unchanged["chat_label"] as? String, "Declared chat")
            XCTAssertEqual(unchanged["workspace_id"] as? String, workspace)
            XCTAssertEqual(unchanged["updated_ms"] as? Int64, 1_000)
        }
        let unscoped = try begin(store, title: "Unscoped")
        XCTAssertThrowsError(try store.manage(["action": "update", "work_id": unscoped, "workspace_id": workspace],
            validWorkspaces: [workspace], jobs: []))
        XCTAssertThrowsError(try store.manage(["action": "finish", "work_id": unscoped, "workspace_id": workspace],
            validWorkspaces: [workspace], jobs: []))
        XCTAssertNil(store.list(jobs: nil).last?["workspace_id"])
    }

    func testListWorkspaceIsAnExplicitFilterAndRejectsUnsupportedFields() throws {
        let store = WorkActivity(), workspace = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        let a = try begin(store, title: "A", workspace: workspace)
        _ = try begin(store, title: "B", workspace: other)
        _ = try begin(store, title: "Unscoped")
        let filtered = try store.manage(["action": "list", "workspace_id": workspace.uppercased()],
            validWorkspaces: [workspace, other], jobs: [])
        XCTAssertEqual((filtered["work_items"] as? [JSONObject])?.compactMap { $0["work_id"] as? String }, [a])
        XCTAssertEqual((try store.manage(["action": "list"], validWorkspaces: [workspace, other], jobs: [])["work_items"] as? [JSONObject])?.count, 3)
        XCTAssertThrowsError(try store.manage(["action": "list", "workspace_id": UUID().uuidString],
            validWorkspaces: [workspace, other], jobs: []))
        XCTAssertThrowsError(try store.manage(["action": "list", "workspace_id": 42],
            validWorkspaces: [workspace, other], jobs: []))
        XCTAssertThrowsError(try store.manage(["action": "list", "title": "Not a supported filter"],
            validWorkspaces: [workspace, other], jobs: []))
    }

    func testBoundsNeverEvictActiveParentAndStaleDoesNotComplete() throws {
        let store = WorkActivity()
        let ids = try (0..<32).map { try begin(store, title: "Task \($0)") }
        XCTAssertThrowsError(try begin(store))
        let before = store.list(jobs: [], now: 121_000)
        XCTAssertEqual(before.count, 32)
        XCTAssertEqual(before[0]["stale"] as? Bool, true)
        XCTAssertEqual(before[0]["state"] as? String, "active")
        _ = try store.manage(["action": "finish", "work_id": ids[1], "status": "failed"], validWorkspaces: [], jobs: [])
        _ = try begin(store, title: "Replacement")
        let after = store.list(jobs: [])
        XCTAssertEqual(after.count, 32)
        XCTAssertEqual(after[0]["work_id"] as? String, ids[0])
        XCTAssertFalse(after.contains { $0["work_id"] as? String == ids[1] })
    }

    func testHeadlessBatchCompletionDoesNotExhaustJobRetentionAfter129Cycles() throws {
        let store = WorkActivity(), id = try begin(store)
        var firstJob: String?
        for cycle in 0..<129 {
            let job = UUID().uuidString.lowercased()
            if cycle == 0 { firstJob = job }
            _ = try store.beginCall(name: "command_start", arguments: ["work_id": id])
            store.finishCall(id, name: "command_start", result: ["task_id": job, "running": true], failed: false)
            let admitted = try store.beginCall(name: "process_output_many", arguments: ["jobs": [["task_id": job]]])
            XCTAssertEqual(admitted, id)
            store.finishCall(admitted, name: "process_output_many", result: ["results": [
                ["task_id": job, "status": "ok", "result": ["task_id": job, "running": false,
                    "exit_code": 7, "session_retained": false] as JSONObject] as JSONObject,
            ]], failed: false)
        }
        // No list/observer snapshot refresh supplied job state during the loop.
        let parent = store.list(jobs: nil)[0]
        let jobs = try XCTUnwrap(parent["job_ids"] as? [String])
        XCTAssertEqual(jobs.count, 128)
        XCTAssertFalse(jobs.contains(try XCTUnwrap(firstJob)))
        XCTAssertEqual(parent["phase"] as? String, "waiting_next_step")
        XCTAssertEqual(parent["active_call_count"] as? Int, 0)
        XCTAssertEqual(parent["call_count"] as? Int, 258)
        XCTAssertEqual(parent["error_count"] as? Int, 129, "Eviction must not erase historical failures")
        XCTAssertNil(try store.beginCall(name: "process_status", arguments: ["task_id": try XCTUnwrap(firstJob)]))
        store.finishCall(nil, name: "process_status", result: ["task_id": try XCTUnwrap(firstJob),
            "running": false, "exit_code": 7], failed: false)
        XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 129)
    }

    func testMixedOwnerBatchReconcilesOnlySuccessfulMatchingRetainedJobs() throws {
        let store = WorkActivity(), a = try begin(store, title: "A"), b = try begin(store, title: "B")
        let jobA = UUID().uuidString.lowercased(), jobB = UUID().uuidString.lowercased()
        for (owner, job) in [(a, jobA), (b, jobB)] {
            _ = try store.beginCall(name: "command_start", arguments: ["work_id": owner])
            store.finishCall(owner, name: "command_start", result: ["task_id": job, "running": true], failed: false)
        }
        let admitted = try store.beginCall(name: "process_status_many", arguments: ["task_ids": [jobA, jobB]])
        XCTAssertNil(admitted, "A mixed-owner call remains ungrouped")
        store.finishCall(admitted, name: "process_status_many", result: ["results": [
            ["task_id": jobA, "status": "ok", "result": ["task_id": jobA, "running": false, "exit_code": 7] as JSONObject] as JSONObject,
            ["task_id": jobB, "status": "error", "result": ["task_id": jobB, "running": false, "exit_code": 7] as JSONObject] as JSONObject,
            ["task_id": jobA, "status": "ok", "result": ["task_id": jobB, "running": false, "exit_code": 7] as JSONObject] as JSONObject,
        ]], failed: false)
        XCTAssertEqual(store.list(jobs: nil)[0]["phase"] as? String, "waiting_next_step")
        XCTAssertEqual(store.list(jobs: nil)[1]["phase"] as? String, "executing")
        XCTAssertEqual(store.list(jobs: nil)[0]["error_count"] as? Int, 1)
        XCTAssertEqual(store.list(jobs: nil)[1]["error_count"] as? Int, 0)
        XCTAssertThrowsError(try store.beginCall(name: "process_cancel", arguments: ["task_id": jobB, "work_id": a]))
        XCTAssertEqual(try store.beginCall(name: "process_status", arguments: ["task_id": jobB]), b)
        store.finishCall(b, name: "process_status", result: ["task_id": jobB, "running": false], failed: false)
    }

    func testLabelsAreBoundedAndCannotGrantWorkspaceOrAttachUnownedJob() throws {
        let store = WorkActivity(), workspace = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try store.manage(["action": "begin", "title": "Root", "workspace_id": workspace], validWorkspaces: [], jobs: []))
        XCTAssertThrowsError(try begin(store, title: String(repeating: "x", count: 161)))
        XCTAssertThrowsError(try begin(store, title: "Task\nforged status"))
        XCTAssertThrowsError(try begin(store, title: "Task\u{202e}forged"))
        let id = try begin(store, title: "Administrator", workspace: workspace)
        XCTAssertThrowsError(try store.manage(["action": "update", "work_id": id,
            "title": "Must not apply", "chat_label": "Invalid\u{202e}label"], validWorkspaces: [workspace], jobs: []))
        XCTAssertEqual(store.list(jobs: [])[0]["title"] as? String, "Administrator")
        XCTAssertEqual(store.list(jobs: [])[0]["chat_label"] as? String, "Declared chat")
        XCTAssertEqual(store.list(jobs: [])[0]["chat_label_authenticated"] as? Bool, false)
        XCTAssertThrowsError(try store.beginCall(name: "file_write", arguments: ["work_id": id, "workspace_id": UUID().uuidString]))
        XCTAssertThrowsError(try store.beginCall(name: "command_start", arguments: ["work_id": "not-a-uuid"]))
        XCTAssertThrowsError(try store.beginCall(name: "process_cancel", arguments: ["work_id": id, "task_id": UUID().uuidString]))
        XCTAssertNil(try store.beginCall(name: "file_read", arguments: [:]))
        XCTAssertNil(try store.beginCall(name: "process_status", arguments: ["task_id": UUID().uuidString]))
        XCTAssertEqual(store.list(jobs: [])[0]["call_count"] as? Int, 0)
    }

    func testServerStripsGroupingBeforeValidationAndRetainsParentBeyondHistory() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try LocalMCPServer(configurationURL: fixture.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"), observationEnabled: true)
        let parent = try server.callTool(name: "work_task", arguments: ["action": "begin", "title": "Review files", "workspace_id": fixture.workspaceID])
        let id = try XCTUnwrap(parent["work_id"] as? String)
        for _ in 0..<70 {
            XCTAssertEqual(try server.callTool(name: "workspace_overview", arguments: ["work_id": id])["work_id"] as? String, id)
        }
        _ = try server.callTool(name: "workspace_overview", arguments: [:])
        let snapshot = try server.observerRequest(["action": "snapshot"])
        let history = try XCTUnwrap(snapshot["history"] as? [JSONObject])
        XCTAssertEqual(history.count, 64)
        XCTAssertNil(history.last?["work_id"])
        XCTAssertEqual(history.first?["work_id"] as? String, id)
        let retained = try XCTUnwrap((snapshot["work_items"] as? [JSONObject])?.first)
        XCTAssertEqual(retained["call_count"] as? Int, 70)
        XCTAssertEqual(retained["phase"] as? String, "waiting_next_step")
        XCTAssertThrowsError(try server.callTool(name: "file_write", arguments: ["work_id": id, "workspace_id": fixture.workspaceID, "path": "forbidden.txt", "content": "test", "invented": true]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("forbidden.txt").path))
        XCTAssertThrowsError(try server.callTool(name: "command_start", arguments: ["work_id": UUID().uuidString, "workspace_id": fixture.workspaceID, "executable": "sh", "arguments": ["-c", "exit 0"]]))
        XCTAssertEqual((try server.callTool(name: "process_list", arguments: [:])["processes"] as? [JSONObject])?.count, 0)
    }

    func testCatalogHasExplicitBoundedGroupingWithoutChangingReadOnlyFlags() throws {
        let specs = LocalMCPServer.toolSpecs
        XCTAssertEqual(specs.count, 67)
        for spec in specs {
            let name = try XCTUnwrap(spec["name"] as? String)
            let schema = try XCTUnwrap(spec["inputSchema"] as? JSONObject)
            let properties = try XCTUnwrap(schema["properties"] as? JSONObject)
            if !["bridge_activity", "bridge_activity_view"].contains(name) { XCTAssertNotNil(properties["work_id"]) }
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }
        let read = try XCTUnwrap(specs.first { $0["name"] as? String == "file_read" })
        XCTAssertEqual((read["annotations"] as? JSONObject)?["readOnlyHint"] as? Bool, true)
    }

    func testRealCommandFailureAndCachedStatusDoNotInflateParentErrors() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try LocalMCPServer(configurationURL: fixture.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"), observationEnabled: true)
        let parent = try server.callTool(name: "work_task", arguments: ["action": "begin", "title": "Failure accounting",
            "workspace_id": fixture.workspaceID])
        let id = try XCTUnwrap(parent["work_id"] as? String)
        // A bounded synthetic child: no files, network, dependencies or live owner.
        let result = try server.callTool(name: "command_run", arguments: ["work_id": id,
            "workspace_id": fixture.workspaceID, "executable": "sh", "arguments": ["-c", "exit 7"],
            "timeout_milliseconds": 5000, "maximum_output_bytes": 4096])
        XCTAssertEqual(result["timed_out"] as? Bool, false, "Synthetic child exceeded its bounded startup allowance")
        XCTAssertEqual(result["exit_code"] as? Int, 7, "Synthetic child result: \(result)")
        let job = try XCTUnwrap(result["task_id"] as? String)
        for _ in 0..<3 {
            let status = try server.callTool(name: "process_status", arguments: ["task_id": job])
            XCTAssertEqual(status["exit_code"] as? Int, 7)
            XCTAssertEqual(status["status_only"] as? Bool, true)
            let snapshot = try server.observerRequest(["action": "snapshot"])
            XCTAssertEqual((snapshot["work_items"] as? [JSONObject])?.first?["error_count"] as? Int, 1)
        }
        let finished = try server.callTool(name: "work_task", arguments: ["action": "finish", "work_id": id, "status": "failed"])
        XCTAssertEqual(finished["error_count"] as? Int, 1)
        // The synchronous result already drained output. This is a real failed
        // tool call, and must count independently of the cached child exit.
        XCTAssertThrowsError(try server.callTool(name: "process_output", arguments: ["task_id": job]))
        let snapshot = try server.observerRequest(["action": "snapshot"])
        let retained = try XCTUnwrap((snapshot["work_items"] as? [JSONObject])?.first)
        XCTAssertEqual(retained["error_count"] as? Int, 2)
        XCTAssertEqual(retained["state"] as? String, "failed")
        XCTAssertEqual((try server.callTool(name: "process_list", arguments: [:])["processes"] as? [JSONObject])?.count, 0)
    }
}
