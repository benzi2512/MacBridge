# Current state

## Serving release — 2026-09-21

The serving release is MacBridge 0.4.3. Its source is the privacy-filtered
public release source commit recorded below plus this documentation-only record.

- runtime build: `0.4.3-read-preflight+0497140678f1`
- source commit: `6e5b6fdd2dcb982e750a4f41a9bd6757774ea21d`
- core SHA-256:
  `0497140678f19f721f0c9c94801ab414b282543cd7a6389f60d699b63c3d9ee8`
- packaged observer SHA-256:
  `a2de06b770dc1c223c7475d55a00f18d01cb075be8829f6fd42d6159f0eb99ba`
- catalog: 76 tools, SHA-256
  `88bb09683fdd79da4a4e0391ff4d99075587a0bf3ebc7be0006c0f34363560fc`

The installed headless core and app-embedded core match the exact reviewed
core hash. The app reports version 0.4.3, build 7, and passes deep/strict
code-signature verification. It remains ad-hoc signed: there is no Developer ID
signature or notarization, so the project still does not claim a one-click
consumer installer.

The full Swift suite passed 701/701 tests. Exact 0.4.3 desktop-local and
web-tunnel E2E gates each passed 303/303 checks with clean exits and unchanged
sentinels. Packaging passed 19 cases plus three manifest self-checks, and the
compact UI source policy passed 42/42 checks. The release candidate privacy scan
found no user home path, personal email/handle, private-key marker or token-shaped
value.

This release fixes a stale host-catalog path: after a web-tunnel client sends
`notifications/initialized`, the core emits one bounded
`notifications/tools/list_changed` notification. The tunnel profiles enable the
initialized notification, and the registered personal ChatGPT plugin was
refreshed once from its own management page. A notification cannot force an old
ChatGPT registration to change, so an existing installation may still require
that one explicit plugin **Refresh** after upgrading.

Eight existing normal Chat conversations that had previously reported disabled,
502, timeout or stale-recipient failures were then exercised against the live
runtime. All eight called the requested capability, workspace and bounded file
operations successfully. Seven materialized the complete 76-schema catalog; the
remaining audit chat materialized a smaller bounded subset but still called all
five requested tools successfully. Every chat reported no `computer_control`,
zero retained transactions/undo bytes, zero reload blockers, and zero active or
retained process handles.

`bridge_diagnostic` deliberately reports `DEGRADED` when the core cannot
self-certify host binding or a file action. In the same normal-Chat acceptance
turn, direct `bridge_capabilities`, `workspace_resolve`, `workspace_overview`,
`file_stat` and `file_read` calls all passed. The diagnostic label is therefore
kept as a conservative unknown, not rewritten into a false internal PASS.

Developer gateway receipts now aggregate child failures and truncation instead
of returning a successful parent while hiding a failed Git child. Work activity
retains bounded structured failure reports and the observer shows child/report
counts. Filesystem traversal errors distinguish a file that is not locally
materialized from a preflight failure and report a protected, workspace-relative
cause instead of a generic error or private absolute path.

Computer control and browser control are absent from the source and serving
catalog. The fixed-purpose `desktop_open` capability remains a separate bounded
tool for Finder, Preview and TextEdit only; it cannot open a browser or URL and
does not add Accessibility, Screen Recording or Input Monitoring authority.

The exact serving runtime is installed and live. The public repository provides
source plus a per-user ChatGPT installation guide. Each other user must still
build the ad-hoc app locally and create their own Secure MCP Tunnel and personal
ChatGPT connection; the repository contains no shared tunnel credential, app ID,
workspace registry or maintainer runtime state.

Older sections below are release history and may describe artifacts that are no
longer serving.

## Previous serving release — 2026-09-20

The serving release is now the reviewed minimal-guardrail build:

- source commit: `a630f7ab53823e438a26944255afd5bc1e61f2db`
- core SHA-256:
  `834fed3a58ccaa15445cc1d13d390b94e3fb1763d8079bf17e108917e376ca9c`
- observer SHA-256:
  `c3b93dc127a94ef78f3633e2178190a30df1f50e673fc1e30954e75225322cb7`
- runtime build: `0.4.0-feedback-hardening+834fed3a58cc`
- serving catalog: 76 tools, SHA-256
  `88bb09683fdd79da4a4e0391ff4d99075587a0bf3ebc7be0006c0f34363560fc`

The installed app's embedded core and the headless serving core match the exact
reviewed core hash. Deep/strict code-signature verification passes. The app is
ad-hoc signed and Gatekeeper assessment rejects it; this repository does not
claim Developer ID signing or notarization.

The full Swift suite passed 692/692 tests after both changes. Exact packaged
desktop and web-tunnel E2E runs each passed 303 checks with clean exits, restored
sentinels and zero retained state. The cutover preflight found no running job or
active call. Previous installed app/core/config generations remain recoverable
outside the source tree. A new two-hour soak was not run for this small patch;
that limitation is recorded in the private pre-install evidence rather than
being converted into a blanket update exception.

Computer control and browser control are not present in the serving catalog.
The fixed-purpose desktop-open capability remains disabled by default in source;
the owner policy explicitly enables it for the current broad workspace. It is
closed to Finder, Preview and TextEdit. It accepts no browser, URL, arbitrary
application, shell fallback or permission change.
For commands, a cwd equal to the Downloads root is read-only and sandboxed to
ordinary single-link files; an explicitly configured child project cwd may
remain writable. Direct file-tool writes keep their existing workspace and file
policy gates and are not described as globally read-only.

After cutover, eight existing normal Chat conversations were exercised at the
same time. Seven initially returned this exact build, owner, catalog count and
catalog digest. The eighth older conversation initially returned
`Resource not found: MacBridge_Developer.bridge_capabilities` because earlier
plain-text `plugin://` syntax had not created a real attachment. Selecting
MacBridge Developer from the conversation's plugin menu created the actual
inline plugin pill; the next bounded capability call then returned the exact
serving build, owner, catalog and digest. A follow-up API-delivered probe is
recorded separately as the persistence check. Final acceptance is therefore
8/8 conversations, including ones that previously reported disabled, timeout,
502 and file-recipient mismatches. Two normal Chats then independently
`file_stat`ed and read the same synthetic Downloads fixture, including the
previously failing conversation; both returned the same 174-byte content and
SHA-256 `ce2fca5e5d1eb4794f93ab4a10779635a6d8c8c5171311458c56a9fbf7790fb5`.

The new mutation receipts return exact creator-only accept/restore arguments for
both success and partial-recovery outcomes. A first normal-Chat acceptance run
proved the host rejected the former 64-hex bearer as secret-like data before the
call reached MB. The final build keeps creator isolation but represents only
transaction capabilities as one UUID. In a fresh normal-Chat run, the chat
created and read a disposable fixture, verified its exact content and SHA-256,
used the receipt's `transaction_resolution.keep_changes` arguments unchanged,
accepted the create transaction, removed and verified the fixture absent, then
used the removal receipt unchanged. Final `transaction_list` reported zero
transactions, zero undo bytes and zero reload blockers. No accept-all route was
added; process and work capabilities retain their previous format.

The same existing normal Chat called `desktop_open` once. The receipt reported
Finder, request accepted, no shell, no mutation and no permission change. An
independent Finder readback showed the requested project folder window. A
separate capability call returned this exact build, core hash, catalog, digest,
desktop-open enabled, credential paths blocked, loopback-only network and zero
process/transaction state.

Normal-Chat command routing reaches the new runtime, but least-privilege policy
still applies. A host safety gate blocked one `printf` payload before MB, and
MB itself rejected `/bin/pwd` because it is outside the configured executable
allowlist. These are policy rejections, not tunnel disconnects. A final
normal-Chat `command_run` using the allowlisted `python3 --version` from the
canonical MacBridge workspace exited 0, printed `Python 3.9.6`, produced no
stderr and did not time out or write a file.

The existing official tunnel client remains version `0.0.14`. After the final
controlled restart, health and readiness passed immediately; the successful
control-plane-poll metric appeared on the first ten-second backoff without a
second restart. Final owner readback reports this exact build and hash, zero
active leases, jobs, process handles, work items and retained transactions.
Actual scheduled-context hint following was not separately exercised in this
cutover, so it remains distinct from the normal-Chat PASS above.

Updated 2026-09-08 after the approved blue-logo release cutover.

## Serving artifacts

- One headless execution core, one optional native observer and the existing
  outbound tunnel adapter. Closing the observer does not stop the core.
- Serving catalog: 55 tools. Source, built candidates and serving artifacts are
  separate; do not install whatever happens to be newest in `.build`.
- Serving core SHA-256:
  `5c6946e98251ceaad9ec7d1c6fda81ec6dc49c0760ca7d9255277c5315b7207b`.
- Installed observer SHA-256:
  `0eece7c40f60cfaeab9ece75525fb6297d9a092587d4a549c6737f452c2fde3d`.
- The app embeds the same serving core. This cutover restarted the existing
  tunnel/core only after an idle preflight with zero jobs, active tasks and undo
  handles. The previous `1182457a10bb` app and core remain in a local recoverable
  rollback directory; its user-specific path is intentionally omitted.
- Ignored local distribution archive SHA-256:
  `6686c4145190c44e7075f5b97328bc0504c1f9aaa0903a83474225604c49e12a`.
  A fresh extraction matched the installed binaries and passed strict/deep code
  signature verification. Ad-hoc signing is not Developer ID or notarization.

## Deployed parent-error accounting fix

The source now counts a retained child job's terminal nonzero exit once instead
of adding another error on every successful status/output readback. Genuine
failed tool calls and partial calls still count separately. Valid mixed-parent
batch outcomes stay attributed to each job's original parent; deduplication
state stays within the existing 128-job retention limit.

The old behavior was reproduced before editing the implementation. The focused
core/observer grouping suite covers a real bounded child exit, cached status
reads, an independent output-read error and 129 job cycles. A separate nested
test attempt inside MB remained correctly non-accepted when macOS refused a
second sandbox layer; no protection was disabled to force it through.

After deployment, normal Chat called this exact b86 artifact without Work or a
fallback connector. One child command started once, printed the expected marker
and exited 7. Repeated list, status and tail observations kept `error_count=1`;
final drain released the handle, the parent finished failed as intended, and
`active_call_count=0`. There were no tool errors, retries or relaunches. This is
a scoped acceptance of terminal-error accounting, not a blanket host guarantee.

## Source-only developer gateway and accident guards

The current source adds a thin two-surface developer gateway, bringing the source
catalog to 55 tools (54 canonical plus one compatibility alias).
`developer_inspect` holds the two read-only actions (`inspect_repo`, `review_diff`),
while `developer_task` holds command/test/continuation actions. Keeping these
annotations honest avoids routing a read-only normal-Chat request through a
write-capable schema. Neither surface adds a second model, scheduler, dependency,
network path or permission; ChatGPT remains the reasoning and authorization layer.

The same source blocks move/remove of exact workspace, system, account-home and
top-level user-data roots. Commands in a broad workspace receive only their
explicit non-root `cwd` subtree; narrow project work keeps the existing broad
file/edit/build/Git capabilities. The full Swift suite passed 279 tests. Exact
Release hashes and finite E2E evidence are recorded in the private candidate
report, including both connector profiles, the retained-parent gateway fixture,
and the activity-resource/streaming fixture with no remaining process or undo
handle. Host rendering and normal-Chat callability are still post-install gates;
this source has not replaced the serving b86 artifact.

## Source-only MB Operator and read hardening candidate

The source now carries one small MB Operator skill and the same compact
inspect → act → verify → repair/finish loop in MCP initialization instructions.
It uses the existing developer, file, process, Git and parent-task tools. Optional
checkpoint and evidence fields are plain data for long/paused work; there is no
new agent, model, workflow engine, database, daemon, permission or network path.

A pre-patch `file_read` against a synthetic FIFO was independently observed to
remain unanswered beyond 750 ms because the pathname open waited for a writer.
The direct read now uses the same non-blocking, no-ancestor-symlink open pattern
already used by retained previews and then requires a single-link regular file.
The focused regression returns in milliseconds. Exact environment templates are
now readable for legitimate setup work while `.env`, secret variants and files
under a template-named directory remain denied in both direct and command paths.

These changes are source-only and have not replaced the serving core. Path-based
hashing/atomic-write parent replacement, same-user loopback services and broad
same-user control-plane access remain explicit audit residuals; no demonstrated
exploit was hidden behind a broad architectural rewrite.

The exact Release core for this source has SHA-256
`92d183067b5d91ca9999bf50f8411eef9d9caeb3d607c714627c6309c0a219e6`.
It passed 181 finite E2E checks in each of the desktop-local and web-tunnel
profiles, including a real MB Operator inspect/edit/test/diff/rollback fixture.
Packaging passed 19 cases and three manifest self-checks; the app passed
deep/strict code-signature verification. It remains ad-hoc signed, is rejected by
Gatekeeper assessment, and is not installed or accepted in normal Chat yet.

## Deployed blue branding

The user-provided 1254 × 1254 blue PNG is the exact visual source of truth. The
installed release uses it in the native observer header, app bundle PNG, Finder,
Spotlight, Dock and application switcher through an ICNS, README, and the inline
activity card through a self-contained 32 × 32 data URI. Smaller assets are
deterministic resizes; the design was not regenerated or redrawn. The card adds
no fetch, server, network permission or polling. Packaging tests require the PNG
and ICNS hashes to match their reviewed source assets. The card moved to a new
cache identity while retaining both previous resource identities for open cards.

The local created-by-me plugin cache also points its composer and logo fields to
the blue 256 × 256 asset. That cache may need a host/plugin reload and can be
replaced by a future host refresh. The account-hosted normal-Chat connector icon
is controlled by ChatGPT and is not claimed changed. The installed runtime reports
build `0.3.0-functional-first+5c6946e98251`, 55 tools and no retained job or undo.
The full Swift suite passed 290 tests; compact UI policy, client behavior, packaging
and exact debug/release stdio card checks also passed.

## Verified observer behavior

- Activity and Details remain in resizable side-by-side panes, with a hideable
  workspace sidebar and compact rows.
- Unlabelled actions now group automatically under **By context**, using retained
  project folders and file targets. Parents are labelled **Inferred**; explicit
  tasks and exact child controls are unchanged. No core update is required.
- Contexts show Running only for live MB activity. Short calls leave the context
  Recent in Active for two minutes, then Idle in All. This uses existing refresh
  cycles without a new timer, transcript reader or background request.
- Selecting a row preserves its bounded parent/child order. Incoming activity
  waits for **Show latest**, while status and counts still update. Explicit
  filter/search/workspace/owner changes release the held order.
- The final 14 focused reading/compact/render tests passed. Native verification
  held a selected fixture parent and its Details steady across two real MB calls
  and another parent updating; Show latest then exposed the new calls.
- The preview request gate prevents automatic refresh from silently swallowing
  an explicit Open/Reveal request. Actual external-editor behavior remains a
  separate interactive acceptance check.
- The current observer suite passed 58 tests through live MB, including separate
  interleaved projects, same-project context grouping, preserved ownership,
  reading order, exact Recent expiry and workspace switching. Offscreen native
  rendering was also inspected; tests do not certify every live workflow.
- A normal Chat then listed three folders across two projects without a supplied
  work ID. Native UI verification showed the corresponding inferred project
  groups, nested receipts, Recent-to-Idle transition and selectable Details.
  Retained receipts from other concurrent activity were also visible; this is
  scoped acceptance of display grouping, not exact chat attribution.

## Normal-Chat evidence and limitations

A normal-Chat fixture performed file patch/readback, a retained process across
observer reconnect, process input/drain, file restoration and explicit parent
completion. The fixture baseline was independently verified. An initial host
discovery attempt lacked necessary callable tools; a legitimate discovery retry
succeeded. This is useful workflow evidence, not universal first-attempt discovery
or every-conversation reliability.

Exact automatic grouping by chat/run is **not implemented or accepted**. Explicit
tasks use `work_id` or a process already linked to one. The separate inferred
display groups may combine two chats using the same project, or split one chat
working across projects. They do not claim chat identity or grant control over
jobs/undo. Mixed or incomplete targets remain ungrouped. The experimental inline
activity card also remains unproven on the intended host surface.

## Serving diagnostic core

Installed core SHA-256:
`f71f992792abdbce2bdee5f5fd5a92f767c4f4ee2a8f5dba0318549076b1f613`.

It adds an off-by-default, owner-bound local request-identity probe. The probe
keeps at most 32 samples of allowlisted metadata field names/types and ephemeral
HMAC equality tags, not raw IDs, arguments, headers or chat contents. It is not
an MCP tool and does not change grouping or permissions. See Observer/README.md.
Focused metadata, interleaved-call and asynchronous-dispatch regressions passed.
After the cutover, a normal Chat discovered and called bridge_capabilities and
file_stat successfully with the new build/owner and the unchanged fixture hash,
without Work or retry. The Codex connector separately received one initial
transport HTTP 504; a later bounded read retry succeeded. This does not certify
universal first-attempt connection reliability.

The bounded live probe retained seven request samples, then was explicitly
stopped and cleared. Each had an object with ten omitted, unrecognized metadata
fields and no allowlisted identity match. This is a coverage limitation, NOT
proof that the host sends no identity. Samples include an independent Codex
read; record counts are not logical chat-call counts. A second, older normal
Chat reported discovery `Resource not found` and did not reach the target file
read. With the independently verified current workspace supplied, that older
Chat discovered file_stat but received `The MacBridge_Developer tool has been
disabled.` at invocation. A new turn in the first Chat read the fixture again
successfully. Cross-chat/run attribution is not established by this probe, and
upgrading the core did not repair every old conversation's host tool state.

A subsequent supported ChatGPT plugin **Refresh** reported **Actions refreshed**
and replaced stale tool descriptions in the management UI with the serving
catalog's descriptions. The same failing old Chat then discovered
bridge_capabilities, but invocation still returned **The MacBridge_Developer
tool has been disabled.** No file read followed. This confirms that catalog
refresh alone did not repair that conversation. The existing app permission
override already allowed all actions; permissions were not broadened, and the
plugin was not removed/reinstalled. Attachment search in the available browser
UI did not expose a selectable MacBridge plugin, so reattachment was not claimed.

The working normal Chat subsequently completed a real, read-only packaging-code
review through two file_read_lines calls after one host discovery step. Both
files reached EOF and their reported SHA-256 values matched the independent
local values. It reported no retry/Work/DC or mutation, and identified concrete
test-coverage gaps. This is successful repeated use of that Chat, not recovery
of the separate disabled conversation.

That same normal Chat then ran the packaging test through `command_start` and
found a real caller-environment defect: the reserved app root inherited mode
0700 from the MB job's private umask instead of preserving source mode 0755.
The packager now restores only the new app root's source mode after copying,
without changing the runtime's umask. The final reviewed source passed all 19
packaging cases and three manifest self-checks through normal Chat, with the
preserve case explicitly forcing umask 0077. The job/parent completion and
output were matched to the live owner's retained receipts; all individual
case logs were checked independently. Installed app/input file hashes and
metadata remained unchanged, as did the serving process identities. These
are successful project-execution checks in that Chat, not a repair or stability
guarantee for the separate disabled Chat, automatic attribution or inline card.

Before a core cutover, recheck active calls/searches, retained processes,
transactions and parent tasks. An empty process list does not mean a chat between
steps is finished. Old recovery scripts contain exact obsolete owners/PIDs and
must never be replayed as generic installation commands. Preserve recovery and
coordinate a maintenance point before changing the serving owner.

## Distribution and recovery

Packaging now supports explicit `--preserve-ui` mode: validate and copy a complete
signed source app, replace only its embedded core with the exact reviewed
candidate, then verify and re-seal the copy. The original raw-binary interface
remains available. Nineteen packaging cases passed, including a distinct
replacement core, invalid seals, overwrite/symlink refusal and a destination
inside the source app. The normal-Chat review's two test gaps were fixed: refused
raw overwrites now require an unchanged manifest, and manifests compare entry
types, permissions, empty directories, literal symlink targets and file
bytes/sizes without following symlinks. Three fixture-only manifest self-checks
also passed. Failed packaging destinations remain inspection-only and must not
be installed. MacBridge executables were not launched by these tests. This fixes
the bundle-bound UI extraction problem without rebuilding the UI or touching the
installed app/runtime. See Observer/README.md for the invocation and limitations.

The ignored local Dist manifest identifies exact artifacts. Source contains no
runtime configuration or credentials. Previous app/archive copies remain in
recoverable Desktop/trash folders ending in `.noindex`; source history preserves
earlier state reports. Seven recovery bundles were removed from search and five
obsolete temporary app bundles were moved into that recovery area. Exact-path
LaunchServices unregistering was used, not a database-wide reset. Directory/file
identities and executable hashes were preserved; no core restart was performed.
Spotlight queries by MacBridge name and bundle identifier now return only the
current installed app. This is app-discovery cleanup, not completion of the
broader normal-Chat, automatic-grouping or inline-card gates.

Seven additional obsolete staging/development/build directories (326,992 KiB,
about 319 MiB) were moved into a manifest-backed Desktop/trash recovery folder,
not deleted. Current runtime paths and the canonical build cache were retained;
keeping that cache avoids an unnecessary rebuild. A fresh Spotlight name query
again returned only the installed app. Moving recoverable copies on the same
volume does not reclaim that disk space.
The four completed packaging-test trees (143,164 KiB) were likewise moved into
a separate manifest-backed recovery folder, with logs, results and literal
symlink targets preserved. No test process or installed app was moved.
