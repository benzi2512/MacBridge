import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ExpandedToolsTests: XCTestCase {
    private func server(_ f: Fixture) throws -> LocalMCPServer {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LocalMCPServer(configurationURL: f.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"))
    }

    func testCatalogBootstrapAndExactSchemaStayTogether() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), specs = LocalMCPServer.toolSpecs
        let names = specs.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, 76); XCTAssertEqual(Set(names).count, 76)
        let compact = try s.callTool(name: "tool_catalog", arguments: [:])
        XCTAssertEqual(compact["returned_count"] as? Int, 13)
        XCTAssertEqual(compact["truncated"] as? Bool, true)
        XCTAssertEqual(compact["detail"] as? String, "index")
        let catalog = try s.callTool(name: "tool_catalog", arguments: ["detail": "schemas"])
        XCTAssertEqual(try LocalJSON.encode(catalog["tools"] as! [JSONObject]), try LocalJSON.encode(specs))
        let capabilities = try s.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(capabilities["tool_names"] as? [String], names)
        XCTAssertEqual(capabilities["catalog_sha256"] as? String, catalog["catalog_sha256"] as? String)
        XCTAssertFalse(LocalMCPServer.discoveryGuide.contains(names.joined(separator: ", ")))
        XCTAssertTrue(LocalMCPServer.discoveryGuide.contains("already-loaded"))
        XCTAssertEqual(try LocalJSON.encode(s.callTool(name: "workspace_list", arguments: [:])),
                       try LocalJSON.encode(s.callTool(name: "workspace_overview", arguments: [:])))
        let subset = try s.callTool(name: "tool_catalog", arguments: ["names": ["command_start", "command_run"]])
        let selected = subset["tools"] as! [JSONObject]
        XCTAssertEqual(selected.count, 2)
        let start = selected.first { $0["name"] as? String == "command_start" }!
        XCTAssertNil(((start["inputSchema"] as! JSONObject)["properties"] as! JSONObject)["timeout_milliseconds"])
        XCTAssertThrowsError(try s.callTool(name: "tool_catalog", arguments: ["names": ["invented"]]))
        XCTAssertThrowsError(try s.callTool(name: "tool_catalog", arguments: ["names": []]))
        XCTAssertThrowsError(try s.callTool(name: "tool_catalog", arguments: ["detail": "invalid"]))
        XCTAssertThrowsError(try s.callTool(name: "command_list", arguments: ["surprise": true]))
    }

    func testLinesTailCompareAndUTF8Boundaries() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        let bytes = Data("one\r\n🙂tail\nlast".utf8)
        try bytes.write(to: f.workspace.appendingPathComponent("a.txt"))
        try bytes.write(to: f.workspace.appendingPathComponent("b.txt"))
        let lines = try s.callTool(name: "file_read_lines", arguments: ["workspace_id": id, "path": "a.txt", "maximum_lines": 2])
        XCTAssertEqual(lines["content"] as? String, "one\r\n🙂tail\n")
        XCTAssertEqual(lines["total_lines"] as? Int, 3)
        XCTAssertEqual(lines["next_line"] as? Int, 3)
        let eof = try s.callTool(name: "file_read_lines", arguments: ["workspace_id": id, "path": "a.txt", "start_line": 999])
        XCTAssertEqual(eof["content"] as? String, ""); XCTAssertEqual(eof["eof"] as? Bool, true)
        let tail = try s.callTool(name: "file_tail", arguments: ["workspace_id": id, "path": "a.txt", "maximum_bytes": 10])
        XCTAssertEqual(tail["content"] as? String, "tail\nlast")
        XCTAssertEqual(tail["byte_offset"] as? Int, 9)
        XCTAssertEqual(try s.callTool(name: "file_compare", arguments: ["workspace_id": id, "left_path": "a.txt", "right_path": "b.txt"])["equal"] as? Bool, true)
        try Data("other".utf8).write(to: f.workspace.appendingPathComponent("b.txt"))
        XCTAssertEqual(try s.callTool(name: "file_compare", arguments: ["workspace_id": id, "left_path": "a.txt", "right_path": "b.txt"])["first_different_byte"] as? Int, 1)
        try Data().write(to: f.workspace.appendingPathComponent("empty"))
        XCTAssertEqual(try s.callTool(name: "file_read_lines", arguments: ["workspace_id": id, "path": "empty"])["total_lines"] as? Int, 0)
    }

    func testExpandedReadsKeepBoundariesAndBudgets() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        try Data(repeating: 65, count: 1048577).write(to: f.workspace.appendingPathComponent("large"))
        try Data([0xFF]).write(to: f.workspace.appendingPathComponent("invalid"))
        try Data("one\ntwo\nONE\n".utf8).write(to: f.workspace.appendingPathComponent("a"))
        for path in ["large", "invalid", "../outside", ".env"] {
            XCTAssertThrowsError(try s.callTool(name: "file_read_lines", arguments: ["workspace_id": id, "path": path]))
        }
        let search = try s.callTool(name: "file_search_many", arguments: ["workspace_id": id,
            "paths": ["a", "missing", "invalid"], "query": "one", "case_sensitive": false, "maximum_results_per_file": 1])
        let rows = search["results"] as! [JSONObject]
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(rows[0]["complete"] as? Bool, false)
        XCTAssertEqual((rows[0]["matches"] as? [JSONObject])?.count, 1)
        XCTAssertEqual(rows[1]["status"] as? String, "error")
        XCTAssertEqual(rows[2]["status"] as? String, "error")
        XCTAssertThrowsError(try s.callTool(name: "file_search_many", arguments: ["workspace_id": id, "paths": [], "query": "one"]))
    }

    func testDirectorySummaryFindAndProjectMarkers() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        try Data("abc".utf8).write(to: f.workspace.appendingPathComponent("README.md"))
        try Data("defg".utf8).write(to: f.workspace.appendingPathComponent("other.txt"))
        let summary = try s.callTool(name: "directory_summary", arguments: ["workspace_id": id])
        XCTAssertEqual((summary["logical_file_bytes"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(summary["complete"] as? Bool, true)
        let find = try s.callTool(name: "directory_find", arguments: ["workspace_id": id, "pattern": "R*?.md"])
        XCTAssertEqual((find["matches"] as? [JSONObject])?.count, 1)
        let inspect = try s.callTool(name: "workspace_inspect", arguments: ["workspace_id": id])
        XCTAssertEqual((inspect["project_markers"] as? [JSONObject])?.count, 1)
        let limited = try s.callTool(name: "directory_summary", arguments: ["workspace_id": id, "maximum_entries": 1])
        XCTAssertEqual(limited["complete"] as? Bool, false)
        XCTAssertThrowsError(try s.callTool(name: "directory_find", arguments: ["workspace_id": id, "pattern": "../*"]))
    }

    func testMultiEditsValidateAllThenWriteOneTransactionAndRestore() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID, data = Data("alpha🙂 beta\n".utf8)
        let file = f.workspace.appendingPathComponent("a")
        try data.write(to: file)
        let args: JSONObject = ["workspace_id": id, "path": "a", "expected_sha256": LocalHash.sha256(data),
            "edits": [["old_text": "alpha", "new_text": "A"], ["old_text": "beta", "new_text": "B"]]]
        let receipt = try s.callTool(name: "file_apply_edits", arguments: args)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "A🙂 B\n")
        XCTAssertEqual(receipt["edits_applied"] as? Int, 2)
        _ = try s.callTool(name: "transaction_restore", arguments: ["transaction_id": receipt["transaction_id"]!])
        XCTAssertEqual(try Data(contentsOf: file), data)
        for edits in [
            [["old_text": "alpha", "new_text": "A"], ["old_text": "missing", "new_text": "B"]],
            [["old_text": "alpha", "new_text": "A"], ["old_text": "lpha", "new_text": "B"]],
            [["old_text": "", "new_text": "A"]],
        ] {
            var invalid = args; invalid["edits"] = edits
            XCTAssertThrowsError(try s.callTool(name: "file_apply_edits", arguments: invalid))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
        var stale = args; stale["expected_sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try s.callTool(name: "file_apply_edits", arguments: stale))
    }

    func testBatchWritesAreCoordinatedWithOneUndoAndValidationBeforeMutation() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        XCTAssertThrowsError(try s.callTool(name: "file_write_many", arguments: ["workspace_id": id, "files": [
            ["path": "a", "content": "new"], ["path": "absent/child", "content": "no"]]]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("a").path))
        let batch = try s.callTool(name: "file_write_many", arguments: ["workspace_id": id, "files": [
            ["path": "a", "content": "new"], ["path": "b", "content": "two"]]])
        XCTAssertEqual(batch["success_count"] as? Int, 2); XCTAssertEqual(batch["error_count"] as? Int, 0)
        XCTAssertEqual(batch["batch_atomic"] as? Bool, false)
        XCTAssertEqual(batch["all_or_compensated"] as? Bool, true)
        XCTAssertEqual(batch["crash_atomic"] as? Bool, false)
        _ = try s.callTool(name: "transaction_restore", arguments: ["transaction_id": batch["transaction_id"]!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("b").path))
        XCTAssertThrowsError(try s.callTool(name: "file_write_many", arguments: ["workspace_id": id, "files": [
            ["path": "b", "content": "new"], ["path": "c", "content": "no", "extra": "invalid"]]]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("b").path))

        let caseSensitive = try f.workspace.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames ?? true
        if !caseSensitive {
            XCTAssertThrowsError(try s.callTool(name: "file_write_many", arguments: [
                "workspace_id": id,
                "files": [["path": "alias.txt", "content": "one"],
                          ["path": "ALIAS.TXT", "content": "two"]],
            ]))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: f.workspace.appendingPathComponent("alias.txt").path
            ))
            let sigma = f.workspace.appendingPathComponent("σ.txt")
            try Data("baseline".utf8).write(to: sigma)
            XCTAssertThrowsError(try s.callTool(name: "file_write_many", arguments: [
                "workspace_id": id,
                "files": [["path": "σ.txt", "content": "one",
                           "expected_sha256": LocalHash.sha256(Data("baseline".utf8))],
                          ["path": "ς.txt", "content": "two",
                           "expected_sha256": LocalHash.sha256(Data("baseline".utf8))]],
            ]))
            XCTAssertEqual(try String(contentsOf: sigma, encoding: .utf8), "baseline")
        }
    }

    func testCompositeRestoreRetainsOnlyMembersNotYetRestored() throws {
        let f = try Fixture(); defer { f.remove() }
        let blocked = f.workspace.appendingPathComponent("blocked")
        let writable = f.workspace.appendingPathComponent("writable")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: false)
        let a = blocked.appendingPathComponent("a.txt")
        let b = writable.appendingPathComponent("b.txt")
        try Data("a-old".utf8).write(to: a)
        try Data("b-old".utf8).write(to: b)
        let s = try server(f)
        let batch = try s.callTool(name: "file_write_many", arguments: [
            "workspace_id": f.workspaceID,
            "files": [
                ["path": "blocked/a.txt", "content": "a-new",
                 "expected_sha256": LocalHash.sha256(Data("a-old".utf8))],
                ["path": "writable/b.txt", "content": "b-new",
                 "expected_sha256": LocalHash.sha256(Data("b-old".utf8))],
            ],
        ])
        let transactionID = try XCTUnwrap(batch["transaction_id"] as? String)
        XCTAssertEqual(chmod(blocked.path, 0o500), 0)
        XCTAssertThrowsError(try s.callTool(
            name: "transaction_restore", arguments: ["transaction_id": transactionID]
        ))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b-old")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a-new")
        XCTAssertEqual(chmod(blocked.path, 0o700), 0)
        _ = try s.callTool(
            name: "transaction_restore", arguments: ["transaction_id": transactionID]
        )
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a-old")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b-old")
    }

    func testProcessWaitIsNonCancellingAndTailIsNonConsuming() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let list = try s.callTool(name: "command_list", arguments: [:])
        XCTAssertTrue((list["commands"] as! [JSONObject]).contains { $0["executable"] as? String == "cat" && $0["available"] as? Bool == true })
        let started = try s.callTool(name: "command_start", arguments: ["workspace_id": f.workspaceID, "executable": "cat", "arguments": []])
        let id = started["task_id"] as! String
        defer { _ = try? s.callTool(name: "process_cancel", arguments: ["task_id": id]) }
        let wait = try s.callTool(name: "process_wait", arguments: ["task_id": id, "maximum_wait_milliseconds": 5])
        XCTAssertEqual(wait["running"] as? Bool, true)
        XCTAssertEqual(wait["timed_out"] as? Bool, false)
        _ = try s.callTool(name: "process_input", arguments: ["task_id": id, "content": "hello🙂END", "close_stdin": true])
        let end = try s.callTool(name: "process_wait", arguments: ["task_id": id])
        XCTAssertEqual(end["exit_code"] as? Int, 0)
        let tail = try s.callTool(name: "process_output_tail", arguments: ["task_id": id, "maximum_bytes_per_stream": 5])
        XCTAssertEqual(tail["stdout"] as? String, "END")
        XCTAssertEqual(tail["session_retained"] as? Bool, true)
        let states = try s.callTool(name: "process_status_many", arguments: ["task_ids": [id, "invalid"]])
        XCTAssertEqual((states["results"] as! [JSONObject])[1]["status"] as? String, "error")
        let drained = try s.callTool(name: "process_output_many", arguments: ["jobs": [["task_id": id]]])
        let result = (drained["results"] as! [JSONObject])[0]["result"] as! JSONObject
        XCTAssertEqual(result["stdout"] as? String, "hello🙂END")
        XCTAssertEqual(result["session_retained"] as? Bool, false)
        let status = try s.callTool(name: "process_wait", arguments: ["task_id": id])
        XCTAssertEqual(status["status_only"] as? Bool, true)
        XCTAssertThrowsError(try s.callTool(name: "process_wait", arguments: ["task_id": id, "maximum_wait_milliseconds": 1001]))
    }

    func testCapabilitiesCountBackgroundAndCompletedUndrainedHandlesSeparately() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        func counts() throws -> JSONObject {
            let capabilities = try s.callTool(name: "bridge_capabilities", arguments: [:])
            XCTAssertEqual(capabilities["active_command_runs"] as? Int, 0)
            XCTAssertEqual(capabilities["active_command_runs_scope"] as? String,
                           "active_command_run_execution_leases_not_background_jobs_or_delivery_ack")
            let result = try XCTUnwrap(capabilities["process_activity"] as? JSONObject)
            XCTAssertEqual(Set(result.keys), Set([
                "running", "retained_handles", "completed_retained_handles", "starting",
                "retained_handle_limit", "scope",
            ]))
            XCTAssertEqual(result["starting"] as? Int, 0)
            XCTAssertEqual(result["retained_handle_limit"] as? Int, 32)
            XCTAssertEqual(result["scope"] as? String, "runtime_wide_snapshot_not_restart_authorization")
            return result
        }
        XCTAssertEqual(try counts()["retained_handles"] as? Int, 0)
        var ids: [String] = []
        defer {
            for id in ids { _ = try? s.callTool(name: "process_cancel", arguments: ["task_id": id]) }
        }
        for _ in 0..<8 {
            let start = try s.callTool(name: "command_start", arguments: [
                "workspace_id": f.workspaceID, "executable": "cat", "arguments": [],
                "maximum_output_bytes": 4096,
            ])
            ids.append(try XCTUnwrap(start["task_id"] as? String))
        }
        let running = try counts()
        XCTAssertEqual(running["running"] as? Int, 8)
        XCTAssertEqual(running["retained_handles"] as? Int, 8)
        XCTAssertEqual(running["completed_retained_handles"] as? Int, 0)
        // Invalid starts must not leave a reservation in the activity count.
        XCTAssertThrowsError(try s.callTool(name: "command_start", arguments: [
            "workspace_id": f.workspaceID, "executable": "unavailable-fixture-command", "arguments": [],
        ]))
        XCTAssertEqual(try counts()["retained_handles"] as? Int, 8)
        for id in ids {
            do {
                _ = try s.callTool(name: "process_input", arguments: [
                    "task_id": id, "content": "private-output-marker\n", "close_stdin": true,
                ])
            } catch {
                let detail = try? s.callTool(name: "process_output_tail", arguments: ["task_id": id])
                let stderr = detail?["stderr"] as? String ?? "unavailable"
                XCTFail("cat fixture closed before input; stderr: \(stderr)")
                throw error
            }
            let finished = try s.callTool(name: "process_wait", arguments: ["task_id": id])
            XCTAssertEqual(finished["running"] as? Bool, false)
        }
        let completed = try counts()
        XCTAssertEqual(completed["running"] as? Int, 0)
        XCTAssertEqual(completed["retained_handles"] as? Int, 8)
        XCTAssertEqual(completed["completed_retained_handles"] as? Int, 8)
        let encoded = try LocalJSON.encode(completed)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-output-marker"))
        for id in ids { XCTAssertFalse(text.contains(id)) }
        let drain = try s.callTool(name: "process_output_many", arguments: [
            "jobs": ids.map { ["task_id": $0] },
        ])
        let results = try XCTUnwrap(drain["results"] as? [JSONObject])
        XCTAssertEqual(results.count, 8)
        for row in results {
            let result = try XCTUnwrap(row["result"] as? JSONObject)
            XCTAssertEqual(result["session_retained"] as? Bool, false)
            XCTAssertEqual(result["exit_code"] as? Int, 0)
        }
        let empty = try counts()
        XCTAssertEqual(empty["running"] as? Int, 0)
        XCTAssertEqual(empty["retained_handles"] as? Int, 0)
        XCTAssertEqual(empty["completed_retained_handles"] as? Int, 0)
    }

    func testFeedbackHardeningDiagnosticsResolutionAndSnapshotBundle() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        try Data("readme".utf8).write(to: f.workspace.appendingPathComponent("README.md"))
        try Data("value".utf8).write(to: f.workspace.appendingPathComponent("a.txt"))
        let diagnostic = try s.callTool(name: "bridge_diagnostic", arguments: [:])
        XCTAssertEqual(diagnostic["server_alive"] as? Bool, true)
        XCTAssertEqual(diagnostic["host_binding_verified"] as? Bool, false)
        XCTAssertEqual(diagnostic["workspace_actions_callable"] as? Bool, true)
        XCTAssertNil(diagnostic["file_actions_callable"] as? Bool)
        XCTAssertEqual(diagnostic["file_actions_verified"] as? Bool, false)
        XCTAssertNotNil(diagnostic["binding_epoch"] as? String)
        let caps = try s.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(caps["binding_epoch"] as? String, diagnostic["binding_epoch"] as? String)
        let resolved = try s.callTool(name: "workspace_resolve", arguments: [
            "path": f.workspace.appendingPathComponent("a.txt").path,
        ])
        XCTAssertEqual(resolved["workspace_id"] as? String, id)
        XCTAssertEqual(resolved["relative_path"] as? String, "a.txt")
        XCTAssertEqual(resolved["access_changed"] as? Bool, false)
        let bundle = try s.callTool(name: "project_read_bundle", arguments: [
            "workspace_id": id, "paths": ["README.md", "a.txt"],
        ])
        XCTAssertEqual(bundle["snapshot_consistent"] as? Bool, true)
        XCTAssertEqual(bundle["snapshot_atomic"] as? Bool, true)
        XCTAssertEqual(bundle["project_markers"] as? [String], ["README.md"])
        XCTAssertNotNil(bundle["snapshot_token"] as? String)
    }

    func testDiagnosticBlocksWhenRegisteredWorkspaceRootDisappears() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let moved = f.root.appendingPathComponent("workspace-moved")
        try FileManager.default.moveItem(at: f.workspace, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: f.workspace) }
        let diagnostic = try s.callTool(name: "bridge_diagnostic", arguments: [:])
        XCTAssertEqual(diagnostic["status"] as? String, "BLOCKED")
        XCTAssertEqual(diagnostic["workspace_actions_callable"] as? Bool, false)
        XCTAssertEqual(diagnostic["available_workspace_count"] as? Int, 0)
        XCTAssertNil(diagnostic["file_actions_callable"] as? Bool)
    }

    func testDiagnosticDoesNotCallUnreadableWorkspaceAvailable() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        XCTAssertEqual(chmod(f.workspace.path, 0o000), 0)
        defer { _ = chmod(f.workspace.path, 0o700) }
        let diagnostic = try s.callTool(name: "bridge_diagnostic", arguments: [:])
        XCTAssertEqual(diagnostic["status"] as? String, "BLOCKED")
        XCTAssertEqual(diagnostic["available_workspace_count"] as? Int, 0)
    }

    func testJSONPatchAndContentAddressedArtifactHaveCASAndUndo() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        let original = Data("{\"name\":\"old\",\"items\":[1]}\n".utf8)
        let json = f.workspace.appendingPathComponent("data.json")
        try original.write(to: json)
        let originalHash = LocalHash.sha256(original)
        let patched = try s.callTool(name: "file_json_patch", arguments: [
            "workspace_id": id, "path": "data.json", "expected_sha256": originalHash,
            "operations": [
                ["op": "test", "path": "/name", "value": "old"],
                ["op": "replace", "path": "/name", "value": "new"],
                ["op": "add", "path": "/items/-", "value": 2],
            ],
        ])
        XCTAssertEqual(patched["json_patch_operations"] as? Int, 3)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? JSONObject
        XCTAssertEqual(object?["name"] as? String, "new")
        XCTAssertEqual(object?["items"] as? [Int], [1, 2])
        XCTAssertThrowsError(try s.callTool(name: "file_json_patch", arguments: [
            "workspace_id": id, "path": "data.json", "expected_sha256": originalHash,
            "operations": [["op": "replace", "path": "/name", "value": "stale"]],
        ]))
        _ = try s.callTool(name: "transaction_restore", arguments: ["transaction_id": patched["transaction_id"]!])
        XCTAssertEqual(try Data(contentsOf: json), original)

        let destination = "artifacts/\(originalHash).json"
        try FileManager.default.createDirectory(
            at: f.workspace.appendingPathComponent("artifacts"), withIntermediateDirectories: false
        )
        let artifact = try s.callTool(name: "artifact_snapshot", arguments: [
            "workspace_id": id, "source_path": "data.json",
            "destination_path": destination, "expected_source_sha256": originalHash,
        ])
        XCTAssertEqual(artifact["artifact_sha256"] as? String, originalHash)
        XCTAssertEqual(artifact["content_addressed"] as? Bool, true)
        XCTAssertThrowsError(try s.callTool(name: "artifact_snapshot", arguments: [
            "workspace_id": id, "source_path": "data.json",
            "destination_path": destination, "expected_source_sha256": originalHash,
        ]))
        _ = try s.callTool(name: "transaction_restore", arguments: ["transaction_id": artifact["transaction_id"]!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent(destination).path))
    }

    func testCreateOnlyAndStaleCASExposeCurrentRevision() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        let current = Data("current".utf8)
        try current.write(to: f.workspace.appendingPathComponent("existing.txt"))
        for createOnly in [true, false] {
            do {
                var arguments: JSONObject = [
                    "workspace_id": id, "path": "existing.txt", "content": "next",
                    "create_only": createOnly,
                ]
                if !createOnly { arguments["expected_sha256"] = String(repeating: "0", count: 64) }
                _ = try s.callTool(name: "file_write", arguments: arguments)
                XCTFail("conflict should be returned")
            } catch let error as LocalMCPError {
                XCTAssertEqual(error.detail["current_sha256"] as? String, LocalHash.sha256(current))
                XCTAssertNotNil(error.detail["current_modified_milliseconds"])
            }
        }
    }
}
