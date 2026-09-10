# Experimental inline activity card

MacBridge's headless file and process tools do not require this card. The native
[observer preview](../Observer/README.md) is a separate optional interface.
Neither interface is an AI model, a chat transcript, or a replacement for host
permissions.

## Current status

**The inline card is not accepted for normal-Chat use yet.** On the tested
deployment, discovery and both read-only activity calls succeeded with the same
runtime identity, but the host did not render the card. Its asset request returned
HTTP 404, `HTML asset not found`, shown as `Failed to fetch template`.

A refreshed connector and a new template URI with the ChatGPT compatibility
MIME type did not resolve that result. This rules out that specific compatibility
change as a sufficient fix; it does not establish the cause inside the host or
transport. Resource responses prepared by MCP and successful transport posting
are not proof that the host registered or rendered the HTML asset.

Do not claim a native desktop, mobile, or web render pass from a returned tool
result. Deployment logs and personal runtime/connector identifiers are kept
outside the shareable source repository.

## Interface

- `bridge_activity_view` returns a snapshot and references the embedded card.
- `bridge_activity` refreshes data for the original `instance_id`; optional
  `task_id` peeks at bounded job logs without consuming the process handle.
- Primary resource: `ui://macbridge/activity-chatgpt-v3.html`,
  `text/html+skybridge`, using the feature-detected `window.openai` bridge.
- Previous ChatGPT resource: `ui://macbridge/activity-chatgpt-v2.html`,
  `text/html+skybridge`, retained for existing references.
- Legacy MCP Apps resource: `ui://macbridge/activity-v1.html`,
  `text/html;profile=mcp-app`, retained for existing references. All exact
  allowlisted resources return the same embedded HTML. Arbitrary URI/file/network
  lookup is not supported.
- The two activity tools supplement the 50 file/process/discovery tools. They
  are read-only and require observation enabled on the same headless instance.

## Scope and resource use

The card shows up to 24 tool receipts and 32 jobs from a **shared runtime**, not
from a verified individual chat. It does not expose model reasoning. Snapshots
omit file contents, complete request arguments, environment values and automatic
stdout/stderr dumps. Selecting a job returns at most 4 KiB per stream.

Refresh runs after 3 seconds while active and 10 seconds while idle. Requests do
not overlap. Automatic polling pauses while hidden/offscreen, after errors or
when disposed. An unsettled request pauses after 20 seconds instead of being
silently duplicated. Runtime changes require a new card; cached/busy snapshots
are explicitly labelled.

Long synchronous operations can still delay stdio replies. Use `command_start`
for long work; the card does not introduce a preemptive scheduler. Untrusted
output is rendered as text, not interpreted as HTML.

There is no extra listener, asset server, dependency download, model API,
credential access, Keychain use, telemetry or persistent transcript. Outbound
resource/connect allowlists are empty. Existing transport authentication and
host approval requirements continue to apply.

## Verification

Review the test code before executing it. With the existing Swift and Node
toolchains, from `LocalMCP`:

```sh
swift test --disable-automatic-resolution --disable-keychain --disable-netrc --jobs 2 --filter 'ActivityWidgetTests|ToolDiscoveryTests'
node Tests/E2E/activity_widget_client_test.cjs
node Tests/E2E/activity_widget_stdio_test.cjs
```

These cover exact resource delivery, owner binding, bounded/read-only snapshots,
running/completed jobs, non-consuming log reads and client refresh/error
lifecycle. The stdio test uses the already-built debug executable; it does not
install or restart the user's connected runtime.

The separate acceptance gate must use the exact tested artifact in normal Chat,
allow host discovery/schema loading, visually verify the real card, observe a
disposable job complete, hide/show the card and confirm its original handle is
still usable. Do not bypass a host gate or substitute generated HTML for the
embedded card. Preserve retained jobs/undo before any authorized runtime restart.
