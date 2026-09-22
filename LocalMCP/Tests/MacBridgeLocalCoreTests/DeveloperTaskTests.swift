import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class DeveloperTaskTests: XCTestCase {
    private func server(_ fixture: Fixture) throws -> LocalMCPServer {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp")
        )
    }

    private func finish(
        _ server: LocalMCPServer,
        workflowID: String
    ) throws -> JSONObject {
        for _ in 0..<100 {
            let result = try server.callTool(
                name: "developer_task",
                arguments: ["action": "continue_task", "workflow_id": workflowID]
            )
            if result["workflow_terminal"] as? Bool == true { return result }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("developer workflow did not reach a terminal state")
        return [:]
    }

    func testExecuteTaskCreatesOneParentAndFinishesIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try server(fixture)
        let started = try server.callTool(
            name: "developer_task",
            arguments: [
                "action": "execute_task", "workspace_id": fixture.workspaceID,
                "cwd": ".", "title": "Developer gateway fixture",
                "chat_label": "Synthetic test only", "executable": "sh",
                "arguments": ["-c", "printf 'developer-ok\\n'"],
                "maximum_output_bytes": 4096,
            ]
        )
        let workflowID = try XCTUnwrap(started["workflow_id"] as? String)
        XCTAssertEqual(started["work_id"] as? String, workflowID)
        XCTAssertNotNil(started["task_id"] as? String)
        XCTAssertEqual(started["next_action"] as? String, "continue_task")

        let terminal = try finish(server, workflowID: workflowID)
        XCTAssertEqual(terminal["exit_code"] as? Int, 0)
        XCTAssertEqual((terminal["process"] as? JSONObject)?["stdout"] as? String,
                       "developer-ok\n")
        XCTAssertEqual(terminal["workflow_terminal_status"] as? String, "completed")

        let list = try server.callTool(name: "work_task", arguments: ["action": "list"])
        let parent = try XCTUnwrap((list["work_items"] as? [JSONObject])?.first {
            $0["work_id"] as? String == workflowID
        })
        XCTAssertEqual(parent["state"] as? String, "completed")
        XCTAssertEqual(parent["active_call_count"] as? Int, 0)
        XCTAssertEqual(parent["error_count"] as? Int, 0)
        let processes = try server.callTool(name: "process_list", arguments: [:])
        XCTAssertTrue((processes["processes"] as? [JSONObject] ?? []).isEmpty)
    }

    func testReadOnlyInspectionUsesItsOwnSurface() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try server(fixture)
        let inspected = try server.callTool(
            name: "developer_inspect",
            arguments: ["action": "inspect_repo", "workspace_id": fixture.workspaceID]
        )
        XCTAssertEqual(inspected["developer_action"] as? String, "inspect_repo")
        XCTAssertEqual(inspected["authority_changed"] as? Bool, false)
        XCTAssertNotNil(inspected["inspection"] as? JSONObject)
        XCTAssertEqual(inspected["child_count"] as? Int, 4)
        XCTAssertEqual(inspected["child_error_count"] as? Int, 3)
        XCTAssertEqual(inspected["error_count"] as? Int, 3)
        XCTAssertEqual(inspected["complete"] as? Bool, false)
        XCTAssertEqual(inspected["partial"] as? Bool, true)
        XCTAssertEqual(inspected["overall_status"] as? String, "partial")
        let children = try XCTUnwrap(inspected["child_results"] as? [JSONObject])
        XCTAssertEqual(children.filter { $0["status"] as? String == "failed" }.count, 3)
        XCTAssertFalse(children.contains { $0["stdout"] != nil || $0["stderr"] != nil })
        XCTAssertThrowsError(
            try server.callTool(
                name: "developer_inspect",
                arguments: [
                    "action": "execute_task", "workspace_id": fixture.workspaceID,
                    "executable": "true", "arguments": [],
                ]
            )
        )
        XCTAssertThrowsError(
            try server.callTool(
                name: "developer_task",
                arguments: ["action": "inspect_repo", "workspace_id": fixture.workspaceID]
            )
        )
    }

    func testReviewDiffAggregatesNonRepositoryChildFailures() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inspected = try server(fixture).callTool(
            name: "developer_inspect",
            arguments: ["action": "review_diff", "workspace_id": fixture.workspaceID]
        )
        XCTAssertEqual(inspected["child_count"] as? Int, 2)
        XCTAssertEqual(inspected["child_error_count"] as? Int, 2)
        XCTAssertEqual(inspected["overall_status"] as? String, "failed")
        XCTAssertEqual(inspected["complete"] as? Bool, false)
    }

    func testRejectedLaunchClosesItsNewParentAsFailed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try server(fixture)
        XCTAssertThrowsError(
            try server.callTool(
                name: "developer_task",
                arguments: [
                    "action": "execute_task", "workspace_id": fixture.workspaceID,
                    "cwd": ".", "title": "Rejected developer fixture",
                    "executable": "not-allowed", "arguments": [],
                ]
            )
        )
        let list = try server.callTool(name: "work_task", arguments: ["action": "list"])
        let parent = try XCTUnwrap((list["work_items"] as? [JSONObject])?.first {
            $0["title"] as? String == "Rejected developer fixture"
        })
        XCTAssertEqual(parent["state"] as? String, "failed")
        XCTAssertEqual(parent["active_call_count"] as? Int, 0)
        XCTAssertEqual(parent["error_count"] as? Int, 1)
        XCTAssertTrue((parent["job_ids"] as? [String] ?? []).isEmpty)
    }
}
