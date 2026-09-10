import AppKit
import SwiftUI

private struct MBReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }
private struct MBGlassOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var mbReduceTransparency: Bool {
        get { self[MBReduceTransparencyKey.self] }
        set { self[MBReduceTransparencyKey.self] = newValue }
    }
    var mbGlassOpacity: Double {
        get { self[MBGlassOpacityKey.self] }
        set { self[MBGlassOpacityKey.self] = newValue }
    }
}

/// Explicit source-over color, separate from the system's adaptive glass tint.
/// Alpha stays below one in both appearances; Reduce Transparency is a distinct
/// opaque path. Sharing this treatment keeps fallback and native glass coherent.
struct GlassColorTreatment {
    let scheme: ColorScheme
    let elevated: Bool
    let strength: Double

    init(scheme: ColorScheme, elevated: Bool, strength: Double = 1) {
        self.scheme = scheme
        self.elevated = elevated
        self.strength = min(1, max(0, strength))
    }

    var topOpacity: Double { (scheme == .dark ? (elevated ? 0.28 : 0.20) : 0.10) * strength }
    var bottomOpacity: Double { (scheme == .dark ? (elevated ? 0.40 : 0.30) : 0.06) * strength }
    var topColor: Color { scheme == .dark ? MBPalette.surfaceElevated : .white }
    var bottomColor: Color { scheme == .dark ? MBPalette.deepNavy : .white }
    var gradient: LinearGradient {
        LinearGradient(colors: [topColor.opacity(topOpacity), bottomColor.opacity(bottomOpacity)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct ObserverWindowSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.mbReduceTransparency) private var appReduced
    @Environment(\.accessibilityReduceTransparency) private var systemReduced
    var body: some View {
        if appReduced || systemReduced {
            scheme == .dark ? MBPalette.deepNavy : Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                DesktopBackdrop()
                LinearGradient(colors: scheme == .dark
                    ? [MBPalette.surface.opacity(0.48), MBPalette.deepNavy.opacity(0.70)]
                    : [Color.white.opacity(0.12), MBPalette.brandBlue.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
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
    var body: some View {
        RoundedRectangle(cornerRadius: 10).fill(scheme == .dark
            ? MBPalette.deepNavy.opacity(0.68) : Color(nsColor: .textBackgroundColor).opacity(0.82))
    }
}

struct ObserverAppearanceModifier: ViewModifier {
    @ObservedObject var preferences: ObserverPreferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferences.appearance.colorScheme)
            .environment(\.mbReduceTransparency, systemReduceTransparency || preferences.reduceTransparency)
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
        var body: some View {
            label.background(MBPalette.brandBlue.opacity(pressed ? 0.22 : hovered ? 0.10 : 0),
                             in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
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
        preferences.setNormalizedY(value, for: displayID)
    }
}

struct FullObserverSettingsView: View {
    @ObservedObject var preferences: ObserverPreferences
    @ObservedObject var position: ObserverSettingsPosition
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MacBridgeMark(size: 28)
                Text("MacBridge Settings").font(.system(size: 17, weight: .semibold))
            }
            Divider()
            ScrollView {
                CompactSettingsView(preferences: preferences, displayID: position.displayID,
                    normalizedY: preferences.normalizedY(for: position.displayID),
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
    }
}
