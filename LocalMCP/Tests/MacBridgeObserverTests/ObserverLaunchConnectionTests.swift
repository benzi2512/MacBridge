import XCTest
@testable import MacBridgeObserver

final class ObserverLaunchConnectionTests: XCTestCase {
    func testDefaultObserverDirectorySurvivesUIStartingBeforeOwner() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let observerDirectory = home.appendingPathComponent(".config/macbridge/observer", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: home.path))
        XCTAssertEqual(
            ObserverLaunchConnection.defaultObserverDirectory(homeDirectory: home),
            observerDirectory.path
        )
        XCTAssertFalse(fileManager.fileExists(atPath: home.path), "Discovery must not create a directory, socket or owner")
    }

    func testDefaultPathIsScopedToTheSuppliedUserHome() {
        let home = URL(fileURLWithPath: "/fixtures/Users/example user", isDirectory: true)
        XCTAssertEqual(ObserverLaunchConnection.defaultObserverDirectory(homeDirectory: home),
                       "/fixtures/Users/example user/.config/macbridge/observer")
    }

    func testFirstLaunchOpensSetupWithoutCreatingConfiguration() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(ObserverLaunchConnection.shouldShowSetup(arguments: [], homeDirectory: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testExplicitObserverOrDashboardDoesNotOpenSetupAtLogin() {
        let home = URL(fileURLWithPath: "/fixtures/missing-home")
        for arguments in [["--observer-directory", "/fixtures/private-observer"], ["--dashboard"]] {
            XCTAssertFalse(ObserverLaunchConnection.shouldShowSetup(arguments: arguments, homeDirectory: home))
        }
        XCTAssertTrue(ObserverLaunchConnection.shouldShowSetup(arguments: ["--observer-directory", "/fixtures/owner", "--setup"],
                                                               homeDirectory: home))
    }

    func testExistingRegistryOrOwnerDoesNotTriggerReplacementSetup() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent(".config/macbridge")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("observer"), withIntermediateDirectories: true)
        for component in ["workspaces.json", "observer/observer-owner.json", "observer/observer.sock"] {
            let path = base.appendingPathComponent(component)
            try Data("inert presence fixture".utf8).write(to: path)
            XCTAssertFalse(ObserverLaunchConnection.shouldShowSetup(arguments: [], homeDirectory: home))
            try FileManager.default.removeItem(at: path)
        }
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("workspaces.json"),
                                                  withDestinationURL: home.appendingPathComponent("missing"))
        XCTAssertFalse(ObserverLaunchConnection.shouldShowSetup(arguments: [], homeDirectory: home),
                       "A broken existing configuration must not be treated as a new install")
    }
}
