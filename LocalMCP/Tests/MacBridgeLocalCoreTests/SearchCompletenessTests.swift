import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class SearchCompletenessTests: XCTestCase {
    func testSkippedContentIsExplicitAndDoesNotLoseReadableMatches() throws {
        let f = try Fixture()
        defer { f.remove() }
        try Data("needle".utf8).write(to: f.workspace.appendingPathComponent("readable"))
        try Data(repeating: 65, count: 33).write(to: f.workspace.appendingPathComponent("oversized"))
        try Data([0xff, 0xfe]).write(to: f.workspace.appendingPathComponent("binary"))
        let service = try f.service()
        let result = try service.searchFiles(workspaceID: f.workspaceID, path: ".", query: "needle",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 32)
        XCTAssertEqual((result["matches"] as? [JSONObject])?.first?["relative_path"] as? String, "readable")
        XCTAssertEqual(result["complete"] as? Bool, false)
        XCTAssertEqual(result["partial"] as? Bool, true)
        XCTAssertEqual(result["skipped_oversized_files"] as? Int, 1)
        XCTAssertEqual(result["skipped_non_utf8_files"] as? Int, 1)
        XCTAssertEqual(result["skipped_inaccessible_paths"] as? Int, 0)
        XCTAssertNil(result["next_cursor"]) // not recoverable by paging
        let names = try service.searchFiles(workspaceID: f.workspaceID, path: ".", query: "binary",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 32, mode: "name")
        XCTAssertEqual(names["complete"] as? Bool, true)
        XCTAssertEqual(names["partial"] as? Bool, false)
        XCTAssertEqual(names["skipped_non_utf8_files"] as? Int, 0)
    }
}
