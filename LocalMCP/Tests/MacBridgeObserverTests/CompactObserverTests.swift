import AppKit
import SwiftUI
import XCTest
@testable import MacBridgeObserver

final class CompactObserverTests: XCTestCase {
    private func previewResponse() -> [String: Any] {
        ["instance_id": "owner", "event_id": "read", "workspace_id": "workspace", "path": "/fixtures/sample.swift",
         "version": "stat-v1", "total_bytes": 12, "truncated": false, "preview_limit_bytes": 16384,
         "unchanged": false, "text": "let x = 42\n"]
    }

    func testExplicitFileActionSupersedesAutomaticReadWithoutDroppingClick() throws {
        var gate = FilePreviewRequestGate()
        let automatic = try XCTUnwrap(gate.beginRead())
        XCTAssertNil(gate.beginRead(), "Automatic reads remain single-flight")
        let action = try XCTUnwrap(gate.beginAction(), "An automatic read must not discard an explicit click")
        XCTAssertNil(gate.beginAction(), "A second click must not duplicate the OS action")
        let explicit = try XCTUnwrap(gate.beginRead(forAction: action))
        XCTAssertNotEqual(explicit, automatic)
        XCTAssertFalse(gate.finishRead(automatic), "The older read cannot complete the replacement request")
        XCTAssertTrue(gate.reading)
        XCTAssertEqual(gate.requestID, explicit)
        XCTAssertNil(gate.beginRead(), "Polling cannot supersede the explicit revalidation")
        XCTAssertTrue(gate.finishRead(explicit))
        XCTAssertFalse(gate.reading)
        XCTAssertNil(gate.beginRead(), "The action remains exclusive until Open/Reveal returns")
        XCTAssertNil(gate.beginAction())
        XCTAssertTrue(gate.finishAction(action))
        XCTAssertNotNil(gate.beginRead())
    }

    func testPreviewSelectionResetInvalidatesReadButDoesNotReleaseAnotherAction() throws {
        var gate = FilePreviewRequestGate()
        let action = try XCTUnwrap(gate.beginAction())
        let read = try XCTUnwrap(gate.beginRead(forAction: action))
        gate.invalidateRead()
        XCTAssertNotEqual(gate.requestID, read)
        XCTAssertFalse(gate.finishRead(read))
        XCTAssertFalse(gate.finishAction(UUID()))
        XCTAssertEqual(gate.actionID, action)
        XCTAssertNil(gate.beginRead(forAction: UUID()))
        XCTAssertTrue(gate.finishAction(action))
        XCTAssertNil(gate.beginRead(forAction: action), "An expired action cannot authorize a replacement read")
        XCTAssertNotNil(gate.beginAction())
    }

    func testPreviewRequiresConfirmedIdentityAndBoundedCanonicalPath() throws {
        let raw = previewResponse()
        let preview = try XCTUnwrap(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: nil))
        XCTAssertEqual(preview.text, "let x = 42\n")
        XCTAssertTrue(preview.matchesSelection(owner: "owner", eventID: "read", connected: true, stale: false))
        XCTAssertFalse(preview.matchesSelection(owner: "other", eventID: "read", connected: true, stale: false))
        XCTAssertFalse(preview.matchesSelection(owner: "owner", eventID: "other", connected: true, stale: false))
        XCTAssertFalse(preview.matchesSelection(owner: "owner", eventID: "read", connected: false, stale: false))
        XCTAssertFalse(preview.matchesSelection(owner: "owner", eventID: "read", connected: true, stale: true))
        for invalid in ["relative/file", "https://example.test/file", "file:///fixtures/sample.swift", "/",
                        "/fixtures/../sample.swift", "/fixtures/./sample.swift", "/fixtures//sample.swift",
                        "//fixtures/sample.swift", "/fixtures/sample.swift/", "/fixtures/file\n", "/fixtures/file\u{0000}"] {
            var candidate = raw; candidate["path"] = invalid
            XCTAssertNil(SelectedFilePreview(candidate, expectedOwner: "owner", expectedEvent: "read", previous: nil))
        }
        var oversized = raw; oversized["text"] = String(repeating: "x", count: 20000)
        XCTAssertNil(SelectedFilePreview(oversized, expectedOwner: "owner", expectedEvent: "read", previous: nil))
        XCTAssertNil(SelectedFilePreview(raw, expectedOwner: "other", expectedEvent: "read", previous: nil))
    }

    func testPreviewKeepsOwnerConfirmedPrivateTemporaryPathWithoutAliasNormalization() throws {
        for path in ["/private/tmp/mb-normal-work-vKxV7E/sum.py", "/private/var/folders/fixture/sample.swift"] {
            var raw = previewResponse(); raw["path"] = path
            let preview = try XCTUnwrap(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: nil))
            XCTAssertEqual(preview.path, path)
            XCTAssertEqual(preview.url.path, path)
            raw["unchanged"] = true; raw.removeValue(forKey: "text")
            let unchanged = try XCTUnwrap(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: preview))
            XCTAssertEqual(unchanged.path, path)
            XCTAssertEqual(unchanged.text, preview.text)
        }
    }

    func testUnchangedPreviewReusesOnlySameSelectionAndStatVersion() throws {
        var raw = previewResponse()
        let previous = try XCTUnwrap(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: nil))
        raw["unchanged"] = true; raw.removeValue(forKey: "text")
        let next = try XCTUnwrap(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: previous))
        XCTAssertEqual(next.text, previous.text)
        XCTAssertNil(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: nil))
        raw["version"] = "stat-v2"
        XCTAssertNil(SelectedFilePreview(raw, expectedOwner: "owner", expectedEvent: "read", previous: previous))
    }

    @MainActor
    func testSelectionClearsPreviewAndOnlyReturnedSingleFileReceiptsAreEligible() throws {
        let model = ObserverModel()
        model.updateSnapshot(["observer_file_preview": true, "jobs": [], "history": [
            ["id": "read", "tool": "file_read", "state": "returned", "path": "sample.swift"],
            ["id": "shell", "tool": "command_run", "state": "returned"],
            ["id": "pending", "tool": "file_patch", "state": "running", "path": "sample.swift"],
        ]])
        model.selection = "event:read"
        XCTAssertEqual(model.selectedPreviewEventID, "read")
        model.selectedFilePreview = try XCTUnwrap(SelectedFilePreview(previewResponse(), expectedOwner: "owner", expectedEvent: "read", previous: nil))
        model.selection = "event:shell"
        XCTAssertNil(model.selectedFilePreview)
        XCTAssertNil(model.selectedPreviewEventID)
        XCTAssertFalse(model.canOpenPreview)
        model.selection = "event:pending"
        XCTAssertNil(model.selectedPreviewEventID)
    }

    @MainActor
    func testTwoLineRowsRemainCompactWithLongTextAt125Percent() throws {
        _ = NSApplication.shared
        let long = String(repeating: "A very long task and command ", count: 30)
        let parent = WorkActivity(raw: ["work_id": "w", "title": long, "chat_label": long, "state": "active",
                                       "phase": "waiting_next_step", "call_count": 65, "error_count": 2],
                                  children: [], workspaceName: long, connected: true, snapshotStale: false)
        let feed = ActivityFeed(history: [["id": "e", "tool": "command_run", "state": "returned", "cwd": "/fixtures/" + long,
                                          "detail": ["command_preview": long], "result": ["exit_code": 0]]], jobs: [],
                                workspaces: [], workspace: "all", connected: true, stale: false)
        let contextFeed = ActivityFeed(history: [["id": "context", "tool": "command_run", "state": "returned",
            "cwd": "/fixtures/Projects/" + String(repeating: "Long project name ", count: 10),
            "detail": ["command_preview": long]]], jobs: [], workspaces: [], workspace: "all", connected: true, stale: false)
        let contents = [CompactRowContent(work: parent), CompactRowContent(item: try XCTUnwrap(feed.items.first)),
                        CompactRowContent(unavailableItemID: "event:expired"),
                        CompactRowContent(context: try XCTUnwrap(contextFeed.contextGroups.first))]
        XCTAssertEqual(CompactRowContent.maximumVisualLines, 2)
        for content in contents {
            XCTAssertFalse(content.title.contains("\n"))
            XCTAssertFalse(content.subtitle.contains("\n"))
            let host = NSHostingView(rootView: CompactActivityRow(content: content)
                .environment(\.observerTextScale, 1.25).frame(width: 300))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 25)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 60, "Long metadata must not create extra text rows")
        }
        XCTAssertTrue(contents[0].help.contains("65 calls · 2 errors"))
        XCTAssertFalse(contents[0].subtitle.contains("65 calls"))
    }

    @MainActor
    func testReadOnlyPreviewRendersBoundedText() throws {
        _ = NSApplication.shared
        let preview = try XCTUnwrap(SelectedFilePreview(previewResponse(), expectedOwner: "owner", expectedEvent: "read", previous: nil))
        let host = NSHostingView(rootView: SelectedFilePreviewView(preview: preview, message: "", loading: false)
            .environment(\.observerTextScale, 1.25).frame(width: 400))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 50)
        XCTAssertLessThan(host.fittingSize.height, 300)
    }
}
