import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

/// Synthetic snapshots and offscreen native rendering only. Never attach to an
/// owner, show a window, change real preferences, or execute a project command.
final class MonochromeBadgeTests: XCTestCase {
    private func snapshot(running: Int, waiting: Int = 0, stale: Bool = false) -> [String: Any] {
        let rows: [[String: Any]] = (0..<(running + waiting)).map { index in
            ["work_id": "fixture-\(index)", "workspace_id": index == 0 ? "first" : "second",
             "title": "Synthetic task \(index)", "state": "active",
             "phase": index < running ? "executing" : "waiting_next_step",
             "active_call_count": index < running ? 1 : 0, "updated_ms": 1_000,
             "stale": false]
        }
        return ["jobs": [], "history": [], "work_items": rows, "snapshot_stale": stale,
                "workspaces": [["workspace_id": "first", "display_name": "First"],
                               ["workspace_id": "second", "display_name": "Second"]]]
    }

    @MainActor
    private func model(running: Int, waiting: Int = 0, connected: Bool = true,
                       stale: Bool = false) -> ObserverModel {
        let model = ObserverModel()
        model.connected = connected
        model.updateSnapshot(snapshot(running: running, waiting: waiting, stale: stale))
        return model
    }

    @MainActor
    func testWidgetCountDoesNotFollowDashboardWorkspaceFilter() {
        let model = model(running: 2, waiting: 3)
        for workspace in ["all", "first", "second", "missing-workspace"] {
            model.workspace = workspace
            XCTAssertEqual(model.compactSummary.runningBadgeText, "2")
            XCTAssertEqual(model.compactSummary.runningCount, 2)
            XCTAssertEqual(model.compactSummary.waitingCount, 3)
            XCTAssertTrue(model.compactSummary.runningBadgeHelp.contains("3 waiting"))
            XCTAssertEqual(model.workspace, workspace, "Reading the widget must not reset the user's filter")
        }
        model.workspace = "first"
        XCTAssertEqual(model.activityFeed.groups.count, 1)
        XCTAssertEqual(model.allActivityFeed.groups.count, 5)
    }

    @MainActor
    func testZeroIsVisibleAndWaitingIsNotMislabelledAsRunning() {
        let empty = model(running: 0)
        XCTAssertEqual(empty.compactSummary.runningBadgeText, "0")
        XCTAssertEqual(empty.compactSummary.runningBadgeHelp, "0 tasks running across all workspaces")
        let waiting = model(running: 0, waiting: 2)
        XCTAssertEqual(waiting.compactSummary.runningBadgeText, "0")
        XCTAssertEqual(waiting.compactSummary.statusText, "2 waiting")
        XCTAssertTrue(waiting.compactSummary.runningBadgeHelp.contains("2 waiting"))
        XCTAssertEqual(model(running: 100).compactSummary.runningBadgeText, "99+")
    }

    @MainActor
    func testUnavailableOrBusySnapshotNeverPretendsToBeZero() {
        let model = model(running: 2)
        model.connected = false
        XCTAssertEqual(model.compactSummary.runningBadgeText, "–")
        XCTAssertTrue(model.compactSummary.runningBadgeHelp.contains("unavailable"))
        model.connected = true
        model.updateSnapshot(snapshot(running: 2, stale: true))
        XCTAssertEqual(model.compactSummary.runningBadgeText, "–")
        model.updateSnapshot(snapshot(running: 2))
        model.busy = true
        XCTAssertEqual(model.compactSummary.runningBadgeText, "–")
        model.busy = false
        XCTAssertEqual(model.compactSummary.runningBadgeText, "2")
        model.updateSnapshot([:])
        XCTAssertEqual(model.compactSummary.runningBadgeText, "–", "No jobs snapshot is not proof of no jobs")
    }

    @MainActor
    func testOpeningGlobalTaskOnlyClearsFilterWhenRequired() {
        let model = model(running: 2)
        model.workspace = "first"
        model.selectGlobalActivity("work:fixture-0")
        XCTAssertEqual(model.workspace, "first")
        XCTAssertEqual(model.selectedWork?.workID, "fixture-0")
        model.selectGlobalActivity("work:fixture-1")
        XCTAssertEqual(model.workspace, "all")
        XCTAssertEqual(model.selectedWork?.workID, "fixture-1")
    }

    @MainActor
    func testMonochromeMarkIsCachedTemplateWithTransparentCorners() throws {
        _ = NSApplication.shared
        for size: CGFloat in [18, 22, 28] {
            let image = MacBridgeMarkRenderer.image(size: size, style: .monochrome)
            XCTAssertTrue(image.isTemplate)
            for _ in 0..<100 {
                XCTAssertTrue(image === MacBridgeMarkRenderer.image(size: size, style: .monochrome))
            }
            XCTAssertFalse(image === MacBridgeMarkRenderer.image(size: size, style: .appIcon))
            let pixels = 96
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            var painted = 0
            var maximumChannelSpread: CGFloat = 0
            for x in 0..<pixels {
                for y in 0..<pixels {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.05 {
                        painted += 1
                        maximumChannelSpread = max(maximumChannelSpread,
                            abs(color.redComponent - color.greenComponent), abs(color.greenComponent - color.blueComponent))
                    }
                }
            }
            XCTAssertGreaterThan(painted, 500)
            XCTAssertLessThan(maximumChannelSpread, 0.005)
            XCTAssertLessThan(painted, pixels * pixels / 2, "The mark must not regain an opaque tile")
            for point in [(0, 0), (95, 0), (0, 95), (95, 95)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)).alphaComponent, 0.01)
            }
        }
    }

    @MainActor
    func testBadgeGeometryStaysInsideNarrowIdleAndExpandedCanvases() throws {
        _ = NSApplication.shared
        for count in [0, 1, 99, 100] {
            let summary = model(running: count).compactSummary
            for shown in [true, false] {
                let host = NSHostingView(rootView: CompactBrandBadge(summary: summary, showCount: shown))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, MBMetrics.edgeTargetSize, accuracy: 0.1)
                XCTAssertEqual(host.fittingSize.height, MBMetrics.edgeBrandHeight, accuracy: 0.1)
                XCTAssertLessThan(host.fittingSize.width, MBMetrics.edgeIdleWidth)
                XCTAssertLessThan(host.fittingSize.height, MBMetrics.edgeIdleHeight)
            }
        }
        XCTAssertLessThanOrEqual(MBMetrics.edgeLogoSize, 22)
        XCTAssertEqual(MBMetrics.edgeIdleWidth, 30, "Count must not widen the user's compact widget")
    }

    @MainActor
    func testVisibleBrandAndCountStayInsideGlassThroughoutMorph() throws {
        let summary = model(running: 100).compactSummary
        let renderer = ImageRenderer(content: CompactBrandBadge(summary: summary, showCount: true)
            .environment(\.colorScheme, .dark))
        renderer.scale = 3
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let canvas = CGRect(x: 0, y: 0, width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight)
        let origin = CGPoint(x: canvas.maxX - EdgeLayout.logoInset - MBMetrics.edgeTargetSize / 2,
                             y: canvas.midY - EdgeLayout.railLogoOffset - MBMetrics.edgeBrandHeight / 2)
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let silhouette = AnchoredOrganicEdgeShape(expansion: progress).path(in: canvas)
            var outside = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                    guard color.alphaComponent > 0.04 else { continue }
                    let point = CGPoint(x: origin.x + (CGFloat(x) + 0.5) / 3,
                                        y: origin.y + (CGFloat(y) + 0.5) / 3)
                    if !silhouette.contains(point) { outside += 1 }
                }
            }
            XCTAssertEqual(outside, 0, "Visible logo/count must not cross the glass shoulder at \(progress)")
        }
    }

    @MainActor
    func testActualBrandAndCountRenderInBothAppearancesWithoutBlueTile() throws {
        _ = NSApplication.shared
        let cases: [(String, CompactSummary)] = [
            ("0", model(running: 0).compactSummary), ("1", model(running: 1).compactSummary),
            ("2", model(running: 2).compactSummary), ("99", model(running: 99).compactSummary),
            ("99plus", model(running: 100).compactSummary),
            ("unavailable", model(running: 2, connected: false).compactSummary)
        ]
        for scheme: ColorScheme in [.light, .dark] {
            for (name, summary) in cases {
                let view = CompactBrandBadge(summary: summary, showCount: true)
                    .padding(6).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                renderer.isOpaque = false
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                var painted = 0
                var maximumChannelSpread: CGFloat = 0
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh {
                        let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if c.alphaComponent > 0.25 {
                            painted += 1
                            maximumChannelSpread = max(maximumChannelSpread,
                                abs(c.redComponent - c.greenComponent), abs(c.greenComponent - c.blueComponent))
                        }
                    }
                }
                XCTAssertGreaterThan(painted, 100, "A nonempty native render is required")
                XCTAssertLessThan(maximumChannelSpread, 0.03)
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
                if let directory = ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_DIR"] {
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("brand-\(scheme == .dark ? "dark" : "light")-\(name).png"),
                        options: .atomic)
                }
            }
        }
        if let directory = ProcessInfo.processInfo.environment["MB_OBSERVER_RENDER_DIR"] {
            let preview = VStack(spacing: 0) {
                ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                    HStack(spacing: 18) {
                        ForEach(Array(cases.enumerated()), id: \.offset) { _, entry in
                            VStack(spacing: 8) {
                                CompactBrandBadge(summary: entry.1, showCount: true)
                                Text(entry.0).font(.system(size: 10))
                            }.frame(width: 58, height: 78)
                        }
                    }.padding(16).environment(\.colorScheme, scheme)
                        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.94))
                }
            }
            let renderer = ImageRenderer(content: preview)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("widget-monochrome-proof.png"),
                          options: .atomic)
        }
    }
}
