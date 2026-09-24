# MacBridge

<img src="Assets/Brand/macbridge-icon.png" alt="MacBridge logo" width="128">

MacBridge is a headless MCP executable for local file operations and background
processes, with an optional menu-bar, right-edge task surface and full activity
dashboard. It does not run an AI model.
Local MCP clients use stdio. Ordinary Chat requires a supported connector and
transport; the core alone cannot guarantee that a host permits every tool.

The current public source release is **0.4.4**. The installed app and public
source can be compared against the exact hashes in [Current state](CURRENT-STATE.md).
For a separate user's Mac and ChatGPT account, use the owner-neutral
[installation guide](INSTALL-FOR-CHATGPT.md). The GitHub marketplace installs the
MB Operator workflow; each user must still install the local app and create
their own Secure MCP Tunnel and personal ChatGPT connection.

## Set up from Codex

Send Codex this repository URL and ask it to follow
[CODEX-SETUP.md](CODEX-SETUP.md). Codex can audit and install the pinned desktop
app/core, guide the per-user tunnel setup, install the workflow plugin and run
acceptance checks. Account-bound tunnel credentials, ChatGPT Developer Mode and
plugin confirmation still belong to the installing user and are never copied
from the repository owner.

## Source layout

- [Current state](CURRENT-STATE.md): serving artifact, proven scope and remaining host boundary.
- [LocalMCP](LocalMCP/README.md): core, entry point, unit tests and E2E harnesses.
- [Observer](Observer/README.md): menu bar, edge task tab, same-owner activity,
  output, file preview and transaction UI.
- [Inline activity card](LocalMCP/CHAT-UI.md): experimental ChatGPT UI; host
  template rendering is currently failing in the tested deployment.
- [MB Operator](Skills/mb-operator/SKILL.md): the thin inspect → act → verify →
  continue workflow, with optional checkpoint and evidence contracts.
- [Security policy](SECURITY.md): boundaries and known limitations.
- [Brand assets](Assets/Brand/README.md): the canonical blue MacBridge logo and derived app/card sizes.

The source includes listing, reads/search, bounded edits, recoverable
transactions, and headless process start/status/output/input/cancel.
Commands retain filesystem, credential and loopback-network limits.
Use `command_start` for long jobs. `command_run` returns final output, and its
wait runs off the request loop; up to eight command jobs may run concurrently.
Neither requires a Terminal window. See CURRENT-STATE.md for the serving build.

The source catalog includes twelve grouped Brevo tools and the
separate opt-in media transfer. `developer_inspect` keeps repo inspection and diff review explicitly
read-only; `developer_task` starts and continues one bounded background task or
test run. ChatGPT remains the reasoning layer. Compact discovery reduces catalog
payload; it does not force a host to
load functions or permit execution. Normal-Chat routing and embedded UI rendering
remain separate acceptance gates, not completed by passing the local tests.

For multi-step work, `work_task` retains a named parent task across short calls.
Pass its `work_id` on related actions and explicitly finish it when the work is
done. The observer groups those actions under the parent and distinguishes a
running process from waiting for the next step. A caller-provided chat label is
only a label, not authenticated chat identity or an additional permission.

The core includes the compact MB Operator loop in every MCP initialize response,
so a normal Chat connection does not depend on loading a separate local skill.
The packaged skill is the fuller reusable version for clients that support skills.
It adds instructions only: no model, scheduler, database, permission, or network
path. Checkpoints are reserved for long or paused work; routine calls stay direct.

## Build and verification

Review source and test harnesses before execution. The Swift package has no
third-party package dependencies. The following are direct developer commands,
not arguments to MacBridge's command tools. Use an existing compatible toolchain:

```sh
swift build --package-path LocalMCP --configuration release --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2
swift test --package-path LocalMCP --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2
```

When invoking Swift through MB, use the package's workspace-relative directory
as `cwd`; MB supplies its own SwiftPM isolation flags. See the
[tool guide](LocalMCP/TOOL-GUIDE.md#swift-builds-and-tests). Do not copy the direct
command flags verbatim into `command_start`. The full self-test suite exercises
MB's own filesystem/process/observer boundaries; running it inside MB also tests
the compatibility of nested test fixtures with the outer command sandbox. Keep
that result distinct from direct unit-test results and ordinary project builds.

Configuration examples in the LocalMCP README are placeholders. Create your own
configuration locally; do not commit credentials or personal paths.
The observer packager consumes already-built binaries and refuses overwrites.
It does not provision a tunnel, install an updater, or replace a running owner.

Build/local test results do not establish normal-Chat acceptance. Verify
discovery, actual execution, readback and required restore/lifecycle behavior on
the intended host and exact artifact. Host approval/mode restrictions are not
bypassed. Read, job and mutation workflows must be graded separately.

## Sharing boundary

This branch is a privacy-filtered source history. Personal author/contact data,
machine configuration, runtime identifiers, private deployment reports and old
platform artifacts are excluded or replaced with non-personal examples.
Original development/recovery history is kept outside this branch.

Build and identify the exact source revision intended for distribution. Source
changes do not update a running installation: compare the serving executable hash
with the tested artifact. A packaged app needs metadata, signing, binary and
functional checks before sharing. Exclude workspaces, tunnel credentials, observer sockets,
runtime state, logs, chat exports, recovery bundles and debug symbols.
The local observer bundle is ad-hoc signed; no production signing, notarization,
complete Codex/DC parity or universal normal-Chat support is claimed.

Only this branch was filtered. Other branches, tags, cached commit views and
forks can retain old material. Do not infer whole-repository erasure or change
repository visibility from this publication.

The repository marketplace contains no registered ChatGPT app mapping. That is
intentional: an app ID and Secure MCP Tunnel belong to the installing user's
account/workspace and must not be copied from the maintainer. This source release
does not claim one-click public-directory installation or a notarized consumer
DMG.
