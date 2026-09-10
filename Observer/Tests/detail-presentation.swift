import Foundation

// Pure synthetic, bounded data. No filesystem, subprocess, network or credentials.
@main
enum DetailPresentationTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        func diff(_ before: String, _ after: String, complete: Bool = true, exists: Bool = true) -> String {
            TextComparison.render(["before": before, "after": after, "before_exists": exists,
                "before_is_text": true, "after_is_text": true,
                "before_truncated": !complete, "after_truncated": !complete])!
        }
        let replacement = diff("a\nb\nc\n", "a\nB\nc\n")
        check(replacement.contains("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"), "replacement and context")
        check(diff("", "x\n", exists: false).contains("--- /dev/null\n+++ current\n@@ -0,0 +1,1 @@\n+x\n"), "new file")
        check(!diff("[File did not exist]", "x\n", exists: false).contains("-[File did not exist]"), "absence not literal file text")
        check(diff("", "", exists: false).contains("New empty file"), "empty creation")
        check(diff("x\n", "").contains("@@ -1,1 +0,0 @@\n-x\n"), "remove last line")
        check(diff("same\n", "same\n").contains("No text changes."), "identical complete input")
        check(diff("same", "same", complete: false).contains("unseen content may differ"), "identical preview not complete")
        check(diff("old", "new", complete: false).contains("PARTIAL PREVIEW"), "partial diff marked")
        check(diff("old", "new").components(separatedBy: "\\ No newline at end of file").count == 3, "both absent newlines")
        check(diff("same", "same\n").contains("-same\n\\ No newline at end of file\n+same\n"), "newline-only change")
        check(diff("a\r\nb\r\n", "a\r\nB\r\n").contains("@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n"), "CRLF is two lines")
        check(diff("é\n", "e\u{301}\n").contains("-é\n+e\u{301}\n"), "normalization is byte change")
        check(diff("🌏\n", "🌍\n").contains("-🌏\n+🌍\n"), "unicode intact")
        let common = (0..<20).map { "line\($0)\n" }.joined()
        check(diff(common + "old\n", common + "new\n").contains("@@ -18,4 +18,4 @@"), "bounded context offset")
        check(TextComparison.render(["before": "old", "after": "new"])!.contains("legacy owner"), "legacy metadata fallback")
        check(TextComparison.render(["before": "[binary]", "after": "[binary]", "before_is_text": false])!.contains("Text diff unavailable"), "binary not textual diff")
        check(diff(String(repeating: "a", count: 9000), "b").contains("exceeds"), "oversized input bounded")
        check(TextComparison.render([:]) == nil, "path metadata not invented text")
        var result: [String: Any] = ["stdout": "abc", "stderr": "é", "stdout_cursor": 0, "stderr_cursor": 0,
            "stdout_next_cursor": 3, "stderr_next_cursor": 2, "stdout_total_bytes": 9, "stderr_total_bytes": 2, "running": true]
        let first = OutputPage(result)!
        check(first.hasMore, "remaining output")
        check(first.next == OutputCursor(stdout: 3, stderr: 2), "independent cursors")
        check(first.text.contains("bytes 0..<3 of 9"), "byte range shown")
        check(first.running, "live EOF can refresh")
        check(first.stdout == "abc" && first.stderr == "é", "streams separate without transformation")
        check(first.stderrRange == "bytes 0..<2 of 2", "UTF8 byte range")
        result["stdout_total_bytes"] = 3; result["running"] = false
        check(!OutputPage(result)!.hasMore, "terminal EOF")
        result["stdout_dropped_before_cursor"] = 10
        check(OutputPage(result)!.text.contains("discarded 10 earlier bytes"), "rollover disclosed")
        result["stderr_dropped_before_cursor"] = Int.max
        check(OutputPage(result)!.lostBytes == Int.max, "malformed overflow saturates")
        result["stdout_next_cursor"] = 4
        check(OutputPage(result) == nil, "cursor beyond total rejected")
        result["stdout_next_cursor"] = 3; result["stdout_cursor"] = -1
        check(OutputPage(result) == nil, "negative cursor rejected")
        result["stdout_cursor"] = 0; result["stdout"] = String(repeating: "x", count: 9000)
        check(OutputPage(result) == nil, "oversized page rejected")
        let event: [String: Any] = ["tool": "command_run", "path": "sample.txt", "result": ["task_id": "job-1", "error": "refused", "stdout": "output", "stderr": "err"]]
        let fields = DetailPresentation.fields(event, kind: .event)
        check(fields.contains { $0.label == "Job" && $0.value == "job-1" }, "nested receipt field")
        check(fields.contains { $0.label == "Error" && $0.value == "refused" }, "human error field")
        check(!fields.contains { $0.value == "output" }, "streams not summary fields")
        check(DetailPresentation.fields([:], kind: .metadata).isEmpty, "no invented metadata")
        check(DetailPresentation.fields(["running": true], kind: .output).first?.value == "Running at last read", "output snapshot not live claim")
        check(DetailPresentation.fields(["exit_code": 0], kind: .output).first?.value == "Exited · 0", "exit zero not test pass")
        check(DetailPresentation.fields(["cancelled": true, "exit_code": 15], kind: .output).first?.value == "Cancelled", "cancel precedence")
        check(DetailPresentation.fields(["timed_out": true], kind: .output).first?.value == "Timed out", "timeout presentation")
        let metadata = DetailPresentation.metadata(event)
        check((metadata["result"] as? [String: Any])?["stdout"] == nil, "metadata excludes nested streams")
        check((metadata["result"] as? [String: Any])?["error"] as? String == "refused", "metadata keeps errors")
        check(DetailPresentation.metadata(["before": "old", "after": "new", "path": "file"]).count == 1, "diff not duplicated")
        check(DetailPresentation.receiptSummary([:], action: "cancel").contains("Check"), "acknowledgement not invented cancellation")
        check(DetailPresentation.receiptSummary(["cancelled": true], action: "cancel").contains("confirmed"), "confirmed cancellation")
        check(DetailPresentation.receiptSummary([:], action: "restore").contains("before assuming"), "restore requires evidence")
        check(DetailPresentation.receiptSummary(["mutation_performed": true], action: "restore").contains("confirmed a restore mutation"), "restore mutation receipt")
        check(DetailPresentation.receiptSummary(["error": "conflict"], action: "restore").contains("conflict"), "refusal not success")
        print("PASS: \(checks) detail presentation checks")
    }
}
