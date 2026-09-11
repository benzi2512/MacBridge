import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ObserverTests: XCTestCase {
    private func server(_ f: Fixture, enabled: Bool = true) throws -> LocalMCPServer {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LocalMCPServer(configurationURL: f.config,
                                  selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"),
                                  observationEnabled: enabled)
    }

    func testDisabledObserverHasNoObservationAPI() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f, enabled: false)
        XCTAssertThrowsError(try owner.observerRequest(["action": "snapshot"]))
        XCTAssertEqual(try owner.callTool(name: "bridge_capabilities", arguments: [:])["catalog_count"] as? Int, 72)
    }

    func testHistoryIsBoundedAndDoesNotStoreRequestContent() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        for _ in 0..<90 { _ = try owner.callTool(name: "workspace_overview", arguments: [:]) }
        _ = try owner.callTool(name: "file_write", arguments: [
            "workspace_id": f.workspaceID, "path": "sample.txt", "content": "SYNTHETIC_PAYLOAD_NOT_IN_HISTORY",
        ])
        let snapshot = try owner.observerRequest(["action": "snapshot"])
        XCTAssertEqual((snapshot["history"] as? [JSONObject])?.count, 64)
        let text = String(decoding: try LocalJSON.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains("SYNTHETIC_PAYLOAD_NOT_IN_HISTORY"))
        XCTAssertEqual((snapshot["transactions"] as? [JSONObject])?.count, 1)
    }

    func testBatchOutcomeMetadataSurvivesBothActivitySurfaces() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let batch = try owner.callTool(name: "file_write_many", arguments: [
            "workspace_id": f.workspaceID, "files": [
                ["path": "a.txt", "content": "SYNTHETIC_BATCH_BODY"],
                ["path": "missing/child.txt", "content": "SYNTHETIC_REJECTED_BODY"],
            ],
        ])
        XCTAssertEqual(batch["success_count"] as? Int, 1)
        XCTAssertEqual(batch["error_count"] as? Int, 1)
        let snapshot = try owner.observerRequest(["action": "snapshot"])
        let identity = try XCTUnwrap(snapshot["instance_id"] as? String)
        let activity = try owner.callTool(name: "bridge_activity", arguments: ["instance_id": identity])
        for surface in [snapshot, activity] {
            let event = try XCTUnwrap((surface["history"] as? [JSONObject])?.last)
            XCTAssertEqual(event["state"] as? String, "returned")
            let result = try XCTUnwrap(event["result"] as? JSONObject)
            XCTAssertEqual(result["success_count"] as? Int, 1)
            XCTAssertEqual(result["error_count"] as? Int, 1)
            XCTAssertEqual(result["complete"] as? Bool, false)
            XCTAssertNil(result["results"], "Do not retain nested file results or payloads")
            let encoded = String(decoding: try LocalJSON.encode(surface), as: UTF8.self)
            XCTAssertFalse(encoded.contains("SYNTHETIC_BATCH_BODY"))
            XCTAssertFalse(encoded.contains("SYNTHETIC_REJECTED_BODY"))
        }
        let receipt = try XCTUnwrap((batch["results"] as? [JSONObject])?.first?["receipt"] as? JSONObject)
        _ = try owner.callTool(name: "transaction_restore", arguments: ["transaction_id": receipt["transaction_id"]!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("a.txt").path))
    }

    func testTransactionOwnerConflictReadbackAndStaleGuards() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let identity = try XCTUnwrap(owner.observerRequest(["action": "snapshot"])["instance_id"] as? String)
        let original = Data("Xin chào 🌏\nvalue=1\n".utf8)
        try original.write(to: f.workspace.appendingPathComponent("sample.txt"))
        func patch(_ old: String, _ new: String, _ digest: String) throws -> JSONObject {
            try owner.callTool(name: "file_patch", arguments: [
                "workspace_id": f.workspaceID, "path": "sample.txt",
                "old_text": old, "new_text": new, "expected_sha256": digest,
            ])
        }
        let first = try patch("value=1", "value=2", LocalHash.sha256(original))
        let t1 = try XCTUnwrap(first["transaction_id"] as? String)
        let changed = Data("Xin chào 🌏\nvalue=2\n".utf8)
        let detail = try owner.observerRequest(["action": "transaction", "instance_id": identity,
                                               "transaction_id": t1, "workspace_id": f.workspaceID])
        XCTAssertEqual(detail["before"] as? String, String(data: original, encoding: .utf8))
        XCTAssertEqual(detail["after"] as? String, String(data: changed, encoding: .utf8))
        XCTAssertThrowsError(try owner.observerRequest(["action": "restore", "instance_id": UUID().uuidString,
                                                       "transaction_id": t1, "workspace_id": f.workspaceID]))
        XCTAssertThrowsError(try owner.observerRequest(["action": "restore", "instance_id": identity,
                                                       "transaction_id": t1, "workspace_id": UUID().uuidString]))
        let second = try patch("value=2", "value=3", LocalHash.sha256(changed))
        let t2 = try XCTUnwrap(second["transaction_id"] as? String)
        func restore(_ id: String) throws -> JSONObject {
            try owner.observerRequest(["action": "restore", "instance_id": identity,
                                       "transaction_id": id, "workspace_id": f.workspaceID])
        }
        XCTAssertThrowsError(try restore(t1))
        XCTAssertEqual(try restore(t2)["readback_verified"] as? Bool, true)
        XCTAssertEqual(try restore(t1)["readback_verified"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: f.workspace.appendingPathComponent("sample.txt")), original)
        XCTAssertThrowsError(try restore(t1))
        XCTAssertEqual((try owner.observerRequest(["action": "snapshot"])["transactions"] as? [JSONObject])?.count, 0)
    }

    func testObserverPeekDoesNotConsumeCompletedHandleAndOutputIsBounded() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let identity = try XCTUnwrap(owner.observerRequest(["action": "snapshot"])["instance_id"] as? String)
        let started = try owner.callTool(name: "command_start", arguments: [
            "workspace_id": f.workspaceID, "executable": "python3",
            "arguments": ["-c", "print('X' * 20000)"], "maximum_output_bytes": 4096,
        ])
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? owner.callTool(name: "process_cancel", arguments: ["task_id": id]) }
        for _ in 0..<100 {
            if try owner.callTool(name: "process_status", arguments: ["task_id": id])["running"] as? Bool == false { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        for _ in 0..<3 {
            let peek = try owner.observerRequest(["action": "output", "instance_id": identity, "task_id": id])
            XCTAssertEqual(peek["running"] as? Bool, false)
            XCTAssertEqual(peek["session_retained"] as? Bool, true)
            XCTAssertLessThanOrEqual((peek["stdout"] as? String)?.utf8.count ?? 0, 4096)
            XCTAssertEqual(peek["stdout_cursor_adjusted"] as? Bool, true)
            XCTAssertNoThrow(try owner.callTool(name: "process_status", arguments: ["task_id": id]))
        }
        let drained = try owner.callTool(name: "process_output", arguments: ["task_id": id])
        XCTAssertEqual(drained["session_retained"] as? Bool, false)
        let completed = try owner.callTool(name: "process_status", arguments: ["task_id": id])
        XCTAssertEqual(completed["status_only"] as? Bool, true)
        XCTAssertEqual(completed["session_retained"] as? Bool, false)
        XCTAssertNil(completed["stdout"])
        XCTAssertThrowsError(try owner.observerRequest(["action": "output", "instance_id": identity, "task_id": id]))
    }

    func testSocketRoundTripNoReplacementAndStopCleanup() throws {
        var template = Array("/private/tmp/mb-ui-test-XXXXXX".utf8CString)
        let directory = try XCTUnwrap(template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let path = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: path)
        })
        // Keep the workspace in the existing canonical fixture location.
        // Only the socket directory needs a short sockaddr_un-compatible path.
        let f = try Fixture()
        defer { f.remove(); try? FileManager.default.removeItem(atPath: directory) }
        let owner = try server(f)
        let endpoint = try LocalObserverEndpoint(directory: directory, server: owner)
        defer { endpoint.stop() }
        let bytes = try ObserverSocket.request(directory: directory,
                                               payload: LocalJSON.encode(["action": "snapshot"] as JSONObject))
        let wrapper = try LocalJSON.decodeObject(bytes)
        XCTAssertEqual(wrapper["ok"] as? Bool, true)
        XCTAssertEqual((wrapper["result"] as? JSONObject)?["catalog_count"] as? Int, 72)
        XCTAssertThrowsError(try LocalObserverEndpoint(directory: directory, server: owner))
        XCTAssertNoThrow(try ObserverSocket.request(directory: directory,
                                                    payload: LocalJSON.encode(["action": "snapshot"] as JSONObject)))
        endpoint.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/observer.sock"))
        XCTAssertThrowsError(try ObserverSocket.request(directory: directory, payload: Data("{}".utf8)))
        let restarted = try LocalObserverEndpoint(directory: directory, server: owner)
        defer { restarted.stop() }
        let restartedBytes = try ObserverSocket.request(directory: directory,
            payload: LocalJSON.encode(["action": "snapshot"] as JSONObject))
        XCTAssertEqual(try LocalJSON.decodeObject(restartedBytes)["ok"] as? Bool, true,
                       "Normal stop must release the directory lease and allow a fresh endpoint to serve")
    }

    func testPagedObserverOutputIsUTF8CompleteAndNeverConsumesChatHandle() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let identity = try XCTUnwrap(owner.observerRequest(["action": "snapshot"])["instance_id"] as? String)
        XCTAssertEqual(try owner.observerRequest(["action": "snapshot"])["observer_output_pagination"] as? Bool, true)
        let started = try owner.callTool(name: "command_start", arguments: [
            "workspace_id": f.workspaceID, "executable": "python3", "maximum_output_bytes": 131072,
            "arguments": ["-c", "import sys;sys.stdout.write('🌏abc\\n'*5000);sys.stderr.write('é!\\n'*5000)"],
        ])
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? owner.callTool(name: "process_cancel", arguments: ["task_id": id]) }
        for _ in 0..<100 {
            if try owner.callTool(name: "process_status", arguments: ["task_id": id])["running"] as? Bool == false { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try owner.callTool(name: "process_status", arguments: ["task_id": id])["running"] as? Bool, false)
        func page(_ out: Int, _ err: Int) throws -> JSONObject {
            try owner.observerRequest(["action": "output", "instance_id": identity, "task_id": id,
                                       "stdout_cursor": out, "stderr_cursor": err])
        }
        XCTAssertThrowsError(try page(-1, 0))
        XCTAssertThrowsError(try page(1, 0)) // Inside the initial four-byte scalar.
        XCTAssertThrowsError(try page(1000000, 0))
        XCTAssertThrowsError(try owner.observerRequest(["action": "cancel", "instance_id": identity,
                                                        "task_id": id, "stdout_cursor": 0]))
        var out = 0, err = 0, text = "", errors = "", pages = 0
        for _ in 0..<32 {
            let result = try page(out, err)
            let chunk = try XCTUnwrap(result["stdout"] as? String)
            let errorChunk = try XCTUnwrap(result["stderr"] as? String)
            XCTAssertLessThanOrEqual(chunk.utf8.count, 8195)
            XCTAssertLessThanOrEqual(errorChunk.utf8.count, 8195)
            XCTAssertEqual(result["session_retained"] as? Bool, true)
            text += chunk; errors += errorChunk; pages += 1
            out = try XCTUnwrap(result["stdout_next_cursor"] as? Int)
            err = try XCTUnwrap(result["stderr_next_cursor"] as? Int)
            if out == result["stdout_total_bytes"] as? Int && err == result["stderr_total_bytes"] as? Int { break }
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(text, String(repeating: "🌏abc\n", count: 5000))
        XCTAssertEqual(errors, String(repeating: "é!\n", count: 5000))
        // Read back an earlier page: no navigation state is stored in the owner.
        XCTAssertTrue((try page(0, 0)["stdout"] as? String)?.hasPrefix("🌏abc\n") == true)
        let chatRead = try owner.callTool(name: "process_output", arguments: ["task_id": id, "maximum_bytes_per_stream": 131072])
        XCTAssertEqual(chatRead["stdout"] as? String, text)
        XCTAssertEqual(chatRead["stderr"] as? String, errors)
        XCTAssertEqual(chatRead["session_retained"] as? Bool, false)
        XCTAssertThrowsError(try page(0, 0))
    }

    func testObserverTextMetadataNeverMistakesBinaryOrCreationForLiteralText() throws {
        let f = try Fixture(); defer { f.remove() }
        let owner = try server(f)
        let identity = try XCTUnwrap(owner.observerRequest(["action": "snapshot"])["instance_id"] as? String)
        func write(_ name: String, _ data: Data) throws -> JSONObject {
            let made = try owner.callTool(name: "file_write", arguments: ["workspace_id": f.workspaceID,
                "path": name, "content": data.base64EncodedString(), "encoding": "base64"])
            let id = try XCTUnwrap(made["transaction_id"] as? String)
            return try owner.observerRequest(["action": "transaction", "instance_id": identity,
                "transaction_id": id, "workspace_id": f.workspaceID])
        }
        let created = try write("new.txt", Data("hello\n".utf8))
        XCTAssertEqual(created["before_exists"] as? Bool, false)
        XCTAssertEqual(created["before_is_text"] as? Bool, true)
        XCTAssertEqual(created["after_is_text"] as? Bool, true)
        XCTAssertEqual(try write("nul.bin", Data([65, 0]))["after_is_text"] as? Bool, false)
        XCTAssertEqual(try write("invalid.bin", Data([65, 255]))["after_is_text"] as? Bool, false)
        let text = String(repeating: "a", count: 8191) + "🌏end\n"
        let partial = try write("large.txt", Data(text.utf8))
        XCTAssertEqual(partial["after_is_text"] as? Bool, true)
        XCTAssertEqual((partial["after"] as? String)?.utf8.count, 8191)
        XCTAssertEqual(partial["after_truncated"] as? Bool, true)
        let smallPartial = try write("8193.txt", Data((String(repeating: "a", count: 8193)).utf8))
        XCTAssertEqual(smallPartial["after_truncated"] as? Bool, true)
        XCTAssertEqual((smallPartial["after"] as? String)?.utf8.count, 8192)
    }

    func testRejectsNonPrivateObserverDirectory() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertEqual(chmod(f.root.path, 0o755), 0)
        XCTAssertThrowsError(try LocalObserverEndpoint(directory: f.root.path, server: server(f)))
    }
}
