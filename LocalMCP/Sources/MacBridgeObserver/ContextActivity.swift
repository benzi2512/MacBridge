import Foundation

/// A presentation-only folder context inferred from retained paths. It may
/// contain multiple chats and is never a work ID, chat identity or permission.
/// No filesystem lookup, transcript parsing, timer, storage or runtime mutation.
struct ContextActivity: Identifiable {
    static let recentWindowSeconds: TimeInterval = 120
    let id: String
    let title: String
    let rootPath: String
    let workspaceID: String?
    let workspaceName: String
    let children: [ActivityItem]
    let updatedMilliseconds: Double
    let executing: Bool
    let recent: Bool
    let connected: Bool
    let stale: Bool

    var active: Bool { executing || recent }
    var issueCount: Int { visibleChildren.filter(\.issue).count }
    var status: String {
        if !connected { return "Offline" }
        // Busy snapshots can retain stale jobs but contain a current live call.
        if executing { return "Running" }
        if stale { return "Snapshot not current" }
        return recent ? "Recent" : "Idle"
    }
    var visibleChildren: [ActivityItem] {
        let jobs = Set(children.filter { $0.kind == .job }.compactMap { $0.raw["task_id"] as? String })
        return children.filter { child in
            guard child.kind == .call else { return true }
            let tool = child.origin["tool"] as? String ?? ""
            guard tool == "command_start" || tool == "command_run" || tool.hasPrefix("git_") else { return true }
            let result = child.raw["result"] as? [String: Any] ?? [:]
            return (result["task_id"] as? String).map { !jobs.contains($0) } ?? true
        }.sorted {
            if $0.presentation.running != $1.presentation.running { return $0.presentation.running }
            let lhs = $0.started ?? .distantPast, rhs = $1.started ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }
    var currentAction: ActivityItem? { visibleChildren.first }

    func matches(query: String, filter: ActivityPresentation.Filter) -> Bool {
        if filter == .ungrouped { return false }
        if filter == .running && !active { return false }
        if filter == .issues && issueCount == 0 { return false }
        let text = [title, rootPath, workspaceName, status].joined(separator: " ")
        let words = query.prefix(256).split(whereSeparator: { $0.isWhitespace })
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
            || children.contains { $0.matches(query: query, filter: .all) }
    }

    static func make(items: [ActivityItem], workspaces: [[String: Any]], connected: Bool,
                     stale: Bool, now: Date) -> [ContextActivity] {
        let roots = workspaces.prefix(64).compactMap { row -> [String]? in
            guard let path = row["root_path"] as? String, let parts = components(path),
                  usefulFolder(parts) else { return nil }
            return parts
        }.sorted { $0.count > $1.count }
        let bounded = Array(items.prefix(512))
        // Polls have no target path. Associate their display context only with
        // an exact job ID from a retained start receipt, never with a time or
        // command match. This does not copy any provenance or task ownership.
        var rootsByJob: [String: String] = [:]
        var conflictingJobs = Set<String>()
        for item in bounded where item.workID == nil {
            let tool = item.origin["tool"] as? String ?? ""
            guard tool == "command_start" || tool == "command_run" || tool.hasPrefix("git_"),
                  let context = root(for: item, registered: roots) else { continue }
            let result = item.origin["result"] as? [String: Any] ?? [:]
            guard let jobID = result["task_id"] as? String, !jobID.isEmpty, jobID.utf8.count <= 256 else { continue }
            if let previous = rootsByJob[jobID], previous != context { conflictingJobs.insert(jobID) }
            rootsByJob[jobID] = context
        }
        var grouped: [String: (root: String, children: [ActivityItem])] = [:]
        for item in bounded {
            // Explicit tasks, including missing/evicted parents, are not inferred.
            guard item.workID == nil, item.workspaceID.map({ $0.utf8.count <= 256 }) ?? true else { continue }
            var context = root(for: item, registered: roots)
            let tool = item.origin["tool"] as? String ?? ""
            if context == nil, tool.hasPrefix("process_"), item.subject == nil,
               item.detail["cwd"] == nil, (item.detail["targets"] as? [String] ?? []).isEmpty,
               (item.detail["target_count"] as? Int ?? 0) == 0 {
                let result = item.origin["result"] as? [String: Any] ?? [:]
                if let jobID = item.origin["task_id"] as? String ?? result["task_id"] as? String,
                   !jobID.isEmpty, jobID.utf8.count <= 256,
                   !conflictingJobs.contains(jobID) { context = rootsByJob[jobID] }
            }
            guard let root = context else { continue }
            let workspace = item.workspaceID ?? ""
            // Length-delimited, not concatenation-ambiguous. A display key only.
            let id = "context:\(workspace.utf8.count):\(workspace)\(root.utf8.count):\(root)"
            grouped[id, default: (root, [])].children.append(item)
        }
        let nowMilliseconds = now.timeIntervalSince1970 * 1000
        return grouped.map { id, value in
            let children = value.children
            let updated = children.reduce(0.0) { latest, child in
                [child.started, child.finished].compactMap { $0?.timeIntervalSince1970 }
                    .filter { $0.isFinite && $0 > 0 }.reduce(latest) { max($0, $1 * 1000) }
            }
            let executing = connected && children.contains { $0.presentation.running }
            let recent = connected && !stale && updated > 0 && nowMilliseconds.isFinite
                && updated <= nowMilliseconds && nowMilliseconds - updated < recentWindowSeconds * 1000
            return ContextActivity(id: id, title: String((value.root as NSString).lastPathComponent.prefix(100)),
                rootPath: value.root, workspaceID: children.first?.workspaceID,
                workspaceName: children.first?.workspaceName ?? "Workspace not retained", children: children,
                updatedMilliseconds: updated, executing: executing, recent: recent, connected: connected, stale: stale)
        }.sorted {
            if $0.active != $1.active { return $0.active }
            if $0.updatedMilliseconds != $1.updatedMilliseconds { return $0.updatedMilliseconds > $1.updatedMilliseconds }
            return $0.id < $1.id
        }
    }

    private static let markers: Set<String> = ["projects", "repos", "plugins"]
    private static let directoryTools: Set<String> = ["directory_list", "directory_summary", "directory_find",
        "directory_create", "workspace_inspect", "file_search", "file_search_many"]

    private static func root(for item: ActivityItem, registered: [[String]]) -> String? {
        let detail = item.detail
        let targets = detail["targets"] as? [String] ?? []
        // An omitted fourth target could be a different context. Do not pick the
        // first visible target and claim that the whole batch belongs there.
        guard targets.count <= 3,
              (detail["target_count"] as? Int ?? targets.count) == targets.count else { return nil }
        let tool = item.origin["tool"] as? String ?? ""
        var paths: [(String, Bool)] = []
        if let subject = item.subject {
            paths.append((subject, item.origin["path"] == nil || directoryTools.contains(tool)))
        } else if let cwd = detail["cwd"] as? String {
            paths.append((cwd, true))
        }
        paths.append(contentsOf: targets.map { ($0, directoryTools.contains(tool)) })
        guard !paths.isEmpty else { return nil }
        var common: String?
        for (path, isDirectory) in paths {
            guard let parts = components(path) else { return nil }
            let candidate: [String]
            if let known = registered.first(where: { parts.starts(with: $0) }) {
                candidate = known
            } else if let marker = parts.indices.first(where: {
                markers.contains(parts[$0].lowercased()) && $0 + 1 < parts.count
            }) {
                candidate = Array(parts.prefix(marker + 2))
            } else {
                candidate = isDirectory ? parts : Array(parts.dropLast())
            }
            guard usefulFolder(candidate) else { return nil }
            let value = "/" + candidate.joined(separator: "/")
            if let common, common != value { return nil }
            common = value
        }
        return common
    }

    private static func components(_ path: String) -> [String]? {
        guard path.utf8.count <= 4096, path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("\\"), !path.contains("…"), !path.contains("["), !path.contains("]"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // A trailing directory slash does not change lexical identity. Keep
        // rejecting empty interior components rather than rewriting them.
        var normalized = path
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let parts = normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 128,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { return nil }
        return parts
    }

    private static func usefulFolder(_ parts: [String]) -> Bool {
        guard parts.count >= 2, let last = parts.last, !markers.contains(last.lowercased()) else { return false }
        if parts.count == 2 && (parts[0] == "Users" || parts[0] == "home") { return false }
        if parts == ["var", "root"] || parts == ["private", "var", "root"] { return false }
        return true
    }
}
