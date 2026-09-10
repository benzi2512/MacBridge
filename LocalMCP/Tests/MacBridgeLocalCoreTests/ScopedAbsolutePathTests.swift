import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ScopedAbsolutePathTests: XCTestCase {
    func testCanonicalPrivateTempWorkspaceCanBeRegistered() throws {
        let fixture = try Fixture(baseDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        defer { fixture.remove() }
        // Foundation can rewrite an existing /private/tmp path to /tmp when
        // standardizing it. The canonical spelling is nevertheless valid.
        try fixture.replaceConfiguration(workspacePath: fixture.workspace.path)
        let workspace = try fixture.service().registry.workspace(id: fixture.workspaceID)
        XCTAssertEqual(workspace.rootURL.path, fixture.workspace.path)
        XCTAssertFalse(workspace.allowsBroadAccess)
    }

    func testAbsoluteAndRelativePathsUseTheSameScopedFileAndUndo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let id = fixture.workspaceID
        let target = fixture.workspace.appendingPathComponent("Dữ liệu.txt")
        let before = Data("value=1\n".utf8)
        try before.write(to: target)
        let absolute = try service.readFile(workspaceID: id, path: target.path,
            encoding: "utf8", maximumBytes: 1024)
        let relative = try service.readFile(workspaceID: id, path: "Dữ liệu.txt",
            encoding: "utf8", maximumBytes: 1024)
        XCTAssertEqual((absolute["file"] as? JSONObject)?["sha256"] as? String,
                       (relative["file"] as? JSONObject)?["sha256"] as? String)
        XCTAssertEqual((absolute["file"] as? JSONObject)?["relative_path"] as? String, "Dữ liệu.txt")
        XCTAssertEqual(try service.workspaceURL(workspaceID: id, relativePath: fixture.workspace.path), fixture.workspace)
        let changed = try service.patchFile(workspaceID: id, path: target.path,
            oldText: "value=1", newText: "value=2", replaceAll: false,
            expectedSHA256: LocalHash.sha256(before))
        XCTAssertEqual(try Data(contentsOf: target), Data("value=2\n".utf8))
        _ = try service.restoreTransaction(XCTUnwrap(changed["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertEqual(service.retainedTransactionCount, 0)
        let workspace = try service.registry.workspace(id: id)
        XCTAssertFalse(workspace.allowsBroadAccess)
        XCTAssertEqual(workspace.json["absolute_paths"] as? Bool, true)
    }

    func testAbsoluteCreateRestoresWithoutBroadAccess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let target = fixture.workspace.appendingPathComponent("created.txt")
        let result = try service.writeFile(workspaceID: fixture.workspaceID,
            path: target.path, content: "synthetic", encoding: "utf8", expectedSHA256: nil)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "synthetic")
        _ = try service.restoreTransaction(XCTUnwrap(result["transaction_id"] as? String))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testAbsoluteSpellingDoesNotWidenTheWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("untouched".utf8).write(to: outside)
        XCTAssertThrowsError(try service.statPath(workspaceID: fixture.workspaceID, path: outside.path))
        XCTAssertThrowsError(try service.writeFile(workspaceID: fixture.workspaceID,
            path: outside.path, content: "changed", encoding: "utf8", expectedSHA256: nil))
        XCTAssertThrowsError(try service.createDirectory(workspaceID: fixture.workspaceID, path: fixture.workspace.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }
}
