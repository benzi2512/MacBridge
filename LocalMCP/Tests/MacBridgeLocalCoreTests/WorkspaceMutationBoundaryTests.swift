import Darwin
import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class WorkspaceMutationBoundaryTests: XCTestCase {
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
        guard FileManager.default.fileExists(atPath: alternative.path) else {
            throw XCTSkip("Alternate-casing regression requires a case-insensitive fixture volume")
        }
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
