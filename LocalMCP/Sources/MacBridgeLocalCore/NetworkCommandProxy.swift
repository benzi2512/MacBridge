import Darwin
import Foundation

/// Per-command CONNECT relay. The child stays loopback-only in Seatbelt.
/// A random per-job credential, one fixed IPv4:port, two connections, bounded
/// headers/buffers and an expiry enforce scope; no system proxy, DNS or daemon.
/// This is TCP destination pinning, not HTTP/TLS hostname or payload inspection.
final class NetworkCommandProxy: @unchecked Sendable {
    typealias Dialer = @Sendable (String, Int, TimeInterval) throws -> Int32
    let port: UInt16
    let environment: [String: String]
    private let expectedAuthorization: String
    private let destination: String
    private let destinationPort: Int
    private let deadline: TimeInterval
    private let dialer: Dialer
    private let lock = NSLock()
    private var stopped = false
    private var ownedDescriptors: Set<Int32> = []
    private var clients = 0
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.macbridge.network-grant.accept", qos: .utility)
    private let ioQueue = DispatchQueue(label: "com.macbridge.network-grant.io", qos: .utility, attributes: .concurrent)

    init(grant: LocalNetworkGrant, dialerForTesting: Dialer? = nil) throws {
        let duration = try grant.remainingSeconds()
        destination = grant.ipv4; destinationPort = grant.port
        deadline = ProcessInfo.processInfo.systemUptime + duration
        dialer = dialerForTesting ?? Self.dial
        let password = UUID().uuidString + UUID().uuidString
        expectedAuthorization = "Basic " + Data("macbridge:\(password)".utf8).base64EncodedString()
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LocalMCPError.operationFailed("cannot create job-local relay") }
        var transferred = false
        defer { if !transferred { close(listener) } }
        guard Self.prepare(listener) else { throw LocalMCPError.operationFailed("relay descriptor setup failed") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 2) == 0 else { throw LocalMCPError.operationFailed("cannot bind job-local relay") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let obtained = withUnsafeMutablePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard obtained == 0 else { throw LocalMCPError.operationFailed("cannot inspect job-local relay") }
        port = UInt16(bigEndian: addr.sin_port)
        let proxy = "http://macbridge:\(password)@127.0.0.1:\(port)"
        environment = ["HTTPS_PROXY": proxy, "https_proxy": proxy, "ALL_PROXY": proxy,
            "all_proxy": proxy, "HTTP_PROXY": proxy, "http_proxy": proxy, "NO_PROXY": "", "no_proxy": ""]
        ownedDescriptors.insert(listener)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
        acceptSource = source
        source.setEventHandler { [weak self] in self?.acceptClients(listener) }
        // Cancellation runs after any accept handler on this serial queue.
        // Unlike shutdown(listeningSocket), it reliably closes on macOS even
        // when no client has connected. No idle accept polling is needed.
        source.setCancelHandler { [self] in release(listener) }
        transferred = true
        source.resume()
        // Even a launch failure or a caller forgetting its process handle may
        // not leave an authenticated egress service beyond this grant.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration) { [weak self] in self?.stop() }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        stopped = true
        // Workers close the descriptors they own. shutdown wakes blocking IO
        // without a cross-thread close/reuse race against unrelated descriptors.
        for fd in ownedDescriptors { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        acceptSource?.cancel()
    }

    private var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && ProcessInfo.processInfo.systemUptime < deadline
    }

    private func own(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { close(fd); return false }
        ownedDescriptors.insert(fd); return true
    }

    private func release(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        if ownedDescriptors.remove(fd) != nil { close(fd) }
    }

    private func acceptClients(_ listener: Int32) {
        while active {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; break }
            guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else { close(client); continue }
            lock.lock()
            let admitted = !stopped && clients < 2
            if admitted { clients += 1; ownedDescriptors.insert(client) }
            lock.unlock()
            if !admitted { close(client); continue }
            ioQueue.async { [self] in
                defer {
                    release(client)
                    lock.lock(); clients -= 1; lock.unlock()
                }
                serve(client)
            }
        }
    }

    private static func prepare(_ fd: Int32) -> Bool {
        var yes: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func ready(_ fd: Int32, _ events: Int16, until: TimeInterval) -> Bool {
        while active && ProcessInfo.processInfo.systemUptime < until {
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let count = poll(&entry, 1, 100)
            if count > 0 { return entry.revents & events != 0 }
            if count < 0 && errno != EINTR { return false }
        }
        return false
    }

    private func sendAll(_ data: Data, to fd: Int32) -> Bool {
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count, ready(fd, Int16(POLLOUT), until: until) {
                let count = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { return false }
            }
            return offset == raw.count
        }
    }

    static func accepts(header: String, destination: String, port: Int, authorization: String) -> Bool {
        let lines = header.components(separatedBy: "\r\n")
        guard ["CONNECT \(destination):\(port) HTTP/1.1", "CONNECT \(destination):\(port) HTTP/1.0"].contains(lines.first ?? "") else { return false }
        let values = lines.dropFirst().filter { $0.lowercased().hasPrefix("proxy-authorization:") }
        guard values.count == 1, let separator = values[0].firstIndex(of: ":") else { return false }
        let supplied = values[0][values[0].index(after: separator)...].trimmingCharacters(in: .whitespaces)
        let expected = Array(authorization.utf8), bytes = Array(supplied.utf8)
        guard bytes.count == expected.count else { return false }
        return zip(bytes, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func serve(_ client: Int32) {
        guard Self.prepare(client) else { return }
        var header = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        let delimiter = Data("\r\n\r\n".utf8)
        var boundary: Range<Data.Index>?
        while header.count < 8192, ready(client, Int16(POLLIN), until: until) {
            let count = recv(client, &buffer, min(buffer.count, 8192 - header.count), 0)
            guard count > 0 else { return }
            header.append(contentsOf: buffer.prefix(count))
            if let range = header.range(of: delimiter) { boundary = range; break }
        }
        guard let boundary, let text = String(data: header[..<boundary.lowerBound], encoding: .utf8),
              Self.accepts(header: text, destination: destination, port: destinationPort, authorization: expectedAuthorization), active else {
            _ = sendAll(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: client)
            return
        }
        guard let upstream = try? dialer(destination, destinationPort, min(deadline, ProcessInfo.processInfo.systemUptime + 3)) else { return }
        guard own(upstream) else { return }
        defer { release(upstream) }
        guard Self.prepare(upstream), sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: client) else { return }
        if boundary.upperBound < header.endIndex, !sendAll(Data(header[boundary.upperBound...]), to: upstream) { return }
        var pair = [pollfd(fd: client, events: Int16(POLLIN), revents: 0), pollfd(fd: upstream, events: Int16(POLLIN), revents: 0)]
        while active {
            let count = poll(&pair, 2, 200)
            if count < 0 { if errno == EINTR { continue }; return }
            for index in 0...1 {
                if pair[index].revents & Int16(POLLIN) != 0 {
                    let size = recv(pair[index].fd, &buffer, buffer.count, 0)
                    guard size > 0, sendAll(Data(buffer.prefix(size)), to: pair[1-index].fd) else { return }
                } else if pair[index].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
            }
        }
    }

    private static func dial(_ ipv4: String, _ port: Int, _ until: TimeInterval) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalMCPError.operationFailed("relay socket unavailable") }
        var keep = false
        defer { if !keep { close(fd) } }
        guard prepare(fd) else { throw LocalMCPError.operationFailed("relay socket setup failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, ipv4, &address.sin_addr) == 1 else { throw LocalMCPError.invalidRequest("invalid relay destination") }
        let connected = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw LocalMCPError.operationFailed("relay destination unavailable") }
            var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let remaining = max(0, min(3000, Int((until - ProcessInfo.processInfo.systemUptime) * 1000)))
            guard poll(&entry, 1, Int32(remaining)) > 0 else { throw LocalMCPError.operationFailed("relay connection timed out") }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw LocalMCPError.operationFailed("relay destination unavailable")
            }
        }
        keep = true; return fd
    }
}
