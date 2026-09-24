import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class SharedCapabilityIsolationTests: XCTestCase {
    private func server(_ fixture: Fixture, observation: Bool = true) throws -> LocalMCPServer {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"),
            connectorSurface: .webTunnel,
            observationEnabled: observation
        )
    }

    func testProcessUUIDAloneCannotReadInjectWaitOrCancelAcrossChats() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let server = try server(fixture)
        let started = try server.callTool(name: "command_start", arguments: [
            "workspace_id": fixture.workspaceID, "executable": "cat", "arguments": [],
        ])
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        let token = try XCTUnwrap(started["process_control_token"] as? String)
        XCTAssertEqual(token.count, 64)
        defer {
            _ = try? server.callTool(name: "process_cancel", arguments: [
                "task_id": taskID, "process_control_token": token,
            ])
        }

        for (name, arguments) in [
            ("process_wait", ["task_id": taskID] as JSONObject),
            ("process_output", ["task_id": taskID] as JSONObject),
            ("process_output_tail", ["task_id": taskID] as JSONObject),
            ("process_input", ["task_id": taskID, "content": "hijack"] as JSONObject),
            ("process_cancel", ["task_id": taskID] as JSONObject),
        ] {
            XCTAssertThrowsError(try server.callTool(name: name, arguments: arguments), name)
        }
        XCTAssertThrowsError(try server.callTool(name: "process_cancel", arguments: [
            "task_id": taskID, "process_control_token": String(repeating: "0", count: 64),
        ]))

        let listing = try server.callTool(name: "process_list", arguments: [:])
        let encoded = String(decoding: try LocalJSON.encode(listing), as: UTF8.self)
        XCTAssertTrue(encoded.contains(taskID))
        XCTAssertFalse(encoded.contains(token))
        XCTAssertEqual(try server.callTool(name: "process_status", arguments: [
            "task_id": taskID,
        ])["running"] as? Bool, true)
        let owner = try XCTUnwrap(
            server.callTool(name: "bridge_activity_view", arguments: [:])["instance_id"] as? String
        )
        XCTAssertThrowsError(try server.callTool(name: "bridge_activity", arguments: [
            "instance_id": owner, "task_id": taskID,
        ]))
        XCTAssertNoThrow(try server.callTool(name: "bridge_activity", arguments: [
            "instance_id": owner, "task_id": taskID, "process_control_token": token,
        ]))

        _ = try server.callTool(name: "process_input", arguments: [
            "task_id": taskID, "process_control_token": token,
            "content": "creator\n", "close_stdin": true,
        ])
        _ = try server.callTool(name: "process_wait", arguments: [
            "task_id": taskID, "process_control_token": token,
            "maximum_wait_milliseconds": 1_000,
        ])
        let output = try server.callTool(name: "process_output", arguments: [
            "task_id": taskID, "process_control_token": token,
        ])
        XCTAssertEqual(output["stdout"] as? String, "creator\n")
    }

    func testUndoIDsAreDiscoverableButCreatorCapabilitiesAreNot() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let server = try server(fixture)
        let first = try server.callTool(name: "file_write", arguments: [
            "workspace_id": fixture.workspaceID, "path": "one.txt", "content": "one",
        ])
        let firstID = try XCTUnwrap(first["transaction_id"] as? String)
        let firstToken = try XCTUnwrap(first["transaction_control_token"] as? String)
        XCTAssertEqual(UUID(uuidString: firstToken)?.uuidString.lowercased(), firstToken)
        let resolution = try XCTUnwrap(first["transaction_resolution"] as? JSONObject)
        XCTAssertEqual(resolution["required_before_task_completion"] as? Bool, true)
        let keep = try XCTUnwrap(resolution["keep_changes"] as? JSONObject)
        XCTAssertEqual(keep["tool"] as? String, "transaction_accept")
        let keepArguments = try XCTUnwrap(keep["arguments"] as? JSONObject)
        XCTAssertEqual(keepArguments["transaction_ids"] as? [String], [firstID])
        XCTAssertEqual(keepArguments["transaction_control_tokens"] as? [String], [firstToken])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(keepArguments["instance_id"] as? String)))
        let rollback = try XCTUnwrap(resolution["rollback"] as? JSONObject)
        XCTAssertEqual(rollback["tool"] as? String, "transaction_restore")

        let listed = try server.callTool(name: "transaction_list", arguments: [:])
        let listedText = String(decoding: try LocalJSON.encode(listed), as: UTF8.self)
        XCTAssertTrue(listedText.contains(firstID))
        XCTAssertFalse(listedText.contains(firstToken))
        XCTAssertFalse(listedText.contains("transaction_control_token"))

        XCTAssertThrowsError(try server.callTool(name: "transaction_restore", arguments: [
            "transaction_id": firstID,
        ]))
        XCTAssertThrowsError(try server.callTool(name: "transaction_restore", arguments: [
            "transaction_id": firstID,
            "transaction_control_token": String(repeating: "f", count: 64),
        ]))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("one.txt").path
        ))
        _ = try server.callTool(name: "transaction_restore", arguments: [
            "transaction_id": firstID, "transaction_control_token": firstToken,
        ])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("one.txt").path
        ))

        let second = try server.callTool(name: "file_write", arguments: [
            "workspace_id": fixture.workspaceID, "path": "two.txt", "content": "two",
        ])
        let secondID = try XCTUnwrap(second["transaction_id"] as? String)
        let secondToken = try XCTUnwrap(second["transaction_control_token"] as? String)
        let instance = try XCTUnwrap(
            server.callTool(name: "transaction_list", arguments: [:])["instance_id"] as? String
        )
        XCTAssertThrowsError(try server.callTool(name: "transaction_accept", arguments: [
            "instance_id": instance, "transaction_ids": [secondID],
        ]))
        _ = try server.callTool(name: "transaction_accept", arguments: [
            "instance_id": instance, "transaction_ids": [secondID],
            "transaction_control_tokens": [secondToken],
        ])
        let afterAccept = try server.callTool(name: "transaction_list", arguments: [:])
        XCTAssertEqual(afterAccept["retained_transaction_count"] as? Int, 0)
    }

    func testVerifiedFileFinalizationRecoversWithoutCreatorCapability() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let server = try server(fixture)
        let created = try server.callTool(name: "file_write", arguments: [
            "workspace_id": fixture.workspaceID,
            "path": "scheduled-receipt.json",
            "content": "{\"result\":\"persisted\"}",
        ])
        let transactionID = try XCTUnwrap(created["transaction_id"] as? String)
        let creatorToken = try XCTUnwrap(created["transaction_control_token"] as? String)
        let sha256 = try XCTUnwrap(created["sha256"] as? String)
        let instanceID = try XCTUnwrap(
            server.callTool(name: "transaction_list", arguments: [:])["instance_id"] as? String
        )
        let finalized = try server.callTool(name: "transaction_finalize_file", arguments: [
            "instance_id": instanceID,
            "transaction_id": transactionID,
            "workspace_id": fixture.workspaceID,
            "path": "scheduled-receipt.json",
            "expected_pre_sha256": "absent",
            "expected_post_sha256": sha256,
        ])
        XCTAssertEqual(finalized["finalized_count"] as? Int, 1)
        XCTAssertEqual(finalized["filesystem_mutation_performed"] as? Bool, false)
        XCTAssertEqual(finalized["current_file_state_validated"] as? Bool, true)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.workspace.appendingPathComponent("scheduled-receipt.json"),
                encoding: .utf8
            ),
            "{\"result\":\"persisted\"}"
        )
        XCTAssertThrowsError(try server.callTool(name: "transaction_restore", arguments: [
            "transaction_id": transactionID,
            "transaction_control_token": creatorToken,
        ]))
        XCTAssertEqual(
            try server.callTool(name: "transaction_list", arguments: [:])[
                "retained_transaction_count"
            ] as? Int,
            0
        )
    }

    func testWorkGroupingRequiresItsCreatorCapabilityWithoutLeakingIt() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let server = try server(fixture)
        let begun = try server.callTool(name: "work_task", arguments: [
            "action": "begin", "title": "Chat A", "workspace_id": fixture.workspaceID,
        ])
        let workID = try XCTUnwrap(begun["work_id"] as? String)
        let token = try XCTUnwrap(begun["work_control_token"] as? String)
        let listed = try server.callTool(name: "work_task", arguments: ["action": "list"])
        let listedText = String(decoding: try LocalJSON.encode(listed), as: UTF8.self)
        XCTAssertTrue(listedText.contains(workID))
        XCTAssertFalse(listedText.contains(token))

        XCTAssertThrowsError(try server.callTool(name: "workspace_overview", arguments: [
            "work_id": workID,
        ]))
        XCTAssertThrowsError(try server.callTool(name: "work_task", arguments: [
            "action": "finish", "work_id": workID,
        ]))
        XCTAssertEqual(try server.callTool(name: "workspace_overview", arguments: [
            "work_id": workID, "work_control_token": token,
        ])["work_id"] as? String, workID)
        XCTAssertEqual(try server.callTool(name: "work_task", arguments: [
            "action": "finish", "work_id": workID, "work_control_token": token,
        ])["state"] as? String, "completed")
    }

    func testActivityAndOwnerIPCDoNotExposeOrRequireWebCapabilities() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let server = try server(fixture)
        let write = try server.callTool(name: "file_write", arguments: [
            "workspace_id": fixture.workspaceID, "path": "restore.txt", "content": "value",
        ])
        let transactionID = try XCTUnwrap(write["transaction_id"] as? String)
        let transactionToken = try XCTUnwrap(write["transaction_control_token"] as? String)
        let snapshot = try server.observerRequest(["action": "snapshot"])
        let snapshotText = String(decoding: try LocalJSON.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(snapshotText.contains(transactionToken))
        _ = try server.observerRequest([
            "action": "restore", "instance_id": snapshot["instance_id"]!,
            "transaction_id": transactionID, "workspace_id": fixture.workspaceID,
        ])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("restore.txt").path
        ))
    }
}
