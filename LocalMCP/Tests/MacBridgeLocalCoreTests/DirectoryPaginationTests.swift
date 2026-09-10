import Darwin
import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class DirectoryPaginationTests: XCTestCase {
    func testFlatPagesIndexNamesOnceAndStatOnlyTheirEntries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let names = (0..<420).map { String(format: "%04d-Xin chào 🙂.txt", $0) }
        for name in names + [".env", ".env.test", "tunnel-api-key"] {
            try Data().write(to: fixture.workspace.appendingPathComponent(name))
        }
        let service = try fixture.service()
        var collected: [String] = []
        var cursor = 0
        var scanned = 0
        repeat {
            let page = try service.listDirectory(workspaceID: fixture.workspaceID,
                path: ".", recursive: false, maximumEntries: 17, cursor: cursor)
            XCTAssertEqual(page["name_index_cache_hit"] as? Bool, cursor != 0)
            XCTAssertEqual(page["enumerated_entries"] as? Int, cursor == 0 ? 423 : 0)
            let entries = try XCTUnwrap(page["entries"] as? [JSONObject])
            scanned += try XCTUnwrap(page["scanned_entries"] as? Int)
            XCTAssertLessThanOrEqual(entries.count, 17)
            collected += entries.compactMap { $0["relative_path"] as? String }
            if let next = page["next_cursor"] as? Int {
                XCTAssertGreaterThan(next, cursor)
                cursor = next
            } else {
                XCTAssertEqual(page["complete"] as? Bool, true)
                break
            }
        } while cursor < 500
        XCTAssertEqual(collected, names.sorted())
        XCTAssertEqual(scanned, names.count)

        // A caller can still jump to an arbitrary integer offset, even cold.
        let late = try fixture.service().listDirectory(workspaceID: fixture.workspaceID,
            path: ".", recursive: false, maximumEntries: 17, cursor: 410)
        XCTAssertEqual(late["scanned_entries"] as? Int, 10)
        XCTAssertEqual((late["entries"] as? [JSONObject])?.compactMap {
            $0["relative_path"] as? String
        }, Array(names.sorted().suffix(10)))
        XCTAssertThrowsError(try service.listDirectory(workspaceID: fixture.workspaceID,
            path: ".", recursive: false, maximumEntries: 17, cursor: 421))
        XCTAssertThrowsError(try service.listDirectory(workspaceID: fixture.workspaceID,
            path: ".", recursive: false, maximumEntries: 0))
    }

    func testNameCacheInvalidatesButNeverCachesFileMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.workspace.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["a.txt", "b.txt"] { try Data().write(to: folder.appendingPathComponent(name)) }
        let service = try fixture.service()
        func page(_ path: String = "folder", cursor: Int = 0) throws -> JSONObject {
            try service.listDirectory(workspaceID: fixture.workspaceID, path: path,
                                      recursive: false, maximumEntries: 100, cursor: cursor)
        }
        XCTAssertEqual(try page()["name_index_cache_hit"] as? Bool, false)
        try Data("changed in place".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let edited = try page(cursor: 1)
        XCTAssertEqual(edited["name_index_cache_hit"] as? Bool, true)
        XCTAssertEqual((edited["entries"] as? [JSONObject])?.first?["byte_count"] as? Int64, 16)

        try Data().write(to: folder.appendingPathComponent("c.txt"))
        let inserted = try page()
        XCTAssertEqual(inserted["name_index_cache_hit"] as? Bool, false)
        XCTAssertEqual(inserted["returned_entries"] as? Int, 3)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.txt"))
        let removed = try page()
        XCTAssertEqual(removed["name_index_cache_hit"] as? Bool, false)
        XCTAssertEqual((removed["entries"] as? [JSONObject])?.compactMap {
            $0["relative_path"] as? String
        }, ["folder/b.txt", "folder/c.txt"])

        // Different paths evict the one retained index; permissions are checked
        // by normal resolution/enumeration after the directory stamp changes.
        _ = try page(".")
        XCTAssertEqual(try page()["name_index_cache_hit"] as? Bool, false)
        XCTAssertEqual(chmod(folder.path, 0), 0)
        defer { _ = chmod(folder.path, 0o700) }
        XCTAssertThrowsError(try page())
        XCTAssertEqual(chmod(folder.path, 0o700), 0)
        XCTAssertEqual(try page()["returned_entries"] as? Int, 2)
    }

    func testCachedNamesStillReportLinksWithoutFollowingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.workspace.appendingPathComponent("target.txt")
        try Data("synthetic".utf8).write(to: target)
        let service = try fixture.service()
        _ = try service.listDirectory(workspaceID: fixture.workspaceID,
            path: ".", recursive: false, maximumEntries: 1)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("link"), withDestinationURL: target)
        let page = try service.listDirectory(workspaceID: fixture.workspaceID,
            path: ".", recursive: false, maximumEntries: 100)
        XCTAssertEqual(page["name_index_cache_hit"] as? Bool, false)
        XCTAssertEqual((page["entries"] as? [JSONObject])?.first?["kind"] as? String, "symlink-blocked")
        XCTAssertEqual(try Data(contentsOf: target), Data("synthetic".utf8))
    }
}
