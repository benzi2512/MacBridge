import AppKit
import SwiftUI

enum MBMetrics {
    static let edgeIdleWidth: CGFloat = 30
    static let edgeIdleHeight: CGFloat = 58
    static let edgeRailWidth: CGFloat = 36
    static let edgeRailHeight: CGFloat = 196
    static let edgeLogoSize: CGFloat = 22
    static let edgeBrandHeight: CGFloat = 38
    static let edgeTargetSize: CGFloat = 28
    static let edgeRailSpacing: CGFloat = 7
    static let panelGap: CGFloat = 0
    static let panelWidth: CGFloat = 320
    static let taskDetailWidth: CGFloat = 360
    static let settingsHeight: CGFloat = 520
    static let taskDetailHeight: CGFloat = 520
    static let panelRadius: CGFloat = 16
    static let tooltipRadius: CGFloat = 11
    static let hoverDelay: TimeInterval = 0.10
    static let hoverExitGrace: TimeInterval = 0.45
    // Canvas retention budgets, not animation speed. A spring must finish
    // settling before AppKit is allowed to trim its backing surface.
    static let openDuration: TimeInterval = 0.64
    static let panelDuration: TimeInterval = 0.72
    static let closeDuration: TimeInterval = 0.64
    static let reducedMotionDuration: TimeInterval = 0.10
    static let edgeMotionHorizontalSlack: CGFloat = 4
    static let edgeMotionVerticalSlack: CGFloat = 16
}

enum MBPalette {
    static let brandBlue = Color.accentColor
    static let electricBlue = Color(red: 22 / 255, green: 119 / 255, blue: 1)
    static let cyanHighlight = Color(red: 53 / 255, green: 201 / 255, blue: 1)
    static let deepNavy = Color(red: 7 / 255, green: 17 / 255, blue: 31 / 255)
    static let surface = Color(red: 11 / 255, green: 25 / 255, blue: 48 / 255)
    static let surfaceElevated = Color(red: 14 / 255, green: 39 / 255, blue: 68 / 255)
    static let surfaceHover = Color(red: 18 / 255, green: 49 / 255, blue: 82 / 255)
    static let textPrimary = Color.primary
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let running = Color.accentColor
    static let waiting = Color(nsColor: .systemOrange)
    static let completed = Color(nsColor: .secondaryLabelColor)
    static let failed = Color(nsColor: .systemRed)
    static let paused = Color(nsColor: .secondaryLabelColor)
    static let idle = Color(nsColor: .secondaryLabelColor)

    static let nsBrandBlue = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
    static let nsCyan = NSColor(srgbRed: 53 / 255, green: 201 / 255, blue: 1, alpha: 1)
    static let nsElectricBlue = NSColor(srgbRed: 22 / 255, green: 119 / 255, blue: 1, alpha: 1)
}

enum CompactTaskStatus: String, CaseIterable, Sendable {
    case idle, waiting, running, paused, completed, failed, cancelled

    var label: String {
        switch self {
        case .idle: return "Recent"
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .running: return MBPalette.running
        case .waiting: return MBPalette.waiting
        case .completed: return MBPalette.completed
        case .failed: return MBPalette.failed
        case .paused, .cancelled: return MBPalette.paused
        case .idle: return MBPalette.idle
        }
    }
}

struct CompactTaskPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let projectName: String
    let status: CompactTaskStatus
    let progress: Double?
    let startedAt: Date?
    let updatedAt: Date?
    let shortActivity: String
    let selectionID: String
    let canCancel: Bool

    var statusText: String {
        if let progress, status == .running {
            return "\(Int((min(1, max(0, progress)) * 100).rounded()))%"
        }
        return status.label
    }
}

struct CompactSummary: Equatable, Sendable {
    let connected: Bool
    let busy: Bool
    let countIsCurrent: Bool
    let tasks: [CompactTaskPresentation]

    var runningCount: Int { tasks.filter { $0.status == .running }.count }
    var waitingCount: Int { tasks.filter { $0.status == .waiting }.count }
    var activeCount: Int { runningCount + waitingCount }
    var activeBadgeText: String? { activeCount == 0 ? nil : activeCount > 99 ? "99+" : String(activeCount) }
    var failedCount: Int { tasks.filter { $0.status == .failed }.count }
    var runningBadgeText: String {
        guard countIsCurrent else { return "–" }
        return runningCount > 99 ? "99+" : String(runningCount)
    }

    var runningBadgeHelp: String {
        guard countIsCurrent else { return "Running task count unavailable · waiting for a current MacBridge snapshot" }
        return "\(runningCount) \(runningCount == 1 ? "task" : "tasks") running across all workspaces"
            + (waitingCount > 0 ? " · \(waitingCount) waiting for the next step" : "")
    }

    var globalStatus: CompactTaskStatus {
        if runningCount > 0 { return .running }
        if waitingCount > 0 { return .waiting }
        if failedCount > 0 { return .failed }
        return connected ? .idle : .paused
    }

    var statusText: String {
        guard connected else { return "disconnected" }
        guard countIsCurrent else { return busy ? "updating" : "status unavailable" }
        if runningCount > 0 { return "\(runningCount) running" }
        if waitingCount > 0 { return "\(waitingCount) waiting" }
        if failedCount > 0 { return "\(failedCount) failed" }
        return busy ? "updating" : "idle"
    }

    init(feed: ActivityFeed, connected: Bool, busy: Bool) {
        self.connected = connected
        self.busy = busy
        countIsCurrent = connected && feed.jobsCurrent
        var rows: [CompactTaskPresentation] = []
        rows.reserveCapacity(feed.groups.count + feed.contextGroups.count + feed.ungroupedItems.count)

        for work in feed.groups {
            let status: CompactTaskStatus
            if !connected || work.stale { status = .paused }
            else if work.state == "failed" { status = .failed }
            else if work.state == "completed" { status = .completed }
            else if work.executing { status = .running }
            else { status = .waiting }
            rows.append(CompactTaskPresentation(id: work.id, title: work.title, projectName: work.workspaceName,
                status: status, progress: nil, startedAt: nil, updatedAt: work.updated,
                shortActivity: work.currentAction?.title ?? work.phaseLabel, selectionID: work.id, canCancel: false))
        }

        for context in feed.contextGroups {
            let status: CompactTaskStatus = !connected || context.stale ? .paused
                : context.executing ? .running : .idle
            let action = context.currentAction
            let title = action.flatMap { $0.presentation.title.isEmpty ? nil : $0.presentation.title }
                ?? "Recent project activity"
            let project = context.title.isEmpty ? context.workspaceName : context.title
            let detail = action?.commandPreview ?? action?.presentation.subtitle ?? context.status
            rows.append(CompactTaskPresentation(id: context.id, title: title, projectName: project,
                status: status, progress: nil, startedAt: context.visibleChildren.compactMap(\.started).min(),
                updatedAt: context.updatedMilliseconds > 0
                    ? Date(timeIntervalSince1970: context.updatedMilliseconds / 1000) : nil,
                shortActivity: detail,
                selectionID: context.id, canCancel: false))
        }

        let retainedJobs = Set(feed.ungroupedItems.filter { $0.kind == .job }
            .compactMap { $0.raw["task_id"] as? String })
        for item in feed.ungroupedItems {
            if item.kind == .call {
                let tool = item.origin["tool"] as? String ?? ""
                let result = item.origin["result"] as? [String: Any] ?? [:]
                if (tool == "command_start" || tool == "command_run" || tool.hasPrefix("git_")),
                   let taskID = result["task_id"] as? String, retainedJobs.contains(taskID) { continue }
            }
            // A standalone completed/read receipt is an activity row, not a
            // task. Only a retained background job may become an ungrouped
            // task card when no explicit/inferred parent exists.
            guard item.kind == .job else { continue }
            let result = item.kind == .job ? item.raw : item.raw["result"] as? [String: Any] ?? [:]
            let status: CompactTaskStatus
            if !connected || item.presentation.subtitle.hasPrefix("Unknown") { status = .paused }
            else if result["cancelled"] as? Bool == true { status = .cancelled }
            else if item.presentation.running { status = .running }
            else if item.presentation.failed { status = .failed }
            else { status = .completed }
            rows.append(CompactTaskPresentation(id: item.id, title: item.title, projectName: item.workspaceName,
                status: status, progress: nil, startedAt: item.started, updatedAt: item.finished ?? item.started,
                shortActivity: item.presentation.subtitle, selectionID: item.id,
                canCancel: item.kind == .job && status == .running))
        }

        func rank(_ status: CompactTaskStatus) -> Int {
            switch status {
            case .running: return 0
            case .waiting: return 1
            case .failed: return 2
            case .paused: return 3
            case .idle: return 4
            case .completed: return 5
            case .cancelled: return 6
            }
        }
        tasks = rows.sorted {
            let lhs = rank($0.status), rhs = rank($1.status)
            if lhs != rhs { return lhs < rhs }
            let lhsDate = $0.updatedAt ?? $0.startedAt ?? .distantPast
            let rhsDate = $1.updatedAt ?? $1.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.id < $1.id
        }
    }
}

extension ObserverModel {
    var compactSummary: CompactSummary {
        // The menu bar and widget describe the owner, not the Dashboard's
        // selected workspace. A local filter must never hide another task.
        CompactSummary(feed: allActivityFeed, connected: connected, busy: busy)
    }
}

enum FloatingLayer: Hashable, Sendable {
    case idle
    case rail
    case recentTasks
    case settings
    case taskDetail(String)

    var hasPanel: Bool {
        switch self {
        case .recentTasks, .settings, .taskDetail: return true
        case .idle, .rail: return false
        }
    }

    var isExpanded: Bool { self != .idle }
}

struct FloatingInteractionStateMachine: Equatable, Sendable {
    private(set) var layer: FloatingLayer = .idle
    private(set) var locked = false

    mutating func hoverDelayElapsed(pointerInside: Bool) {
        guard pointerInside, layer == .idle else { return }
        layer = .rail
    }

    mutating func exitGraceElapsed(pointerInside: Bool) {
        guard !pointerInside, !locked else { return }
        layer = .idle
    }

    mutating func select(_ next: FloatingLayer, locked requestedLock: Bool? = nil) {
        layer = next
        locked = next.hasPanel && (requestedLock ?? true)
    }

    mutating func unlockToRail() {
        layer = .rail
        locked = false
    }

    mutating func closeDeepest() {
        switch layer {
        case .taskDetail:
            layer = .recentTasks
            locked = true
        case .recentTasks, .settings:
            layer = .rail
            locked = false
        case .rail:
            layer = .idle
            locked = false
        case .idle:
            break
        }
    }
}

struct EdgeLayout: Equatable, Sendable {
    static let outerInset: CGFloat = 8

    static func panelSize(for layer: FloatingLayer, taskCount: Int) -> CGSize {
        switch layer {
        case .recentTasks: return CGSize(width: MBMetrics.panelWidth, height: recentTasksHeight(taskCount: taskCount))
        case .settings: return CGSize(width: MBMetrics.panelWidth, height: MBMetrics.settingsHeight)
        case .taskDetail: return CGSize(width: MBMetrics.taskDetailWidth, height: MBMetrics.taskDetailHeight)
        case .idle, .rail: return .zero
        }
    }

    static func recentTasksHeight(taskCount: Int) -> CGFloat {
        // Keep a bounded viewport, not a window that grows with the history.
        128 + CGFloat(min(6, max(2, taskCount))) * 48
    }

    static func size(for layer: FloatingLayer, visibleFrame: CGRect, taskCount: Int = 3) -> CGSize {
        let requested: CGSize
        switch layer {
        case .idle:
            requested = CGSize(width: MBMetrics.edgeIdleWidth, height: MBMetrics.edgeIdleHeight)
        case .rail:
            // Invisible slack contains the soft spring overshoot. The painted
            // rail and its hit targets keep their original narrow dimensions.
            requested = CGSize(width: MBMetrics.edgeRailWidth + MBMetrics.edgeMotionHorizontalSlack,
                               height: MBMetrics.edgeRailHeight + MBMetrics.edgeMotionVerticalSlack)
        case .recentTasks:
            requested = CGSize(width: MBMetrics.edgeRailWidth + MBMetrics.panelGap + MBMetrics.panelWidth,
                               height: max(MBMetrics.edgeRailHeight, recentTasksHeight(taskCount: taskCount)))
        case .settings:
            requested = CGSize(width: MBMetrics.edgeRailWidth + MBMetrics.panelGap + MBMetrics.panelWidth,
                               height: max(MBMetrics.edgeRailHeight, MBMetrics.settingsHeight))
        case .taskDetail:
            requested = CGSize(width: MBMetrics.edgeRailWidth + MBMetrics.panelGap + MBMetrics.taskDetailWidth,
                               height: max(MBMetrics.edgeRailHeight, MBMetrics.taskDetailHeight))
        }
        let availableWidth = max(1, visibleFrame.width - min(outerInset * 2, max(0, visibleFrame.width - 1)))
        let availableHeight = max(1, visibleFrame.height - min(outerInset * 2, max(0, visibleFrame.height - 1)))
        return CGSize(width: min(requested.width, availableWidth), height: min(requested.height, availableHeight))
    }

    static func frame(visibleFrame: CGRect, layer: FloatingLayer, normalizedFromTop: CGFloat,
                      taskCount: Int = 3) -> CGRect {
        let size = size(for: layer, visibleFrame: visibleFrame, taskCount: taskCount)
        let normalized = min(1, max(0, normalizedFromTop))
        // Reserve vertical room for the deepest panel before opening anything.
        // Thus neither a taller panel nor a new task row can shift the rail.
        let maximumHeight = EdgeLayout.size(for: .taskDetail("anchor"), visibleFrame: visibleFrame).height
        let railCenter = min(visibleFrame.maxY - maximumHeight / 2 - outerInset,
                             max(visibleFrame.minY + maximumHeight / 2 + outerInset,
                                 visibleFrame.maxY - visibleFrame.height * normalized - railLogoOffset))
        let centerY = railCenter + (layer == .idle ? railLogoOffset : 0)
        let verticalInset = min(outerInset, max(0, (visibleFrame.height - size.height) / 2))
        let minimumY = visibleFrame.minY + verticalInset
        let maximumY = visibleFrame.maxY - size.height - verticalInset
        let y = min(maximumY, max(minimumY, centerY - size.height / 2))
        return CGRect(x: visibleFrame.maxX - size.width, y: y, width: size.width, height: size.height)
    }

    // The logo never moves while the compact five-target rail opens around it.
    static let railLogoOffset: CGFloat = 69
    static let logoInset: CGFloat = 15

    static func isContained(_ frame: CGRect, in visibleFrame: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        frame.minX >= visibleFrame.minX - tolerance && frame.maxX <= visibleFrame.maxX + tolerance
            && frame.minY >= visibleFrame.minY - tolerance && frame.maxY <= visibleFrame.maxY + tolerance
    }
}

/// Only visible surfaces participate in hover; transparent canvas corners do not.
/// The logo and panel use the same coordinates as FloatingTabView, including
/// the retained canvas while a close transition completes.
struct FloatingHitRegion: Shape {
    let logoY: CGFloat
    var expansion: CGFloat
    let panelSize: CGSize

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let rail = CGRect(x: rect.maxX - MBMetrics.edgeRailWidth,
                          y: rect.minY + logoY + EdgeLayout.railLogoOffset - MBMetrics.edgeRailHeight / 2,
                          width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight)
        var path = AnchoredOrganicEdgeShape(expansion: expansion).path(in: rail)
        if panelSize.width > 0, panelSize.height > 0 {
            let panel = CGRect(x: rect.maxX - MBMetrics.edgeRailWidth - panelSize.width,
                               y: rect.midY - panelSize.height / 2,
                               width: panelSize.width, height: panelSize.height)
            path.addRoundedRect(in: panel, cornerSize: CGSize(width: MBMetrics.panelRadius, height: MBMetrics.panelRadius))
        }
        return path
    }
}

enum ObserverAppearance: String, CaseIterable {
    case system, light, dark
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
    var nativeAppearance: NSAppearance? {
        self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

@MainActor
final class ObserverPreferences: ObservableObject {
    private enum Key {
        static let showMenuBar = "ui.showMenuBar"
        static let showFloatingTab = "ui.showFloatingTab"
        static let showTaskCount = "ui.showTaskCount"
        static let reduceMotion = "ui.reduceMacBridgeMotion"
        static let showInFullscreen = "ui.showInFullscreen"
        static let followSystemAppearance = "ui.followSystemAppearance"
        static let appearance = "ui.appearance"
        static let reduceTransparency = "ui.reduceTransparency"
        static let glassOpacity = "ui.floatingTabGlassOpacity"
        static let hoverPreviews = "ui.hoverPreviews"
        static let pinOnClick = "ui.pinOnClick"
        static let verticalAnchors = "ui.floatingTabNormalizedYByDisplay"
    }

    private let defaults: UserDefaults
    @Published var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: Key.showMenuBar) } }
    @Published var showFloatingTab: Bool { didSet { defaults.set(showFloatingTab, forKey: Key.showFloatingTab) } }
    @Published var showTaskCount: Bool { didSet { defaults.set(showTaskCount, forKey: Key.showTaskCount) } }
    @Published var reduceMacBridgeMotion: Bool { didSet { defaults.set(reduceMacBridgeMotion, forKey: Key.reduceMotion) } }
    @Published var showInFullscreen: Bool { didSet { defaults.set(showInFullscreen, forKey: Key.showInFullscreen) } }
    @Published var appearance: ObserverAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    @Published var reduceTransparency: Bool { didSet { defaults.set(reduceTransparency, forKey: Key.reduceTransparency) } }
    @Published var glassOpacity: Double {
        didSet {
            let clamped = Self.clampedGlassOpacity(glassOpacity)
            if glassOpacity != clamped {
                glassOpacity = clamped
                return
            }
            defaults.set(glassOpacity, forKey: Key.glassOpacity)
        }
    }
    @Published var hoverPreviews: Bool { didSet { defaults.set(hoverPreviews, forKey: Key.hoverPreviews) } }
    @Published var pinOnClick: Bool { didSet { defaults.set(pinOnClick, forKey: Key.pinOnClick) } }
    var followSystemAppearance: Bool {
        get { appearance == .system }
        set { appearance = newValue ? .system : .dark }
    }
    @Published private(set) var verticalAnchors: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        let storedMenuBar = value(Key.showMenuBar, default: true)
        let storedFloatingTab = value(Key.showFloatingTab, default: true)
        if !storedMenuBar && !storedFloatingTab {
            showMenuBar = true
            showFloatingTab = false
            defaults.set(true, forKey: Key.showMenuBar)
        } else {
            showMenuBar = storedMenuBar
            showFloatingTab = storedFloatingTab
        }
        showTaskCount = value(Key.showTaskCount, default: true)
        reduceMacBridgeMotion = value(Key.reduceMotion, default: false)
        showInFullscreen = value(Key.showInFullscreen, default: false)
        appearance = defaults.string(forKey: Key.appearance).flatMap(ObserverAppearance.init(rawValue:))
            ?? (value(Key.followSystemAppearance, default: true) ? .system : .dark)
        reduceTransparency = value(Key.reduceTransparency, default: false)
        glassOpacity = Self.clampedGlassOpacity(defaults.object(forKey: Key.glassOpacity) == nil
            ? Self.defaultGlassOpacity : defaults.double(forKey: Key.glassOpacity))
        hoverPreviews = value(Key.hoverPreviews, default: true)
        pinOnClick = value(Key.pinOnClick, default: true)
        verticalAnchors = defaults.dictionary(forKey: Key.verticalAnchors) as? [String: Double] ?? [:]
    }

    func normalizedY(for displayID: String) -> CGFloat {
        CGFloat(min(0.86, max(0.14, verticalAnchors[displayID] ?? 0.40)))
    }

    static let glassOpacityRange: ClosedRange<Double> = 0.35...1.0
    static let defaultGlassOpacity = 0.55

    private static func clampedGlassOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultGlassOpacity }
        return min(glassOpacityRange.upperBound, max(glassOpacityRange.lowerBound, value))
    }

    func setNormalizedY(_ value: CGFloat, for displayID: String) {
        verticalAnchors[displayID] = Double(min(0.86, max(0.14, value)))
        if verticalAnchors.count > 16 {
            for key in verticalAnchors.keys.sorted().prefix(verticalAnchors.count - 16) {
                verticalAnchors.removeValue(forKey: key)
            }
        }
        defaults.set(verticalAnchors, forKey: Key.verticalAnchors)
    }

    func hideFloatingTab() {
        // Always leave a visible way back, even when the user hid the menu bar.
        if !showMenuBar { showMenuBar = true }
        showFloatingTab = false
    }
}

/// Bounded IDs only: live payloads are never frozen or retained a second time.
struct CompactReadingOrder {
    static let capacity = 64
    private(set) var ids: [String] = []
    private var knownIDs = Set<String>()
    mutating func capture(_ tasks: [CompactTaskPresentation]) {
        ids = Array(tasks.prefix(Self.capacity).map(\.id))
        knownIDs = Set(tasks.prefix(512).map(\.id))
    }
    func pendingCount(_ tasks: [CompactTaskPresentation]) -> Int { tasks.prefix(512).filter { !knownIDs.contains($0.id) }.count }
    func rows(_ tasks: [CompactTaskPresentation]) -> [CompactTaskPresentation] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}

/// A constant canvas lets the silhouette morph without moving the logo or hit targets.
struct AnchoredOrganicEdgeShape: Shape {
    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }
    func path(in rect: CGRect) -> Path {
        // Keep the spring's small settle instead of clipping every value above
        // one into a hard stop. AppKit's rail canvas reserves room for this.
        let t = min(1.04, max(0, expansion))
        let width = MBMetrics.edgeIdleWidth + (MBMetrics.edgeRailWidth - MBMetrics.edgeIdleWidth) * t
        let height = MBMetrics.edgeIdleHeight + (MBMetrics.edgeRailHeight - MBMetrics.edgeIdleHeight) * t
        let logoY = rect.midY - EdgeLayout.railLogoOffset
        let top = logoY - MBMetrics.edgeIdleHeight / 2 * (1 - t) - (MBMetrics.edgeRailHeight / 2 - EdgeLayout.railLogoOffset) * t
        return OrganicEdgeShape(expansion: t).path(in: CGRect(x: 0, y: 0, width: width, height: height))
            .applying(CGAffineTransform(translationX: rect.maxX - width, y: top))
    }
}

struct OrganicEdgeShape: Shape {
    var expansion: CGFloat
    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let amount = min(1, max(0, expansion))
        // Idle is a shallow logo handle. Hover grows inward into a slim rail
        // with a long straight reading edge, matching the approved Concept 7
        // instead of producing a large semicircular bulge.
        let inner: CGFloat = 0
        // The rail grows below the fixed brand target. Scaling the shoulder
        // with the whole rail height cuts into that target when expanded.
        let upperShoulder = min(h * (0.28 - 0.08 * amount), MBMetrics.edgeIdleHeight * 0.28)
        let lowerShoulder = h - upperShoulder
        var path = Path()
        path.move(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addCurve(to: CGPoint(x: inner, y: lowerShoulder),
                      control1: CGPoint(x: w, y: h - upperShoulder * 0.75),
                      control2: CGPoint(x: inner, y: h - upperShoulder * 0.25))
        path.addLine(to: CGPoint(x: inner, y: upperShoulder))
        path.addCurve(to: CGPoint(x: w, y: 0),
                      control1: CGPoint(x: inner, y: upperShoulder * 0.25),
                      control2: CGPoint(x: w, y: upperShoulder * 0.75))
        path.closeSubpath()
        return path
    }
}

enum MacBridgeMarkRenderer {
    enum Style: Hashable { case appIcon, monochrome }
    private struct CacheKey: Hashable { let size: CGFloat; let style: Style }
    // Keep the original pixel representations. Cache only the finite UI sizes;
    // a new model publication must not allocate another logo image each time.
    @MainActor private static var images: [CacheKey: NSImage] = [:]
    private static let cachedSizes: Set<CGFloat> = [18, 22, 24, 26, 28, 32, 40, 48, 64, 96]
    private static let canonicalImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MacBridge", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    @MainActor static func image(size: CGFloat, style: Style = .appIcon) -> NSImage {
        let key = CacheKey(size: size, style: style)
        if let image = images[key] { return image }
        let image = makeImage(size: size, style: style)
        if cachedSizes.contains(size) { images[key] = image }
        return image
    }

    private static func makeImage(size: CGFloat, style: Style) -> NSImage {
        if style == .appIcon, let exact = canonicalImage?.copy() as? NSImage {
            exact.size = CGSize(width: size, height: size)
            exact.isTemplate = false
            return exact
        }
        // Reuse the native ribbon for template chrome, without the blue bitmap
        // tile. Template rendering adapts to the system appearance and scale;
        // the full-color user artwork remains the Dock/Finder app icon.
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            let w = rect.width, h = rect.height
            let ribbon = NSBezierPath()
            ribbon.move(to: CGPoint(x: 0.08 * w, y: 0.22 * h))
            ribbon.curve(to: CGPoint(x: 0.39 * w, y: 0.72 * h),
                         controlPoint1: CGPoint(x: 0.15 * w, y: 0.54 * h), controlPoint2: CGPoint(x: 0.25 * w, y: 0.80 * h))
            ribbon.curve(to: CGPoint(x: 0.61 * w, y: 0.49 * h),
                         controlPoint1: CGPoint(x: 0.48 * w, y: 0.68 * h), controlPoint2: CGPoint(x: 0.53 * w, y: 0.49 * h))
            ribbon.curve(to: CGPoint(x: 0.86 * w, y: 0.64 * h),
                         controlPoint1: CGPoint(x: 0.71 * w, y: 0.46 * h), controlPoint2: CGPoint(x: 0.77 * w, y: 0.68 * h))
            ribbon.line(to: CGPoint(x: 0.94 * w, y: 0.22 * h))
            ribbon.curve(to: CGPoint(x: 0.63 * w, y: 0.33 * h),
                         controlPoint1: CGPoint(x: 0.85 * w, y: 0.48 * h), controlPoint2: CGPoint(x: 0.76 * w, y: 0.30 * h))
            ribbon.curve(to: CGPoint(x: 0.37 * w, y: 0.54 * h),
                         controlPoint1: CGPoint(x: 0.54 * w, y: 0.34 * h), controlPoint2: CGPoint(x: 0.48 * w, y: 0.56 * h))
            ribbon.curve(to: CGPoint(x: 0.08 * w, y: 0.22 * h),
                         controlPoint1: CGPoint(x: 0.28 * w, y: 0.58 * h), controlPoint2: CGPoint(x: 0.17 * w, y: 0.31 * h))
            ribbon.close()
            if style == .monochrome {
                // Rounded ribbon silhouette, including both substantial feet;
                // keep the app artwork's shape at small sizes, not its tile.
                ribbon.removeAllPoints()
                ribbon.move(to: CGPoint(x: 0.05 * w, y: 0.22 * h))
                ribbon.curve(to: CGPoint(x: 0.35 * w, y: 0.80 * h),
                             controlPoint1: CGPoint(x: 0.12 * w, y: 0.46 * h), controlPoint2: CGPoint(x: 0.20 * w, y: 0.78 * h))
                ribbon.curve(to: CGPoint(x: 0.60 * w, y: 0.58 * h),
                             controlPoint1: CGPoint(x: 0.47 * w, y: 0.82 * h), controlPoint2: CGPoint(x: 0.50 * w, y: 0.58 * h))
                ribbon.curve(to: CGPoint(x: 0.78 * w, y: 0.64 * h),
                             controlPoint1: CGPoint(x: 0.70 * w, y: 0.58 * h), controlPoint2: CGPoint(x: 0.72 * w, y: 0.71 * h))
                ribbon.curve(to: CGPoint(x: 0.95 * w, y: 0.22 * h),
                             controlPoint1: CGPoint(x: 0.82 * w, y: 0.56 * h), controlPoint2: CGPoint(x: 0.90 * w, y: 0.32 * h))
                ribbon.curve(to: CGPoint(x: 0.928 * w, y: 0.17 * h),
                             controlPoint1: CGPoint(x: 0.965 * w, y: 0.19 * h), controlPoint2: CGPoint(x: 0.953 * w, y: 0.17 * h))
                ribbon.line(to: CGPoint(x: 0.772 * w, y: 0.175 * h))
                ribbon.curve(to: CGPoint(x: 0.697 * w, y: 0.24 * h),
                             controlPoint1: CGPoint(x: 0.737 * w, y: 0.175 * h), controlPoint2: CGPoint(x: 0.716 * w, y: 0.19 * h))
                ribbon.curve(to: CGPoint(x: 0.51 * w, y: 0.555 * h),
                             controlPoint1: CGPoint(x: 0.641 * w, y: 0.34 * h), controlPoint2: CGPoint(x: 0.62 * w, y: 0.48 * h))
                ribbon.curve(to: CGPoint(x: 0.287 * w, y: 0.216 * h),
                             controlPoint1: CGPoint(x: 0.428 * w, y: 0.61 * h), controlPoint2: CGPoint(x: 0.352 * w, y: 0.405 * h))
                ribbon.curve(to: CGPoint(x: 0.227 * w, y: 0.17 * h),
                             controlPoint1: CGPoint(x: 0.274 * w, y: 0.178 * h), controlPoint2: CGPoint(x: 0.258 * w, y: 0.17 * h))
                ribbon.line(to: CGPoint(x: 0.073 * w, y: 0.17 * h))
                ribbon.curve(to: CGPoint(x: 0.05 * w, y: 0.22 * h),
                             controlPoint1: CGPoint(x: 0.048 * w, y: 0.17 * h), controlPoint2: CGPoint(x: 0.039 * w, y: 0.19 * h))
                ribbon.close()
                NSColor.black.setFill()
                ribbon.fill()
            } else {
                NSGradient(colors: [MBPalette.nsCyan, MBPalette.nsBrandBlue, MBPalette.nsElectricBlue])?
                    .draw(in: ribbon, angle: -24)
            }

            let stem = NSBezierPath()
            stem.move(to: CGPoint(x: 0.50 * w, y: 0.19 * h))
            stem.line(to: CGPoint(x: 0.50 * w, y: 0.52 * h))
            stem.lineWidth = max(0.8, size * 0.035)
            (style == .monochrome ? NSColor.black : MBPalette.nsCyan.withAlphaComponent(0.75)).setStroke()
            stem.stroke()
            return true
        }
        image.isTemplate = style == .monochrome
        return image
    }
}

private struct MBBrandImageKey: EnvironmentKey {
    static var defaultValue: NSImage? { nil }
}

extension EnvironmentValues {
    var mbBrandImage: NSImage? {
        get { self[MBBrandImageKey.self] }
        set { self[MBBrandImageKey.self] = newValue }
    }
}

struct MacBridgeMark: View {
    let size: CGFloat
    var style: MacBridgeMarkRenderer.Style = .appIcon
    @Environment(\.mbBrandImage) private var previewImage
    var body: some View {
        Image(nsImage: style == .appIcon ? previewImage ?? MacBridgeMarkRenderer.image(size: size)
              : MacBridgeMarkRenderer.image(size: size, style: style))
            .renderingMode(style == .monochrome ? .template : .original)
            .resizable().interpolation(.high).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
