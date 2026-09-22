import Foundation

/// A retained, caller-declared task. It is not a verified chat identity or a
/// claim that ChatGPT is thinking. No timer, process, polling or storage here.
struct WorkActivity: Identifiable {
    let raw: [String: Any]
    let children: [ActivityItem]
    let workspaceName: String
    let connected: Bool
    let snapshotStale: Bool

    var workID: String { raw["work_id"] as? String ?? "" }
    var id: String { "work:" + workID }
    var title: String { String((raw["title"] as? String ?? "Untitled task").prefix(160)) }
    var chatLabel: String? { (raw["chat_label"] as? String).map { String($0.prefix(160)) } }
    var state: String { raw["state"] as? String ?? "unknown" }
    var phase: String { raw["phase"] as? String ?? "unknown" }
    var active: Bool { state != "completed" && state != "failed" }
    var stale: Bool { snapshotStale || raw["stale"] as? Bool == true }
    var executing: Bool { connected && !stale && active && phase == "executing" }
    var issue: Bool { !connected || stale || state == "unknown" || state == "failed" || errorCount > 0 || childErrorCount > 0 || failureReportCount > 0 }
    var callCount: Int { max(0, raw["call_count"] as? Int ?? 0) }
    var errorCount: Int { max(0, raw["error_count"] as? Int ?? 0) }
    var childErrorCount: Int { max(0, raw["child_error_count"] as? Int ?? 0) }
    var failureReportCount: Int { max(0, raw["failure_report_count"] as? Int ?? 0) }
    var retainedFailureReportCount: Int {
        max(0, (raw["failure_reports"] as? [[String: Any]])?.count ?? 0)
    }
    var updatedMilliseconds: Double { (raw["updated_ms"] as? NSNumber)?.doubleValue ?? 0 }
    var updated: Date? { updatedMilliseconds > 0 && updatedMilliseconds.isFinite ? Date(timeIntervalSince1970: updatedMilliseconds / 1000) : nil }
    var phaseLabel: String {
        switch phase {
        case "executing": return "Executing MB work"
        case "waiting_next_step": return "Waiting for the next step"
        case "waiting_user": return "Waiting for you"
        case "completed": return "Marked complete by caller"
        case "failed": return "Marked failed by caller"
        default: return "Task state unavailable"
        }
    }
    var status: String {
        if !connected { return "Offline · last reported: " + phaseLabel }
        if snapshotStale { return "Snapshot not current · last reported: " + phaseLabel }
        if raw["stale"] as? Bool == true { return "Update overdue · last reported: " + phaseLabel }
        return phaseLabel
    }
    var explanation: String {
        if !connected || stale {
            return active
                ? "This task has not been marked complete. Its current progress cannot be confirmed from this snapshot."
                : "The last snapshot records the caller's finished task status. This is not a current connection or independent verification that the goal passed."
        }
        if failureReportCount > 0 {
            return "MacBridge recorded \(failureReportCount) automatic failure report\(failureReportCount == 1 ? "" : "s") for this task and retains the latest \(retainedFailureReportCount) in bounded owner memory. Technical metadata shows structured causes and next actions without control tokens or command output."
        }
        if phase == "waiting_next_step" { return "The last MB call has returned. The task stays active until its caller marks it complete; no process is implied by this waiting state." }
        if phase == "waiting_user" { return "The caller marked this task as waiting for your input. It remains in Active." }
        if !active { return "This is the caller's task status, not an independent verification that the goal passed." }
        return "Recorded MB actions are grouped by their explicit work ID. Other chat tools and private reasoning are not collected."
    }
    /// A job and its starting receipt describe the same action. Keep the job
    /// row (whose origin retains the receipt) instead of duplicating both rows.
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
            return ($0.started ?? .distantPast) > ($1.started ?? .distantPast)
        }
    }
    var currentAction: ActivityItem? {
        visibleChildren.first(where: { $0.presentation.running }) ?? visibleChildren.first
    }
    func matches(query: String, filter: ActivityPresentation.Filter) -> Bool {
        if filter == .ungrouped { return false }
        if filter == .running && !active { return false }
        if filter == .issues && !issue && !children.contains(where: { $0.issue }) { return false }
        let words = query.prefix(256).split(whereSeparator: { $0.isWhitespace })
        let text = [title, chatLabel ?? "", workspaceName, status, workID].joined(separator: " ")
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
            || children.contains { $0.matches(query: query, filter: .all) }
    }
}
