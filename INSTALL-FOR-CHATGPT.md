# Install MacBridge for your own ChatGPT account

This repository provides reviewed source and a ChatGPT/Codex marketplace entry.
It does **not** contain another user's API key, tunnel ID, ChatGPT app ID,
workspace configuration, credentials, logs, browser data or plugin cache.

There are three separate installations:

1. the local MacBridge app/runtime on your Mac;
2. a Secure MCP Tunnel and personal ChatGPT MCP connection owned by your account;
3. the optional `macbridge` operator plugin from this GitHub repository.

Installing one does not silently complete the other two.

## Supported distribution boundary

- macOS 13 or newer on Apple silicon is the currently tested target.
- The v0.4.4 release includes an exact arm64 ZIP and the source needed to rebuild
  it. The app is ad-hoc signed, not Developer-ID signed or notarized, so this
  project does not advertise a one-click consumer DMG.
- The Secure MCP Tunnel is private, account/workspace scoped transport. Every user
  creates and authorizes their own tunnel and personal ChatGPT connection.
- A public, universally installable ChatGPT plugin would require a stable public
  HTTPS MCP endpoint plus OpenAI review. MacBridge intentionally has no public
  listener and this source release does not claim that distribution mode.
- Developer Mode and plugin availability can depend on the user's ChatGPT plan
  and workspace policy.

## Codex-assisted setup

For the shortest owner-neutral route, send Codex the repository URL and ask it
to follow [CODEX-SETUP.md](CODEX-SETUP.md). That workflow pins the exact release
asset and hashes, verifies before installing, and separates local installation
from the user's account-bound tunnel/ChatGPT authorization.

## 1. Review and obtain one exact source release

Read `SECURITY.md`, the release notes and the source before running build scripts.
Use the exact release tag, not a moving branch or an asset copied elsewhere.

```sh
git clone --branch v0.4.4 --depth 1 https://github.com/benzi2512/MacBridge.git
cd MacBridge
git rev-parse HEAD
```

Compare the reported commit with the commit shown on the `v0.4.4` GitHub release.
Do not use a tunnel key, app ID or configuration posted in an issue, screenshot,
fork or chat message.

## 2. Build and package locally

The Swift package has no third-party package dependencies. Use an already
installed compatible Swift 6 toolchain:

```sh
swift build --package-path LocalMCP --configuration release --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2
swift test --package-path LocalMCP --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2
```

Package only those exact built binaries into a new destination:

```sh
candidate_dir="$(mktemp -d)"
sh Observer/package-observer.sh "$(pwd)/LocalMCP/.build/release" "$candidate_dir/MacBridge.app"
codesign --verify --deep --strict "$candidate_dir/MacBridge.app"
```

Inspect the candidate, then copy it to a permanent `Applications` directory you
own. Do not remove quarantine attributes, disable Gatekeeper or weaken macOS
security controls. If macOS refuses the app, stop; build from the reviewed source
or wait for a future Developer-ID/notarized release.

On first launch, **Set Up Local Connection** creates a private workspace allowlist
for this Mac. Choose only project folders the user intends to expose. Credentials,
browser profiles and known secret paths remain blocked.

## 3. Connect the user's own Secure MCP Tunnel

Follow OpenAI's current Secure MCP Tunnel guide. In the user's own OpenAI
organization/workspace:

1. create a new tunnel and grant that user the required Read + Use permissions;
2. install the official `tunnel-client` from the OpenAI-provided channel;
3. configure it to launch this user's packaged `macbridge-mcp` with this user's
   private `workspaces.json` and `--surface web-tunnel`, and set
   `stdio_send_initialized_notification: true` so the core can advertise one
   bounded catalog refresh after initialization;
4. keep `tunnel-client run` healthy and connected;
5. enable Developer Mode in ChatGPT, create a personal plugin, select **Tunnel**,
   then select this user's tunnel;
6. inspect the discovered tools and test `bridge_capabilities` in a new chat.

Never commit or share the API key, `tunnel_id`, generated `plugin_asdk_app...` ID,
workspace configuration or runtime directories. Do not copy those values from the
repository owner or another user.

## 4. Install the optional GitHub marketplace plugin

This installs the owner-neutral MB Operator workflow and branding. It does not
contain or replace the per-user MCP connection from step 3.

```sh
codex plugin marketplace add benzi2512/MacBridge \
  --ref dba87815858f2105d699b9f65d319b1b6d0264b4
codex plugin add macbridge@macbridge-public
```

Restart ChatGPT Desktop, open the Plugin Directory, select the **MacBridge**
marketplace and install **MacBridge**. Start a new chat and attach the personal
MacBridge MCP connection created in step 3.

## Acceptance check

A complete per-user installation has all of these distinct results:

- the local app starts from the exact locally reviewed build;
- `tunnel-client` is healthy, ready and polling successfully;
- ChatGPT discovers the user's own MCP connection and its tool schemas;
- a fresh chat calls `bridge_capabilities` and receives the expected live build;
- if an upgraded personal plugin still exposes an old schema set, use its own
  management-page **Refresh** once and repeat the capability call;
- one bounded read against a disposable file succeeds;
- no credentials, browser data or another user's configuration were imported.

Source build success, a visible marketplace entry or a healthy local process does
not by itself prove the normal-Chat connection is callable.
