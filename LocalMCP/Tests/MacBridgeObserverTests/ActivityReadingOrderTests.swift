import XCTest
@testable import MacBridgeObserver

final class ActivityReadingOrderTests: XCTestCase {
    private func work(_ id: String, updated: Int, completed: Bool = false) -> [String: Any] {
        ["work_id": id, "title": "Task " + id, "workspace_id": "ws", "updated_ms": updated,
         "state": completed ? "completed" : "active", "phase": completed ? "completed" : "executing"]
    }
    private func call(_ id: String, work: String, started: Int, running: Bool = false) -> [String: Any] {
        ["id": id, "work_id": work, "tool": "file_read", "workspace_id": "ws",
         "state": running ? "running" : "returned", "started_ms": started]
    }
    private func feed(_ works: [[String: Any]], calls: [[String: Any]] = [], connected: Bool = true) -> ActivityFeed {
        ActivityFeed(history: calls, jobs: [], workItems: works,
                     workspaces: [["workspace_id": "ws", "display_name": "Fixture"]],
                     workspace: "all", connected: connected, stale: !connected)
    }
    private func order(_ feed: ActivityFeed, filter: ActivityPresentation.Filter = .all) -> ActivityReadingOrder {
        ActivityReadingOrder(feed: feed, transactions: [], owner: "owner", workspace: "all", query: "", filter: filter)
    }

    func testAnotherParentRisingAndNewChildrenAboveReaderDoNotMoveHeldSlots() {
        let initial = feed([work("A", updated: 20), work("B", updated: 10)],
                           calls: [call("a1", work: "A", started: 10), call("b1", work: "B", started: 9)])
        let reading = order(initial)
        XCTAssertEqual(reading.groupIDs, ["work:A", "work:B"])
        let update = feed([work("A", updated: 21), work("B", updated: 30), work("C", updated: 40)],
                          calls: [call("a2", work: "A", started: 25, running: true),
                                  call("a1", work: "A", started: 10), call("b1", work: "B", started: 9)])
        XCTAssertEqual(order(update).groupIDs, ["work:C", "work:B", "work:A"])
        XCTAssertEqual(reading.groupIDs, ["work:A", "work:B"])
        XCTAssertEqual(reading.childIDs["work:A"], ["event:a1"], "A new child above B must not push B down")
        XCTAssertEqual(order(update).childIDs["work:A"], ["event:a2", "event:a1"], "Show latest captures the new rows")
        XCTAssertEqual(update.runningCount, 1, "Live counts are not frozen with reading positions")
    }

    func testCompletionRetainsPositionButUsesFreshCompletedStatusAndActiveCount() throws {
        let reading = order(feed([work("A", updated: 1)]), filter: .running)
        let completed = feed([work("A", updated: 2, completed: true)])
        XCTAssertEqual(reading.groupIDs, ["work:A"])
        XCTAssertEqual(completed.displayCount(filter: .running), 0)
        let live = try XCTUnwrap(completed.groups.first { $0.id == reading.groupIDs.first })
        XCTAssertFalse(live.active)
        XCTAssertEqual(CompactRowContent(work: live).status, "Completed")
        XCTAssertTrue(order(completed, filter: .running).groupIDs.isEmpty)
    }

    func testExplicitContextChangesAndOwnerReplacementReleaseReadingOrder() {
        let reading = order(feed([work("A", updated: 1)]))
        XCTAssertTrue(reading.matches(owner: "owner", workspace: "all", query: "", filter: .all))
        XCTAssertFalse(reading.matches(owner: "replacement", workspace: "all", query: "", filter: .all))
        XCTAssertFalse(reading.matches(owner: nil, workspace: "all", query: "", filter: .all))
        XCTAssertFalse(reading.matches(owner: "owner", workspace: "other", query: "", filter: .all))
        XCTAssertFalse(reading.matches(owner: "owner", workspace: "all", query: "file", filter: .all))
        XCTAssertFalse(reading.matches(owner: "owner", workspace: "all", query: "", filter: .issues))
    }

    @MainActor
    func testExpiredHeldIDDoesNotBecomeAUsableHandleAndDisconnectIsHonest() throws {
        let initial = feed([work("A", updated: 1)], calls: [call("a1", work: "A", started: 1)])
        let reading = order(initial)
        let expired = feed([])
        XCTAssertEqual(reading.childIDs["work:A"], ["event:a1"])
        XCTAssertNil(expired.items.first { $0.id == "event:a1" }, "The UI must show an unavailable placeholder, not cached payload")
        let model = ObserverModel()
        model.connected = true
        model.updateSnapshot(["jobs": [], "history": [], "work_items": [], "transactions": []])
        model.selection = "event:a1"
        XCTAssertNil(model.selectedActivity)
        XCTAssertNil(model.selectedJob)
        XCTAssertNil(model.selectedTransaction)
        XCTAssertNil(model.selectedPreviewEventID)
        XCTAssertFalse(model.canOpenPreview)
        model.selection = nil // The owner's expiry handling clears controls/details.
        XCTAssertEqual(reading.groupIDs, ["work:A"], "Implicit deselection must not release the separate reading order")
        XCTAssertEqual(reading.childIDs["work:A"], ["event:a1"])
        XCTAssertEqual(CompactRowContent(unavailableItemID: "event:a1").status, "Unavailable")
        XCTAssertFalse(CompactRowContent(unavailableItemID: "event:a1").active)
        let offline = try XCTUnwrap(feed([work("A", updated: 1)], connected: false).groups.first)
        XCTAssertFalse(offline.executing)
        XCTAssertEqual(CompactRowContent(work: offline).status, "Offline")
    }

    func testReadingOrderHasAnAggregateIDBound() {
        let calls = (0..<2_000).map { call("c\($0)", work: "A", started: $0) }
        let reading = order(feed([work("A", updated: 1)], calls: calls))
        let total = reading.groupIDs.count + reading.contextIDs.count + reading.childIDs.values.reduce(0) { $0 + $1.count }
            + reading.liveIDs.count + reading.recentIDs.count + reading.retainedIDs.count + reading.transactionIDs.count
        XCTAssertEqual(total, ActivityReadingOrder.maximumRows)
    }
}
