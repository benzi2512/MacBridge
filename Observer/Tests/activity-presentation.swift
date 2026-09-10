import Foundation

// Compile with ActivityPresentation.swift. Pure synthetic data; no MCP, GUI,
// filesystem mutation, network, credentials or external dependencies.
@main
enum ActivityPresentationTests {
    static func main() {
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name)
            checks += 1
        }
        func event(_ tool: String, _ state: String = "returned", _ result: [String: Any] = [:],
                   connected: Bool = true) -> ActivityPresentation {
            ActivityPresentation.event(["tool": tool, "state": state, "result": result,
                                        "started_ms": 1000, "finished_ms": 1250, "path": "sample.txt"], connected: connected)
        }
        check("Read title", event("file_read").title == "Read a file")
        check("Read-many title", event("file_read_many").title == "Read files")
        check("Stat-many title", event("file_stat_many").title == "Checked files")
        check("Append title", event("file_append").title == "Appended to a file")
        check("Create directory title", event("directory_create").title == "Created a folder")
        check("Move path title", event("path_move").title == "Moved a path")
        check("Copy path title", event("path_copy").title == "Copied a path")
        check("Remove path title", event("path_remove").title == "Removed a path")
        check("List alias title", event("workspace_list").title == "Listed workspaces")
        check("Running is live", event("command_run", "running").running)
        check("Running title", event("command_run", "running").title == "Running a command")
        check("Disconnected running is not live", !event("command_run", "running", connected: false).running)
        check("Disconnected label is unknown", event("command_run", "running", connected: false).subtitle.contains("Unknown"))
        check("Returned is not goal success", event("file_read").subtitle.hasPrefix("Tool returned"))
        check("Duration from receipts", event("file_read").subtitle.contains("250 ms"))
        check("Path from metadata", event("file_read").subtitle.hasSuffix("sample.txt"))
        check("Failed write not past tense", event("file_write", "failed").title != "Wrote a file")
        check("Error result fails", event("file_patch", "returned", ["error": "conflict"]).failed)
        check("Exit nonzero fails", event("command_run", "returned", ["exit_code": 2]).failed)
        check("Exit zero means process exit only", event("command_run", "returned", ["exit_code": 0]).subtitle.hasPrefix("Exited · 0"))
        check("Cancelled differs from failure", !event("process_cancel", "returned", ["cancelled": true, "exit_code": 15]).failed)
        check("Cancelled label", event("process_cancel", "returned", ["cancelled": true]).subtitle.hasPrefix("Cancelled"))
        check("Timeout label", event("command_run", "returned", ["timed_out": true]).subtitle.hasPrefix("Timed out"))
        check("Started is not completed", event("command_start", "returned", ["running": true]).subtitle.contains("check current job state"))
        check("Input receipt does not claim new process", !event("process_input", "returned", ["running": true]).subtitle.contains("Process started"))
        check("Unknown tool preserved", event("future_tool").title == "future_tool returned")
        check("Unknown state not past tense", event("file_write", "unknown").subtitle.hasPrefix("Unknown"))
        check("Undo accept not file mutation", event("transaction_accept").title == "Released selected undo")
        let waiting = ActivityPresentation.summary(history: [], jobs: [], connected: true, stale: false)
        check("Empty waiting", waiting == "Waiting for MacBridge activity")
        check("Offline summary", ActivityPresentation.summary(history: [], jobs: [["running": true]], connected: false, stale: false).contains("unavailable"))
        check("Stale jobs not live", ActivityPresentation.summary(history: [], jobs: [["running": true]], connected: true, stale: true).contains("not current"))
        check("Live process count", ActivityPresentation.summary(history: [], jobs: [["running": true], ["running": false]], connected: true, stale: false) == "1 process running")
        check("Busy invocation from fresh history", ActivityPresentation.summary(history: [["tool": "file_read", "state": "running"]], jobs: [], connected: true, stale: true) == "Reading a file · owner busy")
        let large = ActivityPresentation.event(["tool": "file_read", "state": "returned", "path": String(repeating: "x", count: 5000)], connected: true)
        check("Subject display bounded", large.subtitle.count < 200)
        check("Raw content never rendered", !ActivityPresentation.event(["tool": "file_write", "state": "returned", "content": "PRIVATE_CONTENT"], connected: true).subtitle.contains("PRIVATE_CONTENT"))
        let expanded = "tool_catalog workspace_inspect file_read_lines file_tail file_compare file_search_many directory_summary directory_find file_apply_edits file_write_many command_list process_wait process_status_many process_output_tail process_output_many git_status git_diff git_log git_show git_branches git_worktrees git_blame git_file_list".split(separator: " ").map(String.init)
        check("Exactly 52 tool labels", ActivityPresentation.knownTools.count == 52)
        for tool in ["developer_inspect", "developer_task"] + expanded {
            check("Human label " + tool, !event(tool).title.contains(tool))
            check("Known action " + tool, ActivityPresentation.knownTools.contains(tool))
        }
        check("Batch does not claim all writes", event("file_write_many").title == "File batch returned")
        let failed: [String: Any] = ["tool": "file_patch", "path": "Dữ liệu/sample.txt", "state": "failed", "result": ["error": "Hash conflict", "stdout": "SECRET_OUTPUT"]]
        check("Case-insensitive metadata search", ActivityPresentation.matches(failed, query: "PATCH sample", filter: .issues, connected: true))
        check("Unicode search", ActivityPresentation.matches(failed, query: "dữ liệu", filter: .all, connected: true))
        check("Error search", ActivityPresentation.matches(failed, query: "conflict", filter: .all, connected: true))
        check("Do not search output", !ActivityPresentation.matches(failed, query: "SECRET_OUTPUT", filter: .all, connected: true))
        check("No false running", !ActivityPresentation.matches(failed, query: "", filter: .running, connected: true))
        let active: [String: Any] = ["tool": "command_start", "state": "running"]
        check("Live running filter", ActivityPresentation.matches(active, query: "", filter: .running, connected: true))
        check("Offline running excluded", !ActivityPresentation.matches(active, query: "", filter: .running, connected: false))
        check("Offline unknown is issue", ActivityPresentation.matches(active, query: "", filter: .issues, connected: false))
        check("Timeout is issue", ActivityPresentation.matches(["result": ["timed_out": true]], query: "", filter: .issues, connected: true))
        check("Cancel is issue, not failure", ActivityPresentation.matches(["result": ["cancelled": true]], query: "", filter: .issues, connected: true))
        check("Normal returned excluded from issues", !ActivityPresentation.matches(["state": "returned"], query: "", filter: .issues, connected: true))
        check("Timeout emphasized", event("command_run", "returned", ["timed_out": true]).failed)
        print("PASS: \(checks) activity presentation checks")
    }
}
