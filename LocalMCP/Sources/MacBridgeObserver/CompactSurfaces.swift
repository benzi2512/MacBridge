import AppKit
import Combine
import SwiftUI

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let elevated: Bool
    let borderOpacity: Double
    var resting = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.mbReduceTransparency) private var appReduceTransparency
    @Environment(\.mbGlassOpacity) private var requestedGlassOpacity
    @Environment(\.colorSchemeContrast) private var contrast

    private var glassOpacity: Double { min(1, max(0.35, requestedGlassOpacity)) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || appReduceTransparency {
            content.background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 1).allowsHitTesting(false))
                .clipShape(shape)
        } else {
            content.background {
                ZStack {
                    if #available(macOS 26.0, *) {
                        // Clear/Tinted and light/dark belong to macOS, not to
                        // a colored overlay. Both layers retain shape identity.
                        Color.clear.glassEffect(.regular, in: shape)
                            .opacity(resting ? 0 : glassOpacity)
                    } else {
                        shape.fill(.regularMaterial).opacity(resting ? 0 : glassOpacity)
                    }
                    // A small idle surface does not need backdrop sampling.
                    // Keep MB's saved opacity and adaptive monochrome branding.
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                        .opacity(resting ? glassOpacity : 0)
                }.allowsHitTesting(false)
            }
            .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.42 : min(borderOpacity, 0.08)),
                                  lineWidth: contrast == .increased ? 1 : 0.5).allowsHitTesting(false))
            .shadow(color: .black.opacity((elevated ? 0.16 : 0.06) * glassOpacity),
                    radius: elevated ? 12 : 3, y: elevated ? 3 : 1)
        }
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, elevated: Bool = false, borderOpacity: Double = 0.20,
                               resting: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, elevated: elevated, borderOpacity: borderOpacity, resting: resting))
    }
}

@MainActor
final class FloatingTabController: ObservableObject {
    @Published private(set) var machine = FloatingInteractionStateMachine()
    @Published private(set) var pointerInside = false
    @Published private(set) var windowLayer: FloatingLayer = .idle
    @Published private(set) var readingOrder = CompactReadingOrder()
    @Published private(set) var draggingAnchor: FloatingDockAnchor?
    private var logoDrag: FloatingLogoDrag?
    private var screenBeforeDrag: NSScreen?

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
    var dockAnchor: FloatingDockAnchor { draggingAnchor ?? preferences.dockAnchor(for: displayID) }
    var isDraggingLogo: Bool { logoDrag?.isDragging == true }
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
        self.anchoredScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == preferences.preferredDisplayID
        }) ?? NSScreen.main ?? NSScreen.screens.first
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
        cancelLogoDrag()
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        hoverCloseTask?.cancel(); hoverCloseTask = nil
        cancelPreview()
        shrinkTask?.cancel(); shrinkTask = nil
        if presentsWindow { edgePanel?.orderOut(nil) }
    }

    func pointerChanged(_ inside: Bool) {
        guard logoDrag == nil else { return }
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
            guard layer != .idle, !machine.locked else { return }
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
        guard logoDrag == nil else { return }
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
        if machine != FloatingInteractionStateMachine() { machine = FloatingInteractionStateMachine() }
        if windowLayer != .idle { windowLayer = .idle }
        if pointerInside { pointerInside = false }
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
        if logoDrag != nil { cancelLogoDrag(); return }
        cancelPreview()
        var next = machine
        next.closeDeepest()
        setMachine(next)
    }

    func setVerticalAnchor(_ value: CGFloat) {
        preferences.setDockAnchor(.init(edge: dockAnchor.edge, position: Double(value)), for: displayID)
        reposition(animated: false)
    }

    func logoPressBegan(at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        hoverCloseTask?.cancel(); hoverCloseTask = nil
        cancelPreview()
        logoDrag = FloatingLogoDrag(start: point)
        screenBeforeDrag = anchoredScreen
    }

    func logoDragged(to point: CGPoint) {
        guard var drag = logoDrag else { return }
        let moved = drag.move(to: point)
        logoDrag = drag
        guard moved else { return }
        let previousEdge = dockAnchor.edge
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? currentScreen else { return }
        anchoredScreen = screen
        shrinkTask?.cancel(); shrinkTask = nil
        if machine != FloatingInteractionStateMachine() { machine = FloatingInteractionStateMachine() }
        if windowLayer != .idle { windowLayer = .idle }
        if pointerInside { pointerInside = false }
        let next = FloatingDockLayout.anchor(at: point, visibleFrame: screen.visibleFrame, previousEdge: previousEdge)
        if draggingAnchor != next { draggingAnchor = next }
        reposition(animated: false)
    }

    func logoPressEnded(at point: CGPoint) {
        guard logoDrag != nil else { return }
        logoDragged(to: point)
        let moved = isDraggingLogo
        if let anchor = draggingAnchor { preferences.setDockAnchor(anchor, for: displayID) }
        logoDrag = nil
        draggingAnchor = nil
        screenBeforeDrag = nil
        reposition(animated: false)
        if !moved { openDashboard() }
    }

    func cancelLogoDrag() {
        guard logoDrag != nil else { return }
        anchoredScreen = screenBeforeDrag
        logoDrag = nil
        screenBeforeDrag = nil
        draggingAnchor = nil
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
        let currentWindowSize = FloatingDockLayout.size(for: windowLayer, visibleFrame: visibleFrame,
                                                taskCount: readingOrder.ids.count, edge: dockAnchor.edge)
        let nextWindowSize = FloatingDockLayout.size(for: next.layer, visibleFrame: visibleFrame,
                                             taskCount: readingOrder.ids.count, edge: dockAnchor.edge)
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
        let frame = FloatingDockLayout.frame(visibleFrame: screen.visibleFrame, layer: windowLayer,
                                             anchor: dockAnchor, taskCount: readingOrder.ids.count)
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
        let hosting = FloatingFirstClickHostingView(rootView: FloatingTabView(controller: self))
        // AppKit owns the canvas. Do not let GeometryReader's 10pt ideal size
        // feed a second, competing resize back into the borderless window.
        hosting.sizingOptions = []
        panel.contentView = hosting
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
            let bottom = controller.dockAnchor.edge == .bottom
            let logo = FloatingDockLayout.logo(in: geometry.size, layer: controller.windowLayer, edge: controller.dockAnchor.edge)
            ZStack(alignment: .topLeading) {
                edgeHandle
                    .position(x: bottom ? logo.x + EdgeLayout.railLogoOffset : geometry.size.width - MBMetrics.edgeRailWidth / 2,
                              y: bottom ? geometry.size.height - MBMetrics.edgeRailWidth / 2 : logo.y + EdgeLayout.railLogoOffset)
                logoButton.position(logo)
                ZStack(alignment: .trailing) {
                    if controller.layer.hasPanel {
                        compactPanel
                            .transition(reducedMotion ? .opacity : .opacity.combined(with: .offset(x: bottom ? 0 : 12, y: bottom ? 12 : 0)))
                    }
                }
                .animation(FloatingMotion.panel(reduced: reducedMotion), value: controller.layer)
                .frame(width: canvasPanelSize.width, height: canvasPanelSize.height, alignment: .trailing)
                .position(x: bottom ? geometry.size.width / 2 : max(canvasPanelSize.width / 2, geometry.size.width - MBMetrics.edgeRailWidth - canvasPanelSize.width / 2),
                          y: bottom ? geometry.size.height - MBMetrics.edgeRailWidth - MBMetrics.panelGap - canvasPanelSize.height / 2 : geometry.size.height / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(FloatingHitRegion(logoY: logo.y,
                expansion: reducedMotion ? (controller.windowLayer.isExpanded ? 1 : 0) : expansion,
                panelSize: canvasPanelSize, dockEdge: controller.dockAnchor.edge, logoX: logo.x))
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
        .environment(\.mbReduceMotion, preferences.reduceMacBridgeMotion)
        .onAppear { expansion = controller.layer.isExpanded ? 1 : 0 }
        .onChange(of: controller.layer.isExpanded) { expanded in
            let reduced = systemReduceMotion || preferences.reduceMacBridgeMotion
            withAnimation(FloatingMotion.unfold(reduced: reduced)) {
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
        // The card's shell glides; commands and labels must not stretch or
        // interpolate into another task while its dimensions are changing.
        .transaction { $0.animation = nil }
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
                        .glassSurface(DockedOrganicEdgeShape(edge: controller.dockAnchor.edge, expansion: controller.layer.isExpanded ? 1 : 0),
                                      borderOpacity: 0.16, resting: !controller.layer.isExpanded)
                        .id(controller.layer.isExpanded)
                        .transition(.opacity)
                }
                .animation(.easeOut(duration: MBMetrics.reducedMotionDuration), value: controller.layer.isExpanded)
            } else {
                handleContent.glassSurface(DockedOrganicEdgeShape(edge: controller.dockAnchor.edge, expansion: expansion), borderOpacity: 0.16,
                                          resting: !controller.layer.isExpanded)
            }
        }
        .accessibilityIdentifier("floating-edge-handle")
    }

    private var handleContent: some View {
        ZStack {
            Color.clear
            railContent
                .allowsHitTesting(controller.layer.isExpanded)
                .accessibilityHidden(!controller.layer.isExpanded)
        }
        .frame(width: controller.dockAnchor.edge == .bottom ? MBMetrics.edgeRailHeight : MBMetrics.edgeRailWidth,
               height: controller.dockAnchor.edge == .bottom ? MBMetrics.edgeRailWidth : MBMetrics.edgeRailHeight)
    }

    private var logoButton: some View {
        FloatingLogoControl(summary: summary, showCount: preferences.showTaskCount,
                            edge: controller.dockAnchor.edge, controller: controller)
            .frame(width: controller.dockAnchor.edge == .bottom ? 38 : MBMetrics.edgeTargetSize,
                   height: controller.dockAnchor.edge == .bottom ? MBMetrics.edgeTargetSize : MBMetrics.edgeBrandHeight)
            .help("Click to open. Drag to move along the right or bottom edge. \(summary.runningBadgeHelp)")
    }

    private var railContent: some View {
        let bottom = controller.dockAnchor.edge == .bottom
        let layout = bottom ? AnyLayout(HStackLayout(spacing: MBMetrics.edgeRailSpacing))
            : AnyLayout(VStackLayout(spacing: MBMetrics.edgeRailSpacing))
        return layout {
            Color.clear.frame(width: MBMetrics.edgeTargetSize, height: MBMetrics.edgeTargetSize).allowsHitTesting(false)
            ForEach(Array(RailAction.allCases.enumerated()), id: \.element) { index, action in
                Button { perform(action) } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: action == .hide ? 10 : 15, weight: .regular))
                        .frame(width: MBMetrics.edgeTargetSize, height: MBMetrics.edgeTargetSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(selected: selected(action)))
                .accessibilityLabel(action.label)
                .opacity(controller.layer.isExpanded ? 1 : 0)
                .offset(x: !bottom || reducedMotion || controller.layer.isExpanded ? 0 : -6,
                        y: bottom || reducedMotion || controller.layer.isExpanded ? 0 : -6)
                .animation(FloatingMotion.contents(index: index, appearing: controller.layer.isExpanded,
                                                  reduced: reducedMotion), value: controller.layer.isExpanded)
                .onHover { inside in
                    if action == .recentTasks { controller.preview(.recentTasks, inside: inside) }
                }
            }
        }
        .foregroundStyle(MBPalette.textPrimary.opacity(0.88))
        .offset(x: bottom ? FloatingDockLayout.railContentOffset : MBMetrics.edgeRailWidth / 2 - EdgeLayout.logoInset,
                y: bottom ? MBMetrics.edgeRailWidth / 2 - EdgeLayout.logoInset : FloatingDockLayout.railContentOffset)
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
                Image(systemName: controller.machine.locked ? "pin.fill" : "pin").frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(controller.machine.locked ? MBPalette.brandBlue : MBPalette.textSecondary)
                .accessibilityLabel(controller.machine.locked ? "Unpin panel" : "Pin panel")
            Button(action: controller.closeDeepest) { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
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
                Button { controller.show(.recentTasks) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Back to recent tasks")
                Spacer()
                Button(action: controller.closeDeepest) { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
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
        ScrollView {
            CompactSettingsView(preferences: preferences, displayID: controller.displayID,
                                onAnchorChanged: controller.setVerticalAnchor,
                                onOpenFullSettings: controller.openSettings,
                                onClose: controller.closeDeepest)
                .padding(16)
        }
    }
}

/// One narrow, transparent brand target in both idle and expanded states.
/// Count changes do not resize/move the window or add polling/animation work.
struct CompactBrandBadge: View {
    let summary: CompactSummary
    let showCount: Bool
    var horizontal = false

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        return layout {
            MacBridgeMark(size: horizontal ? 18 : MBMetrics.edgeLogoSize, style: .monochrome)
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
        .frame(width: horizontal ? 38 : MBMetrics.edgeBrandWidth,
               height: horizontal ? MBMetrics.edgeTargetSize : MBMetrics.edgeBrandHeight)
        .animation(nil, value: summary.runningBadgeText)
    }
}

private struct RailButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? MBPalette.textPrimary : MBPalette.textSecondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : selected ? 0.10 : 0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .contentShape(Rectangle())
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
    var onAnchorChanged: (CGFloat) -> Void
    var onOpenFullSettings: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Appearance & behavior").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
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
                Text("Drag the logo up/down or onto the bottom edge. Click to open Dashboard.")
                    .font(.system(size: 11)).foregroundStyle(MBPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Picker("Screen edge", selection: Binding(get: { preferences.dockAnchor(for: displayID).edge }, set: {
                    preferences.setDockAnchor(.init(edge: $0, position: 0.5), for: displayID)
                })) {
                    ForEach(FloatingDockEdge.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Slider(value: Binding(get: { preferences.dockAnchor(for: displayID).position }, set: {
                    onAnchorChanged(CGFloat($0))
                }), in: 0...1)
                    .accessibilityLabel("Position along \(preferences.dockAnchor(for: displayID).edge.rawValue) edge")
                Text("Display \(displayID) · attached to \(preferences.dockAnchor(for: displayID).edge.rawValue) edge")
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
