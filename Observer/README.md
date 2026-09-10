# MacBridge menu-bar and activity UI

This native AppKit/SwiftUI companion observes one opt-in headless MCP owner. It
provides a variable-width menu-bar item, a right-edge compact task tab and the
full Activity/Details dashboard. It does not start MCP, a tunnel, an AI model,
XPC, a daemon or a terminal window. Closing its windows does not stop the owner.
Building it does not change the installed normal-Chat runtime.

Raw packages include the canonical blue PNG and ICNS. The mark appears in the
menu bar, edge tab, panels and dashboard; the full icon remains available to
Finder and Spotlight. The app is an `LSUIElement`, so it does not add a permanent
Dock tile. Packaging tests compare both bundled assets to the reviewed source
hashes; packaging does not download or regenerate artwork.

## Compact surfaces

- Launch initializes the menu-bar item and right-edge tab without opening or
  focusing the dashboard. `--dashboard` is the explicit developer/test opt-in.
- The idle edge tab is a static 30×58 organic handle on the main display at a
  saved per-display vertical position. It shows the blue mark and only shows a
  task badge for a positive active count (running plus waiting; `1`–`99`, then
  `99+`). The textual summary distinguishes those states.
- A 100 ms hover dwell opens one inward 36×196 rail. The 26pt logo opens
  Dashboard directly; the other four targets are connection refresh, Recent
  Tasks, Settings and Hide Widget. Quick Actions and its lightning shortcut are
  removed. Recent Tasks does not duplicate Dashboard with a View all footer,
  and Settings opens its own controls rather than a dashboard alias. A
  single retained panel grows left for recent tasks, task detail or settings;
  it never creates a panel per task.
- The logo stays at the same screen position when the rail opens. All panels
  share that fixed rail anchor, including near display edges; changing task
  counts does not move it. Its center remains 15pt from the right edge. The
  display remains pinned until it disconnects.
- Only Recent Tasks offers a 100 ms icon-hover preview. Connection, Settings
  and Hide Widget are click-only, so crossing them does not switch panels or
  perform an action. Clicking a preview pins it; hover cannot replace a pinned
  panel or task detail. Clicking the same pinned icon again closes it to the rail.
  Hover tracks the visible silhouette and panel; the transparent corners of the
  retained window canvas do not keep the UI open. Its hit shape uses the same
  morph progress; fading panels remain in the hover region until their exit
  completes. Reduced-motion crossfades retain the union of their silhouettes.
  Canvas shrink decisions compare full window extents, not panel-only heights:
  opening a wider task detail expands immediately, while a smaller Recent Tasks
  panel retains the outgoing bounds until its exit completes. A pending icon
  dwell rechecks Hover previews before opening.
- The visual outline morphs on a constant 36×196 canvas around one retained logo
  button. Window geometry is not animated. Closing retains that canvas for
  240 ms before shrinking; reopening cancels the shrink. Expansion uses 200 ms,
  panels 220 ms and reduced motion 100 ms without shape interpolation.
  Context panels fade and enter 12pt from the rail; Reduce Motion uses opacity
  only. The canvas remains until the panel exit finishes, and reopening cancels
  its pending shrink. The logo and window frame have no implicit animation.
  Native pointer/compositor acceptance is separate from geometry unit tests;
  these timings are not a measured 120 Hz frame-rate claim.
- On macOS 26+, edge and context surfaces use native SwiftUI Liquid Glass, with
  a separate translucent navy wash above the adaptive tint and below labels.
  Dark panel wash alpha is 28–40%; the rail uses 20–30%. Light appearance uses
  a 10–6% white wash. The reduced color cover leaves most of the system material
  visible instead of painting a dense navy panel; it does not dim controls.
  A restrained cyan/blue rim remains. The dashboard uses a transparent native
  window and behind-window material so its desktop backdrop is not blocked by
  an opaque NSWindow.
  Reading panes keep a stable tinted backing. Older systems use standard
  material. Floating Tab glass opacity is adjustable from 35% to 100% and
  defaults to 55%; it changes the floating material, wash, rim and shadow,
  never labels or controls. Reduce Transparency uses an opaque navy/system
  background. Label colors adapt to light/dark appearance. Dashboard and
  floating UI share the same System / Light / Dark preference, applied to both
  SwiftUI and AppKit windows.
  Dashboard and settings controllers own the native window appearance from
  creation through preference changes. Their background extends under the
  transparent full-size title bar; controls continue to respect its safe area.
  A separate Reduce transparency preference respects the system setting too.
  The nonactivating floating panel explicitly requests active visual appearance
  so native controls retain their contrast while another application has focus;
  this does not activate MacBridge. Changes to these material values still
  require exact-binary native acceptance; offscreen arithmetic or layout tests
  do not establish visual equivalence to a mockup or compositor smoothness.
- The menu-bar item shows the canonical mark and an optional active count.
  Its native menu contains at most two task rows, then Dashboard, Recent Tasks,
  Show/Hide Widget, connection, Settings and Quit Interface.
- Compact task state is derived from the same bounded owner snapshot as the
  dashboard. A returned start receipt and its live job are one displayed task;
  disconnected data is paused/last-known rather than falsely called running.
  The attached panel retains at most 64 meaningful parent/context/job IDs in a
  lazy scrolling list. Panel height grows only from 224 to 416pt, with at most
  six rows in the viewport; more history does not create a taller window.
  Reading order stays fixed while the
  panel is open, while row payloads remain live. A missing task keeps its slot;
  Show updates explicitly adopts newer ordering. Completed one-shot receipts
  stay in Dashboard rather than appearing as fake tasks in the edge switcher.
- Hide Widget cancels pending hover/close work and releases its reading IDs.
  It keeps or restores the menu-bar item so Show Widget remains reachable.
  Hiding the widget does not quit the interface, stop the core or cancel jobs.
- The compact UI follows system light/dark appearance by default and responds to
  Reduce Motion, Reduce Transparency and Increase Contrast. Motion is one-shot;
  there is no visual timer, display link, repeating animation, telemetry or new
  network client. It reuses one observer model polling loop, without duplicate
  per-view polling or duplicate forwarding of model redraws. Connected automatic
  reads remain visibility-aware. Foreground cadence is 1s during active work or
  3s otherwise, and background cadence is 5s. Low Power Mode enforces at least
  5s between cycles; repeated offline failures increase the retry interval up
  to 30s.
  These bounds reduce avoidable work, but are not measured CPU, RAM or battery
  savings. No periodic polling is created for an unattached model.
- Rendering tests inject the exact canonical PNG from source, rather than the
  source-binary fallback mark. Opaque layout snapshots exercise accessibility
  fallback only; they must not be presented as native glass acceptance.
- Full-screen display is off by default. The tab and panels clamp to the actual
  `visibleFrame`, including offset displays and space reserved by the Dock/menu
  bar. Keyboard Escape closes the deepest layer first; hover never activates or
  steals focus from the current app.
- Compact controls remain observer/navigation actions only; they do not add
  an independent shell or file-mutation path.

## Connection

### First-time local configuration

The menu's **Set Up Local Connection…** opens an explicit first-run flow. It
previews one selected project folder, then creates an owner-only workspace
registry and observer directory only after the user clicks **Create local
configuration**. The same core registry validator checks the scope. Existing
configuration, symlink ancestors, unsafe permissions and broad roots are
refused, not repaired or overwritten. The app must first be in a permanent
Applications folder, not on a mounted image or a translocated launch path.

The resulting JSON is for a local stdio MCP client. It contains the recipient's
own paths, never credentials or another installation's defaults. Copy happens
only on an explicit button click. Setup starts no core, tunnel, login service,
network request or cloud registration. Ordinary launches keep their menu-only
behavior; `--setup` explicitly opens the setup window for onboarding. Existing
owners keep **Choose connection** and **Refresh Connection** unchanged.

The [first-run guide](../Release/FIRST-RUN.md) distinguishes this local setup
from the separately reviewed normal-Chat adapter and reboot deployment.

An owner must be started with its usual reviewed configuration plus
`--observer-directory /absolute/private/directory`. The directory must already
exist, be owned by the current user, have mode 0700, and have a short canonical
path: Unix socket paths are limited to 103 bytes. The endpoint is `observer.sock`
with mode 0600. The channel checks same-user peer identity and pins instance ID;
it is not protection against another malicious process running as the same user.
This flag is OFF by default. Do not add it to a live deployment without reviewing
and approving that deployment change.

Open the preview and use Connect to select that directory, or pass the same
`--observer-directory` argument to the app. The UI canonicalizes a selected alias
with realpath; the server still validates the canonical private directory.
At launch, without an explicit override, the app retains the known private path
`~/.config/macbridge/observer` even if its socket is not present yet. Bounded
offline retries wait for the existing owner to publish a valid endpoint; this
also works when only the menu bar is shown. The normal private-directory,
same-user and peer-identity checks still apply. The UI does not create that
directory, remove sockets, start the core or start a tunnel. Choose connection
remains available for a non-default owner. Refresh reopens the selected local
observer connection. It does not restart MCP or
force ChatGPT to reload a conversation's tool registry.
Refresh connection explicitly reattaches to the current directory, clears stale
selection/handles and reads the current owner. It does not restart MCP or cancel
jobs. Selecting a different directory remains a separate Connect action.
An explicit refresh resets the offline backoff and performs one immediate read,
without a duplicate snapshot request in the same polling cycle.

Wake and application activation request an immediate, single-flight, read-only
snapshot; they do not cancel a pending snapshot or replay a control. When only
the menu bar is visible, the existing observer loop checks every 30 seconds so
the status item cannot retain a stale Connected state indefinitely. Opening the
status menu requests a current read. There is no second periodic timer or new
network connection. With no visible status surface, connected hidden UI still
does not fetch snapshots.

Closing the edge widget keeps the menu bar available. Restore it with **Show
Widget** in the status menu or the dashboard toolbar; the toolbar button appears
only while the widget is hidden. Dashboard More also opens the real Settings
window. Explicitly reopening an already-running MacBridge app through
Finder/Spotlight restores the widget even if the dashboard is already open.
The `--show-widget` launch argument explicitly restores it on a fresh launch;
ordinary login launch continues to respect the saved visibility preference.

Waiting for a late socket fixes UI/core launch ordering; it is not a promise
that the core and tunnel will start after reboot. Observer does not install a
login item or service. If those processes are stopped, the UI remains honestly
Disconnected while retrying; boot startup requires a separately reviewed
runtime deployment. A core-side stale-socket repair is separate from UI
reattachment and must pass its own checks before deployment.

### Lifecycle acceptance for a deployment

Do not mark a release operational based on one successful capabilities call.
Record the result and evidence level for each applicable case:

| Case | Required check |
| --- | --- |
| User login / reboot | Approved login service is loaded, uses absolute reviewed paths, has bounded restart throttling; then verify a real reboot separately when no work is at risk. |
| UI starts before core | UI remains offline and then adopts the valid owner without manual Connect. |
| Core exits / changes instance | UI drops stale control handles and reconnects by read-only discovery; no command replay. |
| Sleep / wake or app reactivation | One coalesced immediate read, including with only the menu bar visible. |
| Quit / reopen ChatGPT | Existing independent tunnel/core remain alive; verify a read-only call in an existing chat after reopening the host. |
| UI-only update | Packaged core hash is byte-identical to the installed standalone core; no tunnel/core restart or undo loss. |
| Core / tool update | Verify the profile's actual executable, the installed app core and live reported core hashes. Refresh metadata on the existing ChatGPT plugin connection when its schema changes, then verify the affected tools in normal Chat. |
| Hide widget | Restore from dashboard or status menu without a running core; explicit app reopen also restores it. |

Schema refresh is part of release acceptance, not a reason to create another
plugin registration or a new tunnel. Tool count alone is insufficient: compare
the tool names and schemas/fingerprint and exercise changed tools safely. A
simulated owner restart or static login-service check must never be reported as
a successful physical reboot, network outage, or ChatGPT restart.

## ChatGPT chat recovery

The observer's Connect and Refresh controls only read the selected local owner;
they do not refresh ChatGPT's conversation-local tool registry. The app has no
supported API for forcing that host state, so the UI does not present a fake
"Refresh ChatGPT" control.

If an existing ChatGPT chat cannot find MacBridge, attach `@MacBridge Developer`
again and retry a read-only health call. Branching from the latest message may be
useful as a diagnostic because it creates a fresh conversation registry, but it
is not a reliable repair: one live branch recovered one call and then became
host-disabled on a later turn. The observer reports that boundary instead of
claiming its local Refresh control can repair ChatGPT.

## What is real, and what is bounded

- Workspaces, jobs, build/hash and instance identity come from the selected owner.
- At most 64 recent tool invocations and 100 transaction summaries are shown.
  Explicit `work_task` parents are retained separately in `work_items`, so a
  parent's state and total call/error counts survive receipt eviction. This is
  observed tool activity, not a ChatGPT transcript or durable run history.
  In the source fix after the f71 serving build, parent errors count failed or
  partial tool calls plus distinct retained jobs observed with a terminal nonzero
  exit in command/process results or job snapshots. Reading the same failed job again does not
  add a child failure. Batch results keep each job's original parent; failed
  mixed-parent batch calls remain ungrouped. List/observer refresh counts only
  explicit terminal outcomes of mapped jobs, never missing rows. Historical
  counts survive bounded job eviction.
- Output inspection is a non-consuming peek, capped at 8 KiB per stream. The UI
  cannot drain ChatGPT's completed process handle. Owners advertising
  `observer_output_pagination` expose First available / Previous / Next page.
  Refresh re-reads the selected page; only cursor pairs (at most 256), not an
  ever-growing transcript, are retained. Dropped output is disclosed, not recovered.
  Older owners, such as the historical 76 build, provide only the bounded preview.
- Changes renders a unified +/- text comparison for file-tool
  transactions with typed text metadata. It uses one contiguous change hunk,
  not a minimal multi-hunk algorithm, shell attribution or a Git worktree viewer.
  Input text is capped at 8 KiB per side. Incomplete input is labeled PARTIAL
  PREVIEW, never a full-file diff. Binary and older owners use a labeled fallback.
- Cancel acts only on an owned task; Restore uses the owner's existing conflict
  checks and adds independent readback verification. Confirmations identify the
  exact owner and handle. A failed transport is not automatically retried.
- Details are cleared when a handle disappears or connection is lost. Successful
  tool return, process exit 0 and completion of a user's goal are distinct.
- A local owner connection does not prove tunnel health or ChatGPT connectivity.

## Activity and detail controls

- Task and activity rows use two single-line, truncating text lines: action/title
  followed by concise state and context. Full paths, commands, timestamps and
  counters remain in Details and accessibility descriptions; expanding a parent
  reveals its child rows without making every row a tall metadata card.
  New task/context groups start collapsed. Expanded stable IDs remain expanded
  across snapshot refreshes and reset when the selected owner changes.
- Selecting a row holds the existing parent/child positions while statuses and
  counts remain live. New rows wait for **Show latest**; they do not push the
  reader down inside an earlier expanded task. The reading view stores at most
  512 IDs, not previous payloads. Completed rows show their current status;
  expired rows use disabled same-height placeholders. Show latest, search,
  filter, workspace or owner changes release the held order.
- Activity and Details stay side by side in draggable panes; resizing never
  replaces the activity list with a separate detail page. The workspace sidebar
  keeps its list and has an explicit show/hide button. Hide it to give the two
  working panes more room. Text-size controls enlarge or reduce content without a
  new editor or animation system. Connection refresh is separate from
  selected-detail refresh.
- Selecting an eligible, retained single-file action enables a current text-file
  preview through the same private owner channel. Only the selected file is read,
  at most 16 KiB; truncation is labeled. The existing visible-window polling cycle
  checks a metadata version and skips retransmitting unchanged text. No extra
  timer, watcher, full-file hash or retained transcript is added. This is the file
  on disk, not keystrokes or unsaved editor buffers. Binary files, unavailable or
  ambiguous paths and protected paths are not previewed. Open file uses TextEdit
  explicitly, not the executable or a potentially executing default association.
  Reveal shows the owner-confirmed path in Finder. Both require a fresh validated
  selection and remain subject to ordinary macOS permissions.
- All 50 non-UI tools have human-readable activity labels. The two read-only
  activity-card tools are not added to their own feed. Batch returns are labeled
  as batch receipts, not a claim that every item succeeded.
- Owners that retain outcome counters mark incomplete/budget-skipped results and
  per-item errors as Partial result, with available read/write/error counts.
  These entries appear in Issues without relabeling the entire tool call as a
  failure. Older owners without those fields cannot expose the missing detail.
- Find (Cmd-F) searches retained task, action and job metadata: declared task/chat
  label, tool, workspace, sanitized command preview, path/folder, handle IDs and
  error text. All / Active / Issues count tasks, inferred contexts and ungrouped actions,
  not every nested step. Active parents appear first and stay visible between
  calls with **Waiting for the next step**, or **Waiting for you**. Completed and
  failed parents leave Active only after the caller marks that state. An overdue
  or disconnected task is labeled unknown/last-reported, never auto-completed.
- Parent rows expand to show current jobs and retained recent receipts. The
  group uses only explicit `work_id` and retained `job_ids`; a later poll, shared
  folder or similar title cannot relabel a job. A job's starting receipt is
  represented by its job row rather than shown twice. Calls without a work ID
  can appear under the separate **By context** section described below. A returned
  `command_start` receipt does not hide its running job;
  current job state, not the old receipt's `running` flag, determines the filter.
  Stale/disconnected jobs are unknown, not live. Saved changes appear under All.
- Rows include the recorded file/folder, workspace and start time; job details
  link to the starting receipt by task ID, never by a guessed folder or later
  poll. Explicit parent/job membership survives starting-receipt expiry; other
  missing provenance remains unknown. A chat label is caller-declared display
  metadata, not a verified ChatGPT identity. Safe bounded command/target previews
  are shown when the owner supplies them; scripts, secret arguments and file
  contents are not taken from raw request data. Requested edit/line counts are
  distinct from confirmed applied edits. Short ungrouped calls may complete
  between refreshes and appear only in All. An empty Active tab is not evidence
  that ChatGPT finished thinking or its goal. Search does not read files, fetch
  more history, or search output. Parent selection never selects a cancelable
  job or undo record; those controls require selecting the exact child handle.
- Details (Cmd-Shift-D) separates summary fields, stdout/stderr pages and colored
  +/- comparisons. Technical metadata starts collapsed. Color is supplementary;
  status words, icons and diff markers retain the meaning without color.
- Inspector tabs separate Activity, File, Diff and Output. File Live can pause
  selected-file polling without pausing the owner's work. The compact task panel
  also holds up to 64 scrolling IDs while open; Show updates releases that order.
- Cmd-R refreshes selected detail. Output is explicitly a snapshot: opening UI
  does not add an output-draining poller or release ChatGPT's process handle.
- Owner acknowledgements use plain-language receipts; the exact technical
  response remains expandable. Missing evidence does not become a success claim.
- Snapshot polling retains fresh raw metadata but avoids publishing a window
  redraw for changes only to the undisplayed snapshot/uptime clocks. Job, output
  count, owner, busy/stale and other content changes still publish. Inferred
  contexts also publish once when their Recent window expires. This reduces
  redundant view updates; it is not a measured battery-saving claim.
- Workspace changes clear selection. Offline detail is cleared and controls are
  disabled. No search index, telemetry, persisted transcript or new dependency.

### Automatic display grouping without a supplied task

The native observer groups otherwise-unlabelled activity from retained absolute
folders and file targets. It prefers a specific registered project root, then a
project under `Projects`, `repos` or `plugins`, or a useful immediate folder.
The parent is explicitly labelled **Inferred**. This works without a new core,
caller changes, disk scanning or a chat transcript. It is presentation only:
two chats using the same project can appear in one context, and one chat working
across projects can appear in several contexts. Exact chat/run ownership is not
inferred, written back or used for permissions.

Contexts with a live MB call/job show **Running**. After short calls finish, the
context stays **Recent** in Active for two minutes, using the existing visible
window refresh cycle, then becomes **Idle** in All. No extra timer or polling
request is added; neither Recent nor Idle claims overall chat completion. Only
the retained history is grouped, not an unlimited task archive.

Explicit work IDs always win and are never reassigned. Incomplete/mixed-target
batches and missing or redacted paths remain ungrouped. Pathless process polls
can join a context only through an exact unambiguous retained job ID; they do not
replace its origin. Parent selection grants no cancel, restore or file controls.
Select the actual child receipt/job for commands, files, output and existing
preview controls. Selected reading positions remain held until **Show latest**.

Use asynchronous `command_start` for long work. `command_run` now waits outside
the owner operation lock, allowing status and observer requests during its
bounded wait. This does not make every synchronous operation preemptible; cached
busy snapshots still disable controls. There is no new preemptive scheduler.

Recursive `file_search` uses one separately admitted worker, so a slow filesystem
read does not hold the normal request/observer lock. A second simultaneous search
is rejected, not queued; workspace reload waits until that search finishes. Its
time budget is cooperative, not an OS syscall cancellation guarantee. Other
synchronous file/command operations and output backpressure can still delay the
owner; this is not universal operation isolation.

History and undo are in memory. Restart loses them. Graceful stdio EOF cleans
the socket. A crash/kill may leave the socket pathname. Recovery accepts only
an owned private socket that predates boot or matches the private owner receipt,
after a bounded refused-connection probe and unchanged-identity checks. Live,
ambiguous or unrecognized same-boot sockets are preserved. Do not delete a socket
solely because a connection failed.

## Bounded request-identity diagnostic (not automatic grouping)

Exact task grouping requires explicit `work_id` (or an already-linked process).
The separate inferred display contexts above do not infer chat/run ownership from a shared connection,
workspace, folder, title, nearby timestamp or similar commands. A successful
explicit-parent fixture is not acceptance of automatic chat-run grouping.

An observer-enabled candidate exposes the local-only observer action
`identity_probe` with the exact `instance_id` and `operation: start | read | stop`.
This is not an MCP tool and is not exported by activity/card responses. It is OFF
by default, samples at most 32 tool-call envelopes, then stops. Stop clears the
samples. Only recognized identity-like field names/types in protocol `_meta`
are inspected, with bounded nodes/depth/bytes; unknown names and credential/header
subtrees are omitted. Bounded string IDs become per-probe HMAC equality tags;
raw IDs, arguments, headers, chat contents and keys are never retained. No logs,
disk writes, timers, network requests or dependency downloads are added.

Tags show equality only, not authenticated chat identity. Compare repeated calls
in chat A, interleaved calls in chat B, and another turn in A before selecting any
grouping key. Missing metadata at the core does not prove the host never had it;
omitted fields do not prove absence. Installing or starting the diagnostic is not
an automatic-grouping PASS. Preserve active jobs/undo before any core cutover.

## Build, package, test

No third-party package dependencies were added. Review the local code and tests
before execution. From the repository root, build with the existing Swift 6.0+
toolchain (the package targets macOS 13+):

```sh
swift build --package-path LocalMCP --configuration release --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2
swift test --package-path LocalMCP --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2
python3 -B Observer/Tests/ui-source-policy.py
```

`package-observer.sh` takes an absolute release-binary directory and an absolute
new `MacBridge.app` destination; it refuses overwrites and performs no build,
download or installation. Package into a newly created local temporary directory
outside File Provider/iCloud synchronization, then verify signature and hashes
after moving the exact app to Dist. File Provider-added FinderInfo prevented one
Documents-based candidate from signing; that failed candidate was not delivered.
Do not remove quarantine or bypass Gatekeeper to resolve a packaging problem.

From the repository root, using the exact reviewed release binaries:

```sh
sh Observer/package-observer.sh /absolute/release-binary-directory /absolute/new-local-directory/MacBridge.app
codesign --verify --deep --strict /absolute/new-local-directory/MacBridge.app
```

To package an already-tested core while keeping the current UI, use the explicit
preserve mode. It validates the complete source app's deep/strict signature,
copies that app, replaces only its embedded core, and re-seals the copy ad-hoc:

```sh
sh Observer/package-observer.sh --preserve-ui /absolute/current/MacBridge.app /absolute/tested/macbridge-mcp /absolute/new-local-directory/MacBridge.app
```

Do not extract the installed `macbridge-observer` into a raw binary directory:
its signature is bound to the app's Info.plist. Preserve mode keeps resources and
bundle metadata, requires the expected observer executable, rejects source-app
symlinks and verifies the exact candidate core hash before and after signing.
The newly reserved app root receives the source root's permission mode explicitly;
`ditto` alone retains the reserved directory's mode under a restrictive caller
umask. This does not change the caller's umask or the installed source app.
Both modes refuse existing destinations, dangling destination links and symlink
ancestors. Preserve mode also rejects any destination inside its source app,
before creating directories. Neither mode modifies the source app, installs or
restarts anything. A failed copy/sign can leave a partial destination for
inspection only. Never treat a nonzero-exit destination as an install candidate;
retry in a new directory, not over that artifact.

Focused packaging regression cases use only existing reviewed inputs, do not
launch either executable, and retain fixtures/logs in a new local `.noindex`
temporary directory. The preserve case forces umask `0077` and still requires
the complete checked source metadata, including the app-root mode:

```sh
python3 -B Observer/Tests/package-observer.py --binary-directory /absolute/release-binary-directory --source-app /absolute/current/MacBridge.app
```

Packaging signs the bundle and may change the main UI executable's bytes. Record
the final bundle and binary hashes after packaging, and validate those packaged
bytes. A later rebuild or re-sign is a new artifact requiring validation. There
is no generic installer in this source tree: replacing a live owner is a separate
reviewed maintenance operation that can invalidate its in-memory jobs and undo.

The app is an arm64 development preview with an ad-hoc signature, not a
Developer-ID signed, hardened or notarized distribution release.

`e2e_observer.py --binary /exact/macbridge-mcp --evidence /new/path --hold`
creates a synthetic private owner and real disposable file/job for GUI QA. It
does not attach to the installed runtime. On finish it restores the fixture and
stops that owner. The regular LocalMCP E2E gate must also test the exact bundled
core. New-core promotion additionally requires real normal-Chat testing with
UI closed/open/closed; local web-surface simulation is not that proof.

Machine-specific deployment records and historical preview reports are excluded
from shared source. Record the exact deployed hash and remaining host/UI gates
locally; the selected owner's live identity is authoritative for the UI.
