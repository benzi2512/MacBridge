import Foundation
import XCTest
@testable import MacBridgeLocalCore

final class ActivityDetailTests: XCTestCase {
    func testUsefulCommandPreviewsKeepExecutableSafeArgumentsAndFolder() {
        let swift = ActivityDetail.metadata(name: "command_start", arguments: [
            "executable": "swift", "arguments": ["test", "--jobs", "2", "--filter", "ActivityDetailTests"],
            "cwd": "/Users/example/Project"])
        XCTAssertEqual(swift["command_preview"] as? String, "swift test --jobs 2 --filter ActivityDetailTests")
        XCTAssertEqual(swift["cwd"] as? String, "/Users/example/Project")
        XCTAssertNil(swift["preview_omitted"])
        XCTAssertEqual(preview("npm", ["test"]), "npm test")
        XCTAssertEqual(preview("python3", ["-B", "scripts/check.py"]), "python3 -B scripts/check.py")
        XCTAssertEqual(preview("git", ["status", "--porcelain=v1"]), "git status --porcelain=v1")
    }

    func testSecretsEnvironmentURLsAndUnknownValuesAreNotCopied() {
        let secrets = ["sk-private0123456789", "ghp_private0123456789", "github_pat_private0123456789",
            "xoxb-private", "AKIA" + "1234567890123456", "eyJhbGciOiJIUzI1NiJ9.payload.signature"]
        for secret in secrets {
            let text = preview("python3", ["scripts/check.py", "--token", secret])
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertTrue(text.contains("scripts/check.py"))
        }
        let args = ["test", "API_KEY=private-value", "--password", "apparently-safe.txt",
                    "https://user:password@example.com/file?token=private", "--opaque", "another-value.json"]
        let text = preview("npm", args)
        for fragment in ["private-value", "apparently-safe.txt", "user:", "example.com", "another-value.json"] {
            XCTAssertFalse(text.contains(fragment), text)
        }
        XCTAssertTrue(text.contains("[argument omitted]"))
        XCTAssertFalse(preview("npm", ["test", "--filter", String(repeating: "a", count: 40)]).contains(String(repeating: "a", count: 40)))
    }

    func testShellInterpreterAndTextPayloadsAreAlwaysHidden() {
        for (executable, flag) in [("zsh", "-lc"), ("bash", "-c"), ("python3", "-c"), ("node", "-e")] {
            let text = preview(executable, [flag, "cat /private/secret; echo hello", "private.txt"])
            XCTAssertFalse(text.contains("/private/secret"), text)
            XCTAssertFalse(text.contains("private.txt"), text)
            XCTAssertTrue(text.contains("script"))
        }
        for executable in ["printf", "echo", "sed", "awk"] {
            XCTAssertFalse(preview(executable, ["private.txt"]).contains("private.txt"))
        }
        XCTAssertEqual(preview("rg", ["private-query.swift", "Sources/"]), "rg [search pattern omitted] Sources/")
    }

    func testFileDetailsShowOnlyRequestedPathsRangesAndEditCounts() {
        let detail = ActivityDetail.metadata(name: "file_apply_edits", arguments: [
            "path": "Sources/Config.swift", "expected_sha256": "private-hash",
            "edits": [["old_text": "old-private", "new_text": "new-private"],
                      ["old_text": "other-private", "new_text": "replacement-private"]]])
        XCTAssertEqual(detail["targets"] as? [String], ["Sources/Config.swift"])
        XCTAssertEqual(detail["edit_count"] as? Int, 2)
        XCTAssertEqual(detail["edit_count_scope"] as? String, "requested")
        let encoded = encoded(detail)
        for forbidden in ["old-private", "new-private", "private-hash", "replacement-private"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
        let lines = ActivityDetail.metadata(name: "file_read_lines", arguments: [
            "path": "Sources/Config.swift", "start_line": 40, "maximum_lines": 56])
        XCTAssertEqual(lines["start_line"] as? Int, 40)
        XCTAssertEqual(lines["maximum_lines"] as? Int, 56)
        XCTAssertTrue(ActivityDetail.context(lines)?.contains("requested lines 40–95") == true)
        let replaceAll = ActivityDetail.metadata(name: "file_patch", arguments: ["path": "a.txt", "replace_all": true])
        XCTAssertEqual(replaceAll["edit_count"] as? Int, 1)
        XCTAssertEqual(replaceAll["edit_count_scope"] as? String, "requested")
    }

    func testBatchTargetsAreBoundedAndContentsAreExcluded() {
        let rows: [JSONObject] = (0..<16).map { ["path": "Sources/file-\($0).txt", "content": "never-display-content"] }
        let detail = ActivityDetail.metadata(name: "file_write_many", arguments: ["files": rows])
        XCTAssertEqual(detail["target_count"] as? Int, 16)
        XCTAssertEqual((detail["targets"] as? [String])?.count, 3)
        XCTAssertEqual(detail["preview_truncated"] as? Bool, true)
        XCTAssertFalse(encoded(detail).contains("never-display-content"))
        XCTAssertTrue(ActivityDetail.context(detail)?.contains("16 targets total") == true)
    }

    func testMaliciousControlsAndSensitivePathsAreOmittedNotReformatted() {
        for path in ["safe.txt\nFORGED SUCCESS", "file\u{001b}[31m.txt", "safe\u{202e}txt.exe",
                     "safe\u{2028}next.txt", "safe\u{2066}file.txt", "$(echo private).txt",
                     "/tmp/password.txt", "https://user:pass@example.com/file", "/tmp/file?key=private"] {
            let detail = ActivityDetail.metadata(name: "file_read", arguments: ["path": path])
            XCTAssertEqual(detail["targets"] as? [String], ["[path omitted]"], path)
            XCTAssertEqual(detail["preview_omitted"] as? Bool, true)
            XCTAssertFalse(encoded(detail).contains(path))
        }
        XCTAssertFalse(preview("swift", ["test\nFORGED SUCCESS"]).contains("FORGED SUCCESS"))
    }

    func testBoundsAreUTF8SafeAndDoNotOverflowLineRange() {
        let detail = ActivityDetail.metadata(name: "file_read", arguments: ["path": "/tmp/" + String(repeating: "測/", count: 160) + "a.txt"])
        let path = (detail["targets"] as? [String])?.first ?? ""
        XCTAssertLessThanOrEqual(path.utf8.count, 192)
        XCTAssertTrue(path.contains("truncated"))
        XCTAssertEqual(detail["preview_truncated"] as? Bool, true)
        let command = ActivityDetail.metadata(name: "command_start", arguments: ["executable": "swift",
            "arguments": Array(repeating: "--parallel", count: 128)])
        XCTAssertLessThanOrEqual((command["command_preview"] as? String ?? "").utf8.count, 512)
        XCTAssertEqual(command["preview_truncated"] as? Bool, true)
        let invalid = ActivityDetail.metadata(name: "file_read_lines", arguments: [
            "start_line": Int.max, "maximum_lines": true, "path": "a.txt"])
        XCTAssertNil(invalid["start_line"])
        XCTAssertNil(invalid["maximum_lines"])
    }

    func testUnknownInputFieldsAndStdinAreNotIncluded() {
        let result = ActivityDetail.metadata(name: "process_input", arguments: [
            "content": "private stdin", "environment": ["API_KEY": "private-key"],
            "path": "private.txt", "arguments": ["private argv"]])
        XCTAssertTrue(result.isEmpty)
        let unknown = preview("untrusted-binary-with-secret", ["private argv"])
        XCTAssertEqual(unknown, "[executable and arguments omitted]")
        let search = ActivityDetail.metadata(name: "file_search", arguments: ["path": "Sources", "query": "private-query"])
        XCTAssertFalse(encoded(search).contains("private-query"))
    }

    private func preview(_ executable: String, _ arguments: [String]) -> String {
        ActivityDetail.metadata(name: "command_start", arguments: ["executable": executable, "arguments": arguments])["command_preview"] as? String ?? ""
    }

    private func encoded(_ value: JSONObject) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}
