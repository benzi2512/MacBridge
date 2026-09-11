import AppKit
import SwiftUI

private struct MBReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }
private struct MBGlassOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }
private struct MBReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var mbReduceMotion: Bool {
        get { self[MBReduceMotionKey.self] }
        set { self[MBReduceMotionKey.self] = newValue }
    }
    var mbReduceTransparency: Bool {
        get { self[MBReduceTransparencyKey.self] }
        set { self[MBReduceTransparencyKey.self] = newValue }
    }
    var mbGlassOpacity: Double {
        get { self[MBGlassOpacityKey.self] }
        set { self[MBGlassOpacityKey.self] = newValue }
    }
}

struct ObserverWindowSurface: View {
    @Environment(\.mbReduceTransparency) private var appReduced
    @Environment(\.accessibilityReduceTransparency) private var systemReduced
    var body: some View {
        if appReduced || systemReduced {
            Color(nsColor: .windowBackgroundColor)
        } else {
            // WindowServer provides the desktop-backed material. No fixed
            // navy wash, tint, or screenshot layer overrides system appearance.
            DesktopBackdrop()
        }
    }
}

/// The dashboard's old opaque NSWindow prevented desktop-backed material.
/// This uses the WindowServer backdrop; it does not capture the screen.
private struct DesktopBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ObserverReadingSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.mbReduceTransparency) private var appReduced
    @Environment(\.accessibilityReduceTransparency) private var systemReduced
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor)
                .opacity(appReduced || systemReduced ? 1 : scheme == .dark ? 0.25 : 0.50))
    }
}

struct ObserverAppearanceModifier: ViewModifier {
    @ObservedObject var preferences: ObserverPreferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferences.appearance.colorScheme)
            .environment(\.mbReduceTransparency, systemReduceTransparency || preferences.reduceTransparency)
            .environment(\.mbReduceMotion, preferences.reduceMacBridgeMotion)
    }
}

struct CompactActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(label: configuration.label, pressed: configuration.isPressed)
    }
    private struct HoverSurface: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var systemReduced
        @Environment(\.mbReduceMotion) private var appReduced
        var body: some View {
            label.background(Color.primary.opacity(pressed ? 0.14 : hovered ? 0.07 : 0),
                             in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
                .animation(FloatingMotion.crossfade(reduced: systemReduced || appReduced), value: hovered)
        }
    }
}

@MainActor
final class ObserverSettingsPosition: ObservableObject {
    @Published private(set) var displayID: String
    private let preferences: ObserverPreferences
    private let currentDisplayID: () -> String

    init(preferences: ObserverPreferences, displayID: @escaping () -> String) {
        self.preferences = preferences
        currentDisplayID = displayID
        self.displayID = displayID()
    }

    func refreshDisplay() {
        let current = currentDisplayID()
        if displayID != current { displayID = current }
    }

    func setNormalizedY(_ value: CGFloat) {
        refreshDisplay()
        preferences.setDockAnchor(.init(edge: preferences.dockAnchor(for: displayID).edge,
                                       position: Double(value)), for: displayID)
    }
}

struct FullObserverSettingsView: View {
    @ObservedObject var preferences: ObserverPreferences
    @ObservedObject var position: ObserverSettingsPosition
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MacBridgeMark(size: 28, style: .monochrome)
                Text("MacBridge Settings").font(.system(size: 17, weight: .semibold))
            }
            Divider()
            ScrollView {
                CompactSettingsView(preferences: preferences, displayID: position.displayID,
                    onAnchorChanged: position.setNormalizedY)
                    .id(position.displayID)
            }
            Text("UI preferences do not grant file or command permissions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background { ObserverWindowSurface().ignoresSafeArea() }
        .modifier(ObserverAppearanceModifier(preferences: preferences))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            position.refreshDisplay()
        }
        .onReceive(preferences.objectWillChange) { _ in position.refreshDisplay() }
    }
}
