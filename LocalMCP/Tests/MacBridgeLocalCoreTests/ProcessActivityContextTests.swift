import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ProcessActivityContextTests: XCTestCase {
    func testContextLookupDoesNotConsumeOutputOrLeakInlineScripts() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = LocalProcessService(workspaceService: try f.service(), selfExecutable: binary)
        let start = try service.startCommand(workspaceID: f.workspaceID, executableID: "sh",
            arguments: ["-c", "printf 'PRIVATE_CONTEXT_SENTINEL'"], cwd: ".", maximumOutputBytes: 1_024)
        let id = try XCTUnwrap(start["task_id"] as? String)
        defer { _ = try? service.cancelProcess(taskID: id) }
        for _ in 0..<100 {
            let context = try XCTUnwrap(service.activityContext(taskID: id))
            XCTAssertTrue(context.contains("command sh -c [script"))
            XCTAssertTrue(context.contains("folder ."))
            XCTAssertFalse(context.contains("PRIVATE_CONTEXT_SENTINEL"))
            XCTAssertFalse(context.contains("printf"))
        }
        for _ in 0..<5 {
            if try service.observeProcess(taskID: id, maximumWaitMilliseconds: 1_000)["running"] as? Bool == false { break }
        }
        let before = try LocalJSON.encode(service.processStatus(taskID: id))
        _ = service.activityContext(taskID: id)
        XCTAssertEqual(try LocalJSON.encode(service.processStatus(taskID: id)), before)
        let output = try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 1_024)
        XCTAssertEqual(output["stdout"] as? String, "PRIVATE_CONTEXT_SENTINEL")
        XCTAssertEqual(output["session_retained"] as? Bool, false)
        XCTAssertNotNil(service.activityContext(taskID: id), "final receipt retains sanitized command context")
        XCTAssertNil(service.activityContext(taskID: UUID().uuidString))
        XCTAssertNil(service.activityContext(taskID: "not a task"))
    }

    func testContextUsesExistingCompletedStatusTTLAndCountBound() throws {
        let f = try Fixture(); defer { f.remove() }
        var now: TimeInterval = 0
        let service = LocalProcessService(workspaceService: try f.service(), selfExecutable: binary,
            outputByteLimit: 4_096, completedStatusLimit: 1, completedStatusTTL: 5, monotonicNow: { now })
        func run(_ executable: String) throws -> String {
            let result = try service.runCommand(workspaceID: f.workspaceID, executableID: executable,
                arguments: [], cwd: ".", timeoutMilliseconds: 2_000, maximumOutputBytes: 1_024)
            return try XCTUnwrap(result["task_id"] as? String)
        }
        let first = try run("true")
        XCTAssertTrue(try XCTUnwrap(service.activityContext(taskID: first)).contains("command true"))
        let second = try run("true")
        XCTAssertNil(service.activityContext(taskID: first), "eviction also drops context")
        XCTAssertTrue(try XCTUnwrap(service.activityContext(taskID: second)).contains("command true"))
        now = 6
        XCTAssertNil(service.activityContext(taskID: second), "TTL also expires context")
        XCTAssertEqual(service.trackedProcessCount, 0)
    }

    func testRPCContinuationNamesRealJobCommandWithoutChangingStructuredPayload() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try LocalMCPServer(configurationURL: f.config, selfExecutable: binary, connectorSurface: .webTunnel)
        func call(_ name: String, _ args: JSONObject) throws -> JSONObject {
            let rpc = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": args]])?["result"] as? JSONObject)
            XCTAssertEqual(rpc["isError"] as? Bool, false)
            return rpc
        }
        let start = try call("command_start", ["workspace_id": f.workspaceID, "cwd": ".", "executable": "cat", "arguments": [String]()])
        let id = try XCTUnwrap((start["structuredContent"] as? JSONObject)?["task_id"] as? String)
        let token = try XCTUnwrap((start["structuredContent"] as? JSONObject)?["process_control_token"] as? String)
        let status = try call("process_status", ["task_id": id])
        let text = try XCTUnwrap((status["content"] as? [JSONObject])?.first?["text"] as? String)
        XCTAssertTrue(text.contains("command cat; folder ."), text)
        XCTAssertTrue(text.contains("Process running"), text)
        XCTAssertNil((status["structuredContent"] as? JSONObject)?["activity_context"])
        _ = try call("process_cancel", ["task_id": id, "process_control_token": token])
    }

    private var binary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/macbridge-mcp")
    }
}
