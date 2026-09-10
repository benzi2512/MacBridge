import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class RequestIdentityProbeTests: XCTestCase {
    private func samples(_ probe: RequestIdentityProbe) throws -> [JSONObject] {
        try XCTUnwrap(probe.snapshot()["samples"] as? [JSONObject])
    }

    private func tag(_ row: JSONObject, field: String) throws -> String {
        try XCTUnwrap((row["fields"] as? [JSONObject])?.first { $0["field"] as? String == field }?["equality_tag"] as? String)
    }

    func testDisabledByDefaultAndAutomaticallyStopsAtBound() throws {
        let probe = RequestIdentityProbe()
        func mustNotEvaluate() -> String { XCTFail("Disabled diagnostic must not evaluate tool catalog"); return "bad" }
        probe.observe(tool: mustNotEvaluate(), metadata: ["thread_id": "a"])
        XCTAssertTrue(try samples(probe).isEmpty)
        _ = probe.start()
        for _ in 0..<50 { probe.observe(tool: "file_read", metadata: nil) }
        XCTAssertEqual(try samples(probe).count, 32)
        XCTAssertEqual(probe.snapshot()["enabled"] as? Bool, false)
        XCTAssertEqual(try samples(probe)[0]["meta_type"] as? String, "absent")
        _ = probe.stop()
        XCTAssertTrue(try samples(probe).isEmpty)
    }

    func testInterleavedChatRunComparisonDoesNotRetainValuesOrBecomeIdentity() throws {
        let probe = RequestIdentityProbe()
        _ = probe.start()
        for (chat, run) in [("private-chat-A", "private-run-1"), ("private-chat-B", "private-run-1"),
                            ("private-chat-A", "private-run-1"), ("private-chat-A", "private-run-2")] {
            probe.observe(tool: "file_read", metadata: ["openai/thread_id": chat, "openai/turn_id": run,
                "session_id": "shared-connection"])
        }
        let rows = try samples(probe)
        XCTAssertEqual(try tag(rows[0], field: "openai/thread_id"), try tag(rows[2], field: "openai/thread_id"))
        XCTAssertNotEqual(try tag(rows[0], field: "openai/thread_id"), try tag(rows[1], field: "openai/thread_id"))
        XCTAssertNotEqual(try tag(rows[0], field: "openai/turn_id"), try tag(rows[3], field: "openai/turn_id"))
        XCTAssertEqual(try tag(rows[0], field: "session_id"), try tag(rows[1], field: "session_id"))
        let text = String(decoding: try LocalJSON.encode(probe.snapshot()), as: UTF8.self)
        for secret in ["private-chat-A", "private-chat-B", "private-run-1", "private-run-2", "shared-connection"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertFalse(text.contains("work_id"), "This measurement must never imply or create a group")
        let old = try tag(rows[0], field: "openai/thread_id")
        _ = probe.start()
        probe.observe(tool: "file_read", metadata: ["openai/thread_id": "private-chat-A"])
        XCTAssertNotEqual(old, try tag(samples(probe)[0], field: "openai/thread_id"))
    }

    func testOnlyKnownBoundedFieldNamesAndTypesSurvive() throws {
        let probe = RequestIdentityProbe()
        _ = probe.start()
        probe.observe(tool: "file_read", metadata: [
            "SECRET_KEY_NAME": "SECRET_VALUE", "Authorization": ["thread_id": "SECRET_HEADER"],
            "secret-namespace/thread_id": "SECRET_NAMESPACE", "openai/locale": "PRIVATE_LOCALE",
            "context": ["conversationId": "PRIVATE_CONVERSATION", "token": "SECRET_TOKEN"],
            "run_id": ["secret": "SECRET_NESTED"], "request_id": String(repeating: "x", count: 513),
            "session_id": ["SECRET_ARRAY"],
            "": "SECRET_EMPTY_KEY", "/": "SECRET_SLASH_KEY",
        ])
        let row = try samples(probe)[0], fields = try XCTUnwrap(row["fields"] as? [JSONObject])
        XCTAssertEqual(Set(fields.compactMap { $0["field"] as? String }),
                       ["context.conversationId", "run_id", "request_id", "session_id"])
        XCTAssertEqual(fields.filter { $0["equality_tag"] != nil }.count, 1)
        let text = String(decoding: try LocalJSON.encode(probe.snapshot()), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("PRIVATE"))
        probe.observe(tool: "file_read", metadata: Dictionary(uniqueKeysWithValues: (0..<25).map { ("field\($0)", "secret") }))
        XCTAssertTrue((try samples(probe)[1]["fields"] as? [JSONObject])?.isEmpty == true)
        XCTAssertEqual(try samples(probe)[1]["omitted_fields"] as? Int, 25)
    }

    func testMalformedEmptyAndDeepMetadataStayDistinctAndBounded() throws {
        let probe = RequestIdentityProbe()
        _ = probe.start()
        for value in [nil, [:] as JSONObject, "PRIVATE_INVALID_META", NSNull(), ["PRIVATE_ARRAY"]] as [Any?] {
            probe.observe(tool: "file_read", metadata: value)
        }
        XCTAssertEqual(try samples(probe).compactMap { $0["meta_type"] as? String },
                       ["absent", "object", "string", "null", "array"])
        let leaves: JSONObject = ["thread_id": "PRIVATE_NESTED", "run_id": "PRIVATE_RUN"]
        let branch = Dictionary(uniqueKeysWithValues: ["context", "openai", "mcp", "client", "request", "session"]
            .map { ($0, leaves as Any) })
        let tree = Dictionary(uniqueKeysWithValues: ["context", "openai", "mcp", "client", "request", "session"]
            .map { ($0, branch as Any) })
        probe.observe(tool: "file_read", metadata: tree)
        let row = try XCTUnwrap(samples(probe).last)
        XCTAssertLessThanOrEqual(try XCTUnwrap(row["inspected_nodes"] as? Int), 64)
        XCTAssertLessThanOrEqual((row["fields"] as? [JSONObject])?.count ?? 999, 24)
        XCTAssertGreaterThan(row["omitted_fields"] as? Int ?? 0, 0)
        let text = String(decoding: try LocalJSON.encode(probe.snapshot()), as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE"))
    }

    func testProbeIsOwnerBoundLocalOnlyAndDoesNotChangeToolExecution() throws {
        let f = try Fixture(); defer { f.remove() }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let server = try LocalMCPServer(configurationURL: f.config, selfExecutable: executable,
                                        connectorSurface: .webTunnel, observationEnabled: true)
        let owner = try XCTUnwrap(server.callTool(name: "bridge_capabilities", arguments: [:])["instance_id"] as? String)
        func probe(_ operation: String, identity: String? = nil) throws -> JSONObject {
            try server.observerRequest(["action": "identity_probe", "instance_id": identity ?? owner, "operation": operation])
        }
        XCTAssertThrowsError(try probe("start", identity: UUID().uuidString))
        XCTAssertThrowsError(try probe("unknown"))
        _ = try probe("start")
        let response = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "workspace_overview", "arguments": [:], "_meta": ["thread_id": "SYNTHETIC_PRIVATE_CHAT"],
        ] as JSONObject])
        XCTAssertNotNil(response?["result"])
        let diagnostic = try probe("read")
        XCTAssertEqual((diagnostic["samples"] as? [JSONObject])?.count, 1)
        let snapshot = try server.observerRequest(["action": "snapshot"])
        XCTAssertTrue((snapshot["work_items"] as? [JSONObject])?.isEmpty == true)
        XCTAssertNil(snapshot["identity_probe"], "Normal snapshots must not export probe records")
        for result in [try server.callTool(name: "bridge_activity", arguments: ["instance_id": owner]), response ?? [:]] {
            let text = String(decoding: try LocalJSON.encode(result), as: UTF8.self)
            XCTAssertFalse(text.contains("equality_tag")); XCTAssertFalse(text.contains("SYNTHETIC_PRIVATE_CHAT"))
        }
        _ = try probe("stop")
        XCTAssertTrue((try probe("read")["samples"] as? [JSONObject])?.isEmpty == true)
        let disabled = try LocalMCPServer(configurationURL: f.config, selfExecutable: executable)
        XCTAssertThrowsError(try disabled.observerRequest(["action": "identity_probe", "instance_id": owner, "operation": "start"]))
    }
}
