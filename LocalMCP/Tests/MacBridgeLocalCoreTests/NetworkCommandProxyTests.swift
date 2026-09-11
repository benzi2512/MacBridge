import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

/// Every upstream is a synthetic socketpair. No public service, credential or
/// user file is touched. Never include the ephemeral proxy URL in assertions.
final class NetworkCommandProxyTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    private func grant(seconds: Double = 10) -> LocalNetworkGrant {
        .init(id: UUID().uuidString, cwd: ".", ipv4: "203.0.113.10", port: 443,
              expiresAt: Date().addingTimeInterval(seconds))
    }
    private func connection(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalMCPError.operationFailed("test socket unavailable") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { close(fd); throw LocalMCPError.operationFailed("test listener unavailable") }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
    private func header(_ proxy: NetworkCommandProxy, target: String = "203.0.113.10:443") throws -> String {
        guard let raw = proxy.environment["HTTPS_PROXY"], let url = URLComponents(string: raw),
              let user = url.user, let password = url.password else {
            throw LocalMCPError.operationFailed("test grant not configured")
        }
        let authorization = Data("\(user):\(password)".utf8).base64EncodedString()
        return "CONNECT \(target) HTTP/1.1\r\nProxy-Authorization: Basic \(authorization)\r\n\r\n"
    }
    private func send(_ text: String, fd: Int32) throws {
        let data = Data(text.utf8)
        let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw LocalMCPError.operationFailed("test send failed") }
    }
    private func receive(_ fd: Int32, through marker: String = "\r\n\r\n") -> String {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline, result.count < 16_384 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) > 0 {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                result.append(contentsOf: buffer.prefix(n))
                if String(decoding: result, as: UTF8.self).contains(marker) { break }
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    func testHeaderRequiresOneCredentialAndExactNumericDestination() {
        let auth = "Basic synthetic-test-only"
        func accepts(_ value: String) -> Bool {
            NetworkCommandProxy.accepts(header: value, destination: "203.0.113.10", port: 443, authorization: auth)
        }
        XCTAssertTrue(accepts("CONNECT 203.0.113.10:443 HTTP/1.1\r\nProxy-Authorization: \(auth)"))
        for value in [
            "CONNECT 203.0.113.10:443 HTTP/1.1",
            "CONNECT 203.0.113.10:443 HTTP/1.1\r\nProxy-Authorization: wrong",
            "CONNECT 203.0.113.11:443 HTTP/1.1\r\nProxy-Authorization: \(auth)",
            "CONNECT 203.0.113.10:80 HTTP/1.1\r\nProxy-Authorization: \(auth)",
            "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: \(auth)",
            "GET http://203.0.113.10/ HTTP/1.1\r\nProxy-Authorization: \(auth)",
            "CONNECT 203.0.113.10:443 HTTP/1.1\r\nProxy-Authorization: \(auth)\r\nProxy-Authorization: \(auth)"
        ] { XCTAssertFalse(accepts(value)) }
    }

    func testWrongDestinationMissingCredentialAndOtherJobCredentialNeverDial() throws {
        let calls = Calls()
        let deny: NetworkCommandProxy.Dialer = { _, _, _ in
            calls.increment(); throw LocalMCPError.operationFailed("unexpected test dial")
        }
        let proxy = try NetworkCommandProxy(grant: grant(), dialerForTesting: deny)
        let other = try NetworkCommandProxy(grant: grant(), dialerForTesting: deny)
        defer { proxy.stop(); other.stop() }
        let requests = ["CONNECT 203.0.113.10:443 HTTP/1.1\r\n\r\n",
                        try header(proxy, target: "127.0.0.1:443"), try header(other)]
        for request in requests {
            let fd = try connection(proxy.port)
            try send(request, fd: fd)
            XCTAssertTrue(receive(fd).hasPrefix("HTTP/1.1 403"))
            close(fd)
        }
        XCTAssertEqual(calls.count, 0)
    }

    func testAuthorizedCONNECTRelaysBothDirectionsAndPinsUpstream() throws {
        let calls = Calls()
        let completed = expectation(description: "synthetic upstream echoed")
        let proxy = try NetworkCommandProxy(grant: grant()) { ip, port, _ in
            guard ip == "203.0.113.10", port == 443 else { throw LocalMCPError.operationFailed("wrong test destination") }
            calls.increment()
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw LocalMCPError.operationFailed("test pair failed") }
            let remote = pair[1]
            DispatchQueue.global().async {
                defer { close(remote); completed.fulfill() }
                var poller = pollfd(fd: remote, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 2000) > 0 else { return }
                var bytes = [UInt8](repeating: 0, count: 128)
                let n = recv(remote, &bytes, bytes.count, 0)
                if n > 0 { _ = bytes.withUnsafeBytes { Darwin.send(remote, $0.baseAddress, n, 0) } }
            }
            return pair[0]
        }
        defer { proxy.stop() }
        let fd = try connection(proxy.port); defer { close(fd) }
        try send(try header(proxy), fd: fd)
        XCTAssertTrue(receive(fd).hasPrefix("HTTP/1.1 200"))
        try send("synthetic payload complete", fd: fd)
        XCTAssertEqual(receive(fd, through: "complete"), "synthetic payload complete")
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(calls.count, 1)
    }

    func testStopClosesListenerAndIncompleteClients() throws {
        let calls = Calls()
        let proxy = try NetworkCommandProxy(grant: grant()) { _, _, _ in
            calls.increment(); throw LocalMCPError.operationFailed("unexpected test dial")
        }
        let fd = try connection(proxy.port); defer { close(fd) }
        try send("CONNECT incomplete", fd: fd)
        proxy.stop()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertThrowsError(try connection(proxy.port))
        XCTAssertEqual(receive(fd), "")
        XCTAssertEqual(calls.count, 0)
    }

    func testDeadlineClosesRelayEvenWithoutProcessHandle() throws {
        let proxy = try NetworkCommandProxy(grant: grant(seconds: 0.2)) { _, _, _ in
            throw LocalMCPError.operationFailed("no network in test")
        }
        defer { proxy.stop() }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertThrowsError(try connection(proxy.port))
    }

    func testHeadersAreBoundedAndCauseNoDial() throws {
        let calls = Calls()
        let proxy = try NetworkCommandProxy(grant: grant()) { _, _, _ in
            calls.increment(); throw LocalMCPError.operationFailed("unexpected test dial")
        }
        defer { proxy.stop() }
        let fd = try connection(proxy.port); defer { close(fd) }
        try send(String(repeating: "x", count: 8192), fd: fd)
        XCTAssertTrue(receive(fd).hasPrefix("HTTP/1.1 403"))
        XCTAssertEqual(calls.count, 0)
    }
}
