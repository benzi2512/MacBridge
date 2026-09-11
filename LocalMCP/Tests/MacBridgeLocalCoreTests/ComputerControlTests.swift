import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ComputerControlTests: XCTestCase {
    private final class Fake: ComputerBackend {
        var trusted = true
        var app = ComputerApplication(bundleID: "com.example.Editor", pid: 123, launchStamp: 1, frontmost: true)
        var actionCalls = 0
        var reads = 0
        var failAction = false
        var failSnapshot = false
        var lastText: String?
        var frame = ComputerFrame(nodes: [
            ComputerNode(id: 0, role: "AXButton", title: "Save", value: nil, actions: ["press"], secure: false, handle: nil),
            ComputerNode(id: 1, role: "AXTextField", title: "Title", value: nil, actions: ["set_value"], secure: false, handle: nil),
            ComputerNode(id: 2, role: "AXTextField", title: "Password", value: "DO_NOT_RETURN", actions: ["set_value"], secure: true, handle: nil),
        ], partial: false)
        func application(bundleID: String) throws -> ComputerApplication { app }
        func snapshot(application: ComputerApplication) throws -> ComputerFrame {
            reads += 1
            if failSnapshot { throw LocalMCPError.operationFailed("fixture") }
            return frame
        }
        func perform(action: String, application: ComputerApplication, node: ComputerNode?, text: String?) throws {
            actionCalls += 1; lastText = text
            if failAction { throw LocalMCPError.operationFailed("fixture timeout") }
        }
    }
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private func service(_ f: Fixture, actions: [String] = LocalComputerGrant.supportedActions,
                         expiry: Date? = nil, enabled: Bool = true) throws -> LocalWorkspaceService {
        let grant = LocalComputerGrant(bundleID: "com.example.Editor", actions: actions,
            expiresAt: ISO8601DateFormatter().string(from: expiry ?? clock.addingTimeInterval(300)))
        return LocalWorkspaceService(registry: try LocalWorkspaceRegistry(configuration:
            LocalWorkspaceConfiguration(workspaces: [.init(id: f.workspaceID, name: "fixture", path: f.workspace.path,
                computerGrants: enabled ? [grant] : [])])))
    }
    private func args(_ f: Fixture, _ action: String = "snapshot") -> JSONObject {
        ["workspace_id": f.workspaceID, "bundle_id": "com.example.Editor", "action": action]
    }
    private func mutation(_ f: Fixture, _ snapshot: JSONObject, action: String = "press", element: Int = 0) -> JSONObject {
        args(f, action).merging(["snapshot_id": snapshot["snapshot_id"]!, "element_id": element]) { _, rhs in rhs }
    }

    func testOptInAndPermissionAreSeparateAndNeverPrompted() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), control = ComputerControl(backend: Fake(), now: { self.clock })
        XCTAssertThrowsError(try control.execute(args(f), workspace: service(f, enabled: false)))
        fake.trusted = false
        let noPermission = ComputerControl(backend: fake, now: { self.clock })
        let r = try noPermission.execute(args(f), workspace: service(f))
        XCTAssertEqual(r["status"] as? String, "permission_required")
        XCTAssertEqual(r["permission_prompted"] as? Bool, false)
        XCTAssertEqual(fake.reads, 0); XCTAssertEqual(fake.actionCalls, 0)
    }

    func testExpiredOrOverlongGrantAndProtectedAppAreRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), c = ComputerControl(backend: Fake(), now: { self.clock })
        for date in [clock, clock.addingTimeInterval(-1), clock.addingTimeInterval(3601)] {
            XCTAssertThrowsError(try c.execute(args(f), workspace: service(f, expiry: date)))
        }
        for bundle in LocalComputerGrant.blockedBundles {
            XCTAssertThrowsError(try LocalComputerGrant(bundleID: bundle, actions: ["snapshot"],
                expiresAt: ISO8601DateFormatter().string(from: clock.addingTimeInterval(100))).validateShape())
        }
        XCTAssertEqual(fake.actionCalls, 0)
    }

    func testSnapshotOmitsSecureValuesAndStatusDoesNotReadUI() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let s = try c.execute(args(f, "status"), workspace: w)
        XCTAssertEqual(s["status"] as? String, "permission_present"); XCTAssertEqual(fake.reads, 0)
        let r = try c.execute(args(f), workspace: w)
        XCTAssertFalse(String(describing: r).contains("DO_NOT_RETURN"))
        XCTAssertEqual((r["nodes"] as? [JSONObject])?.count, 2)
        XCTAssertEqual(r["screenshots_captured"] as? Bool, false)
        XCTAssertEqual(fake.actionCalls, 0)
    }

    func testSnapshotPreservesWindowHierarchyForAmbiguousButtonLabels() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        fake.frame = ComputerFrame(nodes: [
            .init(id: 0, role: "AXWindow", title: "Fixture document", value: nil, actions: [], secure: false, handle: nil),
            .init(id: 1, role: "AXButton", title: "Save", value: nil, actions: ["press"], secure: false, handle: nil, parentID: 0),
            .init(id: 2, role: "AXWindow", title: "Other window", value: nil, actions: [], secure: false, handle: nil),
            .init(id: 3, role: "AXButton", title: "Save", value: nil, actions: ["press"], secure: false, handle: nil, parentID: 2),
        ], partial: false)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let nodes = try XCTUnwrap(try c.execute(args(f), workspace: w)["nodes"] as? [JSONObject])
        XCTAssertEqual(nodes[1]["parent_id"] as? Int, 0)
        XCTAssertEqual(nodes[3]["parent_id"] as? Int, 2)
        XCTAssertNil(nodes[0]["parent_id"])
    }

    func testActionReturnsFreshSnapshotInSameCallAndOldReferenceIsConsumed() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let first = try c.execute(args(f), workspace: w)
        let request = mutation(f, first)
        let result = try c.execute(request, workspace: w)
        XCTAssertEqual(fake.actionCalls, 1); XCTAssertEqual(fake.reads, 2)
        XCTAssertNotEqual(result["snapshot_id"] as? String, first["snapshot_id"] as? String)
        XCTAssertThrowsError(try c.execute(request, workspace: w))
        XCTAssertEqual(fake.actionCalls, 1)
    }

    func testSetValuePreservesUnicodeAndNeverUsesClipboard() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let first = try c.execute(args(f), workspace: w)
        var request = mutation(f, first, action: "set_value", element: 1)
        request["text"] = "Xin chào 🦋"
        _ = try c.execute(request, workspace: w)
        XCTAssertEqual(fake.lastText, "Xin chào 🦋")
    }

    func testFocusChangePIDReuseExpiryAndUnknownElementStopBeforeMutation() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        var date = clock
        let c = ComputerControl(backend: fake, now: { date })
        let first = try c.execute(args(f), workspace: w)
        let request = mutation(f, first)
        fake.app = ComputerApplication(bundleID: "com.example.Editor", pid: 123, launchStamp: 1, frontmost: false)
        XCTAssertThrowsError(try c.execute(request, workspace: w))
        fake.app = ComputerApplication(bundleID: "com.example.Editor", pid: 123, launchStamp: 2, frontmost: true)
        XCTAssertThrowsError(try c.execute(request, workspace: w))
        fake.app = ComputerApplication(bundleID: "com.example.Editor", pid: 123, launchStamp: 1, frontmost: true)
        date = clock.addingTimeInterval(16)
        XCTAssertThrowsError(try c.execute(request, workspace: w))
        date = clock
        XCTAssertThrowsError(try c.execute(mutation(f, first, element: 127), workspace: w))
        XCTAssertThrowsError(try c.execute(mutation(f, first, action: "set_value", element: 2).merging(["text": "x"]) { _, b in b }, workspace: w))
        XCTAssertEqual(fake.actionCalls, 0)
    }

    func testUnknownActionCannotWidenReadOnlyGrant() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f, actions: ["snapshot"])
        let c = ComputerControl(backend: fake, now: { self.clock })
        let first = try c.execute(args(f), workspace: w)
        XCTAssertThrowsError(try c.execute(mutation(f, first), workspace: w))
        for action in ["screenshot", "key", "shell", "click", "grant", "enable"] {
            XCTAssertThrowsError(try c.execute(args(f, action), workspace: w))
        }
        XCTAssertEqual(fake.actionCalls, 0)
    }

    func testMutationGrantMustExplicitlyPermitItsSnapshotReadback() throws {
        let f = try Fixture(); defer { f.remove() }
        for actions in [["focus"], ["press"], ["set_value"]] {
            XCTAssertThrowsError(try service(f, actions: actions))
        }
    }

    func testTimeoutHasUnknownOutcomeAndCannotBeAutomaticallyReplayed() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let first = try c.execute(args(f), workspace: w)
        fake.failAction = true
        let request = mutation(f, first)
        let r = try c.execute(request, workspace: w)
        XCTAssertEqual(r["status"] as? String, "outcome_unknown")
        XCTAssertEqual(r["retry_safe"] as? Bool, false)
        XCTAssertEqual(fake.actionCalls, 1)
        XCTAssertThrowsError(try c.execute(request, workspace: w))
        XCTAssertEqual(fake.actionCalls, 1)
    }

    func testAcceptedActionWithFailedReadbackIsNotReportedAsUnperformed() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let first = try c.execute(args(f), workspace: w)
        fake.failSnapshot = true
        let r = try c.execute(mutation(f, first), workspace: w)
        XCTAssertEqual(r["status"] as? String, "action_accepted_snapshot_unavailable")
        XCTAssertEqual(r["action_performed"] as? Bool, true)
        XCTAssertEqual(r["retry_safe"] as? Bool, false)
    }

    func testFrameAndOutputAreBounded() throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = Fake(), w = try service(f)
        fake.frame = ComputerFrame(nodes: (0..<500).map { ComputerNode(id: $0, role: "AXButton",
            title: String(repeating: "x", count: 1000), value: String(repeating: "y", count: 1000),
            actions: ["press"], secure: false, handle: nil) }, partial: false)
        let c = ComputerControl(backend: fake, now: { self.clock })
        let r = try c.execute(args(f), workspace: w)
        XCTAssertEqual(r["partial"] as? Bool, true)
        XCTAssertEqual((r["nodes"] as? [JSONObject])?.count, 128)
        XCTAssertLessThan(try LocalJSON.encode(r).count, 80_000)
    }
}
