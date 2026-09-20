import Foundation
import CoreFoundation

/// Small text companion to the unchanged structured result. No I/O, polling,
/// raw request arguments, file contents or stdout/stderr are copied into this label.
/// ActivityDetail supplies a separate allowlisted command/path preview when available.
/// The host still decides how (or whether) to display it in its activity UI.
enum ToolResultSummary {
    static func text(name: String, result r: JSONObject, arguments: JSONObject = [:],
                     processContext: String? = nil,
                     nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> String {
        let label = name.replacingOccurrences(of: "_", with: " ")
        // continue_task wraps the actual process receipt. Read that receipt, not
        // a guessed task percentage, a caller title or text parsed from stdout.
        let process = name == "developer_task" ? (r["process"] as? JSONObject ?? r) : r
        var detail = "Result returned"
        var partial = r["partial"] as? Bool == true || r["complete"] as? Bool == false
        let failed = r["isError"] as? Bool == true || r["error"] != nil || r["status"] as? String == "error"
        if failed {
            // A failed or ambiguous call is not evidence that the requested edit happened.
            detail = "Call failed; inspect error and any available receipt"
        } else if name == "media_inspect" || name == "media_share" {
            if r["share_state"] as? String == "revoked" { detail = "Staged object absent after revocation; downloaded copies are unaffected" }
            else if r["link_available"] as? Bool == true { detail = "Creative staged with an expiring link; not uploaded to Meta" }
            else if r["link_expired"] as? Bool == true { detail = "Transfer link expired; storage deletion is separate" }
            else { detail = "Media inspection returned; no new public link" }
            if let bytes = nonnegative(r["byte_count"]) { detail += "; \(bytes) bytes" }
        } else if name == "desktop_open", r["request_accepted"] as? Bool == true {
            detail = "macOS accepted the desktop request; window visibility is not verified"
        } else if name == "bridge_capabilities", let count = nonnegative(r["catalog_count"]) {
            detail = "Runtime reachable; \(count) catalog tools; host loading not verified by this receipt"
        } else if name == "work_task" {
            detail = workSummary(r)
        } else if name == "developer_inspect" {
            detail = inspectionSummary(r)
        } else if let rows = r["results"] as? [JSONObject] {
            let errors = r["error_count"] as? Int ?? rows.filter { $0["status"] as? String == "error" }.count
            let skipped = r["skipped_count"] as? Int ?? rows.filter { $0["status"] as? String == "skipped_budget" }.count
            partial = partial || errors > 0 || skipped > 0 || rows.contains {
                $0["complete"] as? Bool == false || ($0["file"] as? JSONObject)?["eof"] as? Bool == false
            }
            detail = "\(rows.count) item results; \(errors) item-call errors; \(skipped) skipped"
            if let count = r["read_count"] as? Int { detail += "; \(count) files read" }
            if let count = r["success_count"] as? Int { detail += "; \(count) writes applied" }
            if name == "process_status_many" || name == "process_output_many" {
                let jobs = rows.compactMap { $0["result"] as? JSONObject }
                detail += "; \(jobs.filter { $0["running"] as? Bool == true }.count) running"
                detail += "; \(jobs.filter { ($0["exit_code"] as? Int).map { $0 != 0 } == true }.count) nonzero exits"
                detail += "; \(jobs.filter { $0["timed_out"] as? Bool == true }.count) timed out"
                detail += "; \(jobs.filter { $0["cancelled"] as? Bool == true }.count) cancelled"
                if jobs.contains(where: { $0["stdout_truncated"] as? Bool == true || $0["stderr_truncated"] as? Bool == true }) {
                    detail += "; some job output truncated"
                }
            }
        } else if name == "process_input", let count = r["bytes_written"] as? Int {
            detail = "\(count) input bytes written"
            if r["input_complete"] as? Bool == false { detail += "; input incomplete; reconcile before retrying" }
            if r["stdin_closed"] as? Bool == true { detail += "; stdin closed" }
        } else if let running = process["running"] as? Bool {
            if running { detail = "Process running" }
            else if let code = process["exit_code"] as? Int { detail = "Process exited with code \(code)" }
            else { detail = "Process stopped; exit code unavailable" }
            if process["timed_out"] as? Bool == true { detail += "; timed out" }
            if process["cancelled"] as? Bool == true { detail += "; cancelled" }
            if process["session_retained"] as? Bool == true { detail += "; handle retained" }
            if process["session_retained"] as? Bool == false { detail += "; handle released" }
            detail += processMetrics(process, nowMilliseconds: nowMilliseconds)
            if name == "developer_task", r["developer_action"] as? String == "run_tests" {
                detail += "; test command started, test outcome not yet verified"
            }
            if name == "developer_task", r["workflow_terminal"] as? Bool == true {
                detail += "; command finished, acceptance still requires test/diff review"
            }
        } else if let file = r["file"] as? JSONObject, let count = file["byte_count"] as? Int {
            detail = "Read \(count) bytes"
            if file["eof"] as? Bool == false { detail += "; more file data remains" }
        } else if let count = r["returned_lines"] as? Int {
            detail = "Read \(count) lines"
            if count > 0, let start = r["start_line"] as? Int, start > 0, start <= Int.max - count {
                detail += " (\(start)–\(start + count - 1))"
            }
            if r["eof"] as? Bool == false { detail += "; more lines remain" }
        } else if name == "file_tail", let count = r["byte_count"] as? Int {
            detail = "Read \(count) tail bytes; not a full-file read"
        } else if r["mutation_performed"] as? Bool == true {
            detail = "Change applied; see receipt"
            if let count = r["edits_applied"] as? Int, count >= 0 { detail += "; \(count) edits applied" }
            else if let count = r["replacements"] as? Int, count >= 0 { detail += "; \(count) replacements applied" }
        } else if name == "workspace_inspect", let count = nonnegative(r["scanned_returned_entries"]) {
            detail = "Inspected \(count) directory entries"
            if let markers = r["project_markers"] as? [JSONObject] { detail += "; \(markers.count) project markers" }
        } else if let processes = r["processes"] as? [JSONObject] {
            detail = "\(processes.count) retained processes"
        } else if let entries = r["entries"] as? [JSONObject] {
            detail = "Returned \(entries.count) directory entries"
        } else if let matches = r["matches"] as? [JSONObject] {
            detail = "Returned \(matches.count) matches"
        } else if name == "bridge_activity" || name == "bridge_activity_view" {
            detail = "Activity snapshot returned; rendering is host-controlled"
            if r["snapshot_stale"] as? Bool == true { detail += "; stale snapshot" }
        }
        if partial { detail += "; partial result; inspect continuation and item results" }
        if r["truncated"] as? Bool == true || process["stdout_truncated"] as? Bool == true || process["stderr_truncated"] as? Bool == true {
            detail += "; truncated"
        }
        let requestedContext = ActivityDetail.context(ActivityDetail.metadata(name: name, arguments: arguments))
        // Put the target/command before counters and opaque IDs, so host label
        // truncation is less likely to hide what is actually being worked on.
        if let context = process["running"] is Bool ? (processContext ?? requestedContext) : requestedContext {
            detail = "\(context); \(detail)"
        }
        // IDs are useful for job handoff; only accept the server's UUID shape.
        if let id = r["task_id"] as? String, UUID(uuidString: id) != nil { detail += "; job \(id)" }
        return "\(label): \(detail)."
    }

    private static func nonnegative(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return n.int64Value
    }

    private static func processMetrics(_ p: JSONObject, nowMilliseconds: Int64) -> String {
        var parts: [String] = []
        if let start = nonnegative(p["started_milliseconds"]), start > 0 {
            let end = nonnegative(p["ended_milliseconds"])
                ?? (p["running"] as? Bool == true ? nowMilliseconds : nil)
            if let end, end >= start, end - start <= 31_536_000_000 {
                let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(end - start) / 1_000)
                parts.append("\(p["running"] as? Bool == true ? "elapsed" : "duration") \(duration)s")
            }
        }
        if let out = nonnegative(p["stdout_total_bytes"]), let err = nonnegative(p["stderr_total_bytes"]) {
            parts.append("produced \(out) B stdout / \(err) B stderr")
            if let outStart = nonnegative(p["stdout_cursor"]), let outEnd = nonnegative(p["stdout_next_cursor"]),
               let errStart = nonnegative(p["stderr_cursor"]), let errEnd = nonnegative(p["stderr_next_cursor"]),
               outStart <= outEnd, outEnd <= out, errStart <= errEnd, errEnd <= err {
                parts.append("this page \(outEnd - outStart) B stdout / \(errEnd - errStart) B stderr")
                if outEnd < out || errEnd < err { parts.append("more output remains; continue from returned cursors") }
            }
        }
        if p["output_consumed"] as? Bool == false { parts.append("non-consuming preview") }
        return parts.isEmpty ? "" : "; " + parts.joined(separator: "; ")
    }

    private static func workSummary(_ r: JSONObject) -> String {
        if let items = r["work_items"] as? [JSONObject] {
            return "\(items.count) retained tasks; \(items.filter { $0["phase"] as? String == "executing" }.count) executing; "
                + "\(items.filter { $0["phase"] as? String == "waiting_next_step" }.count) awaiting next step"
        }
        let phases = ["executing": "Task executing", "waiting_next_step": "Task retained; awaiting next step",
                      "waiting_user": "Task waiting for user", "completed": "Task marked completed by caller",
                      "failed": "Task marked failed by caller"]
        var text = phases[r["phase"] as? String ?? ""] ?? "Task state returned"
        if let calls = nonnegative(r["call_count"]), let errors = nonnegative(r["error_count"]) {
            text += "; \(calls) calls; \(errors) recorded errors"
        }
        if r["stale"] as? Bool == true { text += "; no recent update, not proof of completion" }
        return text
    }

    private static func inspectionSummary(_ r: JSONObject) -> String {
        var parts: [String] = []
        if let inspection = r["inspection"] as? JSONObject,
           let count = nonnegative(inspection["scanned_returned_entries"]) {
            parts.append("inspected \(count) directory entries")
        }
        for (key, title) in [("git_status", "Git status"), ("git_branches", "branches"),
                             ("git_log", "commit log"), ("git_diff", "diff")] {
            guard let receipt = r[key] as? JSONObject else { continue }
            if let code = receipt["exit_code"] as? Int { parts.append("\(title) exit \(code)") }
            else { parts.append("\(title) receipt, outcome unavailable") }
            if receipt["stdout_truncated"] as? Bool == true || receipt["stderr_truncated"] as? Bool == true {
                parts.append("\(title) output truncated")
            }
        }
        return parts.isEmpty ? "Inspection receipt returned; inspect nested results" : parts.joined(separator: "; ")
    }
}
