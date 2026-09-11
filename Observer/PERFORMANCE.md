# Observer resource behavior and verification

The Observer displays retained runtime evidence. It does not keep chat transcripts,
infer private reasoning, or run a second task engine.

## Activity-feed work

The dashboard, compact summary, workspace list and selected details share derived
activity data. Only two feeds can be retained: All and the most recently requested
workspace. Switching among many workspaces does not grow a per-workspace history.

The cache is discarded when observable snapshot content changes, a context crosses
its Recent/Idle boundary, or the clock moves backward. Connection and stale/busy
state are checked on every access, including when refresh updates health after
replacing the snapshot. Evicted receipts are not preserved as actionable handles.
Top-level clock metadata remains fresh without invalidating unchanged rows.

This reduces repeated grouping, formatting and allocation during a view update.
It does not change task ownership, polling frequency, retention limits, tool
execution, permissions or network behavior. No new timer, process or dependency
is required. Retained feed data is released with its snapshot or model.

## Existing wake-up policy

- Foreground active work: a one-second refresh cadence.
- Foreground idle: three seconds; background visible surfaces: five seconds.
- Low Power Mode: at least five seconds between scheduled refreshes.
- Menu-bar-only observation: thirty seconds; activation/wake can request an
  immediate read through the same single-flight refresh gate.
- Repeated connection failures back off to thirty seconds.

Compact idle surfaces have no continuous display-link, pointer-polling loop or
repeating decorative animation. File previews refresh only while visible and
enabled. These are source-level policies, not a measured battery-life guarantee.

Logo dragging uses only the widget's own AppKit mouse events. It does not install
a global event monitor or poll the pointer. Intermediate positions are transient;
only the drop persists a bounded per-display anchor. The hosted logo updates only
when its badge, orientation or appearance changes, not for each movement sample.

## Tests and benchmark

`ObserverFeedCacheTests` checks workspace isolation, selection, health transitions,
changing output, missing jobs, owner replacement, clock boundaries and release of
old payloads. Existing tests separately cover polling, stale handles and stable
reading positions.

`ObserverFeedPerformanceTests` is an opt-in, model-only release microbenchmark:
64 receipts, 16 jobs, 32 parent tasks, two workspaces and repeated multi-surface
reads. Enable `MB_OBSERVER_FEED_BENCHMARK=1` when running that test class. Without
the flag it is skipped, keeping routine functional tests independent of timing.
No owner socket, credentials, app window, filesystem fixture or live task is used.
The test reports timing samples and a result checksum; it does not impose a
hardware-specific timing threshold or claim native frame-pacing acceptance.

`ObserverFeedSoakTests`, enabled separately with `MB_OBSERVER_FEED_SOAK=1`,
exercises 2,048 changed snapshots, 6,144 workspace-scope checks and 160 clock-only
refreshes. It rotates 64 receipts, 16 jobs and 32 parents through current, busy,
stale, disconnected and missing-job snapshots. Weak lifetime markers require
every replaced payload and the final model to release; repeated unchanged-clock
updates must not redraw the model. It reports its own test-process resident and
physical-footprint samples after each 128 updates, without reading other
processes or user files. Run it in release mode inside the same isolated harness.
This is accelerated model churn, not a wall-clock endurance, compositor, total
app memory or battery test. Retained allocator pages are not automatically leaks;
reported footprints are evidence, while payload lifetime and scope checks are
functional assertions.

Before interpreting any improvement as whole-app efficiency, measure a signed
release on the intended Mac with a controlled workload. Include idle/active,
hidden/visible, Low Power Mode, memory after repeated updates, and native hover
frame pacing. A model microbenchmark is not proof of 120 Hz rendering, lower
system-wide power draw, or a smooth clean-machine installation.
