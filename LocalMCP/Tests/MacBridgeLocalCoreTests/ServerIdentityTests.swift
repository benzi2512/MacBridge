import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class ServerIdentityTests: XCTestCase {
    func testCapabilitiesKeepInstanceIdentityAndMonotonicUptime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let first = try server.callTool(name: "bridge_capabilities", arguments: [:])
        let instanceID = try XCTUnwrap(first["instance_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: instanceID))
        let firstUptime = try XCTUnwrap(first["uptime_milliseconds"] as? Int64)
        XCTAssertGreaterThanOrEqual(firstUptime, 0)
        var previousUptime = firstUptime

        for _ in 0..<25 {
            let current = try server.callTool(name: "bridge_capabilities", arguments: [:])
            XCTAssertEqual(current["instance_id"] as? String, instanceID)
            XCTAssertEqual(current["build_id"] as? String, first["build_id"] as? String)
            XCTAssertEqual(
                current["mcp_executable_sha256"] as? String,
                first["mcp_executable_sha256"] as? String
            )
            XCTAssertEqual(
                current["catalog_sha256"] as? String, first["catalog_sha256"] as? String
            )
            let uptime = try XCTUnwrap(current["uptime_milliseconds"] as? Int64)
            XCTAssertGreaterThanOrEqual(uptime, previousUptime)
            previousUptime = uptime
        }

        _ = try server.callTool(name: "workspace_reload", arguments: [:])
        let reloaded = try server.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(reloaded["instance_id"] as? String, instanceID)
        XCTAssertEqual(reloaded["catalog_sha256"] as? String, first["catalog_sha256"] as? String)
    }

    func testReplacingExecutablePathDoesNotRelabelExistingInstance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // An inert fixture stands in for the artifact path; neither version is
        // executable and this test never starts a child process.
        let artifact = fixture.root.appendingPathComponent("identity-fixture.bin")
        let originalBytes = Data("identity-original\n".utf8)
        let replacementBytes = Data("identity-replacement\n".utf8)
        try originalBytes.write(to: artifact)
        let original = try LocalMCPServer(
            configurationURL: fixture.config, selfExecutable: artifact
        )
        let before = try original.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(before["mcp_executable_sha256"] as? String, LocalHash.sha256(originalBytes))

        try replacementBytes.write(to: artifact, options: .atomic)
        let after = try original.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(after["mcp_executable_sha256"] as? String, before["mcp_executable_sha256"] as? String)
        XCTAssertEqual(after["build_id"] as? String, before["build_id"] as? String)
        XCTAssertEqual(after["instance_id"] as? String, before["instance_id"] as? String)

        let replacement = try LocalMCPServer(
            configurationURL: fixture.config, selfExecutable: artifact
        )
        let next = try replacement.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertEqual(next["mcp_executable_sha256"] as? String, LocalHash.sha256(replacementBytes))
        XCTAssertNotEqual(next["build_id"] as? String, before["build_id"] as? String)
        XCTAssertNotEqual(next["instance_id"] as? String, before["instance_id"] as? String)
        XCTAssertEqual(next["catalog_sha256"] as? String, before["catalog_sha256"] as? String)
    }

    func testCachedCatalogMatchesSerializationAndCannotBeChangedThroughReturnedValue() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalSpecs = LocalMCPServer.toolSpecs
        let originalJSON = try LocalJSON.encode(originalSpecs)
        var callerCopy = LocalMCPServer.toolSpecs
        callerCopy[0]["description"] = "Changed only in the caller's copy."
        var schema = try XCTUnwrap(callerCopy[0]["inputSchema"] as? JSONObject)
        schema["additionalProperties"] = true
        callerCopy[0]["inputSchema"] = schema
        XCTAssertNotEqual(try LocalJSON.encode(callerCopy), originalJSON)
        XCTAssertEqual(try LocalJSON.encode(LocalMCPServer.toolSpecs), originalJSON)

        for surface in [MacBridgeConnectorSurface.desktopLocal, .webTunnel] {
            let server = try LocalMCPServer(
                configurationURL: fixture.config,
                selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
                connectorSurface: surface
            )
            let capability = try server.callTool(name: "bridge_capabilities", arguments: [:])
            XCTAssertEqual(capability["catalog_sha256"] as? String, LocalHash.sha256(originalJSON))
            XCTAssertEqual(capability["catalog_count"] as? Int, originalSpecs.count)
            let response = try XCTUnwrap(server.handle([
                "jsonrpc": "2.0", "id": 1, "method": "server/discover",
                "params": [:] as JSONObject,
            ]))
            let result = try XCTUnwrap(response["result"] as? JSONObject)
            XCTAssertEqual(result["catalogEpoch"] as? String, capability["catalog_sha256"] as? String)
        }
    }

    func testNewInstancesHaveDifferentIDsForIdenticalArtifact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let web = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel
        )
        let localCapability = try local.callTool(name: "bridge_capabilities", arguments: [:])
        let webCapability = try web.callTool(name: "bridge_capabilities", arguments: [:])
        XCTAssertNotEqual(localCapability["instance_id"] as? String, webCapability["instance_id"] as? String)
        XCTAssertEqual(localCapability["build_id"] as? String, webCapability["build_id"] as? String)
        XCTAssertEqual(localCapability["catalog_sha256"] as? String, webCapability["catalog_sha256"] as? String)
    }
}
