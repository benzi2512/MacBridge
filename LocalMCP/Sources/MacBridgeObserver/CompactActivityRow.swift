import SwiftUI

/// Exactly two visual lines. Full metadata remains available in Details/help.
struct CompactRowContent {
    let title: String
    let status: String
    let subtitle: String
    let icon: String
    let active: Bool
    let failed: Bool
    let help: String
    static let maximumVisualLines = 2

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
    init(unavailableItemID: String) {
        title = "No longer retained"; status = "Unavailable"
        subtitle = "Show latest to update this reading view"
        icon = "clock.badge.exclamationmark"; active = false; failed = false
        help = "This held position is no longer available on the owner. No saved payload or usable handle is retained. " + unavailableItemID
    }
    init(item: ActivityItem) {
        title = Self.oneLine(item.presentation.title)
        let result = item.kind == .job ? item.raw : item.raw["result"] as? [String: Any] ?? [:]
        if item.presentation.running { status = "Running" }
        else if result["cancelled"] as? Bool == true { status = "Cancelled" }
        else if result["timed_out"] as? Bool == true { status = "Timed out" }
        else if item.presentation.failed { status = "Failed" }
        else if item.presentation.partial { status = "Partial" }
        else if item.presentation.subtitle.hasPrefix("Unknown") { status = "Unknown" }
        else if let code = result["exit_code"] as? Int { status = "Exit \(code)" }
        else if result["running"] as? Bool == true { status = "Started" }
        else { status = "Returned" }
        let target = item.commandPreview ?? item.subject ?? (item.detail["targets"] as? [String])?.first ?? ""
        subtitle = [target, item.workspaceName, Self.time(item.started)].filter { !$0.isEmpty }.map(Self.oneLine).joined(separator: " · ")
        icon = item.presentation.icon; active = item.presentation.running; failed = item.presentation.failed
        help = [item.title, item.presentation.subtitle, item.context,
                item.started.map { "Started: " + $0.formatted() } ?? "",
                item.finished.map { "Finished: " + $0.formatted() } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    init(context: ContextActivity) {
        title = Self.oneLine(context.title)
        status = context.status
        subtitle = ["Inferred", context.currentAction?.title ?? context.workspaceName]
            .filter { !$0.isEmpty }.map(Self.oneLine).joined(separator: " · ")
        icon = context.executing ? "play.circle" : "folder"
        active = context.executing; failed = context.issueCount > 0
        help = [context.title, context.status, "Grouped from recorded folders and file targets, not a verified chat identity.",
                context.rootPath, "\(context.children.count) retained entries · \(context.issueCount) issues",
                "Recent contexts stay in Active for two minutes after the last MB action. Recent does not mean a process is still running."].joined(separator: "\n")
    }
    init(work: WorkActivity) {
        title = Self.oneLine(work.title)
        if !work.connected { status = "Offline" }
        else if work.stale { status = "Update overdue" }
        else {
            switch work.phase {
            case "executing": status = "Working"
            case "waiting_next_step": status = "Next step"
            case "waiting_user": status = "Needs you"
            case "completed": status = "Completed"
            case "failed": status = "Failed"
            default: status = "Unknown"
            }
        }
        subtitle = [work.chatLabel ?? "", work.workspaceName, work.currentAction?.title ?? ""]
            .filter { !$0.isEmpty }.map(Self.oneLine).joined(separator: " · ")
        icon = work.executing ? "play.circle" : work.active ? "clock" : "checkmark.circle"
        active = work.executing; failed = work.state == "failed"
        help = [work.title, work.status, "Chat label: " + (work.chatLabel ?? "Not supplied"),
                work.workspaceName, "\(work.callCount) calls · \(work.errorCount) errors · \(work.failureReportCount) reports",
                work.updated.map { "Updated: " + $0.formatted() } ?? "", work.explanation].joined(separator: "\n")
    }
}

struct CompactActivityRow: View {
    let content: CompactRowContent
    @Environment(\.observerTextScale) private var textScale
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: content.icon)
                    .foregroundStyle(content.failed ? ObserverStyle.failure : content.active ? ObserverStyle.accent : .secondary)
                    .frame(width: 16)
                Text(content.title).font(.system(size: 13 * textScale)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(content.status).font(.system(size: 11 * textScale)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Text(content.subtitle).font(.system(size: 11 * textScale)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).padding(.leading, 24)
        }.padding(.vertical, 4)
            .help(content.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.help)
    }
}
