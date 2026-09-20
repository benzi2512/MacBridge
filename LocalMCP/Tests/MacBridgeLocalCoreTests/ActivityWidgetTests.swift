import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ActivityWidgetTests: XCTestCase {
    private func server(_ fixture: Fixture, enabled: Bool = true) throws -> LocalMCPServer {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LocalMCPServer(configurationURL: fixture.config,
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"),
            connectorSurface: .webTunnel, observationEnabled: enabled)
    }

    func testResourceAndRenderMetadataAreConsistentAndBounded() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let listed = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/list"]))
        let resources = try XCTUnwrap((listed["result"] as? JSONObject)?["resources"] as? [JSONObject])
        XCTAssertEqual(resources.count, 3)
        XCTAssertEqual(Set(resources.compactMap { $0["uri"] as? String }),
                       [ActivityWidget.uri, ActivityWidget.previousURI, ActivityWidget.legacyURI])
        XCTAssertEqual(resources[0]["uri"] as? String, ActivityWidget.uri)
        for resource in resources {
            let uri = try XCTUnwrap(resource["uri"] as? String)
            let response = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 2, "method": "resources/read",
                                                 "params": ["uri": uri]]))
            let contents = try XCTUnwrap((response["result"] as? JSONObject)?["contents"] as? [JSONObject])
            XCTAssertEqual(contents.count, 1)
            XCTAssertEqual(contents[0]["uri"] as? String, uri)
            XCTAssertEqual(contents[0]["text"] as? String, ActivityWidget.html)
            XCTAssertEqual(contents[0]["mimeType"] as? String, resource["mimeType"] as? String)
            XCTAssertEqual(contents[0]["mimeType"] as? String,
                           uri == ActivityWidget.legacyURI ? "text/html;profile=mcp-app" : "text/html+skybridge")
            let meta = try XCTUnwrap(contents[0]["_meta"] as? JSONObject)
            let csp = try XCTUnwrap((meta["ui"] as? JSONObject)?["csp"] as? JSONObject)
            XCTAssertEqual(csp["connectDomains"] as? [String], [])
            XCTAssertEqual(csp["resourceDomains"] as? [String], [])
            if uri != ActivityWidget.legacyURI {
                let compatibilityCSP = try XCTUnwrap(meta["openai/widgetCSP"] as? JSONObject)
                XCTAssertEqual(compatibilityCSP["connect_domains"] as? [String], [])
                XCTAssertEqual(compatibilityCSP["resource_domains"] as? [String], [])
            }
        }
        XCTAssertLessThan(ActivityWidget.html.utf8.count, 20_000)
        XCTAssertTrue(ActivityWidget.html.contains("<img class=\"mark\""))
        XCTAssertTrue(ActivityWidget.html.contains("data:image/png;base64,"))
        let prefix = "src=\"data:image/png;base64,"
        let encodedStart = try XCTUnwrap(ActivityWidget.html.range(of: prefix)?.upperBound)
        let encodedEnd = try XCTUnwrap(ActivityWidget.html[encodedStart...].firstIndex(of: "\""))
        let embedded = try XCTUnwrap(Data(base64Encoded: String(ActivityWidget.html[encodedStart..<encodedEnd])))
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let card = try Data(contentsOf: packageRoot.appendingPathComponent("Assets/Brand/macbridge-icon-card.png"))
        XCTAssertEqual(embedded, card)
        XCTAssertFalse(ActivityWidget.html.contains(">MB</span>"))
        XCTAssertFalse(ActivityWidget.html.contains("fetch("))
        XCTAssertFalse(ActivityWidget.html.contains("WebSocket("))
        XCTAssertFalse(ActivityWidget.html.contains("process_cancel"))
        let specs = ActivityWidget.toolSpecs
        let renderUI = (specs[0]["_meta"] as? JSONObject)?["ui"] as? JSONObject
        let dataUI = (specs[1]["_meta"] as? JSONObject)?["ui"] as? JSONObject
        XCTAssertEqual(renderUI?["resourceUri"] as? String, ActivityWidget.uri)
        XCTAssertEqual((specs[0]["_meta"] as? JSONObject)?["openai/outputTemplate"] as? String, ActivityWidget.uri)
        XCTAssertNil(dataUI?["resourceUri"])
        for spec in specs {
            XCTAssertEqual((spec["annotations"] as? JSONObject)?["readOnlyHint"] as? Bool, true)
            XCTAssertEqual((spec["annotations"] as? JSONObject)?["destructiveHint"] as? Bool, false)
        }
        for uri in ["file:///etc/passwd", "ui://macbridge/../activity-v1.html", ActivityWidget.uri + "?q=1",
                    ActivityWidget.previousURI + "?q=1", ActivityWidget.legacyURI + "?q=1",
                    ActivityWidget.uri + "#fragment"] {
            let rejected = s.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": ["uri": uri]])
            XCTAssertNotNil(rejected?["error"])
        }
    }

    func testDiscoverAndInitializeAdvertiseIdenticalResourceCapabilities() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let discovered = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 1, "method": "server/discover"])?["result"] as? JSONObject)
        let initialized = try XCTUnwrap(s.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": JSONObject(),
                       "clientInfo": ["name": "resource-fixture", "version": "1"]]])?["result"] as? JSONObject)
        let discoveryCapabilities = try XCTUnwrap(discovered["capabilities"] as? JSONObject)
        let initializeCapabilities = try XCTUnwrap(initialized["capabilities"] as? JSONObject)
        XCTAssertEqual(try LocalJSON.encode(discoveryCapabilities), try LocalJSON.encode(initializeCapabilities))
        XCTAssertEqual((discoveryCapabilities["resources"] as? JSONObject)?["listChanged"] as? Bool, false)
        XCTAssertEqual((discoveryCapabilities["tools"] as? JSONObject)?["listChanged"] as? Bool, true)
    }

    func testRefreshIsOwnerBoundAndCannotDispatchMutations() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let view = try s.callTool(name: "bridge_activity_view", arguments: [:])
        let owner = try XCTUnwrap(view["instance_id"] as? String)
        XCTAssertEqual(view["scope"] as? String, "shared_runtime_not_chat_scoped")
        XCTAssertEqual(view["snapshot_stale"] as? Bool, false)
        XCTAssertEqual(view["jobs_known"] as? Bool, true)
        for args: JSONObject in [[:], ["instance_id": "wrong"], ["instance_id": owner, "action": "restore"],
                                 ["instance_id": owner, "path": "/etc/passwd"], ["instance_id": owner, "task_id": 1]] {
            XCTAssertThrowsError(try s.callTool(name: "bridge_activity", arguments: args))
        }
        XCTAssertThrowsError(try s.callTool(name: "bridge_activity_view", arguments: ["instance_id": owner]))
        XCTAssertNoThrow(try s.callTool(name: "bridge_activity", arguments: ["instance_id": owner]))
        XCTAssertThrowsError(try server(f, enabled: false).callTool(name: "bridge_activity_view", arguments: [:]))
    }

    func testResourceDeliveryDiagnosticsAreBoundedAndDoNotRetainInput() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        func delivery() throws -> JSONObject {
            try XCTUnwrap(s.callTool(name: "bridge_activity_view", arguments: [:])["ui_resource_delivery"] as? JSONObject)
        }
        XCTAssertEqual(try delivery()["last_outcome"] as? String, "not_requested")
        let read = s.handle(["jsonrpc": "2.0", "id": 1, "method": "resources/read",
                             "params": ["uri": ActivityWidget.uri]])
        XCTAssertNotNil(read?["result"])
        XCTAssertEqual(try delivery()["last_outcome"] as? String, "response_prepared")
        let unknown = s.handle(["jsonrpc": "2.0", "id": 2, "method": "resources/read",
                                "params": ["uri": "ui://PRIVATE_SENTINEL", "_meta": ["secret": "PRIVATE_SENTINEL"]]])
        XCTAssertEqual((unknown?["error"] as? JSONObject)?["code"] as? Int, -32_002)
        XCTAssertEqual(try delivery()["last_outcome"] as? String, "unknown_uri")
        let invalid = s.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/read",
                                "unexpected": "PRIVATE_SENTINEL", "params": ["uri": ActivityWidget.uri]])
        XCTAssertNotNil(invalid?["error"])
        let latest = try delivery()
        XCTAssertEqual(latest["read_count"] as? Int, 3)
        XCTAssertEqual(latest["last_outcome"] as? String, "invalid_request")
        XCTAssertEqual(Set(latest.keys), ["read_count", "last_outcome"])
        let snapshot = try s.observerRequest(["action": "snapshot"])
        XCTAssertFalse(String(decoding: try LocalJSON.encode(snapshot), as: UTF8.self).contains("PRIVATE_SENTINEL"))
        XCTAssertTrue((snapshot["history"] as? [JSONObject] ?? []).isEmpty)
        XCTAssertEqual(snapshot["transaction_count"] as? Int, 0)
    }

    func testReadOnlyRefreshPreservesUndoAndDoesNotRecordItselfOrFileContents() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let write = try s.callTool(name: "file_write", arguments: ["workspace_id": f.workspaceID,
            "path": "sample.txt", "content": "FIXTURE_CONTENT_NOT_IN_CARD"])
        let transaction = try XCTUnwrap(write["transaction_id"] as? String)
        let transactionToken = try XCTUnwrap(write["transaction_control_token"] as? String)
        for _ in 0..<30 { _ = try s.callTool(name: "workspace_overview", arguments: [:]) }
        let first = try s.callTool(name: "bridge_activity_view", arguments: [:])
        let owner = try XCTUnwrap(first["instance_id"] as? String)
        let history = try LocalJSON.encode(first["history"] as! [JSONObject])
        XCTAssertEqual((first["history"] as? [JSONObject])?.count, 24)
        for _ in 0..<50 {
            let refreshed = try s.callTool(name: "bridge_activity", arguments: ["instance_id": owner])
            XCTAssertEqual(try LocalJSON.encode(refreshed["history"] as! [JSONObject]), history)
            XCTAssertEqual(refreshed["transaction_count"] as? Int, 1)
            XCTAssertNil(refreshed["transactions"])
            XCTAssertNil(refreshed["log"])
            XCTAssertFalse(String(decoding: try LocalJSON.encode(refreshed), as: UTF8.self).contains("FIXTURE_CONTENT_NOT_IN_CARD"))
        }
        _ = try s.callTool(name: "transaction_restore", arguments: [
            "transaction_id": transaction, "transaction_control_token": transactionToken,
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("sample.txt").path))
    }

    func testBackgroundJobRunsAndLogPeekNeverConsumesTheHandle() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let view = try s.callTool(name: "bridge_activity_view", arguments: [:])
        let owner = try XCTUnwrap(view["instance_id"] as? String)
        let started = try s.callTool(name: "command_start", arguments: ["workspace_id": f.workspaceID,
            "executable": "sh", "arguments": ["-c", "printf 'widget-start\\n'; sleep 0.3; printf 'widget-done\\n'"],
            "maximum_output_bytes": 8192])
        let id = try XCTUnwrap(started["task_id"] as? String)
        let token = try XCTUnwrap(started["process_control_token"] as? String)
        defer { _ = try? s.callTool(name: "process_cancel", arguments: [
            "task_id": id, "process_control_token": token,
        ]) }
        let running = try s.callTool(name: "bridge_activity", arguments: ["instance_id": owner])
        XCTAssertTrue((running["jobs"] as! [JSONObject]).contains { $0["task_id"] as? String == id && $0["running"] as? Bool == true })
        for _ in 0..<100 {
            if try s.callTool(name: "process_status", arguments: ["task_id": id])["running"] as? Bool == false { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        for _ in 0..<3 {
            let peek = try s.callTool(name: "bridge_activity", arguments: [
                "instance_id": owner, "task_id": id, "process_control_token": token,
            ])
            let log = try XCTUnwrap(peek["log"] as? JSONObject)
            XCTAssertEqual(log["running"] as? Bool, false)
            XCTAssertEqual(log["output_consumed"] as? Bool, false)
            XCTAssertEqual(log["session_retained"] as? Bool, true)
            XCTAssertEqual(log["exit_code"] as? Int, 0, "Fixture child stderr: " + (log["stderr"] as? String ?? ""))
            XCTAssertTrue((log["stdout"] as? String ?? "").contains("widget-done"))
            XCTAssertLessThanOrEqual((log["stdout"] as? String ?? "").utf8.count, 4096)
        }
        let drained = try s.callTool(name: "process_output", arguments: [
            "task_id": id, "process_control_token": token,
        ])
        XCTAssertEqual(drained["session_retained"] as? Bool, false)
        let missing = try s.callTool(name: "bridge_activity", arguments: [
            "instance_id": owner, "task_id": id, "process_control_token": token,
        ])
        XCTAssertNotNil(missing["log_error"])
        XCTAssertNil(missing["log"])
    }

    func testWaitingCommandReturnsFreshSnapshotWithRunningHistoryAndJob() throws {
        let f = try Fixture(); defer { f.remove() }
        let s = try server(f)
        let owner = try XCTUnwrap(s.callTool(name: "bridge_activity_view", arguments: [:])["instance_id"] as? String)
        let done = DispatchSemaphore(value: 0)
        let workspaceID = f.workspaceID
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let result = try s.callTool(name: "command_run", arguments: ["workspace_id": workspaceID,
                    "executable": "cat", "arguments": [] as [String], "timeout_milliseconds": 5000])
                XCTAssertEqual(result["cancelled"] as? Bool, true)
            } catch { XCTFail("synthetic command failed: \(error)") }
        }
        // Always release this fixture's stdin and join before removing its files,
        // including on an assertion/error path. No unrelated owner is involved.
        defer {
            let jobs = (try? s.callTool(name: "process_list", arguments: [:])["processes"] as? [JSONObject]) ?? []
            for job in jobs where job["running"] as? Bool == true {
                if let id = job["task_id"] as? String {
                    _ = try? s.observerRequest([
                        "action": "cancel", "instance_id": owner, "task_id": id,
                    ])
                }
            }
            XCTAssertEqual(done.wait(timeout: .now() + 8), .success)
        }
        var running: JSONObject?
        for _ in 0..<200 {
            let sample = try s.callTool(name: "bridge_activity", arguments: ["instance_id": owner])
            let commandObserved = (sample["history"] as? [JSONObject] ?? []).contains {
                $0["tool"] as? String == "command_run" && $0["state"] as? String == "running"
            }
            let jobObserved = (sample["jobs"] as? [JSONObject] ?? []).contains { $0["running"] as? Bool == true }
            if commandObserved && jobObserved { running = sample; break }
            // A bounded startup wait, not an assumed execution duration: cat
            // cannot finish naturally until this test closes its stdin below.
            if done.wait(timeout: .now() + 0.01) == .success { done.signal(); break }
        }
        let snapshot = try XCTUnwrap(running)
        XCTAssertEqual(snapshot["busy"] as? Bool, false)
        XCTAssertEqual(snapshot["snapshot_stale"] as? Bool, false)
        let jobs = try XCTUnwrap(snapshot["jobs"] as? [JSONObject])
        let taskID = try XCTUnwrap(jobs.first(where: { $0["running"] as? Bool == true })?["task_id"] as? String)
        let completionBeforeRelease = done.wait(timeout: .now())
        if completionBeforeRelease == .success { done.signal() }
        XCTAssertEqual(completionBeforeRelease, .timedOut)
        _ = try s.observerRequest([
            "action": "cancel", "instance_id": owner, "task_id": taskID,
        ])
        XCTAssertEqual(done.wait(timeout: .now() + 8), .success)
        done.signal()
        let fresh = try s.callTool(name: "bridge_activity", arguments: ["instance_id": owner])
        XCTAssertEqual(fresh["snapshot_stale"] as? Bool, false)
        let finished = try XCTUnwrap((fresh["history"] as? [JSONObject])?.last {
            $0["tool"] as? String == "command_run"
        })
        XCTAssertEqual(finished["state"] as? String, "returned")
        XCTAssertEqual((finished["result"] as? JSONObject)?["cancelled"] as? Bool, true)
    }
}
