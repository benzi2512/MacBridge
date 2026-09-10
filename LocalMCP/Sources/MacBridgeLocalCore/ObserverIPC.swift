import Darwin
import Foundation

/// An opt-in, same-user local channel. No TCP, authentication token or owner startup.
public enum ObserverSocket {
    public static let responseLimit = 1_048_576
    public static func validateDirectory(_ path: String) throws {
        var s = stat()
        guard path.hasPrefix("/"), lstat(path, &s) == 0,
              s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
              s.st_mode & 0o777 == 0o700 else {
            throw LocalMCPError.invalidPath("observer directory must be an existing owned 0700 directory")
        }
        guard let real = realpath(path, nil) else { throw LocalMCPError.invalidPath("observer directory") }
        defer { free(real) }
        guard String(cString: real) == path else { throw LocalMCPError.invalidPath("observer directory must be canonical") }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalMCPError.invalidPath("observer socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw LocalMCPError.invalidRequest("observer peer UID mismatch")
        }
    }

    static func readFrame(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, min(bytes.count, limit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LocalMCPError.operationFailed("observer disconnected or timed out") }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= limit else { throw LocalMCPError.invalidRequest("observer frame too large") }
            if let end = data.firstIndex(of: 10) { return Data(data.prefix(upTo: end)) }
        }
    }

    static func sendFrame(_ fd: Int32, data: Data, limit: Int) throws {
        guard data.count <= limit else { throw LocalMCPError.invalidRequest("observer response too large") }
        let framed = data + Data([10])
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw LocalMCPError.operationFailed("observer write timed out") }
                offset += n
            }
        }
    }

    public static func request(directory: String, payload: Data) throws -> Data {
        try validateDirectory(directory)
        let path = directory + "/observer.sock"
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == getuid(), status.st_mode & 0o777 == 0o600 else {
            throw LocalMCPError.invalidPath("no compatible private observer endpoint; core is not started by this UI")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalMCPError.operationFailed("observer socket unavailable") }
        defer { close(fd) }
        configure(fd)
        var addr = try address(path)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw LocalMCPError.operationFailed("observer owner offline") }
        try verifyPeer(fd)
        try sendFrame(fd, data: payload, limit: 4096)
        return try readFrame(fd, limit: responseLimit)
    }
}

// Serialize cooperating owners without a persistent lock file. The directory
// descriptor also anchors cleanup so renaming/replacing the path cannot redirect
// an unlink into a different directory. A private receipt identifies sockets
// created by lease-aware cores, allowing crash recovery within the same boot.
final class ObserverEndpointLease {
    private(set) var fd: Int32
    private let directory: String
    private let identity: stat
    private static let receiptName = "observer-owner.json"

    private struct SocketReceipt: Codable, Equatable {
        let version: Int
        let device: Int64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        init(_ value: stat) {
            version = 1; device = Int64(value.st_dev); inode = UInt64(value.st_ino)
            birthSeconds = Int64(value.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        }
    }

    private func readReceipt() -> SocketReceipt? {
        let file = openat(fd, Self.receiptName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & 0o7777 == 0o600,
              let bytes = try? LocalFileReader.read(descriptor: file, maximumBytes: 512),
              let receipt = try? JSONDecoder().decode(SocketReceipt.self, from: bytes),
              receipt.version == 1 else { return nil }
        return receipt
    }

    // The receipt carries no credential or PID. Exclusive creation preserves
    // unexpected files; only a validated receipt belonging to this socket is removed.
    func recordSocket(_ status: stat) throws {
        try Self.validatePrivateSocket(status)
        try verifyDirectory()
        let bytes = try JSONEncoder().encode(SocketReceipt(status))
        let file = openat(fd, Self.receiptName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw LocalMCPError.conflict("observer recovery receipt unavailable") }
        defer { close(file) }
        let written = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(file) == 0 else {
            throw LocalMCPError.operationFailed("observer recovery receipt could not be saved")
        }
    }

    private func removeReceipt(matching status: stat) {
        if readReceipt() == SocketReceipt(status) { _ = unlinkat(fd, Self.receiptName, 0) }
    }

    init(directory: String) throws {
        try ObserverSocket.validateDirectory(directory)
        let descriptor = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalMCPError.invalidPath("observer directory could not be opened safely") }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_uid == getuid(), opened.st_mode & 0o777 == 0o700 else {
            close(descriptor)
            throw LocalMCPError.invalidPath("observer directory identity unavailable")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LocalMCPError.conflict("another observer owner holds the endpoint directory")
        }
        fd = descriptor
        self.directory = directory
        identity = opened
        do { try verifyDirectory() }
        catch { release(); throw error }
    }

    deinit { release() }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    func verifyDirectory() throws {
        try ObserverSocket.validateDirectory(directory)
        var current = stat()
        guard fd >= 0, lstat(directory, &current) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw LocalMCPError.conflict("observer directory changed during endpoint startup")
        }
    }

    static func validatePrivateSocket(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o600 else {
            throw LocalMCPError.conflict("existing observer path is not an owned private socket; not replaced")
        }
    }

    private static func systemBootTime() throws -> timespec {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, boot.tv_sec > 0 else {
            throw LocalMCPError.conflict("system boot time unavailable; existing observer socket not replaced")
        }
        return timespec(tv_sec: boot.tv_sec, tv_nsec: Int(boot.tv_usec) * 1000)
    }

    // bootTime is internal test injection only; production uses kern.boottime.
    func prepareSocket(bootTime: timespec? = nil) throws {
        try verifyDirectory()
        var before = stat()
        if fstatat(fd, "observer.sock", &before, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw LocalMCPError.conflict("observer endpoint cannot be inspected; not replaced") }
            // A crash between socket unlink and receipt unlink can leave only
            // our valid metadata. Unknown files and symlinks remain untouched.
            if readReceipt() != nil { _ = unlinkat(fd, Self.receiptName, 0) }
            return
        }
        try Self.validatePrivateSocket(before)
        let boot = try bootTime ?? Self.systemBootTime()
        let birth = before.st_birthtimespec
        let predatesBoot = boot.tv_sec > 0 && birth.tv_sec > 0
            && (birth.tv_sec < boot.tv_sec || birth.tv_sec == boot.tv_sec && birth.tv_nsec < boot.tv_nsec)
        guard predatesBoot || readReceipt() == SocketReceipt(before) else {
            throw LocalMCPError.conflict("existing observer socket has no recoverable owner identity; not replaced")
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw LocalMCPError.operationFailed("observer liveness probe unavailable") }
        defer { close(probe) }
        ObserverSocket.configure(probe)
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
            throw LocalMCPError.conflict("observer liveness probe could not be bounded; not replaced")
        }
        var address = try ObserverSocket.address(directory + "/observer.sock")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let probeError = errno
        // Success means an owner is alive. EINPROGRESS/EAGAIN and every other
        // error are ambiguous, including permission errors: preserve the path.
        guard result == -1, probeError == ECONNREFUSED else {
            throw LocalMCPError.conflict("existing observer socket is live or ambiguous; not replaced")
        }
        try verifyDirectory()
        var after = stat()
        guard fstatat(fd, "observer.sock", &after, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec,
              before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec else {
            throw LocalMCPError.conflict("observer socket identity changed during probe; not replaced")
        }
        try Self.validatePrivateSocket(after)
        guard unlinkat(fd, "observer.sock", 0) == 0 else {
            throw LocalMCPError.operationFailed("stale observer socket could not be removed")
        }
        removeReceipt(matching: after)
    }

    func removeSocket(matching inode: ino_t) {
        var status = stat()
        if fd >= 0, fstatat(fd, "observer.sock", &status, AT_SYMLINK_NOFOLLOW) == 0,
           status.st_ino == inode, (try? Self.validatePrivateSocket(status)) != nil {
            if unlinkat(fd, "observer.sock", 0) == 0 { removeReceipt(matching: status) }
        }
    }

    // Only setup failure may remove the exact socket just created by bind
    // before chmod has established 0600. Never relax normal-stop cleanup.
    func removeNewlyBoundSocket(matching created: stat) {
        var current = stat()
        guard fd >= 0, created.st_mode & S_IFMT == S_IFSOCK, created.st_uid == getuid(),
              fstatat(fd, "observer.sock", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == getuid(),
              current.st_dev == created.st_dev, current.st_ino == created.st_ino,
              current.st_birthtimespec.tv_sec == created.st_birthtimespec.tv_sec,
              current.st_birthtimespec.tv_nsec == created.st_birthtimespec.tv_nsec else { return }
        _ = unlinkat(fd, "observer.sock", 0)
    }
}

public final class LocalObserverEndpoint: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let inode: ino_t
    private let endpointLease: ObserverEndpointLease
    private let server: LocalMCPServer
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var stopped = false

    public init(directory: String, server: LocalMCPServer) throws {
        let lease = try ObserverEndpointLease(directory: directory)
        try lease.prepareSocket()
        endpointLease = lease
        path = directory + "/observer.sock"
        self.server = server
        var address = try ObserverSocket.address(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LocalMCPError.operationFailed("observer listener unavailable") }
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(listener)
            throw LocalMCPError.conflict("observer endpoint already exists or cannot bind; not replaced")
        }
        var status = stat()
        guard fstatat(lease.fd, "observer.sock", &status, AT_SYMLINK_NOFOLLOW) == 0,
              status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == getuid() else {
            close(listener)
            throw LocalMCPError.operationFailed("observer endpoint identity unavailable")
        }
        guard chmod(path, 0o600) == 0, listen(listener, 4) == 0 else {
            close(listener); lease.removeNewlyBoundSocket(matching: status)
            throw LocalMCPError.operationFailed("observer listener setup failed")
        }
        // Receipt failure must not break a healthy channel. Recovery remains
        // fail-closed for an unrecorded same-boot socket, and the warning is explicit.
        if fstatat(lease.fd, "observer.sock", &status, AT_SYMLINK_NOFOLLOW) == 0 {
            do { try lease.recordSocket(status) }
            catch { FileHandle.standardError.write(Data("MACBRIDGE_OBSERVER_RECOVERY_RECEIPT_UNAVAILABLE\n".utf8)) }
        }
        inode = status.st_ino
        fd = listener
        ObserverSocket.configure(listener)
        finished.enter()
        DispatchQueue(label: "macbridge.observer").async { [self] in
            defer { finished.leave() }
            while true {
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { break }
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&item, 1, 250) <= 0 { continue }
                let peer = accept(fd, nil, nil)
                if peer < 0 { continue }
                ObserverSocket.configure(peer)
                serve(peer)
                close(peer)
            }
        }
    }

    private func serve(_ peer: Int32) {
        do {
            try ObserverSocket.verifyPeer(peer)
            let data = try ObserverSocket.readFrame(peer, limit: 4096)
            guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
                throw LocalMCPError.invalidRequest("observer request must be an object")
            }
            let result = try server.observerRequest(object)
            let response = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
            try ObserverSocket.sendFrame(peer, data: response, limit: ObserverSocket.responseLimit)
        } catch {
            let text = (error as? LocalMCPError)?.description ?? "Observer request failed"
            if let response = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": String(text.prefix(512))]) {
                try? ObserverSocket.sendFrame(peer, data: response, limit: ObserverSocket.responseLimit)
            }
        }
    }

    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        _ = shutdown(fd, SHUT_RDWR)
        finished.wait()
        close(fd)
        endpointLease.removeSocket(matching: inode)
        endpointLease.release()
    }
}
