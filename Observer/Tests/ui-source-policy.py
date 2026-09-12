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
MOTION = (SOURCES / "FloatingMotion.swift").read_text()
APPEARANCE = (SOURCES / "ObserverAppearance.swift").read_text()
DOCKING = (SOURCES / "FloatingDocking.swift").read_text()


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
check("runtime-aligned-version", info.get("CFBundleShortVersionString") == "0.3.1")
check("canonical-png", (ROOT / "Assets" / "Brand" / "macbridge-icon.png").is_file())
check("canonical-icns", (ROOT / "Assets" / "Brand" / "MacBridge.icns").is_file())

for name, value in {
    "edgeIdleWidth": "30", "edgeIdleHeight": "58", "edgeRailWidth": "36", "edgeRailHeight": "196",
    "edgeLogoSize": "22", "minimumHitTargetSize": "44", "edgeRailSpacing": "0",
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

check("native-adaptive-liquid-glass", ".glassEffect(.regular.tint(glassTint), in: shape)" in SURFACES
      and "colorScheme == .dark" in SURFACES and "Color.black.opacity(" in SURFACES
      and "Color.white.opacity(" in SURFACES)
check("no-blue-glass-wash-or-rim", all(value not in SURFACES + APPEARANCE
      for value in ["GlassColorTreatment", "MBPalette.deepNavy", "MBPalette.surfaceElevated",
                    "MBPalette.cyanHighlight", "MBPalette.surfaceHover"]))
check("explicit-switch-track-and-thumb", "CompactSwitchToggleStyle" in SURFACES
      and "Capsule(style: .continuous)" in SURFACES and "Circle()" in SURFACES
      and ".fill(Color.white.opacity(configuration.isOn ? 0.96 : 0.84))" in SURFACES)
check("event-driven-outside-click-dismissal", "addGlobalMonitorForEvents" in SURFACES
      and "addLocalMonitorForEvents" in SURFACES and "removeOutsideClickMonitors()" in SURFACES
      and "shouldDismissForOutsideClick" in SURFACES
      and "screenPoint(forLocalMouseEvent: event)" in SURFACES
      and "dismissForOutsideApplicationClick()" in SURFACES)
check("spring-motion-not-fixed-curve", ".spring(response:" in MOTION
      and "FloatingMotion.unfold(reduced:" in SURFACES and ".timingCurve(" not in SURFACES)
check("bounded-content-stagger", "staggerStep = 0.045" in MOTION and "maximumStagger = 0.18" in MOTION
      and "FloatingMotion.contents(index: index" in SURFACES)
check("one-retained-card-shell", "compactPanel.id(controller.layer)" not in SURFACES)
check("host-does-not-autosize", "hosting.sizingOptions = []" in SURFACES)
check("resting-material-is-inactive", ".opacity(resting ? 0 : glassOpacity)" in SURFACES)
check("window-background-has-no-gradient", "LinearGradient" not in APPEARANCE
      and "view.blendingMode = .behindWindow" in APPEARANCE)

check("local-logo-drag", "override func mouseDragged" in DOCKING and "FloatingLogoDrag" in DOCKING)
check("bottom-edge-docking", "case right, bottom" in DOCKING and "DockedOrganicEdgeShape" in SURFACES)
check("drag-does-not-grant-input-access", all(value not in DOCKING for value in [
    "CGEvent(", "CGEventTap", "addGlobalMonitorForEvents", "CGRequestPostEventAccess", "AXIsProcessTrustedWithOptions"]))
check("bounded-dock-preferences", "updated.count - 16" in DESIGN and "ui.floatingTabDockAnchors" in DESIGN)
check("first-click-floating-host", "FloatingFirstClickHostingView(rootView:" in SURFACES
      and "override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }" in DOCKING)
check("full-rect-action-targets", ".contentShape(Rectangle())" in SURFACES
      and "controlsPath()" in DESIGN and ".cgPath.union(controlsPath().cgPath)" in DESIGN)
check("minimum-44-point-targets", "edgeTargetSize: CGFloat = minimumHitTargetSize" in DESIGN
      and "CompactIconButtonLabel" in SURFACES and "minimumHitTargetSize" in SURFACES)
check("fixed-edge-endpoint-drag", "let edge = previousEdge" in DOCKING
      and "bottom-right corner is a valid end position" in DOCKING
      and "Choose another edge explicitly below" in SURFACES)
check("readable-scrollable-settings", "struct CompactPreferenceToggle" in SURFACES
      and "CompactSwitchToggleStyle" in SURFACES
      and ".frame(width: 40, height: 24)" in SURFACES
      and "ScrollView {" in SURFACES)
compact_source = DESIGN + SURFACES + LIFECYCLE + APPEARANCE + MOTION + DOCKING
for forbidden in ["repeatForever", "Timer.scheduledTimer", "CVDisplayLink", "CADisplayLink",
                  "DispatchSource.makeTimerSource", "URLSession", "NWConnection", "Process()"]:
    check("absent-" + forbidden.replace(".", "-"), forbidden not in compact_source)
for index, private_marker in enumerate(["/Users/", "api_key", "access_token", "BEGIN PRIVATE KEY"]):
    check("no-private-pattern-" + str(index),
          private_marker.lower() not in compact_source.lower())

print(f"PASS: {len(checks)} compact UI source-policy checks")
