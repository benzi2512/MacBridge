import Foundation

/// Small text companion to the unchanged structured result. No I/O, timers,
/// raw request arguments, file contents or stdout/stderr are copied into this label.
/// ActivityDetail supplies a separate allowlisted command/path preview when available.
/// The host still decides how (or whether) to display it in its activity UI.
enum ToolResultSummary {
    static func text(name: String, result r: JSONObject, arguments: JSONObject = [:]) -> String {
        let label = name.replacingOccurrences(of: "_", with: " ")
        var detail = "Result returned"
        var partial = r["partial"] as? Bool == true || r["complete"] as? Bool == false
        if r["isError"] as? Bool == true || r["error"] != nil || r["status"] as? String == "error" {
            // A failed or ambiguous call is not evidence that the requested edit happened.
            detail = "Call failed; inspect error and any available receipt"
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
        } else if let running = r["running"] as? Bool {
            if running { detail = "Process running" }
            else if let code = r["exit_code"] as? Int { detail = "Process exited with code \(code)" }
            else { detail = "Process stopped; exit code unavailable" }
            if r["timed_out"] as? Bool == true { detail += "; timed out" }
            if r["cancelled"] as? Bool == true { detail += "; cancelled" }
            if r["session_retained"] as? Bool == true { detail += "; handle retained" }
            if r["session_retained"] as? Bool == false { detail += "; handle released" }
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
        if r["truncated"] as? Bool == true || r["stdout_truncated"] as? Bool == true || r["stderr_truncated"] as? Bool == true {
            detail += "; truncated"
        }
        // IDs are useful for job handoff; only accept the server's UUID shape.
        if let id = r["task_id"] as? String, UUID(uuidString: id) != nil { detail += "; job \(id)" }
        if let context = ActivityDetail.context(ActivityDetail.metadata(name: name, arguments: arguments)) {
            detail += "; \(context)"
        }
        return "\(label): \(detail)."
    }
}
