import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class MediaDispatchTests: XCTestCase {
    func testSlowMediaDoesNotBlockOtherChatsOrQueueAnotherUpload() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let held = MediaHeldHTTP()
        let server = try makeServer(f, held), io = MediaStdioConnection(server)
        defer { held.release.signal(); io.close() }
        try io.tool(1, "media_share", publish(f))
        XCTAssertEqual(held.entered.wait(timeout: .now() + 2), .success)
        let start = DispatchTime.now().uptimeNanoseconds
        try io.tool(2, "bridge_capabilities", [:])
        let capabilities = try io.structured(id: 2)
        XCTAssertEqual(capabilities["active_media_calls"] as? Int, 1)
        XCTAssertEqual(capabilities["catalog_count"] as? Int, 77)
        try io.tool(3, "media_share", publish(f))
        XCTAssertEqual(try io.receive(3)["isError"] as? Bool, true)
        XCTAssertThrowsError(try server.callTool(name: "media_inspect", arguments: ["action": "capabilities"]))
        try io.tool(4, "workspace_reload", [:])
        XCTAssertEqual(try io.receive(4)["isError"] as? Bool, true)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, 1_000)
        let snapshot = try server.observerRequest(["action": "snapshot"])
        XCTAssertEqual(snapshot["busy"] as? Bool, true)
        XCTAssertEqual(snapshot["snapshot_stale"] as? Bool, false)
        XCTAssertEqual(held.calls, 1)
        held.release.signal()
        XCTAssertEqual(try io.structured(id: 1)["share_state"] as? String, "ready")
        try io.tool(5, "bridge_capabilities", [:])
        XCTAssertEqual(try io.structured(id: 5)["active_media_calls"] as? Int, 0)
        XCTAssertTrue(try io.drain().isEmpty)
    }
    func testUncertainUploadSurvivesEOFAndHasOuterErrorFlagWithoutReplay() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let held = MediaHeldHTTP(failPUT: true), server = try makeServer(f, held), io = MediaStdioConnection(server)
        defer { held.release.signal(); io.close() }
        try io.tool(1, "media_share", publish(f))
        XCTAssertEqual(held.entered.wait(timeout: .now() + 2), .success)
        try io.endInput(); held.release.signal()
        let result = try io.receive(1)
        XCTAssertEqual(result["isError"] as? Bool, true)
        let body = try XCTUnwrap(result["structuredContent"] as? JSONObject)
        XCTAssertEqual(body["share_state"] as? String, "outcome_unknown"); XCTAssertNil(body["media_url"])
        XCTAssertEqual(held.calls, 1); XCTAssertTrue(try io.drain().isEmpty)
        XCTAssertEqual(try server.callTool(name: "bridge_capabilities", arguments: [:])["active_media_calls"] as? Int, 0)
    }
    func testObserverAndParentNeverRetainSignedURLOrCredentials() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let server = try LocalMCPServer(configurationURL: f.base.config, selfExecutable: f.base.config,
            connectorSurface: .webTunnel, observationEnabled: true, searchStartForTesting: nil,
            mediaConfigurationURLForTesting: f.config, mediaTransportForTesting: f.http.run)
        let begun = try server.callTool(name: "work_task", arguments: ["action": "begin", "title": "Fixture media"])
        let parent = try XCTUnwrap(begun["work_id"] as? String)
        let token = try XCTUnwrap(begun["work_control_token"] as? String)
        var args = publish(f); args["work_id"] = parent; args["work_control_token"] = token
        let result = try server.callTool(name: "media_share", arguments: args)
        XCTAssertNotNil(result["media_url"])
        let text = String(decoding: try LocalJSON.encode(server.observerRequest(["action": "snapshot"])), as: UTF8.self)
        for secret in ["X-Amz", f.secret, f.access, "media_url"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(result["work_id"] as? String, parent)
        XCTAssertEqual(try server.callTool(name: "work_task", arguments: [
            "action": "finish", "work_id": parent, "work_control_token": token,
        ])["state"] as? String, "completed")
    }
    func testUnconfiguredSharingIsClosedButLocalPrepareStillWorks() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let server = try LocalMCPServer(configurationURL: f.base.config, selfExecutable: f.base.config,
            connectorSurface: .webTunnel, searchStartForTesting: nil,
            mediaConfigurationURLForTesting: f.base.root.appendingPathComponent("missing-config"),
            mediaTransportForTesting: { _,_ in XCTFail("Disabled means no transport"); throw URLError(.unknown) })
        XCTAssertThrowsError(try server.callTool(name: "media_share", arguments: publish(f)))
        XCTAssertEqual(try server.callTool(name: "media_inspect", arguments: ["action": "prepare", "workspace_id": f.base.workspaceID, "path": "creative.png"])["sha256"] as? String, f.sha)
        XCTAssertEqual(try server.callTool(name: "bridge_capabilities", arguments: [:])["active_media_calls"] as? Int, 0)
    }
    func testMediaSchemaSeparatesReadAndWriteAndDeniesCallerNetworkBinding() throws {
        let specs = LocalMCPServer.toolSpecs
        for name in ["media_inspect", "media_share"] {
            let spec = try XCTUnwrap(specs.first { $0["name"] as? String == name })
            let annotations = try XCTUnwrap(spec["annotations"] as? JSONObject)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, name == "media_inspect")
            XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
            let schema = try XCTUnwrap(spec["inputSchema"] as? JSONObject)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? JSONObject)
            for forbidden in ["endpoint", "bucket", "access_key_id", "secret_access_key", "media_url", "command"] { XCTAssertNil(properties[forbidden]) }
            XCTAssertNotNil(properties["work_id"])
            XCTAssertEqual(ToolDiscovery.category(for: name), "external")
        }
    }
    private func publish(_ f: MediaFixture) -> JSONObject {
        ["action": "publish", "workspace_id": f.base.workspaceID, "request_id": f.id,
         "path": "creative.png", "expected_sha256": f.sha, "confirm_public_link": true]
    }
    private func makeServer(_ f: MediaFixture, _ held: MediaHeldHTTP) throws -> LocalMCPServer {
        try LocalMCPServer(configurationURL: f.base.config, selfExecutable: f.base.config, connectorSurface: .webTunnel,
            observationEnabled: true, searchStartForTesting: nil, mediaConfigurationURLForTesting: f.config,
            mediaTransportForTesting: held.run)
    }
}

private final class MediaHeldHTTP: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(), fake = MediaFakeHTTP()
    private var count = 0
    private let failPUT: Bool
    init(failPUT: Bool = false) { self.failPUT = failPUT }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func run(_ request: URLRequest, _ file: URL?) throws -> MediaHTTPReply {
        lock.lock(); count += 1; lock.unlock()
        if request.httpMethod == "PUT" {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            if failPUT { throw URLError(.networkConnectionLost) }
        }
        return try fake.run(request, file)
    }
}

private final class MediaStdioConnection {
    private let input = Pipe(), output = Pipe(), done = DispatchSemaphore(value: 0)
    private var bytes = Data(), closed = false, drained = false
    init(_ server: LocalMCPServer) {
        let read = input.fileHandleForReading, write = output.fileHandleForWriting, completion = done
        DispatchQueue.global().async {
            defer { completion.signal() }
            do { try server.run(input: read, output: write) } catch { XCTFail("Synthetic stdio failed") }
        }
    }
    func tool(_ id: Int, _ name: String, _ args: JSONObject) throws {
        var data = try LocalJSON.encode(["jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": args] as JSONObject]); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func receive(_ id: Int) throws -> JSONObject {
        let until = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while bytes.firstIndex(of: 10) == nil {
            var p = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard DispatchTime.now().uptimeNanoseconds < until else { throw URLError(.timedOut) }
            if poll(&p, 1, 100) <= 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let n = Darwin.read(p.fd, &buffer, buffer.count)
            guard n > 0, bytes.count + n <= 1_048_576 else { throw URLError(.cannotDecodeRawData) }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        let end = bytes.firstIndex(of: 10)!, frame = Data(bytes.prefix(upTo: end)); bytes.removeSubrange(...end)
        let r = try LocalJSON.decodeObject(frame); XCTAssertEqual(r["id"] as? Int, id)
        return try XCTUnwrap(r["result"] as? JSONObject)
    }
    func structured(id: Int) throws -> JSONObject {
        let r = try receive(id); XCTAssertEqual(r["isError"] as? Bool, false)
        return try XCTUnwrap(r["structuredContent"] as? JSONObject)
    }
    func endInput() throws { if !closed { try input.fileHandleForWriting.close(); closed = true } }
    func drain() throws -> Data {
        try endInput(); guard done.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
        done.signal(); try output.fileHandleForWriting.close(); drained = true
        bytes.append(output.fileHandleForReading.readDataToEndOfFile()); return bytes
    }
    func close() {
        try? endInput(); _ = done.wait(timeout: .now() + 3)
        if !drained { try? output.fileHandleForWriting.close() }
        try? output.fileHandleForReading.close(); try? input.fileHandleForReading.close()
    }
}
