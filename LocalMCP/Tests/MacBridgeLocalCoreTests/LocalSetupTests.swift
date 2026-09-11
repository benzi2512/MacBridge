import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class LocalSetupTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var workspace: URL!
    private var executable: URL!

    override func setUpWithError() throws {
        var template = Array("/private/tmp/mb-setup-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw LocalMCPError.operationFailed("fixture creation failed") }
        root = URL(fileURLWithPath: String(cString: created))
        home = root.appendingPathComponent("home")
        workspace = root.appendingPathComponent("project with spaces")
        executable = root.appendingPathComponent("Applications/MacBridge.app/Contents/MacOS/macbridge-mcp")
        for url in [home!, workspace!, executable.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        try Data("inert test fixture; never executed\n".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
    }

    override func tearDownWithError() throws {
        // Only this test's fresh, synthetic directory, never an account home.
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func plan() throws -> LocalSetupPlan {
        try LocalSetupPlan(workspaceURL: workspace, executableURL: executable, homeDirectory: home)
    }

    private func directory(_ relative: String, mode: Int16 = 0o700) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: mode])
        XCTAssertEqual(chmod(url.path, mode_t(mode)), 0)
        return url
    }

    func testPlanningHasNoFilesystemSideEffects() throws {
        let value = try plan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.configurationPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        XCTAssertNil(value.configuration.workspaces.first?.allowBroadAccess)
        XCTAssertEqual(value.configuration.workspaces.first?.path, workspace.path)
    }

    func testCreatesPrivateConfigurationAcceptedByActualRegistry() throws {
        let value = try plan()
        try value.createConfiguration()
        let registry = try LocalWorkspaceRegistry(configurationURL: URL(fileURLWithPath: value.configurationPath))
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertEqual(registry.workspaces[0].rootURL.path, workspace.path)
        XCTAssertFalse(registry.workspaces[0].allowsBroadAccess)
        for (path, mode): (String, mode_t) in [(value.configurationPath, 0o600),
            (home.path + "/.config/macbridge", 0o700), (value.observerDirectory, 0o700)] {
            var info = stat()
            XCTAssertEqual(lstat(path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, mode)
            XCTAssertEqual(info.st_uid, getuid())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: value.observerDirectory + "/observer.sock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/Library/LaunchAgents"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path + "/.config/macbridge").sorted(),
                       ["observer", "workspaces.json"])
    }

    func testSecondSetupNeverOverwritesExistingConfiguration() throws {
        let value = try plan()
        try value.createConfiguration()
        let before = try Data(contentsOf: URL(fileURLWithPath: value.configurationPath))
        XCTAssertThrowsError(try plan().createConfiguration())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: value.configurationPath)), before)
    }

    func testExistingMalformedConfigurationAndOtherFilesRemainUntouched() throws {
        let folder = try directory(".config/macbridge")
        let existing = folder.appendingPathComponent("workspaces.json")
        try Data("owner-owned incomplete configuration".utf8).write(to: existing)
        let credential = folder.appendingPathComponent("brevo.env")
        try Data("inert private fixture".utf8).write(to: credential)
        XCTAssertThrowsError(try plan().createConfiguration())
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "owner-owned incomplete configuration")
        XCTAssertEqual(try String(contentsOf: credential, encoding: .utf8), "inert private fixture")
    }

    func testSymlinkConfigAncestorRejected() throws {
        let elsewhere = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".config"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try plan().createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testSymlinkObserverDirectoryRejected() throws {
        let parent = try directory(".config/macbridge")
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("observer"), withDestinationURL: workspace)
        XCTAssertThrowsError(try plan().createConfiguration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("workspaces.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.path), [])
    }

    func testExistingPrivateDirectoryPermissionsAreNotSilentlyChanged() throws {
        let parent = try directory(".config/macbridge", mode: 0o755)
        XCTAssertThrowsError(try plan().createConfiguration())
        var info = stat()
        XCTAssertEqual(lstat(parent.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
    }

    func testWritableByOthersConfigAncestorRejected() throws {
        _ = try directory(".config", mode: 0o777)
        XCTAssertThrowsError(try plan().createConfiguration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/.config/macbridge"))
    }

    func testHomeAndFilesystemRootRejectedWithoutWriting() throws {
        for url in [home!, URL(fileURLWithPath: "/"), root!] {
            XCTAssertThrowsError(try LocalSetupPlan(workspaceURL: url, executableURL: executable, homeDirectory: home))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    func testCredentialRootAndWorkspaceSymlinkRejected() throws {
        let sensitive = try directory(".ssh")
        XCTAssertThrowsError(try LocalSetupPlan(workspaceURL: sensitive, executableURL: executable, homeDirectory: home))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)
        XCTAssertThrowsError(try LocalSetupPlan(workspaceURL: link, executableURL: executable, homeDirectory: home))
    }

    func testChangedWorkspaceFailsBeforeProvisioning() throws {
        let value = try plan()
        let moved = root.appendingPathComponent("moved-project")
        try FileManager.default.moveItem(at: workspace, to: moved)
        try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: moved)
        XCTAssertThrowsError(try value.createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    func testClientConfigurationUsesExactPathsAndNoCredentialOrBroadGrant() throws {
        let value = try plan()
        let data = Data(try value.clientConfiguration.utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: [String: Any]])
        let server = try XCTUnwrap(servers["MacBridge"])
        XCTAssertEqual(server["command"] as? String, executable.path)
        XCTAssertEqual(server["args"] as? [String], ["--config", value.configurationPath,
            "--observer-directory", value.observerDirectory])
        XCTAssertEqual(Set(server.keys), Set(["command", "args"]))
        XCTAssertEqual(servers.count, 1)
    }

    func testMountedOrTranslocatedOrMissingCoreRejected() throws {
        for path in ["/Volumes/Test/MacBridge.app/Contents/MacOS/macbridge-mcp",
                     "/private/tmp/AppTranslocation/Test/MacBridge.app/Contents/MacOS/macbridge-mcp",
                     root.path + "/missing/MacBridge.app/Contents/MacOS/macbridge-mcp"] {
            XCTAssertThrowsError(try LocalSetupPlan(workspaceURL: workspace,
                executableURL: URL(fileURLWithPath: path), homeDirectory: home))
        }
    }

    func testSymlinkOrNonExecutableCoreRejected() throws {
        XCTAssertEqual(chmod(executable.path, 0o600), 0)
        XCTAssertThrowsError(try plan())
        let moved = executable.deletingLastPathComponent().appendingPathComponent("fixture-original")
        try FileManager.default.moveItem(at: executable, to: moved)
        XCTAssertEqual(chmod(moved.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: moved)
        XCTAssertThrowsError(try plan())
    }

    func testCoreRemovedAfterReviewFailsBeforeProvisioning() throws {
        let value = try plan()
        try FileManager.default.removeItem(at: executable)
        XCTAssertThrowsError(try value.createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    func testCoreChangedToSymlinkAfterReviewFailsBeforeProvisioning() throws {
        let value = try plan()
        let moved = executable.deletingLastPathComponent().appendingPathComponent("moved-fixture")
        try FileManager.default.moveItem(at: executable, to: moved)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: moved)
        XCTAssertThrowsError(try value.createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "inert test fixture; never executed\n")
    }

    func testCoreLosingExecutablePermissionAfterReviewFailsBeforeProvisioning() throws {
        let value = try plan()
        XCTAssertEqual(chmod(executable.path, 0o600), 0)
        XCTAssertThrowsError(try value.createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        var status = stat()
        XCTAssertEqual(lstat(executable.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600, "Setup must not silently grant execute permission")
    }

    func testCoreChangedToDirectoryAfterReviewFailsBeforeProvisioning() throws {
        let value = try plan()
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: false)
        XCTAssertThrowsError(try value.createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    func testRestoredCoreCanRetryTheReviewedPlanWithoutLeftoverConfiguration() throws {
        let value = try plan()
        let moved = executable.deletingLastPathComponent().appendingPathComponent("restorable-fixture")
        try FileManager.default.moveItem(at: executable, to: moved)
        XCTAssertThrowsError(try value.createConfiguration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        try FileManager.default.moveItem(at: moved, to: executable)
        try value.createConfiguration()
        let registry = try LocalWorkspaceRegistry(configurationURL: URL(fileURLWithPath: value.configurationPath))
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertEqual(registry.workspaces[0].rootURL.path, workspace.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path + "/.config/macbridge").sorted(),
                       ["observer", "workspaces.json"])
    }
}
