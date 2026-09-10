import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ProcessSecurityBoundaryTests: XCTestCase {
    private func binary() throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["MACBRIDGE_TEST_EXECUTABLE"]
            ?? package.appendingPathComponent(".build/debug/macbridge-mcp").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw LocalMCPError.operationFailed("build macbridge-mcp before the process security tests")
        }
        return URL(fileURLWithPath: path)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func run(_ p: LocalProcessService, _ f: Fixture, _ script: String,
                     _ arguments: [String] = []) throws -> JSONObject {
        try p.runCommand(workspaceID: f.workspaceID, executableID: "sh",
            arguments: ["-c", script, "test"] + arguments, cwd: ".",
            timeoutMilliseconds: 5_000, maximumOutputBytes: 8_192)
    }

    func testFreshRunnerIgnoresReplacedDiagnosticProfile() throws {
        let f = try Fixture(); defer { f.remove() }
        let outside = f.root.appendingPathComponent("outside.txt")
        try Data("outside-synthetic-sentinel".utf8).write(to: outside)
        // A trusted test shim substitutes the file exactly after owner creation
        // and before runner consumption, without relying on a probabilistic race.
        let shim = f.root.appendingPathComponent("replace-profile.sh")
        let script = "#!/bin/sh\nprintf '(version 1)\\n(allow default)\\n' > \"$HOME/../command.sb\"\nexec "
            + shellQuote(try binary().path) + " \"$@\"\n"
        try Data(script.utf8).write(to: shim)
        XCTAssertEqual(chmod(shim.path, 0o700), 0)
        let p = LocalProcessService(workspaceService: try f.service(), selfExecutable: shim)
        let denied = try run(p, f, "/bin/cat \"$1\"", [outside.path])
        XCTAssertNotEqual(denied["exit_code"] as? Int, 0)
        XCTAssertFalse((denied["stdout"] as? String ?? "").contains("outside-synthetic-sentinel"))
        let control = try run(p, f, "printf workspace-ok > control.txt; /bin/cat control.txt")
        XCTAssertEqual(control["exit_code"] as? Int, 0, control["stderr"] as? String ?? "")
        XCTAssertEqual(control["stdout"] as? String, "workspace-ok")
    }

    func testChildCannotRewriteSiblingProfileOrRecoveryButCanUseItsOwnData() throws {
        let f = try Fixture(); defer { f.remove() }
        let w = try f.service()
        try Data("retained-original".utf8).write(to: f.workspace.appendingPathComponent("removed.txt"))
        let removal = try w.removePath(workspaceID: f.workspaceID, path: "removed.txt")
        let recoveryPath = try XCTUnwrap(removal["recovery_path"] as? String)
        let p = LocalProcessService(workspaceService: w, selfExecutable: try binary())
        let sibling = try p.startCommand(workspaceID: f.workspaceID, executableID: "cat",
            arguments: [], cwd: ".", maximumOutputBytes: 1_024)
        let siblingID = try XCTUnwrap(sibling["task_id"] as? String)
        defer { _ = try? p.cancelProcess(taskID: siblingID) }
        let siblingProfile = f.workspace.appendingPathComponent(".macbridge/runtime/\(siblingID)/command.sb")
        let profileBefore = try Data(contentsOf: siblingProfile)
        let staging = [".macbridge-copy-", ".macbridge-write-"].map {
            f.workspace.appendingPathComponent($0 + UUID().uuidString.lowercased())
        }
        for path in staging { try Data("owner-staging".utf8).write(to: path) }
        let result = try run(p, f, """
            for target in "$1" "$HOME/../command.sb" "$2" "$3" "$4"; do
                if printf changed > "$target"; then exit 41; fi
            done
            if /bin/mv .macbridge moved-owner-state; then exit 42; fi
            printf home > "$HOME/control"
            printf tmp > "$TMPDIR/control"
            printf cache > "$XDG_CACHE_HOME/control"
            printf workspace > control.txt
            /bin/cat "$HOME/control" "$TMPDIR/control" "$XDG_CACHE_HOME/control" control.txt
            """, [siblingProfile.path, f.workspace.appendingPathComponent(recoveryPath).path] + staging.map(\.path))
        XCTAssertEqual(result["exit_code"] as? Int, 0, result["stderr"] as? String ?? "")
        XCTAssertEqual(result["stdout"] as? String, "hometmpcacheworkspace")
        XCTAssertEqual(try Data(contentsOf: siblingProfile), profileBefore)
        for path in staging { XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "owner-staging") }
        _ = try w.restoreTransaction(XCTUnwrap(removal["transaction_id"] as? String))
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("removed.txt"), encoding: .utf8), "retained-original")
    }

    func testGeneratedSandboxDeniesCredentialStoresButAllowsSiblings() throws {
        let f = try Fixture(); defer { f.remove() }
        let p = LocalProcessService(workspaceService: try f.service(), selfExecutable: try binary())
        for (folder, file) in [(".docker", "config.json"), (".config/git", "credentials")] {
            let directory = f.workspace.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("synthetic-auth-only".utf8).write(to: directory.appendingPathComponent(file))
            try Data("ordinary-doc".utf8).write(to: directory.appendingPathComponent("readme.txt"))
            let denied = try run(p, f, "/bin/cat \(folder)/\(file)")
            XCTAssertNotEqual(denied["exit_code"] as? Int, 0)
            XCTAssertFalse((denied["stdout"] as? String ?? "").contains("synthetic-auth-only"))
            let allowed = try run(p, f, "/bin/cat \(folder)/readme.txt")
            XCTAssertEqual(allowed["exit_code"] as? Int, 0, allowed["stderr"] as? String ?? "")
            XCTAssertEqual(allowed["stdout"] as? String, "ordinary-doc")
        }
    }

    // Only reviewed system Git and a fresh synthetic repository are used for
    // fixture setup. No user config, hooks, credentials, remotes or network.
    private func fixtureGit(_ f: Fixture, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir="] + arguments
        process.currentDirectoryURL = f.workspace
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": f.root.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    private func repository(_ f: Fixture) throws {
        try fixtureGit(f, ["init", "-q"])
        try Data("before\n".utf8).write(to: f.workspace.appendingPathComponent("tracked.txt"))
        try fixtureGit(f, ["add", "--", "tracked.txt"])
        try fixtureGit(f, ["commit", "-qm", "synthetic baseline"])
        try Data("after\n".utf8).write(to: f.workspace.appendingPathComponent("tracked.txt"))
    }

    private func inspect(_ name: String, _ f: Fixture, _ p: LocalProcessService,
                         _ extra: JSONObject = [:]) throws -> JSONObject {
        var arguments = extra
        arguments["workspace_id"] = f.workspaceID
        return try ExpandedToolOperations.execute(name, arguments, workspace: f.service(), processes: p)
    }

    func testGitInspectRefusesCleanAndProcessFilterExecution() throws {
        for filterKind in ["clean", "process"] {
            let f = try Fixture(); defer { f.remove() }
            try repository(f)
            let marker = f.workspace.appendingPathComponent("filter-executed")
            try Data("tracked.txt filter=attack\n".utf8).write(to: f.workspace.appendingPathComponent(".gitattributes"))
            try Data("#!/bin/sh\nprintf invoked > filter-executed\n/bin/cat\n".utf8)
                .write(to: f.workspace.appendingPathComponent("filter.sh"))
            try fixtureGit(f, ["config", "filter.attack.\(filterKind)", "/bin/sh ./filter.sh"])
            try fixtureGit(f, ["config", "filter.attack.required", "true"])
            let p = LocalProcessService(workspaceService: try f.service(), selfExecutable: try binary())
            for name in ["git_status", "git_diff", "git_blame"] {
                let extra: JSONObject = name == "git_blame" ? ["path": "tracked.txt"] : [:]
                let result = try inspect(name, f, p, extra)
                // Status may determine that a file changed from its stat cache
                // without requesting conversion. Diff/blame need the required
                // filter and must fail; every route must leave the marker absent.
                if name != "git_status" {
                    XCTAssertNotEqual(result["exit_code"] as? Int, 0, "\(filterKind): \(name) should report refused required filter")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "\(filterKind): \(name) ran project code")
            }
        }
    }

    func testGitInspectIsReadOnlyAndOrdinaryInspectionStillWorks() throws {
        let f = try Fixture(); defer { f.remove() }
        try repository(f)
        let p = LocalProcessService(workspaceService: try f.service(), selfExecutable: try binary())
        let originalConfig = try Data(contentsOf: f.workspace.appendingPathComponent(".git/config"))
        let denied = try p.runReadOnlyGit(workspaceID: f.workspaceID,
            arguments: ["config", "--local", "test.forbidden", "value"], cwd: ".",
            timeoutMilliseconds: 5_000, maximumOutputBytes: 8_192)
        XCTAssertNotEqual(denied["exit_code"] as? Int, 0)
        XCTAssertEqual(try Data(contentsOf: f.workspace.appendingPathComponent(".git/config")), originalConfig)
        let indexBefore = try Data(contentsOf: f.workspace.appendingPathComponent(".git/index"))
        for name in ["git_status", "git_diff", "git_log", "git_show", "git_branches", "git_worktrees", "git_blame", "git_file_list"] {
            let extra: JSONObject = name == "git_blame" ? ["path": "tracked.txt"] : [:]
            let result = try inspect(name, f, p, extra)
            XCTAssertEqual(result["exit_code"] as? Int, 0, "\(name): \(result["stderr"] as? String ?? "")")
            XCTAssertFalse((result["stdout"] as? String ?? "").isEmpty, name)
        }
        XCTAssertEqual(try Data(contentsOf: f.workspace.appendingPathComponent(".git/index")), indexBefore)
        XCTAssertEqual(try String(contentsOf: f.workspace.appendingPathComponent("tracked.txt"), encoding: .utf8), "after\n")
    }
}
