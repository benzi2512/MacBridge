import AppKit
import XCTest
@testable import MacBridgeObserver

/// Pure/synthetic compact-surface checks. These never attach to a live owner,
/// run commands, access the network, or mutate user files.
final class CompactSurfaceTests: XCTestCase {
    private let workspaces: [[String: Any]] = [["workspace_id": "app", "display_name": "MacBridge"]]

    private func work(_ index: Int, state: String = "active", phase: String = "executing",
                      jobs: [String] = []) -> [String: Any] {
        ["work_id": "work-\(index)", "title": "Task \(index)", "chat_label": "Chat \(index)",
         "workspace_id": "app", "state": state, "phase": phase,
         "updated_ms": 10_000 + index, "call_count": 1, "error_count": 0,
         "active_call_count": phase == "executing" ? 1 : 0, "job_ids": jobs, "stale": false]
    }

    private func summary(works: [[String: Any]], history: [[String: Any]] = [], jobs: [[String: Any]] = [],
                         connected: Bool = true, busy: Bool = false) -> CompactSummary {
        let feed = ActivityFeed(history: history, jobs: jobs, workItems: works, workspaces: workspaces,
                                workspace: "all", connected: connected, stale: false,
                                now: Date(timeIntervalSince1970: 20))
        return CompactSummary(feed: feed, connected: connected, busy: busy)
    }

    func testSummaryStatusPrecedenceAndOfflineHonesty() {
        let rows = [work(1), work(2, phase: "waiting_next_step"),
                    work(3, state: "failed", phase: "failed"), work(4, state: "completed", phase: "completed")]
        let current = summary(works: rows)
        XCTAssertEqual(current.runningCount, 1)
        XCTAssertEqual(current.waitingCount, 1)
        XCTAssertEqual(current.activeCount, 2)
        XCTAssertEqual(current.activeBadgeText, "2")
        XCTAssertEqual(current.failedCount, 1)
        XCTAssertEqual(current.globalStatus, .running)
        XCTAssertEqual(current.statusText, "1 running")
        XCTAssertEqual(current.tasks.map(\.status), [.running, .waiting, .failed, .completed])

        let offline = summary(works: rows, connected: false)
        XCTAssertEqual(offline.globalStatus, .paused)
        XCTAssertEqual(offline.statusText, "disconnected")
        XCTAssertTrue(offline.tasks.allSatisfy { $0.status == .paused })

        let busy = summary(works: [], busy: true)
        XCTAssertEqual(busy.globalStatus, .idle)
        XCTAssertEqual(busy.statusText, "updating")
    }

    func testRunningBadgeUsesZeroExactAndNinetyNinePlusRules() {
        XCTAssertEqual(summary(works: []).runningBadgeText, "0")
        XCTAssertEqual(summary(works: [], connected: false).runningBadgeText, "–")
        for count in [1, 2, 99, 100, 140] {
            let value = summary(works: (0..<count).map { work($0) })
            XCTAssertEqual(value.runningCount, count)
            XCTAssertEqual(value.runningBadgeText, count > 99 ? "99+" : String(count))
        }
    }

    func testOneTaskRepresentsItsReturnedStartReceiptAndCurrentJob() throws {
        var start: [String: Any] = ["id": "start", "tool": "command_start", "state": "returned",
            "workspace_id": "app", "work_id": "work-1", "cwd": "/fixtures/MacBridge",
            "started_ms": 1_000, "finished_ms": 1_002,
            "result": ["task_id": "job-1", "running": true]]
        start["detail"] = ["command_preview": "swift test --jobs 2"]
        let job: [String: Any] = ["task_id": "job-1", "workspace_id": "app", "running": true,
                                  "started_milliseconds": 1_000]
        let current = summary(works: [work(1, jobs: ["job-1"])], history: [start], jobs: [job])
        XCTAssertEqual(current.tasks.count, 1)
        XCTAssertEqual(current.runningCount, 1)
        XCTAssertEqual(current.tasks.first?.title, "Task 1")
        XCTAssertTrue(current.tasks.first?.shortActivity.contains("swift test") == true)
    }

    func testEveryLayerFitsVisibleFramesAndStaysFlushToRightEdge() {
        let layers: [FloatingLayer] = [.idle, .rail, .recentTasks, .settings, .taskDetail("task")]
        let frames = [
            CGRect(x: 0, y: 25, width: 1_512, height: 957),
            CGRect(x: 80, y: 48, width: 1_360, height: 760), // left/bottom Dock already removed
            CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 10, y: 20, width: 120, height: 140),
            CGRect(x: 5, y: 7, width: 40, height: 60),
        ]
        for visible in frames {
            for layer in layers {
                for anchor in [-2.0, 0.14, 0.40, 0.86, 2.0] as [CGFloat] {
                    let frame = EdgeLayout.frame(visibleFrame: visible, layer: layer, normalizedFromTop: anchor)
                    XCTAssertTrue(EdgeLayout.isContained(frame, in: visible), "\(layer) escaped \(visible): \(frame)")
                    XCTAssertEqual(frame.maxX, visible.maxX, accuracy: 0.001)
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                }
            }
        }
        XCTAssertEqual(EdgeLayout.size(for: .idle, visibleFrame: frames[0]),
                       CGSize(width: MBMetrics.edgeIdleWidth, height: MBMetrics.edgeIdleHeight))
        XCTAssertEqual(EdgeLayout.size(for: .rail, visibleFrame: frames[0]),
                       CGSize(width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight))
        XCTAssertLessThanOrEqual(MBMetrics.edgeIdleWidth, 30, "The idle handle must remain extremely narrow")
        XCTAssertLessThanOrEqual(MBMetrics.edgeRailWidth, 36, "Hover must not restore the old wide rail")
        XCTAssertEqual(EdgeLayout.railLogoOffset,
                       (MBMetrics.edgeRailHeight - MBMetrics.edgeIdleHeight) / 2,
                       "The idle mark must remain anchored at the rail's first position")
        XCTAssertEqual(EdgeLayout.size(for: .recentTasks, visibleFrame: frames[0]).width,
                       MBMetrics.edgeRailWidth + MBMetrics.panelGap + MBMetrics.panelWidth)
        XCTAssertEqual(EdgeLayout.size(for: .taskDetail("task"), visibleFrame: frames[0]).width,
                       MBMetrics.edgeRailWidth + MBMetrics.panelGap + MBMetrics.taskDetailWidth)
        XCTAssertGreaterThan(EdgeLayout.recentTasksHeight(taskCount: 0), 0)
        XCTAssertEqual(EdgeLayout.recentTasksHeight(taskCount: 0), 224)
        XCTAssertEqual(EdgeLayout.recentTasksHeight(taskCount: 2), EdgeLayout.recentTasksHeight(taskCount: 1))
        XCTAssertGreaterThan(EdgeLayout.recentTasksHeight(taskCount: 6), EdgeLayout.recentTasksHeight(taskCount: 3))
        XCTAssertEqual(EdgeLayout.recentTasksHeight(taskCount: 6), 416)
        XCTAssertEqual(EdgeLayout.recentTasksHeight(taskCount: 64), EdgeLayout.recentTasksHeight(taskCount: 6))
        XCTAssertEqual(EdgeLayout.recentTasksHeight(taskCount: 99), EdgeLayout.recentTasksHeight(taskCount: 6),
                       "Long task lists scroll within a bounded viewport")
    }

    func testCompactTaskSwitcherOmitsCompletedOneShotReceipts() {
        let history: [[String: Any]] = [
            ["id": "catalog", "tool": "tool_catalog", "state": "returned", "result": ["count": 55]],
            ["id": "status", "tool": "git_status", "state": "returned", "result": ["exit_code": 0]],
        ]
        let current = summary(works: [], history: history)
        XCTAssertTrue(current.tasks.isEmpty, "Raw completed receipts belong in Dashboard, not Recent Tasks")
    }

    func testInteractionStateMachineHonorsDwellLockGraceAndDeepEscape() {
        var machine = FloatingInteractionStateMachine()
        machine.hoverDelayElapsed(pointerInside: false)
        XCTAssertEqual(machine.layer, .idle)
        machine.hoverDelayElapsed(pointerInside: true)
        XCTAssertEqual(machine.layer, .rail)
        machine.select(.recentTasks)
        XCTAssertTrue(machine.locked)
        machine.exitGraceElapsed(pointerInside: false)
        XCTAssertEqual(machine.layer, .recentTasks)
        machine.select(.taskDetail("task"))
        machine.closeDeepest()
        XCTAssertEqual(machine.layer, .recentTasks)
        machine.closeDeepest()
        XCTAssertEqual(machine.layer, .rail)
        XCTAssertFalse(machine.locked)
        machine.exitGraceElapsed(pointerInside: false)
        XCTAssertEqual(machine.layer, .idle)

        machine.select(.settings, locked: false)
        XCTAssertFalse(machine.locked)
        machine.exitGraceElapsed(pointerInside: false)
        XCTAssertEqual(machine.layer, .idle)
    }

    func testOneHundredHoverCyclesLeaveNoLogicalStateBehind() {
        var machine = FloatingInteractionStateMachine()
        for _ in 0..<100 {
            machine.hoverDelayElapsed(pointerInside: true)
            XCTAssertEqual(machine.layer, .rail)
            machine.exitGraceElapsed(pointerInside: false)
            XCTAssertEqual(machine.layer, .idle)
        }
        XCTAssertFalse(machine.locked)
    }

    func testMotionDurationsMatchSpecification() {
        for expanded in [false, true] {
            for reduced in [false, true] {
                XCTAssertEqual(FloatingMotion.duration(expanded: expanded, reduced: reduced),
                               reduced ? 0.10 : expanded ? 0.20 : 0.24, accuracy: 0.001)
            }
        }
    }

    func testLogoAndRailStayAnchoredAcrossEveryPanelAndTaskCount() {
        for visible in [CGRect(x: 0, y: 25, width: 1512, height: 957),
                        CGRect(x: -1920, y: 0, width: 1920, height: 1080)] {
            for anchor: CGFloat in [0.14, 0.40, 0.86] {
                let idle = EdgeLayout.frame(visibleFrame: visible, layer: .idle, normalizedFromTop: anchor)
                for layer: FloatingLayer in [.rail, .recentTasks, .settings, .taskDetail("a")] {
                    for count in [0, 1, 3, 6, 64] {
                        let frame = EdgeLayout.frame(visibleFrame: visible, layer: layer,
                                                     normalizedFromTop: anchor, taskCount: count)
                        XCTAssertEqual(frame.midY + EdgeLayout.railLogoOffset, idle.midY, accuracy: 0.001)
                        XCTAssertEqual(frame.maxX, idle.maxX, accuracy: 0.001)
                    }
                }
            }
        }
    }

    @MainActor
    func testHoverPreviewDwellClickPinAndPendingExitCannotReplaceSelection() async throws {
        _ = NSApplication.shared
        let suite = "MacBridge.HoverPinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingTabController(model: ObserverModel(), preferences: ObserverPreferences(defaults: defaults),
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.show(.rail)
        controller.pointerChanged(true)
        controller.preview(.settings, inside: true)
        controller.preview(.settings, inside: false)
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertEqual(controller.layer, .rail, "Crossing an icon must not open its panel")
        controller.preview(.recentTasks, inside: true)
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertEqual(controller.layer, .recentTasks)
        XCTAssertFalse(controller.machine.locked)
        controller.pointerChanged(false) // pending exit before deliberate click
        controller.activate(.recentTasks)
        XCTAssertTrue(controller.machine.locked, "First click pins the preview instead of closing it")
        controller.preview(.settings, inside: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.layer, .recentTasks)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        controller.show(.taskDetail("selected"))
        controller.preview(.recentTasks, inside: true)
        try await Task.sleep(nanoseconds: 140_000_000)
        XCTAssertEqual(controller.layer, .taskDetail("selected"))
        controller.activate(.recentTasks)
        controller.activate(.recentTasks)
        XCTAssertEqual(controller.layer, .rail, "Second deliberate click closes pinned panel")
    }

    @MainActor
    func testPreferencesPersistClampDisplayAnchorsAndNeverHideEverySurface() throws {
        let suite = "MacBridge.CompactSurfaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var preferences: ObserverPreferences? = ObserverPreferences(defaults: defaults)
        XCTAssertTrue(preferences?.showMenuBar == true)
        XCTAssertTrue(preferences?.showFloatingTab == true)
        XCTAssertTrue(preferences?.showTaskCount == true)
        XCTAssertFalse(preferences?.showInFullscreen == true)
        XCTAssertEqual(preferences?.glassOpacity ?? 0, ObserverPreferences.defaultGlassOpacity, accuracy: 0.0001)
        preferences?.showTaskCount = false
        preferences?.reduceMacBridgeMotion = true
        preferences?.setNormalizedY(-1, for: "top")
        preferences?.setNormalizedY(2, for: "bottom")
        XCTAssertEqual(try XCTUnwrap(preferences).normalizedY(for: "top"), 0.14, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(preferences).normalizedY(for: "bottom"), 0.86, accuracy: 0.0001)
        for index in 0..<20 { preferences?.setNormalizedY(0.40, for: "display-\(index)") }
        XCTAssertLessThanOrEqual(preferences?.verticalAnchors.count ?? 100, 16)
        preferences = nil

        let restored = ObserverPreferences(defaults: defaults)
        XCTAssertFalse(restored.showTaskCount)
        XCTAssertTrue(restored.reduceMacBridgeMotion)
        defaults.set(false, forKey: "ui.showMenuBar")
        defaults.set(false, forKey: "ui.showFloatingTab")
        let recovered = ObserverPreferences(defaults: defaults)
        XCTAssertTrue(recovered.showMenuBar)
        XCTAssertFalse(recovered.showFloatingTab)
    }

    @MainActor
    func testControllerCoalescesRapidHoverTransitionsWithoutCreatingAWindow() async throws {
        _ = NSApplication.shared
        let suite = "MacBridge.ControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingTabController(model: ObserverModel(), preferences: ObserverPreferences(defaults: defaults),
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        controller.start()
        for _ in 0..<100 {
            controller.pointerChanged(true)
            controller.pointerChanged(false)
            XCTAssertLessThanOrEqual(controller.pendingTransitionCount, 1)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
        XCTAssertEqual(controller.layer, .idle)
        controller.stop()
    }

    @MainActor
    func testDisabledFloatingSurfaceDoesNotCreateHiddenPanel() throws {
        _ = NSApplication.shared
        let suite = "MacBridge.DisabledFloating.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ui.showMenuBar")
        defaults.set(false, forKey: "ui.showFloatingTab")
        let controller = FloatingTabController(model: ObserverModel(), preferences: ObserverPreferences(defaults: defaults),
            openDashboard: { _ in }, openSettings: {})
        XCTAssertFalse(controller.hasCreatedPanel)
        controller.start()
        XCTAssertFalse(controller.hasCreatedPanel)
        controller.stop()
        XCTAssertFalse(controller.hasCreatedPanel)
    }
}
