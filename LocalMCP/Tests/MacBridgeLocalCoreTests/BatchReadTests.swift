import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class BatchReadTests: XCTestCase {
    func testPartialBatchPreservesOrderAndSingleFilePolicy() throws {
        let f = try Fixture()
        defer { f.remove() }
        try Data("hello🙂".utf8).write(to: f.workspace.appendingPathComponent("good.txt"))
        try Data("synthetic-only".utf8).write(to: f.workspace.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(atPath: f.workspace.appendingPathComponent("link").path,
            withDestinationPath: f.workspace.appendingPathComponent("good.txt").path)
        let service = try f.service()
        let paths = ["good.txt", ".env", "link", "../outside", "missing.txt", "good.txt"]
        let value = try service.readFiles(workspaceID: f.workspaceID, paths: paths, encoding: "utf8",
            maximumBytesPerFile: 100, maximumTotalBytes: 1024)
        let rows = try XCTUnwrap(value["results"] as? [JSONObject])
        XCTAssertEqual(rows.compactMap { $0["requested_path"] as? String }, paths)
        XCTAssertEqual(value["read_count"] as? Int, 2)
        XCTAssertEqual(value["error_count"] as? Int, 4)
        XCTAssertEqual(value["complete"] as? Bool, false)
        XCTAssertEqual(rows[1]["error_code"] as? String, "sensitive_path_blocked")
        XCTAssertEqual(rows[2]["error_code"] as? String, "invalid_path")
        XCTAssertEqual(rows[3]["error_code"] as? String, "invalid_path")
        XCTAssertFalse(String(decoding: try LocalJSON.encode(value), as: UTF8.self).contains("synthetic-only"))
        let single = try service.readFile(workspaceID: f.workspaceID, path: "good.txt", encoding: "utf8", maximumBytes: 100)
        XCTAssertEqual(try LocalJSON.encode(rows[0]["file"]!), try LocalJSON.encode(single["file"]!))
    }

    func testUTF8AggregateBudgetAndContinuationAreExplicit() throws {
        let f = try Fixture()
        defer { f.remove() }
        try Data("🙂tail".utf8).write(to: f.workspace.appendingPathComponent("a"))
        let service = try f.service()
        let value = try service.readFiles(workspaceID: f.workspaceID, paths: ["a", "a"], encoding: "utf8",
            maximumBytesPerFile: 1, maximumTotalBytes: 4)
        let rows = try XCTUnwrap(value["results"] as? [JSONObject])
        let file = try XCTUnwrap(rows[0]["file"] as? JSONObject)
        XCTAssertEqual(value["returned_bytes"] as? Int, 4)
        XCTAssertEqual(value["skipped_count"] as? Int, 1)
        XCTAssertEqual(file["content"] as? String, "🙂")
        XCTAssertEqual(file["next_offset"] as? Int, 4)
        XCTAssertEqual(file["eof"] as? Bool, false)
        XCTAssertEqual(rows[1]["status"] as? String, "skipped_budget")
        XCTAssertEqual(value["complete"] as? Bool, false)
        let rest = try service.readFile(workspaceID: f.workspaceID, path: "a", encoding: "utf8", maximumBytes: 20, offset: 4)
        XCTAssertEqual((rest["file"] as? JSONObject)?["content"] as? String, "tail")
    }

    func testBase64BudgetAndMetadataHashOptIn() throws {
        let f = try Fixture()
        defer { f.remove() }
        let bytes = Data([0, 255, 1, 254, 2, 253])
        try bytes.write(to: f.workspace.appendingPathComponent("binary"))
        let service = try f.service()
        let value = try service.readFiles(workspaceID: f.workspaceID, paths: ["binary"], encoding: "base64",
            maximumBytesPerFile: 100, maximumTotalBytes: 4)
        let file = try XCTUnwrap((value["results"] as? [JSONObject])?.first?["file"] as? JSONObject)
        XCTAssertEqual(file["content"] as? String, bytes.prefix(4).base64EncodedString())
        XCTAssertEqual(value["returned_bytes"] as? Int, 4)
        for includeHash in [false, true] {
            let stats = try service.statPaths(workspaceID: f.workspaceID, paths: ["binary", ".env"], includeSHA256: includeHash)
            let rows = try XCTUnwrap(stats["results"] as? [JSONObject])
            let metadata = try XCTUnwrap(rows[0]["path"] as? JSONObject)
            XCTAssertEqual(metadata["sha256"] as? String, includeHash ? LocalHash.sha256(bytes) : nil)
            XCTAssertEqual(rows[1]["error_code"] as? String, "sensitive_path_blocked")
            XCTAssertEqual(stats["complete"] as? Bool, false)
        }
    }

    func testBatchLimitsAndClosedToolSchemas() throws {
        let f = try Fixture()
        defer { f.remove() }
        let server = try LocalMCPServer(configurationURL: f.config, selfExecutable: URL(fileURLWithPath: "/usr/bin/true"))
        for name in ["file_read_many", "file_stat_many"] {
            for paths in [[], Array(repeating: "a", count: 33), [""], [String(repeating: "x", count: 4097)]] {
                XCTAssertThrowsError(try server.callTool(name: name, arguments: ["workspace_id": f.workspaceID, "paths": paths]))
            }
            XCTAssertThrowsError(try server.callTool(name: name, arguments: ["workspace_id": f.workspaceID, "paths": ["a"], "approve_all": true]))
            XCTAssertThrowsError(try server.callTool(name: name, arguments: ["workspace_id": UUID().uuidString, "paths": ["a"]]))
        }
        for bad in [-1, 0, 3, 1_048_577] {
            XCTAssertThrowsError(try server.callTool(name: "file_read_many", arguments: ["workspace_id": f.workspaceID, "paths": ["a"], "maximum_total_bytes": bad]))
        }
    }
}
