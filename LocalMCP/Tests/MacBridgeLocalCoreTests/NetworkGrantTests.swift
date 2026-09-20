import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class NetworkGrantTests: XCTestCase {
    private func grant(ip: String = "203.0.113.10", port: Int = 443, cwd: String = ".",
                       expiry: Date = Date().addingTimeInterval(60)) -> LocalNetworkGrant {
        LocalNetworkGrant(id: "aaaaaaaa-1111-4222-8333-444444444444", cwd: cwd,
            ipv4: ip, port: port, expiresAt: expiry)
    }
    private func service(_ f: Fixture, grants: [LocalNetworkGrant]) throws -> LocalWorkspaceService {
        LocalWorkspaceService(registry: try LocalWorkspaceRegistry(configuration:
            LocalWorkspaceConfiguration(workspaces: [.init(id: f.workspaceID, name: "fixture", path: f.workspace.path, networkGrants: grants)])))
    }
    private func binary() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/macbridge-mcp")
        return try XCTUnwrap(FileManager.default.isExecutableFile(atPath: url.path) ? url : nil,
                             "Build the actual candidate before process qualification")
    }

    func testGrantSerializationPinsExactAddressPortScopeAndExpiry() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let g = grant(expiry: expiry)
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(LocalNetworkGrant.self, from: data)
        XCTAssertEqual(g, decoded)
        let rule = LocalNetworkGrant.sandboxRule(proxyPort: 54321)
        XCTAssertEqual(rule, "(allow network-outbound (remote tcp \"localhost:54321\"))")
        XCTAssertFalse(rule.contains("*"))
    }

    func testPrivateWildcardHostnameMalformedOrInjectedTargetsAreRejected() throws {
        for ip in ["0.0.0.0", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254",
                   "100.64.0.1", "198.18.0.1", "224.0.0.1", "255.255.255.255", "example.com", "::1",
                   "203.0.113.*", "203.0.113.010", "203.0.113.256", "1.2.3.4\") (allow default)", "1.2.3.4\n"] {
            XCTAssertThrowsError(try grant(ip: ip).validateShape(), ip)
        }
        XCTAssertThrowsError(try grant(port: 0).validateShape())
        XCTAssertThrowsError(try grant(port: 65536).validateShape())
    }

    func testExpiredAndOverlongGrantIsNotRenewedByUse() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for delta in [-1.0, 0, 3601] { XCTAssertThrowsError(try grant(expiry: now.addingTimeInterval(delta)).remainingSeconds(now: now)) }
        XCTAssertEqual(try grant(expiry: now.addingTimeInterval(60)).remainingSeconds(now: now), 60)
    }

    func testMissingGrantWrongWorkspaceAndTraversalNeverStartProcess() throws {
        let f = try Fixture(); defer { f.remove() }
        let w = try service(f, grants: [])
        let p = LocalProcessService(workspaceService: w, selfExecutable: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertThrowsError(try p.startNetworkCommand(workspaceID: f.workspaceID, grantID: grant().id,
            executableID: "sh", arguments: ["-c", "true"], maximumOutputBytes: 1024))
        XCTAssertEqual(p.trackedProcessCount, 0)
        let escaped = try service(f, grants: [grant(cwd: "../")])
        XCTAssertThrowsError(try LocalNetworkGrant.resolve(id: grant().id,
            workspace: escaped.registry.workspace(id: f.workspaceID), service: escaped))
    }

    func testDuplicateGrantsAreRejectedAtConfigurationLoad() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertThrowsError(try service(f, grants: [grant(), grant()]))
    }

    func testActualSandboxProfileRetainsCredentialAndGUIRestrictions() throws {
        let f = try Fixture(); defer { f.remove() }
        let g = grant(), w = try service(f, grants: [g])
        let p = LocalProcessService(workspaceService: w, selfExecutable: try binary())
        let result = try p.startNetworkCommand(workspaceID: f.workspaceID, grantID: g.id,
            executableID: "cat", arguments: [], maximumOutputBytes: 1024)
        let id = try XCTUnwrap(result["task_id"] as? String)
        defer { _ = try? p.cancelProcess(taskID: id) }
        Thread.sleep(forTimeInterval: 0.15)
        let running = try p.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 4096)
        XCTAssertEqual(running["running"] as? Bool, true, String(describing: running))
        let profile = try String(contentsOf: f.workspace.appendingPathComponent(".macbridge/runtime/\(id)/command.sb"), encoding: .utf8)
        XCTAssertTrue(profile.contains("(allow network-outbound (remote tcp \"localhost:"))
        XCTAssertFalse(profile.contains("localhost:*"))
        XCTAssertFalse(profile.contains(g.ipv4))
        XCTAssertTrue(profile.contains("(deny appleevent-send)"))
        XCTAssertTrue(profile.contains("(literal \"/usr/bin/open\")"))
        XCTAssertTrue(profile.contains("(literal \"/usr/bin/sudo\")"))
        XCTAssertTrue(profile.contains(LocalFilesystemAccess.sandboxDenyRules()))
        XCTAssertFalse(profile.contains("(literal \"/usr/bin/curl\")"))
        XCTAssertFalse(profile.contains("(allow network*)"))
        XCTAssertEqual(result["network_grant_id"] as? String, g.id)
    }

    func testOrdinaryCommandsDoNotInheritConfiguredNetworkGrant() throws {
        let f = try Fixture(); defer { f.remove() }
        let g = grant(), w = try service(f, grants: [g])
        let p = LocalProcessService(workspaceService: w, selfExecutable: try binary())
        let started = try p.startCommand(workspaceID: f.workspaceID, executableID: "cat", arguments: [], cwd: ".", maximumOutputBytes: 1024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? p.cancelProcess(taskID: id) }
        let profile = try String(contentsOf: f.workspace.appendingPathComponent(".macbridge/runtime/\(id)/command.sb"), encoding: .utf8)
        XCTAssertTrue(profile.contains("localhost:*"))
        XCTAssertFalse(profile.contains(g.ipv4))
        XCTAssertTrue(profile.contains("(literal \"/usr/bin/curl\")"))
    }

    func testExpiredGrantStopsItsRealProcessWithoutAnInternetRequest() throws {
        let f = try Fixture(); defer { f.remove() }
        let g = grant(expiry: Date().addingTimeInterval(0.6))
        let w = try service(f, grants: [g]), executable = try binary()
        let p = LocalProcessService(workspaceService: w, selfExecutable: executable)
        let started = try p.startNetworkCommand(workspaceID: f.workspaceID, grantID: g.id,
            executableID: "sleep", arguments: ["30"], maximumOutputBytes: 1024)
        let id = try XCTUnwrap(started["task_id"] as? String)
        defer { _ = try? p.cancelProcess(taskID: id) }
        Thread.sleep(forTimeInterval: 1.2)
        let status = try p.processStatus(taskID: id)
        XCTAssertEqual(status["running"] as? Bool, false)
        let output = try p.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 4096)
        XCTAssertEqual(status["cancelled"] as? Bool, true, String(describing: output))
    }

    func testRealChildReachesItsProxyButWrongDestinationIsRefused() throws {
        let f = try Fixture(); defer { f.remove() }
        let g = grant(), w = try service(f, grants: [g])
        let p = LocalProcessService(workspaceService: w, selfExecutable: try binary())
        // Destination differs from the owner pin: the local relay must answer
        // 403 before any upstream socket is created. No Internet request.
        let start = try p.startNetworkCommand(workspaceID: f.workspaceID, grantID: g.id,
            executableID: "sh", arguments: ["-c", "/usr/bin/curl --silent --show-error --max-time 2 https://203.0.113.11/"], maximumOutputBytes: 4096)
        let id = try XCTUnwrap(start["task_id"] as? String)
        defer { _ = try? p.cancelProcess(taskID: id) }
        for _ in 0..<4 {
            if try p.observeProcess(taskID: id, maximumWaitMilliseconds: 1000)["running"] as? Bool == false { break }
        }
        let output = try p.processOutput(taskID: id, stdoutCursor: 0, stderrCursor: 0, maximumBytesPerStream: 4096)
        XCTAssertEqual(output["running"] as? Bool, false)
        XCTAssertNotEqual(output["exit_code"] as? Int, 0)
        XCTAssertTrue((output["stderr"] as? String ?? "").contains("403"), String(describing: output))
        XCTAssertEqual(output["network"] as? String, "pinned_destination_via_job_local_proxy")
        XCTAssertEqual(output["network_grant_id"] as? String, g.id)
        XCTAssertFalse(String(describing: output).contains("macbridge:"))
        let retained = try p.processStatus(taskID: id)
        XCTAssertEqual(retained["network_grant_id"] as? String, g.id)
    }
}
