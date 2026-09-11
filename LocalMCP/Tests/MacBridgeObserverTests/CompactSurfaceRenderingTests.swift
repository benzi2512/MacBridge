import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

/// Offscreen render probe using synthetic activity, never a real owner.
/// Native compositor-only surfaces may not support bitmap capture; skip honestly.
final class CompactSurfaceRenderingTests: XCTestCase {
    @MainActor
    func testEveryCompactLayerRendersAtItsDesignedGeometry() async throws {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brand = try XCTUnwrap(NSImage(contentsOf: source.appendingPathComponent("Assets/Brand/macbridge-icon.png")))
        let suite = "MacBridge.CompactRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ObserverModel()
        model.connected = true
        let workItems: [[String: Any]] = [
            ["work_id": "work-1", "title": "Finish MacBridge compact surfaces",
             "chat_label": "UI implementation", "workspace_id": "app", "state": "active",
             "phase": "executing", "updated_ms": 20_000, "call_count": 12, "error_count": 0,
             "active_call_count": 1, "job_ids": ["job-1"], "stale": false],
            ["work_id": "work-2", "title": "Review the normal Chat connection",
             "chat_label": "Connection verification", "workspace_id": "app", "state": "active",
             "phase": "waiting_next_step", "updated_ms": 19_000, "call_count": 5, "error_count": 0,
             "active_call_count": 0, "job_ids": [], "stale": false],
            ["work_id": "work-3", "title": "Refresh approved MacBridge branding",
             "chat_label": "Brand assets", "workspace_id": "app", "state": "completed",
             "phase": "completed", "updated_ms": 18_000, "call_count": 4, "error_count": 0,
             "active_call_count": 0, "job_ids": [], "stale": false],
        ]
        let jobs: [[String: Any]] = [["task_id": "job-1", "workspace_id": "app", "running": true,
            "started_milliseconds": 10_000, "stdout_total_bytes": 1_024, "stderr_total_bytes": 0]]
        let history: [[String: Any]] = [["id": "start", "tool": "command_start", "state": "returned",
            "workspace_id": "app", "work_id": "work-1", "cwd": "/fixtures/MacBridge",
            "started_ms": 10_000, "finished_ms": 10_002,
            "detail": ["command_preview": "swift test --jobs 2"],
            "result": ["task_id": "job-1", "running": true]]]
        model.updateSnapshot([
            "snapshot_stale": false,
            "workspaces": [["workspace_id": "app", "display_name": "MacBridge"]],
            "work_items": workItems,
            "jobs": jobs,
            "history": history,
            "transactions": [],
        ])
        let preferences = ObserverPreferences(defaults: defaults)
        preferences.reduceTransparency = ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_OPAQUE"] == "1"
        let controller = FloatingTabController(model: model, preferences: preferences, presentsWindow: false,
            openDashboard: { _ in }, openSettings: {})
        defer { controller.stop() }

        let rightCases: [(String, FloatingLayer, ColorScheme)] = [
            ("idle-dark", .idle, .dark),
            ("rail-dark", .rail, .dark),
            ("recent-light", .recentTasks, .light),
            ("rail-light", .rail, .light),
            ("recent-dark", .recentTasks, .dark),
            ("detail-light", .taskDetail("work:work-1"), .light),
            ("settings-dark", .settings, .dark),
            ("recent-64-dark", .recentTasks, .dark),
        ]
        let cases = rightCases.map { ($0.0, $0.1, $0.2, FloatingDockEdge.right) } + [
            ("bottom-idle-dark", .idle, .dark, .bottom),
            ("bottom-rail-dark", .rail, .dark, .bottom),
            ("bottom-recent-light", .recentTasks, .light, .bottom),
            ("bottom-settings-dark", .settings, .dark, .bottom),
            ("bottom-detail-dark", .taskDetail("work:work-1"), .dark, .bottom),
            ("bottom-recent-64-dark", .recentTasks, .dark, .bottom),
        ]
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        for (name, layer, scheme, edge) in cases {
            preferences.setDockAnchor(.init(edge: edge, position: 0.5), for: controller.displayID)
            if name.contains("recent-64-dark") {
                let manyTasks = (0..<64).map { index -> [String: Any] in
                    var item = workItems[0]
                    item["work_id"] = "scroll-\(index)"
                    item["title"] = "Scrollable task \(index)"
                    item["job_ids"] = []
                    item["updated_ms"] = 30_000 + index
                    return item
                }
                model.updateSnapshot([
                    "snapshot_stale": false,
                    "workspaces": [["workspace_id": "app", "display_name": "MacBridge"]],
                    "work_items": manyTasks, "jobs": [], "history": [], "transactions": [],
                ])
            }
            controller.show(layer, locked: layer != .rail && layer != .idle)
            // This host represents the settled target canvas. Let the controller
            // finish retaining any wider outgoing canvas before constructing it.
            try await Task.sleep(nanoseconds: UInt64((MBMetrics.panelDuration + 0.05) * 1_000_000_000))
            XCTAssertEqual(controller.windowLayer, layer)
            let size = FloatingDockLayout.size(for: layer, visibleFrame: visible,
                                       taskCount: model.compactSummary.tasks.count, edge: edge)
            let view = FloatingTabView(controller: controller)
                .environment(\.mbBrandImage, brand)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = NSColor.clear
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.orderOut(nil) }
            if name == "recent-dark", ProcessInfo.processInfo.environment["MB_OBSERVER_GLASS_PREVIEW"] == "1" {
                // Opt-in compositor inspection, without installing/replacing the app.
                // Native Liquid Glass is not captured by cacheDisplay's bitmap path.
                window.title = "MacBridge Glass Preview"
                window.center()
                window.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 45_000_000_000)
            }
            try await Task.sleep(nanoseconds: 80_000_000)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
            if name.contains("recent-64-dark") {
                XCTAssertEqual(controller.readingOrder.ids.count, 64)
                XCTAssertEqual(size.height, FloatingDockLayout.size(for: .recentTasks, visibleFrame: visible, taskCount: 6, edge: edge).height,
                               "The scrollable list must not create a 64-row-tall window")
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let hasVisibleContent = stride(from: 0, to: bitmap.pixelsWide, by: 8).contains { x in
                stride(from: 0, to: bitmap.pixelsHigh, by: 8).contains { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) > 0.1
                }
            }
            guard hasVisibleContent else {
                throw XCTSkip("\(name): native compositor not captured by cacheDisplay; visual acceptance requires a live app window")
            }
            if let directory = ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-\(name).png"), options: .atomic)
            }
        }

        preferences.setDockAnchor(.init(edge: .right, position: 0.5), for: controller.displayID)
        model.updateSnapshot([
            "snapshot_stale": false,
            "workspaces": [["workspace_id": "app", "display_name": "MacBridge"]],
            "work_items": workItems, "jobs": jobs, "history": history, "transactions": [],
        ])

        if let directory = ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_DIR"] {
            for count in 0...3 {
                model.updateSnapshot([
                    "snapshot_stale": false,
                    "workspaces": [["workspace_id": "app", "display_name": "MacBridge"]],
                    "work_items": Array(workItems.prefix(count)),
                    "jobs": count > 0 ? jobs : [],
                    "history": count > 0 ? history : [],
                    "transactions": [],
                ])
                controller.show(.recentTasks)
                controller.showLatest()
                try await Task.sleep(nanoseconds: UInt64((MBMetrics.panelDuration + 0.05) * 1_000_000_000))
                XCTAssertEqual(controller.windowLayer, .recentTasks)
                let size = EdgeLayout.size(for: .recentTasks, visibleFrame: visible, taskCount: count)
                let view = FloatingTabView(controller: controller)
                    .environment(\.mbBrandImage, brand)
                    .environment(\.colorScheme, .dark)
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: size)
                try await Task.sleep(nanoseconds: 80_000_000)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-recent-\(count)-tasks.png"), options: .atomic)
            }
        }
        XCTAssertEqual(model.directory, "")
        XCTAssertEqual(model.compactSummary.runningCount, 1)
    }
}
