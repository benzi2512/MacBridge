import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

final class DesignSpecificationTests: XCTestCase {
    private func task(_ id: String, _ status: CompactTaskStatus = .running) -> CompactTaskPresentation {
        CompactTaskPresentation(id: id, title: id, projectName: "Fixture", status: status,
            progress: nil, startedAt: nil, updatedAt: nil, shortActivity: "Fixture activity",
            selectionID: id, canCancel: false)
    }

    func testReadingOrderKeepsRowsWhenAnotherTaskBecomesFirst() {
        var order = CompactReadingOrder()
        order.capture([task("a"), task("b"), task("c"), task("existing-offscreen")])
        XCTAssertEqual(order.pendingCount([task("a"), task("b"), task("c"), task("existing-offscreen")]), 0)
        let changed = [task("new"), task("b"), task("a", .completed), task("c")]
        XCTAssertEqual(order.rows(changed).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(order.rows(changed).first?.status, .completed, "Order is held, not the payload")
        XCTAssertEqual(order.pendingCount(changed), 1)
        XCTAssertEqual(order.ids, ["a", "b", "c", "existing-offscreen"])
        XCTAssertEqual(order.ids.count, 4)
        order.capture(changed)
        XCTAssertEqual(order.ids, ["new", "b", "a", "c"])
    }

    func testLongReadingOrderKeepsScrollableRowsStableAndBoundsRetainedIDs() {
        let initial = (0..<100).map { task("task-\($0)") }
        var order = CompactReadingOrder()
        order.capture(initial)
        XCTAssertEqual(order.ids.count, 64, "Keep more than the former three rows without retaining unbounded history")
        XCTAssertEqual(order.ids.first, "task-0")
        XCTAssertEqual(order.ids.last, "task-63", "Rows below the six-row viewport remain reachable")
        XCTAssertEqual(order.pendingCount(initial), 0, "Existing overflow must not masquerade as a new update")

        let reordered = [task("new"), task("task-63", .completed)]
            + initial.reversed().filter { $0.id != "task-63" }
        let rows = order.rows(reordered)
        XCTAssertEqual(rows.map(\.id), order.ids, "A live update must not jump the user's scrolled reading position")
        XCTAssertEqual(rows.last?.status, .completed, "Rows retain fresh payloads, not frozen task copies")
        XCTAssertEqual(order.pendingCount(reordered), 1)

        order.capture(reordered)
        XCTAssertEqual(order.ids.count, 64)
        XCTAssertEqual(order.ids.first, "new", "Explicit refresh adopts the latest order")
        XCTAssertEqual(order.pendingCount(reordered), 0)
    }

    func testExpiredTaskKeepsItsSlotWithoutRetainingPayload() {
        var order = CompactReadingOrder()
        order.capture([task("a"), task("b")])
        XCTAssertEqual(order.rows([task("b")]).map(\.id), ["b"])
        XCTAssertEqual(order.ids, ["a", "b"], "View renders a same-height placeholder for the missing ID")
    }

    func testShapeHonorsCanvasOriginAndContainsStationaryLogoAcrossMorph() {
        let canvas = CGRect(x: 0, y: 0, width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight)
        let logo = CGPoint(x: canvas.maxX - EdgeLayout.logoInset,
                           y: canvas.midY - EdgeLayout.railLogoOffset)
        for step in 0...100 {
            let t = CGFloat(step) / 100
            let path = AnchoredOrganicEdgeShape(expansion: t).path(in: canvas)
            XCTAssertTrue(path.contains(logo), "Logo must remain inside silhouette at \(t)")
            XCTAssertEqual(path.boundingRect.maxX, canvas.maxX, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(path.boundingRect.minX, 0)
            XCTAssertGreaterThanOrEqual(path.boundingRect.minY, -1e-8, "Allow floating-point roundoff, not visible clipping")
            XCTAssertLessThanOrEqual(path.boundingRect.maxY, canvas.maxY)
        }
        let idle = AnchoredOrganicEdgeShape(expansion: 0).path(in: canvas).boundingRect
        XCTAssertEqual(idle.height, MBMetrics.edgeIdleHeight, accuracy: 0.01)
        XCTAssertEqual(idle.midY, logo.y, accuracy: 0.01)
    }

    @MainActor
    func testRealWindowControllersSetChromeBeforeShowAndReturnToSystem() throws {
        _ = NSApplication.shared
        let suite = "MacBridge.WindowChrome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.appearance = .dark
        let model = ObserverModel()
        let dashboard = DashboardWindowController(model: model, preferences: preferences)
        let settings = SettingsWindowController(preferences: preferences)
        let windows = [dashboard.prepareWindow(), settings.prepareWindow()]
        let globalAppearance = NSApp.appearance
        defer { windows.forEach { $0.close() } }
        for window in windows {
            XCTAssertFalse(window.isVisible, "Tests must not present a window or change focus")
            XCTAssertEqual(window.appearance?.name, .darkAqua)
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
            XCTAssertTrue(window.titlebarAppearsTransparent)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
        }
        preferences.appearance = .light
        windows.forEach { XCTAssertEqual($0.appearance?.name, .aqua) }
        preferences.appearance = .system
        windows.forEach { XCTAssertNil($0.appearance) }
        XCTAssertEqual(NSApp.appearance, globalAppearance, "Appearance is local to the Observer windows")
        XCTAssertTrue(dashboard.prepareWindow() === windows[0])
        XCTAssertTrue(settings.prepareWindow() === windows[1])
        XCTAssertEqual(model.directory, "", "No live owner is attached")
        // Recreating a closed window must subscribe to the current preference.
        windows.forEach { $0.close() }
        preferences.appearance = .dark
        let reopened = [dashboard.prepareWindow(), settings.prepareWindow()]
        defer { reopened.forEach { $0.close() } }
        for (old, new) in zip(windows, reopened) {
            XCTAssertFalse(old === new)
            XCTAssertEqual(new.appearance?.name, .darkAqua)
            XCTAssertFalse(new.isVisible)
        }
    }

    @MainActor
    func testReducedTransparencyReadingSurfaceIsNeutralAndOpaque() throws {
        // Only the accessibility fallback is raster-tested here. Native glass
        // still requires compositor acceptance, not an offscreen bitmap claim.
        _ = NSApplication.shared
        for scheme: ColorScheme in [.light, .dark] {
            let host = NSHostingView(rootView: ObserverReadingSurface()
                .environment(\.colorScheme, scheme)
                .environment(\.mbReduceTransparency, true)
                .frame(width: 120, height: 80))
            host.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let rgb = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(rgb.alphaComponent, 0.99)
            XCTAssertEqual(rgb.redComponent, rgb.greenComponent, accuracy: 0.015)
            XCTAssertEqual(rgb.greenComponent, rgb.blueComponent, accuracy: 0.015)
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    func testAppearanceMigrationAndNewPreferencesRoundTrip() throws {
        let suite = "MacBridge.DesignSpec.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "ui.followSystemAppearance")
        let migrated = ObserverPreferences(defaults: defaults)
        XCTAssertEqual(migrated.appearance, .dark)
        migrated.appearance = .light
        migrated.reduceTransparency = true
        migrated.glassOpacity = 0.42
        migrated.hoverPreviews = false
        migrated.pinOnClick = false
        let restored = ObserverPreferences(defaults: defaults)
        XCTAssertEqual(restored.appearance, .light)
        XCTAssertTrue(restored.reduceTransparency)
        XCTAssertEqual(restored.glassOpacity, 0.42, accuracy: 0.0001)
        XCTAssertFalse(restored.hoverPreviews)
        XCTAssertFalse(restored.pinOnClick)
        restored.followSystemAppearance = true
        XCTAssertEqual(restored.appearance, .system)
        restored.glassOpacity = 0
        XCTAssertEqual(restored.glassOpacity, ObserverPreferences.glassOpacityRange.lowerBound, accuracy: 0.0001)
        restored.glassOpacity = 2
        XCTAssertEqual(restored.glassOpacity, ObserverPreferences.glassOpacityRange.upperBound, accuracy: 0.0001)
    }

    @MainActor
    func testReopeningCancelsDelayedShrinkAndNoPreviewWhenDisabled() async throws {
        _ = NSApplication.shared
        let suite = "MacBridge.MorphSpec.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ObserverPreferences(defaults: defaults)
        let controller = FloatingTabController(model: ObserverModel(), preferences: prefs,
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.show(.rail)
        controller.show(.idle)
        XCTAssertEqual(controller.windowLayer, .rail, "Keep canvas while closing silhouette")
        controller.show(.recentTasks)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.closeDuration + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.windowLayer, .recentTasks)
        controller.togglePin()
        XCTAssertFalse(controller.machine.locked)
        prefs.hoverPreviews = false
        controller.preview(.settings, inside: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.layer, .recentTasks)
        controller.show(.idle)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.closeDuration + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.windowLayer, .idle)
    }

    func testInspectorTabsDoNotInventBackendActions() {
        XCTAssertEqual(InspectorTab.allCases.map(\.rawValue), ["Activity", "File", "Diff", "Output"])
    }

    func testHoverRegionExcludesTransparentCornersButKeepsLogoAndPanelCrossing() {
        let size = EdgeLayout.size(for: .recentTasks,
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982), taskCount: 0)
        let canvas = CGRect(origin: .zero, size: size)
        let logoY = canvas.midY - EdgeLayout.railLogoOffset
        let logoX = canvas.maxX - EdgeLayout.logoInset
        let visible = FloatingHitRegion(logoY: logoY, expansion: 1,
            panelSize: EdgeLayout.panelSize(for: .recentTasks, taskCount: 0)).path(in: canvas)
        XCTAssertFalse(visible.contains(CGPoint(x: 1, y: 1)), "Transparent canvas and rounded panel corners are not hover targets")
        XCTAssertTrue(visible.contains(CGPoint(x: logoX, y: logoY)), "The anchored logo remains reachable")
        for x in stride(from: canvas.maxX - MBMetrics.edgeRailWidth - 16, through: logoX, by: 2) {
            XCTAssertTrue(visible.contains(CGPoint(x: x, y: canvas.midY)), "No dead gap crossing from panel to rail at \(x)")
        }
        let closing = FloatingHitRegion(logoY: logoY, expansion: 0, panelSize: .zero).path(in: canvas)
        XCTAssertTrue(closing.contains(CGPoint(x: logoX, y: logoY)))
        XCTAssertFalse(closing.contains(CGPoint(x: logoX, y: canvas.maxY - 20)), "The closed rail does not keep its invisible canvas active")
        XCTAssertFalse(closing.contains(CGPoint(x: 100, y: canvas.midY)), "A removed panel is not a hover target")
        for step in 0...20 {
            let progress = CGFloat(step) / 20
            let region = FloatingHitRegion(logoY: logoY, expansion: progress, panelSize: .zero).path(in: canvas)
            let painted = AnchoredOrganicEdgeShape(expansion: progress)
                .path(in: CGRect(x: canvas.maxX - MBMetrics.edgeRailWidth,
                                 y: canvas.midY - MBMetrics.edgeRailHeight / 2,
                                 width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight))
            var boxes = [CGRect(x: logoX - 16, y: logoY - 19, width: 32, height: 38).intersection(canvas)]
            if progress > 0 {
                boxes += (1...4).map { CGRect(x: logoX - 16, y: logoY + CGFloat($0) * 35 - 16,
                                             width: 32, height: 32).intersection(canvas) }
            }
            // Buttons intentionally include blank space outside the painted
            // curve; no other invisible area should keep the widget open.
            for x in stride(from: CGFloat(0.5), to: canvas.maxX, by: 3) {
                for y in stride(from: CGFloat(0.5), to: canvas.maxY, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    XCTAssertEqual(region.contains(point), painted.contains(point) || boxes.contains { $0.contains(point) },
                                   "Only the silhouette and real button boxes are active at \(progress): \(point)")
                }
            }
        }
    }

    @MainActor
    func testPanelCloseRetainsCanvasAndReopeningCancelsItsShrink() async throws {
        _ = NSApplication.shared
        let suite = "MacBridge.PanelMotion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatingTabController(model: ObserverModel(), preferences: ObserverPreferences(defaults: defaults),
            presentsWindow: false, openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }
        controller.show(.recentTasks)
        controller.closeDeepest()
        XCTAssertEqual(controller.layer, .rail)
        XCTAssertEqual(controller.windowLayer, .recentTasks, "Do not clip the closing panel by shrinking its window immediately")
        controller.show(.settings)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.panelDuration + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.windowLayer, .settings, "A stale close must not shrink the reopened panel")
        controller.show(.taskDetail("selected"))
        controller.show(.recentTasks)
        XCTAssertEqual(controller.windowLayer, .taskDetail("selected"), "Keep outgoing panel bounds during a smaller-panel transition")
        controller.show(.settings)
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.panelDuration + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.windowLayer, .settings, "Latest target owns the eventual canvas after reversal")
        controller.closeDeepest()
        try await Task.sleep(nanoseconds: UInt64((MBMetrics.panelDuration + 0.08) * 1_000_000_000))
        XCTAssertEqual(controller.windowLayer, .rail)
        XCTAssertEqual(controller.pendingTransitionCount, 0)
    }
}
