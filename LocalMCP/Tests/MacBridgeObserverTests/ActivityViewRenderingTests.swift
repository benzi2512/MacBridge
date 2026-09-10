import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

// Offscreen native rendering, synthetic data. No attachment to a real owner and
// no screen capture permission. Optional PNGs go only to the explicit test path.
final class ActivityViewRenderingTests: XCTestCase {
    @MainActor
    func testAllAndRunningRenderWithoutStartingAnOwner() throws {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brand = try XCTUnwrap(NSImage(contentsOf: source.appendingPathComponent("Assets/Brand/macbridge-icon.png")))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let model = ObserverModel()
        model.connected = true
        model.notice = "UI TEST FIXTURE · synthetic activity, not a live chat"
        model.updateSnapshot([
            "instance_id": "fixture-owner", "build_id": "observer-ui-test", "snapshot_stale": false,
            "workspaces": [["workspace_id": "app", "display_name": "MacBridge"]],
            "work_items": [["work_id": "fixture-work", "title": "Repair plugin, validate its generated configuration, and verify the full production build without losing other chat activity",
                            "chat_label": "Plugin check", "workspace_id": "app", "state": "active", "phase": "executing",
                            "started_ms": now - 70000, "updated_ms": now, "call_count": 18, "error_count": 0,
                            "job_ids": ["fixture-job"], "active_call_count": 0, "stale": false]],
            "jobs": [["task_id": "fixture-job", "running": true, "started_milliseconds": now - 65000,
                      "stdout_total_bytes": 4096, "stderr_total_bytes": 0]],
            "history": [
                ["id": "context-a", "tool": "file_read", "state": "returned", "workspace_id": "app",
                 "path": "/fixtures/Projects/Orchid/receipts/latest.json", "started_ms": now - 5000, "finished_ms": now - 4998],
                ["id": "context-b", "tool": "command_run", "state": "returned", "workspace_id": "app",
                 "cwd": "/fixtures/Projects/Birch/automation", "detail": ["command_preview": "swift test --jobs 2"],
                 "started_ms": now - 6000, "finished_ms": now - 5900, "result": ["exit_code": 0]],
                ["id": "read", "tool": "file_read", "state": "returned", "workspace_id": "app",
                 "path": "Sources/ObserverApp.swift", "started_ms": now - 70000, "finished_ms": now - 69998],
                ["id": "start", "tool": "command_start", "state": "returned", "workspace_id": "app",
                 "work_id": "fixture-work", "detail": ["command_preview": "swift test --filter Observer --scratch-path /fixtures/very-long-project-location/build/isolated-preview-and-production-validation"],
                 "cwd": "/fixtures/MacBridge/LocalMCP", "started_ms": now - 65000, "finished_ms": now - 64990,
                 "result": ["task_id": "fixture-job", "running": true]],
                ["id": "git", "tool": "git_status", "state": "returned", "workspace_id": "app",
                 "work_id": "fixture-work",
                 "cwd": "/fixtures/MacBridge", "started_ms": now - 30000, "finished_ms": now - 29930,
                 "result": ["exit_code": 0]],
            ], "transactions": [],
        ])
        model.selection = "work:fixture-work"
        defer { model.stopPolling() }
        for filter in [ActivityPresentation.Filter.all, .running] {
          for scheme in [ColorScheme.light, .dark] {
          for (width, details, sidebar) in [(680, false, false), (680, true, false), (1320, true, true)] {
            let view = ObserverView(model: model, initialFilter: filter, showsDetails: details,
                                    initialTextScale: 1.25, showsSidebar: sidebar)
                .environment(\.colorScheme, scheme)
                .environment(\.mbBrandImage, brand)
                .environment(\.mbReduceTransparency, ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_OPAQUE"] == "1")
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 850)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            defer { window.orderOut(nil) }
            // SwiftUI/AppKit list rows settle on the next main run-loop cycle.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, width)
            XCTAssertEqual(model.directory, "")
            XCTAssertEqual(model.activityFeed.runningCount, 1)
            XCTAssertEqual(model.activityFeed.matchingGroups(filter: .running).count, 1)
            XCTAssertEqual(model.activityFeed.matchingContexts(filter: filter).count, 2)
            XCTAssertNil(model.selectedJob)
            if let directory = ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_DIR"] {
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("observer-\(scheme == .dark ? "dark" : "light")-\(filter.rawValue.lowercased())-\(width)-\(details ? "details" : "activity").png"), options: .atomic)
            }
          }
          }
        }
    }
}
