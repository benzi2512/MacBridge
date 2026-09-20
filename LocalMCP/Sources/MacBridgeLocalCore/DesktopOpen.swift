import AppKit
import Darwin
import Foundation

/// Fixed OS presentation actions. This is deliberately not a general `open`
/// executable: callers cannot choose flags, URLs, handlers or executable paths.
enum DesktopOpen {
    static let actions = ["folder", "reveal", "file", "application"]
    static let applications = [
        "finder": "/System/Library/CoreServices/Finder.app",
        "preview": "/System/Applications/Preview.app",
        "textedit": "/System/Applications/TextEdit.app",
    ]
    private static let previewExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "pdf"]
    private static let textExtensions: Set<String> = ["txt", "md", "csv", "tsv", "json", "xml", "log", "swift", "py", "js", "ts", "css", "html", "yaml", "yml", "toml", "sh"]
    private static let bundleExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "prefpane", "kext", "appex", "workflow", "scptd", "rtfd"]

    struct Request: Equatable {
        let action: String
        let target: URL?
        let application: String
    }

    // Only dependency injection in compiled tests; never selected by a tool,
    // environment variable, workspace data or a command-line argument.
    typealias Presenter = (Request) throws -> Bool

    static func execute(_ arguments: JSONObject, workspace: LocalWorkspaceService,
                        presenter: Presenter = present) throws -> JSONObject {
        try arguments.requireOnlyKeys(["workspace_id", "action", "path", "application"])
        let id = try arguments.requiredString("workspace_id", maximumBytes: 36)
        let configured = try workspace.registry.workspace(id: id)
        guard configured.allowsDesktopOpen else {
            throw LocalMCPError.operationFailed("desktop opening is not enabled for this workspace; the owner must approve allow_desktop_open in local configuration")
        }
        let action = try arguments.requiredString("action", maximumBytes: 16)
        guard actions.contains(action) else { throw LocalMCPError.invalidRequest("unsupported desktop action") }
        let requestedApp = try arguments.optionalString("application", maximumBytes: 16)
        let request: Request
        if action == "application" {
            guard arguments["path"] == nil, let requestedApp, applications[requestedApp] != nil else {
                throw LocalMCPError.invalidRequest("application requires finder, preview or textedit and no path")
            }
            request = Request(action: action, target: nil, application: requestedApp)
        } else {
            let path = try arguments.requiredString("path", maximumBytes: 4096)
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !path.contains("://"), !path.hasPrefix("~") else {
                throw LocalMCPError.invalidPath("use a canonical local path, not a URL or shell expression")
            }
            let target = try workspace.workspaceURL(workspaceID: id, relativePath: path)
            // Compare ancestor identities again immediately before the request,
            // without creating files or following symlinks. Finder's APIs are
            // not a filesystem sandbox; this is not a malware-containment claim.
            let validated = try validate(target, action: action)
            let app: String
            if action == "file" {
                let ext = target.pathExtension.lowercased()
                if previewExtensions.contains(ext) { app = "preview" }
                else if textExtensions.contains(ext) { app = "textedit" }
                else { throw LocalMCPError.invalidRequest("unsupported file type; use reveal to show it in Finder without opening it") }
                guard requestedApp == nil || requestedApp == app else {
                    throw LocalMCPError.invalidRequest("file viewer is fixed by the supported file type")
                }
            } else {
                guard requestedApp == nil || requestedApp == "finder" else {
                    throw LocalMCPError.invalidRequest("folder and reveal use Finder only")
                }
                app = "finder"
            }
            request = Request(action: action, target: target, application: app)
            // Do not publish a successful receipt after detecting a raced path.
            guard try validate(target, action: action) == validated else {
                throw LocalMCPError.conflict("desktop target changed before presentation")
            }
        }
        let accepted = try presenter(request)
        guard accepted else {
            throw LocalMCPError.operationFailed("macOS did not accept the desktop request; check the logged-in GUI session; no shell fallback was attempted")
        }
        var result: JSONObject = ["operation": "desktop_open", "action": action,
            "workspace_id": id, "application": request.application,
            "backend_called": true, "request_accepted": true,
            "window_visibility_verified": false, "mutation_performed": false,
            "ui_side_effect": true, "execution_backend": "macos_workspace",
            "shell_executed": false, "permissions_changed": false]
        if let target = request.target { result["path"] = target.path }
        return result
    }

    private static func validate(_ target: URL, action: String) throws -> [String] {
        let path = target.path
        guard !LocalFilesystemAccess.isSensitive(path) else { throw LocalMCPError.sensitivePathBlocked }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var stamps: [String] = []
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let status = try lstatValue(current.path)
            let kind = status.st_mode & S_IFMT
            guard kind != S_IFLNK else { throw LocalMCPError.invalidPath("symbolic links are not followed") }
            if index < components.count - 1, kind != S_IFDIR { throw LocalMCPError.wrongFileType }
            if action != "reveal", bundleExtensions.contains(current.pathExtension.lowercased()) {
                throw LocalMCPError.invalidPath("application and document bundles may only be revealed, not opened as folders or files")
            }
            stamps.append("\(status.st_dev):\(status.st_ino):\(status.st_mode)")
        }
        let status = try lstatValue(path)
        let kind = status.st_mode & S_IFMT
        if action == "folder" { guard kind == S_IFDIR else { throw LocalMCPError.wrongFileType } }
        else if action == "file" {
            guard kind == S_IFREG, status.st_nlink == 1, status.st_mode & 0o111 == 0 else {
                throw LocalMCPError.invalidPath("only non-executable single-link regular documents can be opened")
            }
        } else { guard kind == S_IFREG || kind == S_IFDIR else { throw LocalMCPError.wrongFileType } }
        return stamps
    }

    private static func present(_ request: Request) throws -> Bool {
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw LocalMCPError.operationFailed("no logged-in graphical session is available")
        }
        let workspace = NSWorkspace.shared
        switch request.action {
        case "folder":
            return workspace.selectFile(nil, inFileViewerRootedAtPath: request.target!.path)
        case "reveal":
            return workspace.selectFile(request.target!.path, inFileViewerRootedAtPath: "")
        case "file":
            // The synchronous API reports acceptance without blocking the MCP
            // loop waiting for a main-queue asynchronous completion handler.
            return workspace.openFile(request.target!.path,
                withApplication: applications[request.application]!, andDeactivate: true)
        case "application":
            return workspace.open(URL(fileURLWithPath: applications[request.application]!))
        default: return false
        }
    }
}
