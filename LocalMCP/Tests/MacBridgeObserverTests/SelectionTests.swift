import XCTest
@testable import MacBridgeObserver

// Model-only regression: no window, IPC, child process or filesystem changes.
final class SelectionTests: XCTestCase {
    @MainActor
    func testSelectionClearsOldDetailSynchronously() {
        let model = ObserverModel()
        model.selection = "job:first"
        model.detail = "Old output"
        model.detailResult = ["stdout": "Old output"]
        model.selection = "job:second"
        XCTAssertEqual(model.detail, "")
        XCTAssertTrue(model.detailResult.isEmpty)
    }

    @MainActor
    func testExpiredHandleMessageSurvivesDeselectAndNoSelectionInspection() async {
        let model = ObserverModel()
        model.selection = "job:first"
        model.detail = "Old output"
        model.selection = nil
        let message = "This handle is no longer active on the owner."
        model.detail = message
        // The view's selection callback may schedule this after refresh returns.
        await model.inspectSelection()
        XCTAssertEqual(model.detail, message)
        XCTAssertTrue(model.detailResult.isEmpty)
        model.selection = "event:next"
        XCTAssertEqual(model.detail, "")
    }
}
