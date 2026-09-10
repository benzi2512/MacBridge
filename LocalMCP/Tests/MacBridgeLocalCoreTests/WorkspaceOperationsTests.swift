import Darwin
import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class WorkspaceOperationsTests: XCTestCase {
    func testRecursiveReadsPreserveReadableResultsAndReportInaccessibleChildren() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let locked = fixture.workspace.appendingPathComponent("locked")
        let deniedFile = fixture.workspace.appendingPathComponent("denied.txt")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("needle hidden\n".utf8).write(to: locked.appendingPathComponent("hidden.txt"))
        try Data("needle denied\n".utf8).write(to: deniedFile)
        try Data("needle visible\n".utf8).write(to: fixture.workspace.appendingPathComponent("visible.txt"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        XCTAssertEqual(chmod(deniedFile.path, 0), 0)
        defer {
            _ = chmod(locked.path, 0o700)
            _ = chmod(deniedFile.path, 0o600)
        }
        let service = try fixture.service()
        let listing = try service.listDirectory(
            workspaceID: fixture.workspaceID, path: ".", recursive: true, maximumEntries: 100)
        XCTAssertTrue((listing["entries"] as? [JSONObject])?.contains {
            $0["relative_path"] as? String == "visible.txt"
        } == true)
        XCTAssertEqual(listing["partial"] as? Bool, true)
        XCTAssertEqual(listing["complete"] as? Bool, false)
        XCTAssertEqual(listing["skipped_inaccessible_paths"] as? Int, 1)
        XCTAssertEqual(listing["skipped_path_samples"] as? [String], ["locked"])
        XCTAssertNil(listing["next_cursor"])

        let search = try service.searchFiles(
            workspaceID: fixture.workspaceID, path: ".", query: "NEEDLE",
            caseSensitive: false, maximumResults: 100, maximumFileBytes: 1_024)
        XCTAssertEqual((search["matches"] as? [JSONObject])?.compactMap {
            $0["relative_path"] as? String
        }, ["visible.txt"])
        XCTAssertEqual(search["partial"] as? Bool, true)
        XCTAssertEqual(search["complete"] as? Bool, false)
        XCTAssertEqual(search["skipped_inaccessible_paths"] as? Int, 2)
        XCTAssertEqual(search["skipped_path_samples"] as? [String], ["denied.txt", "locked"])
        XCTAssertNil(search["next_cursor"])

        // Explicitly requesting an unreadable root still fails; no permission bypass.
        XCTAssertThrowsError(try service.listDirectory(
            workspaceID: fixture.workspaceID, path: "locked", recursive: true, maximumEntries: 100))
        XCTAssertThrowsError(try service.searchFiles(
            workspaceID: fixture.workspaceID, path: "locked", query: "needle",
            caseSensitive: true, maximumResults: 100, maximumFileBytes: 1_024))
        // Mutations must not treat an incomplete digest as a valid snapshot.
        XCTAssertThrowsError(try service.copyPath(
            workspaceID: fixture.workspaceID, sourcePath: "locked", destinationPath: "copy"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("copy").path))
    }

    func testTraversalLimitDoesNotClaimAFlatDirectoryIsComplete() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for index in 0...LocalWorkspaceService.maximumTreeEntries {
            try Data().write(to: fixture.workspace.appendingPathComponent("item-\(index).txt"))
        }
        let service = try fixture.service()
        let listing = try service.listDirectory(
            workspaceID: fixture.workspaceID, path: ".", recursive: false,
            maximumEntries: LocalWorkspaceService.maximumTreeEntries)
        XCTAssertEqual(listing["returned_entries"] as? Int, LocalWorkspaceService.maximumTreeEntries)
        XCTAssertEqual(listing["complete"] as? Bool, false)
        XCTAssertEqual(listing["limit_reached"] as? Bool, true)
        var pagedCount = 0
        var pagedScans = 0
        var cursor = 0
        while true {
            let page = try service.listDirectory(workspaceID: fixture.workspaceID,
                path: ".", recursive: false, maximumEntries: 128, cursor: cursor)
            pagedCount += try XCTUnwrap(page["returned_entries"] as? Int)
            pagedScans += try XCTUnwrap(page["scanned_entries"] as? Int)
            if let next = page["next_cursor"] as? Int {
                XCTAssertGreaterThan(next, cursor)
                cursor = next
            } else {
                XCTAssertEqual(page["complete"] as? Bool, false)
                XCTAssertEqual(page["limit_reached"] as? Bool, true)
                break
            }
        }
        XCTAssertEqual(pagedCount, LocalWorkspaceService.maximumTreeEntries)
        XCTAssertEqual(pagedScans, pagedCount)
        let search = try service.searchFiles(
            workspaceID: fixture.workspaceID, path: ".", query: "not-present",
            caseSensitive: true, maximumResults: 10, maximumFileBytes: 1_024, mode: "name")
        XCTAssertEqual(search["scanned_entries"] as? Int, LocalWorkspaceService.maximumTreeEntries)
        XCTAssertEqual(search["complete"] as? Bool, false)
        XCTAssertEqual(search["limit_reached"] as? Bool, true)
        try FileManager.default.removeItem(at: fixture.workspace.appendingPathComponent("item-10000.txt"))
        let exact = try service.listDirectory(
            workspaceID: fixture.workspaceID, path: ".", recursive: false,
            maximumEntries: LocalWorkspaceService.maximumTreeEntries)
        XCTAssertEqual(exact["complete"] as? Bool, true)
        XCTAssertEqual(exact["limit_reached"] as? Bool, false)
    }

    func testHashEncodingPreservesKnownDigestsAndStreamedBytes() throws {
        XCTAssertEqual(LocalHash.sha256(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(LocalHash.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data((0..<1_100_000).map { UInt8(truncatingIfNeeded: $0) })
        let file = fixture.workspace.appendingPathComponent("hash.bin")
        try bytes.write(to: file)
        XCTAssertEqual(try LocalHash.sha256(fileAt: file), LocalHash.sha256(bytes))
        XCTAssertTrue(LocalHash.isSHA256(try LocalHash.sha256(fileAt: file)))
        XCTAssertThrowsError(try LocalHash.sha256(fileAt: file, maximumBytes: 100))
    }

    func testConfigurationRejectsLeafSymlinkAndWritableFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let linkedConfiguration = fixture.root.appendingPathComponent("linked-workspaces.json")
        XCTAssertEqual(symlink(fixture.config.path, linkedConfiguration.path), 0)
        XCTAssertThrowsError(
            try LocalWorkspaceRegistry(configurationURL: linkedConfiguration)
        )

        XCTAssertEqual(chmod(fixture.config.path, 0o622), 0)
        XCTAssertThrowsError(
            try LocalWorkspaceRegistry(configurationURL: fixture.config)
        )

        XCTAssertEqual(chmod(fixture.config.path, 0o600), 0)
        let hardlinkedConfiguration = fixture.root.appendingPathComponent("hardlinked.json")
        XCTAssertEqual(link(fixture.config.path, hardlinkedConfiguration.path), 0)
        XCTAssertThrowsError(
            try LocalWorkspaceRegistry(configurationURL: fixture.config)
        )
    }

    func testConfigurationRejectsHomeAndItsAncestorsAsWorkspaceRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        try fixture.replaceConfiguration(workspacePath: home.path)
        XCTAssertThrowsError(try LocalWorkspaceRegistry(configurationURL: fixture.config))

        try fixture.replaceConfiguration(workspacePath: home.deletingLastPathComponent().path)
        XCTAssertThrowsError(try LocalWorkspaceRegistry(configurationURL: fixture.config))
    }

    func testReadListStatAndSearchStayInsideRegisteredWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("alpha\nneedle value\nomega\n".utf8).write(
            to: fixture.workspace.appendingPathComponent("notes.txt")
        )
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent("Sources"),
            withIntermediateDirectories: false
        )
        try Data("let marker = \"needle\"\n".utf8).write(
            to: fixture.workspace.appendingPathComponent("Sources/main.swift")
        )

        let service = try fixture.service()
        let list = try service.listDirectory(
            workspaceID: fixture.workspaceID,
            path: ".",
            recursive: true,
            maximumEntries: 100
        )
        let entries = try XCTUnwrap(list["entries"] as? [JSONObject])
        XCTAssertTrue(entries.contains { $0["relative_path"] as? String == "notes.txt" })
        XCTAssertTrue(entries.contains { $0["relative_path"] as? String == "Sources/main.swift" })

        let read = try service.readFile(
            workspaceID: fixture.workspaceID,
            path: "notes.txt",
            encoding: "utf8",
            maximumBytes: 1_024
        )
        let file = try XCTUnwrap(read["file"] as? JSONObject)
        XCTAssertEqual(file["content"] as? String, "alpha\nneedle value\nomega\n")
        XCTAssertEqual(
            file["sha256"] as? String, LocalHash.sha256(Data("alpha\nneedle value\nomega\n".utf8)))

        let stat = try service.statPath(
            workspaceID: fixture.workspaceID,
            path: "notes.txt"
        )
        XCTAssertEqual((stat["path"] as? JSONObject)?["kind"] as? String, "file")

        let search = try service.searchFiles(
            workspaceID: fixture.workspaceID,
            path: ".",
            query: "needle",
            caseSensitive: true,
            maximumResults: 10,
            maximumFileBytes: 1_024
        )
        let matches = try XCTUnwrap(search["matches"] as? [JSONObject])
        XCTAssertEqual(matches.count, 2)
    }

    func testReadRejectsFIFOWithoutWaitingForAWriter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fifo = fixture.workspace.appendingPathComponent("input.pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let service = try fixture.service()

        let started = ContinuousClock.now
        XCTAssertThrowsError(try service.readFile(
            workspaceID: fixture.workspaceID,
            path: "input.pipe",
            encoding: "utf8",
            maximumBytes: 1_024
        ))
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
    }

    func testReadAllowsEnvironmentTemplatesButStillBlocksEnvironmentSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("PLACEHOLDER=test-only\n".utf8).write(
            to: fixture.workspace.appendingPathComponent(".env.example"))
        try Data("SECRET=test-only\n".utf8).write(
            to: fixture.workspace.appendingPathComponent(".env.local"))
        let service = try fixture.service()

        let template = try service.readFile(
            workspaceID: fixture.workspaceID,
            path: ".env.example",
            encoding: "utf8",
            maximumBytes: 1_024
        )
        XCTAssertEqual((template["file"] as? JSONObject)?["content"] as? String,
                       "PLACEHOLDER=test-only\n")
        XCTAssertThrowsError(try service.readFile(
            workspaceID: fixture.workspaceID,
            path: ".env.local",
            encoding: "utf8",
            maximumBytes: 1_024
        ))
    }

    func testWritePatchAndRestoreReturnExactBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.workspace.appendingPathComponent("mutation.txt")
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: target)
        let service = try fixture.service()

        let write = try service.writeFile(
            workspaceID: fixture.workspaceID,
            path: "mutation.txt",
            content: "changed\n",
            encoding: "utf8",
            expectedSHA256: LocalHash.sha256(baseline)
        )
        XCTAssertEqual(try Data(contentsOf: target), Data("changed\n".utf8))
        XCTAssertEqual(write["backend_called"] as? Bool, true)
        XCTAssertEqual(write["mutation_performed"] as? Bool, true)
        let writeTransaction = try XCTUnwrap(write["transaction_id"] as? String)
        _ = try service.restoreTransaction(writeTransaction)
        XCTAssertEqual(try Data(contentsOf: target), baseline)

        let patch = try service.patchFile(
            workspaceID: fixture.workspaceID,
            path: "mutation.txt",
            oldText: "baseline",
            newText: "patched",
            replaceAll: false,
            expectedSHA256: LocalHash.sha256(baseline)
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "patched\n")
        _ = try service.restoreTransaction(try XCTUnwrap(patch["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: target), baseline)

        let created = try service.writeFile(
            workspaceID: fixture.workspaceID,
            path: "new.txt",
            content: "new",
            encoding: "utf8",
            expectedSHA256: nil
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("new.txt").path))
        _ = try service.restoreTransaction(try XCTUnwrap(created["transaction_id"] as? String))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("new.txt").path))
    }

    func testDirectoryCopyMoveAndRestore() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let source = fixture.workspace.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("content".utf8).write(to: source.appendingPathComponent("file.txt"))

        let copied = try service.copyPath(
            workspaceID: fixture.workspaceID,
            sourcePath: "source",
            destinationPath: "copied"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("copied/file.txt").path))
        _ = try service.restoreTransaction(try XCTUnwrap(copied["transaction_id"] as? String))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("copied").path))

        let moved = try service.movePath(
            workspaceID: fixture.workspaceID,
            sourcePath: "source",
            destinationPath: "moved"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        _ = try service.restoreTransaction(try XCTUnwrap(moved["transaction_id"] as? String))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.appendingPathComponent("file.txt").path))

        let made = try service.createDirectory(
            workspaceID: fixture.workspaceID,
            path: "empty"
        )
        _ = try service.restoreTransaction(try XCTUnwrap(made["transaction_id"] as? String))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("empty").path))
    }

    func testChunkedReadPreservesUTF8BoundariesAndBinaryOffsets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let textData = Data("ab🙂cd".utf8)
        try textData.write(to: fixture.workspace.appendingPathComponent("unicode.txt"))

        let first = try service.readFile(
            workspaceID: fixture.workspaceID,
            path: "unicode.txt",
            encoding: "utf8",
            maximumBytes: 4,
            offset: 0
        )
        let firstFile = try XCTUnwrap(first["file"] as? JSONObject)
        XCTAssertEqual(firstFile["content"] as? String, "ab🙂")
        XCTAssertEqual(firstFile["byte_count"] as? Int, 6)
        XCTAssertEqual(firstFile["next_offset"] as? Int, 6)
        XCTAssertEqual(firstFile["eof"] as? Bool, false)
        XCTAssertNil(firstFile["sha256"])

        let second = try service.readFile(
            workspaceID: fixture.workspaceID,
            path: "unicode.txt",
            encoding: "utf8",
            maximumBytes: 4,
            offset: 6
        )
        let secondFile = try XCTUnwrap(second["file"] as? JSONObject)
        XCTAssertEqual(secondFile["content"] as? String, "cd")
        XCTAssertEqual(secondFile["next_offset"] as? Int, textData.count)
        XCTAssertEqual(secondFile["eof"] as? Bool, true)

        XCTAssertThrowsError(
            try service.readFile(
                workspaceID: fixture.workspaceID,
                path: "unicode.txt",
                encoding: "utf8",
                maximumBytes: 4,
                offset: 3
            )
        )

        let binaryData = Data((0..<257).map { UInt8($0 % 251) })
        try binaryData.write(to: fixture.workspace.appendingPathComponent("binary.dat"))
        var rebuilt = Data()
        var offset = 0
        while offset < binaryData.count {
            let result = try service.readFile(
                workspaceID: fixture.workspaceID,
                path: "binary.dat",
                encoding: "base64",
                maximumBytes: 31,
                offset: offset
            )
            let file = try XCTUnwrap(result["file"] as? JSONObject)
            rebuilt.append(
                try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["content"] as? String)))
            )
            offset = try XCTUnwrap(file["next_offset"] as? Int)
        }
        XCTAssertEqual(rebuilt, binaryData)
    }

    func testDirectoryAndSearchPaginationAreCompleteAndSkipGeneratedTrees() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data("needle \(name)\n".utf8).write(
                to: fixture.workspace.appendingPathComponent(name)
            )
        }
        for directory in [".build", "vendor"] {
            let url = fixture.workspace.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("needle ignored\n".utf8).write(to: url.appendingPathComponent("ignored.txt"))
        }
        let service = try fixture.service()

        var listedPaths: [String] = []
        var listCursor = 0
        while true {
            let page = try service.listDirectory(
                workspaceID: fixture.workspaceID,
                path: ".",
                recursive: true,
                maximumEntries: 2,
                cursor: listCursor
            )
            let entries = try XCTUnwrap(page["entries"] as? [JSONObject])
            listedPaths += entries.compactMap { $0["relative_path"] as? String }
            if page["complete"] as? Bool == true { break }
            listCursor = try XCTUnwrap(page["next_cursor"] as? Int)
        }
        XCTAssertEqual(Set(listedPaths).count, listedPaths.count)
        XCTAssertTrue(listedPaths.contains("vendor/ignored.txt"))

        var searchPaths: [String] = []
        var searchCursor = 0
        while true {
            let page = try service.searchFiles(
                workspaceID: fixture.workspaceID,
                path: ".",
                query: "needle",
                caseSensitive: true,
                maximumResults: 1,
                maximumFileBytes: 1_024,
                mode: "content",
                cursor: searchCursor
            )
            let matches = try XCTUnwrap(page["matches"] as? [JSONObject])
            searchPaths += matches.compactMap { $0["relative_path"] as? String }
            if page["complete"] as? Bool == true { break }
            searchCursor = try XCTUnwrap(page["next_cursor"] as? Int)
        }
        XCTAssertEqual(searchPaths, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(Set(searchPaths).count, searchPaths.count)

        let names = try service.searchFiles(
            workspaceID: fixture.workspaceID,
            path: ".",
            query: "ignored.txt",
            caseSensitive: true,
            maximumResults: 10,
            maximumFileBytes: 1_024,
            mode: "name",
            includeIgnored: true
        )
        XCTAssertEqual((names["matches"] as? [JSONObject])?.count, 2)
        XCTAssertEqual(names["complete"] as? Bool, true)
    }

    func testAppendAndRecoverableRemoveRestoreExactState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let target = fixture.workspace.appendingPathComponent("append.txt")
        let baseline = Data("before".utf8)
        try baseline.write(to: target)

        let appended = try service.appendFile(
            workspaceID: fixture.workspaceID,
            path: "append.txt",
            content: " after",
            encoding: "utf8",
            expectedSHA256: LocalHash.sha256(baseline)
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "before after")
        _ = try service.restoreTransaction(try XCTUnwrap(appended["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: target), baseline)

        let directory = fixture.workspace.appendingPathComponent("remove-me")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("recover me".utf8).write(to: directory.appendingPathComponent("data.txt"))
        let removed = try service.removePath(workspaceID: fixture.workspaceID, path: "remove-me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let recoveryPath = try XCTUnwrap(removed["recovery_path"] as? String)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(recoveryPath).path
            )
        )
        _ = try service.restoreTransaction(try XCTUnwrap(removed["transaction_id"] as? String))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("data.txt"), encoding: .utf8),
            "recover me"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(recoveryPath).path
            )
        )
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }

    func testCopyRejectsDestinationNestedInsideSourceBeforeMutation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("content".utf8).write(to: source.appendingPathComponent("file.txt"))
        let service = try fixture.service()

        XCTAssertThrowsError(
            try service.copyPath(
                workspaceID: fixture.workspaceID,
                sourcePath: "source",
                destinationPath: "source/nested-copy"
            )
        ) { error in
            XCTAssertTrue(error is LocalMCPError)
            XCTAssertTrue(String(describing: error).contains("inside the source"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: source.appendingPathComponent("nested-copy").path
            )
        )
    }

    func testRestoreRejectsModeChangeAfterCopiedTransaction() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.workspace.appendingPathComponent("mode-source.txt")
        try Data("mode-content".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, 0o644), 0)
        let service = try fixture.service()
        let copied = try service.copyPath(
            workspaceID: fixture.workspaceID,
            sourcePath: "mode-source.txt",
            destinationPath: "mode-copy.txt"
        )
        let copy = fixture.workspace.appendingPathComponent("mode-copy.txt")
        XCTAssertEqual(chmod(copy.path, 0o600), 0)

        XCTAssertThrowsError(
            try service.restoreTransaction(try XCTUnwrap(copied["transaction_id"] as? String))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testStatDoesNotHashFilesLargerThanMutationLimit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let large = fixture.workspace.appendingPathComponent("large-sparse.bin")
        let descriptor = Darwin.open(large.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        XCTAssertEqual(
            ftruncate(descriptor, off_t(LocalWorkspaceService.maximumFileBytes + 1)),
            0
        )
        let service = try fixture.service()

        let result = try service.statPath(
            workspaceID: fixture.workspaceID,
            path: "large-sparse.bin"
        )
        let metadata = try XCTUnwrap(result["path"] as? JSONObject)
        XCTAssertEqual(
            metadata["byte_count"] as? Int64, Int64(LocalWorkspaceService.maximumFileBytes + 1))
        XCTAssertNil(metadata["sha256"])
    }

    func testTraversalSymlinkHardlinkAndSensitivePathsFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let regular = fixture.workspace.appendingPathComponent("regular.txt")
        try Data("safe".utf8).write(to: regular)
        let hardlink = fixture.workspace.appendingPathComponent("hardlink.txt")
        XCTAssertEqual(link(regular.path, hardlink.path), 0)
        let symlinkURL = fixture.workspace.appendingPathComponent("outside-link")
        XCTAssertEqual(symlink("/etc/passwd", symlinkURL.path), 0)
        try Data("secret".utf8).write(to: fixture.workspace.appendingPathComponent(".env"))

        XCTAssertThrowsError(
            try service.readFile(
                workspaceID: fixture.workspaceID, path: "../outside", encoding: "utf8",
                maximumBytes: 1_024
            ))
        XCTAssertThrowsError(
            try service.readFile(
                workspaceID: fixture.workspaceID, path: "outside-link", encoding: "utf8",
                maximumBytes: 1_024
            ))
        XCTAssertThrowsError(
            try service.readFile(
                workspaceID: fixture.workspaceID, path: "hardlink.txt", encoding: "utf8",
                maximumBytes: 1_024
            ))
        XCTAssertThrowsError(
            try service.readFile(
                workspaceID: fixture.workspaceID, path: ".env", encoding: "utf8",
                maximumBytes: 1_024
            ))
        let list = try service.listDirectory(
            workspaceID: fixture.workspaceID,
            path: ".",
            recursive: false,
            maximumEntries: 100
        )
        let listed = try XCTUnwrap(list["entries"] as? [JSONObject])
        XCTAssertFalse(listed.contains { $0["relative_path"] as? String == ".env" })

        let linkedTree = fixture.workspace.appendingPathComponent("linked-tree")
        try FileManager.default.createDirectory(at: linkedTree, withIntermediateDirectories: false)
        XCTAssertEqual(
            symlink("/etc/passwd", linkedTree.appendingPathComponent("escape").path),
            0
        )
        XCTAssertThrowsError(
            try service.copyPath(
                workspaceID: fixture.workspaceID,
                sourcePath: "linked-tree",
                destinationPath: "linked-tree-copy"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent("linked-tree-copy").path
            )
        )
    }

    func testWorkspaceRootReplacementWithSymlinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let original = fixture.root.appendingPathComponent("original-workspace")
        let outside = fixture.root.appendingPathComponent("outside-workspace")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside.txt"))
        try FileManager.default.moveItem(at: fixture.workspace, to: original)
        XCTAssertEqual(symlink(outside.path, fixture.workspace.path), 0)

        XCTAssertThrowsError(
            try service.readFile(
                workspaceID: fixture.workspaceID,
                path: "outside.txt",
                encoding: "utf8",
                maximumBytes: 1_024
            )
        )
        XCTAssertThrowsError(
            try service.writeFile(
                workspaceID: fixture.workspaceID,
                path: "created.txt",
                content: "must-not-write",
                encoding: "utf8",
                expectedSHA256: nil
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("created.txt").path))
    }

    func testRestoreRejectsPostMutationConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.workspace.appendingPathComponent("conflict.txt")
        try Data("before".utf8).write(to: target)
        let service = try fixture.service()
        let write = try service.writeFile(
            workspaceID: fixture.workspaceID,
            path: "conflict.txt",
            content: "transaction-value",
            encoding: "utf8",
            expectedSHA256: LocalHash.sha256(Data("before".utf8))
        )
        try Data("external-change".utf8).write(to: target)
        XCTAssertThrowsError(
            try service.restoreTransaction(try XCTUnwrap(write["transaction_id"] as? String))
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external-change")
    }

    func testSuccessfulRestoreReleasesRollbackPayload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.workspace.appendingPathComponent("released-rollback.txt")
        let baseline = Data(repeating: 0x61, count: 1_048_576)
        try baseline.write(to: target)
        let service = try fixture.service()
        let write = try service.writeFile(
            workspaceID: fixture.workspaceID,
            path: "released-rollback.txt",
            content: String(repeating: "b", count: baseline.count),
            encoding: "utf8",
            expectedSHA256: LocalHash.sha256(baseline)
        )
        XCTAssertEqual(service.retainedTransactionCount, 1)

        _ = try service.restoreTransaction(try XCTUnwrap(write["transaction_id"] as? String))
        XCTAssertEqual(try Data(contentsOf: target), baseline)
        XCTAssertEqual(service.retainedTransactionCount, 0)
    }
}

final class Fixture {
    let root: URL
    let workspace: URL
    let config: URL
    let workspaceID = "11111111-2222-4333-8444-555555555555"

    init(baseDirectory: URL? = nil) throws {
        // Foundation can choose the account's OS temp folder despite TMPDIR.
        // Honor the job's explicit temp root so fixtures stay within its scope.
        let environmentTemporary = ProcessInfo.processInfo.environment["TMPDIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        }
        let base = baseDirectory ?? environmentTemporary ?? FileManager.default.temporaryDirectory
        let canonicalBase = URL(fileURLWithPath: try canonicalExistingPath(base.path), isDirectory: true)
        root = canonicalBase.appendingPathComponent(
            "macbridge-local-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        config = root.appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let configuration = LocalWorkspaceConfiguration(
            workspaces: [
                LocalWorkspaceConfigurationEntry(
                    id: workspaceID,
                    name: "test-workspace",
                    path: workspace.standardizedFileURL.path
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)
    }

    func service() throws -> LocalWorkspaceService {
        LocalWorkspaceService(
            registry: try LocalWorkspaceRegistry(configurationURL: config)
        )
    }

    func replaceConfiguration(workspacePath: String, allowBroadAccess: Bool? = nil) throws {
        let configuration = LocalWorkspaceConfiguration(
            workspaces: [
                LocalWorkspaceConfigurationEntry(
                    id: workspaceID,
                    name: "test-workspace",
                    path: workspacePath,
                    allowBroadAccess: allowBroadAccess
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
