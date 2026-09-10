import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ObserverFilePreviewTests: XCTestCase {
    private func server(_ f: Fixture) throws -> LocalMCPServer {
        // These tests never launch a child process.
        try LocalMCPServer(configurationURL: f.config,
                           selfExecutable: URL(fileURLWithPath: "/usr/bin/true"), observationEnabled: true)
    }

    private func request(_ owner: LocalMCPServer, fixture f: Fixture, path: String) throws -> JSONObject {
        _ = try owner.callTool(name: "file_stat", arguments: ["workspace_id": f.workspaceID, "path": path])
        let snapshot = try owner.observerRequest(["action": "snapshot"])
        XCTAssertEqual(snapshot["observer_file_preview"] as? Bool, true)
        let event = try XCTUnwrap((snapshot["history"] as? [JSONObject])?.last)
        return ["action": "file_preview", "instance_id": try XCTUnwrap(snapshot["instance_id"]),
                "event_id": try XCTUnwrap(event["id"])]
    }

    func testPreviewIsCurrentContentConditionalAndDoesNotEnterHistory() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let file = f.workspace.appendingPathComponent("sample.txt")
        try Data("SYNTHETIC_PREVIEW_ONE\n".utf8).write(to: file)
        var query = try request(owner, fixture: f, path: "sample.txt")
        let first = try owner.observerRequest(query)
        XCTAssertEqual(first["path"] as? String, file.path)
        XCTAssertEqual(first["relative_path"] as? String, "sample.txt")
        XCTAssertEqual(first["workspace_id"] as? String, f.workspaceID)
        XCTAssertEqual(first["text"] as? String, "SYNTHETIC_PREVIEW_ONE\n")
        XCTAssertEqual(first["unchanged"] as? Bool, false)
        XCTAssertEqual(first["truncated"] as? Bool, false)
        XCTAssertEqual(first["version_basis"] as? String, "stat_metadata_not_content_hash")
        query["known_version"] = try XCTUnwrap(first["version"] as? String)
        let unchanged = try owner.observerRequest(query)
        XCTAssertEqual(unchanged["unchanged"] as? Bool, true)
        XCTAssertNil(unchanged["text"])
        // Atomic replacement also changes inode, even for a same-sized update.
        try Data("SYNTHETIC_PREVIEW_TWO\n".utf8).write(to: file, options: .atomic)
        let changed = try owner.observerRequest(query)
        XCTAssertEqual(changed["unchanged"] as? Bool, false)
        XCTAssertNotEqual(changed["version"] as? String, first["version"] as? String)
        XCTAssertEqual(changed["text"] as? String, "SYNTHETIC_PREVIEW_TWO\n")
        let snapshot = try owner.observerRequest(["action": "snapshot"])
        XCTAssertEqual((snapshot["history"] as? [JSONObject])?.count, 1)
        XCTAssertEqual(snapshot["transaction_count"] as? Int, 0)
        let encoded = String(decoding: try LocalJSON.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SYNTHETIC_PREVIEW_ONE"))
        XCTAssertFalse(encoded.contains("SYNTHETIC_PREVIEW_TWO"))
    }

    func testPreviewIsBoundedWithoutSplittingUTF8Scalar() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        let text = String(repeating: "a", count: 16_383) + "🌏" + String(repeating: "z", count: 80)
        try Data(text.utf8).write(to: f.workspace.appendingPathComponent("large.txt"))
        let result = try service.observerFilePreview(workspaceID: f.workspaceID, path: "large.txt", knownVersion: nil)
        let preview = try XCTUnwrap(result["text"] as? String)
        XCTAssertEqual(preview, String(repeating: "a", count: 16_383))
        XCTAssertLessThanOrEqual(preview.utf8.count, 16_384)
        XCTAssertEqual(result["preview_bytes"] as? Int, preview.utf8.count)
        XCTAssertEqual(result["total_bytes"] as? Int, text.utf8.count)
        XCTAssertEqual(result["truncated"] as? Bool, true)
    }

    func testEmptyUTF8AndBinaryControlsAreDistinct() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        let file = f.workspace.appendingPathComponent("content.txt")
        try Data().write(to: file)
        XCTAssertEqual(try service.observerFilePreview(workspaceID: f.workspaceID, path: "content.txt", knownVersion: nil)["text"] as? String, "")
        let binarySamples: [[UInt8]] = [[0x41, 0, 0x42], [0xFF, 0xFE], [0x1B, 0x5B, 0x32, 0x4A], [0x7F]]
        for bytes in binarySamples {
            try Data(bytes).write(to: file)
            XCTAssertThrowsError(try service.observerFilePreview(workspaceID: f.workspaceID, path: "content.txt", knownVersion: String(repeating: "0", count: 64)))
        }
        try Data("tab\tand\nnewlines\r\n".utf8).write(to: file)
        XCTAssertNoThrow(try service.observerFilePreview(workspaceID: f.workspaceID, path: "content.txt", knownVersion: nil))
    }

    func testOwnerEventAndRequestShapeGuards() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        try Data("fixture\n".utf8).write(to: f.workspace.appendingPathComponent("sample.txt"))
        let query = try request(owner, fixture: f, path: "sample.txt")
        var invalid = query
        invalid["instance_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try owner.observerRequest(invalid))
        invalid = query; invalid["event_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try owner.observerRequest(invalid))
        for field in ["path", "workspace_id", "transaction_id"] {
            invalid = query; invalid[field] = "caller-selected-value"
            XCTAssertThrowsError(try owner.observerRequest(invalid))
        }
        for version in ["", "short", String(repeating: "g", count: 64), String(repeating: "a", count: 65)] {
            invalid = query; invalid["known_version"] = version
            XCTAssertThrowsError(try owner.observerRequest(invalid))
        }
        _ = try owner.callTool(name: "workspace_overview", arguments: [:])
        let snapshot = try owner.observerRequest(["action": "snapshot"])
        invalid = query; invalid["event_id"] = (snapshot["history"] as? [JSONObject])?.last?["id"]
        XCTAssertThrowsError(try owner.observerRequest(invalid))
        XCTAssertThrowsError(try owner.callTool(name: "file_read", arguments: ["workspace_id": f.workspaceID, "path": "missing.txt"]))
        let failed = try owner.observerRequest(["action": "snapshot"])
        invalid = query; invalid["event_id"] = (failed["history"] as? [JSONObject])?.last?["id"]
        XCTAssertThrowsError(try owner.observerRequest(invalid))
    }

    func testRetainedEventCannotFollowReplacementLinkOrMissingFile() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let file = f.workspace.appendingPathComponent("sample.txt")
        let outside = f.root.appendingPathComponent("outside.txt")
        try Data("safe\n".utf8).write(to: file)
        try Data("SYNTHETIC_OUTSIDE\n".utf8).write(to: outside)
        let query = try request(owner, fixture: f, path: "sample.txt")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try owner.observerRequest(query))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try owner.observerRequest(query))
    }

    func testPreviewRejectsParentLinksDirectoriesCredentialsAndBoundaryEscape() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        try Data("synthetic\n".utf8).write(to: f.root.appendingPathComponent("outside.txt"))
        try Data("synthetic\n".utf8).write(to: f.workspace.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("link"), withDestinationURL: f.root)
        for path in [".", ".env", "link/outside.txt", "../outside.txt", f.root.appendingPathComponent("outside.txt").path] {
            XCTAssertThrowsError(try service.observerFilePreview(workspaceID: f.workspaceID, path: path, knownVersion: nil))
        }
        XCTAssertThrowsError(try service.observerFilePreview(workspaceID: UUID().uuidString, path: "outside.txt", knownVersion: nil))
    }

    func testLongRetainedPathCannotBeUsedAsExactPreviewTarget() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let path = (0..<6).map { String(repeating: Character(String($0)), count: 90) }.joined(separator: "/") + "/file.txt"
        let file = f.workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("long path\n".utf8).write(to: file)
        let query = try request(owner, fixture: f, path: path)
        XCTAssertThrowsError(try owner.observerRequest(query))
    }

    func testDatalessAndHardLinkedFilesAreRejectedWithoutHydration() throws {
        let f = try Fixture(); defer { f.remove() }
        let file = f.workspace.appendingPathComponent("sample.txt")
        try Data("fixture\n".utf8).write(to: file)
        var status = try lstatValue(file.path)
        // Synthetic metadata only: never mark a real file dataless.
        status.st_flags |= UInt32(SF_DATALESS)
        XCTAssertThrowsError(try ObserverFilePreview().read(url: file, root: f.workspace.path, expected: status, knownVersion: nil))
        try FileManager.default.linkItem(at: file, to: f.workspace.appendingPathComponent("alias.txt"))
        XCTAssertThrowsError(try f.service().observerFilePreview(workspaceID: f.workspaceID, path: "sample.txt", knownVersion: nil))
    }
}
