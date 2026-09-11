import Foundation

public struct LocalComputerGrant: Codable, Equatable, Sendable {
    public let bundleID: String
    public let actions: [String]
    public let expiresAt: String
    enum CodingKeys: String, CodingKey { case actions; case bundleID = "bundle_id"; case expiresAt = "expires_at" }
    public init(bundleID: String, actions: [String], expiresAt: String) {
        self.bundleID = bundleID; self.actions = actions; self.expiresAt = expiresAt
    }
    static let supportedActions = ["snapshot", "focus", "press", "set_value"]
    // General desktop control must not become a convenient shell, credential
    // reader or way to approve its own macOS permissions.
    static let blockedBundles: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2",
        "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop"]
    func validateShape() throws {
        guard (3...180).contains(bundleID.utf8.count), bundleID.contains("."),
              bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !Self.blockedBundles.contains(bundleID), !actions.isEmpty,
              actions.contains("snapshot"),
              Set(actions).count == actions.count,
              Set(actions).isSubset(of: Set(Self.supportedActions)),
              ISO8601DateFormatter().date(from: expiresAt) != nil else {
            throw LocalMCPError.invalidConfiguration("invalid computer grant or protected application")
        }
    }
    func authorize(action: String, now: Date) throws {
        try validateShape()
        guard let expiry = ISO8601DateFormatter().date(from: expiresAt),
              expiry > now, expiry.timeIntervalSince(now) <= 3600,
              action == "status" || actions.contains(action) else {
            throw LocalMCPError.operationFailed("computer grant is expired, outside the one-hour limit, or does not allow this action")
        }
    }
}

struct ComputerApplication: Equatable {
    let bundleID: String
    let pid: Int32
    let launchStamp: Double
    let frontmost: Bool
    func sameProcess(as other: Self) -> Bool {
        bundleID == other.bundleID && pid == other.pid && launchStamp == other.launchStamp
    }
}

struct ComputerNode {
    let id: Int
    let role: String
    let title: String
    let value: String?
    let actions: [String]
    let secure: Bool
    // Native AX element retained only inside one bounded frame. References are
    // unusable after 15 seconds; a newer snapshot replaces the entire frame.
    let handle: Any?
    let parentID: Int?

    init(id: Int, role: String, title: String, value: String?, actions: [String],
         secure: Bool, handle: Any?, parentID: Int? = nil) {
        self.id = id; self.role = role; self.title = title; self.value = value
        self.actions = actions; self.secure = secure; self.handle = handle; self.parentID = parentID
    }
}

struct ComputerFrame {
    let nodes: [ComputerNode]
    let partial: Bool
}

protocol ComputerBackend: AnyObject {
    var trusted: Bool { get }
    func application(bundleID: String) throws -> ComputerApplication
    func snapshot(application: ComputerApplication) throws -> ComputerFrame
    func perform(action: String, application: ComputerApplication, node: ComputerNode?, text: String?) throws
}

/// One on-demand frame, no screenshot stream, clipboard access, event taps,
/// global keyboard/mouse injection, background polling or permission prompts.
final class ComputerControl {
    private let backend: any ComputerBackend
    private let now: () -> Date
    private struct Retained {
        let id: String
        let workspaceID: String
        let application: ComputerApplication
        let capturedAt: Date
        let frame: ComputerFrame
    }
    private var retained: Retained?
    init(backend: any ComputerBackend = NativeComputerBackend(), now: @escaping () -> Date = Date.init) {
        self.backend = backend; self.now = now
    }

    func execute(_ a: JSONObject, workspace: LocalWorkspaceService) throws -> JSONObject {
        try a.requireOnlyKeys(["workspace_id", "bundle_id", "action", "snapshot_id", "element_id", "text"])
        let id = try a.requiredString("workspace_id", maximumBytes: 36)
        let bundle = try a.requiredString("bundle_id", maximumBytes: 180)
        let action = try a.requiredString("action", maximumBytes: 16)
        guard (["status"] + LocalComputerGrant.supportedActions).contains(action) else {
            throw LocalMCPError.invalidRequest("unsupported computer action")
        }
        let w = try workspace.registry.workspace(id: id)
        guard let grant = w.computerGrants.first(where: { $0.bundleID == bundle }) else {
            throw LocalMCPError.operationFailed("application has no owner-approved computer grant in this workspace")
        }
        try grant.authorize(action: action, now: now())
        let isMutation = ["focus", "press", "set_value"].contains(action)
        if !["press", "set_value"].contains(action), a["snapshot_id"] != nil || a["element_id"] != nil || a["text"] != nil {
            throw LocalMCPError.invalidRequest("this action does not take element or text arguments")
        }
        if action == "press", a["text"] != nil { throw LocalMCPError.invalidRequest("press does not take text") }
        guard backend.trusted else {
            retained = nil
            return ["operation": "computer_control", "status": "permission_required",
                "permission": "macOS Accessibility for the installed MacBridge core",
                "permission_prompted": false, "action_performed": false,
                "ui_verified": false, "access_changed": false]
        }
        if action == "status" {
            return ["operation": "computer_control", "status": "permission_present",
                "bundle_id": bundle, "allowed_actions": grant.actions,
                "expires_at": grant.expiresAt, "action_performed": false,
                "ui_verified": false, "permission_prompted": false]
        }
        let app = try backend.application(bundleID: bundle)
        if isMutation {
            var node: ComputerNode?
            if action != "focus" {
                let snapshot = try a.requiredString("snapshot_id", maximumBytes: 36)
                let element = try a.optionalInt("element_id", default: -1, range: 0...127)
                guard let cached = retained, cached.id == snapshot, cached.workspaceID == id,
                      cached.application.sameProcess(as: app), now().timeIntervalSince(cached.capturedAt) >= 0,
                      now().timeIntervalSince(cached.capturedAt) <= 15,
                      let selected = cached.frame.nodes.first(where: { $0.id == element }),
                      !selected.secure, selected.actions.contains(action) else {
                    throw LocalMCPError.conflict("stale or unauthorized element; read a fresh snapshot before acting")
                }
                guard app.frontmost else {
                    throw LocalMCPError.conflict("the approved application is not frontmost; no action was sent")
                }
                node = selected
            }
            var text: String?
            if action == "set_value" {
                guard let supplied = a["text"] as? String, supplied.utf8.count <= 4096, !supplied.contains("\0") else {
                    throw LocalMCPError.invalidRequest("set_value requires at most 4096 UTF-8 bytes without NUL")
                }
                text = supplied
            }
            // Consume the old frame even on timeout: AX timeouts can have an
            // uncertain outcome. Never replay mutations automatically.
            retained = nil
            do { try backend.perform(action: action, application: app, node: node, text: text) }
            catch {
                return ["operation": "computer_control", "status": "outcome_unknown",
                    "isError": true, "action": action, "action_attempted": true,
                    "action_performed": NSNull(), "retry_safe": false,
                    "message": "The app did not confirm the action. Inspect a new snapshot before deciding whether to retry; no automatic replay occurred."]
            }
        }
        // Read once after an action, in the same round trip. A successful AX
        // request is not a claim that the user's whole task is completed.
        let refreshed: ComputerApplication
        do { refreshed = try backend.application(bundleID: bundle) }
        catch {
            retained = nil
            if isMutation {
                return ["operation": "computer_control", "status": "action_accepted_snapshot_unavailable",
                    "action_performed": true, "ui_verified": false, "retry_safe": false]
            }
            throw error
        }
        guard refreshed.sameProcess(as: app) else {
            retained = nil
            return ["operation": "computer_control", "status": "application_changed",
                "action_performed": isMutation, "snapshot_available": false, "retry_safe": false]
        }
        let frame: ComputerFrame
        do { frame = try backend.snapshot(application: refreshed) }
        catch {
            retained = nil
            if isMutation {
                return ["operation": "computer_control", "status": "action_accepted_snapshot_unavailable",
                    "action_performed": true, "ui_verified": false, "retry_safe": false]
            }
            throw error
        }
        let snapshotID = UUID().uuidString.lowercased()
        let bounded = ComputerFrame(nodes: Array(frame.nodes.prefix(128)), partial: frame.partial || frame.nodes.count > 128)
        retained = Retained(id: snapshotID, workspaceID: id, application: refreshed, capturedAt: now(), frame: bounded)
        return ["operation": "computer_control", "status": "snapshot_returned",
            "action_performed": isMutation, "bundle_id": bundle, "pid": refreshed.pid,
            "snapshot_id": snapshotID, "snapshot_ttl_seconds": 15,
            "frontmost": refreshed.frontmost, "partial": bounded.partial,
            "nodes": bounded.nodes.filter { !$0.secure }.map { node -> JSONObject in
                var row: JSONObject = ["element_id": node.id, "role": String(node.role.prefix(64)),
                    "title": String(node.title.prefix(160)), "actions": node.actions.filter { grant.actions.contains($0) }]
                if let value = node.value { row["value"] = String(value.prefix(256)) }
                if let parentID = node.parentID { row["parent_id"] = parentID }
                return row
            }, "content_is_untrusted": true, "screenshots_captured": false,
            "permission_prompted": false, "ui_verified": false,
            "scope": "approved_application_not_a_filesystem_sandbox"]
    }
}
