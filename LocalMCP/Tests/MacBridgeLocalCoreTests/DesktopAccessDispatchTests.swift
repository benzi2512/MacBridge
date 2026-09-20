import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class DesktopAccessDispatchTests: XCTestCase {
    func testOnlyDefaultOwnerPolicyCanEnableFixedDesktopOpenOnBroadRoot() throws {
        let ownerPolicy = URL(fileURLWithPath: "/Users/example/.config/macbridge/workspaces.json")
        let desktopOnly = LocalWorkspaceConfigurationEntry(
            id: UUID().uuidString, name: "Mac", path: "/",
            allowBroadAccess: true, allowDesktopOpen: true
        )
        XCTAssertTrue(LocalWorkspaceRegistry.permitsFixedDesktopPolicyOverlap(
            entry: desktopOnly, canonicalRoot: "/",
            configurationURL: ownerPolicy,
            expectedOwnerConfigurationURL: ownerPolicy
        ))
        XCTAssertFalse(LocalWorkspaceRegistry.permitsFixedDesktopPolicyOverlap(
            entry: desktopOnly, canonicalRoot: "/",
            configurationURL: URL(fileURLWithPath: "/tmp/workspaces.json"),
            expectedOwnerConfigurationURL: ownerPolicy
        ))
        let withNetwork = LocalWorkspaceConfigurationEntry(
            id: UUID().uuidString, name: "Mac", path: "/",
            allowBroadAccess: true, allowDesktopOpen: true,
            networkGrants: [.init(
                id: UUID().uuidString, cwd: ".", ipv4: "203.0.113.10", port: 443,
                expiresAt: Date().addingTimeInterval(60)
            )]
        )
        XCTAssertFalse(LocalWorkspaceRegistry.permitsFixedDesktopPolicyOverlap(
            entry: withNetwork, canonicalRoot: "/",
            configurationURL: ownerPolicy,
            expectedOwnerConfigurationURL: ownerPolicy
        ))
    }

    private func server(_ f: Fixture, enabled: Bool,
                        presented: @escaping DesktopOpen.Presenter) throws -> LocalMCPServer {
        let configuration = LocalWorkspaceConfiguration(workspaces: [.init(id: f.workspaceID, name: "Synthetic only",
            path: f.workspace.path, allowDesktopOpen: enabled)])
        let policyDirectory = f.root.appendingPathComponent(".config/macbridge")
        try FileManager.default.createDirectory(at: policyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let protectedConfig = policyDirectory.appendingPathComponent("workspaces.json")
        try JSONEncoder().encode(configuration).write(to: protectedConfig)
        let s = try LocalMCPServer(configurationURL: protectedConfig, selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            observationEnabled: true, searchStartForTesting: nil,
            desktopPresenterForTesting: presented)
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
                networkGrants: [.init(id: UUID().uuidString, cwd: ".", ipv4: "203.0.113.10", port: 443,
                    expiresAt: Date().addingTimeInterval(60))])
        ] {
            try JSONEncoder().encode(LocalWorkspaceConfiguration(workspaces: [entry])).write(to: f.config)
            XCTAssertThrowsError(try LocalWorkspaceRegistry(configurationURL: f.config))
        }
    }
    func testGrantPolicyNamedCorrectlyStillCannotLiveInsideWritableWorkspace() throws {
        let f = try Fixture(); defer { f.remove() }
        let directory = f.workspace.appendingPathComponent(".config/macbridge")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let config = directory.appendingPathComponent("workspaces.json")
        let entry = LocalWorkspaceConfigurationEntry(
            id: f.workspaceID, name: "Synthetic", path: f.workspace.path,
            allowDesktopOpen: true
        )
        try JSONEncoder().encode(
            LocalWorkspaceConfiguration(workspaces: [entry])
        ).write(to: config)
        XCTAssertThrowsError(try LocalWorkspaceRegistry(configurationURL: config))
    }
    func testProtocolDefaultsRejectDesktopAndNetworkCapabilitiesBeforeEffects() throws {
        let f = try Fixture(); defer { f.remove() }
        var presentations = 0
        let s = try server(f, enabled: false) { _ in presentations += 1; return true }
        for (name, args): (String, JSONObject) in [
            ("desktop_open", ["workspace_id": f.workspaceID, "action": "folder", "path": "."]),
            ("network_command", ["workspace_id": f.workspaceID, "grant_id": UUID().uuidString,
                "executable": "sh", "arguments": ["-c", "true"]])
        ] { XCTAssertEqual(try call(s, name: name, args: args)["isError"] as? Bool, true) }
        XCTAssertEqual(presentations, 0)
        let jobs = try s.callTool(name: "process_list", arguments: [:])
        XCTAssertEqual((jobs["processes"] as? [JSONObject])?.count, 0)
    }
    func testFolderProtocolKeepsWorkGroupingAndHonestReceipt() throws {
        let f = try Fixture(); defer { f.remove() }
        var presentations = 0
        let s = try server(f, enabled: true) { _ in presentations += 1; return true }
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
}
