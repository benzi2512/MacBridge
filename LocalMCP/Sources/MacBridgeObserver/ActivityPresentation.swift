import Foundation

/// A bounded presentation of owner receipts, never an inferred ChatGPT transcript.
struct ActivityPresentation {
    let title: String
    let subtitle: String
    let icon: String
    let running: Bool
    let failed: Bool
    let partial: Bool

    private static let actions: [String: (String, String, String)] = [
        "developer_inspect": ("Inspecting developer context", "Developer context returned", "doc.text.magnifyingglass"),
        "developer_task": ("Running a developer task", "Developer task returned", "hammer"),
        "bridge_capabilities": ("Checking MacBridge", "Checked MacBridge", "info.circle"),
        "media_inspect": ("Checking creative transfer", "Creative transfer checked", "photo"),
        "media_share": ("Transferring approved creative", "Creative transfer receipt", "arrow.up.doc"),
        "workspace_overview": ("Listing workspaces", "Listed workspaces", "folder"),
        "workspace_list": ("Listing workspaces", "Listed workspaces", "folder"),
            "workspace_reload": ("Reloading workspaces", "Reloaded workspaces", "arrow.clockwise"),
            "directory_list": ("Listing files", "Listed files", "folder"),
            "file_search": ("Searching files", "Searched files", "magnifyingglass"),
            "file_read": ("Reading a file", "Read a file", "doc.text"),
            "desktop_open": ("Opening a local item", "Requested desktop opening", "folder"),
            "network_command": ("Running an approved network command", "Ran an approved network command", "network"),
            "file_read_many": ("Reading files", "Read files", "doc.on.doc"),
            "file_stat": ("Checking a file", "Checked a file", "doc"),
            "file_stat_many": ("Checking files", "Checked files", "doc.on.doc"),
            "file_write": ("Writing a file", "Wrote a file", "square.and.pencil"),
            "file_patch": ("Editing a file", "Edited a file", "square.and.pencil"),
            "file_append": ("Appending to a file", "Appended to a file", "square.and.pencil"),
            "directory_create": ("Creating a folder", "Created a folder", "folder.badge.plus"),
            "path_move": ("Moving a path", "Moved a path", "arrow.right.doc.on.clipboard"),
            "path_copy": ("Copying a path", "Copied a path", "doc.on.doc"),
            "path_remove": ("Removing a path", "Removed a path", "trash"),
            "command_run": ("Running a command", "Ran a command", "terminal"),
            "command_start": ("Starting a process", "Started a process", "terminal"),
            "process_list": ("Checking processes", "Checked processes", "list.bullet"),
            "process_status": ("Checking a process", "Checked a process", "terminal"),
            "process_output": ("Reading process output", "Read process output", "text.alignleft"),
            "process_input": ("Sending process input", "Sent process input", "keyboard"),
            "process_cancel": ("Cancelling a process", "Requested process cancellation", "stop.circle"),
            "transaction_restore": ("Restoring a file change", "Restored a file change", "arrow.uturn.backward"),
            "transaction_list": ("Listing undo records", "Listed undo records", "list.bullet"),
            "transaction_accept": ("Releasing selected undo", "Released selected undo", "checkmark.circle"),
            "tool_catalog": ("Finding tools", "Found tool information", "square.grid.2x2"),
            "workspace_inspect": ("Inspecting a workspace", "Inspected a workspace", "folder"),
            "file_read_lines": ("Reading file lines", "Read file lines", "doc.text"),
            "file_tail": ("Reading the end of a file", "Read the end of a file", "text.alignleft"),
            "file_compare": ("Comparing files", "Compared files", "doc.on.doc"),
            "file_search_many": ("Searching selected files", "Searched selected files", "magnifyingglass"),
            "directory_summary": ("Summarizing a folder", "Summarized a folder", "folder"),
            "directory_find": ("Finding paths", "Found path matches", "magnifyingglass"),
            "file_apply_edits": ("Applying file edits", "Applied file edits", "square.and.pencil"),
            "file_write_many": ("Writing selected files", "File batch returned", "doc.on.doc"),
            "command_list": ("Checking available commands", "Checked available commands", "terminal"),
            "process_wait": ("Waiting for a process", "Process wait returned", "clock"),
            "process_status_many": ("Checking selected processes", "Checked selected processes", "list.bullet"),
            "process_output_tail": ("Peeking at recent output", "Read recent output", "text.alignleft"),
            "process_output_many": ("Reading selected process outputs", "Process output batch returned", "text.alignleft"),
            "git_status": ("Checking Git changes", "Checked Git changes", "arrow.triangle.branch"),
            "git_diff": ("Reading a Git diff", "Read a Git diff", "doc.text"),
            "git_log": ("Reading commit history", "Read commit history", "clock"),
            "git_show": ("Inspecting a commit", "Inspected a commit", "arrow.triangle.branch"),
            "git_branches": ("Listing branches", "Listed branches", "arrow.triangle.branch"),
            "git_worktrees": ("Listing worktrees", "Listed worktrees", "folder"),
            "git_blame": ("Reading line attribution", "Read line attribution", "text.alignleft"),
            "git_file_list": ("Listing Git files", "Listed Git files", "doc.on.doc"),
            "work_task": ("Updating a work task", "Updated a work task", "checklist"),
            "bridge_diagnostic": ("Checking bridge diagnostics", "Checked bridge diagnostics", "stethoscope"),
            "workspace_resolve": ("Resolving a workspace", "Resolved a workspace", "folder.badge.questionmark"),
            "project_read_bundle": ("Reading project context", "Read project context", "doc.on.doc"),
            "file_json_patch": ("Editing structured data", "Edited structured data", "curlybraces"),
            "artifact_snapshot": ("Capturing an artifact snapshot", "Captured an artifact snapshot", "camera.on.rectangle"),
            "brevo_read": ("Reading Brevo data", "Read Brevo data", "envelope"),
            "brevo_campaign": ("Managing a Brevo campaign", "Brevo campaign returned", "megaphone"),
            "brevo_automations": ("Checking Brevo automations", "Checked Brevo automations", "gearshape.2"),
            "brevo_contacts": ("Managing Brevo contacts", "Brevo contacts returned", "person.2"),
            "brevo_deliverability": ("Checking Brevo deliverability", "Checked Brevo deliverability", "checkmark.seal"),
            "brevo_events": ("Checking Brevo events", "Checked Brevo events", "calendar"),
            "brevo_lists": ("Managing Brevo lists", "Brevo lists returned", "list.bullet"),
            "brevo_reports": ("Reading Brevo reports", "Read Brevo reports", "chart.bar"),
            "brevo_segments": ("Managing Brevo segments", "Brevo segments returned", "person.3"),
            "brevo_templates": ("Managing Brevo templates", "Brevo templates returned", "doc.richtext"),
            "brevo_transactional": ("Managing Brevo messages", "Brevo message operation returned", "paperplane"),
            "brevo_webhooks": ("Managing Brevo webhooks", "Brevo webhooks returned", "link"),
        ]
    static var knownTools: Set<String> { Set(actions.keys) }

    enum Filter: String, CaseIterable {
        case all = "All", running = "Active", issues = "Issues", ungrouped = "Ungrouped"
    }

    /// Only retained, already-observed metadata is searched. No extra MCP calls,
    /// file content, output collection or persistent index is introduced.
    static func matches(_ event: [String: Any], query: String, filter: Filter, connected: Bool) -> Bool {
        let shown = Self.event(event, connected: connected)
        let result = event["result"] as? [String: Any] ?? [:]
        if filter == .running && !shown.running { return false }
        if filter == .issues && !(shown.failed || shown.partial || result["timed_out"] as? Bool == true
            || result["cancelled"] as? Bool == true || event["state"] as? String == "unknown"
            || (!connected && event["state"] as? String == "running")) { return false }
        let fields = [shown.title, shown.subtitle] + ["tool", "path", "cwd", "task_id", "transaction_id"]
            .compactMap { event[$0] as? String }
            + ["error", "task_id", "transaction_id"].compactMap { result[$0] as? String }
        let haystack = fields.joined(separator: " ")
        return query.prefix(256).split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            haystack.localizedStandardContains(String($0))
        }
    }
    static func event(_ event: [String: Any], connected: Bool) -> Self {
        let tool = event["tool"] as? String ?? "Unknown tool"
        let state = event["state"] as? String ?? "unknown"
        let result = event["result"] as? [String: Any] ?? [:]
        var action = actions[tool] ?? ("Calling \(tool)", "\(tool) returned", "wrench.and.screwdriver")
        if (tool == "developer_task" || tool == "developer_inspect"),
           let detail = event["detail"] as? [String: Any],
           let developerAction = detail["developer_action"] as? String {
            action = switch developerAction {
            case "inspect_repo": ("Inspecting a repository", "Inspected repository", "folder.badge.gearshape")
            case "execute_task": ("Starting a developer task", "Developer task started", "hammer")
            case "run_tests": ("Starting project tests", "Project tests started", "checkmark.circle")
            case "review_diff": ("Reviewing changes", "Reviewed changes", "doc.text.magnifyingglass")
            case "continue_task": ("Checking developer task", "Developer task updated", "clock")
            default: action
            }
        }
        let running = connected && state == "running"
        let failed = state == "failed" || result["error"] != nil
            || (result["exit_code"] as? Int).map { $0 != 0 } == true
        let cancelled = result["cancelled"] as? Bool == true
        let timedOut = result["timed_out"] as? Bool == true
        let partial = state == "returned" && (result["complete"] as? Bool == false
            || result["partial"] as? Bool == true || (result["error_count"] as? Int ?? 0) > 0
            || (result["skipped_count"] as? Int ?? 0) > 0)
        var status: String
        if state == "running" { status = connected ? "Running" : "Unknown · disconnected while running" }
        else if timedOut { status = "Timed out" }
        else if cancelled { status = "Cancelled" }
        else if failed { status = "Failed" }
        else if partial { status = "Partial result" }
        else if state == "returned" {
            if result["running"] as? Bool == true { status = "Running when tool returned · check current job state" }
            else if let exit = result["exit_code"] as? Int { status = "Exited · \(exit)" }
            else { status = "Tool returned" }
        } else { status = "Unknown" }
        if state == "returned" {
            if let count = result["success_count"] as? Int { status += " · \(count) applied" }
            if let count = result["read_count"] as? Int { status += " · \(count) read" }
            if let count = result["error_count"] as? Int, count > 0 { status += " · errors: \(count)" }
            if let count = result["skipped_count"] as? Int, count > 0 { status += " · skipped: \(count)" }
        }
        if state != "running", let start = event["started_ms"] as? NSNumber,
           let finish = event["finished_ms"] as? NSNumber, finish.doubleValue >= start.doubleValue {
            let ms = finish.doubleValue - start.doubleValue
            status += ms < 1000 ? " · \(Int(ms)) ms" : String(format: " · %.1f s", ms / 1000)
        }
        let subject = (event["path"] as? String) ?? (event["cwd"] as? String)
        if let subject, !subject.isEmpty { status += " · " + String(subject.prefix(160)) }
        // A failed/unknown invocation must not claim its requested mutation happened.
        let title = state == "returned" && !failed && !cancelled && !timedOut ? action.1 : action.0
        return Self(title: title, subtitle: status, icon: (failed && !cancelled) || partial ? "exclamationmark.circle" : action.2,
                    running: running, failed: (failed || timedOut) && !cancelled, partial: partial)
    }

    static func summary(history: [[String: Any]], jobs: [[String: Any]], connected: Bool, stale: Bool) -> String {
        guard connected else { return "Activity unavailable · MacBridge is not connected" }
        if let current = history.first(where: { $0["state"] as? String == "running" }) {
            return event(current, connected: true).title + (stale ? " · owner busy" : "")
        }
        guard !stale else { return "Owner busy · job state is not current" }
        let running = jobs.filter { $0["running"] as? Bool == true }.count
        if running > 0 { return "\(running) \(running == 1 ? "process running" : "processes running")" }
        return history.isEmpty ? "Waiting for MacBridge activity" : "No process running · recent tool activity below"
    }
}
