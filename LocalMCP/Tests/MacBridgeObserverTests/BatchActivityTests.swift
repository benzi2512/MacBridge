import XCTest
@testable import MacBridgeObserver

// Pure presentation data: no IPC, file writes, processes or network.
final class BatchActivityTests: XCTestCase {
    func testPartialWritesAppearInIssuesWithoutClaimingWholeCallFailed() {
        let event: [String: Any] = ["tool": "file_write_many", "state": "returned",
            "result": ["complete": false, "success_count": 2, "error_count": 1]]
        let shown = ActivityPresentation.event(event, connected: true)
        XCTAssertTrue(ActivityPresentation.matches(event, query: "", filter: .issues, connected: true))
        XCTAssertFalse(shown.failed)
        XCTAssertEqual(shown.title, "File batch returned")
        XCTAssertTrue(shown.subtitle.contains("Partial result"))
        XCTAssertTrue(shown.subtitle.contains("2 applied"))
        XCTAssertTrue(shown.subtitle.contains("errors: 1"))
    }

    func testIncompleteAndBudgetSkippedResultsAreNotHidden() {
        for result: [String: Any] in [
            ["complete": false, "read_count": 1, "error_count": 0],
            ["skipped_count": 1], ["partial": true], ["error_count": 2],
        ] {
            let event: [String: Any] = ["tool": "file_read_many", "state": "returned", "result": result]
            XCTAssertTrue(ActivityPresentation.matches(event, query: "", filter: .issues, connected: true))
            XCTAssertTrue(ActivityPresentation.event(event, connected: true).subtitle.contains("Partial result"))
        }
        let complete: [String: Any] = ["tool": "file_write_many", "state": "returned",
            "result": ["complete": true, "success_count": 2, "error_count": 0, "skipped_count": 0]]
        XCTAssertFalse(ActivityPresentation.matches(complete, query: "", filter: .issues, connected: true))
        XCTAssertFalse(ActivityPresentation.event(complete, connected: true).subtitle.contains("Partial"))
    }

    func testDeveloperGatewayNamesItsConcreteAction() {
        let event: [String: Any] = [
            "tool": "developer_task", "state": "returned",
            "detail": ["developer_action": "run_tests", "cwd": "Project"],
            "result": ["running": true],
        ]
        let shown = ActivityPresentation.event(event, connected: true)
        XCTAssertEqual(shown.title, "Project tests started")
        XCTAssertTrue(shown.subtitle.contains("Running when tool returned"))

        let inspection: [String: Any] = [
            "tool": "developer_inspect", "state": "returned",
            "detail": ["developer_action": "review_diff", "cwd": "Project"],
            "result": [:],
        ]
        XCTAssertEqual(
            ActivityPresentation.event(inspection, connected: true).title,
            "Reviewed changes"
        )
    }
}
