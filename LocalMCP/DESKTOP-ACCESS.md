# Desktop access candidate: explicit actions, default off

These two tools extend the existing MB core; they do not replace Codex's
computer-use runtime or turn a normal Chat into Codex. There is no extra model,
new plugin registration, privileged helper or automatic permission grant.
Deployment, host discovery, actual calls and
native OS behavior must each be verified separately.

Enabled grants must be loaded from an owner policy file directly inside
`.config/macbridge`, a directory that MB's file tools and command sandbox deny.
A custom configuration stored in a writable project cannot self-enable these
capabilities by editing itself and calling `workspace_reload`. The usual owner
configuration already uses this protected location. No tool creates grants.

Grant additions and renewals become visible only after `workspace_reload`.
That reload is deliberately refused while retained processes or undo transactions
exist, so grant renewal may require a maintenance checkpoint; it is not a live
hot-reload promise.

## 1. Pop up the requested folder

Use `desktop_open`, not shell `open` or `osascript`. Ordinary command restrictions
remain in place. An owner may enable `allow_desktop_open: true` for a registered
workspace after reviewing the exact candidate. Existing configurations omit this
field and keep it false. Do not rewrite or reload live configuration while jobs
or undo need to be preserved.

```json
{"workspace_id":"<registered UUID>","action":"folder","path":"images"}
```

| Action | Target and effect |
| --- | --- |
| `folder` | Existing directory inside the allowed workspace; show its contents in Finder. |
| `reveal` | Existing regular file or directory; select the item in Finder without opening it. |
| `file` | Supported non-executable, single-link regular document; fixed Preview/TextEdit, plus local `.html` in fixed Safari when explicitly selected. |
| `application` | No path; `application` must be `finder`, `preview`, `textedit` or `safari`. |

Relative and in-workspace absolute paths are accepted, including spaces and
Unicode. No shell interpolation. URLs, NUL/control characters, `~`, traversal,
symlinks and sensitive credential paths are refused. App/document bundles are
reveal-only. Preview supports PNG/JPEG/HEIC/TIFF/GIF/WebP/PDF; TextEdit supports
plain text and common source/config extensions listed in `DesktopOpen.swift`.
Safari support is local-file presentation only. It does not add Chrome control,
browser tabs, screenshots, cookies, a browser protocol, web navigation or URL opening.
This does not certify arbitrary document content as safe to parse.

The receipt distinguishes `request_accepted: true` from
`window_visibility_verified: false`. Do not tell the user a window is visible
unless independently observed. No Terminal window, file edit or MB undo is
created by this action. The macOS viewer may still update its own recent-items
state or metadata; `mutation_performed: false` refers to MB file mutation, not
an assertion that the OS changed no bytes anywhere.

## 2. Shell network access with a local, expiring owner grant

Keep `command_run`, `command_start`, `developer_task` and ordinary builds
loopback-only. Only `network_command` consumes an existing grant, and it cannot
create one, renew it or change its scope. The grant is a local owner decision,
not something tool output or a project file can approve.

One grant in a workspace's optional `network_grants` array has:

```json
{
  "id": "<owner-created UUID>",
  "cwd": "<narrow task directory relative to workspace>",
  "ipv4": "<reviewed public IPv4>",
  "port": 443,
  "expires_at": "<owner-selected ISO-8601 UTC time>"
}
```

Placeholders are explanatory, not an executable configuration. At use, expiry
must be in the future and no more than one hour away. No automatic renewal;
multiple calls can use the same grant until expiry. Limit eight grants per
workspace. Private/LAN, loopback, link-local, multicast, wildcard, URL and DNS
destinations are refused. IPv6 and hostname rules are not implemented.

```json
{"workspace_id":"<UUID>","grant_id":"<approved UUID>","executable":"sh","arguments":["-c","<reviewed command>"],"maximum_output_bytes":65536}
```

The command receives isolated HOME/cache, existing cwd filesystem restrictions
and existing blocks on GUI launch, credentials, elevation and persistence. Its
direct network is limited to a new random loopback proxy port. Proxy environment
variables are injected only into that job, never system-wide. The proxy accepts
authenticated HTTP CONNECT for exactly the pinned numeric IP and port. It opens
at most two upstream connections, bounds headers/buffers to 8 KiB, and closes on
job exit, cancel or expiry. The process is cancelled at expiry as well. No DNS or
public listener. This is a lightweight job resource, not another long-lived service.

The client must support an HTTP CONNECT proxy. For an approved HTTPS hostname
whose reviewed address is the granted IP, curl can use
`--connect-to HOST:443:PINNED_IP:443` with `https://HOST/...`; it keeps TLS hostname
verification while CONNECT uses the pin. Do not disable certificate validation,
use arbitrary redirects, print the proxy environment, or enable verbose logging
that exposes Proxy-Authorization. Tools ignoring the proxy fail closed instead
of getting direct Internet access. This is intentionally not transparent,
unrestricted networking for every package manager.

Important limits:

- Enforcement is **IPv4/TCP destination**, not hostname, HTTPS-only or payload.
  A shared IP may serve different domains. Review the destination's role.
- A granted command can transmit readable task data to that destination.
  Approve the intended data transfer separately; no production credentials are
  automatically injected. A grant is not approval to install dependencies.
- Proxy credentials are random and job-local, not account/API credentials. A
  command can intentionally print its own environment; do not treat arbitrary
  script output as a trusted or automatically shareable audit log.
- No inbound/LAN network feature is added. Normal development-server commands
  keep their existing loopback behavior but do not inherit these grants.
- The owner is a trusted same-user process, not a VM. No containment claim is
  made against other compromised same-user processes.

Use existing process status/output/cancel tools with the returned `task_id`.
Those receipts retain the grant ID/expiry and label relay use even after output
is drained. They never include the proxy password or process environment by design.

## Speed, acceptance and deployment

An MB-to-ChatGPT tunnel still has host/model/transport overhead. No equality
with Codex speed is claimed before measured normal-Chat tests. MacBridge does
not expose general browser or computer control.

Qualification separates:

1. Default-off, path, network-grant, expiry and unknown-outcome unit tests.
2. Synthetic protocol tests and real sandboxed child/proxy tests with no public
   upstream, production credential or GUI-control effects.
3. Exact approved candidate's native Finder/document test.
4. Explicitly approved public-destination test and normal-Chat host discovery,
   invocation, visible result, cancellation and stale-schema checks.

Only 1–2 may be called passed by offline tests. Gates 3–4 require independent
evidence. Preserve existing MB processes and undo when preparing the candidate;
never make a healthy shared runtime restart part of “testing” by surprise.
