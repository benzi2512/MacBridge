import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class CompletedStatusTests: XCTestCase {
    func testCancelledStatusSurvivesWithoutRetainingOutputOrHandle() throws {
        let f = try Fixture()
        defer { f.remove() }
        let service = try makeService(f)
        let started = try service.startCommand(workspaceID: f.workspaceID, executableID: "cat", arguments: [], cwd: ".", maximumOutputBytes: 1024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        _ = try service.cancelProcess(taskID: id)
        let status = try service.processStatus(taskID: id.uppercased())
        XCTAssertEqual(status["cancelled"] as? Bool, true)
        XCTAssertEqual(status["running"] as? Bool, false)
        XCTAssertEqual(status["status_only"] as? Bool, true)
        XCTAssertEqual(status["session_retained"] as? Bool, false)
        XCTAssertNil(status["stdout"])
        XCTAssertNil(status["stderr"])
        XCTAssertEqual(service.trackedProcessCount, 0)
        XCTAssertEqual((service.processList()["processes"] as? [JSONObject])?.count, 0)
        XCTAssertThrowsError(try service.cancelProcess(taskID: id))
        XCTAssertThrowsError(try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 1024))
        XCTAssertThrowsError(try makeService(f).processStatus(taskID: id))
    }

    func testStatusCacheIsBoundedAndExpiryDoesNotRefreshOnRead() throws {
        let f = try Fixture()
        defer { f.remove() }
        var clock: TimeInterval = 100
        let service = try makeService(f, limit: 2, now: { clock })
        var ids: [String] = []
        for _ in 0..<3 {
            let result = try service.runCommand(workspaceID: f.workspaceID, executableID: "true", arguments: [], cwd: ".", timeoutMilliseconds: 5000, maximumOutputBytes: 1024)
            ids.append(try XCTUnwrap(result["task_id"] as? String))
        }
        XCTAssertThrowsError(try service.processStatus(taskID: ids[0]))
        XCTAssertEqual(try service.processStatus(taskID: ids[1])["exit_code"] as? Int, 0)
        XCTAssertEqual(service.trackedProcessCount, 0)
        clock = 109
        XCTAssertEqual(try service.processStatus(taskID: ids[2])["status_only"] as? Bool, true)
        clock = 110
        XCTAssertThrowsError(try service.processStatus(taskID: ids[1]))
        XCTAssertThrowsError(try service.processStatus(taskID: ids[2]))
        XCTAssertThrowsError(try service.processStatus(taskID: "invalid"))
    }

    func testDrainedCompletionRetainsOnlyMetadata() throws {
        let f = try Fixture()
        defer { f.remove() }
        let service = try makeService(f)
        let started = try service.startCommand(workspaceID: f.workspaceID, executableID: "true", arguments: [], cwd: ".", maximumOutputBytes: 1024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        for _ in 0..<200 {
            if try service.processStatus(taskID: id)["running"] as? Bool == false { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let drained = try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 1024)
        XCTAssertEqual(drained["session_retained"] as? Bool, false)
        let retained = try service.processStatus(taskID: id)
        XCTAssertEqual(retained["exit_code"] as? Int, 0)
        XCTAssertEqual(retained["cancelled"] as? Bool, false)
        XCTAssertEqual(retained["status_only"] as? Bool, true)
        XCTAssertNil(retained["stdout"])
    }

    private func makeService(_ f: Fixture, limit: Int = 2,
                             now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> LocalProcessService {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return LocalProcessService(workspaceService: try f.service(),
            selfExecutable: package.appendingPathComponent(".build/debug/macbridge-mcp"),
            outputByteLimit: 2048, completedStatusLimit: limit, completedStatusTTL: 10, monotonicNow: now)
    }
}
