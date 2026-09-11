import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class DesktopAccessDispatchTests: XCTestCase {
    private final class Fake: ComputerBackend {
        var trusted = true
        var calls = 0
        func application(bundleID: String) throws -> ComputerApplication {
            .init(bundleID: bundleID, pid: 456, launchStamp: 1, frontmost: true)
        }
        func snapshot(application: ComputerApplication) throws -> ComputerFrame {
            .init(nodes: [.init(id: 0, role: "AXButton", title: "Synthetic button", value: nil,
                actions: ["press"], secure: false, handle: nil)], partial: false)
        }
        func perform(action: String, application: ComputerApplication, node: ComputerNode?, text: String?) throws {
            calls += 1
            throw LocalMCPError.operationFailed("simulated uncertain OS action")
        }
    }
    private func server(_ f: Fixture, enabled: Bool, fake: Fake, presented: @escaping DesktopOpen.Presenter) throws -> LocalMCPServer {
        let configuration = LocalWorkspaceConfiguration(workspaces: [.init(id: f.workspaceID, name: "Synthetic only",
            path: f.workspace.path, allowDesktopOpen: enabled,
            computerGrants: enabled ? [.init(bundleID: "com.example.Fixture", actions: ["snapshot", "press"],
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)))] : [])])
        let policyDirectory = f.root.appendingPathComponent(".config/macbridge")
        try FileManager.default.createDirectory(at: policyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let protectedConfig = policyDirectory.appendingPathComponent("workspaces.json")
        try JSONEncoder().encode(configuration).write(to: protectedConfig)
        let s = try LocalMCPServer(configurationURL: protectedConfig, selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            observationEnabled: true, searchStartForTesting: nil,
            desktopPresenterForTesting: presented, computerBackendForTesting: fake)
        _ = s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "clientInfo": ["name": "synthetic", "version": "1"], "capabilities": [:]]])
        _ = s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return s
    }
    private func call(_ s: LocalMCPServer, name: String, args: JSONObject) throws -> JSONObject {
        let r = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": name, "arguments": args]]))
        return try XCTUnwrap(r["result"] as? JSONObject)
    }
    func testProjectWritableConfigurationCannotSelfGrantDesktopCapabilities() throws {
        let f = try Fixture(); defer { f.remove() }
        for entry in [
            LocalWorkspaceConfigurationEntry(id: f.workspaceID, name: "Synthetic", path: f.workspace.path, allowDesktopOpen: true),
            LocalWorkspaceConfigurationEntry(id: f.workspaceID, name: "Synthetic", path: f.workspace.path,
                computerGrants: [.init(bundleID: "com.example.Fixture", actions: ["snapshot"],
                    expiresAt: "2026-09-10T00:00:00Z")]),
            LocalWorkspaceConfigurationEntry(id: f.workspaceID, name: "Synthetic", path: f.workspace.path,
                networkGrants: [.init(id: UUID().uuidString, cwd: ".", ipv4: "203.0.113.10", port: 443,
                    expiresAt: Date().addingTimeInterval(60))])
        ] {
            try JSONEncoder().encode(LocalWorkspaceConfiguration(workspaces: [entry])).write(to: f.config)
            XCTAssertThrowsError(try LocalWorkspaceRegistry(configurationURL: f.config))
        }
    }
    func testProtocolDefaultsRejectAllThreeNewCapabilitiesBeforeEffects() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake()
        var presentations = 0
        let s = try server(f, enabled: false, fake: fake) { _ in presentations += 1; return true }
        for (name, args): (String, JSONObject) in [
            ("desktop_open", ["workspace_id": f.workspaceID, "action": "folder", "path": "."]),
            ("computer_control", ["workspace_id": f.workspaceID, "bundle_id": "com.example.Fixture", "action": "snapshot"]),
            ("network_command", ["workspace_id": f.workspaceID, "grant_id": UUID().uuidString,
                "executable": "sh", "arguments": ["-c", "true"]])
        ] { XCTAssertEqual(try call(s, name: name, args: args)["isError"] as? Bool, true) }
        XCTAssertEqual(presentations, 0); XCTAssertEqual(fake.calls, 0)
        let jobs = try s.callTool(name: "process_list", arguments: [:])
        XCTAssertEqual((jobs["processes"] as? [JSONObject])?.count, 0)
    }
    func testFolderProtocolKeepsWorkGroupingAndHonestReceipt() throws {
        let f = try Fixture(); defer { f.remove() }
        var presentations = 0
        let s = try server(f, enabled: true, fake: Fake()) { _ in presentations += 1; return true }
        let parent = try s.callTool(name: "work_task", arguments: ["action": "begin", "title": "Open fixture", "workspace_id": f.workspaceID])
        let id = try XCTUnwrap(parent["work_id"] as? String)
        let result = try call(s, name: "desktop_open", args: ["workspace_id": f.workspaceID,
            "action": "folder", "path": ".", "work_id": id])
        let data = try XCTUnwrap(result["structuredContent"] as? JSONObject)
        XCTAssertEqual(data["work_id"] as? String, id)
        XCTAssertEqual(data["request_accepted"] as? Bool, true)
        XCTAssertEqual(data["window_visibility_verified"] as? Bool, false)
        XCTAssertEqual(presentations, 1)
        let observer = try s.observerRequest(["action": "snapshot"])
        XCTAssertTrue((observer["history"] as? [JSONObject] ?? []).contains { $0["tool"] as? String == "desktop_open" })
    }
    func testUncertainComputerActionIsProtocolErrorAndObserverIssueNotSuccess() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), s = try server(f, enabled: true, fake: fake) { _ in false }
        let base: JSONObject = ["workspace_id": f.workspaceID, "bundle_id": "com.example.Fixture", "action": "snapshot"]
        let response = try call(s, name: "computer_control", args: base)
        let frame = try XCTUnwrap(response["structuredContent"] as? JSONObject)
        let action = base.merging(["action": "press", "snapshot_id": frame["snapshot_id"]!, "element_id": 0]) { _, b in b }
        let result = try call(s, name: "computer_control", args: action)
        XCTAssertEqual(result["isError"] as? Bool, true)
        let data = try XCTUnwrap(result["structuredContent"] as? JSONObject)
        XCTAssertEqual(data["status"] as? String, "outcome_unknown")
        XCTAssertEqual(data["retry_safe"] as? Bool, false)
        XCTAssertEqual(fake.calls, 1)
        let observer = try s.observerRequest(["action": "snapshot"])
        XCTAssertTrue((observer["history"] as? [JSONObject] ?? []).contains {
            $0["tool"] as? String == "computer_control" && $0["state"] as? String == "failed"
        })
        XCTAssertEqual(try call(s, name: "computer_control", args: action)["isError"] as? Bool, true)
        XCTAssertEqual(fake.calls, 1)
    }
}
