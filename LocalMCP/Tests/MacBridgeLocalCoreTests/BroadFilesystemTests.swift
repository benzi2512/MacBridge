import Darwin
import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class BroadFilesystemTests: XCTestCase {
    func testRootRequiresExplicitOptInAndAdvertisesAbsolutePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.replaceConfiguration(workspacePath: "/")
        XCTAssertThrowsError(try fixture.service())
        try fixture.replaceConfiguration(workspacePath: "/", allowBroadAccess: false)
        XCTAssertThrowsError(try fixture.service())
        try fixture.replaceConfiguration(workspacePath: "/", allowBroadAccess: true)
        let workspace = try fixture.service().registry.workspace(id: fixture.workspaceID)
        XCTAssertEqual(workspace.rootURL.path, "/")
        XCTAssertEqual(workspace.json["root_path"] as? String, "/")
        XCTAssertEqual(workspace.json["absolute_paths"] as? Bool, true)
    }

    func testAbsoluteFileWorkflowAndSameVolumeRecoveryOutsideOriginalWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.replaceConfiguration(workspacePath: "/", allowBroadAccess: true)
        let service = try fixture.service()
        let parent = try canonicalExistingPath(fixture.root.path)
        let target = parent + "/outside-original-workspace.txt"
        let copied = parent + "/copied.txt"
        let moved = parent + "/moved.txt"
        var transactions: [String] = []
        func retain(_ value: JSONObject) throws {
            XCTAssertEqual(value["mutation_performed"] as? Bool, true)
            transactions.append(try XCTUnwrap(value["transaction_id"] as? String))
        }
        try retain(service.writeFile(
            workspaceID: fixture.workspaceID, path: target,
            content: "broad-access baseline\n", encoding: "utf8", expectedSHA256: nil
        ))
        let read = try service.readFile(
            workspaceID: fixture.workspaceID, path: target, encoding: "utf8", maximumBytes: 1024
        )
        XCTAssertEqual((read["file"] as? JSONObject)?["content"] as? String, "broad-access baseline\n")
        let hash = LocalHash.sha256(Data("broad-access baseline\n".utf8))
        try retain(service.patchFile(
            workspaceID: fixture.workspaceID, path: target,
            oldText: "baseline", newText: "patched", replaceAll: false, expectedSHA256: hash
        ))
        try retain(service.copyPath(workspaceID: fixture.workspaceID, sourcePath: target, destinationPath: copied))
        try retain(service.movePath(workspaceID: fixture.workspaceID, sourcePath: copied, destinationPath: moved))
        let removal = try service.removePath(workspaceID: fixture.workspaceID, path: moved)
        try retain(removal)
        XCTAssertTrue((removal["recovery_path"] as? String)?.hasPrefix(String(parent.dropFirst()) + "/.macbridge/recovery/") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved))
        let relativeRead = try service.readFile(
            workspaceID: fixture.workspaceID, path: String(target.dropFirst()),
            encoding: "utf8", maximumBytes: 1024
        )
        XCTAssertEqual((relativeRead["file"] as? JSONObject)?["content"] as? String, "broad-access patched\n")
        let list = try service.listDirectory(workspaceID: fixture.workspaceID, path: parent, recursive: false, maximumEntries: 100)
        XCTAssertTrue((list["entries"] as? [JSONObject])?.contains { ($0["relative_path"] as? String)?.hasSuffix("outside-original-workspace.txt") == true } == true)
        let search = try service.searchFiles(workspaceID: fixture.workspaceID, path: parent, query: "broad-access", caseSensitive: true, maximumResults: 10, maximumFileBytes: 1024)
        XCTAssertEqual((search["matches"] as? [JSONObject])?.count, 1)
        for id in transactions.reversed() { _ = try service.restoreTransaction(id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent + "/.macbridge"))
    }

    func testRootMutationTraversalAndCredentialSubtreesRemainBlocked() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.replaceConfiguration(workspacePath: "/", allowBroadAccess: true)
        let service = try fixture.service()
        XCTAssertThrowsError(try service.removePath(workspaceID: fixture.workspaceID, path: "/"))
        XCTAssertThrowsError(try service.createDirectory(workspaceID: fixture.workspaceID, path: "/"))
        XCTAssertThrowsError(try service.statPath(workspaceID: fixture.workspaceID, path: "/Users/../etc"))
        // Synthetic credential-shaped paths only; no personal secrets are read.
        let parent = try canonicalExistingPath(fixture.root.path)
        let container = URL(fileURLWithPath: parent).appendingPathComponent("synthetic")
        try FileManager.default.createDirectory(at: container.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("test-only-placeholder".utf8).write(to: container.appendingPathComponent(".ssh/id_ed25519"))
        XCTAssertThrowsError(try service.readFile(workspaceID: fixture.workspaceID, path: container.path + "/.ssh/id_ed25519", encoding: "utf8", maximumBytes: 1024))
        XCTAssertThrowsError(try service.copyPath(workspaceID: fixture.workspaceID, sourcePath: container.path, destinationPath: parent + "/copy"))
        XCTAssertThrowsError(try service.movePath(workspaceID: fixture.workspaceID, sourcePath: container.path, destinationPath: parent + "/move"))
        XCTAssertThrowsError(try service.removePath(workspaceID: fixture.workspaceID, path: container.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))
        let entries = try service.listDirectory(workspaceID: fixture.workspaceID, path: container.path, recursive: true, maximumEntries: 100)
        XCTAssertEqual((entries["entries"] as? [JSONObject])?.count, 0)
    }

    func testCredentialPolicyCoversBrowserProfilesAndDataVolumeAliases() {
        for path in [
            "/Users/example/Library/Keychains/login.keychain-db",
            "/System/Volumes/Data/Users/example/Library/Application Support/Google/Chrome/Default/Cookies",
            "/USERS/example/LIBRARY/Safari/History.db",
            "/Users/example/.config/macbridge/tunnel-api-key",
            "/Users/example/.codex/auth.json",
            "/temporary/test/.ENV.local",
        ] { XCTAssertTrue(LocalFilesystemAccess.isSensitive(path), path) }
        for path in [
            "/workspace/.env.example",
            "/workspace/.ENV.SAMPLE",
            "/workspace/config/.env.template",
            "/workspace/.env.dist",
        ] { XCTAssertFalse(LocalFilesystemAccess.isSensitive(path), path) }
        XCTAssertTrue(LocalFilesystemAccess.isSensitive("/workspace/.env.example/private"))
        XCTAssertTrue(LocalFilesystemAccess.isSensitive("/workspace/.env.production"))
        XCTAssertFalse(LocalFilesystemAccess.isSensitive("/Users/example/Desktop/report.txt"))
        XCTAssertFalse(LocalFilesystemAccess.isSensitive("/Volumes/Work/project/main.swift"))
    }

    func testBroadCommandUsesPrivateTempAndScopesEachCommandToItsExplicitCWD() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.replaceConfiguration(workspacePath: "/", allowBroadAccess: true)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = LocalProcessService(workspaceService: try fixture.service(), selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"))
        let parent = try canonicalExistingPath(fixture.root.path)
        let result = try service.runCommand(
            workspaceID: fixture.workspaceID, executableID: "zsh",
            arguments: ["-c", "printf 'headless-broad-ok' > command.txt; printf '%s' \"$HOME\""],
            cwd: parent + "/workspace", timeoutMilliseconds: 5000, maximumOutputBytes: 4096
        )
        XCTAssertEqual(result["exit_code"] as? Int, 0, String(describing: result))
        XCTAssertEqual(result["terminal_window_opened"] as? Bool, false)
        XCTAssertEqual(try String(contentsOfFile: parent + "/workspace/command.txt", encoding: .utf8), "headless-broad-ok")
        let runtimeHome = try XCTUnwrap(result["stdout"] as? String)
        XCTAssertTrue(runtimeHome.hasPrefix("/private/var/folders/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeHome))

        try Data("sibling-only".utf8).write(to: URL(fileURLWithPath: parent + "/sibling.txt"))
        let siblingDenied = try service.runCommand(
            workspaceID: fixture.workspaceID, executableID: "cat", arguments: ["../sibling.txt"],
            cwd: parent + "/workspace", timeoutMilliseconds: 5000, maximumOutputBytes: 4096
        )
        XCTAssertNotEqual(siblingDenied["exit_code"] as? Int, 0)
        XCTAssertFalse((siblingDenied["stdout"] as? String ?? "").contains("sibling-only"))

        // Verify sandbox exclusion with dummy bytes, never a real credential.
        try Data("dummy-only".utf8).write(to: URL(fileURLWithPath: parent + "/workspace/.env"))
        let denied = try service.runCommand(
            workspaceID: fixture.workspaceID, executableID: "cat", arguments: [".env"],
            cwd: parent + "/workspace", timeoutMilliseconds: 5000, maximumOutputBytes: 4096
        )
        XCTAssertNotEqual(denied["exit_code"] as? Int, 0)
        XCTAssertFalse((denied["stdout"] as? String ?? "").contains("dummy-only"))

        try Data("PLACEHOLDER=test-only\n".utf8).write(
            to: URL(fileURLWithPath: parent + "/workspace/.env.example"))
        let template = try service.runCommand(
            workspaceID: fixture.workspaceID, executableID: "cat", arguments: [".env.example"],
            cwd: parent + "/workspace", timeoutMilliseconds: 5000, maximumOutputBytes: 4096
        )
        XCTAssertEqual(template["exit_code"] as? Int, 0, String(describing: template))
        XCTAssertEqual(template["stdout"] as? String, "PLACEHOLDER=test-only\n")

        let disguisedDirectory = URL(fileURLWithPath: parent + "/workspace/.env.sample")
        try FileManager.default.createDirectory(at: disguisedDirectory,
                                                withIntermediateDirectories: false)
        try Data("SECRET=test-only\n".utf8).write(
            to: disguisedDirectory.appendingPathComponent("private"))
        let disguisedSecret = try service.runCommand(
            workspaceID: fixture.workspaceID, executableID: "cat",
            arguments: [".env.sample/private"], cwd: parent + "/workspace",
            timeoutMilliseconds: 5000, maximumOutputBytes: 4096
        )
        XCTAssertNotEqual(disguisedSecret["exit_code"] as? Int, 0)
        XCTAssertFalse((disguisedSecret["stdout"] as? String ?? "").contains("SECRET="))
    }

    func testProtectedRootsCannotBeRemovedOrUsedAsBroadCommandScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.replaceConfiguration(workspacePath: "/", allowBroadAccess: true)
        let workspace = try fixture.service().registry.workspace(id: fixture.workspaceID)
        XCTAssertThrowsError(
            try OperationSafety.validateRecoverableRemoval(
                target: FileManager.default.homeDirectoryForCurrentUser,
                workspace: workspace
            )
        )
        XCTAssertThrowsError(
            try OperationSafety.validateRelocation(
                source: FileManager.default.homeDirectoryForCurrentUser,
                workspace: workspace
            )
        )
        XCTAssertThrowsError(
            try OperationSafety.commandScope(
                workspace: workspace,
                workingDirectory: URL(fileURLWithPath: "/", isDirectory: true)
            )
        )
        for protected in ["/etc", "/opt", "/private/etc", "/private/tmp", "/private/var", "/tmp", "/var"] {
            XCTAssertTrue(OperationSafety.isProtectedAnchor(protected), protected)
            XCTAssertThrowsError(
                try OperationSafety.validateRecoverableRemoval(
                    target: URL(fileURLWithPath: protected, isDirectory: true),
                    workspace: workspace
                )
            )
            XCTAssertThrowsError(
                try OperationSafety.commandScope(
                    workspace: workspace,
                    workingDirectory: URL(fileURLWithPath: protected, isDirectory: true)
                )
            )
        }
        let project = URL(fileURLWithPath: try canonicalExistingPath(fixture.workspace.path), isDirectory: true)
        XCTAssertEqual(
            try OperationSafety.commandScope(workspace: workspace, workingDirectory: project).path,
            project.path
        )
    }
}
