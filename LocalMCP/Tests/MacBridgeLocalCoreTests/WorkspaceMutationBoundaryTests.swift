import Darwin
import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class WorkspaceMutationBoundaryTests: XCTestCase {
    func testAtomicWriteAppliesRequestedModeDespiteProcessUmask() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let directory = try WorkspaceDirectory(fixture.workspace)
        try directory.atomicWrite(
            Data("mode".utf8), name: "mode.txt", mode: 0o666, replacing: false
        )
        XCTAssertEqual(
            posixMode(try lstatValue(fixture.workspace.appendingPathComponent("mode.txt").path)),
            0o666
        )
    }

    func testProtectedRuntimeFileAndContainingDirectoryRejectAllMutationPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtimeDirectory = fixture.workspace.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: false)
        let runtime = runtimeDirectory.appendingPathComponent("macbridge-mcp")
        let original = Data("reviewed runtime".utf8)
        try original.write(to: runtime)
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            protectedMutationPaths: [runtime.path]
        )

        XCTAssertThrowsError(try service.writeFile(
            workspaceID: fixture.workspaceID, path: "runtime/macbridge-mcp",
            content: "replacement", encoding: "utf8",
            expectedSHA256: LocalHash.sha256(original)
        ))
        XCTAssertThrowsError(try service.appendFile(
            workspaceID: fixture.workspaceID, path: "runtime/macbridge-mcp",
            content: "append", encoding: "utf8",
            expectedSHA256: LocalHash.sha256(original)
        ))
        XCTAssertThrowsError(try service.patchFile(
            workspaceID: fixture.workspaceID, path: "runtime/macbridge-mcp",
            oldText: "reviewed", newText: "replacement", replaceAll: false,
            expectedSHA256: LocalHash.sha256(original)
        ))
        XCTAssertThrowsError(try service.writeFilesAtomic(
            workspaceID: fixture.workspaceID,
            requests: [
                AtomicFileWriteRequest(
                    path: "ordinary-batch.txt", content: "must not be created",
                    expectedSHA256: nil, createOnly: true
                ),
                AtomicFileWriteRequest(
                    path: "runtime/macbridge-mcp", content: "replacement",
                    expectedSHA256: LocalHash.sha256(original), createOnly: false
                ),
            ]
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("ordinary-batch.txt").path
        ))
        XCTAssertThrowsError(try service.movePath(
            workspaceID: fixture.workspaceID,
            sourcePath: "runtime/macbridge-mcp", destinationPath: "moved-core"
        ))
        XCTAssertThrowsError(try service.movePath(
            workspaceID: fixture.workspaceID,
            sourcePath: "runtime", destinationPath: "moved-runtime"
        ))
        XCTAssertThrowsError(try service.removePath(
            workspaceID: fixture.workspaceID, path: "runtime"
        ))
        XCTAssertEqual(try Data(contentsOf: runtime), original)
        XCTAssertEqual(service.retainedTransactionCount, 0)

        XCTAssertNoThrow(try service.writeFile(
            workspaceID: fixture.workspaceID, path: "ordinary.txt",
            content: "allowed", encoding: "utf8", expectedSHA256: nil
        ))
    }

    func testTreeSnapshotRejectsChildInsertedAfterDirectoryEnumeration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = fixture.workspace.appendingPathComponent("tree")
        let nested = tree.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: nested.appendingPathComponent("original"))
        let directory = try WorkspaceDirectory(fixture.workspace)
        var inserted = false
        XCTAssertThrowsError(try directory.snapshot("tree", logicalPath: tree.path,
            afterDirectoryEnumerationForTesting: { path in
                if path == nested.path {
                    try Data("concurrent addition".utf8).write(to: nested.appendingPathComponent("added"))
                    inserted = true
                }
            }))
        XCTAssertTrue(inserted)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("original")), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("added")), Data("concurrent addition".utf8))
    }

    func testVerifiedTreeRemovalRefusesAddedOrChangedEntriesBeforeDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = fixture.workspace.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let first = tree.appendingPathComponent("a-original")
        let second = tree.appendingPathComponent("z-original")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let directory = try WorkspaceDirectory(fixture.workspace)
        let beforeAddition = try directory.snapshot("tree", logicalPath: tree.path)
        let added = tree.appendingPathComponent("added")
        try Data("keep added".utf8).write(to: added)
        XCTAssertThrowsError(try directory.removeVerifiedTree(beforeAddition))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: added), Data("keep added".utf8))

        let beforeChange = try directory.snapshot("tree", logicalPath: tree.path)
        try Data("changed in place; preserve all earlier entries too".utf8).write(to: second)
        XCTAssertThrowsError(try directory.removeVerifiedTree(beforeChange))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("changed in place; preserve all earlier entries too".utf8))
        XCTAssertEqual(try Data(contentsOf: added), Data("keep added".utf8))
    }

    func testVerifiedTreeRemovalNeverSelectsChildAddedDuringDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = fixture.workspace.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: tree.appendingPathComponent("original"))
        let directory = try WorkspaceDirectory(fixture.workspace)
        let snapshot = try directory.snapshot("tree", logicalPath: tree.path)
        var inserted = false
        XCTAssertThrowsError(try directory.removeVerifiedTree(snapshot,
            beforeEntryRemovalForTesting: { name in
                if name == "original" {
                    try Data("keep new child".utf8).write(to: tree.appendingPathComponent("added"))
                    inserted = true
                }
            }))
        XCTAssertTrue(inserted)
        XCTAssertEqual(try Data(contentsOf: tree.appendingPathComponent("added")), Data("keep new child".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
    }

    func testVerifiedTreeRemovalRefusesAChildChangedDuringDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = fixture.workspace.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let file = tree.appendingPathComponent("original")
        try Data("original".utf8).write(to: file)
        let directory = try WorkspaceDirectory(fixture.workspace)
        let snapshot = try directory.snapshot("tree", logicalPath: tree.path)
        XCTAssertThrowsError(try directory.removeVerifiedTree(snapshot,
            beforeEntryRemovalForTesting: { name in
                if name == "original" { try Data("concurrently changed".utf8).write(to: file) }
            }))
        XCTAssertEqual(try Data(contentsOf: file), Data("concurrently changed".utf8))
    }

    func testCapturedDirectoryDoesNotFollowReplacedParentForMutations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parent = fixture.workspace.appendingPathComponent("parent")
        let parked = fixture.workspace.appendingPathComponent("parked")
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("external edit".utf8).write(to: outside.appendingPathComponent("target"))
        let held = try WorkspaceDirectory(parent)
        try FileManager.default.moveItem(at: parent, to: parked)
        XCTAssertEqual(symlink(outside.path, parent.path), 0)
        XCTAssertThrowsError(try WorkspaceDirectory(parent))

        try held.atomicWrite(Data("workspace".utf8), name: "target", mode: 0o600, replacing: false)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target")), Data("external edit".utf8))
        XCTAssertEqual(try Data(contentsOf: parked.appendingPathComponent("target")), Data("workspace".utf8))
        try held.rename("target", to: held, as: "moved")
        try held.removeTree("moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.appendingPathComponent("moved").path))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target")), Data("external edit".utf8))
    }

    func testCopyPublicationRacePreservesConcurrentDestinationAndSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("source.txt")
        let destination = fixture.workspace.appendingPathComponent("destination")
        try Data("original".utf8).write(to: source)
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            beforeCopyPublicationForTesting: {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("another task".utf8).write(to: destination.appendingPathComponent("keep.txt"))
            })
        XCTAssertThrowsError(try service.copyPath(workspaceID: fixture.workspaceID,
                                                  sourcePath: "source.txt", destinationPath: "destination"))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("keep.txt")), Data("another task".utf8))
        XCTAssertEqual(service.retainedTransactionCount, 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)
            .contains { $0.hasPrefix(".macbridge-copy-") })
    }

    func testNewFilePublicationDoesNotOverwriteAnExistingEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = try WorkspaceDirectory(fixture.workspace)
        try Data("concurrent".utf8).write(to: fixture.workspace.appendingPathComponent("target"))
        XCTAssertThrowsError(try directory.atomicWrite(Data("requested".utf8), name: "target", mode: 0o600, replacing: false))
        XCTAssertEqual(try Data(contentsOf: fixture.workspace.appendingPathComponent("target")), Data("concurrent".utf8))
    }

    func testCopyCleanupPreservesAReplacementOfItsStagingEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("source".utf8).write(to: fixture.workspace.appendingPathComponent("source"))
        var replaced: URL?
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            beforeCopyPublicationForTesting: {
                let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)
                    .first { $0.hasPrefix(".macbridge-copy-") })
                let staging = fixture.workspace.appendingPathComponent(name)
                try FileManager.default.moveItem(at: staging, to: fixture.workspace.appendingPathComponent("parked-stage"))
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                try Data("unowned replacement".utf8).write(to: staging.appendingPathComponent("keep"))
                replaced = staging
            })
        XCTAssertThrowsError(try service.copyPath(workspaceID: fixture.workspaceID,
                                                  sourcePath: "source", destinationPath: "target"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replaced).appendingPathComponent("keep")), Data("unowned replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("target").path))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testDirectoryCreateDoesNotAdoptConcurrentAdditionIntoUndo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.workspace.appendingPathComponent("created")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "create" else { return }
                XCTAssertEqual(relocated, destination)
                try Data("external".utf8).write(
                    to: relocated.appendingPathComponent("keep.txt")
                )
            }
        )

        XCTAssertThrowsError(try service.createDirectory(
            workspaceID: fixture.workspaceID, path: "created"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        XCTAssertEqual(receipt["kind"] as? String, "created_path")
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        XCTAssertThrowsError(try service.restoreTransaction(transactionID))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8),
            "external"
        )
        _ = try service.acceptTransactions([transactionID])
    }

    func testDirectoryCreateSnapshotFailureRestoresUnchangedPublishedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.workspace.appendingPathComponent("created")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "create" else { return }
                XCTAssertEqual(relocated, destination)
                throw LocalMCPError.operationFailed("injected post-publication failure")
            }
        )

        XCTAssertThrowsError(try service.createDirectory(
            workspaceID: fixture.workspaceID, path: "created"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        _ = try service.restoreTransaction(transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testDirectoryCreateFallbackDoesNotAdoptRootTimestampChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.workspace.appendingPathComponent("created")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "create" else { return }
                XCTAssertEqual(relocated, destination)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                    ofItemAtPath: relocated.path
                )
                throw LocalMCPError.operationFailed("injected post-publication failure")
            }
        )

        XCTAssertThrowsError(try service.createDirectory(
            workspaceID: fixture.workspaceID, path: "created"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        XCTAssertThrowsError(try service.restoreTransaction(transactionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(service.retainedTransactionCount, 1)
        _ = try service.acceptTransactions([transactionID])
    }

    func testDirectoryCreateSuccessPathDoesNotAdoptRootTimestampChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.workspace.appendingPathComponent("created")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "create" else { return }
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                    ofItemAtPath: relocated.path
                )
            }
        )

        XCTAssertThrowsError(try service.createDirectory(
            workspaceID: fixture.workspaceID, path: "created"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        XCTAssertThrowsError(try service.restoreTransaction(transactionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(service.retainedTransactionCount, 1)
        _ = try service.acceptTransactions([transactionID])
    }

    func testCopySnapshotFailureRestoresUnchangedPublishedCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("copy-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appendingPathComponent("source.txt"))
        let destination = fixture.workspace.appendingPathComponent("copy-destination")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "copy" else { return }
                XCTAssertEqual(relocated, destination)
                throw LocalMCPError.operationFailed("injected post-publication failure")
            }
        )

        XCTAssertThrowsError(try service.copyPath(
            workspaceID: fixture.workspaceID,
            sourcePath: "copy-source", destinationPath: "copy-destination"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        _ = try service.restoreTransaction(transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("source.txt"), encoding: .utf8),
            "source"
        )
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testCopyFallbackDoesNotAdoptRootTimestampChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("copy-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appendingPathComponent("source.txt"))
        let destination = fixture.workspace.appendingPathComponent("copy-destination")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "copy" else { return }
                XCTAssertEqual(relocated, destination)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                    ofItemAtPath: relocated.path
                )
                throw LocalMCPError.operationFailed("injected post-publication failure")
            }
        )

        XCTAssertThrowsError(try service.copyPath(
            workspaceID: fixture.workspaceID,
            sourcePath: "copy-source", destinationPath: "copy-destination"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        XCTAssertThrowsError(try service.restoreTransaction(transactionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8),
            "source"
        )
        XCTAssertEqual(service.retainedTransactionCount, 1)
        _ = try service.acceptTransactions([transactionID])
    }

    func testCopySuccessPathDoesNotAdoptRootTimestampChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("copy-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appendingPathComponent("source.txt"))
        let destination = fixture.workspace.appendingPathComponent("copy-destination")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "copy" else { return }
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                    ofItemAtPath: relocated.path
                )
            }
        )

        XCTAssertThrowsError(try service.copyPath(
            workspaceID: fixture.workspaceID,
            sourcePath: "copy-source", destinationPath: "copy-destination"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        XCTAssertThrowsError(try service.restoreTransaction(transactionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(service.retainedTransactionCount, 1)
        _ = try service.acceptTransactions([transactionID])
    }

    func testCopySnapshotFailureRetainsConservativeUndoWithoutDeletingConcurrentEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("copy-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appendingPathComponent("source.txt"))
        let destination = fixture.workspace.appendingPathComponent("copy-destination")
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, relocated in
                guard operation == "copy" else { return }
                XCTAssertEqual(relocated, destination)
                try FileManager.default.createSymbolicLink(
                    at: relocated.appendingPathComponent("external-link"),
                    withDestinationURL: source.appendingPathComponent("source.txt")
                )
            }
        )

        XCTAssertThrowsError(try service.copyPath(
            workspaceID: fixture.workspaceID,
            sourcePath: "copy-source", destinationPath: "copy-destination"
        ))
        let receipt = try XCTUnwrap(
            (try service.listTransactions()["transactions"] as? [JSONObject])?.first
        )
        XCTAssertEqual(receipt["kind"] as? String, "created_path")
        let transactionID = try XCTUnwrap(receipt["transaction_id"] as? String)
        XCTAssertThrowsError(try service.restoreTransaction(transactionID))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: destination.appendingPathComponent("external-link").path
            ),
            source.appendingPathComponent("source.txt").path
        )
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("source.txt"), encoding: .utf8),
            "source"
        )
        _ = try service.acceptTransactions([transactionID])
    }

    func testWebTunnelPartialMutationReturnsUsableRecoveryCapability() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("move-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, original, _ in
                guard operation == "move" else { return }
                try FileManager.default.createDirectory(
                    at: original, withIntermediateDirectories: false
                )
                throw LocalMCPError.operationFailed("injected post-publication failure")
            }
        )
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel,
            observationEnabled: false,
            searchStartForTesting: nil,
            workspaceServiceForTesting: service
        )
        var transactionID: String?
        var transactionToken: String?
        XCTAssertThrowsError(try server.callTool(name: "path_move", arguments: [
            "workspace_id": fixture.workspaceID,
            "source_path": "move-source",
            "destination_path": "move-destination",
        ])) { error in
            guard case LocalMCPError.recoveryRequired(_, let receipts) = error else {
                return XCTFail("expected recoveryRequired, received \(error)")
            }
            let receipt = receipts.first
            transactionID = receipt?.transactionID
            transactionToken = receipt?.transactionControlToken
            XCTAssertNotNil(transactionID)
            XCTAssertNotNil(transactionToken)
            XCTAssertEqual(
                (localErrorDetail(error)["recovery_transactions"] as? [JSONObject])?.count,
                1
            )
        }
        try FileManager.default.removeItem(at: source)
        _ = try server.callTool(name: "transaction_restore", arguments: [
            "transaction_id": try XCTUnwrap(transactionID),
            "transaction_control_token": try XCTUnwrap(transactionToken),
        ])
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8),
            "payload"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("move-destination").path
        ))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testWebTunnelCreateSnapshotFailureReturnsUsableRecoveryCapability() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            afterRelocationBeforeSnapshotForTesting: { operation, _, _ in
                guard operation == "create" else { return }
                throw LocalMCPError.operationFailed("injected post-publication failure")
            }
        )
        let server = try LocalMCPServer(
            configurationURL: fixture.config,
            selfExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            connectorSurface: .webTunnel,
            observationEnabled: false,
            searchStartForTesting: nil,
            workspaceServiceForTesting: service
        )
        var transactionID: String?
        var transactionToken: String?
        XCTAssertThrowsError(try server.callTool(name: "directory_create", arguments: [
            "workspace_id": fixture.workspaceID,
            "path": "created",
        ])) { error in
            guard case LocalMCPError.recoveryRequired(_, let receipts) = error else {
                return XCTFail("expected recoveryRequired, received \(error)")
            }
            transactionID = receipts.first?.transactionID
            transactionToken = receipts.first?.transactionControlToken
        }
        _ = try server.callTool(name: "transaction_restore", arguments: [
            "transaction_id": try XCTUnwrap(transactionID),
            "transaction_control_token": try XCTUnwrap(transactionToken),
        ])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent("created").path
        ))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testCopyPreservesFileMetadataAndRestoresOrdinaryTrees() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("program")
        try Data("synthetic bytes".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o751), 0)
        let attribute = Data("preserve metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes {
            setxattr(file.path, "com.macbridge.tests.marker", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let service = try fixture.service()
        let copied = try service.copyPath(workspaceID: fixture.workspaceID, sourcePath: "source", destinationPath: "copied")
        let output = fixture.workspace.appendingPathComponent("copied/program")
        XCTAssertEqual(try Data(contentsOf: output), Data("synthetic bytes".utf8))
        XCTAssertEqual(posixMode(try lstatValue(output.path)), 0o751)
        var copiedAttribute = Data(count: 64)
        let count = copiedAttribute.withUnsafeMutableBytes {
            getxattr(output.path, "com.macbridge.tests.marker", $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(count, attribute.count)
        XCTAssertEqual(copiedAttribute.prefix(max(0, count)), attribute)
        _ = try service.restoreTransaction(try XCTUnwrap(copied["transaction_id"] as? String))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("copied").path))
        XCTAssertEqual(try Data(contentsOf: file), Data("synthetic bytes".utf8))
    }

    func testOversizedReplaceAllRefusesBeforeMutationAndUnicodeControlWorks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.workspace.appendingPathComponent("patch.txt")
        let original = Data(String(repeating: "a", count: 8192).utf8)
        try original.write(to: target)
        let service = try fixture.service()
        XCTAssertThrowsError(try service.patchFile(workspaceID: fixture.workspaceID, path: "patch.txt",
            oldText: "a", newText: String(repeating: "b", count: 4096), replaceAll: true,
            expectedSHA256: LocalHash.sha256(original)))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(service.retainedTransactionCount, 0)

        let unicode = Data("e\u{301} e\u{301}".utf8)
        try unicode.write(to: target)
        let receipt = try service.patchFile(workspaceID: fixture.workspaceID, path: "patch.txt",
            oldText: "é", newText: "🙂", replaceAll: true, expectedSHA256: LocalHash.sha256(unicode))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "🙂 🙂")
        _ = try service.restoreTransaction(try XCTUnwrap(receipt["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: target), unicode)
    }

    func testDirectoryEnumerationStopsAtCountAndByteBudgets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0..<30 {
            try Data().write(to: fixture.workspace.appendingPathComponent(String(format: "%03d-entry", index)))
        }
        let directory = try WorkspaceDirectory(fixture.workspace)
        let limited = try directory.names(maximumCount: 4)
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(limited.values.count, 4)
        XCTAssertEqual(limited.values, limited.values.sorted())
        let bytes = try directory.names(maximumBytes: 18)
        XCTAssertTrue(bytes.limited)
        XCTAssertLessThanOrEqual(bytes.values.reduce(0) { $0 + $1.utf8.count }, 18)
        let complete = try directory.names()
        XCTAssertFalse(complete.limited)
        XCTAssertEqual(complete.values.count, 30)
    }

    func testTreeCopyAndCleanupRefuseOrUnlinkLinksWithoutFollowingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep"))
        let root = try WorkspaceDirectory(fixture.workspace)
        try root.makeDirectory("source")
        XCTAssertEqual(symlink(outside.path, fixture.workspace.appendingPathComponent("source/link").path), 0)
        XCTAssertThrowsError(try root.digest("source", logicalPath: fixture.workspace.appendingPathComponent("source").path))
        try root.removeTree("source")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep")), Data("keep".utf8))
    }

    func testMovePathRejectsAlternateCasingOfProtectedAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let anchor = fixture.workspace.appendingPathComponent("Synthetic-Anchor")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        try Data("preserve".utf8).write(to: anchor.appendingPathComponent("keep"))
        let alternative = fixture.workspace.appendingPathComponent("sYNTHETIC-aNCHOR")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alternative.path),
                      "Security qualification requires a case-insensitive fixture volume")
        guard FileManager.default.fileExists(atPath: alternative.path) else { return }
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            relocationProtectedPathsForTesting: [anchor.path])
        XCTAssertThrowsError(try service.movePath(workspaceID: fixture.workspaceID,
            sourcePath: alternative.lastPathComponent, destinationPath: "moved-anchor"))
        XCTAssertEqual(try Data(contentsOf: anchor.appendingPathComponent("keep")), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("moved-anchor").path))
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testMovePathAppliesProtectedAnchorGuardBeforeAnyMutation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let anchor = fixture.workspace.appendingPathComponent("synthetic-anchor")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        try Data("preserve".utf8).write(to: anchor.appendingPathComponent("keep"))
        let service = LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: fixture.config),
            transactionLimit: 10, undoFileByteLimit: 1_048_576,
            relocationProtectedPathsForTesting: [anchor.path])
        XCTAssertThrowsError(try service.movePath(workspaceID: fixture.workspaceID,
            sourcePath: "synthetic-anchor", destinationPath: "moved-anchor"))
        XCTAssertEqual(try Data(contentsOf: anchor.appendingPathComponent("keep")), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("moved-anchor").path))
        XCTAssertEqual(service.retainedTransactionCount, 0)

        try Data("ordinary".utf8).write(to: fixture.workspace.appendingPathComponent("ordinary"))
        let moved = try service.movePath(workspaceID: fixture.workspaceID, sourcePath: "ordinary", destinationPath: "moved")
        _ = try service.restoreTransaction(try XCTUnwrap(moved["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: fixture.workspace.appendingPathComponent("ordinary")), Data("ordinary".utf8))
    }
}
