import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class WorkspaceEfficiencyTests: XCTestCase {
    func testFullReadReusesDigestWithoutChangingUnicodeOrBinaryChunks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let unicode = Data("ab🙂Xin chào\n".utf8)
        let binary = Data((0..<257).map { UInt8(truncatingIfNeeded: $0) })
        for (name, data, encoding) in [
            ("unicode.txt", unicode, "utf8"),
            ("binary.bin", binary, "base64"),
            ("empty.txt", Data(), "utf8"),
            ("empty.bin", Data(), "base64"),
        ] {
            try data.write(to: fixture.workspace.appendingPathComponent(name))
            let full = try fileObject(service.readFile(
                workspaceID: fixture.workspaceID, path: name,
                encoding: encoding, maximumBytes: 1_024))
            XCTAssertEqual(full["chunk_sha256"] as? String, LocalHash.sha256(data))
            XCTAssertEqual(full["sha256"] as? String, LocalHash.sha256(data))
            XCTAssertEqual(full["eof"] as? Bool, true)
            XCTAssertEqual(full["byte_count"] as? Int, data.count)
            XCTAssertEqual(full["content"] as? String,
                           encoding == "utf8" ? String(data: data, encoding: .utf8) : data.base64EncodedString())
        }

        let firstUnicode = try fileObject(service.readFile(
            workspaceID: fixture.workspaceID, path: "unicode.txt", encoding: "utf8",
            maximumBytes: 4))
        XCTAssertEqual(firstUnicode["content"] as? String, "ab🙂")
        XCTAssertEqual(firstUnicode["chunk_sha256"] as? String, LocalHash.sha256(Data("ab🙂".utf8)))
        XCTAssertNil(firstUnicode["sha256"])
        let nextOffset = try XCTUnwrap(firstUnicode["next_offset"] as? Int)
        let tailUnicode = try fileObject(service.readFile(
            workspaceID: fixture.workspaceID, path: "unicode.txt", encoding: "utf8",
            maximumBytes: 1_024, offset: nextOffset))
        XCTAssertEqual(tailUnicode["content"] as? String, "Xin chào\n")
        XCTAssertEqual(tailUnicode["chunk_sha256"] as? String,
                       LocalHash.sha256(Data("Xin chào\n".utf8)))
        XCTAssertNil(tailUnicode["sha256"])
        XCTAssertEqual(tailUnicode["eof"] as? Bool, true)

        let partialBinary = try fileObject(service.readFile(
            workspaceID: fixture.workspaceID, path: "binary.bin", encoding: "base64",
            maximumBytes: 31, offset: 17))
        let expectedBinary = binary.subdata(in: 17..<48)
        XCTAssertEqual(partialBinary["content"] as? String, expectedBinary.base64EncodedString())
        XCTAssertEqual(partialBinary["chunk_sha256"] as? String, LocalHash.sha256(expectedBinary))
        XCTAssertNil(partialBinary["sha256"])
        XCTAssertEqual(partialBinary["next_offset"] as? Int, 48)
    }

    func testLazySearchPreservesLFEmptyTrailingCRLFUnicodeAndPaginationSemantics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let marker = "needle(foo)[x]."
        let cases = [
            "",
            "\n\n",
            "\n\(marker) first\n\n\(marker) last\n",
            "\(marker) first\r\nplain\r\n\(marker) last\r\n",
            "one\r\n\(marker)\n\n\(marker)\r\nend\n",
            "á\n🙂 \(marker) Xin chào\nplain\n\(marker) 🧪",
            "\(marker) early\n" + String(repeating: "plain\n", count: 2_000) + "\(marker) late\n",
        ]
        for (index, content) in cases.enumerated() {
            let directory = "case-\(index)"
            let directoryURL = fixture.workspace.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            try Data(content.utf8).write(to: directoryURL.appendingPathComponent("sample.txt"))
            // The old implementation split by a Character LF, not by arbitrary newline scalars.
            // This reference deliberately retains its CRLF and trailing-empty-line behavior.
            let expected = content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().filter { $0.element.contains(marker) }
            let matches = try allSearchPages(service, fixture: fixture, path: directory,
                                             query: marker, caseSensitive: true)
            XCTAssertEqual(matches.compactMap { $0["line"] as? Int }, expected.map { $0.offset + 1 })
            XCTAssertEqual(matches.compactMap { $0["preview"] as? String },
                           expected.map { String($0.element.prefix(500)) })
            XCTAssertTrue(matches.allSatisfy { ($0["relative_path"] as? String) == "\(directory)/sample.txt" })
        }
    }

    func testSearchPrecomputedNeedlePreservesCaseSensitiveAndInsensitiveNamesAndContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let name = "Xin CHÀO 🧪.txt"
        let content = "Xin CHÀO\nxin chào\nnot a match\n"
        try Data(content.utf8).write(to: fixture.workspace.appendingPathComponent(name))
        let insensitiveNames = try allSearchPages(service, fixture: fixture, path: ".",
                                                  query: "chào", caseSensitive: false, mode: "name")
        XCTAssertEqual(insensitiveNames.compactMap { $0["relative_path"] as? String }, [name])
        let sensitiveNames = try allSearchPages(service, fixture: fixture, path: ".",
                                                query: "chào", caseSensitive: true, mode: "name")
        XCTAssertTrue(sensitiveNames.isEmpty)
        let insensitiveContent = try allSearchPages(service, fixture: fixture, path: ".",
                                                    query: "CHÀO", caseSensitive: false)
        XCTAssertEqual(insensitiveContent.compactMap { $0["line"] as? Int }, [1, 2])
        let sensitiveContent = try allSearchPages(service, fixture: fixture, path: ".",
                                                  query: "CHÀO", caseSensitive: true)
        XCTAssertEqual(sensitiveContent.compactMap { $0["line"] as? Int }, [1])
    }

    func testLazySearchMatchesLineSemanticsForUnicodeNewlinesAndInterleavedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let cases: [(String, String, Bool)] = [
            (String(repeating: "plain\n", count: 10_000), "absent", true),
            ("\n\nfirst needle(foo)[x].\n" + String(repeating: "plain\n", count: 5_000)
                + "last needle(foo)[x].\n", "needle(foo)[x].", true),
            ("caf\u{e9}\nplain\ncafe\u{301}\n", "café", true),
            ("👩‍💻 first\nplain\n👩‍💻 last\n", "👩‍💻", true),
            ("first\nsecond\n", "first\nsecond", true),
            ("first\r\nsecond\r\n", "\r\n", true),
            ("\nfirst\r\nsecond\nlast\r\n", "second", true),
            ("Xin CHÀO\nplain\nxin chào\n", "chào", false),
        ]
        for (index, item) in cases.enumerated() {
            let (content, query, caseSensitive) = item
            let path = "reject-\(index)"
            let directory = fixture.workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let files = [("a.txt", "unrelated\n"), ("b.txt", content), ("c.txt", "unrelated again\n"), ("d.txt", content)]
            var expected: [(String, Int, String)] = []
            let needle = caseSensitive ? query : query.lowercased()
            for (name, text) in files {
                try Data(text.utf8).write(to: directory.appendingPathComponent(name))
                for (lineNumber, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let candidate = caseSensitive ? String(line) : line.lowercased()
                    if candidate.contains(needle) {
                        expected.append(("\(path)/\(name)", lineNumber + 1, String(line.prefix(500))))
                    }
                }
            }
            let actual = try allSearchPages(service, fixture: fixture, path: path,
                                            query: query, caseSensitive: caseSensitive)
            XCTAssertEqual(actual.compactMap { $0["relative_path"] as? String }, expected.map { $0.0 })
            XCTAssertEqual(actual.compactMap { $0["line"] as? Int }, expected.map { $0.1 })
            XCTAssertEqual(actual.compactMap { $0["preview"] as? String }, expected.map { $0.2 })
            let unpaged = try service.searchFiles(
                workspaceID: fixture.workspaceID, path: path, query: query,
                caseSensitive: caseSensitive, maximumResults: 100,
                maximumFileBytes: 1_048_576)
            XCTAssertEqual(unpaged["scanned_files"] as? Int, 4)
            XCTAssertEqual(unpaged["scanned_entries"] as? Int, 4)
            XCTAssertEqual(unpaged["complete"] as? Bool, true)
        }
    }

    func testPatchCountsNonoverlappingMatchesAndRestoresExactBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let cases = [
            ("aaaa", "aa", "b"),
            ("aaa", "aa", "b"),
            ("aaaaa", "aa", "b"),
            ("é e\u{301} é", "é", "🧪"),
            ("🙂🙂🙂", "🙂🙂", "é"),
            ("prefix needle(foo)[x]. suffix", "needle(foo)[x].", "done"),
        ]
        for (index, item) in cases.enumerated() {
            let (content, oldText, newText) = item
            let name = "patch-\(index).txt"
            let url = fixture.workspace.appendingPathComponent(name)
            let baseline = Data(content.utf8)
            let baselineHash = LocalHash.sha256(baseline)
            try baseline.write(to: url)
            let expectedCount = content.components(separatedBy: oldText).count - 1
            XCTAssertGreaterThan(expectedCount, 0)
            if expectedCount > 1 {
                XCTAssertThrowsError(try service.patchFile(
                    workspaceID: fixture.workspaceID, path: name,
                    oldText: oldText, newText: newText, replaceAll: false,
                    expectedSHA256: baselineHash))
                XCTAssertEqual(try Data(contentsOf: url), baseline)
                XCTAssertEqual(service.retainedTransactionCount, 0)
            }
            let patch = try service.patchFile(
                workspaceID: fixture.workspaceID, path: name,
                oldText: oldText, newText: newText, replaceAll: expectedCount > 1,
                expectedSHA256: baselineHash)
            XCTAssertEqual(patch["replacements"] as? Int, expectedCount)
            XCTAssertEqual(try Data(contentsOf: url),
                           Data(content.replacingOccurrences(of: oldText, with: newText).utf8))
            _ = try service.restoreTransaction(try XCTUnwrap(patch["transaction_id"] as? String))
            XCTAssertEqual(try Data(contentsOf: url), baseline)
            XCTAssertEqual(service.retainedTransactionCount, 0)
        }
    }

    func testRejectedPatchPreservesBytesAndDoesNotRetainUndoPayload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        let url = fixture.workspace.appendingPathComponent("unchanged.txt")
        let baseline = Data(String(repeating: "x", count: 10_000).utf8)
        try baseline.write(to: url)
        let hash = LocalHash.sha256(baseline)
        for (oldText, expectedHash) in [("x", hash), ("absent", hash), ("x", String(repeating: "0", count: 64))] {
            XCTAssertThrowsError(try service.patchFile(
                workspaceID: fixture.workspaceID, path: "unchanged.txt",
                oldText: oldText, newText: "changed", replaceAll: false,
                expectedSHA256: expectedHash))
            XCTAssertEqual(try Data(contentsOf: url), baseline)
            XCTAssertEqual(service.retainedTransactionCount, 0)
        }
    }

    private func fileObject(_ result: JSONObject) throws -> JSONObject {
        try XCTUnwrap(result["file"] as? JSONObject)
    }

    private func allSearchPages(
        _ service: LocalWorkspaceService,
        fixture: Fixture,
        path: String,
        query: String,
        caseSensitive: Bool,
        mode: String = "content"
    ) throws -> [JSONObject] {
        var collected: [JSONObject] = []
        var cursor = 0
        for _ in 0..<100 {
            let page = try service.searchFiles(
                workspaceID: fixture.workspaceID, path: path, query: query,
                caseSensitive: caseSensitive, maximumResults: 1,
                maximumFileBytes: 1_048_576, mode: mode, cursor: cursor)
            let matches = try XCTUnwrap(page["matches"] as? [JSONObject])
            collected += matches
            if page["complete"] as? Bool == true { return collected }
            let next = try XCTUnwrap(page["next_cursor"] as? Int)
            XCTAssertGreaterThan(next, cursor)
            cursor = next
        }
        XCTFail("search pagination did not terminate")
        return collected
    }
}
