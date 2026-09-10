# MacBridge — first-run guide

## This is a development image, not a notarized public release

Apple Silicon (arm64), macOS 13 or later. The app is ad-hoc signed for integrity
checks; this does not establish publisher identity. Native Liquid Glass is used
only on supported macOS versions. Older versions use standard system materials.

Do not disable Gatekeeper, remove quarantine, or change system security settings
to open this image. If macOS does not accept the app, stop and request a reviewed,
Developer ID signed and notarized release. Alternatively, review and build the
source with your existing toolchain under your own software-security policy.

## Once the reviewed app is accepted on your Mac

1. Move **MacBridge.app** to a permanent Applications folder in Finder. Do not
   configure it from the mounted image or from a temporary/translocated path.
2. Open MacBridge. It appears in the menu bar; opening the UI does not start a
   core, tunnel, login service or network listener.
3. In the MacBridge menu, choose **Set Up Local Connection…**.
4. Choose one existing project folder. Review it, then click **Create local
   configuration**. Setup creates a private workspace registry and observer
   directory under your own `.config/macbridge`; it will not overwrite an
   existing registry or grant whole-disk access.
5. Copy the displayed **local MCP client configuration** into a client that
   supports stdio MCP. Its command points to the bundled core, with your private
   workspace and observer paths. Review your client's exact configuration format.
   Do not put this machine-specific configuration into the public repository.
6. Start that connection in the client. Check `bridge_capabilities` and
   `workspace_overview` with read-only calls. The observer should then show the
   same owner. A working local connection is not proof of ChatGPT web access.

The menu and dashboard also offer **Choose connection** for an existing owner.
Do not run two clients against the same observer directory. They need separate
reviewed owner directories, or one shared adapter that already owns the process.
Moving the installed app later requires updating the client command path.

## Normal Chat / ChatGPT web

Ordinary Chat needs a separately approved outbound adapter and a connection in
the recipient's own account. This image contains no tunnel executable, token,
private connector registration or automatic cloud setup from another machine.
Do not copy somebody else's credentials or runtime directory. An owner-specific
adapter and login/reconnect setup must be reviewed and tested before claiming
normal-Chat or reboot readiness. Refresh Connection in the widget refreshes the
local observation channel; it cannot force-enable a host-disabled conversation.

## Optional Brevo account

Brevo remains unconfigured until you supply your own private account/key pair as
documented in `LocalMCP/BREVO-CAPABILITIES.md` in the source release. No default
account, recipient, campaign or production audience is shipped. Never place
credentials in the app bundle, DMG, Git history or a shared client configuration.
Capabilities and dry-runs work without credentials. They are not proof that a
real workflow, consent cohort or send operation passed acceptance.

## Close, restore and remove

- **Hide Widget** leaves the menu bar available. **Show Widget** restores it;
  reopening the app also restores a hidden widget.
- **Quit Interface** stops only the UI. Your MCP client owns the core and its
  jobs. Stop that connection separately when no work or undo is at risk.
- Removing the app does not delete project files or private configuration.
  Keep those unless you explicitly decide to remove them. No auto-cleaner runs.
- This development image is deliberately non-indexed while mounted, so its
  staging app should not become another Spotlight application entry.
