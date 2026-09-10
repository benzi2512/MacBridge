import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class SearchBudgetTests: XCTestCase {
    func testBufferedReaderMatchesBytesAndEnforcesSizeAndIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        let url = f.workspace.appendingPathComponent("sample")
        let expected = Data("hello🙂\0\n".utf8)
        try expected.write(to: url)
        let metadata = try lstatValue(url.path)
        let budget = SearchBudget(milliseconds: 1_000, maximumBytes: 100)
        XCTAssertEqual(try SearchFileReader.read(url, expected: metadata,
            maximumBytes: 100, budget: budget), expected)
        XCTAssertEqual(budget.bytesRead, expected.count)
        XCTAssertThrowsError(try SearchFileReader.read(url, expected: metadata,
            maximumBytes: 1, budget: budget)) {
            guard case SearchReadIssue.oversized = $0 else { return XCTFail("wrong error: \($0)") }
        }
        var changed = metadata; changed.st_ino &+= 1
        XCTAssertThrowsError(try SearchFileReader.read(url, expected: changed,
            maximumBytes: 100, budget: budget)) {
            guard case SearchReadIssue.changed = $0 else { return XCTFail("wrong error: \($0)") }
        }
        // A size/identity rejection did not read or reserve additional bytes.
        XCTAssertEqual(budget.bytesRead, expected.count)
    }

    func testDatalessMetadataIsSkippedBeforeOpeningAnyPath() throws {
        var metadata = stat()
        metadata.st_flags = UInt32(SF_DATALESS)
        XCTAssertTrue(SearchFileReader.isDataless(metadata))
        let budget = SearchBudget(milliseconds: 1_000, maximumBytes: 100)
        // No actual cloud file, filesystem flag change or download in this test.
        XCTAssertThrowsError(try SearchFileReader.read(
            URL(fileURLWithPath: "/nonexistent-macbridge-placeholder"), expected: metadata,
            maximumBytes: 100, budget: budget)) {
            guard case SearchReadIssue.dataless = $0 else { return XCTFail("wrong error: \($0)") }
        }
        XCTAssertEqual(budget.bytesRead, 0)
        metadata.st_flags = 0
        XCTAssertFalse(SearchFileReader.isDataless(metadata))
    }

    func testCooperativeTimeAndByteBudgetUseExactLimits() throws {
        var now: UInt64 = 123
        let budget = SearchBudget(milliseconds: 2, maximumBytes: 4, now: { now })
        now += 1_999_999
        XCTAssertNoThrow(try budget.checkTime())
        now += 1
        XCTAssertThrowsError(try budget.checkTime()) {
            guard case SearchBudgetLimit.time = $0 else { return XCTFail("wrong error: \($0)") }
        }
        XCTAssertNoThrow(try budget.requireBytes(4))
        budget.recordRead(4)
        XCTAssertNoThrow(try budget.requireBytes(0))
        XCTAssertThrowsError(try budget.requireBytes(1)) {
            guard case SearchBudgetLimit.bytes = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    func testReadBudgetPreservesMatchesAndReportsNonResumablePartial() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("hit\n".utf8).write(to: f.workspace.appendingPathComponent("a.txt"))
        try Data("hit\n".utf8).write(to: f.workspace.appendingPathComponent("b.txt"))
        let service = try f.service()
        let page = try service.searchFiles(workspaceID: f.workspaceID, path: ".", query: "hit",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 1_024,
            maximumTotalReadBytes: 4)
        XCTAssertEqual((page["matches"] as? [JSONObject])?.count, 1)
        XCTAssertEqual(page["read_bytes"] as? Int, 4)
        XCTAssertEqual(page["stop_reason"] as? String, "read_byte_budget")
        XCTAssertEqual(page["limit_reached"] as? Bool, true)
        XCTAssertEqual(page["complete"] as? Bool, false)
        XCTAssertEqual(page["partial"] as? Bool, true)
        XCTAssertNil(page["next_cursor"])
        XCTAssertNotNil(page["retry_guidance"])
        let names = try service.searchFiles(workspaceID: f.workspaceID, path: ".", query: ".txt",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 1_024,
            mode: "name", maximumTotalReadBytes: 1)
        XCTAssertEqual((names["matches"] as? [JSONObject])?.count, 2)
        XCTAssertEqual(names["read_bytes"] as? Int, 0)
        XCTAssertEqual(names["complete"] as? Bool, true)
        let full = try service.searchFiles(workspaceID: f.workspaceID, path: ".", query: "hit",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 1_024,
            maximumTotalReadBytes: 8)
        XCTAssertEqual(full["read_bytes"] as? Int, 8)
        XCTAssertEqual(full["complete"] as? Bool, true)
        XCTAssertNil(full["stop_reason"])
    }

    func testStoppedTraversalDoesNotDeclareAnUnseenCursorInvalid() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("no\n".utf8).write(to: f.workspace.appendingPathComponent("a.txt"))
        try Data("no\n".utf8).write(to: f.workspace.appendingPathComponent("b.txt"))
        let page = try f.service().searchFiles(workspaceID: f.workspaceID, path: ".", query: "hit",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 1_024,
            cursor: 100, maximumTotalReadBytes: 3)
        XCTAssertEqual(page["stop_reason"] as? String, "read_byte_budget")
        XCTAssertEqual(page["complete"] as? Bool, false)
        XCTAssertNil(page["next_cursor"])
    }

    func testSearchBudgetSchemaAndInvalidArguments() throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try LocalMCPServer(configurationURL: f.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"))
        let search = try XCTUnwrap(LocalMCPServer.toolSpecs.first { $0["name"] as? String == "file_search" })
        let schema = try XCTUnwrap(search["inputSchema"] as? JSONObject)
        let properties = try XCTUnwrap(schema["properties"] as? JSONObject)
        XCTAssertNotNil(properties["maximum_duration_milliseconds"])
        XCTAssertNotNil(properties["maximum_total_read_bytes"])
        for (key, value) in [("maximum_duration_milliseconds", 0),
                             ("maximum_duration_milliseconds", 10_001),
                             ("maximum_total_read_bytes", 0),
                             ("maximum_total_read_bytes", 64 * 1_024 * 1_024 + 1)] {
            XCTAssertThrowsError(try server.callTool(name: "file_search", arguments: [
                "workspace_id": f.workspaceID, "query": "hit", key: value]))
        }
    }
}
