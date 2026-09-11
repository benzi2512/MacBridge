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
        XCTAssertEqual(names.count, 70); XCTAssertEqual(Set(names).count, 70)
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

    func testBatchWritesPartialReceiptsAndValidationBeforeMutation() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f), id = f.workspaceID
        let batch = try s.callTool(name: "file_write_many", arguments: ["workspace_id": id, "files": [
            ["path": "a", "content": "new"], ["path": "absent/child", "content": "no"]]])
        XCTAssertEqual(batch["success_count"] as? Int, 1); XCTAssertEqual(batch["error_count"] as? Int, 1)
        XCTAssertEqual(batch["batch_atomic"] as? Bool, false)
        let receipt = (batch["results"] as! [JSONObject])[0]["receipt"] as! JSONObject
        _ = try s.callTool(name: "transaction_restore", arguments: ["transaction_id": receipt["transaction_id"]!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("a").path))
        XCTAssertThrowsError(try s.callTool(name: "file_write_many", arguments: ["workspace_id": id, "files": [
            ["path": "b", "content": "new"], ["path": "c", "content": "no", "extra": "invalid"]]]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("b").path))
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
}
