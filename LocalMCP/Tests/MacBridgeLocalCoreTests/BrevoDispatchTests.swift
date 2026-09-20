import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

/// Exact protocol dispatch with only synthetic, internally injected transport.
/// No credential reads, HTTP, child commands or production configuration.
final class BrevoDispatchTests: XCTestCase {
    func testHeldBrevoTransportDoesNotStarveProtocolMetadata() throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = HeldBrevoTransport()
        let server = try makeServer(f, transport)
        let io = BrevoDispatchConnection(server)
        defer { transport.release.signal(); io.close() }
        try io.tool("brevo/one-é", "brevo_read", ["action": "account"])
        XCTAssertEqual(transport.entered.wait(timeout: .now() + 2), .success)
        try io.send(["jsonrpc": "2.0", "id": 2, "method": "ping"])
        try io.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
        try io.tool(4, "bridge_capabilities", [:])
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let ping = try io.receive(id: 2)
            XCTAssertNotNil(ping["result"])
            let catalog = try XCTUnwrap(try io.receive(id: 3)["result"] as? JSONObject)
            XCTAssertEqual((catalog["tools"] as? [JSONObject])?.count, 76)
            XCTAssertEqual(Set((catalog["tools"] as? [JSONObject] ?? []).compactMap { $0["name"] as? String }).count, 76)
            let capability = try structured(io.receive(id: 4))
            XCTAssertEqual(capability["catalog_count"] as? Int, 76)
            XCTAssertEqual(capability["catalog_sha256"] as? String, catalog["catalogEpoch"] as? String)
            XCTAssertEqual(capability["active_brevo_calls"] as? Int, 1)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            XCTAssertLessThan(milliseconds, 1_000)
            print("BREVO_DISPATCH_METADATA_MS=\(milliseconds)")
        } catch {
            // Fail-before cleanup drains the synchronous baseline, including a
            // full catalog larger than a pipe buffer, without stranding a writer.
            transport.release.signal()
            _ = try io.receive(id: "brevo/one-é")
            for id in [2, 3, 4] { _ = try io.receive(id: id) }
            XCTAssertTrue(try io.finishAndDrain().isEmpty)
            XCTFail("Readiness starvation reproduced: \(error)")
            return
        }
        transport.release.signal()
        XCTAssertEqual(try structured(io.receive(id: "brevo/one-é"))["email"] as? String, BrevoOperations.fixtureAccount)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testSharedAdmissionRejectsSecondFamilyCallAndBalancesParent() throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = HeldBrevoTransport()
        let server = try makeServer(f, transport), io = BrevoDispatchConnection(server)
        defer { transport.release.signal(); io.close() }
        try io.tool(1, "work_task", ["action": "begin", "title": "Synthetic slow read"])
        let started = try structured(io.receive(id: 1))
        let parent = try XCTUnwrap(started["work_id"] as? String)
        let control = try XCTUnwrap(started["work_control_token"] as? String)
        let scoped: JSONObject = ["work_id": parent, "work_control_token": control]
        try io.tool(2, "brevo_read", scoped.merging(["action": "account"]) { _, rhs in rhs })
        XCTAssertEqual(transport.entered.wait(timeout: .now() + 2), .success)
        try io.tool(3, "brevo_lists", scoped.merging(["action": "list"]) { _, rhs in rhs })
        try assertToolError(io.receive(id: 3), contains: "already active")
        XCTAssertThrowsError(try server.callTool(name: "brevo_campaign", arguments: ["action": "preflight", "campaign_id": 1]))
        XCTAssertEqual(transport.calls, 1, "Rejected calls must not touch credentials/transport or queue work")
        let snapshot = try server.observerRequest(["action": "snapshot"])
        XCTAssertEqual(snapshot["busy"] as? Bool, true)
        XCTAssertEqual(snapshot["snapshot_stale"] as? Bool, false)
        XCTAssertEqual(snapshot["active_brevo_calls"] as? Int, 1)
        let item = try XCTUnwrap((snapshot["work_items"] as? [JSONObject])?.first)
        XCTAssertEqual(item["active_call_count"] as? Int, 1)
        try io.tool(4, "work_task", ["action": "finish", "work_id": parent,
                                     "work_control_token": control])
        try assertToolError(io.receive(id: 4), contains: "active calls")
        transport.release.signal()
        XCTAssertEqual(try structured(io.receive(id: 2))["work_id"] as? String, parent)
        try io.tool(5, "work_task", ["action": "finish", "work_id": parent,
                                     "work_control_token": control])
        XCTAssertEqual(try structured(io.receive(id: 5))["state"] as? String, "completed")
        try io.tool(6, "brevo_read", ["action": "account"])
        XCTAssertEqual(try structured(io.receive(id: 6))["email"] as? String, BrevoOperations.fixtureAccount)
        XCTAssertEqual(transport.calls, 2)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testUncertainWriteCompletesOnceDespiteCancellationAndEOF() throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = HeldBrevoTransport(holdWrite: true, failWrite: true)
        let server = try makeServer(f, transport), io = BrevoDispatchConnection(server)
        defer { transport.release.signal(); io.close() }
        let args: JSONObject = ["action": "create", "name": "Synthetic only", "folder_id": 1,
            "apply": true, "confirm_write": true, "verified_account_email": BrevoOperations.fixtureAccount]
        try io.tool("write-original", "brevo_lists", args)
        XCTAssertEqual(transport.entered.wait(timeout: .now() + 2), .success)
        try io.tool("write-not-queued", "brevo_lists", args)
        try assertToolError(io.receive(id: "write-not-queued"), contains: "already active")
        try io.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "write-original"]])
        try io.send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        XCTAssertNotNil(try io.receive(id: 3)["result"])
        try io.endInput()
        transport.release.signal()
        let result = try structured(io.receive(id: "write-original"))
        XCTAssertEqual(result["outcome"] as? String, "outcome_unknown")
        XCTAssertEqual(result["automatic_retry"] as? Bool, false)
        XCTAssertEqual(transport.calls, 2)
        XCTAssertEqual(transport.writes, 1)
        XCTAssertTrue(try io.finishAndDrain().isEmpty, "No duplicate response or cancellation claim")
        XCTAssertEqual(try server.callTool(name: "bridge_capabilities", arguments: [:])["active_brevo_calls"] as? Int, 0)
    }

    func testDirectCallerOwnsSameLaneAndReleasesAfterReadFailure() throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = HeldBrevoTransport(failRead: true)
        let server = try makeServer(f, transport), io = BrevoDispatchConnection(server)
        let finished = DispatchSemaphore(value: 0)
        defer { transport.release.signal(); _ = finished.wait(timeout: .now() + 3); io.close() }
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try server.callTool(name: "brevo_read", arguments: ["action": "account"])
                XCTFail("Synthetic read failure was not propagated")
            } catch { /* Expected fixed synthetic error; no retry. */ }
        }
        XCTAssertEqual(transport.entered.wait(timeout: .now() + 2), .success)
        try io.tool(2, "brevo_lists", ["action": "list"])
        try assertToolError(io.receive(id: 2), contains: "already active")
        try io.tool(3, "bridge_capabilities", [:])
        XCTAssertEqual(try structured(io.receive(id: 3))["active_brevo_calls"] as? Int, 1)
        transport.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success); finished.signal()
        try io.tool(4, "brevo_automations", ["action": "capabilities"])
        XCTAssertEqual(try structured(io.receive(id: 4))["network_request"] as? Bool, false)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testDesktopHandshakeAndInvalidArgumentsNeverReachTransport() throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = HeldBrevoTransport()
        let server = try makeServer(f, transport, surface: .desktopLocal), io = BrevoDispatchConnection(server)
        defer { transport.release.signal(); io.close() }
        try io.tool(1, "brevo_read", ["action": "account"])
        XCTAssertNotNil(try io.receive(id: 1)["error"])
        try io.send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as JSONObject,
            "clientInfo": ["name": "synthetic-brevo-dispatch", "version": "1"]] as JSONObject])
        XCTAssertNotNil(try io.receive(id: 2)["result"])
        try io.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try io.tool(3, "brevo_lists", ["action": "create", "name": "Fixture", "folder_id": 1, "apply": true])
        try assertToolError(io.receive(id: 3), contains: "confirm_write")
        try io.tool(4, "brevo_read", ["action": "account", "transport": "untrusted"])
        try assertToolError(io.receive(id: 4))
        try io.tool(5, "brevo_read", ["action": "account", "work_id": UUID().uuidString])
        try assertToolError(io.receive(id: 5), contains: "work_id")
        try io.tool(6, "brevo_automations", ["action": "capabilities"])
        XCTAssertEqual(try structured(io.receive(id: 6))["network_request"] as? Bool, false)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
    }

    func testBrokenResponseOutputDoesNotReplayAcceptedWrite() throws {
        let f = try Fixture(); defer { f.remove() }
        let transport = HeldBrevoTransport(holdWrite: true)
        let server = try makeServer(f, transport)
        let io = BrevoDispatchConnection(server, expectsOutputFailure: true)
        defer { transport.release.signal(); io.close() }
        try io.tool("write-output-lost", "brevo_lists", ["action": "create", "name": "Synthetic only", "folder_id": 1,
            "apply": true, "confirm_write": true, "verified_account_email": BrevoOperations.fixtureAccount])
        XCTAssertEqual(transport.entered.wait(timeout: .now() + 2), .success)
        try io.endInput()
        // Close the writer while no response write is active: deterministic
        // FileHandle failure, without process-global SIGPIPE disposition changes.
        try io.closeResponseWriter()
        transport.release.signal()
        XCTAssertTrue(try io.finishAndDrain().isEmpty)
        XCTAssertTrue(io.runError.contains("background tool response output failed"))
        XCTAssertEqual(transport.calls, 2)
        XCTAssertEqual(transport.writes, 1)
        XCTAssertEqual(try server.callTool(name: "bridge_capabilities", arguments: [:])["active_brevo_calls"] as? Int, 0)
    }

    private func assertToolError(_ response: JSONObject, contains text: String? = nil) throws {
        let result = try XCTUnwrap(response["result"] as? JSONObject)
        XCTAssertEqual(result["isError"] as? Bool, true)
        if let text {
            let structured = try XCTUnwrap(result["structuredContent"] as? JSONObject)
            XCTAssertTrue((structured["error"] as? String ?? "").contains(text))
        }
    }

    private func makeServer(_ f: Fixture, _ transport: HeldBrevoTransport,
                            surface: MacBridgeConnectorSurface = .webTunnel) throws -> LocalMCPServer {
        try LocalMCPServer(configurationURL: f.config, selfExecutable: f.config,
                           connectorSurface: surface, observationEnabled: true,
                           searchStartForTesting: nil, brevoTransportForTesting: transport.run)
    }

    private func structured(_ response: JSONObject) throws -> JSONObject {
        let result = try XCTUnwrap(response["result"] as? JSONObject)
        XCTAssertEqual(result["isError"] as? Bool, false)
        return try XCTUnwrap(result["structuredContent"] as? JSONObject)
    }
}

private final class HeldBrevoTransport: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0, writeCount = 0
    private let holdWrite: Bool, failWrite: Bool, failRead: Bool
    init(holdWrite: Bool = false, failWrite: Bool = false, failRead: Bool = false) {
        self.holdWrite = holdWrite; self.failWrite = failWrite; self.failRead = failRead
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }

    func run(_ method: String, _ path: String, _ query: [URLQueryItem],
             _ body: JSONObject?, _ write: Bool) throws -> JSONObject {
        lock.lock(); count += 1; let current = count; if write { writeCount += 1 }; lock.unlock()
        guard (method == "GET" && path == "account" && !write)
            || (method == "POST" && path == "contacts/lists" && write) else {
            throw LocalMCPError.operationFailed("Unexpected synthetic request")
        }
        if (holdWrite && write) || (!holdWrite && current == 1) {
            entered.signal()
            guard release.wait(timeout: .now() + 8) == .success else {
                throw LocalMCPError.operationFailed("Synthetic transport release timed out")
            }
        }
        if write && failWrite { throw LocalMCPError.operationFailed("WRITE_OUTCOME_UNKNOWN: synthetic failure") }
        if failRead { throw LocalMCPError.operationFailed("Synthetic read failure") }
        if write { return ["id": 123, "http_status": 201] }
        return ["email": BrevoOperations.fixtureAccount, "plan": [] as [JSONObject]]
    }
}

private final class BrevoDispatchConnection {
    private let input = Pipe(), output = Pipe()
    private let done = DispatchSemaphore(value: 0)
    private var received = Data()
    private var inputClosed = false, outputClosed = false
    private let outcome = BrevoDispatchOutcome()
    var runError: String { outcome.message }

    init(_ server: LocalMCPServer, expectsOutputFailure: Bool = false) {
        let readHandle = input.fileHandleForReading, writeHandle = output.fileHandleForWriting
        let completion = done
        let result = outcome
        DispatchQueue.global().async {
            defer { completion.signal() }
            do { try server.run(input: readHandle, output: writeHandle) }
            catch {
                result.record(String(describing: error))
                if !expectsOutputFailure { XCTFail("Synthetic server run failed: \(error)") }
            }
        }
    }

    func send(_ request: JSONObject) throws {
        var bytes = try LocalJSON.encode(request); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    func tool(_ id: Any, _ name: String, _ arguments: JSONObject) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                  "params": ["name": name, "arguments": arguments] as JSONObject])
    }

    func receive(id: Any) throws -> JSONObject {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while received.firstIndex(of: 10) == nil {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN), revents: 0)
            guard DispatchTime.now().uptimeNanoseconds < deadline, poll(&descriptor, 1, 100) > 0 else {
                if DispatchTime.now().uptimeNanoseconds < deadline { continue }
                throw LocalMCPError.operationFailed("Metadata blocked behind synthetic Brevo transport")
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
            guard count > 0 else { throw LocalMCPError.operationFailed("Response stream ended") }
            received.append(contentsOf: buffer.prefix(count))
            guard received.count <= 1_048_576 else { throw LocalMCPError.operationFailed("Oversized fixture response") }
        }
        let newline = received.firstIndex(of: 10)!
        let frame = Data(received.prefix(upTo: newline)); received.removeSubrange(...newline)
        let response = try LocalJSON.decodeObject(frame)
        if let id = id as? Int { XCTAssertEqual(response["id"] as? Int, id) }
        if let id = id as? String { XCTAssertEqual(response["id"] as? String, id) }
        return response
    }

    func endInput() throws {
        if !inputClosed { try input.fileHandleForWriting.close(); inputClosed = true }
    }

    func closeResponseWriter() throws {
        if !outputClosed { try output.fileHandleForWriting.close(); outputClosed = true }
    }

    func finishAndDrain() throws -> [JSONObject] {
        try endInput()
        guard done.wait(timeout: .now() + 3) == .success else {
            throw LocalMCPError.operationFailed("Synthetic stdio did not finish")
        }
        done.signal()
        try closeResponseWriter()
        received.append(output.fileHandleForReading.readDataToEndOfFile())
        let frames = try received.split(separator: 10).map { try LocalJSON.decodeObject(Data($0)) }
        received.removeAll()
        return frames
    }

    func close() {
        try? endInput()
        _ = done.wait(timeout: .now() + 3)
        if !outputClosed { try? output.fileHandleForWriting.close(); outputClosed = true }
        try? output.fileHandleForReading.close(); try? input.fileHandleForReading.close()
    }
}

private final class BrevoDispatchOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var message: String { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; value = message }
}
