import AppKit
import SwiftUI
import MacBridgeLocalCore

@MainActor
final class FirstRunSetupModel: ObservableObject {
    @Published private(set) var plan: LocalSetupPlan?
    @Published private(set) var created = false
    @Published private(set) var notice = ""
    @Published private(set) var clientConfiguration = ""
    private let executableURL: URL
    private let onConfigured: (String) -> Void

    init(executableURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macbridge-mcp"),
         onConfigured: @escaping (String) -> Void) {
        self.executableURL = executableURL
        self.onConfigured = onConfigured
    }

    func chooseWorkspace() {
        guard !created else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.message = "Only this folder will be registered. Credentials, browser profiles and system protections remain excluded. Nothing changes until you click Create local configuration."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let proposal = try LocalSetupPlan(workspaceURL: selected, executableURL: executableURL)
            clientConfiguration = try proposal.clientConfiguration
            plan = proposal
            notice = "Review the selected folder before creating your local configuration."
        } catch {
            plan = nil
            clientConfiguration = ""
            notice = String(describing: error)
        }
    }

    func createConfiguration() {
        guard !created, let plan else { return }
        do {
            try plan.createConfiguration()
            created = true
            notice = "Local configuration created. Add the configuration below to one local MCP client, then start its MacBridge connection."
            // Read-only observation waits for that client. It does not start
            // another owner, background service or tunnel from this window.
            onConfigured(plan.observerDirectory)
        } catch {
            notice = String(describing: error)
        }
    }

    func copyClientConfiguration() {
        guard created, !clientConfiguration.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clientConfiguration, forType: .string)
        notice = "Copied local MCP configuration. It contains your local paths, but no credentials."
    }
}

struct FirstRunSetupView: View {
    @ObservedObject var model: FirstRunSetupModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Set up MacBridge", systemImage: "externaldrive.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                Text("Choose one project folder and connect your own MCP client.")
                Text("No account, workspace, token or service is copied from another installation. Existing configuration is never overwritten.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.plan == nil ? "Choose project folder…" : "Choose another folder…", action: model.chooseWorkspace)
                    .disabled(model.created)
                if let plan = model.plan {
                    GroupBox("Folder access") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(plan.configuration.workspaces[0].path).textSelection(.enabled)
                            Text("File and process tools are restricted to this folder. No whole-disk grant, root privilege, login service or network tunnel is added.")
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.created {
                        Text("Creates a private workspace registry and observer directory:")
                            .font(.callout)
                        Text(plan.configurationPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Create local configuration", action: model.createConfiguration)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if !model.notice.isEmpty {
                    Text(model.notice).font(.callout).textSelection(.enabled)
                }
                if model.created {
                    GroupBox("Local MCP client configuration") {
                        Text(model.clientConfiguration)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Copy client configuration", action: model.copyClientConfiguration)
                }
                Divider()
                Text("Normal Chat needs a separate, approved tunnel connection for this owner's account. This setup does not register a cloud app, repair a disabled chat, or start a background service.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Already configured? Close this window and use Choose connection in the dashboard. Setup will not change your current owner, jobs or undo records.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 540, minHeight: 480)
    }
}

@MainActor
final class FirstRunSetupWindowController: NSObject, NSWindowDelegate {
    private let model: FirstRunSetupModel
    private var window: NSWindow?

    init(onConfigured: @escaping (String) -> Void) {
        model = FirstRunSetupModel(onConfigured: onConfigured)
        super.init()
    }

    func show() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 610),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            created.title = "MacBridge Setup"
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 540, height: 480)
            created.contentView = NSHostingView(rootView: FirstRunSetupView(model: model))
            created.delegate = self
            created.center()
            created.setAccessibilityLabel("MacBridge Setup")
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { window = nil }
    }
}
