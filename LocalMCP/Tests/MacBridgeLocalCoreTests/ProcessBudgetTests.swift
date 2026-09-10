import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ProcessBudgetTests: XCTestCase {
    func testBothStreamsReservedUntilConsumingDrainNotObserverPeek() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try processService(fixture)
        let id = try start(service, fixture)
        defer { _ = try? service.cancelProcess(taskID: id) }
        try waitForExit(service, id)
        XCTAssertThrowsError(try start(service, fixture)) {
            XCTAssertTrue(String(describing: $0).contains("aggregate process output"))
        }
        let peek = try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0,
                                            maximumBytesPerStream: 1024, consumeCompletedHandle: false)
        XCTAssertEqual(peek["session_retained"] as? Bool, true)
        XCTAssertThrowsError(try start(service, fixture))
        let drained = try service.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0,
                                               maximumBytesPerStream: 1024)
        XCTAssertEqual(drained["session_retained"] as? Bool, false)
        let replacement = try start(service, fixture)
        _ = try service.cancelProcess(taskID: replacement)
        XCTAssertEqual(service.trackedProcessCount, 0)
    }

    func testFailedStartCancelAndSynchronousCompletionReturnReservation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try processService(fixture)
        for _ in 0..<3 {
            XCTAssertThrowsError(try service.startCommand(workspaceID: fixture.workspaceID,
                executableID: "not-available", arguments: [], cwd: ".", maximumOutputBytes: 1024))
        }
        let id = try start(service, fixture)
        _ = try service.cancelProcess(taskID: id)
        XCTAssertThrowsError(try service.cancelProcess(taskID: id)) // no double release
        for _ in 0..<2 {
            let result = try service.runCommand(workspaceID: fixture.workspaceID,
                executableID: "true", arguments: [], cwd: ".", timeoutMilliseconds: 2000,
                maximumOutputBytes: 1024)
            XCTAssertEqual(result["exit_code"] as? Int, 0)
        }
        let replacement = try start(service, fixture)
        XCTAssertThrowsError(try start(service, fixture)) // accounting did not go negative
        _ = try service.cancelProcess(taskID: replacement)
    }

    func testOverBudgetAndInvalidRequestsHaveNoChildOrRuntimeSideEffects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try processService(fixture)
        for capacity in [0, -1, 1025, Int.max] {
            XCTAssertThrowsError(try service.startCommand(workspaceID: fixture.workspaceID,
                executableID: "true", arguments: [], cwd: ".", maximumOutputBytes: capacity))
        }
        XCTAssertEqual(service.trackedProcessCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).isEmpty)
        let id = try start(service, fixture)
        _ = try service.cancelProcess(taskID: id)
    }

    private func processService(_ f: Fixture) throws -> LocalProcessService {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = package.appendingPathComponent(".build/debug/macbridge-mcp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        return LocalProcessService(workspaceService: try f.service(), selfExecutable: binary,
                                   outputByteLimit: 2048)
    }

    private func start(_ service: LocalProcessService, _ f: Fixture) throws -> String {
        let result = try service.startCommand(workspaceID: f.workspaceID, executableID: "true",
                                             arguments: [], cwd: ".", maximumOutputBytes: 1024)
        return try XCTUnwrap(result["task_id"] as? String)
    }

    private func waitForExit(_ service: LocalProcessService, _ id: String) throws {
        for _ in 0..<100 {
            if try service.processStatus(taskID: id)["running"] as? Bool == false { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Synthetic child did not finish within two seconds")
    }
}
