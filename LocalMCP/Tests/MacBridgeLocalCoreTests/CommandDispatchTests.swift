import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class CommandDispatchTests: XCTestCase {
    func testOutstandingResponseBudgetIsFixedAndBalanced() {
        let responses = PendingToolResponses()
        for index in 0..<PendingToolResponses.maximumOutstanding {
            XCTAssertTrue(responses.reserve(), "reservation \(index) should fit")
        }
        XCTAssertEqual(responses.outstandingCount, PendingToolResponses.maximumOutstanding)
        XCTAssertFalse(responses.reserve(), "the first response beyond the fixed budget must fail fast")
        for _ in 0..<PendingToolResponses.maximumOutstanding { responses.release() }
        XCTAssertEqual(responses.outstandingCount, 0)
        XCTAssertTrue(responses.reserve(), "the budget must recover after delivery")
        responses.release()

        let attempted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let admissions = LockedTestCounter()
        for _ in 0..<(PendingToolResponses.maximumOutstanding * 2) {
            group.enter()
            DispatchQueue.global().async {
                if responses.reserve() {
                    admissions.increment()
                    attempted.signal()
                    release.wait()
                    responses.release()
                } else {
                    attempted.signal()
                }
                group.leave()
            }
        }
        for _ in 0..<(PendingToolResponses.maximumOutstanding * 2) {
            XCTAssertEqual(attempted.wait(timeout: .now() + 5), .success)
        }
        let concurrentAdmissions = admissions.value
        XCTAssertEqual(concurrentAdmissions, PendingToolResponses.maximumOutstanding)
        XCTAssertEqual(responses.outstandingCount, PendingToolResponses.maximumOutstanding)
        for _ in 0..<concurrentAdmissions { release.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(responses.outstandingCount, 0)
    }

    func testOutstandingResponseByteBudgetIsFixedAndBalanced() {
        let responses = PendingToolResponses()
        let half = PendingToolResponses.maximumEstimatedBytes / 2
        XCTAssertTrue(responses.reserve(estimatedBytes: half))
        XCTAssertTrue(responses.reserve(
            estimatedBytes: PendingToolResponses.maximumEstimatedBytes - half
        ))
        XCTAssertEqual(responses.estimatedByteCount, PendingToolResponses.maximumEstimatedBytes)
        XCTAssertFalse(responses.reserve(estimatedBytes: 1))
        responses.release(estimatedBytes: half)
        XCTAssertTrue(responses.reserve(estimatedBytes: 1))
        responses.release(estimatedBytes: 1)
        responses.release(estimatedBytes: PendingToolResponses.maximumEstimatedBytes - half)
        XCTAssertEqual(responses.estimatedByteCount, 0)
        XCTAssertEqual(responses.outstandingCount, 0)
    }

    func testUndrainedOutputStopsAdmissionAtTheFixedResponseBudget() throws {
        let f = try Fixture(); defer { f.remove() }
        let entered = DispatchSemaphore(value: 0)
        let server = try makeServer(f, developerInspectionStartForTesting: { entered.signal() })
        let io = CommandDispatchConnection(server); defer { io.close() }
        try io.initialize()
        let fillerBytes = try io.saturateOutputPipe()
        XCTAssertGreaterThan(fillerBytes, 0)

        let requestCount = PendingToolResponses.maximumOutstanding + 1
        for id in 0..<PendingToolResponses.maximumOutstanding {
            try io.tool("backpressure/\(id)", "developer_inspect", [
                "action": "inspect_repo", "workspace_id": f.workspaceID,
            ])
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            var executionLeaseReleased = false
            for _ in 0..<2_000 {
                let capabilities = try server.callTool(name: "bridge_capabilities", arguments: [:])
                if capabilities["active_developer_inspections"] as? Int == 0 {
                    executionLeaseReleased = true
                    break
                }
                usleep(1_000)
            }
            XCTAssertTrue(executionLeaseReleased,
                          "completed execution must release its family lease before stdout drains")
        }
        try io.tool("backpressure/overflow", "developer_inspect", [
            "action": "inspect_repo", "workspace_id": f.workspaceID,
        ])
        XCTAssertEqual(entered.wait(timeout: .now() + 0.25), .timedOut,
                       "a stalled adapter must not admit an unbounded reply backlog")

        try io.drainOutputPrefix(byteCount: fillerBytes)
        var replies: [JSONObject] = []
        for _ in 0..<requestCount { replies.append(try io.receive()) }
        XCTAssertEqual(Set(replies.compactMap { $0["id"] as? String }).count, requestCount)
        XCTAssertTrue(replies.contains { response in
            guard let result = response["result"] as? JSONObject,
                  result["isError"] as? Bool == true,
                  let structured = result["structuredContent"] as? JSONObject,
                  let error = structured["error"] as? String else { return false }
            return error.contains("response delivery budget")
        })
        XCTAssertTrue(try io.finishAndDrain().isEmpty,
                      "every admitted or rejected request must receive exactly one reply")
    }

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

    func testEightWaitingCommandsKeepStdioResponsiveAndRejectNinthLaunch() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("still-readable\n".utf8).write(to: f.workspace.appendingPathComponent("sample.txt"))
        let server = try makeServer(f)
        let io = CommandDispatchConnection(server); defer { io.close() }
        try io.initialize()
        let commandIDs = (0..<8).map { "command-run/\($0)" }
        for id in commandIDs { try io.tool(id, "command_run", commandArguments(f)) }
        // Admission and launch happen in input order. Each cat waits on open
        // stdin, so eight occupied slots are deterministic rather than a race
        // against conveniently slow commands.
        try io.tool(2, "process_list", [:])
        let jobs = try XCTUnwrap(try structured(io.receive(id: 2))["processes"] as? [JSONObject])
        XCTAssertEqual(jobs.count, 8)
        let taskIDs = jobs.compactMap { $0["task_id"] as? String }
        XCTAssertEqual(taskIDs.count, 8)
        defer {
            for taskID in taskIDs {
                _ = try? server.callTool(name: "process_cancel", arguments: ["task_id": taskID])
            }
        }
        XCTAssertTrue(jobs.allSatisfy { $0["running"] as? Bool == true })

        try io.send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        try io.send(["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        try io.tool(5, "bridge_capabilities", [:])
        try io.tool(6, "process_status", ["task_id": taskIDs[0]])
        try io.tool(7, "file_read", ["workspace_id": f.workspaceID, "path": "sample.txt"])
        try io.tool(8, "workspace_reload", [:])
        try io.tool(9, "command_run", commandArguments(f, executable: "true"))
        XCTAssertNotNil(try io.receive(id: 3)["result"])
        let catalog = try XCTUnwrap(try io.receive(id: 4)["result"] as? JSONObject)
        let tools = try XCTUnwrap(catalog["tools"] as? [JSONObject])
        XCTAssertEqual(tools.count, 76)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, 76)
        let capabilities = try structured(io.receive(id: 5))
        XCTAssertEqual(capabilities["catalog_count"] as? Int, 76)
        XCTAssertEqual(capabilities["catalog_sha256"] as? String, catalog["catalogEpoch"] as? String)
        XCTAssertEqual(capabilities["active_command_runs"] as? Int, 8)
        XCTAssertEqual(capabilities["maximum_concurrent_command_runs"] as? Int, 8)
        let processActivity = try XCTUnwrap(capabilities["process_activity"] as? JSONObject)
        XCTAssertEqual(processActivity["running"] as? Int, 8)
        XCTAssertEqual(processActivity["retained_handles"] as? Int, 8)
        XCTAssertEqual(processActivity["completed_retained_handles"] as? Int, 0)
        XCTAssertEqual(try structured(io.receive(id: 6))["running"] as? Bool, true)
        let readFile = try XCTUnwrap(try structured(io.receive(id: 7))["file"] as? JSONObject)
        XCTAssertEqual(readFile["content"] as? String, "still-readable\n")
        XCTAssertEqual(try result(io.receive(id: 8))["isError"] as? Bool, true)
        let rejected = try io.receive(id: 9)
        XCTAssertEqual(try result(rejected)["isError"] as? Bool, true)
        XCTAssertTrue((try structured(rejected)["error"] as? String ?? "").contains("command_run"))
        try io.tool(10, "process_list", [:])
        let afterRejection = try XCTUnwrap(try structured(io.receive(id: 10))["processes"] as? [JSONObject])
        XCTAssertEqual(Set(afterRejection.compactMap { $0["task_id"] as? String }), Set(taskIDs))

        let snapshot = try server.observerRequest(["action": "snapshot"])
        XCTAssertEqual(snapshot["busy"] as? Bool, false)
        XCTAssertEqual(snapshot["snapshot_stale"] as? Bool, false)
        XCTAssertTrue((snapshot["history"] as? [JSONObject] ?? []).contains {
            $0["tool"] as? String == "command_run" && $0["state"] as? String == "failed"
        }, "Admission rejection remains visible in Issues history")
        let observedJobs = try XCTUnwrap(snapshot["jobs"] as? [JSONObject])
        XCTAssertEqual(Set(observedJobs.filter { $0["running"] as? Bool == true }
            .compactMap { $0["task_id"] as? String }), Set(taskIDs))

        // Release all eight through the protocol. Command and input responses
        // may interleave, but every request must receive exactly one response.
        for (index, taskID) in taskIDs.enumerated() {
            try io.tool(20 + index, "process_input", [
                "task_id": taskID, "content": "run-\(index)\n", "close_stdin": true,
            ])
        }
        let completions = try (0..<16).map { _ in try io.receive() }
        XCTAssertEqual(Set(completions.compactMap { $0["id"] as? String }), Set(commandIDs))
        XCTAssertEqual(Set(completions.compactMap { $0["id"] as? Int }), Set(20..<28))
        for response in completions where response["id"] is Int {
            XCTAssertEqual(try structured(response)["input_complete"] as? Bool, true)
        }
        let commandResponses = completions.filter { $0["id"] is String }
        XCTAssertEqual(commandResponses.count, 8)
        for response in commandResponses {
            let completed = try structured(response)
            XCTAssertTrue(taskIDs.contains(try XCTUnwrap(completed["task_id"] as? String)))
            XCTAssertTrue((completed["stdout"] as? String ?? "").hasPrefix("run-"))
            XCTAssertEqual(completed["stderr"] as? String, "")
            XCTAssertEqual(completed["exit_code"] as? Int, 0)
            XCTAssertEqual(completed["running"] as? Bool, false)
            XCTAssertEqual(completed["timed_out"] as? Bool, false)
            XCTAssertEqual(completed["cancelled"] as? Bool, false)
            XCTAssertEqual(completed["backend_called"] as? Bool, true)
        }
        try io.tool(30, "workspace_reload", [:])
        XCTAssertEqual(try structured(io.receive(id: 30))["reloaded"] as? Bool, true)
        try io.tool(31, "command_run", commandArguments(f, executable: "true"))
        XCTAssertEqual(try structured(io.receive(id: 31))["exit_code"] as? Int, 0)
        XCTAssertTrue(try io.finishAndDrain().isEmpty, "No duplicate command response or unsolicited notification")
    }

    func testEightStalledDeveloperInspectionsDoNotStarveOtherChatsOrQueueANinth() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("inspection-independent\n".utf8).write(
            to: f.workspace.appendingPathComponent("sample.txt")
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try makeServer(f, developerInspectionStartForTesting: {
            entered.signal()
            release.wait()
        })
        let io = CommandDispatchConnection(server)
        defer {
            for _ in 0..<8 { release.signal() }
            io.close()
        }
        try io.initialize()
        let inspectionIDs = (0..<8).map { "developer-inspect/\($0)" }
        for id in inspectionIDs {
            try io.tool(id, "developer_inspect", [
                "action": "inspect_repo", "workspace_id": f.workspaceID,
            ])
        }
        for _ in inspectionIDs {
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        }

        try io.send(["jsonrpc": "2.0", "id": 100, "method": "ping"])
        try io.tool(101, "bridge_capabilities", [:])
        try io.tool(102, "file_read", ["workspace_id": f.workspaceID, "path": "sample.txt"])
        try io.tool(103, "workspace_reload", [:])
        try io.tool(104, "developer_inspect", [
            "action": "inspect_repo", "workspace_id": f.workspaceID,
        ])
        var quick: [Int: JSONObject] = [:]
        for _ in 0..<5 {
            let response = try io.receive()
            quick[try XCTUnwrap(response["id"] as? Int)] = response
        }
        XCTAssertEqual(Set(quick.keys), Set(100...104))
        XCTAssertNotNil(quick[100]?["result"])
        let capabilities = try structured(XCTUnwrap(quick[101]))
        XCTAssertEqual(capabilities["developer_inspect_nonblocking_dispatch"] as? Bool, true)
        XCTAssertEqual(capabilities["active_developer_inspections"] as? Int, 8)
        XCTAssertEqual(capabilities["maximum_concurrent_developer_inspections"] as? Int, 8)
        XCTAssertEqual(
            (try structured(XCTUnwrap(quick[102]))["file"] as? JSONObject)?["content"] as? String,
            "inspection-independent\n"
        )
        XCTAssertEqual(try result(XCTUnwrap(quick[103]))["isError"] as? Bool, true)
        let rejected = try XCTUnwrap(quick[104])
        XCTAssertEqual(try result(rejected)["isError"] as? Bool, true)
        XCTAssertTrue((try structured(rejected)["error"] as? String ?? "").contains("developer inspections"))

        for _ in inspectionIDs { release.signal() }
        let completions = try inspectionIDs.map { _ in try io.receive() }
        XCTAssertEqual(Set(completions.compactMap { $0["id"] as? String }), Set(inspectionIDs))
        for response in completions {
            XCTAssertEqual(
                try result(response)["isError"] as? Bool, false,
                "response=\(response)"
            )
            XCTAssertEqual(try structured(response)["developer_action"] as? String, "inspect_repo")
        }
        try io.tool(105, "bridge_capabilities", [:])
        XCTAssertEqual(try structured(io.receive(id: 105))["active_developer_inspections"] as? Int, 0)
        try io.tool(106, "workspace_reload", [:])
        XCTAssertEqual(try structured(io.receive(id: 106))["reloaded"] as? Bool, true)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testEightStalledProcessWaitsDoNotStarvePingAndRejectANinth() throws {
        let f = try Fixture(); defer { f.remove() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try makeServer(f, surface: .webTunnel, processWaitStartForTesting: {
            entered.signal()
            release.wait()
        })
        let process = try server.callTool(name: "command_start", arguments: [
            "workspace_id": f.workspaceID, "executable": "cat", "arguments": [] as [String],
        ])
        let taskID = try XCTUnwrap(process["task_id"] as? String)
        let processToken = try XCTUnwrap(process["process_control_token"] as? String)
        let io = CommandDispatchConnection(server)
        defer {
            for _ in 0..<8 { release.signal() }
            _ = try? server.callTool(name: "process_cancel", arguments: [
                "task_id": taskID, "process_control_token": processToken,
            ])
            io.close()
        }
        try io.initialize()
        let waitIDs = (0..<8).map { "process-wait/\($0)" }
        for id in waitIDs {
            try io.tool(id, "process_wait", [
                "task_id": taskID, "process_control_token": processToken,
                "maximum_wait_milliseconds": 0,
            ])
        }
        for _ in waitIDs {
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        }

        try io.send(["jsonrpc": "2.0", "id": 200, "method": "ping"])
        try io.tool(201, "bridge_capabilities", [:])
        try io.tool(202, "workspace_reload", [:])
        try io.tool(203, "process_wait", [
            "task_id": taskID, "process_control_token": processToken,
            "maximum_wait_milliseconds": 0,
        ])
        var quick: [Int: JSONObject] = [:]
        for _ in 0..<4 {
            let response = try io.receive()
            quick[try XCTUnwrap(response["id"] as? Int)] = response
        }
        XCTAssertEqual(Set(quick.keys), Set(200...203))
        XCTAssertNotNil(quick[200]?["result"])
        let capabilities = try structured(XCTUnwrap(quick[201]))
        XCTAssertEqual(capabilities["process_wait_nonblocking_dispatch"] as? Bool, true)
        XCTAssertEqual(capabilities["active_process_waits"] as? Int, 8)
        XCTAssertEqual(capabilities["maximum_concurrent_process_waits"] as? Int, 8)
        XCTAssertEqual(try result(XCTUnwrap(quick[202]))["isError"] as? Bool, true)
        let rejected = try XCTUnwrap(quick[203])
        XCTAssertEqual(try result(rejected)["isError"] as? Bool, true)
        XCTAssertTrue((try structured(rejected)["error"] as? String ?? "").contains("process waits"))

        for _ in waitIDs { release.signal() }
        let completions = try waitIDs.map { _ in try io.receive() }
        XCTAssertEqual(Set(completions.compactMap { $0["id"] as? String }), Set(waitIDs))
        for response in completions {
            let value = try structured(response)
            XCTAssertEqual(try result(response)["isError"] as? Bool, false)
            XCTAssertEqual(value["task_id"] as? String, taskID)
            XCTAssertEqual(value["running"] as? Bool, true)
            XCTAssertEqual(value["observation_timed_out"] as? Bool, true)
        }
        XCTAssertEqual(try server.callTool(name: "bridge_capabilities", arguments: [:])[
            "active_process_waits"
        ] as? Int, 0)
        _ = try server.callTool(name: "process_cancel", arguments: [
            "task_id": taskID, "process_control_token": processToken,
        ])
        XCTAssertNoThrow(try server.callTool(name: "workspace_reload", arguments: [:]))
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
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

    func testIdentifiedPreparedCommandReturnsItsOwnJobAmongAdjacentLaunches() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = LocalProcessService(workspaceService: try f.service(), selfExecutable: executable)
        let unrelated = try service.startCommand(
            workspaceID: f.workspaceID, executableID: "cat", arguments: [], cwd: ".",
            maximumOutputBytes: 1024
        )
        let unrelatedID = try XCTUnwrap(unrelated["task_id"] as? String)
        let prepared = try service.prepareIdentifiedCommandRun(
            workspaceID: f.workspaceID, executableID: "cat", arguments: [], cwd: ".",
            timeoutMilliseconds: 2_000, maximumOutputBytes: 1024
        )
        defer {
            _ = try? service.cancelProcess(taskID: unrelatedID)
            _ = try? service.cancelProcess(taskID: prepared.taskID)
        }
        XCTAssertNotEqual(prepared.taskID, unrelatedID)
        XCTAssertEqual(Set((service.processList()["processes"] as? [JSONObject] ?? [])
            .compactMap { $0["task_id"] as? String }), Set([unrelatedID, prepared.taskID]))

        _ = try service.processInput(
            taskID: prepared.taskID, content: "owned\n", encoding: "utf8", closeStdin: true
        )
        let result = prepared.finish()
        XCTAssertEqual(result["task_id"] as? String, prepared.taskID)
        XCTAssertEqual(result["stdout"] as? String, "owned\n")
        XCTAssertEqual(result["exit_code"] as? Int, 0)
        XCTAssertEqual(try service.processStatus(taskID: unrelatedID)["running"] as? Bool, true)
    }

    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/macbridge-mcp")
    }

    private func makeServer(
        _ f: Fixture, surface: MacBridgeConnectorSurface = .desktopLocal,
        developerInspectionStartForTesting: (@Sendable () -> Void)? = nil,
        processWaitStartForTesting: (@Sendable () -> Void)? = nil
    ) throws -> LocalMCPServer {
        try LocalMCPServer(
            configurationURL: f.config, selfExecutable: executable,
            connectorSurface: surface, observationEnabled: true, searchStartForTesting: nil,
            developerInspectionStartForTesting: developerInspectionStartForTesting,
            processWaitStartForTesting: processWaitStartForTesting
        )
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

private final class LockedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
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

    /// Fill the response pipe without adding a JSON frame, then restore normal
    /// blocking writes. The server's next response is therefore known to stall
    /// until drainOutputPrefix removes these exact bytes.
    func saturateOutputPipe() throws -> Int {
        let descriptor = output.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalMCPError.operationFailed("could not configure the synthetic response pipe")
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        let chunk = [UInt8](repeating: 0x20, count: 4_096)
        var total = 0
        while true {
            let written = chunk.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            }
            if written > 0 { total += written; continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { return total }
            throw LocalMCPError.operationFailed("could not fill the synthetic response pipe")
        }
    }

    func drainOutputPrefix(byteCount: Int) throws {
        var remaining = byteCount
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while remaining > 0 {
            let requested = min(remaining, chunk.count)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &chunk, requested)
            guard count > 0 else {
                throw LocalMCPError.operationFailed("synthetic response-pipe prefix ended early")
            }
            remaining -= count
        }
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
        if let id = id as? Int {
            let actualID = response["id"]
            XCTAssertEqual(actualID as? Int, id,
                           "received response id \(String(describing: actualID))")
        }
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
