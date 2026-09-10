import Darwin
import Foundation
import XCTest
@testable import MacBridgeLocalCore

/// Synthetic account/key values only. No transport is connected or resumed.
final class BrevoConfigurationTests: XCTestCase {
    private let fakeKey = String(repeating: "fixture", count: 5)
    private func configuration(_ email: String = "account@example.invalid") -> Data {
        Data("BREVO_API_KEY=\(fakeKey)\nBREVO_ACCOUNT_EMAIL=\(email)\n".utf8)
    }
    private func fixture() throws -> URL {
        let parent = try canonicalExistingPath(FileManager.default.temporaryDirectory.path)
        let url = URL(fileURLWithPath: parent)
            .appendingPathComponent("mb-brevo-config-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
    private func write(_ data: Data, to path: URL, mode: mode_t = 0o600) throws {
        try data.write(to: path)
        XCTAssertEqual(chmod(path.path, mode), 0)
    }
    func testExplicitAccountAndKeyAreParsedTogether() throws {
        let parsed = try BrevoConfiguration.parse(configuration("ACCOUNT@EXAMPLE.INVALID"))
        XCTAssertEqual(parsed.accountEmail, "account@example.invalid")
        XCTAssertEqual(parsed.apiKey, fakeKey)
    }
    func testPrivateCommentsWhitespaceAndQuotedValues() throws {
        let text = "# local settings\n BREVO_ACCOUNT_EMAIL = 'account@example.invalid'\nBREVO_API_KEY=\"\(fakeKey)\"\n"
        XCTAssertEqual(try BrevoConfiguration.parse(Data(text.utf8)).apiKey, fakeKey)
    }
    func testLegacyKeyAloneCannotChooseAnAccount() {
        XCTAssertThrowsError(try BrevoConfiguration.parse(Data("BREVO_API_KEY=\(fakeKey)\n".utf8)))
    }
    func testMissingKeyCannotUseConfigurationAsCredential() {
        XCTAssertThrowsError(try BrevoConfiguration.parse(Data("BREVO_ACCOUNT_EMAIL=account@example.invalid\n".utf8)))
    }
    func testDuplicateAndUnexpectedFieldsFailWithoutEchoingValues() {
        for extra in ["BREVO_API_KEY=\(fakeKey)", "BREVO_ACCOUNT_EMAIL=other@example.invalid", "URL=https://example.invalid", "export BREVO_API_KEY=\(fakeKey)", "no-equals"] {
            XCTAssertThrowsError(try BrevoConfiguration.parse(configuration() + Data(extra.utf8))) { error in
                XCTAssertFalse(String(describing: error).contains(self.fakeKey))
                XCTAssertFalse(String(describing: error).contains("other@example.invalid"))
            }
        }
    }
    func testInvalidKeyLengthControlBytesAndEmailAreRejected() {
        for key in ["short", String(repeating: "a", count: 8193), "sixteen characters but spaces", "injected\tcontrol-byte"] {
            let text = "BREVO_API_KEY=\(key)\nBREVO_ACCOUNT_EMAIL=account@example.invalid\n"
            XCTAssertThrowsError(try BrevoConfiguration.parse(Data(text.utf8)))
        }
        for email in ["", "not-an-email", "account@example.invalid\runknown=value"] {
            XCTAssertThrowsError(try BrevoConfiguration.parse(configuration(email)))
        }
    }
    func testInvalidUTF8EmptyAndOversizedAreRejected() {
        for data in [Data(), Data([0xff, 0xfe]), Data(repeating: 65, count: 16_385)] {
            XCTAssertThrowsError(try BrevoConfiguration.parse(data))
        }
    }
    func testOwnerOnlyRegularFileCanBeRead() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("brevo.env")
        try write(configuration(), to: path)
        XCTAssertEqual(try BrevoConfiguration.load(from: path).accountEmail, "account@example.invalid")
    }
    func testOtherReadableConfigurationIsRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("brevo.env")
        try write(configuration(), to: path, mode: 0o644)
        XCTAssertThrowsError(try BrevoConfiguration.load(from: path))
    }
    func testSymlinkFileAndParentAreRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("brevo.env")
        try write(configuration(), to: path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try BrevoConfiguration.load(from: link))
        let parentLink = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        XCTAssertThrowsError(try BrevoConfiguration.load(from: parentLink.appendingPathComponent("brevo.env")))
    }
    func testHardLinkAndFIFOAreRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("brevo.env")
        try write(configuration(), to: path)
        XCTAssertEqual(Darwin.link(path.path, root.appendingPathComponent("alias").path), 0)
        XCTAssertThrowsError(try BrevoConfiguration.load(from: path))
        let pipe = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try BrevoConfiguration.load(from: pipe))
    }
    func testDirectoryMissingAndOversizedFilesAreRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try BrevoConfiguration.load(from: root))
        XCTAssertThrowsError(try BrevoConfiguration.load(from: root.appendingPathComponent("missing")))
        let path = root.appendingPathComponent("oversized")
        try write(Data(repeating: 65, count: 16_385), to: path)
        XCTAssertThrowsError(try BrevoConfiguration.load(from: path))
    }
    func testWriteConfirmationCannotSelectADifferentConfiguredAccount() throws {
        let configured = "second@example.invalid"
        XCTAssertThrowsError(try BrevoSafety.confirmWrite([
            "confirm_write": true, "verified_account_email": "first@example.invalid"], expectedAccountEmail: configured))
        XCTAssertNoThrow(try BrevoSafety.confirmWrite([
            "confirm_write": true, "verified_account_email": "SECOND@EXAMPLE.INVALID"], expectedAccountEmail: configured))
    }
    func testActualAccountMustMatchTheSameConfiguredBinding() throws {
        var calls = 0
        let perform: BrevoOperations.Transport = { method, path, _, _, write in
            calls += 1
            XCTAssertEqual(method, "GET"); XCTAssertEqual(path, "account"); XCTAssertFalse(write)
            return ["email": "first@example.invalid"]
        }
        XCTAssertThrowsError(try BrevoSafety.verifyAccount(perform, expectedAccountEmail: "second@example.invalid"))
        XCTAssertEqual(calls, 1)
    }
    func testConfigurationInstancesDoNotShareMutableAccountState() throws {
        let first = try BrevoConfiguration.parse(configuration("first@example.invalid"))
        let second = try BrevoConfiguration.parse(configuration("second@example.invalid"))
        XCTAssertEqual(first.accountEmail, "first@example.invalid")
        XCTAssertEqual(second.accountEmail, "second@example.invalid")
    }
    func testPrivateConfigurationRemainsProtectedFromOrdinaryFileTools() {
        for path in ["/Users/example/.config/macbridge/brevo.env", "/Users/example/.CONFIG/MACBRIDGE/brevo.env"] {
            XCTAssertTrue(LocalFilesystemAccess.isSensitive(path))
        }
        XCTAssertTrue(LocalFilesystemAccess.sandboxDenyRules().contains("[mM][aA][cC][bB][rR][iI][dD][gG][eE]"))
    }
}
