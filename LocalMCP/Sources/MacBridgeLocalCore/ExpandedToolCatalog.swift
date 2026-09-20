import Foundation

/// Typed, bounded additions. No aliases, remote access, scheduler or UI control.
enum ExpandedToolCatalog {
    static func specs() -> [JSONObject] {
        func text(_ max: Int = 4096) -> JSONObject { ["type": "string", "maxLength": max] }
        func integer(_ min: Int, _ max: Int) -> JSONObject { ["type": "integer", "minimum": min, "maximum": max] }
        func choice(_ values: [String]) -> JSONObject { ["type": "string", "enum": values] }
        func array(_ item: JSONObject, _ max: Int) -> JSONObject {
            ["type": "array", "minItems": 1, "maxItems": max, "items": item]
        }
        func object(_ properties: JSONObject, _ required: [String]) -> JSONObject {
            ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
        }
        func spec(_ name: String, _ description: String, _ properties: JSONObject,
                  _ required: [String], write: Bool = false, openWorld: Bool = false) -> JSONObject {
            ["name": name, "title": name.replacingOccurrences(of: "_", with: " "),
             "description": description, "inputSchema": object(properties, required),
             "annotations": ["readOnlyHint": !write, "destructiveHint": write,
                             "idempotentHint": !write && name != "process_output_many", "openWorldHint": openWorld]]
        }
        let ws = text(36), path = text(), task = text(36), control = text(96)
        let flag: JSONObject = ["type": "boolean"]
        let file: JSONObject = ["workspace_id": ws, "path": path]
        func extend(_ base: JSONObject, _ more: JSONObject) -> JSONObject {
            base.merging(more) { _, rhs in rhs }
        }
        let edit = object(["old_text": text(262144), "new_text": text(262144)], ["old_text", "new_text"])
        let write = object(["path": path, "content": text(262144), "expected_sha256": text(64),
                            "create_only": flag], ["path", "content"])
        let output = object(["task_id": task, "process_control_token": control,
                             "stdout_cursor": integer(0, Int.max),
                             "stderr_cursor": integer(0, Int.max)], ["task_id"])
        let jsonPatch = object([
            "op": choice(["add", "replace", "remove", "test"]),
            "path": text(4096),
            "value": [:],
        ], ["op", "path"])
        let git: JSONObject = ["workspace_id": ws, "cwd": path,
                               "maximum_output_bytes": integer(1024, 262144)]
        return [
            spec("tool_catalog", "Optional tool lookup: defaults to 13 starter tools; query/category finds up to 5 matches across all tools. names returns exact schemas; set limit to the current catalog count for the full index; detail=schemas requests full schemas. Filters intersect. Does not execute, load host functions or grant permission.",
                 ["detail": choice(["schemas", "index"]), "names": array(text(128), 128),
                  "query": text(512), "category": choice(ToolDiscovery.categories), "limit": integer(1, 128)], []),
            spec("developer_inspect", "Codex Developer read-only gateway. inspect_repo returns bounded project markers and Git context; review_diff returns status and diff. Kept separate from command actions so a normal Chat can inspect without a write-capable schema. No added permission, network access or embedded model.",
                 ["action": choice(DeveloperTask.inspectActions), "workspace_id": ws, "cwd": path,
                  "maximum_commits": integer(1, 50), "staged": flag, "path": path],
                 ["action", "workspace_id"]),
            spec("developer_task", "Codex Developer command gateway. execute_task requires workspace_id, executable and arguments; run_tests requires workspace_id; continue_task requires workflow_id. Starts one bounded background command under one retained parent. No added permission, network access or embedded model.",
                 ["action": choice(DeveloperTask.taskActions), "workspace_id": ws, "cwd": path,
                  "title": text(640), "chat_label": text(640), "workflow_id": task,
                  "process_control_token": control,
                  "executable": text(64),
                  "arguments": ["type": "array", "maxItems": 128, "items": text(16384)],
                  "test_kind": choice(["auto", "swift", "make", "custom"]),
                  "maximum_output_bytes": integer(1024, 262144)],
                 ["action"], write: true),
            spec("workspace_inspect", "Inspect a registered workspace directory and bounded top-level project markers without reading their contents. Reports configured scope; does not register or widen access.", file, ["workspace_id"]),
            spec("file_read_lines", "Read a 1-based LF-delimited text line range from a file up to 1 MiB. Reports EOF, total lines, hash and continuation. CRLF bytes are preserved; larger files use byte-oriented file_read.",
                 extend(file, ["start_line": integer(1, 1000000), "maximum_lines": integer(1, 2000)]), ["workspace_id", "path"]),
            spec("file_tail", "Read the last bounded bytes of a file as UTF-8, advancing a split initial scalar. Reports actual byte offset and skipped prefix; never claims that a tail is the whole file.",
                 extend(file, ["maximum_bytes": integer(4, 262144)]), ["workspace_id", "path"]),
            spec("file_compare", "Compare two files up to 1 MiB each, returning hashes, byte lengths and first differing byte without returning contents. No diff subprocess.",
                 ["workspace_id": ws, "left_path": path, "right_path": path], ["workspace_id", "left_path", "right_path"]),
            spec("file_search_many", "Search up to 16 explicit UTF-8 files for a literal string with line numbers in one request. Aggregate read budget 4 MiB; each file at most 1 MiB. Reports per-item errors and bounded matches, not a whole-tree search.",
                 ["workspace_id": ws, "paths": array(path, 16), "query": text(), "case_sensitive": flag,
                  "maximum_results_per_file": integer(1, 200)], ["workspace_id", "paths", "query"]),
            spec("directory_summary", "Count file types and logical file bytes in one bounded directory traversal. Reports inaccessible/limit status; logical bytes are not allocated disk usage and symlinks are not followed.",
                 extend(file, ["recursive": flag, "maximum_entries": integer(1, 10000)]), ["workspace_id"]),
            spec("directory_find", "Match a basename glob (* and ?, no regex) in one bounded directory listing. Case sensitive. Returns scan completeness and matched paths; never follows symlinks.",
                 extend(file, ["pattern": text(256), "recursive": flag, "maximum_entries": integer(1, 10000)]), ["workspace_id", "pattern"]),
            spec("file_apply_edits", "Apply 1-32 unique, non-overlapping literal replacements against one original UTF-8 file (up to 1 MiB). Requires the original SHA-256; all matches validate before one write and one undo transaction. Empty, ambiguous and overlapping matches are refused.",
                 extend(file, ["expected_sha256": text(64), "edits": array(edit, 32)]), ["workspace_id", "path", "expected_sha256", "edits"], write: true),
            spec("file_write_many", "Write 1-16 explicit UTF-8 files under one mutation lock and one composite undo transaction, at most 1 MiB total content. This is a coordinated sequence, not a crash-atomic filesystem transaction: every destination is revalidated immediately before publication and a detected failure triggers verified content/POSIX-mode compensation. Inode identity, extended attributes, ACLs and other metadata are not preserved by compensation. Aliased destinations are refused. Existing files require expected_sha256; create_only refuses an existing target and returns its current revision.",
                 ["workspace_id": ws, "files": array(write, 16)], ["workspace_id", "files"], write: true),
            spec("project_read_bundle", "Read bounded initial bodies for 1-16 explicit project files in one mutation-consistent snapshot, at most 256 KiB per file and 1 MiB total. Per-file eof plus top-level complete/truncated report whether every body is complete. Returns hashes, project-marker matches and one snapshot token; it never performs a recursive or inferred read.",
                 ["workspace_id": ws, "paths": array(path, 16)], ["workspace_id", "paths"]),
            spec("file_json_patch", "Apply 1-32 bounded JSON Pointer operations (add, replace, remove or test) to one JSON file. Requires the exact current SHA-256 and publishes one canonical JSON write with one undo transaction. Test failure or stale content performs no write.",
                 ["workspace_id": ws, "path": path, "expected_sha256": text(64),
                  "operations": array(jsonPatch, 32)],
                 ["workspace_id", "path", "expected_sha256", "operations"], write: true),
            spec("artifact_snapshot", "Create one immutable-by-convention, content-addressed copy of an explicit file. Requires its exact SHA-256; the destination filename must contain that full hash and must not already exist. Returns one normal undo transaction and never overwrites an artifact.",
                 ["workspace_id": ws, "source_path": path, "destination_path": path,
                  "expected_source_sha256": text(64)],
                 ["workspace_id", "source_path", "destination_path", "expected_source_sha256"], write: true),
            spec("command_list", "List executable IDs actually supported and currently resolvable by this runtime without launching them. Use these IDs, not arbitrary absolute executable paths. No version probes or environment-variable values.", [:], []),
            spec("process_wait", "Optional wait up to 1000 ms for one existing job; no kill or output consumption. Not a required step before output. Observation timeout is not job failure. Its bounded wait is dispatched off the MCP request loop so other chats remain responsive; do other work between checks instead of frequent polling.",
                 ["task_id": task, "process_control_token": control,
                  "maximum_wait_milliseconds": integer(0, 1000)], ["task_id"]),
            spec("process_status_many", "Read status for 1-32 existing task IDs with per-item errors. Does not consume output, cancel, or start work.", ["task_ids": array(task, 32)], ["task_ids"]),
            spec("process_output_tail", "Peek at the newest bounded stdout/stderr from one retained job without releasing its handle. Reports skipped-prefix bytes and actual UTF-8-aligned cursors; use process_output for a full drain.",
                 ["task_id": task, "process_control_token": control,
                  "maximum_bytes_per_stream": integer(4, 65536)], ["task_id"]),
            spec("process_output_many", "Read status plus incremental output for 1-8 jobs with per-job cursors, up to 32 KiB per stream. No separate status call needed when these results suffice. Fully draining a completed job releases its handle unless its original command_run response is pending; check session_retained. Per-item errors do not erase other results. Never replay a consumed batch blindly.",
                 ["jobs": array(output, 8), "maximum_bytes_per_stream": integer(4, 32768)], ["jobs"]),
            spec("brevo_read", "Read the owner's locally configured Brevo account, verified against its explicit account binding. Actions: account, campaigns, campaign, senders, lists. Campaign HTML is excluded unless explicitly requested. The Brevo API key is never returned.",
                 ["action": choice(["account", "campaigns", "campaign", "senders", "lists"]),
                  "campaign_id": integer(1, Int.max),
                  "type": choice(["classic", "trigger"]),
                  "status": choice(["suspended", "archive", "sent", "queued", "draft", "inProcess", "inReview"]),
                  "statistics": choice(["globalStats", "linksStats", "statsByDomain", "statsByDevice", "statsByBrowser"]),
                  "start_date": text(64), "end_date": text(64),
                  "limit": integer(1, 100), "offset": integer(0, Int.max),
                  "sort": choice(["asc", "desc"]), "include_html_content": flag,
                  "ip": text(128), "domain": text(255)], ["action"], openWorld: true),
            BrevoCampaignActions.spec(),
            spec("git_status", "Read Git porcelain-v1 status of a workspace repository, including untracked files. Fixed argv, no pager/hooks/fsmonitor or network; bounded output reports truncation.", git, ["workspace_id"]),
            spec("git_diff", "Read Git working-tree or staged diff, optionally for one literal repository-relative path. External diff and textconv are disabled. Does not change index or files.",
                 extend(git, ["staged": flag, "path": path]), ["workspace_id"]),
            spec("git_log", "Read a bounded recent commit log with full hashes, ISO dates and subjects. Optional revision is HEAD or a 7-40-character hexadecimal commit ID. Does not execute repository aliases.",
                 extend(git, ["maximum_commits": integer(1, 100), "revision": text(40)]), ["workspace_id"]),
            spec("git_show", "Read commit metadata and diffstat for HEAD or a hexadecimal commit ID; no file-body dump, external diff or textconv. Does not mutate repository state.",
                 extend(git, ["revision": text(40)]), ["workspace_id"]),
            spec("git_branches", "Read local Git branch names, full object IDs and current-branch marker. No fetch or remote credential access.", git, ["workspace_id"]),
            spec("git_worktrees", "Read Git's registered worktree inventory in porcelain form. Does not create, switch, prune or delete a worktree.", git, ["workspace_id"]),
            spec("git_blame", "Read line-porcelain Git blame for a bounded line range of one literal repository-relative file. Does not run textconv. Output may be truncated; do not infer complete attribution from partial output.",
                 extend(git, ["path": path, "start_line": integer(1, 1000000), "maximum_lines": integer(1, 200)]), ["workspace_id", "path"]),
            spec("git_file_list", "Read NUL-delimited Git index paths and optional untracked paths. Literal pathspecs; not a recursive filesystem read or a content snapshot.",
                 extend(git, ["include_untracked": flag]), ["workspace_id"]),
        ] + BrevoToolCatalog.specs()
    }
}
