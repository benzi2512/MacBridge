import AppKit
import Combine
import SwiftUI

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: ObserverModel
    private let preferences: ObserverPreferences
    private let openSettings: (() -> Void)?
    private let openSetup: (() -> Void)?
    private var window: NSWindow?
    private var appearanceSubscription: AnyCancellable?

    init(model: ObserverModel, preferences: ObserverPreferences, openSettings: (() -> Void)? = nil,
         openSetup: (() -> Void)? = nil) {
        self.model = model
        self.preferences = preferences
        self.openSettings = openSettings
        self.openSetup = openSetup
        super.init()
    }

    func show(selection: String? = nil) {
        if let selection { model.selectGlobalActivity(selection) }
        let window = prepareWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    /// Construct without presenting so initial chrome can be verified offscreen.
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let created = makeWindow()
        window = created
        return created
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        window = nil
        appearanceSubscription = nil
        model.previewsVisible = false
        model.clearFilePreview()
    }

    private func makeWindow() -> NSWindow {
        let root = DashboardAppearanceView(model: model, preferences: preferences, openSettings: openSettings,
                                           openSetup: openSetup)
            .frame(minWidth: 820, minHeight: 560)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "MacBridge"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.center()
        window.contentView = NSHostingView(rootView: root)
        // Own AppKit appearance in the window controller, not a zero-sized
        // SwiftUI background anchor. This also updates chrome before first show.
        appearanceSubscription = preferences.$appearance.sink { [weak window] appearance in
            window?.appearance = appearance.nativeAppearance
        }
        window.delegate = self
        window.setAccessibilityLabel("MacBridge Dashboard")
        return window
    }
}

private struct DashboardAppearanceView: View {
    @ObservedObject var model: ObserverModel
    @ObservedObject var preferences: ObserverPreferences
    let openSettings: (() -> Void)?
    let openSetup: (() -> Void)?

    var body: some View {
        ObserverView(model: model, showsDetails: true, managesLifecycle: false,
                     recoveryPreferences: preferences, openSettings: openSettings, openSetup: openSetup)
            .modifier(ObserverAppearanceModifier(preferences: preferences))
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: ObserverPreferences
    private let position: ObserverSettingsPosition
    private var window: NSWindow?
    private var appearanceSubscription: AnyCancellable?

    init(preferences: ObserverPreferences, displayID: (() -> String)? = nil) {
        self.preferences = preferences
        position = ObserverSettingsPosition(preferences: preferences,
            displayID: displayID ?? { SettingsWindowController.mainDisplayID })
        super.init()
    }

    func show() {
        position.refreshDisplay()
        let window = prepareWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            window = nil
            appearanceSubscription = nil
        }
    }

    func prepareWindow() -> NSWindow {
        if let window { return window }
        let created = makeWindow()
        window = created
        return created
    }

    private func makeWindow() -> NSWindow {
        let root = FullObserverSettingsView(preferences: preferences, position: position)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "MacBridge Settings"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: root)
        appearanceSubscription = preferences.$appearance.sink { [weak window] appearance in
            window?.appearance = appearance.nativeAppearance
        }
        window.delegate = self
        window.setAccessibilityLabel("MacBridge Settings")
        return window
    }

    private static var mainDisplayID: String {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return "main" }
        return String(number.uint32Value)
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: ObserverModel
    private let preferences: ObserverPreferences
    private let openDashboard: (String?) -> Void
    private let openSettings: () -> Void
    private let showFloating: (FloatingLayer) -> Void
    private let openSetup: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()

    init(model: ObserverModel, preferences: ObserverPreferences,
         openDashboard: @escaping (String?) -> Void,
         openSettings: @escaping () -> Void,
         showFloating: @escaping (FloatingLayer) -> Void, openSetup: (() -> Void)? = nil) {
        self.model = model
        self.preferences = preferences
        self.openDashboard = openDashboard
        self.openSettings = openSettings
        self.showFloating = showFloating
        self.openSetup = openSetup
        super.init()
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
        preferences.$showMenuBar.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyVisibility() }
        }.store(in: &subscriptions)
        preferences.$showTaskCount.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
    }

    func start() { applyVisibility() }

    func stop() {
        model.menuBarVisible = false
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
        // Opening the status menu requests a fresh read, never an action replay.
        Task { await model.refresh(automatic: true) }
    }

    private func applyVisibility() {
        if !preferences.showMenuBar {
            stop()
            return
        }
        model.menuBarVisible = true
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "MacBridgeStatusItem"
            let menu = NSMenu(title: "MacBridge")
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        update()
    }

    private func update() {
        guard let button = statusItem?.button else { return }
        let summary = model.compactSummary
        let image = MacBridgeMarkRenderer.image(size: 18, style: .monochrome)
        image.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.title = preferences.showTaskCount ? " " + summary.runningBadgeText : ""
        button.toolTip = "MacBridge — \(summary.statusText). \(summary.runningBadgeHelp)"
        button.setAccessibilityLabel("MacBridge, \(summary.statusText). \(summary.runningBadgeHelp)")
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = model.compactSummary
        let heading = NSMenuItem(title: "MacBridge · \(summary.statusText)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for task in summary.tasks.prefix(2) {
            let row = NSMenuItem(title: "  \(task.statusText) · \(task.title)", action: #selector(openTask(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = task.selectionID
            row.image = statusImage(task.status)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        add(menu, "Open Dashboard", action: #selector(openDashboardMenu), key: "d", image: "rectangle.3.group")
        add(menu, "Recent Tasks", action: #selector(openRecentTasks), image: "clock")
        add(menu, preferences.showFloatingTab ? "Hide Widget" : "Show Widget",
            action: #selector(toggleWidget), image: preferences.showFloatingTab ? "sidebar.right" : "sidebar.left")
        menu.addItem(.separator())
        let refreshTitle = model.directory.isEmpty ? "Choose Connection…" : "Refresh Connection"
        add(menu, refreshTitle, action: #selector(connectionAction), key: "r", image: "arrow.clockwise")
        if openSetup != nil {
            add(menu, "Set Up Local Connection…", action: #selector(openSetupMenu), image: "externaldrive.badge.plus")
        }
        add(menu, "Settings…", action: #selector(openSettingsMenu), key: ",", image: "gearshape")
        menu.addItem(.separator())
        add(menu, "Quit Interface", action: #selector(quit), key: "q", image: "power")
    }

    private func add(_ menu: NSMenu, _ title: String, action: Selector, key: String = "", image: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: title)
        menu.addItem(item)
    }

    private func statusImage(_ status: CompactTaskStatus) -> NSImage? {
        let symbol: String
        switch status {
        case .running: symbol = "play.circle.fill"
        case .waiting: symbol = "clock.fill"
        case .completed: symbol = "checkmark.circle.fill"
        case .failed: symbol = "exclamationmark.circle.fill"
        case .paused, .cancelled: symbol = "pause.circle.fill"
        case .idle: symbol = "circle"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: status.label)
    }

    @objc private func openTask(_ sender: NSMenuItem) {
        openDashboard(sender.representedObject as? String)
    }
    @objc private func openDashboardMenu() { openDashboard(nil) }
    @objc private func openRecentTasks() {
        preferences.showFloatingTab = true
        showFloating(.recentTasks)
    }
    @objc private func toggleWidget() {
        if preferences.showFloatingTab { preferences.hideFloatingTab() }
        else { preferences.showFloatingTab = true }
    }
    @objc private func openSettingsMenu() { openSettings() }
    @objc private func openSetupMenu() { openSetup?() }
    @objc private func connectionAction() {
        if model.directory.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            model.chooseOwner()
        } else { model.reconnect() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

enum ObserverLaunchConnection {
    static func defaultObserverDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        // Login ordering is nondeterministic: the UI can launch before the
        // existing core publishes its socket. Retain only this known endpoint
        // path and let bounded polling wait for it; do not create directories,
        // launch a core, or accept an unvalidated socket here. ObserverSocket
        // still verifies private mode, same-user ownership and peer identity.
        homeDirectory.appendingPathComponent(".config/macbridge/observer", isDirectory: true).path
    }
}

@MainActor
final class MacBridgeLifecycle: NSObject, NSApplicationDelegate {
    let model: ObserverModel
    let preferences: ObserverPreferences
    private var lifecycleSubscriptions = Set<AnyCancellable>()
    private lazy var dashboard = DashboardWindowController(model: model, preferences: preferences,
        openSettings: { [weak self] in self?.settings.show() },
        openSetup: { [weak self] in self?.setup.show() })
    private lazy var setup = FirstRunSetupWindowController(onConfigured: { [weak self] in self?.model.attach($0) })
    private lazy var settings: SettingsWindowController = SettingsWindowController(preferences: preferences,
        displayID: { [weak self] in self?.floating.displayID ?? "main" })
    private lazy var floating: FloatingTabController = FloatingTabController(model: model, preferences: preferences,
        openDashboard: { [weak self] in self?.dashboard.show(selection: $0) },
        openSettings: { [weak self] in self?.settings.show() })
    private lazy var menuBar = MenuBarController(model: model, preferences: preferences,
        openDashboard: { [weak self] in self?.dashboard.show(selection: $0) },
        openSettings: { [weak self] in self?.settings.show() },
        showFloating: { [weak self] in self?.floating.show($0) },
        openSetup: { [weak self] in self?.setup.show() })

    init(model: ObserverModel = ObserverModel(), preferences: ObserverPreferences = ObserverPreferences()) {
        self.model = model
        self.preferences = preferences
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(forResource: "MacBridge", withExtension: "png"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--observer-directory"), args.indices.contains(index + 1) {
            model.attach(args[index + 1])
        } else { model.attach(ObserverLaunchConnection.defaultObserverDirectory()) }
        floating.start()
        menuBar.start()
        let wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        let activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        wake.merge(with: activation).sink { [weak self] _ in
            DispatchQueue.main.async { self?.model.resumeObservation() }
        }.store(in: &lifecycleSubscriptions)
        if args.contains("--show-widget") { preferences.showFloatingTab = true }
        if args.contains("--dashboard") { dashboard.show() }
        if args.contains("--setup") { setup.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleSubscriptions.removeAll()
        menuBar.stop()
        floating.stop()
        model.stopPolling()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An explicit Finder/Spotlight reopen must recover a hidden widget even
        // when another MB window is already visible. Login preserves preferences.
        preferences.showFloatingTab = true
        model.resumeObservation()
        if !flag { dashboard.show() }
        return true
    }
}

@main
enum MacBridgeObserverApp {
    @MainActor private static var lifecycle: MacBridgeLifecycle?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = MacBridgeLifecycle()
        lifecycle = delegate
        app.delegate = delegate
        app.run()
    }
}
