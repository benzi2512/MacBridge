# Working with MacBridge's 67-tool source catalog

The twelve Brevo tools, typed actions, safety gates and reviewed public API
limitations are documented in [Brevo capabilities](BREVO-CAPABILITIES.md).
Source catalog presence is not proof of deployment or normal-Chat callability.

Start with the user's actual task. Allow host tool discovery, schema loading,
workspace selection and read-only preparation before execution. A function not
already in context is not evidence that it is absent from the connector.

Reviewing a tool is not permission to execute it. For a read-only audit, inspect
schemas and documents without invoking the operation being reviewed. Earlier
commands, examples and completed tasks are context, not permission to replay
them in the current task. This guidance is not a server-enforced per-chat policy;
verify actual calls and results before declaring that an audit stayed read-only.

Use already-loaded callable tools directly. Do not call health, workspace
overview or the full catalog before every task when the relevant context is
already known. If a callable schema is missing, first use host discovery for the
actual task; `tool_catalog` is an optional metadata lookup, not a mandatory
extra step or a host loader. Reuse schemas within the chat unless the host
reports staleness or the observed catalog identity changes.

For an unfamiliar choice, `tool_catalog` supports:

- `query`: bounded deterministic English/Vietnamese keyword matching, at most
  5 suggestions by default. Suggestions are not proof that a tool fits every
  constraint; verify its exact schema before use.
- `category`: `workspace`, `files`, `search`, `edit`, `process`, `git`, or `undo`.
- `limit`: 1–55; filters intersect, and `matched_count`/`truncated` expose omissions.
- `names`: exact schemas for selected names, preserving the previous shortcut.
- `detail: "schemas"`: explicitly requests full schemas; without filters this
  still returns all 55, including the compatibility alias.

An empty call returns a **13-tool starter index**, not all schemas or all tools.
Its `truncated: true` and category counts explicitly show there is more.
Use `limit: 55` for the 54-entry canonical index, or search the whole catalog
with query/category. Specialist tools are not removed or hidden from `tools/list`.
Index descriptions can be truncated and are labelled accordingly.
`workspace_list` stays callable for existing clients but is deprecated; prefer
`workspace_overview`. Only an explicitly named lookup includes that alias in
the index. No callable tool is removed in this compatibility stage.

The catalog comes from `tools/list`; this document is not a frozen argument
schema. `bridge_capabilities` reports live names, catalog digest, executable
hash and owner when identity verification is needed. A stale host may need its
supported connector refresh or a fresh chat; changing a binary cannot force
host schema loading or remove an approval requirement.

### When a conversation loses the connector

Distinguish a missing callable schema from an actual failed call. If the schema
is missing, use the host's supported discovery first. When reattachment is needed,
select the real plugin from the @ picker; typing its display name alone is not
proof of attachment. Reattachment can restore schemas without restoring execution.

If a call explicitly reports that the tool is disabled, preserve that exact error
and stop calls to the disabled connector. Do not retry under a different tool name,
mode or misleading read-only label. Compare with an already-authorized read-only
check in an independent conversation to distinguish an account-wide outage from
a conversation-specific failure. A branch is not a clean-new conversation test;
record that condition without assuming it caused the failure.

Check the actual plugin settings and runtime identity before proposing a reset.
Do not restart a healthy shared runtime, discard another chat's handles/undo, or
promise that connector refresh or restarting ChatGPT will repair host state.
Shared runtime logs are not per-chat evidence unless requests are correlated.

## Activity labels and results

Successful RPC replies include a short operation/status text alongside the
unchanged `structuredContent`. Process labels distinguish running, exit code,
timeout, truncation and retained handles; batch labels flag partial results.
They include bounded file/line targets and previews of supported ordinary command
arguments. Script bodies, stdin, environment values, credentials and opaque
arguments are omitted; a preview is not a shell command to replay. Exit code zero is
not a claim that a project's tests passed. Inspect the structured result for
continuation, per-item errors and the actual evidence required by the task.

The host controls its Thinking/Worked activity list and may ignore or shorten
this text. These labels do not stream internal build steps, add polling, reveal
model reasoning or prove that the separate inline activity card rendered.

## Keep a multi-step task visible

For a multi-step job, discover `work_task` once and call `action: "begin"` with a
short factual `title`, the relevant `workspace_id` when known, and optionally a
`chat_label` supplied by the user or this chat. Keep the returned `work_id` and
pass it to related file/command/process tools. This is separate from a process
`task_id` or a transaction ID. Never infer another chat's identity from its folder
or take over a work ID merely because it appears in shared activity.

One-off calls can stay ungrouped. Do not add begin/list/update calls before every
file read. Related tool calls update progress themselves. When waiting for the
user, use `action: "update", status: "waiting_user"`; resume with `status: "active"`.
Finish with `action: "finish", status: "completed"` or `"failed"`
only after checking the actual result and outstanding processes. A tool return
does not finish the parent task. Use `action: "list"` to reconcile an uncertain
begin/update before retrying; do not create duplicate parent tasks blindly.

The observer retains the parent while no child tool is executing and labels it
as waiting for the next step. No recent update means stale/unknown, not automatic
completion. Names are display labels, not proof of host conversation ownership.
Parent tasks are bounded, owner-local metadata; restart loses their handles.
They do not authorize file writes, process cancellation or access outside the
configured workspace. This mechanism does not collect model reasoning.

## Choose the right workflow

| Task | Tools |
|---|---|
| Common repo inspection | `developer_inspect` (`inspect_repo`, `review_diff`) |
| Common command workflow | `developer_task` (`execute_task`, `run_tests`, `continue_task`) |
| Workspace and project markers | `workspace_overview`, `workspace_inspect` |
| Files and directories | `directory_list`, `directory_find`, `directory_summary`, `file_stat`, `file_stat_many` |
| Read/search/compare | `file_read`, `file_read_many`, `file_read_lines`, `file_tail`, `file_compare`, `file_search`, `file_search_many` |
| Edit and recovery | `file_write`, `file_write_many`, `file_patch`, `file_apply_edits`, `file_append`, `transaction_list`, `transaction_restore`, `transaction_accept` |
| Path operations | `directory_create`, `path_copy`, `path_move`, `path_remove` |
| Short commands | `command_list`, `command_run` |
| Long/interacting jobs | `command_start`, `process_status`, `process_wait`, `process_status_many`, `process_input`, `process_output`, `process_output_tail`, `process_output_many`, `process_list`, `process_cancel` |
| Typed read-only Git | `git_status`, `git_diff`, `git_log`, `git_show`, `git_branches`, `git_worktrees`, `git_blame`, `git_file_list` |

The two developer surfaces are the short path when a normal Chat needs a familiar
repo workflow without loading many specialist schemas. Both are deterministic:
they do not contain another model or decide whether a task is authorized.
`developer_inspect` is read-only: `inspect_repo` combines bounded project markers
and Git context, while `review_diff` combines status and diff. `developer_task`
is write-capable: `execute_task` starts one explicit supported command under one
retained parent, while `run_tests` can select SwiftPM or Make from local markers.
`continue_task` returns a bounded tail while running and drains/finalizes the
parent at terminal state. Use the specialist tools when a task needs fine-grained
file edits, several jobs or a workflow outside these five actions.

For both command tools, `executable` is a supported **name**, not a filesystem
path: use `"sh"`, not `"/bin/sh"`; use `"swift"`, not a toolchain path. MB resolves
that name to its configured executable. If the name is unfamiliar, consult
`command_list` once, choose an entry with `available: true`, and reuse the result;
do not guess a path or repeat discovery before every command. Pass arguments
separately, for example `executable: "sh"`
with `arguments: ["-c", "printf 'hello\\n'"]`.

`Command is not in the local executable allowlist.` is a backend validation
error, not a host Work-mode gate or a child-process exit. For a confirmed
pre-start rejection, correct the input using the supported names; do not change
permissions. For uncertain delivery or an existing task ID, reconcile the job
before starting again.

`command_run` accepts `timeout_milliseconds` and returns final output. Its wait
does not block the MCP input loop. One `command_run` response may be pending;
additional synchronous starts are rejected before launch instead of queued.
`command_start` does **not** accept that field: start once, keep the returned
`task_id`, do other work, then inspect status/output. `process_wait` is a bounded
optional observation wait of at most one second, not a kill deadline or a required
step before output. `process_output` and `process_output_many` already return
status, output, cursors and handle state; do not add status-before/output/status-
after calls when those results suffice. Use status alone when logs are not
needed, and batch variants when several known job IDs need observation. Avoid
frequent polling while useful work is available. Output has separate
stdout/stderr byte cursors; inspect dropped/truncated flags. Tail is a peek, not
the complete log. Fully draining completed output releases its handle; retained
status metadata is not a reusable process handle.

`process_cancel` returns the cancellation snapshot, including bounded retained
stdout/stderr, and releases that job's input/output/cancel handle. Keep this
receipt; do not follow it with `process_output` expecting the handle to remain.
Exception: a pending `command_run` keeps its handle and output budget until its
own completion response is prepared. Cancellation or final output drain reports
`session_retained: true` while that pin exists; it does not cancel the response.
If the job had already exited, `cancelled: false` can correctly preserve its
natural exit. Check the returned state, not just the tool name. After an uncertain
cancel response, reconcile with read-only status/list evidence before taking
another action; do not blindly repeat cancel or restart the command.

These process tools manage MB-owned jobs, not all processes on the Mac. The
command sandbox limits process inspection/signals to the same sandbox;
host-wide inspection with `ps` can be denied even when command_start succeeded.
Report that child error separately from discovery or connector failure. Do not
retry it through alternate executables or widen permissions to obtain a result.

While a process is running, output/peek can hold back up to three trailing bytes
of an incomplete UTF-8 scalar until the remaining bytes or EOF arrive. Always
continue from returned `*_next_cursor`, not the raw `*_total_bytes`. At EOF,
invalid/incomplete bytes use replacement decoding so the handle can still drain.
The output chunk target may extend by up to three bytes to finish a complete
scalar. In contrast, `maximum_output_bytes` is a hard retained-byte ceiling per
stream: truncation advances to a scalar boundary and reports discarded bytes.

Prefer `file_read_many`/`file_stat_many` for several known paths. When a read
already returned the full-file SHA-256 needed for an edit, a separate stat solely
to obtain the same hash is unnecessary; the edit still enforces that hash as a
precondition. A chunk hash or a cached hash without confirmed identity is not a
substitute for a full-file hash.

### Swift builds and tests

Set `cwd` to the directory containing `Package.swift`. For example, start
`swift` with `arguments: ["test", "--jobs", "2"]` from that package directory.
For a regular project workspace prefer a workspace-relative `cwd`, such as
`"LocalMCP"`. A workspace whose live overview advertises `absolute_paths: true`
also accepts a canonical absolute path inside that same registered root; this
does not grant access outside the workspace or follow symlinks. Older runtimes
may require relative paths for project workspaces. Verify the
package with a read/stat operation before starting; keep the same workspace.
Do not supply `--package-path` or duplicate the SwiftPM options managed by MB.
The runtime adds isolated cache/config/scratch paths and disables Keychain,
netrc, dependency prefetching and automatic dependency resolution itself.
Only run reviewed code with its dependencies already available.

`conflicting SwiftPM option` is MB's argument-validation error, not evidence of
a host Work-mode gate. Correct a confirmed validation failure before starting
again; first check that no job was created. Once a `task_id` exists, observe that
job instead of starting another. If a start result is uncertain, inspect the
process list before deciding whether any retry is appropriate.

`file_apply_edits` validates all unique, non-overlapping matches against the
original file hash before one write and one transaction. `file_write_many` is
**not atomic**: check every result, retain successful receipts and do not replay
the whole batch after uncertainty. Restore only the transactions the task owns.
Batch reads and directory summaries are not atomic filesystem snapshots.

For a handoff, pass a short checkpoint: workspace/root, live owner/build if known,
task IDs, independent stdout/stderr cursors, transaction IDs, verified results and
the next step. Do not copy the entire chat or log. A checkpoint is context, not
proof of ownership, authority or job completion; recheck an uncertain owner/handle.
MB does not add a transcript database or model scheduler for this workflow.
The maintained field contract and final evidence shape are in
[`Skills/mb-operator`](../Skills/mb-operator/references/checkpoint-and-evidence.md).
Use them only for long, paused, handed-off, or reportable work.

`file_search` uses buffered reads and skips known dataless/cloud placeholders,
reporting them as unsearched content. Its default cooperative time budget is
5 seconds and aggregate read budget is 32 MiB. Check `complete`, `partial`,
`stop_reason`, `read_bytes` and skip counts. A budget-stopped traversal has no
resumable cursor: narrow/partition `path` instead of repeatedly scanning the same
broad prefix. These limits check between filesystem operations; they cannot
forcibly interrupt a stalled OS read, directory lookup or network filesystem.
The stdio runtime admits one `file_search` on a separate worker so ping,
status/cancel and observer snapshots can continue during a slow search. A second
search is rejected instead of queued indefinitely. Workspace reload waits for
that search to finish; results can still change if another actor edits files.

Git tools use fixed argv and the existing command sandbox, disable external
diff/textconv and hooks/fsmonitor, do not fetch/push, and report exit status and
truncation. Inspect output rather than equating a returned response with success.

## Honest acceptance

Separate discovery/loading errors, invalid parameters, fixture/path errors,
host approval/Work-mode gates, backend execution errors and result-verification
failures. Respect host gates; never relabel writes as reads or switch tools to
evade a denial. Read retries may be bounded; uncertain writes require state and
receipt checks before any retry.

A test should not forbid preparation and then count missing preloaded schemas
as a backend failure. Permit bounded read retries and correction of confirmed
pre-execution parameter errors. An actual approval or permission denial is a
different condition: report it, do not retry it with altered tool semantics.

Normal-Chat acceptance needs actual normal-Chat calls and independent outcomes.
An audit that unexpectedly starts a command fails its read-only contract even
if the command is later cancelled and the document comparison is correct.
Test both fresh and reused chats; previous successful jobs do not authorize
new starts. Separate task-scope compliance from connector/backend availability.
Catalog visibility, a local/Web-profile test, or an assistant's success claim
alone is insufficient. MacBridge does not provide ChatGPT schedule/section APIs,
run an AI model, confer root privileges, or promise universal host callability.
