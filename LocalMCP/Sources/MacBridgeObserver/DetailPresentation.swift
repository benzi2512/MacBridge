import Foundation

/// UI navigation stores cursors, not an ever-growing transcript. Owner peeks never
/// consume a completed process handle; output retained/dropped by the owner is
/// still authoritative. One page stays bounded to the endpoint's 8 KiB/stream.
struct OutputCursor: Equatable {
    var stdout = 0
    var stderr = 0
}

struct OutputPage {
    let start: OutputCursor
    let next: OutputCursor
    let hasMore: Bool
    let running: Bool
    let lostBytes: Int
    let text: String
    let stdout: String
    let stderr: String
    let stdoutRange: String
    let stderrRange: String

    init?(_ result: [String: Any]) {
        guard let out = result["stdout"] as? String, let err = result["stderr"] as? String,
              let os = result["stdout_cursor"] as? Int, let es = result["stderr_cursor"] as? Int,
              let on = result["stdout_next_cursor"] as? Int, let en = result["stderr_next_cursor"] as? Int,
              let ot = result["stdout_total_bytes"] as? Int, let et = result["stderr_total_bytes"] as? Int,
              0 <= os, os <= on, on <= ot, 0 <= es, es <= en, en <= et,
              out.utf8.count <= 8195, err.utf8.count <= 8195 else { return nil }
        start = OutputCursor(stdout: os, stderr: es)
        next = OutputCursor(stdout: on, stderr: en)
        hasMore = on < ot || en < et
        running = result["running"] as? Bool == true
        stdout = out; stderr = err
        stdoutRange = "bytes \(os)..<\(on) of \(ot)"
        stderrRange = "bytes \(es)..<\(en) of \(et)"
        // Each difference is bounded by an individual stream counter. Saturate
        // rather than overflow when rendering malformed/unexpected metadata.
        let a = max(0, result["stdout_dropped_before_cursor"] as? Int ?? 0)
        let b = max(0, result["stderr_dropped_before_cursor"] as? Int ?? 0)
        let sum = a.addingReportingOverflow(b)
        lostBytes = sum.overflow ? Int.max : sum.partialValue
        let warning = lostBytes > 0 ? "Owner discarded \(lostBytes) earlier bytes; this page begins at retained output.\n\n" : ""
        text = warning + "STDOUT · bytes \(os)..<\(on) of \(ot)\n" + (out.isEmpty ? "(empty)" : out)
            + "\n\nSTDERR · bytes \(es)..<\(en) of \(et)\n" + (err.isEmpty ? "(empty)" : err)
    }
}

/// Human-readable fields come only from explicit owner receipts. Missing fields
/// remain missing, and a batch receipt does not imply every item succeeded.
enum DetailPresentation {
    enum Kind { case event, output, change, metadata }
    struct Field: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    static func fields(_ raw: [String: Any], kind: Kind) -> [Field] {
        let result = kind == .event ? raw["result"] as? [String: Any] ?? [:] : raw
        var rows: [Field] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(Field(label: label, value: String(value.prefix(1024)))) }
        }
        if kind == .output {
            let status: String
            if result["cancelled"] as? Bool == true { status = "Cancelled" }
            else if result["timed_out"] as? Bool == true { status = "Timed out" }
            else if result["running"] as? Bool == true { status = "Running at last read" }
            else if let code = result["exit_code"] as? Int { status = "Exited · \(code)" }
            else { status = "Unknown" }
            add("Process", status)
        }
        for (label, key) in [("Tool", "tool"), ("Path", "path"), ("Folder", "cwd"),
                             ("Job", "task_id"), ("Undo", "transaction_id"), ("Operation", "operation")] {
            add(label, raw[key] as? String ?? result[key] as? String)
        }
        if let detail = raw["detail"] as? [String: Any] {
            add("Requested command", detail["command_preview"] as? String)
            let targets = Array((detail["targets"] as? [String] ?? []).prefix(3))
            if !targets.isEmpty { add("Requested targets", targets.joined(separator: "\n")) }
            if let count = detail["target_count"] as? Int, count > targets.count {
                add("Target scope", "\(max(0, count)) requested targets · first \(targets.count) shown")
            }
            if let start = detail["start_line"] as? Int {
                add("Requested lines", "From line \(start)" + ((detail["maximum_lines"] as? Int).map { " · up to \($0) lines" } ?? ""))
            }
            if let edits = detail["edit_count"] as? Int {
                add("Requested edits", "\(max(0, edits)) · not an applied-change count")
            }
            if detail["preview_omitted"] as? Bool == true { add("Preview", "Some arguments or targets are hidden to protect sensitive values.") }
            else if detail["preview_truncated"] as? Bool == true { add("Preview", "Bounded preview · some details omitted.") }
        }
        if let mutation = result["mutation_performed"] as? Bool {
            add("File change", mutation ? "Backend confirmed a mutation" : "No mutation reported")
            if mutation {
                if let edits = result["edits_applied"] as? Int { add("Applied edits", String(edits)) }
                if let replacements = result["replacements"] as? Int { add("Applied replacements", String(replacements)) }
            }
        }
        add("Error", result["error"] as? String)
        return rows
    }

    static func metadata(_ raw: [String: Any]) -> [String: Any] {
        var trimmed = raw.filter { !["before", "after", "stdout", "stderr"].contains($0.key) }
        if let result = raw["result"] as? [String: Any] { trimmed["result"] = metadata(result) }
        return trimmed
    }

    static func receiptSummary(_ result: [String: Any], action: String) -> String {
        if let error = result["error"] as? String { return "Owner reported: " + String(error.prefix(512)) }
        if action == "cancel" {
            return result["cancelled"] as? Bool == true ? "Owner confirmed cancellation of the selected job."
                : "Cancellation request returned. Check the selected job’s current state."
        }
        if action == "restore", result["mutation_performed"] as? Bool == true {
            return "Owner confirmed a restore mutation. Inspect the file to verify its contents."
        }
        return "Owner returned a receipt. Inspect the current state before assuming the requested change completed."
    }
}

/// Linear-time, single-hunk unified comparison. This deliberately does not run
/// a quadratic minimal-edit algorithm on the main actor or invoke a shell.
/// It is complete only when both owner text inputs are complete. A truncated
/// input is always labeled a preview and never presented as a complete diff.
enum TextComparison {
    private struct Line: Equatable {
        let text: String
        let terminated: Bool
        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.terminated == rhs.terminated && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }

    private static func lines(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        var parts = text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        let terminated = text.utf8.last == 10
        if terminated { parts.removeLast() }
        return parts.enumerated().map { Line(text: $0.element, terminated: $0.offset < parts.count - 1 || terminated) }
    }

    static func render(_ result: [String: Any]) -> String? {
        guard let rawBefore = result["before"] as? String, let after = result["after"] as? String else { return nil }
        let provenance = "Source: owner-local file transaction; not shell-attributed changes.\n"
        guard rawBefore.utf8.count <= 8195, after.utf8.count <= 8195 else {
            return provenance + "Text comparison exceeds the bounded preview limit."
        }
        guard result["before_is_text"] as? Bool == true, result["after_is_text"] as? Bool == true else {
            return provenance + "Text diff unavailable: binary/non-UTF8 data or legacy owner without text-format metadata.\n\nBEFORE\n"
                + rawBefore + "\n\nCURRENT\n" + after
        }
        let exists = result["before_exists"] as? Bool != false
        let before = exists ? rawBefore : ""
        let complete = result["before_truncated"] as? Bool == false && result["after_truncated"] as? Bool == false
        let scope = complete ? "Complete text comparison (one contiguous change hunk).\n" : "PARTIAL PREVIEW: owner truncated at least one input. This is NOT a complete file diff.\n"
        let old = lines(before), new = lines(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        if prefix == old.count && prefix == new.count {
            if !exists && complete { return provenance + scope + "New empty file; no text lines to diff." }
            return provenance + scope + (complete ? "No text changes." : "No changes in the returned preview; unseen content may differ.")
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let lower = max(0, prefix - 3)
        let oldChangedEnd = old.count - suffix, newChangedEnd = new.count - suffix
        let context = min(3, suffix)
        let oldEnd = oldChangedEnd + context, newEnd = newChangedEnd + context
        let oldCount = oldEnd - lower, newCount = newEnd - lower
        var rendered = provenance + scope + "--- " + (exists ? "before" : "/dev/null") + "\n+++ current\n"
        rendered += "@@ -\(oldCount == 0 ? lower : lower + 1),\(oldCount) +\(newCount == 0 ? lower : lower + 1),\(newCount) @@\n"
        func append(_ line: Line, _ mark: String) {
            rendered += mark + line.text + "\n"
            if !line.terminated { rendered += "\\ No newline at end of file\n" }
        }
        for i in lower..<prefix { append(old[i], " ") }
        for i in prefix..<oldChangedEnd { append(old[i], "-") }
        for i in prefix..<newChangedEnd { append(new[i], "+") }
        for i in oldChangedEnd..<oldEnd { append(old[i], " ") }
        return rendered
    }
}
