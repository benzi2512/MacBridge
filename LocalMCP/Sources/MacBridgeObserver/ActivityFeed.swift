import Foundation

/// Joins retained tool receipts to current jobs by the owner's task ID, never by
/// folder or guessed chat identity. Pure presentation; no extra reads or storage.
struct ActivityItem: Identifiable {
    enum Kind { case call, job }
    let id: String
    let kind: Kind
    let raw: [String: Any]
    let origin: [String: Any]
    let presentation: ActivityPresentation
    let workspaceID: String?
    let workspaceName: String
    let issue: Bool

    var workID: String? { raw["work_id"] as? String ?? origin["work_id"] as? String }
    var detail: [String: Any] { origin["detail"] as? [String: Any] ?? [:] }
    var commandPreview: String? { (detail["command_preview"] as? String).map { String($0.prefix(512)) } }
    var subject: String? { origin["path"] as? String ?? origin["cwd"] as? String }
    var title: String {
        if let commandPreview, !commandPreview.isEmpty {
            return presentation.title + " · " + commandPreview
        }
        guard let subject, !subject.isEmpty else { return presentation.title }
        let name = (subject as NSString).lastPathComponent
        return presentation.title + " · " + String((name.isEmpty ? subject : name).prefix(100))
    }
    var context: String {
        var parts = [workspaceName]
        if let subject, !subject.isEmpty { parts.append(String(subject.prefix(512))) }
        return parts.joined(separator: " · ")
    }
    var explanation: String {
        let tool = origin["tool"] as? String ?? ""
        if tool == "command_run" || tool == "command_start" {
            if commandPreview != nil { return "The requested command is shown with sensitive arguments hidden. Its result and process state are reported separately." }
            return "Runs a program in the shown folder. This owner does not retain the command or its arguments for the observer."
        }
        if tool == "git_status" { return "Checks changed, staged and untracked files in this repository." }
        if tool == "git_diff" { return "Reads code changes in this repository; it does not edit files." }
        if tool == "process_wait" { return "Waits for an existing process. The waiting call and the process have separate lifetimes." }
        if tool.hasPrefix("process_output") { return "Reads output from an existing process; this is not a new build or command." }
        if kind == .job && origin.isEmpty { return "Background process retained by this owner. Its starting call is no longer in the recent history." }
        return "Observed MacBridge action and its recorded target. This is not the chat's overall task or completion status."
    }
    var started: Date? {
        let value = raw[kind == .job ? "started_milliseconds" : "started_ms"] as? NSNumber
        guard let value, value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue / 1000)
    }
    var finished: Date? {
        let value = raw[kind == .job ? "ended_milliseconds" : "finished_ms"] as? NSNumber
        guard let value, value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue / 1000)
    }
    func matches(query: String, filter: ActivityPresentation.Filter) -> Bool {
        if filter == .running && !presentation.running { return false }
        if filter == .issues && !issue { return false }
        let result = raw["result"] as? [String: Any] ?? [:]
        // Search only the owner's bounded, redacted detail, never raw arguments.
        let text = ([title, context, presentation.subtitle, id, commandPreview ?? ""]
            + Array(((detail["targets"] as? [String]) ?? []).prefix(3))
            + ["tool", "task_id", "transaction_id"].compactMap { origin[$0] as? String }
            + ["error", "task_id", "transaction_id"].compactMap { result[$0] as? String }).joined(separator: " ")
        return query.prefix(256).split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }
}

struct ActivityFeed {
    let items: [ActivityItem]
    let groups: [WorkActivity]
    let contextGroups: [ContextActivity]
    let ungroupedItems: [ActivityItem]
    let jobsCurrent: Bool
    let connected: Bool

    init(history: [[String: Any]], jobs: [[String: Any]], workItems: [[String: Any]] = [], workspaces: [[String: Any]],
         workspace: String, connected: Bool, stale: Bool, now: Date = Date()) {
        self.connected = connected
        jobsCurrent = connected && !stale
        var names: [String: String] = [:]
        for row in workspaces {
            if let id = row["workspace_id"] as? String, let name = row["display_name"] as? String {
                names[id] = String(name.prefix(100))
            }
        }
        func name(_ id: String?) -> String {
            guard let id else { return "Workspace not retained" }
            return names[id] ?? "Workspace " + String(id.prefix(8))
        }
        // Only the starting receipt supplies provenance. A later poll might
        // belong to a different caller and must not relabel the job's origin.
        var origins: [String: [String: Any]] = [:]
        for row in history {
            let tool = row["tool"] as? String ?? ""
            let result = row["result"] as? [String: Any] ?? [:]
            if (tool == "command_start" || tool == "command_run" || tool.hasPrefix("git_")),
               let id = result["task_id"] as? String, !id.isEmpty, origins[id] == nil {
                origins[id] = row
            }
        }
        // Explicit work/job associations survive receipt eviction. Never infer
        // task ownership from workspace, later status calls or chat-looking
        // labels. Separate display-only contexts are built after this join.
        var workByJob: [String: [String: Any]] = [:]
        var workByID: [String: [String: Any]] = [:]
        for work in workItems {
            guard let id = work["work_id"] as? String, !id.isEmpty else { continue }
            if workByID[id] == nil { workByID[id] = work }
            for jobID in work["job_ids"] as? [String] ?? [] where workByJob[jobID] == nil {
                workByJob[jobID] = work
            }
        }
        var rows: [ActivityItem] = []
        for job in jobs {
            guard let id = job["task_id"] as? String, !id.isEmpty else { continue }
            var origin = origins[id] ?? [:]
            if origin["work_id"] == nil { origin["work_id"] = workByJob[id]?["work_id"] }
            let workspaceID = job["workspace_id"] as? String ?? origin["workspace_id"] as? String
                ?? workByJob[id]?["workspace_id"] as? String
            guard workspace == "all" || workspaceID == workspace else { continue }
            let running = connected && !stale && job["running"] as? Bool == true
                && job["cancelled"] as? Bool != true && job["timed_out"] as? Bool != true
            let unknown = !connected || stale || job["running"] == nil
                || (job["running"] as? Bool == false && job["exit_code"] == nil
                    && job["cancelled"] as? Bool != true && job["timed_out"] as? Bool != true)
            let synthetic: [String: Any] = ["tool": origin["tool"] ?? "command_start",
                "state": "returned", "result": job]
            let receipt = ActivityPresentation.event(synthetic, connected: connected)
            var status = unknown ? "Unknown · last snapshot is not current"
                : running ? "Running now" : receipt.subtitle
            if job["running"] as? Bool == false && job["exit_code"] == nil
                && job["cancelled"] as? Bool != true && job["timed_out"] as? Bool != true {
                status = "Unknown · exit status unavailable"
            }
            if let out = job["stdout_total_bytes"] as? Int, let err = job["stderr_total_bytes"] as? Int {
                status += " · stdout \(max(0, out)) B / stderr \(max(0, err)) B"
            }
            let tool = origin["tool"] as? String ?? ""
            let title = tool.hasPrefix("git_") ? ActivityPresentation.event(origin, connected: connected).title : "Background command"
            rows.append(ActivityItem(id: "job:" + id, kind: .job, raw: job, origin: origin,
                presentation: ActivityPresentation(title: title, subtitle: status, icon: "terminal",
                    running: running, failed: !unknown && receipt.failed, partial: false),
                workspaceID: workspaceID, workspaceName: name(workspaceID),
                issue: unknown || receipt.failed || job["cancelled"] as? Bool == true || job["timed_out"] as? Bool == true))
        }
        for event in history {
            guard let id = event["id"] as? String, !id.isEmpty else { continue }
            let declaredWork = (event["work_id"] as? String).flatMap { workByID[$0] }
            let workspaceID = event["workspace_id"] as? String ?? declaredWork?["workspace_id"] as? String
            guard workspace == "all" || workspaceID == workspace else { continue }
            let shown = ActivityPresentation.event(event, connected: connected)
            var status = shown.subtitle
            if let path = event["path"] as? String ?? event["cwd"] as? String, !path.isEmpty {
                let suffix = " · " + String(path.prefix(160))
                if status.hasSuffix(suffix) { status.removeLast(suffix.count) }
            }
            rows.append(ActivityItem(id: "event:" + id, kind: .call, raw: event, origin: event,
                presentation: ActivityPresentation(title: shown.title, subtitle: status, icon: shown.icon,
                    running: shown.running, failed: shown.failed, partial: shown.partial),
                workspaceID: workspaceID, workspaceName: name(workspaceID),
                issue: ActivityPresentation.matches(event, query: "", filter: .issues, connected: connected)))
        }
        items = rows
        var seenWorks = Set<String>()
        groups = workItems.compactMap { raw in
            guard let id = raw["work_id"] as? String, !id.isEmpty, seenWorks.insert(id).inserted else { return nil }
            let children = rows.filter { $0.workID == id }
            let workspaceID = raw["workspace_id"] as? String
            guard workspace == "all" || workspaceID == workspace || !children.isEmpty else { return nil }
            return WorkActivity(raw: raw, children: children, workspaceName: name(workspaceID),
                                connected: connected, snapshotStale: stale)
        }.sorted {
            if $0.active != $1.active { return $0.active }
            return $0.updatedMilliseconds > $1.updatedMilliseconds
        }
        let grouped = Set(groups.map(\.workID))
        let withoutParent = rows.filter { $0.workID.map { !grouped.contains($0) } ?? true }
        contextGroups = ContextActivity.make(items: withoutParent, workspaces: workspaces,
                                             connected: connected, stale: stale, now: now)
        let contextual = Set(contextGroups.flatMap { $0.children.map(\.id) })
        ungroupedItems = withoutParent.filter { !contextual.contains($0.id) }
    }

    func matching(query: String = "", filter: ActivityPresentation.Filter = .all) -> [ActivityItem] {
        items.filter { $0.matches(query: query, filter: filter) }
    }
    var runningCount: Int { items.filter { $0.presentation.running }.count }
    func matchingGroups(query: String = "", filter: ActivityPresentation.Filter = .all) -> [WorkActivity] {
        groups.filter { $0.matches(query: query, filter: filter) }
    }
    func matchingUngrouped(query: String = "", filter: ActivityPresentation.Filter = .all) -> [ActivityItem] {
        ungroupedItems.filter { $0.matches(query: query, filter: filter) }
    }
    func matchingContexts(query: String = "", filter: ActivityPresentation.Filter = .all) -> [ContextActivity] {
        contextGroups.filter { $0.matches(query: query, filter: filter) }
    }
    func displayCount(query: String = "", filter: ActivityPresentation.Filter = .all) -> Int {
        matchingGroups(query: query, filter: filter).count + matchingContexts(query: query, filter: filter).count
            + matchingUngrouped(query: query, filter: filter).count
    }
    func emptyMessage(filter: ActivityPresentation.Filter, query: String) -> String {
        if !query.isEmpty { return "No activity matches this search in the selected workspace. Clear the search or select All observed activity." }
        if filter == .running {
            if !jobsCurrent { return "Current process state is unavailable. View All for the last known activity; do not assume the jobs stopped." }
            return "No active task or ungrouped process is recorded here. Short ungrouped calls move to All after returning. ChatGPT may still be preparing its next step."
        }
        return filter == .issues ? "No issues in the retained activity for this workspace." : "No retained activity for this workspace yet."
    }
}
