import AppKit
import SwiftUI
import MacBridgeLocalCore

@MainActor
final class FirstRunSetupModel: ObservableObject {
    @Published private(set) var plan: LocalSetupPlan?
    @Published private(set) var created = false
    @Published private(set) var existing: ExistingLocalSetup?
    @Published private(set) var recoveryFailed = false
    @Published private(set) var notice = ""
    @Published private(set) var clientConfiguration = ""
    private let executableURL: URL
    private let homeDirectory: URL
    private let onConfigured: (String) -> Void
    private let copyToClipboard: (String) -> Void

    var configured: Bool { created || existing != nil }

    init(executableURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macbridge-mcp"),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         copyToClipboard: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
         },
         onConfigured: @escaping (String) -> Void) {
        self.executableURL = executableURL
        self.homeDirectory = homeDirectory
        self.onConfigured = onConfigured
        self.copyToClipboard = copyToClipboard
        reloadExistingConfiguration()
    }

    func reloadExistingConfiguration() {
        guard !created || recoveryFailed else { return }
        do {
            let recovered = try LocalSetupPlan.existingConfiguration(executableURL: executableURL, homeDirectory: homeDirectory)
            guard recovered != nil || !configured else {
                throw LocalMCPError.invalidConfiguration("workspace configuration is missing")
            }
            existing = recovered
            recoveryFailed = false
            if let existing {
                plan = nil
                clientConfiguration = existing.clientConfiguration
                notice = "Your existing configuration is ready. Copy its connection settings into your local MCP client. No files or permissions were changed."
            } else if plan == nil {
                clientConfiguration = ""
                notice = ""
            }
        } catch {
            existing = nil
            recoveryFailed = true
            clientConfiguration = ""
            notice = "Existing setup needs attention: \(error). No files were changed."
        }
    }

    func chooseWorkspace() {
        guard !configured, !recoveryFailed else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.message = "Only this folder will be registered. Credentials, browser profiles and system protections remain excluded. Nothing changes until you click Create local configuration."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let proposal = try LocalSetupPlan(workspaceURL: selected, executableURL: executableURL,
                                              homeDirectory: homeDirectory)
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
        guard !configured, !recoveryFailed, let plan else { return }
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
        guard configured else { return }
        do {
            // The app or registry may have moved since this window was shown.
            // Copy only freshly validated instructions; leave the clipboard
            // alone on failure and never attach/start a second owner here.
            guard let current = try LocalSetupPlan.existingConfiguration(executableURL: executableURL,
                homeDirectory: homeDirectory) else {
                throw LocalMCPError.invalidConfiguration("workspace configuration is missing")
            }
            existing = current
            clientConfiguration = current.clientConfiguration
            copyToClipboard(clientConfiguration)
            notice = "Copied local MCP configuration. It contains your local paths, but no credentials."
        } catch {
            recoveryFailed = true
            clientConfiguration = ""
            notice = "Cannot copy connection settings: \(error). No files were changed."
        }
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
                    .disabled(model.configured || model.recoveryFailed)
                if let existing = model.existing {
                    GroupBox("Existing workspace configuration") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(existing.workspaceCount) configured workspace(s)")
                            Text(existing.configurationPath)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Your existing workspace access and grants are preserved. These settings connect to that registry; they do not create a new one.")
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
                if model.configured && !model.clientConfiguration.isEmpty {
                    GroupBox("Local MCP client configuration") {
                        Text(model.clientConfiguration)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Copy client configuration", action: model.copyClientConfiguration)
                }
                if model.recoveryFailed {
                    Button("Check existing setup again", action: model.reloadExistingConfiguration)
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
        model.reloadExistingConfiguration()
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
