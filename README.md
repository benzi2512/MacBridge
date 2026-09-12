# MacBridge

MacBridge is a native macOS execution core with a companion activity observer.
An MCP client chooses operations; the core performs bounded work against an
explicit workspace registry and returns evidence. The observer displays the
same owner's activity rather than operating a second execution engine.

## Current source

This source contains 72 MCP tools, including 12 Brevo tools, a compact discovery
index, high-level developer workflows, parent activity, process control, guarded
file changes and bounded undo. See [LocalMCP](LocalMCP/README.md),
[tool discovery](LocalMCP/TOOL-GUIDE.md), [Brevo](LocalMCP/BREVO-CAPABILITIES.md),
[Observer](Observer/README.md) and the [security policy](SECURITY.md).

The desktop tools can open an approved workspace folder in Finder, run a command
with a short-lived network grant, or operate one explicitly approved application.
These capabilities are **off by default** and do not grant themselves access.
See [desktop access and its limits](LocalMCP/DESKTOP-ACCESS.md). The native
observer uses system glass, a compact monochrome widget and retained task
selection; it never changes a client's tool permissions.

The two media tools prepare a selected local creative and can stage it behind an
expiring link only after separate owner storage configuration and sharing approval.
No storage account, credentials or default upload destination are shipped. Meta
Ads URL ingestion still needs a separate live acceptance test; preparing or
staging a file is not proof that Meta accepted it. See [media transfer and its
limits](LocalMCP/MEDIA-TRANSFER.md).

The implementation is Swift 6, targets macOS 13 or later and declares no external
Swift package dependencies. It uses macOS system frameworks and the installed
toolchain. The optional [MB Operator skill](Skills/mb-operator/SKILL.md) supplies
workflow guidance, not additional permissions or another model.

The current release preparation removes private account, machine and business
defaults from shared source. It also separates bounded Brevo network work from
protocol discovery so a slow Brevo operation does not hold the main request
reader. A second simultaneous Brevo call is rejected, not queued or replayed.

## Build and configuration

Review source and executable build/test paths before using installed Swift tools:

```sh
swift build --package-path LocalMCP -c release
```

The products are `macbridge-mcp` and `macbridge-observer`. Configure a narrow,
owner-selected workspace as described in LocalMCP/README.md. No account home,
whole disk, credential path, login service, tunnel or root privilege is granted
by building or opening the observer. **Set Up Local Connection** lets a new
owner explicitly choose one project folder and create a private registry plus
observer directory. It produces a local-client configuration without starting
a core, modifying an existing registry, or creating a ChatGPT tunnel. See the
[first-run guide](Release/FIRST-RUN.md).

Setup opens automatically on a new account. After restarting the app, the same
setup window can recover and copy connection instructions for an existing,
validated private registry. It preserves that registry's workspace scopes and
grants; it does not replace configuration or start another runtime.

Every recipient needs their own workspace configuration, credentials and host
connection. Do not copy an existing user's runtime directory, workspace registry,
browser session, connection token or credential file into an app or installer.
Brevo uses a private, explicit per-owner account binding; live calls remain
disabled until the owner configures it. Offline previews require no credentials.

## Release status and verification boundaries

This is a release-preparation source, not a notarized distribution claim. The
packagers produce ad-hoc signed development artifacts. The release packager
builds a DMG only from pinned raw binaries and reviewed resources, then mounts
it read-only and checks its exact contents, signatures and privacy rules.
Developer ID signing, notarization and real-user first-run/reboot
acceptance must be completed before calling installation distribution-ready.
Never remove quarantine or disable macOS controls to make a test pass.

Use the [release privacy gate](Release/README.md) on source, reachable Git history
and exact final payloads separately. Keep private markers, caches, logs and
deployment records outside exported source. A clean working tree is not evidence
that earlier commits or binary resources are clean.

Local protocol success, a tunnel connection and host-side tool enablement are
different observations. A cached, disabled ChatGPT conversation is not proven
recovered by a local capability response. Do not replay an uncertain write or
claim a task complete without its actual result.

In `bridge_capabilities`, `active_command_runs` counts active `command_run`
execution leases, not background jobs or acknowledgement of response delivery.
`process_activity` separately reports running processes, completed-but-retained
handles, starting reservations and the shared handle limit. These are runtime-wide
snapshots, not per-chat identity or permission to restart. A zero running count
does not mean every output handle or undo transaction has been released.
