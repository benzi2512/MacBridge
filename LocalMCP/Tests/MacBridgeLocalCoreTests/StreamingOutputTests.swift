import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class StreamingOutputTests: XCTestCase {
    func testStreamingBoundaryOnlyDefersPotentiallyValidSuffixes() {
        for text in ["é", "€", "🙂", "\u{0080}", "\u{0800}", "\u{D7FF}", "\u{E000}", "\u{10000}", "\u{10FFFF}"] {
            let bytes = Data(text.utf8)
            for length in 1..<bytes.count {
                var partial = Data("ok".utf8)
                partial.append(bytes.prefix(length))
                XCTAssertEqual(streamingUTF8End(partial), 2, "\(text), prefix \(length)")
            }
            XCTAssertEqual(streamingUTF8End(bytes), bytes.count)
        }
        for bytes: [UInt8] in [[], [0x41], [0x80], [0xFF], [0xC0], [0xF5],
                               [0xE0, 0x80], [0xED, 0xA0], [0xF0, 0x80], [0xF4, 0x90],
                               [0xF0, 0x41], [0x80, 0x80, 0x80, 0x80]] {
            XCTAssertEqual(streamingUTF8End(Data(bytes)), bytes.count, "Invalid or complete bytes must progress")
        }
    }

    func testRetentionBudgetIsHardEvenWhenCutoffSplitsScalar() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try service(fixture)
        for (limit, text, expected) in [(1, "🙂", ""), (2, "🙂", ""), (3, "🙂", ""),
                                        (4, "🙂", "🙂"), (4, "A🙂B", "B")] {
            let result = try service.runCommand(workspaceID: fixture.workspaceID,
                executableID: "sh", arguments: ["-c", "printf '\(text)'"], cwd: ".",
                timeoutMilliseconds: 2000, maximumOutputBytes: limit)
            let output = try XCTUnwrap(result["stdout"] as? String)
            XCTAssertEqual(output, expected)
            XCTAssertLessThanOrEqual(output.utf8.count, limit)
            XCTAssertEqual(result["stdout_truncated"] as? Bool, text.utf8.count > limit)
            XCTAssertEqual(result["stdout_dropped_bytes"] as? Int, text.utf8.count - output.utf8.count)
        }
        XCTAssertEqual(service.trackedProcessCount, 0)
    }

    func testStdoutCursorWaitsForSplitScalar() throws {
        try checkSplitScalar(stderr: false)
    }

    func testStderrCursorWaitsForSplitScalar() throws {
        try checkSplitScalar(stderr: true)
    }

    private func checkSplitScalar(stderr: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try service(fixture)
        let started = try service.startCommand(workspaceID: fixture.workspaceID,
            executableID: stderr ? "sh" : "cat", arguments: stderr ? ["-c", "cat >&2"] : [],
            cwd: ".", maximumOutputBytes: 1024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? service.cancelProcess(taskID: id) }
        let stream = stderr ? "stderr" : "stdout"
        let prefix = Data([0x41, 0xF0, 0x9F]) // A + first half of the valid emoji below.
        _ = try service.processInput(taskID: id, content: prefix.base64EncodedString(),
                                     encoding: "base64", closeStdin: false)
        try waitForBytes(service, id, stream: stream, count: prefix.count)
        let first = try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0,
                                               maximumBytesPerStream: 1024)
        XCTAssertEqual(first[stream] as? String, "A")
        let next = try XCTUnwrap(first[stream + "_next_cursor"] as? Int)
        XCTAssertEqual(next, 1, "Do not advance into a scalar still arriving through the pipe")
        XCTAssertEqual(first["session_retained"] as? Bool, true)
        let peek = try service.outputTail(taskID: id, maximumBytes: 1024)
        XCTAssertEqual(peek[stream] as? String, "A")
        XCTAssertEqual(peek[stream + "_next_cursor"] as? Int, 1)
        let suffix = Data([0x99, 0x82, 0x42])
        _ = try service.processInput(taskID: id, content: suffix.base64EncodedString(),
                                     encoding: "base64", closeStdin: true)
        try waitForExit(service, id)
        let last = try service.processOutput(taskID: id, stdoutCursor: stderr ? 0 : next,
            stderrCursor: stderr ? next : 0, maximumBytesPerStream: 1024)
        XCTAssertEqual(last[stream] as? String, "🙂B")
        XCTAssertEqual(last[stream + "_next_cursor"] as? Int, 6)
        XCTAssertEqual(last["session_retained"] as? Bool, false)
        XCTAssertEqual(service.trackedProcessCount, 0)
    }

    func testEOFIncompleteBytesAreReturnedAndHandleDrains() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try service(fixture)
        let started = try service.startCommand(workspaceID: fixture.workspaceID,
            executableID: "cat", arguments: [], cwd: ".", maximumOutputBytes: 1024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? service.cancelProcess(taskID: id) }
        let bytes = Data([0x41, 0xF0, 0x9F])
        _ = try service.processInput(taskID: id, content: bytes.base64EncodedString(),
                                     encoding: "base64", closeStdin: true)
        try waitForExit(service, id)
        let result = try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0,
                                                maximumBytesPerStream: 1024)
        XCTAssertEqual(result["stdout"] as? String, String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(result["stdout_next_cursor"] as? Int, bytes.count)
        XCTAssertEqual(result["session_retained"] as? Bool, false)
        XCTAssertEqual(service.trackedProcessCount, 0)
    }

    private func service(_ fixture: Fixture) throws -> LocalProcessService {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return LocalProcessService(workspaceService: try fixture.service(),
                                   selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"))
    }

    private func waitForBytes(_ service: LocalProcessService, _ id: String,
                              stream: String, count: Int) throws {
        for _ in 0..<200 {
            if try service.processStatus(taskID: id)[stream + "_total_bytes"] as? Int == count { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Reviewed echo fixture did not produce its bounded prefix")
        throw LocalMCPError.operationFailed("fixture output deadline")
    }

    private func waitForExit(_ service: LocalProcessService, _ id: String) throws {
        for _ in 0..<200 {
            if try service.processStatus(taskID: id)["running"] as? Bool == false { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Reviewed echo fixture did not reach EOF")
        throw LocalMCPError.operationFailed("fixture exit deadline")
    }
}
