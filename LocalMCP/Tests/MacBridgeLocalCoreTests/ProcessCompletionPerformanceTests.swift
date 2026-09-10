import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class ProcessCompletionPerformanceTests: XCTestCase {
    func testRapidDualStreamExitPublishesFinalHashesBeforeStoppedStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = try makeProcesses(fixture)
        let stdoutBytes = Data(repeating: 0x78, count: 262_144)
        let stderrBytes = Data(repeating: 0x79, count: 262_144)
        let script = """
            import os, threading
            def write_all(fd, payload):
                while payload:
                    payload = payload[os.write(fd, payload):]
            a = threading.Thread(target=write_all, args=(1, b'x' * 262144))
            b = threading.Thread(target=write_all, args=(2, b'y' * 262144))
            a.start(); b.start(); a.join(); b.join()
            """

        for iteration in 0..<8 {
            let started = try processes.startCommand(
                workspaceID: fixture.workspaceID, executableID: "python3",
                arguments: ["-c", script], cwd: ".", maximumOutputBytes: 1_048_576
            )
            let taskID = try XCTUnwrap(started["task_id"] as? String)
            let stopped = try waitUntilStopped(processes, taskID: taskID)
            XCTAssertEqual(stopped["exit_code"] as? Int, 0, "iteration \(iteration)")
            XCTAssertEqual(stopped["stdout_total_bytes"] as? Int, stdoutBytes.count)
            XCTAssertEqual(stopped["stderr_total_bytes"] as? Int, stderrBytes.count)

            let output = try processes.processOutput(
                taskID: taskID, stdoutCursor: 0, stderrCursor: 0,
                maximumBytesPerStream: 1_048_576
            )
            let stdout = Data(try XCTUnwrap(output["stdout"] as? String).utf8)
            let stderr = Data(try XCTUnwrap(output["stderr"] as? String).utf8)
            XCTAssertEqual(LocalHash.sha256(stdout), LocalHash.sha256(stdoutBytes))
            XCTAssertEqual(LocalHash.sha256(stderr), LocalHash.sha256(stderrBytes))
            XCTAssertEqual(output["session_retained"] as? Bool, false)
            XCTAssertEqual(output["stdout_truncated"] as? Bool, false)
            XCTAssertEqual(output["stderr_truncated"] as? Bool, false)
            XCTAssertEqual(processes.trackedProcessCount, 0)
        }
    }

    func testRapidEmptyCommandsCompleteWithoutOutputOrRetainedSessions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = try makeProcesses(fixture)

        for _ in 0..<8 {
            let result = try processes.runCommand(
                workspaceID: fixture.workspaceID, executableID: "true", arguments: [],
                cwd: ".", timeoutMilliseconds: 5_000, maximumOutputBytes: 1_024
            )
            XCTAssertEqual(result["running"] as? Bool, false)
            XCTAssertEqual(result["exit_code"] as? Int, 0)
            XCTAssertEqual(result["stdout"] as? String, "")
            XCTAssertEqual(result["stderr"] as? String, "")
            XCTAssertEqual(result["timed_out"] as? Bool, false)
            XCTAssertEqual(result["cancelled"] as? Bool, false)
            XCTAssertEqual(processes.trackedProcessCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.workspace.appendingPathComponent(".macbridge").path
            ))
        }
    }

    func testCompletedStatusReadsLeaveOutputAndSessionUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = try makeProcesses(fixture)
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID, executableID: "sh",
            arguments: ["-c", "printf status-out; printf status-err >&2"],
            cwd: ".", maximumOutputBytes: 1_024
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        let stopped = try waitUntilStopped(processes, taskID: taskID)
        let expected = try LocalJSON.encode(stopped)
        let before = ProcessInfo.processInfo.systemUptime
        for _ in 0..<32 {
            XCTAssertEqual(try LocalJSON.encode(processes.processStatus(taskID: taskID)), expected)
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - before) * 1_000
        // Expose a useful benchmark datum without a host-load-sensitive pass threshold.
        print("MB_COMPLETED_STATUS_32_MILLISECONDS=\(milliseconds)")
        XCTAssertEqual(processes.trackedProcessCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.workspace.appendingPathComponent(".macbridge").path
        ))
        let output = try processes.processOutput(
            taskID: taskID, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 1_024
        )
        XCTAssertEqual(output["stdout"] as? String, "status-out")
        XCTAssertEqual(output["stderr"] as? String, "status-err")
        XCTAssertEqual(output["session_retained"] as? Bool, false)
    }

    func testDualStream64KiBTailsRemainBoundedAndDrainExactly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let processes = try makeProcesses(fixture)
        let tailLimit = 65_536
        let stdoutBytes = Data((String(repeating: "x", count: 1_048_576) + "OUT-END").utf8)
        let stderrBytes = Data((String(repeating: "y", count: 1_048_576) + "ERR-END").utf8)
        let script = """
            import os, threading
            def write_all(fd, payload):
                while payload:
                    payload = payload[os.write(fd, payload):]
            a = threading.Thread(target=write_all, args=(1, b'x' * 1048576 + b'OUT-END'))
            b = threading.Thread(target=write_all, args=(2, b'y' * 1048576 + b'ERR-END'))
            a.start(); b.start(); a.join(); b.join()
            """
        let started = try processes.startCommand(
            workspaceID: fixture.workspaceID, executableID: "python3",
            arguments: ["-c", script], cwd: ".", maximumOutputBytes: tailLimit
        )
        let taskID = try XCTUnwrap(started["task_id"] as? String)
        _ = try waitUntilStopped(processes, taskID: taskID)
        let output = try processes.processOutput(
            taskID: taskID, stdoutCursor: 0, stderrCursor: 0,
            maximumBytesPerStream: tailLimit
        )
        let stdout = Data(try XCTUnwrap(output["stdout"] as? String).utf8)
        let stderr = Data(try XCTUnwrap(output["stderr"] as? String).utf8)
        XCTAssertEqual(stdout, Data(stdoutBytes.suffix(tailLimit)))
        XCTAssertEqual(stderr, Data(stderrBytes.suffix(tailLimit)))
        XCTAssertEqual(output["stdout_available_bytes"] as? Int, tailLimit)
        XCTAssertEqual(output["stderr_available_bytes"] as? Int, tailLimit)
        XCTAssertEqual(output["stdout_total_bytes"] as? Int, stdoutBytes.count)
        XCTAssertEqual(output["stderr_total_bytes"] as? Int, stderrBytes.count)
        XCTAssertEqual(output["stdout_cursor_adjusted"] as? Bool, true)
        XCTAssertEqual(output["stderr_cursor_adjusted"] as? Bool, true)
        XCTAssertEqual(output["stdout_next_cursor"] as? Int, stdoutBytes.count)
        XCTAssertEqual(output["stderr_next_cursor"] as? Int, stderrBytes.count)
        XCTAssertEqual(output["session_retained"] as? Bool, false)
        XCTAssertEqual(processes.trackedProcessCount, 0)
    }

    private func waitUntilStopped(_ processes: LocalProcessService, taskID: String) throws -> JSONObject {
        let deadline = Date().addingTimeInterval(5)
        var status = try processes.processStatus(taskID: taskID)
        while status["running"] as? Bool == true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
            status = try processes.processStatus(taskID: taskID)
        }
        XCTAssertEqual(status["running"] as? Bool, false, "bounded process completion")
        return status
    }

    private func makeProcesses(_ fixture: Fixture) throws -> LocalProcessService {
        let binary = packageRoot().appendingPathComponent(".build/debug/macbridge-mcp")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("macbridge-mcp debug product is unavailable")
        }
        return LocalProcessService(workspaceService: try fixture.service(), selfExecutable: binary)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
