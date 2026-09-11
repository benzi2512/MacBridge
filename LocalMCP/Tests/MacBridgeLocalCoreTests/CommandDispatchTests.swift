import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class CommandDispatchTests: XCTestCase {
    func testParentWorkIsValidatedBeforeAsyncLaunchAndOwnsPendingJob() throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try makeServer(f)
        let io = CommandDispatchConnection(server); defer { io.close() }
        try io.initialize()
        try io.tool(100, "work_task", ["action": "begin", "title": "Build fixture", "workspace_id": f.workspaceID])
        let workID = try XCTUnwrap(try structured(io.receive(id: 100))["work_id"] as? String)
        var invalid = commandArguments(f, executable: "true")
        invalid["work_id"] = UUID().uuidString.lowercased()
        try io.tool(101, "command_run", invalid)
        XCTAssertEqual(try result(io.receive(id: 101))["isError"] as? Bool, true)
        try io.tool(102, "process_list", [:])
        XCTAssertEqual((try structured(io.receive(id: 102))["processes"] as? [JSONObject])?.count, 0)
        var valid = commandArguments(f)
        valid["work_id"] = workID
        try io.tool(103, "command_run", valid)
        try io.tool(104, "process_list", [:])
        let job = try XCTUnwrap((try structured(io.receive(id: 104))["processes"] as? [JSONObject])?.first)
        let taskID = try XCTUnwrap(job["task_id"] as? String)
        defer { _ = try? server.callTool(name: "process_cancel", arguments: ["task_id": taskID]) }
        try io.tool(105, "work_task", ["action": "finish", "work_id": workID])
        XCTAssertEqual(try result(io.receive(id: 105))["isError"] as? Bool, true)
        try io.tool(106, "process_status", ["task_id": taskID, "work_id": workID])
        XCTAssertEqual(try structured(io.receive(id: 106))["work_id"] as? String, workID)
        let snapshot = try server.observerRequest(["action": "snapshot"])
        let parent = try XCTUnwrap((snapshot["work_items"] as? [JSONObject])?.first)
        XCTAssertEqual(parent["phase"] as? String, "executing")
        XCTAssertEqual(parent["job_ids"] as? [String], [taskID])
        try io.tool(107, "process_input", ["task_id": taskID, "work_id": workID, "content": "done\n", "close_stdin": true])
        let pair = try [io.receive(), io.receive()]
        XCTAssertEqual(Set(pair.compactMap { $0["id"] as? Int }), Set([103, 107]))
        for response in pair { XCTAssertEqual(try structured(response)["work_id"] as? String, workID) }
        try io.tool(108, "work_task", ["action": "finish", "work_id": workID])
        XCTAssertEqual(try structured(io.receive(id: 108))["state"] as? String, "completed")
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testWaitingCommandKeepsStdioResponsiveAndRejectsSecondLaunch() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("still-readable\n".utf8).write(to: f.workspace.appendingPathComponent("sample.txt"))
        let server = try makeServer(f)
        let io = CommandDispatchConnection(server); defer { io.close() }
        try io.initialize()
        let originalID = "command-run/one-\u{00E9}"
        try io.tool(originalID, "command_run", commandArguments(f))
        // Admission and launch must precede the next input frame. cat waits on
        // open stdin, so this is not a race against a conveniently slow command.
        try io.tool(2, "process_list", [:])
        let jobs = try XCTUnwrap(try structured(io.receive(id: 2))["processes"] as? [JSONObject])
        XCTAssertEqual(jobs.count, 1)
        let taskID = try XCTUnwrap(jobs.first?["task_id"] as? String)
        defer { _ = try? server.callTool(name: "process_cancel", arguments: ["task_id": taskID]) }
        XCTAssertEqual(jobs.first?["running"] as? Bool, true)

        try io.send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        try io.send(["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        try io.tool(5, "bridge_capabilities", [:])
        try io.tool(6, "process_status", ["task_id": taskID])
        try io.tool(7, "file_read", ["workspace_id": f.workspaceID, "path": "sample.txt"])
        try io.tool(8, "workspace_reload", [:])
        try io.tool(9, "command_run", commandArguments(f, executable: "true"))
        XCTAssertNotNil(try io.receive(id: 3)["result"])
        let catalog = try XCTUnwrap(try io.receive(id: 4)["result"] as? JSONObject)
        let tools = try XCTUnwrap(catalog["tools"] as? [JSONObject])
        XCTAssertEqual(tools.count, 72)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, 72)
        let capabilities = try structured(io.receive(id: 5))
        XCTAssertEqual(capabilities["catalog_count"] as? Int, 72)
        XCTAssertEqual(capabilities["catalog_sha256"] as? String, catalog["catalogEpoch"] as? String)
        XCTAssertEqual(try structured(io.receive(id: 6))["running"] as? Bool, true)
        let readFile = try XCTUnwrap(try structured(io.receive(id: 7))["file"] as? JSONObject)
        XCTAssertEqual(readFile["content"] as? String, "still-readable\n")
        XCTAssertEqual(try result(io.receive(id: 8))["isError"] as? Bool, true)
        let rejected = try io.receive(id: 9)
        XCTAssertEqual(try result(rejected)["isError"] as? Bool, true)
        XCTAssertTrue((try structured(rejected)["error"] as? String ?? "").contains("command_run"))
        try io.tool(10, "process_list", [:])
        let afterRejection = try XCTUnwrap(try structured(io.receive(id: 10))["processes"] as? [JSONObject])
        XCTAssertEqual(afterRejection.compactMap { $0["task_id"] as? String }, [taskID])

        let snapshot = try server.observerRequest(["action": "snapshot"])
        XCTAssertEqual(snapshot["busy"] as? Bool, false)
        XCTAssertEqual(snapshot["snapshot_stale"] as? Bool, false)
        XCTAssertTrue((snapshot["history"] as? [JSONObject] ?? []).contains {
            $0["tool"] as? String == "command_run" && $0["state"] as? String == "failed"
        }, "Admission rejection remains visible in Issues history")
        let observedJobs = try XCTUnwrap(snapshot["jobs"] as? [JSONObject])
        XCTAssertTrue(observedJobs.contains { $0["task_id"] as? String == taskID && $0["running"] as? Bool == true })

        // Release the same command through the protocol. The final response
        // may race the process_input receipt, but neither may be lost/replayed.
        try io.tool(11, "process_input", ["task_id": taskID, "content": "one real run\n", "close_stdin": true])
        let pair = try [io.receive(), io.receive()]
        let commandResponse = try XCTUnwrap(pair.first { $0["id"] as? String == originalID })
        let inputResponse = try XCTUnwrap(pair.first { $0["id"] as? Int == 11 })
        XCTAssertEqual(try structured(inputResponse)["input_complete"] as? Bool, true)
        let completed = try structured(commandResponse)
        XCTAssertEqual(completed["task_id"] as? String, taskID)
        XCTAssertEqual(completed["stdout"] as? String, "one real run\n")
        XCTAssertEqual(completed["stderr"] as? String, "")
        XCTAssertEqual(completed["exit_code"] as? Int, 0)
        XCTAssertEqual(completed["running"] as? Bool, false)
        XCTAssertEqual(completed["timed_out"] as? Bool, false)
        XCTAssertEqual(completed["cancelled"] as? Bool, false)
        XCTAssertEqual(completed["backend_called"] as? Bool, true)
        try io.tool(12, "workspace_reload", [:])
        XCTAssertEqual(try structured(io.receive(id: 12))["reloaded"] as? Bool, true)
        try io.tool(13, "command_run", commandArguments(f, executable: "true"))
        XCTAssertEqual(try structured(io.receive(id: 13))["exit_code"] as? Int, 0)
        XCTAssertTrue(try io.finishAndDrain().isEmpty, "No duplicate command response or unsolicited notification")
    }

    func testStdioCancelCompletesOriginalRequestAndKeepsSingleResponse() throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try makeServer(f)
        let io = CommandDispatchConnection(server); defer { io.close() }
        try io.initialize()
        try io.tool(21, "command_run", commandArguments(f))
        try io.tool(22, "process_list", [:])
        let rows = try XCTUnwrap(try structured(io.receive(id: 22))["processes"] as? [JSONObject])
        let taskID = try XCTUnwrap(rows.first?["task_id"] as? String)
        defer { _ = try? server.callTool(name: "process_cancel", arguments: ["task_id": taskID]) }
        try io.tool(23, "process_cancel", ["task_id": taskID])
        let pair = try [io.receive(), io.receive()]
        XCTAssertEqual(Set(pair.compactMap { $0["id"] as? Int }), Set([21, 23]))
        for response in pair {
            let value = try structured(response)
            XCTAssertEqual(value["task_id"] as? String, taskID)
            XCTAssertEqual(value["cancelled"] as? Bool, true)
            XCTAssertEqual(value["running"] as? Bool, false)
            XCTAssertEqual(value["timed_out"] as? Bool, false)
        }
        try io.tool(24, "process_status", ["task_id": taskID])
        XCTAssertEqual(try structured(io.receive(id: 24))["status_only"] as? Bool, true)
        try io.tool(25, "workspace_reload", [:])
        XCTAssertEqual(try structured(io.receive(id: 25))["reloaded"] as? Bool, true)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testEOFWaitsForTimedOutCommandAndPreservesWebResumeSession() throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try makeServer(f, surface: .webTunnel)
        let io = CommandDispatchConnection(server); defer { io.close() }
        // A resumed Web tunnel intentionally need not repeat initialize.
        try io.tool("eof-timeout", "command_run", commandArguments(f, timeout: 100))
        try io.endInput()
        let response = try io.receive(id: "eof-timeout")
        let value = try structured(response)
        XCTAssertEqual(try result(response)["isError"] as? Bool, false)
        XCTAssertEqual(value["timed_out"] as? Bool, true)
        XCTAssertEqual(value["running"] as? Bool, false)
        XCTAssertEqual(value["process_started"] as? Bool, true)
        XCTAssertEqual(value["stdout"] as? String, "")
        XCTAssertNotNil(value["exit_code"])
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
        XCTAssertNoThrow(try server.callTool(name: "workspace_reload", arguments: [:]))
    }

    func testDesktopSessionAndInvalidCommandAreRejectedBeforeLaunch() throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try makeServer(f)
        let io = CommandDispatchConnection(server); defer { io.close() }
        try io.tool(31, "command_run", commandArguments(f))
        let uninitialized = try io.receive(id: 31)
        XCTAssertNotNil(uninitialized["error"])
        XCTAssertTrue((try XCTUnwrap(server.callTool(name: "process_list", arguments: [:])["processes"] as? [JSONObject])).isEmpty)
        try io.initialize()
        try io.tool(32, "command_run", commandArguments(f, timeout: 99))
        XCTAssertEqual(try result(io.receive(id: 32))["isError"] as? Bool, true)
        var malformed = commandArguments(f)
        malformed["unexpected"] = true
        try io.tool(33, "command_run", malformed)
        XCTAssertEqual(try result(io.receive(id: 33))["isError"] as? Bool, true)
        try io.tool(34, "command_run", commandArguments(f, executable: "not-an-allowed-command"))
        XCTAssertEqual(try result(io.receive(id: 34))["isError"] as? Bool, true)
        try io.tool(35, "process_list", [:])
        XCTAssertTrue((try XCTUnwrap(try structured(io.receive(id: 35))["processes"] as? [JSONObject])).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.workspace.path).isEmpty)
        // Rejected requests must release admission; a later valid run works.
        try io.tool(36, "command_run", commandArguments(f, executable: "true"))
        XCTAssertEqual(try structured(io.receive(id: 36))["exit_code"] as? Int, 0)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testPreparedCommandPinsCompletedOutputAndBudgetUntilOriginalResult() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = LocalProcessService(workspaceService: try f.service(), selfExecutable: executable,
                                          outputByteLimit: 2048)
        let finish = try service.prepareCommandRun(workspaceID: f.workspaceID, executableID: "cat",
            arguments: [], cwd: ".", timeoutMilliseconds: 2_000, maximumOutputBytes: 1024)
        let rows = try XCTUnwrap(service.processList()["processes"] as? [JSONObject])
        let taskID = try XCTUnwrap(rows.first?["task_id"] as? String)
        defer { _ = try? service.cancelProcess(taskID: taskID) }
        _ = try service.processInput(taskID: taskID, content: "retained result\n", encoding: "utf8", closeStdin: true)
        try waitForExit(service, taskID)
        let drained = try service.processOutput(taskID: taskID, stdoutCursor: 0, stderrCursor: 0,
                                                maximumBytesPerStream: 1024)
        XCTAssertEqual(drained["stdout"] as? String, "retained result\n")
        XCTAssertEqual(drained["session_retained"] as? Bool, true)
        XCTAssertEqual(service.trackedProcessCount, 1)
        XCTAssertThrowsError(try service.startCommand(workspaceID: f.workspaceID, executableID: "true",
            arguments: [], cwd: ".", maximumOutputBytes: 1024))
        let original = finish()
        XCTAssertEqual(original["task_id"] as? String, taskID)
        XCTAssertEqual(original["stdout"] as? String, "retained result\n")
        XCTAssertEqual(original["exit_code"] as? Int, 0)
        XCTAssertEqual(service.trackedProcessCount, 0)
        XCTAssertEqual(try service.processStatus(taskID: taskID)["status_only"] as? Bool, true)
        let next = try service.runCommand(workspaceID: f.workspaceID, executableID: "true",
            arguments: [], cwd: ".", timeoutMilliseconds: 2_000, maximumOutputBytes: 1024)
        XCTAssertEqual(next["exit_code"] as? Int, 0)
        XCTAssertEqual(service.trackedProcessCount, 0)
    }

    func testPreparedCommandCancellationRetainsHandleUntilOriginalResult() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = LocalProcessService(workspaceService: try f.service(), selfExecutable: executable)
        let finish = try service.prepareCommandRun(workspaceID: f.workspaceID, executableID: "cat",
            arguments: [], cwd: ".", timeoutMilliseconds: 2_000, maximumOutputBytes: 1024)
        let rows = try XCTUnwrap(service.processList()["processes"] as? [JSONObject])
        let taskID = try XCTUnwrap(rows.first?["task_id"] as? String)
        let cancelled = try service.cancelProcess(taskID: taskID)
        XCTAssertEqual(cancelled["cancelled"] as? Bool, true)
        XCTAssertEqual(try service.processStatus(taskID: taskID)["session_retained"] as? Bool, true)
        XCTAssertEqual(service.trackedProcessCount, 1)
        let original = finish()
        XCTAssertEqual(original["task_id"] as? String, taskID)
        XCTAssertEqual(original["cancelled"] as? Bool, true)
        XCTAssertEqual(original["exit_code"] as? Int, cancelled["exit_code"] as? Int)
        XCTAssertEqual(service.trackedProcessCount, 0)
        XCTAssertEqual(try service.processStatus(taskID: taskID)["status_only"] as? Bool, true)
    }

    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/macbridge-mcp")
    }

    private func makeServer(_ f: Fixture, surface: MacBridgeConnectorSurface = .desktopLocal) throws -> LocalMCPServer {
        try LocalMCPServer(configurationURL: f.config, selfExecutable: executable,
                           connectorSurface: surface, observationEnabled: true)
    }

    private func commandArguments(_ f: Fixture, executable: String = "cat", timeout: Int = 10_000) -> JSONObject {
        ["workspace_id": f.workspaceID, "executable": executable, "arguments": [] as [String],
         "timeout_milliseconds": timeout, "maximum_output_bytes": 1024]
    }

    private func result(_ response: JSONObject) throws -> JSONObject {
        try XCTUnwrap(response["result"] as? JSONObject)
    }

    private func structured(_ response: JSONObject) throws -> JSONObject {
        try XCTUnwrap(try result(response)["structuredContent"] as? JSONObject)
    }

    private func waitForExit(_ service: LocalProcessService, _ taskID: String) throws {
        for _ in 0..<3 {
            let result = try service.observeProcess(taskID: taskID, maximumWaitMilliseconds: 1_000)
            if result["running"] as? Bool == false { return }
        }
        throw LocalMCPError.operationFailed("synthetic cat did not exit after stdin closed")
    }
}

private final class CommandDispatchConnection {
    private let input = Pipe(), output = Pipe()
    private let done = DispatchSemaphore(value: 0)
    private var received = Data()
    private var inputClosed = false
    private var outputClosed = false

    init(_ server: LocalMCPServer) {
        let readHandle = input.fileHandleForReading, writeHandle = output.fileHandleForWriting
        let completion = done
        DispatchQueue.global().async {
            defer { completion.signal() }
            do { try server.run(input: readHandle, output: writeHandle) }
            catch { XCTFail("server run failed: \(error)") }
        }
    }

    func initialize() throws {
        try send(["jsonrpc": "2.0", "id": "initialize", "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as JSONObject,
            "clientInfo": ["name": "command-dispatch-test", "version": "1"]] as JSONObject])
        XCTAssertNotNil(try receive(id: "initialize")["result"])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func send(_ request: JSONObject) throws {
        var bytes = try LocalJSON.encode(request); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    func tool(_ id: Any, _ name: String, _ arguments: JSONObject) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                  "params": ["name": name, "arguments": arguments] as JSONObject])
    }

    func receive(id: Any? = nil) throws -> JSONObject {
        while received.firstIndex(of: 10) == nil {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 2_000) > 0 else {
                throw LocalMCPError.operationFailed("stdio response blocked while command awaited completion")
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
            guard count > 0 else { throw LocalMCPError.operationFailed("response stream ended") }
            received.append(contentsOf: buffer.prefix(count))
        }
        let newline = received.firstIndex(of: 10)!
        let frame = Data(received.prefix(upTo: newline))
        received.removeSubrange(...newline)
        let response = try LocalJSON.decodeObject(frame)
        if let id = id as? Int { XCTAssertEqual(response["id"] as? Int, id) }
        if let id = id as? String { XCTAssertEqual(response["id"] as? String, id) }
        return response
    }

    func endInput() throws {
        if !inputClosed { try input.fileHandleForWriting.close(); inputClosed = true }
    }

    func finishAndDrain() throws -> [JSONObject] {
        try endInput()
        guard done.wait(timeout: .now() + 5) == .success else {
            throw LocalMCPError.operationFailed("stdio did not finish after admitted response completed")
        }
        done.signal()
        try output.fileHandleForWriting.close(); outputClosed = true
        received.append(output.fileHandleForReading.readDataToEndOfFile())
        let frames = try received.split(separator: 10).map { try LocalJSON.decodeObject(Data($0)) }
        received.removeAll()
        return frames
    }

    func close() {
        try? endInput()
        _ = done.wait(timeout: .now() + 5)
        if !outputClosed { try? output.fileHandleForWriting.close(); outputClosed = true }
        try? output.fileHandleForReading.close()
        try? input.fileHandleForReading.close()
    }
}
