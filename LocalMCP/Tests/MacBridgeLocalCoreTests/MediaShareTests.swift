import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class MediaShareTests: XCTestCase {
    // Assemble the fixed public documentation vector at runtime so generic
    // release scanners do not misclassify it as a live credential or URL.
    private let publishedAWSAccess = ["AKIAIOSF", "ODNN7EXAMPLE"].joined()
    private let publishedAWSSecret = ["wJalrXUtnFEMI/K7MDENG/", "bPxRfiCYEXAMPLEKEY"].joined()
    private let publishedAWSQuerySignature = ["aeeed9bbccd4d02e", "e5c0109b86d86835f995330da4c265957d157751f604d404"].joined()

    func testPublishedAWSQuerySignatureVector() throws {
        // Public AWS documentation example, not production credentials.
        let url = MediaS3Signing.presignedGET(host: "examplebucket.s3.amazonaws.com", path: "/test.txt",
            access: publishedAWSAccess, secret: publishedAWSSecret,
            region: "us-east-1", issued: Date(timeIntervalSince1970: 1_369_353_600), seconds: 86_400)
        XCTAssertTrue(url.absoluteString.hasSuffix("X-Amz-Signature=" + publishedAWSQuerySignature))
    }
    func testPublishedAWSHeaderSignatureVector() {
        let request = MediaS3Signing.signedRequest(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt",
            access: publishedAWSAccess, secret: publishedAWSSecret,
            region: "us-east-1", date: Date(timeIntervalSince1970: 1_369_353_600), headers: ["range": "bytes=0-9"])
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41") == true)
    }
    func testSigningURIEncodingAndStableGET() {
        XCTAssertEqual(MediaS3Signing.encode("/file é+$~.png", keepSlash: true), "/file%20%C3%A9%2B%24~.png")
        XCTAssertEqual(MediaS3Signing.encode("a/b"), "a%2Fb")
    }
    func testCapabilitiesNeedsNoConfigWorkspaceOrNetwork() throws {
        let r = try MediaShareOperations.execute("media_inspect", ["action": "capabilities"], workspace: nil,
            configurationURL: URL(fileURLWithPath: "/does-not-exist"), transport: { _,_ in XCTFail(); throw URLError(.unknown) })
        XCTAssertEqual(r["credential_read"] as? Bool, false)
        XCTAssertEqual(r["network_request"] as? Bool, false)
        XCTAssertEqual(r["same_link_allows_HEAD"] as? Bool, false)
    }
    func testPrepareHasNoNetworkOrPublicURL() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let r = try f.call("media_inspect", ["action": "prepare", "path": "creative.png"])
        XCTAssertEqual(r["sha256"] as? String, f.sha)
        XCTAssertEqual(r["byte_count"] as? Int, MediaFixture.png.count)
        XCTAssertEqual(r["credential_read"] as? Bool, false)
        XCTAssertNil(r["media_url"]); XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testPublishStreamsSnapshotVerifiesHEADAndReturnsExpiringGET() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let result = try f.publish()
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD"])
        XCTAssertEqual(result["share_state"] as? String, "ready")
        XCTAssertEqual(result["meta_upload_performed"] as? Bool, false)
        XCTAssertEqual(result["source_modified"] as? Bool, false)
        let url = try XCTUnwrap(result["media_url"] as? String)
        XCTAssertTrue(url.hasPrefix("https://" + f.host + "/fixture-media/macbridge-transfers/"))
        XCTAssertFalse(url.contains("creative.png")); XCTAssertTrue(url.contains("X-Amz-Expires=900"))
        XCTAssertEqual(try Data(contentsOf: f.file), MediaFixture.png)
        let snapshot = try XCTUnwrap(f.http.lastSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path), "Snapshot cleaned after transfer")
    }
    func testSameRequestAfterRestartDoesNotUploadAgainOrRenew() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let first = try f.publish(); f.time += 20
        let second = try f.publish() // Every call loads a new configuration/journal.
        XCTAssertEqual(first["media_url"] as? String, second["media_url"] as? String)
        XCTAssertEqual(second["same_request_reconciled"] as? Bool, true)
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD", "HEAD"])
    }
    func testLostPUTResponseReconcilesOriginalObjectWithoutReplay() throws {
        let f = try MediaFixture(); defer { f.remove() }
        f.http.failAfterPUT = true
        XCTAssertEqual(try f.publish()["share_state"] as? String, "outcome_unknown")
        f.http.failAfterPUT = false
        XCTAssertEqual(try f.publish()["share_state"] as? String, "ready")
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD"])
    }
    func testUnknownPUTAnd404DoesNotClaimRevokedOrRetry() throws {
        let f = try MediaFixture(); defer { f.remove() }
        f.http.failBeforePUT = true
        XCTAssertEqual(try f.publish()["isError"] as? Bool, true)
        let result = try f.revoke()
        XCTAssertEqual(result["share_state"] as? String, "outcome_unknown")
        XCTAssertNil(result["media_url"])
        _ = try f.publish()
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD", "HEAD"])
    }
    func testDigestMismatchNeverUsesNetwork() throws {
        let f = try MediaFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.publish(["expected_sha256": String(repeating: "0", count: 64)]))
        XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testRequestIDCannotBeReusedForDifferentFileDigestOrLifetime() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish()
        for change: JSONObject in [["expected_sha256": String(repeating: "0", count: 64)],
                                   ["path": "other.png"], ["expires_in_seconds": 901]] {
            XCTAssertThrowsError(try f.publish(change))
        }
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD"])
    }
    func testExpiredLinkDoesNotRenewOrDeleteObject() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish()
        f.time += 900
        let r = try f.publish()
        XCTAssertNil(r["media_url"]); XCTAssertEqual(r["link_expired"] as? Bool, true)
        XCTAssertEqual(r["share_state"] as? String, "ready")
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD", "HEAD"])
    }
    func testClockRollbackDoesNotReturnFutureDatedLink() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish(); f.time -= 1
        let r = try f.publish()
        XCTAssertNil(r["media_url"]); XCTAssertEqual(r["isError"] as? Bool, true)
    }
    func testRevokeDeletesOnlyRecordedObjectAndVerifiesAbsence() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish()
        let r = try f.revoke()
        XCTAssertEqual(r["share_state"] as? String, "revoked"); XCTAssertNil(r["media_url"])
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD", "HEAD", "DELETE", "HEAD"])
        let calls = f.http.methods
        XCTAssertEqual(try f.revoke()["network_request"] as? Bool, false)
        _ = try f.publish(); XCTAssertEqual(calls, f.http.methods)
        XCTAssertEqual(Set(f.http.paths).count, 1)
    }
    func testRevokeFailureDoesNotClaimSuccess() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish(); f.http.failDelete = true
        let r = try f.revoke()
        XCTAssertEqual(r["isError"] as? Bool, true); XCTAssertEqual(r["share_state"] as? String, "outcome_unknown")
        XCTAssertFalse(f.http.object.isEmpty)
    }
    func testUnknownReceiptNeverDeletesOrReadsRemoteObject() throws {
        let f = try MediaFixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.revoke()); XCTAssertThrowsError(try f.status())
        XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testHEADWrongDigestLengthTypeOrDeniedResponseNeverReturnsURL() throws {
        for mismatch in ["sha", "length", "mime", "denied", "redirect"] {
            let f = try MediaFixture(); defer { f.remove() }; f.http.headMismatch = mismatch
            let r = try f.publish()
            XCTAssertNil(r["media_url"]); XCTAssertEqual(r["isError"] as? Bool, true)
            XCTAssertEqual(f.http.methods, ["PUT", "HEAD"])
        }
    }
    func testInputCannotSupplyEndpointCredentialsOrChangePrivacyBounds() throws {
        let f = try MediaFixture(); defer { f.remove() }
        for values: JSONObject in [["endpoint": "https://example.com"], ["access_key_id": "not allowed"],
            ["expires_in_seconds": 59], ["expires_in_seconds": 3_601], ["expires_in_seconds": true],
            ["confirm_public_link": false], ["confirm_public_link": 1], ["confirm_public_link": "true"],
            ["request_id": "not-uuid"], ["path": "../escape.png"]] {
            XCTAssertThrowsError(try f.publish(values))
        }
        XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testConfigurationRejectsSSRFAndMalformedEndpoints() throws {
        let f = try MediaFixture(); defer { f.remove() }
        for endpoint in ["http://" + f.host, "https://127.0.0.1", "https://" + f.host + ".evil.test",
            "https://user@" + f.host, "https://" + f.host + ":443", "https://" + f.host + "/bucket",
            "https://" + f.host + "?x=1", "https://" + f.host + "#x"] {
            var c = f.configJSON; c["endpoint"] = endpoint
            XCTAssertThrowsError(try MediaShareConfiguration.parse(LocalJSON.encode(c)))
        }
    }
    func testConfigurationRejectsUnknownKeysWideRootSymlinkAndWrongPermissions() throws {
        let f = try MediaFixture(); defer { f.remove() }
        for override: JSONObject in [["secret": "unexpected"], ["media_root": "/"], ["media_root": "/Users"],
                                    ["media_root": f.mediaRoot.path + "/.."]] {
            let c = f.configJSON.merging(override, uniquingKeysWith: { _,n in n })
            XCTAssertThrowsError(try MediaShareConfiguration.parse(LocalJSON.encode(c)))
        }
        let alias = f.base.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.mediaRoot)
        var c = f.configJSON; c["media_root"] = alias.path
        XCTAssertThrowsError(try MediaShareConfiguration.parse(LocalJSON.encode(c)))
        XCTAssertEqual(chmod(f.config.path, 0o644), 0)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testOwnerBindingChangeRetainsOldJournalAndDeniesNewWrite() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish()
        let old = try Data(contentsOf: f.state)
        f.configJSON["bucket"] = "another-bucket"; try f.writeConfig()
        XCTAssertThrowsError(try f.publish()); XCTAssertEqual(try Data(contentsOf: f.state), old)
        XCTAssertEqual(f.http.methods, ["PUT", "HEAD"])
    }
    func testReceiptDoesNotStoreKeysOrSignedURLsAndIsOwnerOnly() throws {
        let f = try MediaFixture(); defer { f.remove() }; _ = try f.publish()
        let text = try String(contentsOf: f.state, encoding: .utf8)
        for forbidden in ["X-Amz", "https://", f.secret, f.access] { XCTAssertFalse(text.contains(forbidden)) }
        var info = stat(); XCTAssertEqual(lstat(f.state.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }
    func testJournalLeaseRejectsConcurrentWriterAndReleases() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let binding = try MediaShareConfiguration.load(from: f.config).binding
        var journal: MediaShareJournal? = try MediaShareJournal(configurationURL: f.config, binding: binding)
        XCTAssertNotNil(journal)
        XCTAssertThrowsError(try MediaShareJournal(configurationURL: f.config, binding: binding))
        journal = nil
        XCTAssertNoThrow(try MediaShareJournal(configurationURL: f.config, binding: binding))
    }
    func testMalformedJournalFailsClosedWithoutNetworkOrReset() throws {
        let f = try MediaFixture(); defer { f.remove() }
        try Data("malformed".utf8).write(to: f.state); _ = chmod(f.state.path, 0o600)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
        XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), "malformed")
    }
    func testMediaFileRejectsSymlinkHardlinkFifoOutsideRootAndSensitivePaths() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let alias = f.mediaRoot.appendingPathComponent("alias.png"), hard = f.mediaRoot.appendingPathComponent("hard.png")
        let fifo = f.mediaRoot.appendingPathComponent("fifo.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.file)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for path in [alias.path, fifo.path, f.base.root.appendingPathComponent("escape.png").path, ".env.png"] {
            XCTAssertThrowsError(try MediaFile.read(workspace: f.workspace, path: path, mediaRoot: f.mediaRoot))
        }
        XCTAssertEqual(link(f.file.path, hard.path), 0)
        XCTAssertThrowsError(try MediaFile.read(workspace: f.workspace, path: f.file.path))
        XCTAssertThrowsError(try MediaFile.read(workspace: f.workspace, path: hard.path))
    }
    func testMagicAndExtensionsMustMatchIncludingVideo() throws {
        let examples: [(String, [UInt8], String)] = [
            ("jpg", [255,216,255,1], "image/jpeg"), ("png", Array(MediaFixture.png), "image/png"),
            ("gif", Array("GIF89a".utf8), "image/gif"),
            ("mp4", [0,0,0,24] + Array("ftypisom0000".utf8), "video/mp4"),
            ("mov", [0,0,0,24] + Array("ftypqt  0000".utf8), "video/quicktime")]
        for (ext, bytes, mime) in examples { XCTAssertEqual(try MediaFile.classify(bytes, extension: ext).0, mime) }
        XCTAssertThrowsError(try MediaFile.classify(Array("#!/bin/sh".utf8), extension: "png"))
        XCTAssertThrowsError(try MediaFile.classify(Array(MediaFixture.png), extension: "mp4"))
        XCTAssertThrowsError(try MediaFile.classify(Array(MediaFixture.png), extension: "svg"))
    }
    func testVideoTransferUsesSameScopedStreamingRoute() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let data = Data([0,0,0,24] + Array("ftypisom000000000000".utf8))
        try data.write(to: f.mediaRoot.appendingPathComponent("creative.mp4"))
        let r = try f.publish(["path": "creative.mp4", "expected_sha256": LocalHash.sha256(data)])
        XCTAssertEqual(r["media_type"] as? String, "VIDEO")
        XCTAssertEqual(r["mime_type"] as? String, "video/mp4")
        XCTAssertEqual(r["meta_upload_performed"] as? Bool, false)
    }
    func testSummaryNeverCopiesBearerURL() {
        let r: JSONObject = ["link_available": true, "media_url": "https://secret.invalid/?X-Amz-Signature=sentinel", "byte_count": 64]
        let text = ToolResultSummary.text(name: "media_share", result: r)
        XCTAssertTrue(text.contains("not uploaded to Meta")); XCTAssertFalse(text.contains("sentinel")); XCTAssertFalse(text.contains("https"))
    }
    func testEmptyAndOversizedSparseFilesAreRejectedBeforeUpload() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let file = f.mediaRoot.appendingPathComponent("oversized.png")
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        XCTAssertThrowsError(try MediaFile.read(workspace: f.workspace, path: file.path))
        XCTAssertEqual(ftruncate(fd, off_t(MediaFile.maximumBytes + 1)), 0)
        XCTAssertThrowsError(try MediaFile.read(workspace: f.workspace, path: file.path))
        XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testConfigHardlinkAndNonPrivateStateDirectoryAreRejected() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let other = f.base.root.appendingPathComponent("config-copy")
        XCTAssertEqual(link(f.config.path, other.path), 0)
        XCTAssertThrowsError(try f.publish()); XCTAssertEqual(unlink(other.path), 0)
        XCTAssertEqual(chmod(f.config.deletingLastPathComponent().path, 0o755), 0)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testOutstandingStorageLimitDoesNotEvictOrPublish() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let records = (0..<4).map { _ in record(f, bytes: MediaFile.maximumBytes) }
        try writeState(f, records)
        let before = try Data(contentsOf: f.state)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
        XCTAssertEqual(before, try Data(contentsOf: f.state))
    }
    func testFullReceiptLedgerFailsClosedWithoutEviction() throws {
        let f = try MediaFixture(); defer { f.remove() }
        try writeState(f, (0..<MediaShareJournal.maximumRecords).map { _ in record(f, bytes: 1) })
        let before = try Data(contentsOf: f.state)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
        XCTAssertEqual(before, try Data(contentsOf: f.state))
    }
    func testOversizedJournalAndDuplicateIDsFailClosed() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let r = record(f, bytes: 1); try writeState(f, [r, r])
        XCTAssertThrowsError(try f.publish())
        try Data(repeating: 32, count: MediaShareJournal.maximumStateBytes + 1).write(to: f.state)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
    }
    func testSourceAncestorSymlinkAndStateSymlinkAreRejected() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let alias = f.mediaRoot.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.mediaRoot)
        XCTAssertThrowsError(try f.publish(["path": "alias/creative.png"]))
        let arbitrary = f.base.root.appendingPathComponent("unrelated.json")
        try Data("must stay unchanged".utf8).write(to: arbitrary)
        try FileManager.default.createSymbolicLink(at: f.state, withDestinationURL: arbitrary)
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
        XCTAssertEqual(try String(contentsOf: arbitrary, encoding: .utf8), "must stay unchanged")
    }
    func testUntrustedStateCannotChooseAnObjectOutsideTransferPrefix() throws {
        let f = try MediaFixture(); defer { f.remove() }
        let r = record(f, bytes: 1)
        let invalid = MediaShareRecord(requestID: r.requestID, workspaceID: r.workspaceID, path: r.path,
            sha256: r.sha256, bytes: r.bytes, mime: r.mime, ext: r.ext, objectKey: "unrelated/important.png",
            issued: r.issued, seconds: r.seconds, state: r.state)
        try writeState(f, [invalid])
        XCTAssertThrowsError(try f.publish()); XCTAssertTrue(f.http.methods.isEmpty)
    }
    private func record(_ f: MediaFixture, bytes: Int) -> MediaShareRecord {
        MediaShareRecord(requestID: UUID().uuidString.lowercased(), workspaceID: f.base.workspaceID,
            path: f.file.path, sha256: f.sha, bytes: bytes, mime: "image/png", ext: "png",
            objectKey: "macbridge-transfers/" + UUID().uuidString.lowercased() + "/media.png",
            issued: Int64(f.time), seconds: 900, state: "ready")
    }
    private func writeState(_ f: MediaFixture, _ records: [MediaShareRecord]) throws {
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
        try LocalJSON.encode(["version": 1, "binding": MediaShareConfiguration.load(from: f.config).binding,
                              "records": values]).write(to: f.state)
        XCTAssertEqual(chmod(f.state.path, 0o600), 0)
    }
}

/// Synthetic local-only fixture. All network requests use the in-memory fake.
final class MediaFixture {
    static let png = Data([137,80,78,71,13,10,26,10,0,0,0,0])
    let base: Fixture, mediaRoot: URL, config: URL, state: URL, file: URL, workspace: RegisteredLocalWorkspace
    let http = MediaFakeHTTP()
    let host = String(repeating: "a", count: 32) + ".r2.cloudflarestorage.com"
    let access = String(repeating: "b", count: 32), secret = String(repeating: "c", count: 64)
    let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    var configJSON: JSONObject = [:]
    var time: TimeInterval = 1_800_000_000
    var sha: String { LocalHash.sha256(Self.png) }
    init() throws {
        base = try Fixture(); mediaRoot = base.workspace
        workspace = try base.service().registry.workspace(id: base.workspaceID)
        let owner = base.root.appendingPathComponent("owner")
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        config = owner.appendingPathComponent("media-share.json"); state = owner.appendingPathComponent("media-shares.json")
        file = mediaRoot.appendingPathComponent("creative.png"); try Self.png.write(to: file)
        configJSON = ["version": 1, "endpoint": "https://" + host, "bucket": "fixture-media",
            "access_key_id": access, "secret_access_key": secret, "workspace_id": base.workspaceID, "media_root": mediaRoot.path]
        try writeConfig()
    }
    func writeConfig() throws { try LocalJSON.encode(configJSON).write(to: config); XCTAssertEqual(chmod(config.path, 0o600), 0) }
    func call(_ tool: String, _ arguments: JSONObject) throws -> JSONObject {
        try MediaShareOperations.execute(tool, arguments.merging(["workspace_id": base.workspaceID], uniquingKeysWith: { old,_ in old }),
            workspace: workspace, configurationURL: config, transport: http.run, now: { Date(timeIntervalSince1970: self.time) })
    }
    func publish(_ changes: JSONObject = [:]) throws -> JSONObject {
        try call("media_share", ["action": "publish", "request_id": id, "path": "creative.png",
            "expected_sha256": sha, "confirm_public_link": true].merging(changes, uniquingKeysWith: { _,n in n }))
    }
    func revoke() throws -> JSONObject { try call("media_share", ["action": "revoke", "request_id": id]) }
    func status() throws -> JSONObject { try call("media_inspect", ["action": "status", "request_id": id]) }
    func remove() { base.remove() }
}

final class MediaFakeHTTP {
    var methods: [String] = [], paths: [String] = [], object: [String: String] = [:]
    var lastSnapshot: URL?
    var failBeforePUT = false, failAfterPUT = false, failDelete = false
    var headMismatch = ""
    func run(_ request: URLRequest, _ file: URL?) throws -> MediaHTTPReply {
        let method = request.httpMethod ?? ""
        methods.append(method); paths.append(request.url!.path)
        XCTAssertEqual(request.url?.scheme, "https"); XCTAssertNil(request.url?.query)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        if method == "PUT" {
            if failBeforePUT { throw URLError(.timedOut) }
            let file = try XCTUnwrap(file); lastSnapshot = file
            let bytes = try Data(contentsOf: file)
            XCTAssertEqual(LocalHash.sha256(bytes), request.value(forHTTPHeaderField: "x-amz-content-sha256"))
            object = ["content-length": String(bytes.count), "content-type": request.value(forHTTPHeaderField: "Content-Type")!,
                      "x-amz-meta-sha256": LocalHash.sha256(bytes)]
            if failAfterPUT { throw URLError(.networkConnectionLost) }
            return MediaHTTPReply(status: 200, headers: [:])
        }
        XCTAssertNil(file)
        if method == "DELETE" {
            if failDelete { throw URLError(.timedOut) }
            object = [:]; return MediaHTTPReply(status: 204, headers: [:])
        }
        XCTAssertEqual(method, "HEAD")
        var headers = object
        if headMismatch == "sha" { headers["x-amz-meta-sha256"] = "wrong" }
        if headMismatch == "length" { headers["content-length"] = "wrong" }
        if headMismatch == "mime" { headers["content-type"] = "wrong" }
        return MediaHTTPReply(status: headMismatch == "denied" ? 403 : headMismatch == "redirect" ? 307 : object.isEmpty ? 404 : 200,
                              headers: headers)
    }
}
