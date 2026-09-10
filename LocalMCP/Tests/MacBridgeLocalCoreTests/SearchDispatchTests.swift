import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class SearchDispatchTests: XCTestCase {
    func testStalledSearchDoesNotBlockPingStatusCancelOrObserverAndRejectsExtraSearch() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("needle\n".utf8).write(to: f.workspace.appendingPathComponent("a.txt"))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let server = try LocalMCPServer(configurationURL: f.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"),
            observationEnabled: true, searchStartForTesting: { entered.signal(); release.wait() })
        let job = try server.callTool(name: "command_start", arguments: [
            "workspace_id": f.workspaceID, "executable": "cat", "arguments": []])
        let jobID = try XCTUnwrap(job["task_id"] as? String)
        defer { _ = try? server.callTool(name: "process_cancel", arguments: ["task_id": jobID]) }
        let owner = try XCTUnwrap(server.observerRequest(["action": "snapshot"])["instance_id"] as? String)
        func probe(_ operation: String) throws -> JSONObject {
            try server.observerRequest(["action": "identity_probe", "instance_id": owner, "operation": operation])
        }
        _ = try probe("start")
        defer { _ = try? probe("stop") }
        let input = Pipe(), output = Pipe(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
            catch { XCTFail("server run failed: \(error)") }
        }
        defer {
            release.signal()
            try? input.fileHandleForWriting.close()
            _ = done.wait(timeout: .now() + 3)
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: JSONObject) throws {
            var bytes = try LocalJSON.encode(value); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        func tool(_ id: Int, _ name: String, _ arguments: JSONObject) throws {
            // Synthetic envelope metadata only. This does not assert that any
            // real host sends these fields or that they establish chat identity.
            let source = id == 4 ? "B" : "A"
            let metadata: JSONObject = ["conversation_id": "SYNTHETIC_CONVERSATION_" + source,
                                        "thread_id": "SYNTHETIC_THREAD_" + source]
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                      "params": ["name": name, "arguments": arguments, "_meta": metadata] as JSONObject])
        }
        var received = Data()
        func receive() throws -> JSONObject {
            while received.firstIndex(of: 10) == nil {
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                        events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 2_000) > 0 else {
                    throw LocalMCPError.operationFailed("response blocked behind stalled search")
                }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
                guard count > 0 else { throw LocalMCPError.operationFailed("response stream ended") }
                received.append(contentsOf: buffer.prefix(count))
            }
            let newline = received.firstIndex(of: 10)!
            let frame = Data(received.prefix(upTo: newline))
            received.removeSubrange(...newline)
            return try LocalJSON.decodeObject(frame)
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as JSONObject,
            "clientInfo": ["name": "search-dispatch-test", "version": "1"]] as JSONObject])
        XCTAssertEqual(try receive()["id"] as? Int, 1)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let args: JSONObject = ["workspace_id": f.workspaceID, "query": "needle"]
        try tool(2, "file_search", args)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // The search is deliberately paused, not just hoped to be slow enough.
        try send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        try tool(4, "process_status", ["task_id": jobID])
        try tool(5, "workspace_reload", [:])
        try tool(6, "file_search", args)
        try tool(7, "process_cancel", ["task_id": jobID])
        var responses: [Int: JSONObject] = [:]
        for _ in 0..<5 {
            let response = try receive()
            responses[try XCTUnwrap(response["id"] as? Int)] = response
        }
        XCTAssertEqual(Set(responses.keys), Set([3, 4, 5, 6, 7]))
        func content(_ id: Int) throws -> JSONObject {
            let result = try XCTUnwrap(responses[id]?["result"] as? JSONObject)
            return try XCTUnwrap(result["structuredContent"] as? JSONObject)
        }
        XCTAssertEqual(try content(4)["running"] as? Bool, true)
        XCTAssertEqual((responses[5]?["result"] as? JSONObject)?["isError"] as? Bool, true)
        XCTAssertEqual((responses[6]?["result"] as? JSONObject)?["isError"] as? Bool, true)
        XCTAssertEqual(try content(7)["cancelled"] as? Bool, true)
        let snapshot = try server.observerRequest(["action": "snapshot"])
        XCTAssertEqual(snapshot["busy"] as? Bool, false)
        XCTAssertEqual(snapshot["snapshot_stale"] as? Bool, false)
        XCTAssertEqual(snapshot["active_searches"] as? Int, 1)
        let diagnostic = try probe("read")
        let samples = try XCTUnwrap(diagnostic["samples"] as? [JSONObject])
        XCTAssertEqual(samples.count, 5, "Each tools/call is sampled once, including rejected admission; ping is not sampled")
        guard samples.count == 5 else { throw LocalMCPError.operationFailed("unexpected identity probe sample count") }
        XCTAssertEqual(samples.compactMap { $0["sequence"] as? Int }, [1, 2, 3, 4, 5])
        XCTAssertEqual(samples.compactMap { $0["tool"] as? String },
                       ["file_search", "process_status", "workspace_reload", "file_search", "process_cancel"])
        for sample in samples {
            XCTAssertEqual(sample["meta_type"] as? String, "object")
            XCTAssertEqual(Set((sample["fields"] as? [JSONObject] ?? []).compactMap { $0["field"] as? String }),
                           Set(["conversation_id", "thread_id"]))
        }
        func tag(_ sample: JSONObject, field: String) throws -> String {
            try XCTUnwrap((sample["fields"] as? [JSONObject])?.first { $0["field"] as? String == field }?["equality_tag"] as? String)
        }
        for field in ["conversation_id", "thread_id"] {
            let first = try tag(samples[0], field: field)
            XCTAssertNotEqual(first, try tag(samples[1], field: field))
            for index in [2, 3, 4] { XCTAssertEqual(first, try tag(samples[index], field: field)) }
        }
        XCTAssertFalse(String(decoding: try LocalJSON.encode(diagnostic), as: UTF8.self).contains("SYNTHETIC_"))
        release.signal()
        try input.fileHandleForWriting.close()
        let search = try receive()
        XCTAssertEqual(search["id"] as? Int, 2)
        XCTAssertEqual((search["result"] as? JSONObject)?["isError"] as? Bool, false)
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        // Re-signal for the cleanup wait, which also handles early failures.
        done.signal()
        let afterCompletion = try XCTUnwrap(probe("read")["samples"] as? [JSONObject])
        XCTAssertEqual(afterCompletion.count, samples.count, "Finishing async dispatch must not sample the original frame again")
        XCTAssertEqual(try server.callTool(name: "bridge_capabilities", arguments: [:])["active_searches"] as? Int, 0)
        XCTAssertNoThrow(try server.callTool(name: "workspace_reload", arguments: [:]))
    }
}
