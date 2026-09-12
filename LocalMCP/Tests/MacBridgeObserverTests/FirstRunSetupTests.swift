import AppKit
import Darwin
import MacBridgeLocalCore
import XCTest
@testable import MacBridgeObserver

final class FirstRunSetupTests: XCTestCase {
    @MainActor
    func testRestartRecoversCopyableInstructionsWithoutAttachingAnOwner() throws {
        var template = Array("/private/tmp/mb-onboard-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw LocalMCPError.operationFailed("fixture creation failed") }
        let root = URL(fileURLWithPath: String(cString: created))
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let workspace = root.appendingPathComponent("project")
        let executable = root.appendingPathComponent("Applications/MacBridge.app/Contents/MacOS/macbridge-mcp")
        for path in [home, workspace, executable.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        try Data("inert executable fixture; not executed".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let proposal = try LocalSetupPlan(workspaceURL: workspace, executableURL: executable, homeDirectory: home)
        try proposal.createConfiguration()
        let registryURL = URL(fileURLWithPath: proposal.configurationPath)
        let before = try Data(contentsOf: registryURL)
        var copies: [String] = []
        let model = FirstRunSetupModel(executableURL: executable, homeDirectory: home,
            copyToClipboard: { copies.append($0) }, onConfigured: { _ in XCTFail("Recovery must not change the observer owner") })
        XCTAssertTrue(model.configured)
        XCTAssertFalse(model.recoveryFailed)
        XCTAssertEqual(model.existing?.workspaceCount, 1)
        XCTAssertEqual(model.clientConfiguration, try proposal.clientConfiguration)
        model.copyClientConfiguration()
        XCTAssertEqual(copies, [try proposal.clientConfiguration])
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: proposal.observerDirectory), [])

        let moved = executable.deletingLastPathComponent().appendingPathComponent("moved-core")
        try FileManager.default.moveItem(at: executable, to: moved)
        model.copyClientConfiguration()
        XCTAssertTrue(model.recoveryFailed)
        XCTAssertTrue(model.clientConfiguration.isEmpty)
        XCTAssertEqual(copies.count, 1, "Failure must preserve the previous clipboard")
        try FileManager.default.moveItem(at: moved, to: executable)
        model.reloadExistingConfiguration()
        XCTAssertFalse(model.recoveryFailed)
        model.copyClientConfiguration()
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }
}
