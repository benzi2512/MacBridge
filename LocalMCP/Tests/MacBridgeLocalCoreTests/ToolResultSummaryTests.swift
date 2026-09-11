import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ToolResultSummaryTests: XCTestCase {
    func testRunningAndNonzeroExitNeverClaimTestSuccess() {
        let running = ToolResultSummary.text(name: "command_start", result: ["running": true])
        XCTAssertEqual(running, "command start: Process running.")
        for code in [0, 1, 127] {
            let text = ToolResultSummary.text(name: "process_output", result: [
                "running": false, "exit_code": code, "session_retained": false,
                "stdout": "ALL TESTS PASS", "stderr": "private output"])
            XCTAssertTrue(text.contains("exited with code \(code)"))
            XCTAssertTrue(text.contains("handle released"))
            XCTAssertFalse(text.contains("PASS"))
            XCTAssertFalse(text.contains("private output"))
        }
    }

    func testTimeoutRetentionAndInputAreExplicit() {
        let status = ToolResultSummary.text(name: "process_status", result: [
            "running": false, "timed_out": true, "cancelled": true, "session_retained": true,
            "stdout_truncated": true])
        for fragment in ["stopped", "timed out", "cancelled", "handle retained", "truncated"] {
            XCTAssertTrue(status.contains(fragment))
        }
        let input = ToolResultSummary.text(name: "process_input", result: [
            "running": true, "bytes_written": 2, "input_complete": false, "stdin_closed": true])
        XCTAssertTrue(input.contains("2 input bytes written"))
        XCTAssertTrue(input.contains("reconcile before retrying"))
        XCTAssertTrue(input.contains("stdin closed"))
    }

    func testPartialBatchDoesNotClaimAllWritesOrReadsSucceeded() {
        let write = ToolResultSummary.text(name: "file_write_many", result: [
            "results": [["status": "ok"], ["status": "error"]], "success_count": 1,
            "error_count": 1, "mutation_performed": true, "complete": false])
        XCTAssertTrue(write.contains("1 writes applied"))
        XCTAssertTrue(write.contains("1 item-call errors"))
        XCTAssertTrue(write.contains("partial result"))
        let read = ToolResultSummary.text(name: "file_read_many", result: [
            "results": [["status": "ok", "file": ["eof": false]], ["status": "skipped_budget"]],
            "read_count": 1])
        for fragment in ["1 skipped", "1 files read", "partial result"] { XCTAssertTrue(read.contains(fragment)) }
        let search = ToolResultSummary.text(name: "file_search_many", result: [
            "results": [["status": "ok", "complete": false]]])
        XCTAssertTrue(search.contains("partial result"))
    }

    func testReadAndActivityLabelsDoNotEchoDataOrClaimRender() {
        let read = ToolResultSummary.text(name: "file_read", result: [
            "file": ["byte_count": 5, "eof": false, "content": "private", "relative_path": "private"]])
        XCTAssertEqual(read, "file read: Read 5 bytes; more file data remains.")
        let activity = ToolResultSummary.text(name: "bridge_activity_view", result: ["snapshot_stale": true])
        XCTAssertTrue(activity.contains("rendering is host-controlled"))
        XCTAssertTrue(activity.contains("stale snapshot"))
        XCTAssertFalse(activity.contains("opened"))
        XCTAssertEqual(ToolResultSummary.text(name: "file_tail", result: ["byte_count": 5]),
                       "file tail: Read 5 tail bytes; not a full-file read.")
    }

    func testBatchProcessSeparatesItemCallErrorsFromJobFailures() {
        for name in ["process_status_many", "process_output_many"] {
            let text = ToolResultSummary.text(name: name, result: ["results": [
                ["status": "ok", "result": ["running": true]],
                ["status": "ok", "result": ["running": false, "exit_code": 1, "timed_out": true,
                                             "cancelled": true, "stdout_truncated": true]],
                ["status": "ok", "result": ["running": false, "exit_code": 0]],
                ["status": "error"]]])
            for fragment in ["1 item-call errors", "1 running", "1 nonzero exits", "1 timed out",
                             "1 cancelled", "some job output truncated", "partial result"] {
                XCTAssertTrue(text.contains(fragment), text)
            }
            XCTAssertFalse(text.contains("PASS"))
        }
    }

    func testOnlyUUIDJobIDsAreRepeated() {
        let id = "11111111-2222-4333-8444-555555555555"
        XCTAssertTrue(ToolResultSummary.text(name: "process_output", result: ["task_id": id]).contains(id))
        XCTAssertFalse(ToolResultSummary.text(name: "process_output", result: ["task_id": "private payload"]).contains("private payload"))
    }

    func testConcreteCommandAndFileContextPreserveResultMeaning() {
        let running = ToolResultSummary.text(name: "command_start", result: ["running": true], arguments: [
            "executable": "swift", "arguments": ["test", "--jobs", "2"], "cwd": "Project"])
        XCTAssertTrue(running.contains("Process running"))
        XCTAssertTrue(running.contains("command swift test --jobs 2"))
        XCTAssertTrue(running.contains("folder Project"))
        XCTAssertFalse(running.contains("success"))
        let read = ToolResultSummary.text(name: "file_read_lines", result: ["returned_lines": 5, "start_line": 40, "eof": true],
            arguments: ["path": "Sources/Config.swift", "start_line": 40, "maximum_lines": 56])
        XCTAssertTrue(read.contains("Read 5 lines (40–44)"))
        XCTAssertTrue(read.contains("target Sources/Config.swift"))
        XCTAssertTrue(read.contains("requested lines 40–95"))
        let edit = ToolResultSummary.text(name: "file_apply_edits", result: ["mutation_performed": true, "edits_applied": 2],
            arguments: ["path": "Sources/Config.swift", "edits": [["old_text": "private", "new_text": "private"]]])
        XCTAssertTrue(edit.contains("2 edits applied"))
        XCTAssertFalse(edit.contains("private"))
    }

    func testFailedRejectedOrMissingMutationReceiptNeverClaimsRequestedEditApplied() {
        let args: JSONObject = ["path": "Sources/Config.swift", "edits": [["old_text": "private", "new_text": "private"]]]
        let results: [JSONObject] = [["error": "conflict"], ["isError": true, "mutation_performed": true, "edits_applied": 1],
                                     ["status": "error"], ["mutation_performed": false], [:]]
        for result in results {
            let summary = ToolResultSummary.text(name: "file_apply_edits", result: result, arguments: args)
            XCTAssertFalse(summary.contains("Change applied"), summary)
            XCTAssertFalse(summary.contains("edits applied"), summary)
            XCTAssertTrue(summary.contains("target Sources/Config.swift"))
            XCTAssertFalse(summary.contains("private"))
        }
    }

    func testSummaryNeverCopiesScriptOrSensitiveArgumentValues() {
        let summary = ToolResultSummary.text(name: "command_run", result: ["running": false, "exit_code": 1], arguments: [
            "executable": "zsh", "arguments": ["-lc", "printf '%s' secret-value"], "cwd": "Project"])
        XCTAssertTrue(summary.contains("Process exited with code 1"))
        XCTAssertTrue(summary.contains("script"))
        XCTAssertFalse(summary.contains("secret-value"))
        XCTAssertFalse(summary.contains("printf"))
    }

    func testRPCUsesSummaryWithoutChangingStructuredPayloadOrError() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try LocalMCPServer(configurationURL: f.config, selfExecutable: f.config, connectorSurface: .webTunnel)
        let response = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                              "params": ["name": "process_list", "arguments": JSONObject()]]))
        let result = try XCTUnwrap(response["result"] as? JSONObject)
        XCTAssertEqual(try LocalJSON.encode(result["structuredContent"]!), try LocalJSON.encode(["processes": [JSONObject]()]))
        XCTAssertEqual((result["content"] as? [JSONObject])?.first?["text"] as? String,
                       "process list: 0 retained processes.")
        let error = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "process_status", "arguments": ["task_id": "11111111-2222-4333-8444-555555555555"]]])?["result"] as? JSONObject)
        XCTAssertEqual(error["isError"] as? Bool, true)
        XCTAssertEqual((error["content"] as? [JSONObject])?.first?["text"] as? String, "Unknown process task.")
    }

    func testLongProcessReportsMeasuredDurationAndPageBoundariesWithoutCopyingOutput() {
        let result: JSONObject = ["running": true, "started_milliseconds": 10_000,
            "stdout_total_bytes": 12_000, "stderr_total_bytes": 900,
            "stdout_cursor": 1_000, "stdout_next_cursor": 2_000,
            "stderr_cursor": 0, "stderr_next_cursor": 900,
            "stdout": "PRIVATE_COMMAND_OUTPUT", "stderr": "password=SECRET_VALUE"]
        let text = ToolResultSummary.text(name: "process_output", result: result,
            processContext: "command swift test --jobs 2; folder Project", nowMilliseconds: 42_500)
        for fragment in ["command swift test --jobs 2", "elapsed 32.5s", "produced 12000 B stdout / 900 B stderr",
                         "this page 1000 B stdout / 900 B stderr", "more output remains"] {
            XCTAssertTrue(text.contains(fragment), text)
        }
        XCTAssertTrue(text.hasPrefix("process output: command swift"))
        XCTAssertFalse(text.contains("PRIVATE_COMMAND_OUTPUT"))
        XCTAssertFalse(text.contains("SECRET_VALUE"))
        XCTAssertFalse(text.contains("%"))
    }

    func testCompletedDurationIsFrozenAndMalformedMetricsAreNotInvented() {
        let result: JSONObject = ["running": false, "exit_code": 7,
            "started_milliseconds": 10_000, "ended_milliseconds": 15_000]
        let a = ToolResultSummary.text(name: "process_status", result: result, nowMilliseconds: 50_000)
        let b = ToolResultSummary.text(name: "process_status", result: result, nowMilliseconds: 99_000)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("duration 5.0s"))
        XCTAssertTrue(a.contains("code 7"))
        for bad: Any in [true, -1, 0.5, "1234", Int64.max, Double.infinity, Double.nan] {
            let text = ToolResultSummary.text(name: "process_status", result: [
                "running": true, "started_milliseconds": bad,
                "stdout_total_bytes": bad, "stderr_total_bytes": 0], nowMilliseconds: 50_000)
            XCTAssertFalse(text.contains("elapsed"), text)
            XCTAssertFalse(text.contains("produced"), text)
        }
    }

    func testClockReversalAndInvalidCursorsDoNotCreateNegativeOrFalseProgress() {
        let text = ToolResultSummary.text(name: "process_output", result: [
            "running": true, "started_milliseconds": 100_000,
            "stdout_total_bytes": 100, "stderr_total_bytes": 0,
            "stdout_cursor": 120, "stdout_next_cursor": 10,
            "stderr_cursor": 0, "stderr_next_cursor": 0], nowMilliseconds: 90_000)
        XCTAssertFalse(text.contains("elapsed"))
        XCTAssertFalse(text.contains("this page"))
        XCTAssertFalse(text.contains("more output remains"))
    }

    func testDeveloperContinuationUsesNestedFailureAndTruncationNotTopLevelSuccess() {
        let text = ToolResultSummary.text(name: "developer_task", result: [
            "developer_action": "continue_task", "running": false, "exit_code": 0,
            "workflow_terminal": true,
            "process": ["running": false, "exit_code": 3, "timed_out": true,
                        "stdout_truncated": true, "session_retained": true,
                        "started_milliseconds": 10_000, "ended_milliseconds": 22_000]],
            processContext: "command make test; folder Project")
        for fragment in ["command make test", "code 3", "timed out", "handle retained", "truncated",
                         "duration 12.0s", "acceptance still requires test/diff review"] {
            XCTAssertTrue(text.contains(fragment), text)
        }
        XCTAssertFalse(text.contains("code 0"))
        XCTAssertFalse(text.contains("PASS"))
    }

    func testTaskPhasesAndInspectionUseReceiptsWithoutTrustingCallerLabels() {
        let work = ToolResultSummary.text(name: "work_task", result: ["phase": "completed",
            "title": "PRIVATE_TITLE_PASS", "call_count": 9, "error_count": 2])
        XCTAssertTrue(work.contains("marked completed by caller"))
        XCTAssertTrue(work.contains("9 calls; 2 recorded errors"))
        XCTAssertFalse(work.contains("PRIVATE_TITLE_PASS"))
        let stale = ToolResultSummary.text(name: "work_task", result: ["phase": "waiting_next_step", "stale": true])
        XCTAssertTrue(stale.contains("not proof of completion"))
        let inspect = ToolResultSummary.text(name: "developer_inspect", result: [
            "inspection": ["scanned_returned_entries": 17],
            "git_status": ["exit_code": 0, "stdout": "private filename"],
            "git_diff": ["exit_code": 128, "stdout_truncated": true]])
        for fragment in ["inspected 17 directory entries", "Git status exit 0", "diff exit 128", "diff output truncated"] {
            XCTAssertTrue(inspect.contains(fragment), inspect)
        }
        XCTAssertFalse(inspect.contains("private filename"))
    }

    func testCapabilityReceiptDoesNotClaimHostToolLoading() {
        let text = ToolResultSummary.text(name: "bridge_capabilities", result: ["catalog_count": 67])
        XCTAssertTrue(text.contains("Runtime reachable; 67 catalog tools"))
        XCTAssertTrue(text.contains("host loading not verified"))
    }

    func testWorstCaseSanitizedCommandSummaryStaysBoundedAndSingleLine() {
        let text = ToolResultSummary.text(name: "command_run", result: ["running": true,
            "task_id": "11111111-2222-4333-8444-555555555555", "started_milliseconds": 1,
            "stdout_total_bytes": 12_345_678, "stderr_total_bytes": 9_876_543], arguments: [
            "executable": "swift", "arguments": Array(repeating: "test", count: 128),
            "cwd": String(repeating: "Project/", count: 500)], nowMilliseconds: 55_000)
        XCTAssertLessThan(text.utf8.count, 1_600)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.contains("truncated"))
    }
}
