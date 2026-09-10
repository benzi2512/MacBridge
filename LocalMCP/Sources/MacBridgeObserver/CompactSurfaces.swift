import AppKit
import Combine
import SwiftUI

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let elevated: Bool
    let borderOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.mbReduceTransparency) private var appReduceTransparency
    @Environment(\.mbGlassOpacity) private var requestedGlassOpacity
    @Environment(\.colorSchemeContrast) private var contrast

    @Environment(\.colorScheme) private var scheme

    private var glassOpacity: Double { min(1, max(0.35, requestedGlassOpacity)) }
    private var rimScale: Double { contrast == .increased ? 1 : 0.45 + glassOpacity * 0.55 }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || appReduceTransparency {
            content.background(shape.fill(scheme == .dark ? MBPalette.deepNavy : Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 1))
                .clipShape(shape)
        } else if #available(macOS 26.0, *) {
            // System tint is adaptive, so it cannot own the brand's tonal floor.
            // Keep native glass underneath a translucent wash and all labels above
            // both layers. The wash never becomes opaque or dims the foreground.
            content.background {
                ZStack {
                    Color.clear.glassEffect(.regular.tint(scheme == .dark
                        ? MBPalette.brandBlue.opacity(0.12 * glassOpacity)
                        : MBPalette.brandBlue.opacity(0.04 * glassOpacity)), in: shape)
                        .opacity(glassOpacity)
                    shape.fill(GlassColorTreatment(scheme: scheme, elevated: elevated,
                                                   strength: glassOpacity).gradient)
                }.allowsHitTesting(false)
            }
                .overlay(shape.stroke(LinearGradient(colors: [
                    scheme == .dark ? MBPalette.cyanHighlight.opacity(0.50 * rimScale) : Color.white.opacity(0.8 * rimScale),
                    MBPalette.cyanHighlight.opacity((contrast == .increased ? 0.7 : 0.18) * rimScale),
                    MBPalette.brandBlue.opacity(0.38 * rimScale)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1.5 : 0.75))
                .shadow(color: MBPalette.deepNavy.opacity((elevated ? 0.24 : 0.12) * glassOpacity),
                        radius: elevated ? 14 : 5, y: 4)
        } else {
            content.background {
                shape.fill(GlassColorTreatment(scheme: scheme, elevated: elevated,
                                               strength: glassOpacity).gradient)
                    .background(shape.fill(.ultraThinMaterial).opacity(glassOpacity))
                    .allowsHitTesting(false)
            }
                .overlay(shape.stroke(MBPalette.cyanHighlight.opacity(min(borderOpacity, 0.16) * rimScale), lineWidth: 0.5))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.12 * glassOpacity), radius: elevated ? 14 : 8, y: 3)
        }
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, elevated: Bool = false, borderOpacity: Double = 0.20) -> some View {
        modifier(GlassSurface(shape: shape, elevated: elevated, borderOpacity: borderOpacity))
    }
}

@MainActor
final class FloatingTabController: ObservableObject {
    @Published private(set) var machine = FloatingInteractionStateMachine()
    @Published private(set) var pointerInside = false
    @Published private(set) var windowLayer: FloatingLayer = .idle
    @Published private(set) var readingOrder = CompactReadingOrder()

    let model: ObserverModel
    let preferences: ObserverPreferences
    private let openDashboardAction: (String?) -> Void
    private let openSettingsAction: () -> Void
    private let presentsWindow: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var previewLayer: FloatingLayer?
    private var anchoredScreen: NSScreen?
    private var readingOwner: String?
    private var edgePanel: EdgeHandlePanel?
    private var panel: EdgeHandlePanel {
        if let edgePanel { return edgePanel }
        let created = makePanel()
        edgePanel = created
        return created
    }

    var layer: FloatingLayer { machine.layer }
    var pendingTransitionCount: Int { (hoverOpenTask == nil ? 0 : 1) + (hoverCloseTask == nil ? 0 : 1) + (previewTask == nil ? 0 : 1) + (shrinkTask == nil ? 0 : 1) }
    var hasCreatedPanel: Bool { edgePanel != nil }
    var currentSummary: CompactSummary { model.compactSummary }
    var currentScreen: NSScreen? {
        if let anchoredScreen, let screen = NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == anchoredScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
    var displayID: String {
        guard let screen = currentScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return "main" }
        return String(number.uint32Value)
    }

    init(model: ObserverModel, preferences: ObserverPreferences,
         presentsWindow: Bool = true,
         openDashboard: @escaping (String?) -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.presentsWindow = presentsWindow
        self.openDashboardAction = openDashboard
        self.openSettingsAction = openSettings
        self.anchoredScreen = NSScreen.main ?? NSScreen.screens.first
        self.readingOwner = model.owner
        model.$owner.compactMap { $0 }.sink { [weak self] owner in
            guard let self, self.readingOwner != owner else { return }
            self.readingOwner = owner
            self.readingOrder.capture(self.currentSummary.tasks)
            if case .taskDetail = self.layer {
                self.show(.recentTasks, locked: self.machine.locked)
            } else if self.layer == .recentTasks {
                self.reposition(animated: false)
            }
        }.store(in: &subscriptions)
        // FloatingTabView already observes the model. Do not forward every
        // publication a second time or relayout a viewport whose IDs are held.
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send()
                self.applyPreferences()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reposition(animated: false) }
            .store(in: &subscriptions)
    }

    deinit {
        hoverOpenTask?.cancel(); hoverCloseTask?.cancel(); previewTask?.cancel(); shrinkTask?.cancel()
    }

    func start() {
        applyPreferences()
    }

    func stop() {
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        hoverCloseTask?.cancel(); hoverCloseTask = nil
        cancelPreview()
        shrinkTask?.cancel(); shrinkTask = nil
        if presentsWindow { edgePanel?.orderOut(nil) }
    }

    func pointerChanged(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        if inside {
            hoverCloseTask?.cancel(); hoverCloseTask = nil
            guard layer == .idle else { return }
            hoverOpenTask?.cancel()
            hoverOpenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(MBMetrics.hoverDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.hoverOpenTask = nil
                var next = self.machine
                next.hoverDelayElapsed(pointerInside: self.pointerInside)
                self.setMachine(next)
            }
        } else {
            cancelPreview()
            hoverOpenTask?.cancel(); hoverOpenTask = nil
            guard !machine.locked else { return }
            hoverCloseTask?.cancel()
            hoverCloseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(MBMetrics.hoverExitGrace * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.hoverCloseTask = nil
                var next = self.machine
                next.exitGraceElapsed(pointerInside: self.pointerInside)
                self.setMachine(next)
            }
        }
    }

    func show(_ nextLayer: FloatingLayer, locked: Bool = true) {
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        hoverCloseTask?.cancel(); hoverCloseTask = nil
        cancelPreview()
        var next = machine
        next.select(nextLayer, locked: locked)
        setMachine(next)
        if presentsWindow, preferences.showFloatingTab { panel.orderFrontRegardless() }
    }

    private func cancelPreview() {
        previewTask?.cancel(); previewTask = nil
        previewLayer = nil
    }

    func preview(_ target: FloatingLayer, inside: Bool) {
        guard inside else {
            if previewLayer == target { cancelPreview() }
            return
        }
        guard preferences.hoverPreviews, !machine.locked, layer.isExpanded, layer != target else { return }
        cancelPreview()
        previewLayer = target
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MBMetrics.hoverDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.previewLayer == target else { return }
            self.previewTask = nil
            self.previewLayer = nil
            guard self.preferences.hoverPreviews, !self.machine.locked else { return }
            self.show(target, locked: false)
        }
    }

    func activate(_ target: FloatingLayer) {
        // Clicking a hover preview pins it; only a second deliberate click closes it.
        show(layer == target && machine.locked ? .rail : target, locked: preferences.pinOnClick)
    }

    func togglePin() {
        guard layer.hasPanel else { return }
        show(layer, locked: !machine.locked)
    }

    func showLatest() {
        readingOrder.capture(currentSummary.tasks)
        if layer == .recentTasks { reposition(animated: false) }
    }

    func openTask(_ task: CompactTaskPresentation) {
        model.selection = task.selectionID
        show(.taskDetail(task.id))
    }

    func openDashboard(selection: String? = nil) {
        openDashboardAction(selection)
    }

    func openSettings() {
        openSettingsAction()
    }

    func hideWidget() {
        stop()
        preferences.hideFloatingTab()
        machine = FloatingInteractionStateMachine()
        windowLayer = .idle
        pointerInside = false
        readingOrder = CompactReadingOrder()
    }

    func chooseConnection() {
        NSApp.activate(ignoringOtherApps: true)
        model.chooseOwner()
    }

    func refreshConnection() {
        model.reconnect()
    }

    func closeDeepest() {
        cancelPreview()
        var next = machine
        next.closeDeepest()
        setMachine(next)
    }

    func setVerticalAnchor(_ value: CGFloat) {
        preferences.setNormalizedY(value, for: displayID)
        reposition(animated: false)
    }

    private func setMachine(_ next: FloatingInteractionStateMachine) {
        guard machine != next else { return }
        if next.layer == .recentTasks, machine.layer != .recentTasks {
            if case .taskDetail = machine.layer { /* Returning preserves the reading order. */ }
            else { showLatest() }
        }
        shrinkTask?.cancel(); shrinkTask = nil
        let closing = next.layer == .idle && windowLayer != .idle
        let visibleFrame = currentScreen?.visibleFrame ?? .infinite
        let currentWindowSize = EdgeLayout.size(for: windowLayer, visibleFrame: visibleFrame,
                                                taskCount: readingOrder.ids.count)
        let nextWindowSize = EdgeLayout.size(for: next.layer, visibleFrame: visibleFrame,
                                             taskCount: readingOrder.ids.count)
        // Compare full canvas dimensions so no leaving panel gets clipped.
        let shrinkingPanelCanvas = windowLayer.hasPanel &&
            (nextWindowSize.width < currentWindowSize.width || nextWindowSize.height < currentWindowSize.height)
        machine = next
        if closing || shrinkingPanelCanvas {
            // Keep the canvas until the visible content closes. Reopening
            // cancels this shrink; the hosting window itself never animates.
            let reduced = preferences.reduceMacBridgeMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let duration = closing ? FloatingMotion.duration(expanded: false, reduced: reduced)
                : FloatingMotion.panelDuration(reduced: reduced)
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled, let self, self.layer == next.layer else { return }
                self.windowLayer = next.layer
                self.reposition(animated: false)
                self.shrinkTask = nil
            }
        } else {
            windowLayer = next.layer
            reposition(animated: false)
        }
    }

    private func applyPreferences() {
        guard presentsWindow else { return }
        guard preferences.showFloatingTab else {
            stop()
            if machine != FloatingInteractionStateMachine() { machine = FloatingInteractionStateMachine() }
            if windowLayer != .idle { windowLayer = .idle }
            if pointerInside { pointerInside = false }
            if !readingOrder.ids.isEmpty { readingOrder = CompactReadingOrder() }
            return
        }
        panel.collectionBehavior = preferences.showInFullscreen
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.canJoinAllSpaces, .stationary]
        panel.appearance = preferences.appearance.nativeAppearance
        reposition(animated: false)
        panel.orderFrontRegardless()
    }

    private func reposition(animated: Bool) {
        guard presentsWindow, preferences.showFloatingTab else { return }
        guard let screen = currentScreen else { return }
        let frame = EdgeLayout.frame(visibleFrame: screen.visibleFrame, layer: windowLayer,
                                     normalizedFromTop: preferences.normalizedY(for: displayID),
                                     taskCount: readingOrder.ids.count)
        // Window geometry must be atomic: animating the hosting window and its
        // SwiftUI layout together moves tracking regions under a stationary mouse.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> EdgeHandlePanel {
        let panel = EdgeHandlePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.appearance = preferences.appearance.nativeAppearance
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.escapeAction = { [weak self] in self?.closeDeepest() }
        panel.contentView = NSHostingView(rootView: FloatingTabView(controller: self))
        panel.setAccessibilityLabel("MacBridge floating task tab")
        return panel
    }
}

private final class EdgeHandlePanel: NSPanel {
    var escapeAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escapeAction?() }
}

private enum RailAction: String, CaseIterable {
    case connection, recentTasks, settings, hide
    var label: String {
        switch self {
        case .connection: return "Connection"
        case .recentTasks: return "Recent Tasks"
        case .settings: return "Settings"
        case .hide: return "Hide widget — restore from the menu bar"
        }
    }
    var icon: String {
        switch self {
        case .connection: return "arrow.clockwise"
        case .recentTasks: return "clock"
        case .settings: return "gearshape"
        case .hide: return "xmark"
        }
    }
}

struct FloatingTabView: View {
    @ObservedObject var controller: FloatingTabController
    @ObservedObject private var model: ObserverModel
    @ObservedObject private var preferences: ObserverPreferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var expansion: CGFloat = 0

    init(controller: FloatingTabController) {
        self.controller = controller
        model = controller.model
        preferences = controller.preferences
    }

    private var summary: CompactSummary { model.compactSummary }
    private var displayedTasks: [CompactTaskPresentation] { controller.readingOrder.rows(summary.tasks) }
    var body: some View {
        GeometryReader { geometry in
            let logoY = geometry.size.height / 2 - (controller.windowLayer == .idle ? 0 : EdgeLayout.railLogoOffset)
            ZStack(alignment: .topLeading) {
                edgeHandle
                    .position(x: geometry.size.width - MBMetrics.edgeRailWidth / 2,
                              y: logoY + EdgeLayout.railLogoOffset)
                logoButton.position(x: geometry.size.width - EdgeLayout.logoInset, y: logoY)
                ZStack(alignment: .trailing) {
                    if controller.layer.hasPanel {
                        compactPanel.id(controller.layer)
                            .transition(reducedMotion ? .opacity : .opacity.combined(with: .offset(x: 12)))
                    }
                }
                .animation(.timingCurve(0.22, 1, 0.36, 1,
                    duration: FloatingMotion.panelDuration(reduced: reducedMotion)), value: controller.layer)
                .frame(width: canvasPanelSize.width, height: canvasPanelSize.height, alignment: .trailing)
                .position(x: max(canvasPanelSize.width / 2, geometry.size.width - MBMetrics.edgeRailWidth - canvasPanelSize.width / 2),
                          y: geometry.size.height / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(FloatingHitRegion(logoY: logoY,
                expansion: reducedMotion ? (controller.windowLayer.isExpanded ? 1 : 0) : expansion,
                panelSize: canvasPanelSize))
            .onHover(perform: controller.pointerChanged)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onExitCommand(perform: controller.closeDeepest)
        .preferredColorScheme(preferences.appearance.colorScheme)
        // The nonactivating observer stays usable while another app owns focus.
        // Keep native control/glass appearance active without activating NSApp.
        .environment(\.appearsActive, true)
        .environment(\.mbReduceTransparency, systemReduceTransparency || preferences.reduceTransparency)
        .environment(\.mbGlassOpacity, preferences.glassOpacity)
        .onAppear { expansion = controller.layer.isExpanded ? 1 : 0 }
        .onChange(of: controller.layer.isExpanded) { expanded in
            let reduced = systemReduceMotion || preferences.reduceMacBridgeMotion
            withAnimation(reduced ? nil : .timingCurve(0.22, 1, 0.36, 1,
                duration: FloatingMotion.duration(expanded: expanded, reduced: reduced))) {
                expansion = expanded ? 1 : 0
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacBridge. \(summary.statusText).")
    }

    @ViewBuilder private var compactPanel: some View {
        Group {
            switch controller.layer {
            case .recentTasks: recentTasksPanel
            case .settings: settingsPanel
            case .taskDetail(let id): taskDetailPanel(id: id)
            case .idle, .rail: EmptyView()
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .foregroundStyle(MBPalette.textPrimary)
        .glassSurface(RoundedRectangle(cornerRadius: MBMetrics.panelRadius, style: .continuous),
                      elevated: true, borderOpacity: 0.24)
    }

    private var panelSize: CGSize {
        EdgeLayout.panelSize(for: controller.layer, taskCount: controller.readingOrder.ids.count)
    }

    private var canvasPanelSize: CGSize {
        EdgeLayout.panelSize(for: controller.windowLayer, taskCount: controller.readingOrder.ids.count)
    }

    private var reducedMotion: Bool { systemReduceMotion || preferences.reduceMacBridgeMotion }

    private var edgeHandle: some View {
        Group {
            if reducedMotion {
                ZStack {
                    handleContent
                        .glassSurface(AnchoredOrganicEdgeShape(expansion: controller.layer.isExpanded ? 1 : 0), borderOpacity: 0.16)
                        .id(controller.layer.isExpanded)
                        .transition(.opacity)
                }
                .animation(.easeOut(duration: MBMetrics.reducedMotionDuration), value: controller.layer.isExpanded)
            } else {
                handleContent.glassSurface(AnchoredOrganicEdgeShape(expansion: expansion), borderOpacity: 0.16)
            }
        }
        .accessibilityIdentifier("floating-edge-handle")
    }

    private var handleContent: some View {
        ZStack {
            Color.clear
            railContent.opacity(controller.layer.isExpanded ? 1 : 0)
                .animation(.easeOut(duration: systemReduceMotion || preferences.reduceMacBridgeMotion
                    ? MBMetrics.reducedMotionDuration : MBMetrics.openDuration), value: controller.layer.isExpanded)
                .allowsHitTesting(controller.layer.isExpanded)
                .accessibilityHidden(!controller.layer.isExpanded)
        }
        .frame(width: MBMetrics.edgeRailWidth, height: MBMetrics.edgeRailHeight)
    }

    private var logoButton: some View {
        Button {
            controller.openDashboard()
        } label: {
            CompactBrandBadge(summary: summary, showCount: preferences.showTaskCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open MacBridge Dashboard")
        .help(summary.runningBadgeHelp)
    }

    private var railContent: some View {
        VStack(spacing: MBMetrics.edgeRailSpacing) {
            Color.clear.frame(width: MBMetrics.edgeTargetSize, height: MBMetrics.edgeTargetSize).allowsHitTesting(false)
            ForEach(RailAction.allCases, id: \.self) { action in
                Button { perform(action) } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: action == .hide ? 10 : 15, weight: .regular))
                        .frame(width: MBMetrics.edgeTargetSize, height: MBMetrics.edgeTargetSize)
                }
                .buttonStyle(RailButtonStyle(selected: selected(action)))
                .accessibilityLabel(action.label)
                .onHover { inside in
                    if action == .recentTasks { controller.preview(.recentTasks, inside: inside) }
                }
            }
        }
        .foregroundStyle(MBPalette.textPrimary.opacity(0.88))
        .offset(x: MBMetrics.edgeRailWidth / 2 - EdgeLayout.logoInset)
    }

    private func selected(_ action: RailAction) -> Bool {
        switch (action, controller.layer) {
        case (.recentTasks, .recentTasks), (.settings, .settings), (.recentTasks, .taskDetail): return true
        default: return false
        }
    }

    private func perform(_ action: RailAction) {
        switch action {
        case .connection:
            if model.directory.isEmpty { controller.chooseConnection() } else { controller.refreshConnection() }
        case .recentTasks: controller.activate(.recentTasks)
        case .settings: controller.activate(.settings)
        case .hide: controller.hideWidget()
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 9) {
            MacBridgeMark(size: 28, style: .monochrome)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacBridge").font(.system(size: 15, weight: .semibold))
                Text(panelStatusText).font(.system(size: 11)).foregroundStyle(MBPalette.textSecondary)
            }
            Spacer()
            Button(action: controller.togglePin) {
                Image(systemName: controller.machine.locked ? "pin.fill" : "pin").frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundStyle(controller.machine.locked ? MBPalette.brandBlue : MBPalette.textSecondary)
                .accessibilityLabel(controller.machine.locked ? "Unpin panel" : "Pin panel")
            Button(action: controller.closeDeepest) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(MBPalette.textSecondary).accessibilityLabel("Close panel")
        }
    }

    private var panelStatusText: String {
        if !summary.connected { return "Disconnected" }
        if summary.runningCount > 0 {
            return "\(summary.runningCount) \(summary.runningCount == 1 ? "task" : "tasks") running"
        }
        if summary.waitingCount > 0 {
            return "\(summary.waitingCount) awaiting next step"
        }
        return summary.busy ? "Updating" : "Idle"
    }

    private var recentTasksPanel: some View {
        let tasks = summary.tasks
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pendingCount = controller.readingOrder.pendingCount(tasks)
        return VStack(alignment: .leading, spacing: 10) {
            panelHeader
            Divider().overlay(MBPalette.textSecondary.opacity(0.14))
            if controller.readingOrder.ids.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock").foregroundStyle(MBPalette.idle)
                    Text("No recent tasks").font(.system(size: 13)).foregroundStyle(MBPalette.textSecondary)
                }.frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ScrollView {
                  LazyVStack(spacing: 0) {
                    ForEach(controller.readingOrder.ids, id: \.self) { id in
                      if let task = byID[id] {
                        Button { controller.openTask(task) } label: { CompactTaskRow(task: task, showsDivider: true) }
                            .buttonStyle(.plain)
                      } else {
                        Text("No longer retained").font(.caption).foregroundStyle(.secondary).frame(height: 48)
                      }
                    }
                  }
                }.accessibilityLabel("Recent tasks, scroll for more")
            }
            Spacer(minLength: 0)
            HStack {
              Text("\(controller.readingOrder.ids.count) retained tasks").font(.caption).foregroundStyle(MBPalette.textSecondary)
              Spacer(minLength: 0)
              if pendingCount > 0 {
                Button("\(pendingCount) new · Show updates", action: controller.showLatest).buttonStyle(.plain)
                    .font(.caption).foregroundStyle(MBPalette.brandBlue)
              }
            }
        }.padding(16)
    }

    private func taskDetailPanel(id: String) -> some View {
        let task = summary.tasks.first { $0.id == id }
        let work = model.allActivityFeed.groups.first { $0.id == id }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { controller.show(.recentTasks) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Back to recent tasks")
                Spacer()
                Button(action: controller.closeDeepest) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Close panel")
            }.foregroundStyle(MBPalette.textSecondary)
            if let task {
                HStack(spacing: 10) {
                    Circle().fill(task.status.color).frame(width: 8, height: 8)
                    Text(task.statusText).font(.system(size: 12, weight: .medium)).foregroundStyle(task.status.color)
                }.accessibilityElement(children: .combine)
                Text(task.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                taskField("Project", task.projectName)
                if let chat = work?.chatLabel { taskField("Chat label", chat + " · caller supplied") }
                taskField("Current activity", task.shortActivity)
                if let command = work?.currentAction?.commandPreview { taskField("Command", command) }
                if let target = work?.currentAction?.subject { taskField("Target", target) }
                if let work, !work.visibleChildren.isEmpty {
                    DisclosureGroup("Recent steps (\(work.visibleChildren.count))") {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(work.visibleChildren.prefix(6)) { item in
                                    Button { controller.openDashboard(selection: item.id) } label: {
                                        CompactActivityRow(content: CompactRowContent(item: item))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(maxHeight: 120)
                    }.font(.caption)
                }
                if let started = task.startedAt { taskField("Started", started.formatted(date: .abbreviated, time: .shortened)) }
                if let updated = task.updatedAt { taskField("Last update", updated.formatted(date: .omitted, time: .shortened)) }
                Spacer(minLength: 0)
                Button("Open receipts in Dashboard") { controller.openDashboard(selection: task.selectionID) }
                    .buttonStyle(.bordered).tint(MBPalette.brandBlue)
            } else {
                Text("Task is no longer retained").font(.headline)
                Text("Open Dashboard to refresh the bounded activity view.").foregroundStyle(MBPalette.textSecondary)
            }
        }.padding(16).foregroundStyle(MBPalette.textPrimary)
    }

    private func taskField(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(MBPalette.textSecondary).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 13)).foregroundStyle(MBPalette.textPrimary).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).help(value)
        }
    }

    private var settingsPanel: some View {
        CompactSettingsView(preferences: preferences, displayID: controller.displayID,
                            normalizedY: preferences.normalizedY(for: controller.displayID),
                            onAnchorChanged: controller.setVerticalAnchor,
                            onOpenFullSettings: controller.openSettings,
                            onClose: controller.closeDeepest)
            .padding(16)
    }
}

/// One narrow, transparent brand target in both idle and expanded states.
/// Count changes do not resize/move the window or add polling/animation work.
struct CompactBrandBadge: View {
    let summary: CompactSummary
    let showCount: Bool

    var body: some View {
        VStack(spacing: 2) {
            MacBridgeMark(size: MBMetrics.edgeLogoSize, style: .monochrome)
            if showCount {
                Text(summary.runningBadgeText)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 18, maxWidth: 26, minHeight: 12, maxHeight: 12)
                    .background(Color.primary.opacity(0.10), in: Capsule())
                    .accessibilityLabel(summary.runningBadgeHelp)
                    .accessibilityIdentifier("floating-running-count")
            }
        }
        .foregroundStyle(.primary)
        .frame(width: MBMetrics.edgeTargetSize, height: MBMetrics.edgeBrandHeight)
        .animation(nil, value: summary.runningBadgeText)
    }
}

enum FloatingMotion {
    static func duration(expanded: Bool, reduced: Bool) -> TimeInterval {
        reduced ? MBMetrics.reducedMotionDuration : expanded ? MBMetrics.openDuration : MBMetrics.closeDuration
    }
    static func panelDuration(reduced: Bool) -> TimeInterval {
        reduced ? MBMetrics.reducedMotionDuration : MBMetrics.panelDuration
    }
}

private struct RailButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? MBPalette.textPrimary : MBPalette.textSecondary)
            .background((selected ? MBPalette.brandBlue.opacity(0.22) : MBPalette.surfaceHover.opacity(configuration.isPressed ? 0.38 : 0)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? MBPalette.cyanHighlight.opacity(0.48) : .clear, lineWidth: 1))
    }
}

struct CompactTaskRow: View {
    let task: CompactTaskPresentation
    var showsDivider = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(MBPalette.textTertiary.opacity(0.22), lineWidth: 3)
                if let progress = task.progress {
                    Circle().trim(from: 0, to: min(1, max(0, progress))).stroke(task.status.color,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                } else {
                    Image(systemName: task.status == .running ? "play.fill" : task.status == .completed ? "checkmark" : "circle.fill")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(task.status.color)
                }
            }.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text([task.projectName, task.shortActivity].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(MBPalette.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(task.statusText).font(.system(size: 10, weight: .medium)).foregroundStyle(task.status.color).lineLimit(1)
        }
        .padding(.horizontal, 4).frame(height: 48)
        .help("\(task.title)\n\(task.projectName)\n\(task.shortActivity)")
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(MBPalette.textSecondary.opacity(0.14)).frame(height: 1) }
        }
        .foregroundStyle(MBPalette.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.title). \(task.statusText). \(task.projectName). \(task.shortActivity)")
    }
}

struct CompactSettingsView: View {
    @ObservedObject var preferences: ObserverPreferences
    let displayID: String
    @State var normalizedY: CGFloat
    var onAnchorChanged: (CGFloat) -> Void
    var onOpenFullSettings: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Appearance & behavior").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel("Close settings")
                }
            }
            Toggle("Show in Menu Bar", isOn: $preferences.showMenuBar)
                .disabled(!preferences.showFloatingTab)
            Toggle("Show Floating Tab", isOn: $preferences.showFloatingTab)
                .disabled(!preferences.showMenuBar)
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(ObserverAppearance.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Show running task count", isOn: $preferences.showTaskCount)
            Toggle("Reduce MacBridge motion", isOn: $preferences.reduceMacBridgeMotion)
            Toggle("Reduce transparency", isOn: $preferences.reduceTransparency)
            HStack(spacing: 8) {
                Text("Floating Tab glass")
                Slider(value: $preferences.glassOpacity, in: ObserverPreferences.glassOpacityRange)
                Text("\(Int((preferences.glassOpacity * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(MBPalette.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .disabled(preferences.reduceTransparency)
            .opacity(preferences.reduceTransparency ? 0.55 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Floating Tab glass opacity")
            .accessibilityValue("\(Int((preferences.glassOpacity * 100).rounded())) percent")
            Toggle("Hover previews", isOn: $preferences.hoverPreviews)
            Toggle("Pin on click", isOn: $preferences.pinOnClick)
            Toggle("Show in full-screen Spaces", isOn: $preferences.showInFullscreen)
            VStack(alignment: .leading, spacing: 6) {
                Text("Floating Tab position").font(.system(size: 11, weight: .medium)).foregroundStyle(MBPalette.textSecondary)
                Slider(value: Binding(get: { Double(normalizedY) }, set: {
                    normalizedY = CGFloat($0); onAnchorChanged(normalizedY)
                }), in: 0.14...0.86)
                Text("Display \(displayID) · attached to right edge")
                    .font(.system(size: 10)).foregroundStyle(MBPalette.textTertiary)
            }
            if let onOpenFullSettings {
                Button("Open Settings…", action: onOpenFullSettings).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(MBPalette.running)
            }
        }
        .toggleStyle(.switch)
        .font(.system(size: 12))
        .foregroundStyle(MBPalette.textPrimary)
    }
}
