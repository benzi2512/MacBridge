import Darwin
import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class ServerAndProcessTests: XCTestCase {
    func testCommandProfileUsesPrivateLocalCreationAndCleansUp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(workspaceService: try fixture.service(), selfExecutable: try testBinary())
        let started = try processes.startCommand(workspaceID: fixture.workspaceID,
            executableID: "cat", arguments: [], cwd: ".", maximumOutputBytes: 1_024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? processes.cancelProcess(taskID: id) }
        let profile = fixture.workspace.appendingPathComponent(".macbridge/runtime/\(id)/command.sb")
        let metadata = try lstatValue(profile.path)
        XCTAssertEqual(metadata.st_mode & S_IFMT, mode_t(S_IFREG))
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(metadata.st_uid, getuid())
        XCTAssertTrue(try String(contentsOf: profile, encoding: .utf8).hasPrefix("(version 1)"))
        _ = try processes.cancelProcess(taskID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }

    func testStdioRequestPoolsPreserveUndoAcrossFramesAndEOF() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let baseline = Data((String(repeating: "🙂", count: 65_536) + "before").utf8)
        let target = fixture.workspace.appendingPathComponent("retained.txt")
        try baseline.write(to: target)
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )

        func exchange(_ name: String, _ messages: [JSONObject], finalNewline: Bool) throws -> [JSONObject] {
            let inputURL = fixture.root.appendingPathComponent("\(name)-input.jsonl")
            let outputURL = fixture.root.appendingPathComponent("\(name)-output.jsonl")
            var bytes = Data()
            for (index, message) in messages.enumerated() {
                bytes.append(try LocalJSON.encode(message))
                if finalNewline || index + 1 < messages.count { bytes.append(0x0A) }
            }
            try bytes.write(to: inputURL)
            try Data().write(to: outputURL)
            let input = try FileHandle(forReadingFrom: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? input.close(); try? output.close() }
            try server.run(input: input, output: output)
            try output.synchronize()
            return try Data(contentsOf: outputURL).split(separator: 0x0A).map {
                try LocalJSON.decodeObject(Data($0))
            }
        }

        let changed = try exchange("patch", [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18", "capabilities": [:] as JSONObject,
                "clientInfo": ["name": "request-pool-test", "version": "1"]] as JSONObject],
            ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:] as JSONObject],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "file_patch", "arguments": [
                    "workspace_id": fixture.workspaceID, "path": "retained.txt",
                    "old_text": "before", "new_text": "after",
                    "expected_sha256": LocalHash.sha256(baseline)] as JSONObject] as JSONObject],
        ], finalNewline: true)
        XCTAssertEqual(changed.count, 2)
        let patch = try XCTUnwrap(changed.last?["result"] as? JSONObject)
        XCTAssertEqual(patch["isError"] as? Bool, false)
        let patchData = try XCTUnwrap(patch["structuredContent"] as? JSONObject)
        let transaction = try XCTUnwrap(patchData["transaction_id"] as? String)
        XCTAssertNotEqual(try Data(contentsOf: target), baseline)

        // Restore in a later run call, with its final frame delivered by EOF.
        // This exercises retained data after the earlier request pool drained.
        let restored = try exchange("restore", [
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                "name": "transaction_restore", "arguments": ["transaction_id": transaction]] as JSONObject],
        ], finalNewline: false)
        XCTAssertEqual(restored.count, 1)
        let response = try XCTUnwrap(restored.first?["result"] as? JSONObject)
        XCTAssertEqual(response["isError"] as? Bool, false)
        let receipt = try XCTUnwrap(response["structuredContent"] as? JSONObject)
        XCTAssertEqual(receipt["backend_called"] as? Bool, true)
        XCTAssertEqual(receipt["mutation_performed"] as? Bool, true)
        // Direct readback, not a field only supplied by the observer wrapper.
        XCTAssertEqual(try Data(contentsOf: target), baseline)
    }

    func testCompletedCommandsReleasePipeReadHandlers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )

        _ = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "true",
            arguments: [],
            cwd: ".",
            timeoutMilliseconds: 5_000,
            maximumOutputBytes: 1_024
        )
        Thread.sleep(forTimeInterval: 0.1)
        let baseline = try currentThreadCount()

        for _ in 0..<16 {
            _ = try processes.runCommand(
                workspaceID: fixture.workspaceID,
                executableID: "true",
                arguments: [],
                cwd: ".",
                timeoutMilliseconds: 5_000,
                maximumOutputBytes: 1_024
            )
        }
        // Dispatch workers are reusable and can remain parked briefly after a
        // burst. Keep the leak threshold strict, but allow a bounded settling
        // window instead of sampling one scheduler instant.
        let deadline = Date().addingTimeInterval(2)
        var settled = try currentThreadCount()
        while settled > baseline + 8, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            settled = try currentThreadCount()
        }

        XCTAssertLessThanOrEqual(
            settled,
            baseline + 8,
            "completed stdout/stderr handlers leaked dispatch workers: baseline=\(baseline), settled=\(settled)"
        )
    }

    func testServerRecoversAtNextFrameAfterOversizedInput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inputURL = fixture.root.appendingPathComponent("oversized-input.jsonl")
        let outputURL = fixture.root.appendingPathComponent("oversized-output.jsonl")
        var inputData = Data(repeating: 0x78, count: LocalMCPServer.maximumFrameBytes + 1_024)
        inputData.append(0x0A)
        inputData.append(
            try LocalJSON.encode(
                [
                    "jsonrpc": "2.0", "id": 77, "method": "ping",
                    "params": [:] as JSONObject,
                ] as JSONObject)
        )
        inputData.append(0x0A)
        try inputData.write(to: inputURL)
        try Data().write(to: outputURL)

        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try server.run(input: input, output: output)
        try output.synchronize()

        let responseLines = try Data(contentsOf: outputURL).split(separator: 0x0A)
        XCTAssertEqual(responseLines.count, 2)
        guard responseLines.count == 2 else { return }
        let oversized = try LocalJSON.decodeObject(Data(responseLines[0]))
        XCTAssertEqual((oversized["error"] as? JSONObject)?["code"] as? Int, -32_600)
        let recovered = try LocalJSON.decodeObject(Data(responseLines[1]))
        XCTAssertEqual(recovered["id"] as? Int, 77)
        XCTAssertNotNil(recovered["result"])
    }

    func testServerAcceptsMultiMegabyteFrameAndSurvivesMalformedFrame() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inputURL = fixture.root.appendingPathComponent("mcp-input.jsonl")
        let outputURL = fixture.root.appendingPathComponent("mcp-output.jsonl")
        let largeContent = String(repeating: "z", count: 3 * 1_024 * 1_024)
        let messages: [JSONObject] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:] as JSONObject,
                    "clientInfo": ["name": "frame-test", "version": "1"] as JSONObject,
                ] as JSONObject,
            ],
            [
                "jsonrpc": "2.0", "method": "notifications/initialized",
                "params": [:] as JSONObject,
            ],
            [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": [
                    "name": "file_write",
                    "arguments": [
                        "workspace_id": fixture.workspaceID,
                        "path": "large.txt",
                        "content": largeContent,
                    ] as JSONObject,
                ] as JSONObject,
            ],
        ]
        var inputData = Data("{malformed}\n".utf8)
        for message in messages {
            inputData.append(try LocalJSON.encode(message))
            inputData.append(0x0A)
        }
        try inputData.write(to: inputURL)
        try Data().write(to: outputURL)

        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try server.run(input: input, output: output)
        try output.synchronize()

        let responseData = try Data(contentsOf: outputURL)
        let responseLines = responseData.split(separator: 0x0A)
        XCTAssertEqual(responseLines.count, 3)
        let malformed = try LocalJSON.decodeObject(Data(responseLines[0]))
        XCTAssertEqual((malformed["error"] as? JSONObject)?["code"] as? Int, -32_700)
        let call = try LocalJSON.decodeObject(Data(responseLines[2]))
        let result = try XCTUnwrap(call["result"] as? JSONObject)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(
            try Data(contentsOf: fixture.workspace.appendingPathComponent("large.txt")).count,
            largeContent.utf8.count
        )
    }

    func testMCPHandshakeCatalogCapabilitiesAndDirectWriteRollback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.workspace.appendingPathComponent("mutation.txt")
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: target)
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let initialized = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:] as JSONObject,
                    "clientInfo": ["name": "tests", "version": "1"] as JSONObject,
                ] as JSONObject,
            ]))
        XCTAssertNotNil(initialized["result"])
        XCTAssertNil(
            server.handle([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:] as JSONObject,
            ]))
        let listed = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0", "id": 2, "method": "tools/list",
                "params": [:] as JSONObject,
            ]))
        let result = try XCTUnwrap(listed["result"] as? JSONObject)
        XCTAssertEqual((result["tools"] as? [JSONObject])?.count, 70)

        let capabilities = try server.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(capabilities["chatgpt_mode"] as? String, "CHATGPT_FULL")
        XCTAssertEqual(capabilities["connector_surface"] as? String, "CHATGPT_DESKTOP_LOCAL")
        XCTAssertEqual(capabilities["transport"] as? String, "local_stdio")
        XCTAssertEqual(capabilities["runtime_architecture"] as? String, "single_process")
        XCTAssertEqual(capabilities["outbound_tunnel_adapter"] as? Bool, false)
        XCTAssertEqual(capabilities["public_listener"] as? Bool, false)
        XCTAssertEqual(capabilities["xpc_used"] as? Bool, false)
        XCTAssertEqual(capabilities["keychain_used"] as? Bool, false)
        XCTAssertEqual(capabilities["terminal_window_opened"] as? Bool, false)
        XCTAssertEqual(capabilities["network_default"] as? String, "loopback_only")

        let write = try server.callTool(
            name: "file_write",
            arguments: [
                "workspace_id": fixture.workspaceID,
                "path": "mutation.txt",
                "content": "direct\n",
                "expected_sha256": LocalHash.sha256(baseline),
            ]
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "direct\n")
        let restored = try server.callTool(
            name: "transaction_restore",
            arguments: ["transaction_id": try XCTUnwrap(write["transaction_id"] as? String)]
        )
        XCTAssertEqual(restored["mutation_performed"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: target), baseline)
    }

    func testRollbackAnnotationIsNonDestructiveWithoutWeakeningRemove() throws {
        let restore = try XCTUnwrap(
            LocalMCPServer.toolSpecs.first { $0["name"] as? String == "transaction_restore" }
        )
        let restoreAnnotations = try XCTUnwrap(restore["annotations"] as? JSONObject)
        XCTAssertEqual(restoreAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(restoreAnnotations["destructiveHint"] as? Bool, false)
        XCTAssertEqual(restoreAnnotations["idempotentHint"] as? Bool, false)
        XCTAssertEqual(restoreAnnotations["openWorldHint"] as? Bool, false)

        let remove = try XCTUnwrap(
            LocalMCPServer.toolSpecs.first { $0["name"] as? String == "path_remove" }
        )
        let removeAnnotations = try XCTUnwrap(remove["annotations"] as? JSONObject)
        XCTAssertEqual(removeAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(removeAnnotations["destructiveHint"] as? Bool, true)
    }

    func testWebTunnelSurfaceUsesSameCatalogAndReportsOnlyAnOutboundAdapter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let direct = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: executable
        )
        let web = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: executable,
            connectorSurface: .webTunnel
        )

        let directCapabilities = try direct.callTool(
            name: "bridge_capabilities", arguments: [:]
        )
        let webCapabilities = try web.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(webCapabilities["chatgpt_mode"] as? String, "CHATGPT_FULL")
        XCTAssertEqual(webCapabilities["connector_surface"] as? String, "CHATGPT_WEB_TUNNEL")
        XCTAssertEqual(webCapabilities["transport"] as? String, "outbound_tunnel_stdio")
        XCTAssertEqual(webCapabilities["runtime_profile"] as? String, "web-tunnel-adapter")
        XCTAssertEqual(
            webCapabilities["runtime_architecture"] as? String,
            "single_process_core_plus_outbound_adapter"
        )
        XCTAssertEqual(webCapabilities["connector_network"] as? String, "outbound_tunnel_only")
        XCTAssertEqual(webCapabilities["outbound_tunnel_adapter"] as? Bool, true)
        XCTAssertEqual(webCapabilities["public_listener"] as? Bool, false)
        XCTAssertEqual(webCapabilities["daemon_used"] as? Bool, false)
        XCTAssertEqual(webCapabilities["xpc_used"] as? Bool, false)
        XCTAssertEqual(webCapabilities["keychain_used"] as? Bool, false)
        XCTAssertEqual(
            webCapabilities["mcp_executable_sha256"] as? String,
            directCapabilities["mcp_executable_sha256"] as? String
        )
        XCTAssertEqual(
            webCapabilities["catalog_sha256"] as? String,
            directCapabilities["catalog_sha256"] as? String
        )

        let discovered = try XCTUnwrap(
            web.handle([
                "jsonrpc": "2.0", "id": 1, "method": "server/discover",
                "params": [:] as JSONObject,
            ])
        )
        let result = try XCTUnwrap(discovered["result"] as? JSONObject)
        let connection = try XCTUnwrap(result["connection"] as? JSONObject)
        XCTAssertEqual(connection["surface"] as? String, "CHATGPT_WEB_TUNNEL")
        XCTAssertEqual(connection["transport"] as? String, "outbound_tunnel_stdio")
        XCTAssertEqual(connection["publicListener"] as? Bool, false)
    }

    func testWebTunnelAcceptsStatelessCatalogAndToolCallsAfterAdapterReconnect() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel
        )

        let listed = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0", "id": 1, "method": "tools/list",
                "params": [:] as JSONObject,
            ])
        )
        let listResult = try XCTUnwrap(listed["result"] as? JSONObject)
        XCTAssertEqual((listResult["tools"] as? [JSONObject])?.count, 70)

        let called = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": [
                    "name": "bridge_capabilities",
                    "arguments": [:] as JSONObject,
                ] as JSONObject,
            ])
        )
        let callResult = try XCTUnwrap(called["result"] as? JSONObject)
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        let structured = try XCTUnwrap(callResult["structuredContent"] as? JSONObject)
        XCTAssertEqual(structured["connector_surface"] as? String, "CHATGPT_WEB_TUNNEL")
        XCTAssertEqual(structured["chatgpt_mode"] as? String, "CHATGPT_FULL")
    }

    func testDesktopLocalStillRequiresInitializationBeforeCatalogAccess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )

        let response = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0", "id": 1, "method": "tools/list",
                "params": [:] as JSONObject,
            ])
        )
        let error = try XCTUnwrap(response["error"] as? JSONObject)
        XCTAssertEqual(error["code"] as? Int, -32_602)
        XCTAssertEqual(error["message"] as? String, "MCP session is not initialized.")
    }

    func testWorkspaceConfigurationReloadsWithoutServerRestart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let before = try server.callTool(name: "workspace_overview", arguments: [:])
        let beforeHash = try XCTUnwrap(
            (before["workspaces"] as? [JSONObject])?.first?["root_hash"] as? String
        )

        let replacement = fixture.root.appendingPathComponent("replacement-workspace")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: replacement.appendingPathComponent("marker.txt"))
        try fixture.replaceConfiguration(workspacePath: replacement.standardizedFileURL.path)
        let reloaded = try server.callTool(name: "workspace_reload", arguments: [:])
        XCTAssertEqual(reloaded["reloaded"] as? Bool, true)
        let afterHash = try XCTUnwrap(
            (reloaded["workspaces"] as? [JSONObject])?.first?["root_hash"] as? String
        )
        XCTAssertNotEqual(afterHash, beforeHash)

        let marker = try server.callTool(
            name: "file_read",
            arguments: [
                "workspace_id": fixture.workspaceID,
                "path": "marker.txt",
            ]
        )
        XCTAssertEqual((marker["file"] as? JSONObject)?["content"] as? String, "replacement")
    }

    func testUnknownJSONRPCNotificationDoesNotProduceResponse() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let response = server.handle([
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": ["progress": 0.5] as JSONObject,
        ])
        XCTAssertNil(response)
    }

    func testHeadlessCommandRunTimeoutAndBackgroundCancel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let binary = try testBinary()
        let processes = LocalProcessService(
            workspaceService: service,
            selfExecutable: binary
        )

        let success = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "true",
            arguments: [],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 1_024
        )
        XCTAssertEqual(success["exit_code"] as? Int, 0)
        XCTAssertEqual(success["terminal_window_opened"] as? Bool, false)
        XCTAssertEqual(success["network"] as? String, "loopback_only")
        XCTAssertEqual(success["xpc_dispatched"] as? Bool, false)

        let timeout = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "sleep",
            arguments: ["5"],
            cwd: ".",
            timeoutMilliseconds: 100,
            maximumOutputBytes: 1_024
        )
        XCTAssertEqual(timeout["timed_out"] as? Bool, true)
        XCTAssertEqual(timeout["running"] as? Bool, false)

        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "sleep",
            arguments: ["5"],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        XCTAssertEqual(started["running"] as? Bool, true)
        let cancelled = try processes.cancelProcess(taskID: taskID)
        XCTAssertEqual(cancelled["cancelled"] as? Bool, true)
        XCTAssertEqual(cancelled["running"] as? Bool, false)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testPersistentHeadlessShellAcceptsInputAcrossCallsAndListsSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent("session-directory"),
            withIntermediateDirectories: false
        )
        let shellRun = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: ["-lc", "/usr/bin/uname -s > shell-output.txt"],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 65_536
        )
        XCTAssertEqual(shellRun["exit_code"] as? Int, 0, shellRun["stderr"] as? String ?? "")
        XCTAssertEqual(
            try String(
                contentsOf: fixture.workspace.appendingPathComponent("shell-output.txt"),
                encoding: .utf8
            ),
            "Darwin\n"
        )
        XCTAssertEqual(shellRun["terminal_window_opened"] as? Bool, false)

        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: ["-s"],
            cwd: ".",
            maximumOutputBytes: 65_536
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? processes.cancelProcess(taskID: taskID) }

        let firstInput = try processes.processInput(
            taskID: taskID,
            content: "cd session-directory\n",
            encoding: "utf8",
            closeStdin: false
        )
        XCTAssertEqual(firstInput["bytes_written"] as? Int, 21)
        XCTAssertEqual(firstInput["stdin_closed"] as? Bool, false)

        let listed = processes.processList()
        let rows = try XCTUnwrap(listed["processes"] as? [JSONObject])
        XCTAssertTrue(rows.contains { $0["task_id"] as? String == taskID })

        let secondInput = try processes.processInput(
            taskID: taskID,
            content: "pwd\nexit\n",
            encoding: "utf8",
            closeStdin: true
        )
        XCTAssertEqual(secondInput["bytes_written"] as? Int, 9)
        XCTAssertEqual(secondInput["stdin_closed"] as? Bool, true)

        var status = try processes.processStatus(taskID: taskID)
        for _ in 0..<100 where status["running"] as? Bool == true {
            Thread.sleep(forTimeInterval: 0.02)
            status = try processes.processStatus(taskID: taskID)
        }
        XCTAssertEqual(status["running"] as? Bool, false)
        XCTAssertEqual(status["exit_code"] as? Int, 0)
        var output = try processes.processOutput(
            taskID: taskID,
            stdoutCursor: 0,
            stderrCursor: 0,
            maximumBytesPerStream: 65_536
        )
        let expectedDirectory = fixture.workspace.appendingPathComponent("session-directory").path
        for _ in 0..<50
        where !((output["stdout"] as? String) ?? "").contains(expectedDirectory) {
            Thread.sleep(forTimeInterval: 0.02)
            output = try processes.processOutput(
                taskID: taskID,
                stdoutCursor: 0,
                stderrCursor: 0,
                maximumBytesPerStream: 65_536
            )
        }
        XCTAssertTrue(
            ((output["stdout"] as? String) ?? "").contains(expectedDirectory),
            "stdout=\(output["stdout"] ?? "nil") stderr=\(output["stderr"] ?? "nil")"
        )
        XCTAssertEqual(output["terminal_window_opened"] as? Bool, false)
        XCTAssertEqual(output["xpc_dispatched"] as? Bool, false)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testCancelAfterNaturalExitDoesNotRelabelCompletedProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "true",
            arguments: [],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        var status = try processes.processStatus(taskID: taskID)
        for _ in 0..<500 where status["running"] as? Bool == true {
            Thread.sleep(forTimeInterval: 0.01)
            status = try processes.processStatus(taskID: taskID)
        }
        XCTAssertEqual(status["running"] as? Bool, false)
        XCTAssertEqual(status["exit_code"] as? Int, 0)
        guard status["running"] as? Bool == false else {
            _ = try? processes.cancelProcess(taskID: taskID)
            return
        }

        let cancelled = try processes.cancelProcess(taskID: taskID)
        XCTAssertEqual(cancelled["cancelled"] as? Bool, false)
        XCTAssertEqual(cancelled["exit_code"] as? Int, 0)
    }

    func testDisownedShellChildCannotOutliveTrackedCommand() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let marker = fixture.workspace.appendingPathComponent("orphan-marker")
        let result = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: [
                "-lc",
                "(/bin/sleep 1; /usr/bin/touch orphan-marker) &!",
            ],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 1_024
        )
        XCTAssertEqual(result["exit_code"] as? Int, 0, result["stderr"] as? String ?? "")
        Thread.sleep(forTimeInterval: 1.25)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNaturalBackgroundExitCleansRuntimeWithoutPolling() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        _ = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "true",
            arguments: [],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let runtimeState = fixture.workspace.appendingPathComponent(".macbridge")
        for _ in 0..<100 where FileManager.default.fileExists(atPath: runtimeState.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeState.path))
    }

    func testRuntimeCleanupHandlesChildChangedDirectoryPermissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let result = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: [
                "-lc",
                "mkdir -p \"$HOME/locked/nested\"; : > \"$HOME/locked/nested/file\"; chmod 000 \"$HOME/locked\" \"$HOME\"",
            ],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 4_096
        )
        let taskID = try XCTUnwrap(result["task_id"] as? String)
        let runtime = fixture.workspace.appendingPathComponent(".macbridge/runtime/\(taskID)")
        defer {
            _ = chmod(runtime.appendingPathComponent("home").path, 0o700)
            _ = chmod(runtime.appendingPathComponent("home/locked").path, 0o700)
            _ = chmod(runtime.appendingPathComponent("home/locked/nested").path, 0o700)
        }
        XCTAssertEqual(result["exit_code"] as? Int, 0, result["stderr"] as? String ?? "")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testRuntimeCleanupSettlesConcurrentDirectoryRecreation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.workspace.appendingPathComponent(
            ".macbridge/runtime/00000000-0000-0000-0000-000000000001"
        )
        let recreated = runtime.appendingPathComponent("home/.npm")
        try FileManager.default.createDirectory(
            at: recreated,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let writer = DispatchGroup()
        let deadline = Date().addingTimeInterval(0.06)
        writer.enter()
        DispatchQueue.global().async {
            while Date() < deadline {
                try? FileManager.default.createDirectory(
                    at: recreated,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            writer.leave()
        }
        Thread.sleep(forTimeInterval: 0.005)
        cleanupRuntimePath(runtime)
        writer.wait()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testDeferredRuntimeCleanupRemovesLateRecreation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.workspace.appendingPathComponent(
            ".macbridge/runtime/00000000-0000-0000-0000-000000000002"
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        cleanupRuntimePath(runtime)
        scheduleRuntimePathCleanup(runtime, delay: 0.15)
        Thread.sleep(forTimeInterval: 0.05)
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent("home/.npm"),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // The callback removes the runtime before its empty parents. Await the
        // same parent asserted below so we cannot observe its intermediate state.
        let runtimeRoot = fixture.workspace.appendingPathComponent(".macbridge")
        let deadline = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: runtimeRoot.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtimeRoot.path)
        )
    }

    func testDrainingCompletedOutputReleasesTrackedSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: ["-lc", "printf retained-output"],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        var status = try processes.processStatus(taskID: taskID)
        for _ in 0..<100 where status["running"] as? Bool == true {
            Thread.sleep(forTimeInterval: 0.01)
            status = try processes.processStatus(taskID: taskID)
        }
        let output = try processes.processOutput(
            taskID: taskID,
            stdoutCursor: 0,
            stderrCursor: 0,
            maximumBytesPerStream: 1_024
        )
        XCTAssertEqual(output["stdout"] as? String, "retained-output")
        XCTAssertEqual(output["session_retained"] as? Bool, false)
        let rows = try XCTUnwrap(processes.processList()["processes"] as? [JSONObject])
        XCTAssertFalse(rows.contains { $0["task_id"] as? String == taskID })
    }

    func testProcessOutputDoesNotSplitUTF8Scalars() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: ["-lc", "printf '🙂x'"],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        var status = try processes.processStatus(taskID: taskID)
        for _ in 0..<100 where status["running"] as? Bool == true {
            Thread.sleep(forTimeInterval: 0.01)
            status = try processes.processStatus(taskID: taskID)
        }
        let first = try processes.processOutput(
            taskID: taskID,
            stdoutCursor: 0,
            stderrCursor: 0,
            maximumBytesPerStream: 1
        )
        XCTAssertEqual(first["stdout"] as? String, "🙂")
        XCTAssertEqual(first["stdout_next_cursor"] as? Int, 4)
        XCTAssertEqual(first["session_retained"] as? Bool, true)
        let second = try processes.processOutput(
            taskID: taskID,
            stdoutCursor: 4,
            stderrCursor: 0,
            maximumBytesPerStream: 1
        )
        XCTAssertEqual(second["stdout"] as? String, "x")
        XCTAssertEqual(second["stdout_next_cursor"] as? Int, 5)
        XCTAssertEqual(second["session_retained"] as? Bool, false)
    }

    func testStoppedStatusMeansAllOutputIsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let byteCount = 262_144
        for iteration in 0..<10 {
            let started = try processes.startCommand(
                workspaceID: fixture.workspaceID,
                executableID: "python3",
                arguments: [
                    "-c",
                    "import os;os.write(1,b'x'*262144);os.write(2,b'y'*262144)",
                ],
                cwd: ".",
                maximumOutputBytes: 1_048_576
            )
            let taskID = try XCTUnwrap(started["task_id"] as? String)
            var status = try processes.processStatus(taskID: taskID)
            for _ in 0..<1_000 where status["running"] as? Bool == true {
                Thread.sleep(forTimeInterval: 0.002)
                status = try processes.processStatus(taskID: taskID)
            }
            XCTAssertEqual(status["running"] as? Bool, false, "iteration \(iteration)")
            let output = try processes.processOutput(
                taskID: taskID,
                stdoutCursor: 0,
                stderrCursor: 0,
                maximumBytesPerStream: 1_048_576
            )
            XCTAssertEqual(
                (output["stdout"] as? String)?.utf8.count,
                byteCount,
                "stdout iteration \(iteration)"
            )
            XCTAssertEqual(
                (output["stderr"] as? String)?.utf8.count,
                byteCount,
                "stderr iteration \(iteration)"
            )
            XCTAssertEqual(output["session_retained"] as? Bool, false)
        }
    }

    func testTrackedProcessLimitReopensAfterOutputDrain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        var taskIDs: [String] = []
        for _ in 0..<32 {
            let started = try processes.startCommand(
                workspaceID: fixture.workspaceID,
                executableID: "true",
                arguments: [],
                cwd: ".",
                maximumOutputBytes: 1_024
            )
            taskIDs.append(try XCTUnwrap(started["task_id"] as? String))
        }
        XCTAssertThrowsError(
            try processes.startCommand(
                workspaceID: fixture.workspaceID,
                executableID: "true",
                arguments: [],
                cwd: ".",
                maximumOutputBytes: 1_024
            )
        )

        let firstTask = try XCTUnwrap(taskIDs.first)
        var status = try processes.processStatus(taskID: firstTask)
        for _ in 0..<100 where status["running"] as? Bool == true {
            Thread.sleep(forTimeInterval: 0.01)
            status = try processes.processStatus(taskID: firstTask)
        }
        let drained = try processes.processOutput(
            taskID: firstTask,
            stdoutCursor: 0,
            stderrCursor: 0,
            maximumBytesPerStream: 1_024
        )
        XCTAssertEqual(drained["session_retained"] as? Bool, false)
        let replacement = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "true",
            arguments: [],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        XCTAssertNotNil(replacement["task_id"])
    }

    func testRapidStartsDoNotRaceRuntimeParentCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        for iteration in 0..<20 {
            let first = try processes.startCommand(
                workspaceID: fixture.workspaceID,
                executableID: "true",
                arguments: [],
                cwd: ".",
                maximumOutputBytes: 1_024
            )
            let second = try processes.startCommand(
                workspaceID: fixture.workspaceID,
                executableID: "true",
                arguments: [],
                cwd: ".",
                maximumOutputBytes: 1_024
            )
            for taskID in [first, second].compactMap({ $0["task_id"] as? String }) {
                var status = try processes.processStatus(taskID: taskID)
                for _ in 0..<1_000 where status["running"] as? Bool == true {
                    Thread.sleep(forTimeInterval: 0.005)
                    status = try processes.processStatus(taskID: taskID)
                }
                XCTAssertEqual(status["running"] as? Bool, false, "iteration \(iteration)")
                guard status["running"] as? Bool == false else {
                    _ = try? processes.cancelProcess(taskID: taskID)
                    continue
                }
                let output = try processes.processOutput(
                    taskID: taskID,
                    stdoutCursor: 0,
                    stderrCursor: 0,
                    maximumBytesPerStream: 1_024
                )
                XCTAssertEqual(output["session_retained"] as? Bool, false)
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testFailedStartsDoNotConsumeTrackedProcessSlots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        for _ in 0..<40 {
            XCTAssertThrowsError(
                try processes.startCommand(
                    workspaceID: fixture.workspaceID,
                    executableID: "not-available",
                    arguments: [],
                    cwd: ".",
                    maximumOutputBytes: 1_024
                )
            )
        }
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "true",
            arguments: [],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        XCTAssertNotNil(started["task_id"])
    }

    func testServiceDeinitCancelsOwnedBackgroundProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = fixture.workspace.appendingPathComponent("deinit-orphan-marker")
        do {
            let processes = LocalProcessService(
                workspaceService: try fixture.service(),
                selfExecutable: try testBinary()
            )
            _ = try processes.startCommand(
                workspaceID: fixture.workspaceID,
                executableID: "zsh",
                arguments: ["-lc", "sleep 1; touch deinit-orphan-marker"],
                cwd: ".",
                maximumOutputBytes: 1_024
            )
        }
        Thread.sleep(forTimeInterval: 1.25)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testProcessInputDoesNotBlockWhenChildIgnoresStdin() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "sleep",
            arguments: ["2"],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? processes.cancelProcess(taskID: taskID) }
        let payload = String(repeating: "x", count: 65_536)

        let began = Date()
        var sawBackpressure = false
        for _ in 0..<4 {
            let result = try processes.processInput(
                taskID: taskID,
                content: payload,
                encoding: "utf8",
                closeStdin: false
            )
            XCTAssertEqual(result["bytes_requested"] as? Int, 65_536)
            let bytesWritten = try XCTUnwrap(result["bytes_written"] as? Int)
            let remainingBytes = try XCTUnwrap(result["remaining_bytes"] as? Int)
            XCTAssertEqual(bytesWritten + remainingBytes, 65_536)
            XCTAssertEqual(result["stdin_closed"] as? Bool, false)
            if remainingBytes > 0 {
                sawBackpressure = true
                XCTAssertEqual(result["input_complete"] as? Bool, false)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
        XCTAssertTrue(sawBackpressure)
    }

    func testProcessInputRetriesDeliverLargePayloadExactly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "python3",
            arguments: [
                "-c",
                "import pathlib,sys;pathlib.Path('stdin.bin').write_bytes(sys.stdin.buffer.read())",
            ],
            cwd: ".",
            maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? processes.cancelProcess(taskID: taskID) }
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        var offset = 0
        var lastInput: JSONObject = [:]
        let deadline = Date().addingTimeInterval(5)
        while offset < payload.count, Date() < deadline {
            let end = min(payload.count, offset + 48_000)
            let chunk = payload.subdata(in: offset..<end)
            lastInput = try processes.processInput(
                taskID: taskID,
                content: chunk.base64EncodedString(),
                encoding: "base64",
                closeStdin: end == payload.count
            )
            let written = try XCTUnwrap(lastInput["bytes_written"] as? Int)
            XCTAssertLessThanOrEqual(written, chunk.count)
            if written == 0 {
                Thread.sleep(forTimeInterval: 0.002)
            } else {
                offset += written
            }
        }
        XCTAssertEqual(offset, payload.count)
        XCTAssertEqual(lastInput["stdin_closed"] as? Bool, true)

        var status = try processes.processStatus(taskID: taskID)
        for _ in 0..<500 where status["running"] as? Bool == true {
            Thread.sleep(forTimeInterval: 0.01)
            status = try processes.processStatus(taskID: taskID)
        }
        XCTAssertEqual(status["exit_code"] as? Int, 0)
        XCTAssertEqual(
            try Data(contentsOf: fixture.workspace.appendingPathComponent("stdin.bin")),
            payload
        )
    }

    func testCommandsReadWriteCaptureAndTruncateWithoutTerminalOrNetwork() throws {
        // Exercise the normal production shape: a registered workspace below
        // the current user's home directory, not only /private/var test data.
        // Use the local cache tree so the test does not make FileProvider sync
        // disposable compiler/runtime state from a Documents-hosted checkout.
        let fixture = try Fixture(baseDirectory: homeCacheRoot())
        defer { fixture.remove() }
        try Data("headless-content\n".utf8).write(
            to: fixture.workspace.appendingPathComponent("input.txt")
        )
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )

        let read = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "cat",
            arguments: ["input.txt"],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 1_024
        )
        XCTAssertEqual(read["exit_code"] as? Int, 0)
        XCTAssertEqual(read["stdout"] as? String, "headless-content\n")
        XCTAssertEqual(read["terminal_window_opened"] as? Bool, false)

        let write = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "touch",
            arguments: ["command-created.txt"],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 1_024
        )
        XCTAssertEqual(write["exit_code"] as? Int, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("command-created.txt").path
            )
        )

        let truncated = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "python3",
            arguments: ["-c", "print('x' * 4096)"],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 128
        )
        XCTAssertEqual(truncated["exit_code"] as? Int, 0)
        XCTAssertEqual((truncated["stdout"] as? String)?.utf8.count, 128)
        XCTAssertEqual(truncated["stdout_truncated"] as? Bool, true)

        let network = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "python3",
            arguments: [
                "-c",
                "import socket; socket.socket().connect(('192.0.2.1', 9))",
            ],
            cwd: ".",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 4_096
        )
        XCTAssertNotEqual(network["exit_code"] as? Int, 0)
        XCTAssertEqual(network["network"] as? String, "loopback_only")
        XCTAssertTrue(
            ((network["stderr"] as? String) ?? "").contains("Operation not permitted")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testLoopbackDevelopmentServerReloadAndStop() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let served = fixture.workspace.appendingPathComponent("served.txt")
        try Data("version-one".utf8).write(to: served)
        try Data(
            """
            import http.server

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    with open("served.txt", "rb") as handle:
                        content = handle.read()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(content)))
                    self.end_headers()
                    self.wfile.write(content)

                def log_message(self, format, *args):
                    pass

            server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
            print(server.server_port, flush=True)
            server.serve_forever()
            """.utf8
        ).write(to: fixture.workspace.appendingPathComponent("server.py"))
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "python3",
            arguments: ["server.py"],
            cwd: ".",
            maximumOutputBytes: 4_096
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        var port: Int?
        let deadline = Date().addingTimeInterval(5)
        while port == nil, Date() < deadline {
            let output = try processes.processOutput(
                taskID: taskID,
                stdoutCursor: 0,
                stderrCursor: 0,
                maximumBytesPerStream: 4_096
            )
            port = Int(
                ((output["stdout"] as? String) ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines))
            if port == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        let boundPort = try XCTUnwrap(port)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(boundPort)/"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "version-one")

        try Data("version-two".utf8).write(to: served)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "version-two")

        let cancelled = try processes.cancelProcess(taskID: taskID)
        XCTAssertEqual(cancelled["cancelled"] as? Bool, true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            )
        )
    }

    func testTruncatedBackgroundOutputRetainsNewestTailAndReportsCursorGap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID,
            executableID: "zsh",
            arguments: [
                "-lc",
                "printf 'BEGIN-'; i=0; while [ $i -lt 200 ]; do printf x; i=$((i+1)); done; printf -- '-TAIL-MARKER'",
            ],
            cwd: ".",
            maximumOutputBytes: 64
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        let deadline = Date().addingTimeInterval(5)
        while try processes.processStatus(taskID: taskID)["running"] as? Bool == true,
            Date() < deadline
        {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let output = try processes.processOutput(
            taskID: taskID,
            stdoutCursor: 0,
            stderrCursor: 0,
            maximumBytesPerStream: 1_024
        )
        XCTAssertEqual(output["stdout_cursor_adjusted"] as? Bool, true)
        XCTAssertGreaterThan(output["stdout_dropped_before_cursor"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(output["stdout_total_bytes"] as? Int ?? 0, 64)
        XCTAssertLessThanOrEqual(output["stdout_available_bytes"] as? Int ?? 1_000, 67)
        XCTAssertTrue(((output["stdout"] as? String) ?? "").hasSuffix("-TAIL-MARKER"))
        XCTAssertEqual(output["session_retained"] as? Bool, false)
    }

    func testSwiftBuildAndTestRunInsideDirectSandbox() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent("Sources/Smoke"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent("Tests/SmokeTests"),
            withIntermediateDirectories: true
        )
        try Data(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Smoke",
                products: [.executable(name: "smoke", targets: ["Smoke"])],
                targets: [
                    .executableTarget(name: "Smoke"),
                    .testTarget(name: "SmokeTests", dependencies: ["Smoke"]),
                ]
            )
            """.utf8
        ).write(to: fixture.workspace.appendingPathComponent("Package.swift"))
        try Data("print(\"direct-build-ok\")\n".utf8).write(
            to: fixture.workspace.appendingPathComponent("Sources/Smoke/main.swift")
        )
        try Data(
            """
            import Testing
            @Test func directTest() { #expect(2 + 2 == 4) }
            import XCTest
            final class XCTestSmoke: XCTestCase {
                func testXCTestAlsoRuns() { XCTAssertEqual(2 + 2, 4) }
            }
            """.utf8
        ).write(to: fixture.workspace.appendingPathComponent("Tests/SmokeTests/SmokeTests.swift"))

        let processes = LocalProcessService(
            workspaceService: try fixture.service(),
            selfExecutable: try testBinary()
        )
        let build = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "swift",
            arguments: ["build"],
            cwd: ".",
            timeoutMilliseconds: 120_000,
            maximumOutputBytes: 1_048_576
        )
        XCTAssertEqual(build["exit_code"] as? Int, 0, build["stderr"] as? String ?? "")
        XCTAssertEqual(build["terminal_window_opened"] as? Bool, false)
        XCTAssertEqual(build["network"] as? String, "loopback_only")

        let test = try processes.runCommand(
            workspaceID: fixture.workspaceID,
            executableID: "swift",
            arguments: ["test"],
            cwd: ".",
            timeoutMilliseconds: 120_000,
            maximumOutputBytes: 1_048_576
        )
        XCTAssertEqual(test["exit_code"] as? Int, 0,
                       (test["stderr"] as? String ?? "") + "\nSTDOUT\n" + (test["stdout"] as? String ?? ""))
        XCTAssertTrue(((test["stdout"] as? String) ?? "").contains("Test run with 1 test"))
        XCTAssertTrue(((test["stdout"] as? String) ?? "").contains("testXCTestAlsoRuns"),
                      "STDOUT\n" + (test["stdout"] as? String ?? "") + "\nSTDERR\n" + (test["stderr"] as? String ?? ""))
        XCTAssertFalse(((test["stderr"] as? String) ?? "").contains("could not write dependency graph"))
        XCTAssertEqual(test["terminal_window_opened"] as? Bool, false)
        XCTAssertEqual(test["network"] as? String, "loopback_only")
        // Termination publishes complete output immediately, while the existing
        // cleanup queue rechecks late toolchain HOME/cache writes for 1.14 s.
        // Check that bounded contract instead of racing the delayed callback.
        let runtimeParent = fixture.workspace.appendingPathComponent(".macbridge")
        let cleanupDeadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: runtimeParent.path), Date() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtimeParent.path),
            "runtime remains after bounded cleanup: \((try? FileManager.default.contentsOfDirectory(atPath: runtimeParent.path)) ?? [])"
        )
    }

    func testUnknownExecutablesAndRuntimeSymlinkFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let processes = LocalProcessService(
            workspaceService: service,
            selfExecutable: try testBinary()
        )
        XCTAssertThrowsError(
            try processes.runCommand(
                workspaceID: fixture.workspaceID,
                executableID: "sudo",
                arguments: [],
                cwd: ".",
                timeoutMilliseconds: 2_000,
                maximumOutputBytes: 1_024
            )
        )

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let bridgeState = fixture.workspace.appendingPathComponent(".macbridge")
        XCTAssertEqual(symlink(outside.path, bridgeState.path), 0)
        XCTAssertThrowsError(
            try processes.runCommand(
                workspaceID: fixture.workspaceID,
                executableID: "true",
                arguments: [],
                cwd: ".",
                timeoutMilliseconds: 2_000,
                maximumOutputBytes: 1_024
            )
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    private func currentThreadCount() throws -> Int {
        var taskInfo = proc_taskinfo()
        let result = proc_pidinfo(
            getpid(),
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        guard result == MemoryLayout<proc_taskinfo>.size else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "proc_pidinfo failed"]
            )
        }
        return Int(taskInfo.pti_threadnum)
    }

    private func testBinary() throws -> URL {
        let candidate = packageRoot().appendingPathComponent(".build/debug/macbridge-mcp")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw XCTSkip("macbridge-mcp debug product is unavailable")
        }
        return candidate
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func homeCacheRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
    }
}
