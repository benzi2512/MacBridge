# MacBridge Direct Local MCP

The current source catalog contains 72 tools, including twelve grouped Brevo
tools. See [Brevo capabilities and acceptance](BREVO-CAPABILITIES.md) for the
fixed-account API coverage, typed actions, gates and known API limits. This
describes source functionality; verify installed build and host discovery.

The two opt-in media tools stage an explicitly approved local creative for the
existing Meta Ads connector's URL route. They do not access Meta credentials or
create ads. See [media transfer candidate and deployment gates](MEDIA-TRANSFER.md).
No storage or sharing is enabled by installing source alone.

The candidate also adds three opt-in tools for Finder/document opening, scoped
shell networking and selected-app Accessibility. They are off in existing
configurations. See [Desktop access and permission boundaries](DESKTOP-ACCESS.md)
before enabling them; native and normal-Chat acceptance are separate gates.

This package builds one headless executable, `macbridge-mcp`. ChatGPT or Codex
launches it over local stdio. Ordinary Chat uses the same executable behind a
thin outbound tunnel adapter. The functional core has no `MacBridge.app`,
daemon, LaunchAgent, XPC service, VM, Terminal window, or Keychain dependency.

```text
ChatGPT/Codex -> local stdio -> macbridge-mcp -> registered workspace files/processes
ordinary Chat -> registered connector -> outbound adapter -> the same macbridge-mcp
```

## Use

The default configuration is `~/.config/macbridge/workspaces.json`. It must be a
current-user regular file with one link and no group/other write permission.
Each root must be an absolute existing non-symlink directory. By default it must
be narrower than the account home and must not overlap blocked credential or
browser-profile roots. Broader roots require explicit `allow_broad_access: true`,
as described under [Explicit access across the Mac](#explicit-access-across-the-mac);
credential and browser-profile exclusions still apply to operations inside them.

```json
{
  "version": 1,
  "workspaces": [
    {
      "id": "11111111-2222-4333-8444-555555555555",
      "name": "example-project",
      "path": "/absolute/path/to/example-project"
    }
  ]
}
```

Run with the default file:

```text
/absolute/path/macbridge-mcp
```

Or select a configuration explicitly:

```text
/absolute/path/macbridge-mcp --config /absolute/path/workspaces.json
```

The direct desktop surface is the default. The Web adapter selects its identity
without changing the catalog or executor:

```text
/absolute/path/macbridge-mcp --config /absolute/path/workspaces.json --surface web-tunnel
```

Edit the allowlist and call `workspace_reload` to load it without restarting.
Reload is rejected while a process or undo transaction is retained. Restore
or explicitly accept selected transactions before reloading; configuration changes never silently
discard undo. Restart still invalidates owner-local handles.

### Instance identity and connection behavior

`bridge_capabilities` returns `instance_id` (a new UUID for each server instance)
and monotonic `uptime_milliseconds`. The executable SHA-256 and derived build ID
are captured from the executable path at server initialization and stay fixed
for that instance. Replacing the file at that path does not relabel the old
running server; a newly initialized server captures the replacement bytes.
This is an initialization-time artifact snapshot, not mapped-memory attestation
or an ongoing on-disk integrity check. Verify the promoted artifact separately.

The immutable tool catalog and its SHA-256 are constructed once per process.
Repeated capability/discovery calls reuse them. Descriptions are part of the
digest: clarifying the short-command/background-job guidance changes the
catalog digest even though tool names and argument schemas remain unchanged.

The core blocks on stdio input while idle; it has no idle polling loop or remote
reconnect supervisor. The existing outbound adapter owns remote transport and
reconnect behavior. The Web surface accepts a resumed negotiated remote session
without requiring another local initialization handshake; Desktop Local still
requires `initialize` followed by `notifications/initialized`. The immutable
catalog advertises `tools.listChanged=false` and sends no unsolicited catalog
notifications. ChatGPT owns its conversation-local registry; a local notification
cannot repair a host-disabled app and must not make a stable catalog appear dynamic.
Neither build ID nor uptime alone proves the remote connector is reachable.

### Explicit access across the Mac

The default remains a narrow workspace. Both relative paths and canonical absolute
paths inside its registered root are accepted; absolute spelling does not widen
the root. A user can explicitly add a second entry
with `"path": "/"` and `"allow_broad_access": true` to work across the Mac without
registering Desktop, Documents, Downloads, or mounted volumes separately. Keep
the original project entry and its ID. Broad entries accept absolute paths and
report `root_path`, `absolute_paths`, and `access_scope` in `workspace_overview`.

This is current-user filesystem access, not root privilege or a TCC bypass.
Known credential paths, Keychains, browser profiles, and MacBridge's own
credential/config directory remain excluded from both file tools and commands.
Symlinks are not followed by file tools; use canonical paths such as
`/private/tmp` instead of `/tmp`. Network and process limits below are unchanged.
Broad commands put temporary state in the private macOS user temp directory.
Recoverable removal uses `.macbridge/recovery` beside the item on the same
volume, and removes empty recovery directories after restoration.

## Functional workflow matrix

This matrix records the earlier functional baseline and test coverage, not a
fresh acceptance result for every rebuilt release. Revalidate the exact final
artifact; source or fixture results do not establish host-side or clean-machine
readiness. The first-run UI is described in the [release guide](../Release/FIRST-RUN.md).

| Workflow | Implementation/tool | Fixed evidence | Current status | Declared limit |
|---|---|---|---|---|
| Protocol and workspace | MCP stdio, `bridge_capabilities`, list/reload | handshake, exact catalog, reconnect, reload | Direct binary PASS | Host plugin still requires a separate live gate |
| Files and rollback | list/stat/read/write/append/patch/copy/move/remove/restore | Unicode/spaces, chunked binary, independent readback, reverse rollback, sentinel | Direct binary PASS | writes and transactions are bounded; automatic rollback is process-local |
| Search | name/content search with cursor | multiple pages, no duplicates, large file present, generated trees skipped | Direct binary PASS | 10,000 traversed entries per search call |
| Build and test | headless shell plus installed toolchains | real Node project: fail, MCP fix, pass, rollback | Direct binary PASS | no dependency download; only installed tools are claimed |
| Local Git | headless `git` | disposable baseline init/commit; task mutation/rollback preserves an existing dirty diff exactly | Direct binary PASS | disposable repository only; no remote and no push |
| Sessions and jobs | persistent shell/REPL, start/status/output/input/cancel | cwd/env, Python, Node, timeout, cancellation, newest-log tail | Direct binary PASS | stdio only; no PTY or terminal-emulator semantics |
| Local dev server | loopback-only command sandbox | bind, request, file reload, stop, non-loopback denial | Direct binary PASS | `127.0.0.1`/`::1` only; Internet and LAN denied |
| Lifecycle | bounded ownership and cleanup | two MCP starts, finite 10-job stress, empty process/runtime state | Direct binary PASS | host shutdown can invalidate in-memory transaction handles |

## Operational limits

- The source catalog contains 72 tools, including twelve Brevo tools, `developer_inspect`, `developer_task`, `work_task`, `transaction_list`,
  `transaction_accept`, `bridge_activity_view` and `bridge_activity`. See current deployment (private deployment notes excluded) for
  the installed artifact and its acceptance limits. A Chat client can cache an
  older schema or load tools on demand. Use the host's available tool discovery
  before concluding that a tool is unavailable; not initially loaded is not the
  same as not discoverable. Capability counts alone do not prove callability.
  `initialize.instructions` describes direct use and selective discovery without
  repeating all names; `bridge_capabilities.tool_names` exposes the live index.
  `tool_catalog` defaults to 13 starter tools (explicitly truncated); `limit=72`
  gives the full 71-entry canonical index. All 72 tools remain in `tools/list`. Bounded
  `query`/`category` filters return up to 5 suggestions by default. `names`
  preserves exact-schema lookup, and explicit `detail: "schemas"` still returns
  the complete 72-tool catalog. `workspace_list` remains a deprecated callable
  alias for compatibility. All schemas derive from `tools/list`; none of these
  metadata lookups force host loading or override approvals. See TOOL-GUIDE.md.
  `file_read_many` reads up to 32 initial file chunks with a shared 1 MiB raw-byte
  ceiling, explicit per-item errors, EOF and next offsets. Check `complete`; a
  returned batch is not necessarily complete or an atomic snapshot. Continue
  partial files with `file_read`. `file_stat_many` makes content hashing opt-in.
  Both tools reuse the existing workspace, credential and symlink boundaries.
  `file_read` uses byte offsets, `next_offset`,
  and `eof`; UTF-8 chunks may extend by at most three bytes so a scalar is not
  split. Base64 chunks honor the exact requested byte limit.
- One file write, append, or patch is limited to 16 MiB. Recursive copy, move,
  and recoverable remove are limited to 10,000 entries and 500 MB.
- Recoverable move/remove refuse the registered workspace root and exact system,
  account-home and top-level user-data roots. A broad workspace still permits
  ordinary work below those roots. Commands in a broad workspace are scoped to
  their explicit non-root `cwd` subtree instead of receiving machine-wide/home-wide
  filesystem access.
- One owner retains at most 1,024 undo handles and 64 MiB of prior file-content
  payload. Capacity is checked before mutation; no undo is evicted. Successful
  restore releases capacity, while conflicting restore retains it. This is not
  an aggregate cap on same-volume disk recovery or total process RSS. There is
  an explicit `transaction_accept` tool. It releases
  only named undo records, not current files or disk recovery. Do not restart
  merely to free this quota. See the transaction lifecycle section below.
- Process stdout and stderr capacities are reserved together against a 64 MiB
  owner-wide budget before launch. Completed retained handles and observer peeks
  keep their reservation. Consuming final drain, cancellation, failed start and
  synchronous completion release it. Request smaller per-stream capacities for
  more concurrent jobs. Kernel pipes and response copies are not part of this
  retained-payload ceiling.
- Content search marks results partial when files are oversized, invalid UTF-8
  or unsupported, with separate skipped-file counts. A partial final page may
  have no next cursor: paging cannot recover excluded content. Name searches
  do not need to decode file contents.
- Content search reads only valid UTF-8 regular files up to the requested
  per-file bound. `.git` and `.macbridge` are always skipped; build, cache,
  coverage, `node_modules`, and vendor trees are skipped unless explicitly
  included.
- Recursive listing/search preserve readable results when a nested path is
  unreadable or disappears. Such responses report `partial: true`,
  `complete: false`, `skipped_inaccessible_paths`, and up to 20 relative
  `skipped_path_samples`. An unreadable requested root still fails. Follow
  `next_cursor` only when present; its absence does not make a partial result
  complete. Copy/move/remove and their rollback digests still fail on unreadable
  paths rather than silently omitting data.
- Background output is a bounded newest-data tail. Absolute cursor ranges,
  dropped byte counts, and cursor adjustment are returned explicitly.
- `process_input` is nonblocking and may accept a prefix. Resend only the
  reported remaining suffix; close is applied after the full supplied payload.
- Shell pipes work. Persistent shell, Python, and Node state work over stdio.
  Programs that require a real TTY, terminal control sequences, or full-screen
  terminal UI are outside this milestone.
- Use `command_start` for builds, tests and other long-running work, followed by
  `process_output` (or `process_output_many` for several jobs). Use `process_status`
  when logs are not needed, and `process_cancel` when the job should stop.
  `command_run` returns a final result and is intended for short commands. Its
  wait runs on one bounded worker so ping, catalog, reads, status and cancellation
  remain usable. A second pending `command_run` is rejected before launch, not
  queued indefinitely; use `command_start` for concurrent jobs. Workspace reload
  is rejected until the original response is prepared and published. Output and
  its budget stay retained for that response even if another request drains or
  cancels the job; inspect `session_retained` rather than assuming release.
  MCP cancellation notifications are not a substitute for the owned-job cancel tool.
- Cancellation returns a bounded output snapshot and releases the job handle
  unless a pending `command_run` still owns it (`session_retained: true`);
  retain the receipt instead of assuming the cancelled handle remains reusable.
  A job that exited naturally can correctly return `cancelled: false`.
- `process_output` already returns job status and output together; do not add a
  separate status call when its result suffices. After cancellation or a consuming
  final drain, `process_status` can return metadata for up to 5 minutes and
  128 completed jobs. Expired entries are pruned lazily on status/completion;
  the cache remains count-bounded without an idle timer.
  `status_only: true` and `session_retained: false` mean output,
  input and cancellation handles have been released. Expiry/eviction or restart
  yields an unknown task. Status reads do not refresh retention. This is not a
  durable job journal and retains no output, command arguments, stdin or paths.
- Touch ID approval is not implemented. Credential blocks remain enforced; no
  tool response or model-generated approval text can grant sensitive access.
  The separate private-folder experiment was deferred, not promoted. Ordinary
  project files must not acquire per-file biometric prompts. A system-changing
  operation still needs explicit user scope and any macOS permission it requires;
  the core has no approved system-mutation or privilege-elevation route.
- Commands inherit a clean private HOME/cache. Loopback sockets are allowed;
  non-loopback networking, remote Git, SSH, package fetching, and external APIs
  remain blocked or unqualified for ordinary commands. Only the separate
  `network_command` candidate can use an owner-pinned expiring TCP relay grant;
  it does not make ordinary commands or package acquisition Internet-enabled.
- `transaction_restore` validates current state and is automatic only in the
  same MCP process. Recoverable removal keeps bytes under private workspace
  recovery until restore, but restart-time automatic journal replay is not part
  of this milestone.

## Verification

### Transaction lifecycle

`transaction_list` returns metadata, exact relative paths, kinds and retained
undo byte counts without reading current or previous file contents. Pages hold
at most 100 records. Follow the opaque `next_cursor` while `complete` is false;
the keyset ordering survives earlier rows being accepted/restored. New mutations
may appear on later pages: this is not a fixed snapshot. Cursors become invalid
when the registry reloads or the owner restarts; begin a new listing then.

`transaction_accept` requires the current `instance_id` and 1–128 explicit
`transaction_ids`. Every ID is checked before any release; duplicates, unknown
IDs or a different owner reject the entire request. There is no accept-all flag,
automatic eviction, new filesystem grant, or Touch ID prompt.

Acceptance means **keep the current file state and discard selected in-memory
undo**, not validate the user's task. The operation does no file reads, hashes,
writes or deletion. It explicitly reports `current_file_state_validated: false`
and `filesystem_mutation_performed: false`. Other transactions remain restorable.
Request acceptance when the user intends to keep those changes; do not infer it
merely from a full quota or replay acceptance after an uncertain response.

For `path_remove`, the receipt contains the preserved recovery path and digest.
After acceptance, automatic owner-local restore is unavailable, but the disk
payload remains for manual recovery. This frees registry quota, **not disk
space**. Process restart still invalidates all owner-local undo. A missing ID
does not establish whether an uncertain request accepted, restored, or otherwise
lost the handle. These tools are not a durable audit or restart recovery journal.

### Finite gate

The package has no third-party dependencies. After reviewing the harness, run
the finite parameterized gate from the repository root:

```text
python3 LocalMCP/Tests/E2E/run_local_e2e.py \
  --binary /exact/path/macbridge-mcp \
  --evidence-dir /new/path/for/evidence \
  --surface desktop-local
```

Run the same finite gate again with `--surface web-tunnel`; both runs must report
the same binary hash, catalog digest, and functional behavior. A live ordinary
Chat gate is still required because a local Web-surface test does not prove that
the registered connector and outbound adapter are online.

It records raw JSON-RPC requests/responses, independent observations, timings,
server exits, binary SHA-256, section results, and a final summary. The harness
creates and removes only a uniquely marked disposable workspace. A release is
not promoted until this gate, the Swift unit/integration suite, and the separate
live host-plugin invocation all pass against the same binary bytes.

### Ordinary-Chat E2E contract

This is a real workflow test, not an exact-call-count protocol test. Host tool
discovery, workspace/schema lookup, parameter checks and scoped preparation are
allowed. Do not prohibit the discovery needed to make the requested tool callable.
Exact RPC-count assertions belong to separate protocol tests. The offline harness
above does not exercise ChatGPT discovery or handoff, and its results stay separate.

1. Discover the required tools using mechanisms actually available in that Chat.
   Confirm the selected connector, current owner/build, workspace and a fresh
   disposable fixture with a known baseline. Do not assume a retired path exists.
2. Let Chat use necessary preparation, read/search/status and validation steps
   within the authorized task. Limit mutations to the intended fixture changes,
   not the total number of tool calls. No substitute connector, shell-disguised
   mutation, Work handoff or permission change counts as normal-Chat acceptance.
3. Allow at most two additional attempts for a repeatable read after a transient
   transport error. Do not retry a host gate, authorization denial, invalid input
   or persistent configuration error. A consuming output read or handle release
   is not a repeatable read merely because it returns data.
4. Never blindly replay an uncertain write. Reconcile the same owner's receipts,
   transaction state and independent file state first. Missing or expired history
   alone does not prove non-execution. Preserve uncertain undo/jobs; do not restart
   the owner to make the ambiguity disappear. Stop on host approval/mode blocks.
5. Verify the intended change independently and through Chat readback, then
   restore the fixture via MB and verify its baseline hash and untouched sentinels.
   A build workflow also needs real exit/output evidence. Claim only the workflow
   actually completed, on that artifact and Chat surface.
6. Retire fixtures only after the Chat attempt and any handoff decision are
   terminal. Mark the old prompt/path retired; do not manufacture a later
   Path-not-found failure by removing an actively used fixture.

Classify each attempt at its observed stopping point, not as a blanket MB FAIL:

| Classification | Required evidence | Backend / user-workflow verdict |
| --- | --- | --- |
| `TEST_SETUP_INVALID` | Missing fixture, wrong precondition, or test forbids needed preparation | Backend not functionally evaluated; fix the test, do not count an expected input rejection as an MB defect |
| `DISCOVERY_UNAVAILABLE` | Permitted host discovery cannot expose the required tool | Backend not exercised; integration/workflow incomplete |
| `HOST_BLOCKED` | Handoff/approval/policy stop before backend dispatch | Backend not exercised; normal-Chat workflow blocked, not PASS |
| `OUTCOME_UNKNOWN` | Delivery or final mutation state cannot be established | Unresolved; reconcile without replay |
| `BACKEND_FAILED` | Valid in-scope request reached MB and its expected behavior demonstrably failed | Scoped backend/workflow failure; retain the actual receipt |
| `PASS` | Actual task result, readback and required rollback/lifecycle checks succeed | Scoped workflow PASS only |

Keep raw surface messages, timestamps, Chat/attempt identity, owner/build and
backend evidence. A desktop Work card and a Web safety message may describe the
same host constraint; neither wording alone proves distinct root causes. Do not
double-count them as separate MB defects or merge their raw attempts. An agent's
explanation/activity title is not a backend receipt. All required workflows must
still pass before claiming `FUNCTIONAL_PASS`; better grading does not waive a gate.
Keep diagnosis and product readiness separate: a required workflow that remains
host-blocked, undiscoverable or uncertain makes the normal-Chat product NOT READY,
even when the core passes locally. Reliable-use claims also need the applicable
cold/warm session, multi-step task, partial-output, concurrent-job and recovery
cases; one successful call is not evidence of stability in every situation.

### Local safety and recovery constraints

The current defensive boundary remains the existing core, not an additional
agent, permission server or dependency:

- Mutations and undo retain no-follow directory handles. New destinations use
  exclusive publication; failed copies clean only their own staging entries.
  Cross-volume moves refuse before mutation instead of silently becoming a
  copy-and-delete. Perform a separately verified copy and recoverable removal
  when crossing volumes is actually required.
- File hashing/preimages are bounded, regular single-link descriptor reads with
  identity/version checks. Mutable mapped reads are not used. Patch output size
  is checked before allocation, including Unicode-equivalent matches.
- Directory scans collect a bounded set of names before sorting. Responses label
  partial traversal and bounded-set ordering; a truncated result is not a full
  directory inventory or a snapshot across concurrent filesystem changes.
- Child sandbox policy is passed as immutable data to the runner. The retained
  diagnostic profile is not executable authority. Commands cannot rewrite owner
  recovery/runtime state or mutation staging; ordinary project writes and each
  command's private HOME/temp/cache remain available.
- Git inspection denies workspace writes, network, and repository-defined
  subprocesses. A repository requiring custom conversion filters may therefore
  report an inspection error; this is not retried under a write-enabled profile.
- Known credential stores are excluded by one policy shared by direct tools and
  child commands. This is not a universal secret detector and cannot identify
  credentials deliberately stored under arbitrary filenames.
- Observer recovery never launches a core. A refused private socket can be
  reclaimed only with verified preboot identity or a matching core-created
  receipt under the exclusive owner lease. Live or ambiguous endpoints remain
  untouched. Login/tunnel service installation is a separate approved operation.
- After losing a core, the UI rediscovers read-only and adopts a replacement
  owner only outside a pending control. It never replays an uncertain control;
  previous-owner warnings remain labelled, and stale selections are invalidated.

Expected hashes and these checks are not a filesystem compare-and-swap against
arbitrary processes already running as the same user. Concurrent edits can still
produce conflicts or partial outcomes; inspect receipts and current state rather
than blindly replaying mutations. Tests use disposable fixtures, not production
credentials. Local passing tests do not replace normal-Chat/tunnel acceptance.
