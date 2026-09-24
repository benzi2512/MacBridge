import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class CatalogRefreshTests: XCTestCase {
    func testFreshWebTunnelSessionRequestsOneCatalogRefreshAfterInitialized() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel
        )

        let frames = try run(server, requests: [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:] as JSONObject,
                    "clientInfo": ["name": "catalog-refresh-test", "version": "1"],
                ] as JSONObject,
            ],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ])

        XCTAssertEqual(frames.count, 2)
        let initialized = try XCTUnwrap(frames.first?["result"] as? JSONObject)
        let capabilities = try XCTUnwrap(initialized["capabilities"] as? JSONObject)
        XCTAssertEqual((capabilities["tools"] as? JSONObject)?["listChanged"] as? Bool, true)
        XCTAssertEqual(frames[1]["method"] as? String, "notifications/tools/list_changed")
        XCTAssertNil(frames[1]["id"])
    }

    func testResumedWebTunnelSessionReturnsOnlyOperationalToolResult() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel
        )

        let frames = try run(server, requests: [[
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": [
                "name": "bridge_capabilities",
                "arguments": [:] as JSONObject,
            ] as JSONObject,
        ]])

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["id"] as? Int, 7)
        XCTAssertNotNil(frames[0]["result"])
    }

    func testResumedWebTunnelToolsListReturnsOnlyCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel
        )

        let frames = try run(server, requests: [[
            "jsonrpc": "2.0", "id": 9, "method": "tools/list",
            "params": [:] as JSONObject,
        ]])

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["id"] as? Int, 9)
        let result = try XCTUnwrap(frames[0]["result"] as? JSONObject)
        XCTAssertEqual((result["tools"] as? [JSONObject])?.count, 77)
    }

    func testDesktopLocalDoesNotAdvertiseListChanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:] as JSONObject,
                "clientInfo": ["name": "catalog-refresh-test", "version": "1"],
            ] as JSONObject,
        ]))
        let result = try XCTUnwrap(response["result"] as? JSONObject)
        let capabilities = try XCTUnwrap(result["capabilities"] as? JSONObject)
        XCTAssertEqual((capabilities["tools"] as? JSONObject)?["listChanged"] as? Bool, true)
    }

    private func run(_ server: LocalMCPServer, requests: [JSONObject]) throws -> [JSONObject] {
        let input = Pipe()
        // A full typed catalog can exceed the kernel pipe capacity. This synchronous
        // harness must not block waiting for a reader that only runs after server.run.
        let fixture = try Fixture(); defer { fixture.remove() }
        let outputURL = fixture.root.appendingPathComponent("catalog-frames.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        for request in requests {
            var data = try LocalJSON.encode(request)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try input.fileHandleForWriting.close()
        try server.run(input: input.fileHandleForReading, output: output)
        try output.synchronize()
        let data = try Data(contentsOf: outputURL)
        return try data.split(separator: 0x0A).map { frame in
            try LocalJSON.decodeObject(Data(frame))
        }
    }
}
