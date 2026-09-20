import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class UndoBudgetTests: XCTestCase {
    func testReloadRefusesUndoAndKeepsOriginalRegistryUntilRestored() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = try LocalMCPServer(configurationURL: fixture.config,
                                       selfExecutable: URL(fileURLWithPath: "/usr/bin/true"))
        let write = try server.callTool(name: "file_write", arguments: [
            "workspace_id": fixture.workspaceID, "path": "original.txt", "content": "keep undo",
        ])
        let transaction = try XCTUnwrap(write["transaction_id"] as? String)
        let replacement = fixture.root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("new root".utf8).write(to: replacement.appendingPathComponent("marker.txt"))
        try fixture.replaceConfiguration(workspacePath: replacement.standardizedFileURL.path)
        XCTAssertThrowsError(try server.callTool(name: "workspace_reload", arguments: [:])) {
            XCTAssertTrue(String(describing: $0).contains("undo transactions"))
        }
        let read = try server.callTool(name: "file_read", arguments: [
            "workspace_id": fixture.workspaceID, "path": "original.txt",
        ])
        XCTAssertEqual((read["file"] as? JSONObject)?["content"] as? String, "keep undo")
        _ = try server.callTool(name: "transaction_restore", arguments: ["transaction_id": transaction])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("original.txt").path))
        XCTAssertEqual(try server.callTool(name: "workspace_reload", arguments: [:])["reloaded"] as? Bool, true)
        let marker = try server.callTool(name: "file_read", arguments: [
            "workspace_id": fixture.workspaceID, "path": "marker.txt",
        ])
        XCTAssertEqual((marker["file"] as? JSONObject)?["content"] as? String, "new root")
    }

    func testByteBudgetRefusesBeforeWriteAndRestorationReopensCapacity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try limitedService(fixture, count: 10, bytes: 4)
        let first = fixture.workspace.appendingPathComponent("first")
        let second = fixture.workspace.appendingPathComponent("second")
        try Data("1234".utf8).write(to: first)
        try Data("x".utf8).write(to: second)
        let write = try service.writeFile(workspaceID: fixture.workspaceID, path: "first",
            content: "done", encoding: "utf8", expectedSHA256: hash("1234"))
        XCTAssertThrowsError(try service.writeFile(workspaceID: fixture.workspaceID, path: "second",
            content: "changed", encoding: "utf8", expectedSHA256: hash("x")))
        XCTAssertEqual(try Data(contentsOf: second), Data("x".utf8))
        XCTAssertEqual(service.retainedTransactionCount, 1)
        _ = try service.restoreTransaction(XCTUnwrap(write["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: first), Data("1234".utf8))
        let append = try service.appendFile(workspaceID: fixture.workspaceID, path: "second",
            content: "y", encoding: "utf8", expectedSHA256: hash("x"))
        _ = try service.restoreTransaction(XCTUnwrap(append["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: second), Data("x".utf8))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testConflictingRestoreRetainsBudgetAndDoesNotEvictUndo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try limitedService(fixture, count: 1, bytes: 4)
        let file = fixture.workspace.appendingPathComponent("file")
        try Data("1234".utf8).write(to: file)
        let write = try service.writeFile(workspaceID: fixture.workspaceID, path: "file",
            content: "done", encoding: "utf8", expectedSHA256: hash("1234"))
        let id = try XCTUnwrap(write["transaction_id"] as? String)
        try Data("external edit".utf8).write(to: file)
        XCTAssertThrowsError(try service.restoreTransaction(id))
        XCTAssertThrowsError(try service.createDirectory(workspaceID: fixture.workspaceID, path: "refused"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("refused").path))
        XCTAssertEqual(service.retainedTransactionCount, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("external edit".utf8))
        try Data("done".utf8).write(to: file)
        XCTAssertThrowsError(try service.restoreTransaction(id),
                             "same bytes on a replacement inode are still an external revision")
        XCTAssertEqual(service.retainedTransactionCount, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("done".utf8))
    }

    func testZeroCountBudgetRefusesEveryMutationWithoutFilesystemEffects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try limitedService(fixture, count: 0, bytes: 100)
        let file = fixture.workspace.appendingPathComponent("file")
        try Data("original".utf8).write(to: file)
        XCTAssertThrowsError(try service.writeFile(workspaceID: fixture.workspaceID, path: "new",
            content: "new", encoding: "utf8", expectedSHA256: nil))
        XCTAssertThrowsError(try service.appendFile(workspaceID: fixture.workspaceID, path: "file",
            content: "append", encoding: "utf8", expectedSHA256: hash("original")))
        XCTAssertThrowsError(try service.patchFile(workspaceID: fixture.workspaceID, path: "file",
            oldText: "original", newText: "patch", replaceAll: false, expectedSHA256: hash("original")))
        XCTAssertThrowsError(try service.createDirectory(workspaceID: fixture.workspaceID, path: "directory"))
        XCTAssertThrowsError(try service.copyPath(workspaceID: fixture.workspaceID, sourcePath: "file", destinationPath: "copy"))
        XCTAssertThrowsError(try service.movePath(workspaceID: fixture.workspaceID, sourcePath: "file", destinationPath: "move"))
        XCTAssertThrowsError(try service.removePath(workspaceID: fixture.workspaceID, path: "file"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path), ["file"])
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testConcurrentMutationsCannotOversubscribeCountBudget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try limitedService(fixture, count: 1, bytes: 0)
        let workspaceID = fixture.workspaceID
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            _ = try? service.writeFile(workspaceID: workspaceID, path: "new-\(index)",
                content: "fixture", encoding: "utf8", expectedSHA256: nil)
        }
        XCTAssertEqual(service.retainedTransactionCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).count, 1)
        let id = try XCTUnwrap(service.observerTransactions().first?["transaction_id"] as? String)
        _ = try service.restoreTransaction(id)
        XCTAssertEqual(service.retainedTransactionCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).isEmpty)
    }

    private func limitedService(_ fixture: Fixture, count: Int, bytes: Int) throws -> LocalWorkspaceService {
        LocalWorkspaceService(registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
                              transactionLimit: count, undoFileByteLimit: bytes)
    }

    private func hash(_ value: String) -> String { LocalHash.sha256(Data(value.utf8)) }
}
