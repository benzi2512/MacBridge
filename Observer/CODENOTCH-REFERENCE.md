# CodeNotch motion and native material reference

Scope: **MacBridge Observer widget and app UI only**. This source-only iteration
does not install a build, stop/restart the existing UI or MCP owner, refresh the
ChatGPT connection, change runtime tools/permissions, or replay work.

## Reference identity and boundary

The user selected [vinzdg/codenotch](https://github.com/vinzdg/codenotch).
The inspected reference is immutable commit
`8406a27fbec4ef8f0df0233d7e194827cd7c4dc7` (2026-09-10), not a moving branch.
GitHub metadata and individual UTF-8 source files were read through its API.
No clone, binary download, package install, upstream test, installer or script
was run. Runtime trust for CodeNotch has not been established; this is a UI
reference review, not an approval to install it. In particular, its README's
quarantine-removal instructions were not followed.

The upstream project is MIT licensed (Copyright 2026 Vinz). MacBridge's motion
parameters draw on that reference, with attribution in
[CODENOTCH-LICENSE.txt](CODENOTCH-LICENSE.txt). Its providers, credentials,
Keychain integration, launch behavior, auto-updater, global pointer monitors
and polling loops are not incorporated.

## What the code actually does

| Reference | Observed technique | MacBridge application |
| --- | --- | --- |
| [NotchMotion.swift](https://github.com/vinzdg/codenotch/blob/8406a27fbec4ef8f0df0233d7e194827cd7c4dc7/Sources/Notch/NotchMotion.swift) | Native SwiftUI springs; fold response 0.42 / damping 0.78, contents 0.36 / 0.82, card glide 0.50 / 0.86; 0.16s crossfade | Central `FloatingMotion`; shape spring, per-icon stagger and card-shell glide |
| [NotchRootView.swift](https://github.com/vinzdg/codenotch/blob/8406a27fbec4ef8f0df0233d7e194827cd7c4dc7/Sources/Notch/NotchRootView.swift) | One retained tooltip, no per-target identity; untinted `glassEffect(.regular)`; solid idle surface | Keep the panel shell while its content changes; remove the navy wash and cyan glow; no idle backdrop contribution |
| [NotchWindowController.swift](https://github.com/vinzdg/codenotch/blob/8406a27fbec4ef8f0df0233d7e194827cd7c4dc7/Sources/Notch/NotchWindowController.swift) | 450ms fold grace, cancelled on pointer return; click-to-pin; bounded geometry changes | 450ms exit grace; preserve MB's existing 100ms entry/preview dwell and pinned-reader behavior |
| [NotchHostingView.swift](https://github.com/vinzdg/codenotch/blob/8406a27fbec4ef8f0df0233d7e194827cd7c4dc7/Sources/Notch/NotchHostingView.swift) | Window geometry does not depend on GeometryReader's ideal size | Disable hosting-view auto-sizing; AppKit remains the only window-frame owner |
| [NotchSurfaceStyle.swift](https://github.com/vinzdg/codenotch/blob/8406a27fbec4ef8f0df0233d7e194827cd7c4dc7/Sources/Settings/NotchSurfaceStyle.swift) | Glass inherits macOS Clear/Tinted and appearance; older OS has fallback | Untinted glass on macOS 26+; neutral material on older macOS; retain MB's explicit System/Light/Dark and opacity preferences |
| [SettingsView.swift](https://github.com/vinzdg/codenotch/blob/8406a27fbec4ef8f0df0233d7e194827cd7c4dc7/Sources/Settings/SettingsView.swift) | Desktop-backed NSVisualEffectView, neutral reading pane, inset glass sidebar | Remove the dashboard's blue/opaque gradient; use neutral reading surfaces and an inset sidebar |

The reference does **not** establish a measured 120 Hz guarantee. Its source
contains a 300ms cursor backup poll and separate clock work. MB does not copy
these loops, introduce a display link, or continuously animate while idle.

## Motion contract

- Native springs drive discrete transitions, not a JavaScript or timer animation engine.
- Icon entrance delay is 45ms per position, capped at 180ms. Exit has no stagger.
- The visible rail stays 36pt wide; the idle handle stays 30 by 58pt with a
  stationary 22pt monochrome MB mark and running-count badge.
- The expanded rail's *transparent backing canvas* adds 4pt horizontally and
  16pt vertically. This contains the small spring overshoot without enlarging
  icons or changing the persistent logo's screen position.
- Painted and hover geometry share the same expansion value. Expansion may
  settle up to 1.04; it is not clamped into a hard stop at exactly 1.
- Window frames still change atomically. They are not animated alongside SwiftUI.
- Closing retains its canvas for 640ms, panel size reductions for 720ms;
  these are conservative backing-lifetime budgets, not opening delays.
  Reopening cancels obsolete shrink work.
- Only the card shell glides. Text/commands do not interpolate into another
  task. Actual reading order and the 64-ID scroll bound are unchanged.
- Reduce Motion suppresses shape/offset motion and uses a short opacity change.
  Reduce Transparency supplies opaque, neutral backgrounds with readable labels.

## Theme contract and deliberate differences

- **Glass, not blue paint:** no custom blue tint, navy overlay or cyan rim.
  The system material controls the chrome. A low-contrast neutral edge remains
  for definition, with a stronger edge for Increase Contrast.
- Dashboard and Settings use desktop-backed native material, not captured
  desktop images. Their windows remain transparent and non-global in appearance.
- The toolbar and widget use MB's own transparent monochrome logo; Finder/app
  icon assets and the MCP/ChatGPT surfaces are unchanged.
- Existing opacity and appearance settings remain effective; no real preference
  is rewritten by building or testing this candidate.
- Unlike CodeNotch's always-black folded pill, MB preserves the user's adaptive,
  translucent idle handle. There is no native glass backdrop contribution in
  that state. This avoids overriding the previously requested black/white
  branding and adjustable transparency.
- Only running/failure/waiting semantic states use accent/status colors. CodeNotch's
  quota colors are not reused as misleading task progress.
- All MB task, inspector, connection and safe-shell behavior is preserved.
  No duplicate Dashboard shortcut or lightning/Quick Actions menu is added.

## Acceptance boundary

Automated checks cover geometry, spring parameter/stagger bounds, interrupted
close/reopen, pinned selection, reading order, badge accuracy, opacity preferences,
neutral accessibility fallback, retained canvas and static resource policies.
Offscreen snapshots are **layout/accessibility evidence**, not proof of the
WindowServer's live Liquid Glass or frame pacing.

Still required before any UI cutover: a separately authorized native preview
after the user's active ad work has finished; inspect real hover reversals,
glass against light/dark backgrounds, Reduce Motion/Transparency, and screen
edges; compare the exact preview binary to the installation artifact. Do not
restart the core for an observer-only update.
