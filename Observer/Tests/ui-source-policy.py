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
check("runtime-aligned-version", info.get("CFBundleShortVersionString") == "0.4.4")
check("canonical-png", (ROOT / "Assets" / "Brand" / "macbridge-icon.png").is_file())
check("canonical-icns", (ROOT / "Assets" / "Brand" / "MacBridge.icns").is_file())

for name, value in {
    "edgeIdleWidth": "30", "edgeIdleHeight": "58", "edgeRailWidth": "36", "edgeRailHeight": "196",
    "hoverDelay": "0.10", "hoverExitGrace": "0.45", "openDuration": "0.64",
    "panelDuration": "0.72", "closeDuration": "0.64", "reducedMotionDuration": "0.10",
}.items():
    check("metric-" + name, re.search(rf"static let {name}: [^=]+ = {re.escape(value)}\b", DESIGN) is not None)

check("right-edge-organic-shape", "struct OrganicEdgeShape: Shape" in DESIGN and "addCurve" in DESIGN)
check("packaged-surfaces-use-canonical-logo", 'Bundle.main.url(forResource: "MacBridge", withExtension: "png")' in DESIGN)
check("variable-menu-bar", "NSStatusItem.variableLength" in LIFECYCLE)
check("launch-without-dashboard", "if args.contains(\"--dashboard\")" in LIFECYCLE)
check("main-display-default", "NSScreen.main ?? NSScreen.screens.first" in SURFACES)
check("one-edge-panel-construction", SURFACES.count("EdgeHandlePanel(contentRect:") == 1)
check("four-rail-actions-plus-logo", "case connection, recentTasks, settings, hide" in SURFACES
      and "case dashboard, connection" not in SURFACES)
check("bounded-recent-task-list", "static let capacity = 64" in DESIGN
      and "tasks.prefix(Self.capacity)" in DESIGN)
check("system-reduce-motion", "accessibilityDisplayShouldReduceMotion" in SURFACES)
check("system-reduce-transparency", "accessibilityReduceTransparency" in SURFACES)
check("increased-contrast", "colorSchemeContrast" in SURFACES)
check("zero-and-99-plus-badge", "runningBadgeText" in DESIGN and "runningCount > 99 ? \"99+\"" in DESIGN)
check("no-unreviewed-command-quick-action", '"Run Command"' not in SURFACES
      and all(label in SURFACES for label in ['case .connection: return "Connection"',
                                               'case .recentTasks: return "Recent Tasks"',
                                               'case .settings: return "Settings"',
                                               'case .hide: return "Hide widget — restore from the menu bar"']))

compact_source = DESIGN + SURFACES + LIFECYCLE
for forbidden in ["repeatForever", "Timer.scheduledTimer", "CVDisplayLink", "CADisplayLink",
                  "DispatchSource.makeTimerSource", "URLSession", "NWConnection", "Process()"]:
    check("absent-" + forbidden.replace(".", "-"), forbidden not in compact_source)
for private_marker in ["/Users/", "private-user", "api_key", "access_token", "BEGIN PRIVATE KEY"]:
    check("no-private-" + private_marker.replace("/", "-").replace(" ", "-"),
          private_marker.lower() not in compact_source.lower())

print(f"PASS: {len(checks)} compact UI source-policy checks")
