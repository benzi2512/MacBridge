import Combine
import XCTest
@testable import MacBridgeObserver

// Model-only resource regressions. No owner, socket, process, UI window, live
// credentials, measurement tool, or filesystem fixture is needed by these tests.
final class ObserverResourceTests: XCTestCase {
    func testHealthyCadenceRetainsLiveProgressAndReducesLowPowerWakeups() {
        XCTAssertEqual(delay(active: true, work: true), 1)
        XCTAssertEqual(delay(active: true, work: false), 3)
        XCTAssertEqual(delay(active: false, work: true), 5)
        XCTAssertEqual(delay(active: false, work: false), 5)
        XCTAssertEqual(delay(active: true, work: true, lowPower: true), 5)
        XCTAssertEqual(delay(active: true, work: false, lowPower: true), 5)
    }

    func testOfflineRetriesBackOffAndRemainBounded() {
        XCTAssertEqual((1...8).map { delay(active: true, work: false, failures: $0) },
                       [3, 6, 12, 24, 30, 30, 30, 30])
        XCTAssertEqual(delay(active: false, work: true, failures: 1), 5)
        XCTAssertEqual(delay(active: false, work: true, lowPower: true, failures: 5), 30)
        XCTAssertEqual(delay(active: true, work: true, failures: 0), 1,
                       "A successful refresh resets failure backoff")
    }

    @MainActor
    func testIdenticalOfflinePollsDoNotRepublishOrRebuildDetail() {
        let model = ObserverModel()
        model.connected = true
        model.busy = true
        model.detail = "Previous live output"
        model.detailResult = ["stdout": "Previous live output"]
        let failure = NSError(domain: "Fixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Fixture owner unavailable"])
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        model.recordSnapshotFailure(failure)
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.detailResult.isEmpty)
        XCTAssertTrue(model.detail.contains("stale"))
        XCTAssertGreaterThan(changes, 0, "The first failure remains visible")
        let initialChanges = changes
        for _ in 0..<100 { model.recordSnapshotFailure(failure) }
        XCTAssertEqual(changes, initialChanges, "Unchanged failures must not invalidate every widget surface")
        model.recordSnapshotFailure(NSError(domain: "Fixture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Fixture endpoint permissions changed"]))
        XCTAssertEqual(changes, initialChanges + 1, "A new failure reason still updates the notice")
    }

    @MainActor
    func testUnattachedObserverHasNoRefreshWorkAndCanBeReleased() async {
        var model: ObserverModel? = ObserverModel()
        weak var weakModel = model
        var changes = 0
        let subscription = model?.objectWillChange.sink { changes += 1 }
        model?.startPolling(refreshImmediately: true)
        await model?.refresh()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model?.directory, "")
        subscription?.cancel()
        model = nil
        XCTAssertNil(weakModel, "No background wake loop should retain an unattached observer")
    }

    private func delay(active: Bool, work: Bool, lowPower: Bool = false, failures: Int = 0) -> UInt64 {
        ObserverPollingCadence.delayNanoseconds(appActive: active, activeWork: work,
            lowPower: lowPower, consecutiveFailures: failures) / 1_000_000_000
    }

}
