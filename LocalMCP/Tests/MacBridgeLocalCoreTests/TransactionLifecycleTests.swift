import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class TransactionLifecycleTests: XCTestCase {
    func testAcceptKeepsCurrentBytesAndReleasesExactUndoBudget() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try limited(f)
        let file = f.workspace.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        let id = try write(service, f, "file", "after", previous: "before")
        XCTAssertEqual(try service.listTransactions()["retained_undo_file_bytes"] as? Int, 6)
        XCTAssertThrowsError(try service.writeFile(workspaceID: f.workspaceID, path: "blocked",
            content: "x", encoding: "utf8", expectedSHA256: nil))
        let accepted = try service.acceptTransactions([id.uppercased()])
        XCTAssertEqual(accepted["released_undo_file_bytes"] as? Int, 6)
        XCTAssertEqual(accepted["retained_undo_file_bytes"] as? Int, 0)
        XCTAssertEqual(accepted["filesystem_mutation_performed"] as? Bool, false)
        XCTAssertEqual(accepted["current_file_state_validated"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: file), Data("after".utf8))
        XCTAssertThrowsError(try service.restoreTransaction(id))
        XCTAssertThrowsError(try service.acceptTransactions([id]))
        let next = try write(service, f, "new", "kept")
        _ = try service.acceptTransactions([next])
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testWholeBatchPreflightPreservesAllUndoOnAnyInvalidID() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        let a = try write(service, f, "a", "a")
        let b = try write(service, f, "b", "b")
        for ids in [[String](), [a, "not-a-uuid"], [a, UUID().uuidString],
                    [a, a.uppercased()], Array(repeating: a, count: 129)] {
            XCTAssertThrowsError(try service.acceptTransactions(ids))
            XCTAssertEqual(service.retainedTransactionCount, 2)
        }
        let result = try service.acceptTransactions([b, a])
        XCTAssertEqual((result["accepted"] as? [JSONObject])?.compactMap { $0["transaction_id"] as? String }, [b, a])
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("a"), encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("b"), encoding: .utf8), "b")
    }

    func testKeysetPagesSurviveEarlierRemovalAndNeverExposeBeforeContent() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        let file = f.workspace.appendingPathComponent("a")
        try Data("synthetic-before-only-content".utf8).write(to: file)
        let a = try write(service, f, "a", "after", previous: "synthetic-before-only-content")
        let b = try write(service, f, "b", "b")
        let c = try write(service, f, "c", "c")
        let page = try service.listTransactions(maximumTransactions: 1)
        let cursor = try XCTUnwrap(page["next_cursor"] as? String)
        XCTAssertEqual(page["complete"] as? Bool, false)
        XCTAssertFalse(String(decoding: try LocalJSON.encode(page), as: UTF8.self).contains("synthetic-before-only-content"))
        _ = try service.acceptTransactions([a, b])
        let d = try write(service, f, "d", "d")
        let rest = try service.listTransactions(cursor: cursor)
        XCTAssertEqual((rest["transactions"] as? [JSONObject])?.compactMap { $0["transaction_id"] as? String }, [c, d])
        XCTAssertEqual(rest["complete"] as? Bool, true)
        XCTAssertNil(rest["next_cursor"])
        for limit in [-1, 0, 101, Int.max] {
            XCTAssertThrowsError(try service.listTransactions(maximumTransactions: limit))
        }
        XCTAssertThrowsError(try service.listTransactions(cursor: ""))
        XCTAssertThrowsError(try service.listTransactions(cursor: "bad:1"))
        XCTAssertThrowsError(try f.service().listTransactions(cursor: cursor))
    }

    func testAcceptedRemovalPreservesPayloadAndManualRecoveryReceipt() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        let file = f.workspace.appendingPathComponent("remove.txt")
        let bytes = Data("recoverable-fixture".utf8)
        try bytes.write(to: file)
        let removed = try service.removePath(workspaceID: f.workspaceID, path: "remove.txt")
        let id = try XCTUnwrap(removed["transaction_id"] as? String)
        let recovery = try XCTUnwrap(removed["recovery_path"] as? String)
        let result = try service.acceptTransactions([id])
        let receipt = try XCTUnwrap((result["accepted"] as? [JSONObject])?.first)
        XCTAssertEqual(receipt["recovery_path"] as? String, recovery)
        XCTAssertEqual(receipt["recovery_payload_preserved"] as? Bool, true)
        XCTAssertEqual(receipt["manual_recovery_required"] as? Bool, true)
        XCTAssertEqual(receipt["expected_recovery_tree_sha256"] as? String, removed["tree_sha256"] as? String)
        XCTAssertEqual(try Data(contentsOf: f.workspace.appendingPathComponent(recovery)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testAcceptDoesNotRevertExternalEditOrOtherTransactions() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try f.service()
        let a = try write(service, f, "a", "owned")
        let b = try write(service, f, "b", "keep undo")
        try Data("external change".utf8).write(to: f.workspace.appendingPathComponent("a"))
        _ = try service.acceptTransactions([a])
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("a"), encoding: .utf8), "external change")
        XCTAssertEqual(service.retainedTransactionCount, 1)
        _ = try service.restoreTransaction(b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("b").path))
    }

    func testServerOwnerBindingReloadCursorAndClosedSchemas() throws {
        let f = try Fixture(); defer { f.remove() }
        let server = try LocalMCPServer(configurationURL: f.config, selfExecutable: URL(fileURLWithPath: "/usr/bin/true"))
        var ids: [String] = []
        for name in ["a", "b"] {
            ids.append(try XCTUnwrap(server.callTool(name: "file_write", arguments: [
                "workspace_id": f.workspaceID, "path": name, "content": "kept",
            ])["transaction_id"] as? String))
        }
        let list = try server.callTool(name: "transaction_list", arguments: ["maximum_transactions": 1])
        let instance = try XCTUnwrap(list["instance_id"] as? String)
        let cursor = try XCTUnwrap(list["next_cursor"] as? String)
        XCTAssertThrowsError(try server.callTool(name: "workspace_reload", arguments: [:]))
        let invalidArguments: [JSONObject] = [
            ["transaction_ids": ids],
            ["instance_id": UUID().uuidString, "transaction_ids": ids],
            ["instance_id": instance, "transaction_ids": ids, "all": true],
            ["instance_id": instance, "transaction_ids": [1]],
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(try server.callTool(name: "transaction_accept", arguments: arguments))
        }
        XCTAssertEqual(try server.callTool(name: "transaction_list", arguments: [:])["retained_transaction_count"] as? Int, 2)
        _ = try server.callTool(name: "transaction_accept", arguments: ["instance_id": instance, "transaction_ids": ids])
        XCTAssertEqual(try server.callTool(name: "workspace_reload", arguments: [:])["reloaded"] as? Bool, true)
        XCTAssertThrowsError(try server.callTool(name: "transaction_list", arguments: ["cursor": cursor]))
        XCTAssertThrowsError(try server.callTool(name: "transaction_list", arguments: ["maximum_transactions": true]))
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("a"), encoding: .utf8), "kept")
    }

    func testConcurrentAcceptAndRestoreReleaseCapacityExactlyOnce() throws {
        let f = try Fixture(); defer { f.remove() }
        let service = try limited(f)
        try Data("before".utf8).write(to: f.workspace.appendingPathComponent("file"))
        let id = try write(service, f, "file", "after", previous: "before")
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 { _ = try? service.acceptTransactions([id]) }
            else { _ = try? service.restoreTransaction(id) }
        }
        XCTAssertEqual(service.retainedTransactionCount, 0)
        XCTAssertEqual(try service.listTransactions()["retained_undo_file_bytes"] as? Int, 0)
        let data = try String(contentsOf: f.workspace.appendingPathComponent("file"), encoding: .utf8)
        XCTAssertTrue(["before", "after"].contains(data))
        let next = try write(service, f, "file", "last", previous: data)
        _ = try service.acceptTransactions([next])
        XCTAssertEqual(try service.listTransactions()["retained_undo_file_bytes"] as? Int, 0)
    }

    func testCatalogDeclaresIrreversibleUndoReleaseAndReadOnlyListing() throws {
        let accept = try XCTUnwrap(LocalMCPServer.toolSpecs.first { $0["name"] as? String == "transaction_accept" })
        let annotations = try XCTUnwrap(accept["annotations"] as? JSONObject)
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
        XCTAssertEqual(annotations["idempotentHint"] as? Bool, false)
        let list = try XCTUnwrap(LocalMCPServer.toolSpecs.first { $0["name"] as? String == "transaction_list" })
        XCTAssertEqual((list["annotations"] as? JSONObject)?["readOnlyHint"] as? Bool, true)
    }

    private func limited(_ fixture: Fixture) throws -> LocalWorkspaceService {
        LocalWorkspaceService(registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
                              transactionLimit: 1, undoFileByteLimit: 6)
    }

    private func write(_ service: LocalWorkspaceService, _ f: Fixture, _ path: String,
                       _ content: String, previous: String? = nil) throws -> String {
        try XCTUnwrap(service.writeFile(workspaceID: f.workspaceID, path: path,
            content: content, encoding: "utf8", expectedSHA256: previous.map { LocalHash.sha256(Data($0.utf8)) })["transaction_id"] as? String)
    }
}
