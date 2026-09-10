import Foundation
import XCTest

@testable import MacBridgeLocalCore

final class ASCIISearchPerformanceTests: XCTestCase {
    func testASCIIByteSearchMatchesLegacyLineResultsAndPagination() throws {
        let query = "needle(foo)[x]."
        try compareWithLegacy([
            ("a.txt", ""),
            ("b.txt", "\n\n"),
            ("c.txt", "\n\(query) first \(query) repeated\n\nplain\n\(query) last\n"),
            ("d.txt", "no match\n"),
            ("e.txt", "leading " + String(repeating: "p", count: 700) + query + "\n"),
            ("f.txt", String(repeating: "plain\n", count: 2_000) + query),
        ], query: query)
    }

    func testASCIIByteSearchHandlesNULControlsAndOverlappingOccurrencesOncePerLine() throws {
        try compareWithLegacy([
            ("a.txt", "\0 first\nplain\n\0\0 final\n"),
            ("b.txt", "no NUL here\n"),
        ], query: "\0")
        try compareWithLegacy([
            ("a.txt", "aaaaa\naaaaaaaa\naa\na\n"),
            ("b.txt", "\n\naaaa"),
        ], query: "aa")
        try compareWithLegacy([
            ("a.txt", "tab\tmarker\n\t\t\ncontrol\u{7f}end\n"),
        ], query: "\t")
        try compareWithLegacy([
            ("a.txt", "control\u{7f}end\nplain\n\u{7f}"),
        ], query: "\u{7f}")
    }

    func testAnyUnicodeCRNewlineQueryOrInsensitiveSearchPreservesFallbackSemantics() throws {
        try compareWithLegacy([
            ("a.txt", "needle first\n" + String(repeating: "plain\n", count: 2_000) + "é"),
            ("b.txt", "needle\r\nplain\r\nneedle\r\n"),
            ("c.txt", "needle first\nplain\nneedle final\r"),
            ("d.txt", "👩‍💻 needle\nplain\nneedle 🧪\n"),
        ], query: "needle")
        try compareWithLegacy([
            ("a.txt", "first\nsecond\n"),
            ("b.txt", "first\r\nsecond\r\n"),
        ], query: "first\nsecond")
        try compareWithLegacy([
            ("a.txt", "first\r\nsecond\r\n"),
            ("b.txt", "first\nsecond\n"),
        ], query: "\r")
        try compareWithLegacy([
            ("a.txt", "caf\u{e9}\nplain\ncafe\u{301}\n"),
        ], query: "café")
        try compareWithLegacy([
            ("a.txt", "ASCII NEEDLE\nASCII needle\n"),
            ("b.txt", "Xin CHÀO\nxin chào\n"),
        ], query: "needle", caseSensitive: false)
        try compareWithLegacy([
            ("a.txt", "Xin CHÀO\nxin chào\n"),
        ], query: "chào", caseSensitive: false)
    }

    func testNoMatchCountsEveryEligibleFileWithoutFalseIncompletePage() throws {
        try compareWithLegacy([
            ("a.txt", String(repeating: "plain filler\n", count: 20_000)),
            ("b.txt", ""),
            ("c.txt", "\n\nlast line\n"),
        ], query: "not-present")
    }

    func testPageLookaheadCountsDistinctLinesIncludingLaterFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        try Data("needle needle needle\n".utf8).write(to: fixture.workspace.appendingPathComponent("a.txt"))
        try Data("\nplain\nneedle\n".utf8).write(to: fixture.workspace.appendingPathComponent("b.txt"))
        let first = try service.searchFiles(
            workspaceID: fixture.workspaceID, path: ".", query: "needle", caseSensitive: true,
            maximumResults: 1, maximumFileBytes: 1_048_576)
        XCTAssertEqual((first["matches"] as? [JSONObject])?.count, 1)
        XCTAssertEqual(first["next_cursor"] as? Int, 1)
        XCTAssertEqual(first["scanned_files"] as? Int, 2)
        XCTAssertEqual(first["complete"] as? Bool, false)
        let last = try service.searchFiles(
            workspaceID: fixture.workspaceID, path: ".", query: "needle", caseSensitive: true,
            maximumResults: 1, maximumFileBytes: 1_048_576, cursor: 1)
        let match = try XCTUnwrap((last["matches"] as? [JSONObject])?.first)
        XCTAssertEqual(match["relative_path"] as? String, "b.txt")
        XCTAssertEqual(match["line"] as? Int, 3)
        XCTAssertEqual(last["complete"] as? Bool, true)
        XCTAssertNil(last["next_cursor"])
        let finalCursor = try service.searchFiles(
            workspaceID: fixture.workspaceID, path: ".", query: "needle", caseSensitive: true,
            maximumResults: 1, maximumFileBytes: 1_048_576, cursor: 2)
        XCTAssertTrue(try XCTUnwrap(finalCursor["matches"] as? [JSONObject]).isEmpty)
        XCTAssertEqual(finalCursor["complete"] as? Bool, true)
        XCTAssertThrowsError(try service.searchFiles(
            workspaceID: fixture.workspaceID, path: ".", query: "needle", caseSensitive: true,
            maximumResults: 1, maximumFileBytes: 1_048_576, cursor: 3))
    }

    private func compareWithLegacy(
        _ files: [(String, String)], query: String, caseSensitive: Bool = true
    ) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try fixture.service()
        var expected: [(String, Int, String)] = []
        let needle = caseSensitive ? query : query.lowercased()
        for (name, text) in files.sorted(by: { $0.0 < $1.0 }) {
            try Data(text.utf8).write(to: fixture.workspace.appendingPathComponent(name))
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let candidate = caseSensitive ? String(line) : line.lowercased()
                if candidate.contains(needle) {
                    expected.append((name, index + 1, String(line.prefix(500))))
                }
            }
        }
        for pageSize in [1, 2, 100] {
            var actual: [JSONObject] = []
            var cursor = 0
            var complete = false
            for _ in 0..<100 {
                let page = try service.searchFiles(
                    workspaceID: fixture.workspaceID, path: ".", query: query,
                    caseSensitive: caseSensitive, maximumResults: pageSize,
                    maximumFileBytes: 1_048_576, cursor: cursor)
                XCTAssertEqual(page["cursor"] as? Int, cursor)
                XCTAssertEqual(page["partial"] as? Bool, false)
                XCTAssertEqual(page["limit_reached"] as? Bool, false)
                actual += try XCTUnwrap(page["matches"] as? [JSONObject])
                if page["complete"] as? Bool == true {
                    XCTAssertEqual(page["scanned_files"] as? Int, files.count)
                    XCTAssertEqual(page["scanned_entries"] as? Int, files.count)
                    XCTAssertNil(page["next_cursor"])
                    complete = true
                    break
                }
                let next = try XCTUnwrap(page["next_cursor"] as? Int)
                XCTAssertGreaterThan(next, cursor)
                cursor = next
            }
            XCTAssertTrue(complete, "pagination must terminate")
            XCTAssertEqual(actual.compactMap { $0["relative_path"] as? String }, expected.map { $0.0 })
            XCTAssertEqual(actual.compactMap { $0["line"] as? Int }, expected.map { $0.1 })
            XCTAssertEqual(actual.compactMap { $0["preview"] as? String }, expected.map { $0.2 })
        }
    }
}
