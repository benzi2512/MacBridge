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
}
