import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

// Only fresh owned 0700 fixtures under /private/tmp. No real owner directory,
// core process, credentials, TCP listener, boot metadata changes, or GUI access.
final class ObserverEndpointRecoveryTests: XCTestCase {
    func testRecordedSameBootCrashCanRecoverAndClearsOnlyItsReceipt() throws {
        try withDirectory { directory in
            let lease = try ObserverEndpointLease(directory: directory)
            let socketFD = try boundSocket(directory)
            try lease.recordSocket(try socketIdentity(directory))
            close(socketFD) // Simulate a closed listener whose process left its socket.
            lease.release()
            let next = try ObserverEndpointLease(directory: directory)
            defer { next.release() }
            try next.prepareSocket(bootTime: timespec(tv_sec: 1, tv_nsec: 0))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), [])
        }
    }

    func testReceiptCannotAuthorizeRemovalOfLiveOrReplacedSocket() throws {
        try withDirectory { directory in
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            let socketFD = try boundSocket(directory, listening: true)
            try lease.recordSocket(try socketIdentity(directory))
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: timespec(tv_sec: 1, tv_nsec: 0)))
            close(socketFD)
            try FileManager.default.moveItem(atPath: directory + "/observer.sock", toPath: directory + "/old.sock")
            let replacement = try boundSocket(directory)
            close(replacement)
            let identity = try socketIdentity(directory)
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: timespec(tv_sec: 1, tv_nsec: 0)))
            XCTAssertEqual(try socketIdentity(directory).st_ino, identity.st_ino)
        }
    }

    func testInvalidReceiptAndReceiptSymlinkPreserveUnknownState() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            let receipt = URL(fileURLWithPath: directory + "/observer-owner.json")
            try Data("not a MacBridge receipt".utf8).write(to: receipt)
            XCTAssertEqual(chmod(receipt.path, 0o600), 0)
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: timespec(tv_sec: 1, tv_nsec: 0)))
            XCTAssertThrowsError(try lease.recordSocket(try socketIdentity(directory)))
            try FileManager.default.moveItem(at: receipt, to: URL(fileURLWithPath: directory + "/kept"))
            XCTAssertEqual(symlink((directory + "/kept"), receipt.path), 0)
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: timespec(tv_sec: 1, tv_nsec: 0)))
        }
    }

    func testClosedPrebootFixtureCanBeReclaimedWithoutOtherChanges() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            try lease.prepareSocket(bootTime: futureBoot())
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/observer.sock"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), [])
            // Cleanup does not hold a hidden global/file lock after release.
            lease.release()
            let next = try ObserverEndpointLease(directory: directory)
            next.release()
        }
    }

    func testSameBootClosedSocketIsNotReclaimed() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let before = try socketIdentity(directory)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            for boot in [timespec(tv_sec: 0, tv_nsec: 0), timespec(tv_sec: 1, tv_nsec: 0), before.st_birthtimespec] {
                XCTAssertThrowsError(try lease.prepareSocket(bootTime: boot))
                XCTAssertEqual(try socketIdentity(directory).st_ino, before.st_ino)
            }
        }
    }

    func testLiveSocketWithoutNewOwnerLockIsPreserved() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory, listening: true)
            defer { close(socketFD) }
            let before = try socketIdentity(directory)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: futureBoot()))
            XCTAssertEqual(try socketIdentity(directory).st_ino, before.st_ino)
        }
    }

    func testRegularFileAndSymlinkAreNeverRemoved() throws {
        try withDirectory { directory in
            let file = URL(fileURLWithPath: directory + "/observer.sock")
            let payload = Data("fixture data must survive".utf8)
            try payload.write(to: file)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: futureBoot()))
            XCTAssertEqual(try Data(contentsOf: file), payload)
        }
        try withDirectory { directory in
            let target = URL(fileURLWithPath: directory + "/preserved.txt")
            let payload = Data("symlink target must survive".utf8)
            try payload.write(to: target)
            let link = directory + "/observer.sock"
            XCTAssertEqual(symlink(target.path, link), 0)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: futureBoot()))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target.path)
            XCTAssertEqual(try Data(contentsOf: target), payload)
        }
    }

    func testNonPrivateSocketAndWrongOwnerMetadataAreRejected() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            XCTAssertEqual(chmod(directory + "/observer.sock", 0o644), 0)
            let before = try socketIdentity(directory)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: futureBoot()))
            XCTAssertEqual(try socketIdentity(directory).st_ino, before.st_ino)
            var synthetic = before
            synthetic.st_mode = mode_t(S_IFSOCK | 0o600)
            synthetic.st_uid = getuid() == 0 ? 1 : 0
            XCTAssertThrowsError(try ObserverEndpointLease.validatePrivateSocket(synthetic),
                                 "Wrong owner is tested as metadata, never by chown/root")
        }
    }

    func testConcurrentOwnersCannotHoldTheSameDirectory() throws {
        try withDirectory { directory in
            let first = try ObserverEndpointLease(directory: directory)
            defer { first.release() }
            XCTAssertThrowsError(try ObserverEndpointLease(directory: directory))
            first.release()
            let second = try ObserverEndpointLease(directory: directory)
            second.release()
        }
    }

    func testDirectoryReplacementCannotRedirectCleanup() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            let moved = directory + "-moved"
            try FileManager.default.moveItem(atPath: directory, toPath: moved)
            defer { try? FileManager.default.removeItem(atPath: moved) }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let replacementFD = try boundSocket(directory)
            close(replacementFD)
            let before = try socketIdentity(directory)
            XCTAssertThrowsError(try lease.prepareSocket(bootTime: futureBoot()))
            XCTAssertEqual(try socketIdentity(directory).st_ino, before.st_ino)
            XCTAssertNoThrow(try socketIdentity(moved), "The original socket is also preserved on identity mismatch")
        }
    }

    func testNonPrivateDirectoryIsRejectedBeforeAnySocketChanges() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let before = try socketIdentity(directory)
            XCTAssertEqual(chmod(directory, 0o755), 0)
            XCTAssertThrowsError(try ObserverEndpointLease(directory: directory))
            XCTAssertEqual(try socketIdentity(directory).st_ino, before.st_ino)
        }
    }

    func testFailedSetupCanCleanItsExactSocketBeforePrivateModeIsApplied() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            XCTAssertEqual(chmod(directory + "/observer.sock", 0o700), 0)
            let created = try socketIdentity(directory)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            lease.removeSocket(matching: created.st_ino)
            XCTAssertEqual(try socketIdentity(directory).st_ino, created.st_ino,
                           "Normal stop must still refuse non-private mode")
            lease.removeNewlyBoundSocket(matching: created)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/observer.sock"))
        }
    }

    func testFailedSetupCleanupPreservesAReplacementSocketInode() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let created = try socketIdentity(directory)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            let previousPath = directory + "/previous.sock"
            try FileManager.default.moveItem(atPath: directory + "/observer.sock", toPath: previousPath)
            let replacementFD = try boundSocket(directory)
            close(replacementFD)
            let replacement = try socketIdentity(directory)
            XCTAssertNotEqual(replacement.st_ino, created.st_ino)
            lease.removeNewlyBoundSocket(matching: created)
            XCTAssertEqual(try socketIdentity(directory).st_ino, replacement.st_ino)
            XCTAssertTrue(FileManager.default.fileExists(atPath: previousPath))
        }
    }

    func testFailedSetupCleanupPreservesAReplacementRegularFile() throws {
        try withDirectory { directory in
            let socketFD = try boundSocket(directory)
            close(socketFD)
            let created = try socketIdentity(directory)
            let lease = try ObserverEndpointLease(directory: directory)
            defer { lease.release() }
            let path = directory + "/observer.sock"
            try FileManager.default.moveItem(atPath: path, toPath: directory + "/previous.sock")
            let payload = Data("replacement file must survive setup cleanup".utf8)
            try payload.write(to: URL(fileURLWithPath: path))
            lease.removeNewlyBoundSocket(matching: created)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)
            // Even passing metadata from a regular file cannot authorize unlink.
            lease.removeNewlyBoundSocket(matching: try socketIdentity(directory))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)
        }
    }

    private func futureBoot() -> timespec {
        // Simulates only the validator's cutoff. No host boot/file times change.
        timespec(tv_sec: Int(Date().timeIntervalSince1970) + 10, tv_nsec: 0)
    }

    private func socketIdentity(_ directory: String) throws -> stat {
        var status = stat()
        guard lstat(directory + "/observer.sock", &status) == 0 else {
            throw NSError(domain: "ObserverRecoveryFixture", code: Int(errno))
        }
        return status
    }

    private func boundSocket(_ directory: String, listening: Bool = false) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "ObserverRecoveryFixture", code: Int(errno)) }
        var address = try ObserverSocket.address(directory + "/observer.sock")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(directory + "/observer.sock", 0o600) == 0,
              !listening || listen(descriptor, 1) == 0 else {
            let error = errno
            close(descriptor)
            throw NSError(domain: "ObserverRecoveryFixture", code: Int(error))
        }
        return descriptor
    }

    private func withDirectory(_ action: (String) throws -> Void) throws {
        var template = Array("/private/tmp/mb-endpoint-test-XXXXXX".utf8CString)
        let directory = try XCTUnwrap(template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let result = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: result)
        })
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try action(directory)
    }
}
