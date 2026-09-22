import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class FileReaderSecurityTests: XCTestCase {
    func testDatalessDirectReadHasStableNonHydratingErrorMetadata() throws {
        var metadata = stat()
        metadata.st_size = 8_191
        metadata.st_blocks = 0
        metadata.st_flags = UInt32(SF_DATALESS)
        XCTAssertTrue(LocalFileReader.isDataless(metadata))
        var detail: JSONObject = [:]
        XCTAssertThrowsError(try LocalFileReader.requireMaterialized(metadata)) {
            detail = localErrorDetail($0)
        }
        XCTAssertEqual(detail["code"] as? String, "FILE_NOT_MATERIALIZED")
        XCTAssertEqual(detail["stage"] as? String, "read_preflight")
        XCTAssertEqual(detail["logical_size_bytes"] as? Int64, 8_191)
        XCTAssertEqual(detail["allocated_blocks"] as? Int64, 0)
        XCTAssertEqual(detail["content_read_attempted"] as? Bool, false)
        XCTAssertEqual(detail["retry_safe"] as? Bool, false)
        XCTAssertEqual(detail["recommended_action"] as? String,
                       "materialize_file_locally_then_retry")
    }

    func testBoundedReaderPreservesBytesHashAndDescriptorOffset() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.workspace.appendingPathComponent("normal.bin")
        let bytes = Data(repeating: 0x5a, count: 1_100_000)
        try bytes.write(to: url)
        XCTAssertEqual(try LocalFileReader.read(url: url, maximumBytes: bytes.count), bytes)
        XCTAssertEqual(try LocalHash.sha256(fileAt: url), LocalHash.sha256(bytes))
        XCTAssertThrowsError(try LocalFileReader.read(url: url, maximumBytes: bytes.count - 1))
        XCTAssertThrowsError(try LocalHash.sha256(fileAt: url, maximumBytes: 100))
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        XCTAssertEqual(lseek(fd, 7, SEEK_SET), 7)
        XCTAssertEqual(try LocalFileReader.read(descriptor: fd, maximumBytes: bytes.count), bytes)
        XCTAssertEqual(lseek(fd, 0, SEEK_CUR), 7)
        XCTAssertEqual(try LocalHash.sha256(descriptor: fd), LocalHash.sha256(bytes))
    }

    func testWorkspaceReadUsesSharedNonHydratingOpenPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.workspace.appendingPathComponent("entry-point.txt")
        try Data("entry point".utf8).write(to: url)
        let service = try fixture.service()
        let result = try service.readFile(
            workspaceID: fixture.workspaceID, path: "entry-point.txt",
            encoding: "utf8", maximumBytes: 64
        )
        let file = try XCTUnwrap(result["file"] as? JSONObject)
        XCTAssertEqual(file["content"] as? String, "entry point")
        XCTAssertEqual(file["byte_count"] as? Int, 11)
    }

    func testFIFOLeafAncestorSymlinksAndHardlinksFailWithoutBlocking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.workspace.appendingPathComponent("data")
        try Data("private fixture".utf8).write(to: file)
        let fifo = fixture.workspace.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try LocalHash.sha256(fileAt: fifo))
        XCTAssertThrowsError(try LocalFileReader.read(url: fifo, maximumBytes: 100))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let leaf = fixture.workspace.appendingPathComponent("link")
        XCTAssertEqual(symlink(file.path, leaf.path), 0)
        XCTAssertThrowsError(try LocalHash.sha256(fileAt: leaf))
        let parent = fixture.root.appendingPathComponent("alias")
        XCTAssertEqual(symlink(fixture.workspace.path, parent.path), 0)
        XCTAssertThrowsError(try LocalFileReader.read(url: parent.appendingPathComponent("data"), maximumBytes: 100))
        let hardlink = fixture.workspace.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, hardlink.path), 0)
        XCTAssertThrowsError(try LocalHash.sha256(fileAt: file))
        XCTAssertThrowsError(try LocalFileReader.read(url: hardlink, maximumBytes: 100))
    }

    func testConcurrentTruncationIsConflictNotMappedMemoryCrash() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.workspace.appendingPathComponent("changing")
        try Data(repeating: 0x61, count: 1_100_000).write(to: file)
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertThrowsError(try LocalFileReader.chunks(descriptor: descriptor, maximumBytes: 2_000_000) { _ in
            XCTAssertEqual(truncate(file.path, 0), 0)
        })
    }

    func testURLReplacementDuringReadIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.workspace.appendingPathComponent("changing")
        try Data("original".utf8).write(to: file)
        XCTAssertThrowsError(try LocalFileReader.withFile(url: file) { descriptor in
            let bytes = try LocalFileReader.read(descriptor: descriptor, maximumBytes: 100)
            try Data("replaced".utf8).write(to: file, options: .atomic)
            return bytes
        })
    }

    func testCredentialStorePolicyAndDirectReadsUseSameBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let denied = [".git-credentials", ".config/git/credentials", ".config/gh/hosts.yml", ".config/gcloud/application_default_credentials.json",
                      ".docker/config.json", "Library/Application Support/Microsoft Edge/Default/Cookies",
                      "Library/Application Support/Arc/User Data/Local State"]
        let service = try fixture.service()
        for path in denied {
            let url = fixture.workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic, not a credential".utf8).write(to: url)
            XCTAssertTrue(LocalFilesystemAccess.isSensitive(path))
            XCTAssertTrue(LocalFilesystemAccess.isSensitive(path.uppercased()))
            XCTAssertThrowsError(try service.readFile(workspaceID: fixture.workspaceID, path: path,
                                                     encoding: "utf8", maximumBytes: 100))
        }
        for path in [".config/gh/config.yml", ".config/git/config", ".docker/Dockerfile", ".env.example", "git-credentials-not-secret"] {
            XCTAssertFalse(LocalFilesystemAccess.isSensitive(path), path)
        }
        XCTAssertTrue(LocalFilesystemAccess.isSensitive(".env.example/nested"))
    }

    func testTrustedExecutableAliasStillInitializesAndConfigRemainsBounded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("executable-alias")
        XCTAssertEqual(symlink("/usr/bin/true", alias.path), 0)
        XCTAssertNoThrow(try LocalMCPServer(configurationURL: fixture.config, selfExecutable: alias))
        let parentAlias = fixture.root.appendingPathComponent("workspace-alias")
        XCTAssertEqual(symlink(fixture.root.path, parentAlias.path), 0)
        XCTAssertNoThrow(try LocalWorkspaceRegistry(configurationURL: parentAlias.appendingPathComponent("workspaces.json")))
        try Data(repeating: 0x20, count: 1_048_577).write(to: fixture.config)
        XCTAssertThrowsError(try LocalWorkspaceRegistry(configurationURL: fixture.config))
    }
}
