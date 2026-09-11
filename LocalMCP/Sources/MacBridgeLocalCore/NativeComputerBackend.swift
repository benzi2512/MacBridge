import AppKit
import ApplicationServices
import Foundation

/// Native Accessibility is opt-in and user-facing. No AppleScript, CGEvent,
/// browser-profile access, arbitrary JS or display recording fallback.
final class NativeComputerBackend: ComputerBackend {
    var trusted: Bool { AXIsProcessTrusted() }

    func application(bundleID: String) throws -> ComputerApplication {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        guard matches.count == 1, let app = matches.first, let launched = app.launchDate else {
            throw LocalMCPError.operationFailed("approved application must already be running as one unambiguous process")
        }
        return ComputerApplication(bundleID: bundleID, pid: app.processIdentifier,
            launchStamp: launched.timeIntervalSince1970, frontmost: app.isActive)
    }

    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }

    private func strings(_ element: AXUIElement) -> (String, String, String) {
        (value(element, kAXRoleAttribute) as? String ?? "",
         value(element, kAXSubroleAttribute) as? String ?? "",
         value(element, kAXTitleAttribute) as? String ?? "")
    }

    func snapshot(application: ComputerApplication) throws -> ComputerFrame {
        let root = AXUIElementCreateApplication(application.pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        var queue: [(element: AXUIElement, parentID: Int?)] = [(root, nil)]
        var visited: [AXUIElement] = []
        var nodes: [ComputerNode] = []
        var partial = false
        var index = 0
        while index < queue.count, nodes.count < 128 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { partial = true; break }
            let (element, parentID) = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            guard AXUIElementSetMessagingTimeout(element, 0.04) == .success else { partial = true; continue }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == application.pid else { partial = true; continue }
            let (role, subrole, title) = strings(element)
            guard !role.isEmpty else { partial = true; continue }
            // Never read secure values or descend into secure elements.
            if role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole { continue }
            var names: CFArray?
            var actions: [String] = []
            if AXUIElementCopyActionNames(element, &names) == .success,
               (names as? [String])?.contains(kAXPressAction) == true { actions.append("press") }
            var settable = DarwinBoolean(false)
            if [kAXTextFieldRole, kAXTextAreaRole].contains(role),
               AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue { actions.append("set_value") }
            // AX may return a large application value internally. Do not ask
            // for document/text-area contents; direct MB file tools are better.
            let text: String? = [kAXButtonRole, kAXCheckBoxRole, kAXStaticTextRole].contains(role)
                ? value(element, kAXValueAttribute) as? String : nil
            nodes.append(ComputerNode(id: nodes.count, role: role, title: String(title.prefix(160)),
                value: text.map { String($0.prefix(256)) }, actions: actions, secure: false, handle: element, parentID: parentID))
            let currentID = nodes.count - 1
            var children: CFArray?
            let available = 128 - queue.count
            if available > 0 {
                var count = 0
                if AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success, count > 0 {
                    if count > available { partial = true }
                    if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(count, available), &children) == .success {
                        queue.append(contentsOf: ((children as? [AXUIElement]) ?? []).map { ($0, currentID) })
                    } else { partial = true }
                }
            } else { partial = true }
        }
        guard !nodes.isEmpty else { throw LocalMCPError.operationFailed("application did not provide an accessible UI tree") }
        return ComputerFrame(nodes: nodes, partial: partial || index < queue.count)
    }

    func perform(action: String, application app: ComputerApplication, node: ComputerNode?, text: String?) throws {
        guard trusted, try application(bundleID: app.bundleID).sameProcess(as: app) else {
            throw LocalMCPError.operationFailed("application or Accessibility permission changed")
        }
        if action == "focus" {
            guard let running = NSRunningApplication(processIdentifier: app.pid),
                  running.activate(options: [.activateIgnoringOtherApps]) else {
                throw LocalMCPError.operationFailed("application did not accept focus")
            }
            return
        }
        guard try application(bundleID: app.bundleID).frontmost,
              let node, let raw = node.handle, CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else {
            throw LocalMCPError.operationFailed("application is no longer frontmost or element is unavailable")
        }
        let element = raw as! AXUIElement
        guard AXUIElementSetMessagingTimeout(element, 0.25) == .success else {
            throw LocalMCPError.operationFailed("cannot set bounded Accessibility timeout")
        }
        var pid: pid_t = 0
        let (role, subrole, title) = strings(element)
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.pid,
              role == node.role, String(title.prefix(160)) == node.title,
              subrole != kAXSecureTextFieldSubrole, role != kAXSecureTextFieldSubrole else {
            throw LocalMCPError.conflict("element identity changed before action")
        }
        let result: AXError
        if action == "press" { result = AXUIElementPerformAction(element, kAXPressAction as CFString) }
        else if action == "set_value", [kAXTextFieldRole, kAXTextAreaRole].contains(role), let text {
            result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        } else { throw LocalMCPError.invalidRequest("unsupported element action") }
        guard result == .success else { throw LocalMCPError.operationFailed("Accessibility action was not confirmed") }
    }
}
