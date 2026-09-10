#!/usr/bin/env python3
"""Static compact-UI policy checks. Reads source only; executes no app or owner."""
from pathlib import Path
import plistlib
import re


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "LocalMCP" / "Sources" / "MacBridgeObserver"
DESIGN = (SOURCES / "MacBridgeDesignSystem.swift").read_text()
SURFACES = (SOURCES / "CompactSurfaces.swift").read_text()
LIFECYCLE = (SOURCES / "AppLifecycle.swift").read_text()
APP = (SOURCES / "ObserverApp.swift").read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


checks = []


def check(name, condition):
    require(condition, name)
    checks.append(name)


with (ROOT / "Observer" / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)

check("agent-app-no-dock", info.get("LSUIElement") is True)
check("app-name", info.get("CFBundleDisplayName") == "MacBridge")
check("macos-13-minimum", info.get("LSMinimumSystemVersion") == "13.0")
check("runtime-aligned-version", info.get("CFBundleShortVersionString") == "0.3.0")
check("canonical-png", (ROOT / "Assets" / "Brand" / "macbridge-icon.png").is_file())
check("canonical-icns", (ROOT / "Assets" / "Brand" / "MacBridge.icns").is_file())

for name, value in {
    "edgeIdleWidth": "30", "edgeIdleHeight": "58", "edgeRailWidth": "36", "edgeRailHeight": "196",
    "edgeLogoSize": "26", "edgeTargetSize": "28", "edgeRailSpacing": "7",
    "hoverDelay": "0.10", "hoverExitGrace": "0.15", "openDuration": "0.20",
    "panelDuration": "0.22", "closeDuration": "0.24", "reducedMotionDuration": "0.10",
}.items():
    check("metric-" + name, re.search(rf"static let {name}: [^=]+ = {re.escape(value)}\b", DESIGN) is not None)

check("right-edge-organic-shape", "struct OrganicEdgeShape: Shape" in DESIGN and "addCurve" in DESIGN)
check("packaged-surfaces-use-canonical-logo", 'Bundle.main.url(forResource: "MacBridge", withExtension: "png")' in DESIGN)
check("variable-menu-bar", "NSStatusItem.variableLength" in LIFECYCLE)
check("launch-without-dashboard", "if args.contains(\"--dashboard\")" in LIFECYCLE)
check("main-display-default", "NSScreen.main ?? NSScreen.screens.first" in SURFACES)
check("one-edge-panel-construction", SURFACES.count("EdgeHandlePanel(contentRect:") == 1)
check("three-actions-and-hide-plus-logo", "case connection, recentTasks, settings, hide" in SURFACES
      and "case dashboard, connection" not in SURFACES)
check("bounded-scrollable-task-list", "static let capacity = 64" in DESIGN and "tasks.prefix(Self.capacity).map" in DESIGN
      and "LazyVStack(spacing: 0)" in SURFACES and "Recent tasks, scroll for more" in SURFACES)
check("system-reduce-motion", "accessibilityDisplayShouldReduceMotion" in SURFACES)
check("system-reduce-transparency", "accessibilityReduceTransparency" in SURFACES)
check("adjustable-floating-glass", "ui.floatingTabGlassOpacity" in DESIGN
      and "Floating Tab glass" in SURFACES and "mbGlassOpacity" in SURFACES)
check("increased-contrast", "colorSchemeContrast" in SURFACES)
check("zero-and-99-plus-badge", "runningBadgeText" in DESIGN and "runningCount > 99 ? \"99+\"" in DESIGN)
check("no-redundant-quick-actions", all("quickActions" not in text for text in [DESIGN, SURFACES, LIFECYCLE]))
check("no-dashboard-task-footer", "View all tasks" not in SURFACES)
check("recoverable-widget-hide", "func hideFloatingTab()" in DESIGN and "Show Widget" in LIFECYCLE
      and "controller.hideWidget()" in SURFACES)
check("dashboard-widget-recovery", "WidgetRecoveryButton(preferences: recoveryPreferences)" in APP
      and 'accessibilityIdentifier("show-floating-widget")' in APP)
check("dashboard-settings-entry", 'if let openSettings { Button("Settings…"' in APP)
check("reopen-restores-widget", "applicationShouldHandleReopen" in LIFECYCLE
      and "preferences.showFloatingTab = true\n        model.resumeObservation()" in LIFECYCLE)
check("wake-and-activation-refresh", "NSWorkspace.didWakeNotification" in LIFECYCLE
      and "NSApplication.didBecomeActiveNotification" in LIFECYCLE)
check("bounded-menu-only-refresh", "menuBarOnly ? 30" in APP
      and "visible || menuBarVisible" in APP)
check("bounded-logo-cache", "cachedSizes.contains(size)" in DESIGN)

compact_source = DESIGN + SURFACES + LIFECYCLE + (SOURCES / "ObserverAppearance.swift").read_text()
for forbidden in ["repeatForever", "Timer.scheduledTimer", "CVDisplayLink", "CADisplayLink",
                  "DispatchSource.makeTimerSource", "URLSession", "NWConnection", "Process()"]:
    check("absent-" + forbidden.replace(".", "-"), forbidden not in compact_source)
for index, private_marker in enumerate(["/Users/", "api_key", "access_token", "BEGIN PRIVATE KEY"]):
    check("no-private-pattern-" + str(index),
          private_marker.lower() not in compact_source.lower())

print(f"PASS: {len(checks)} compact UI source-policy checks")
