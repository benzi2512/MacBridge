import SwiftUI

enum ObserverStyle {
    static let accent = MBPalette.brandBlue
    static let running = MBPalette.running
    static let waiting = MBPalette.waiting
    static let idle = MBPalette.idle
    static let failure = MBPalette.failed
    static let added = MBPalette.cyanHighlight
    static let removed = MBPalette.failed
}

/// Renders bounded owner data. Does not issue requests, parse test success from
/// logs, collect chat text, or persist output. Technical metadata starts folded.
struct ObserverDetailView: View {
    let raw: [String: Any]
    let kind: DetailPresentation.Kind
    let message: String
    let page: OutputPage?
    let connected: Bool
    var activity: ActivityItem? = nil
    var work: WorkActivity? = nil
    var activityWork: WorkActivity? = nil
    var context: ContextActivity? = nil
    var activityContext: ContextActivity? = nil
    @Environment(\.observerTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let work {
                Label(work.title, systemImage: "square.stack.3d.up").font(.headline)
                Text(work.status).font(.system(size: 13 * textScale, weight: .medium))
                Text(work.explanation).font(.system(size: 13 * textScale)).foregroundStyle(.secondary)
                detailField("Workspace", work.workspaceName)
                detailField("Chat label", work.chatLabel ?? "Not supplied")
                Text("Caller-supplied label · not a verified chat identity.").font(.caption2).foregroundStyle(.secondary)
                detailField("Recorded activity", "\(work.callCount) calls · \(work.errorCount) errors · \(work.visibleChildren.count) recent steps shown")
                if let updated = work.updated {
                    HStack { Text("Last update"); Text(updated, style: .date); Text(updated, style: .time) }
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let latest = work.currentAction {
                    detailField(work.executing && latest.presentation.running ? "Current action" : "Latest action", latest.title)
                    ForEach(DetailPresentation.fields(latest.origin, kind: .event)) { field in
                        detailField(field.label, field.value)
                    }
                }
                Text("Select an individual job to inspect its output or cancel it. Selecting this task does not select all its jobs.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let context {
                Label(context.title, systemImage: "folder").font(.headline)
                Text(context.status).font(.system(size: 13 * textScale, weight: .medium))
                Text("Grouped from recorded folders and file targets. Several chats using this project can appear together; this is not a verified chat or task identity.")
                    .font(.system(size: 13 * textScale)).foregroundStyle(.secondary)
                detailField("Folder", context.rootPath)
                detailField("Workspace", context.workspaceName)
                detailField("Activity", "\(context.children.count) retained entries · \(context.issueCount) issues")
                if let latest = context.currentAction { detailField("Latest action", latest.title) }
                Text("Recent stays in Active for two minutes after the last MB action. It does not mean a process is running or the chat has finished. Select a specific action for its files, command or output.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let activity {
                Label(activity.title, systemImage: activity.presentation.icon).font(.headline)
                    .foregroundStyle(activity.presentation.failed ? ObserverStyle.failure : Color.primary)
                Text(activity.presentation.subtitle).font(.caption).foregroundStyle(.secondary)
                Text(activity.explanation).font(.system(size: 13 * textScale))
                detailField("Workspace", activity.workspaceName)
                if let activityWork {
                    detailField("Task", activityWork.title)
                    detailField("Chat label", activityWork.chatLabel ?? "Not supplied")
                } else if let activityContext {
                    detailField("Context", activityContext.title + " · inferred")
                } else { detailField("Task", "Ungrouped · no parent task supplied") }
                if activity.kind == .job {
                    if let tool = activity.origin["tool"] as? String { detailField("Started by", tool) }
                    if let subject = activity.subject { detailField("Working folder", subject) }
                    detailField("Job", activity.raw["task_id"] as? String ?? "Unknown")
                    ForEach(DetailPresentation.fields(activity.origin, kind: .event).filter {
                        $0.label.hasPrefix("Requested") || $0.label == "Preview" || $0.label == "Target scope"
                    }) { field in detailField(field.label, field.value) }
                }
                if let started = activity.started {
                    HStack { Text("Started"); Text(started, style: .date); Text(started, style: .time) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if kind == .event, !raw.isEmpty {
                let activity = ActivityPresentation.event(raw, connected: connected)
                Label(activity.title, systemImage: activity.icon).font(.headline)
                    .foregroundStyle(activity.failed ? ObserverStyle.failure : Color.primary)
                Text(activity.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(DetailPresentation.fields(raw, kind: kind).filter {
                !(activity?.kind == .job && $0.label == "Job")
            }) { field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(field.value).font(.system(size: 13 * textScale)).textSelection(.enabled)
                        .foregroundStyle(field.label == "Error" ? ObserverStyle.failure : Color.primary)
                }
            }
            if let page {
                if page.lostBytes > 0 {
                    Label("Owner discarded \(page.lostBytes) earlier bytes. Showing retained output.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(ObserverStyle.waiting)
                }
                output("Standard output", text: page.stdout, range: page.stdoutRange)
                output("Standard error", text: page.stderr, range: page.stderrRange)
                Text("This is a non-consuming snapshot, not a live stream. Use Read newer output to update. Exit 0 alone does not prove tests or your goal passed.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if kind == .event, let result = raw["result"] as? [String: Any] {
                ForEach(["stdout", "stderr"], id: \.self) { stream in
                    if let content = result[stream] as? String, !content.isEmpty {
                        output(stream == "stdout" ? "Output receipt preview" : "Error-stream receipt preview",
                               text: content, range: result[stream + "_preview_truncated"] as? Bool == true
                                   ? "Tail only · earlier output omitted" : "Retained tool-return preview")
                    }
                }
                Text("A tool receipt is not a full result archive. Batch item outcomes and file contents may not be retained here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                if kind == .change {
                    Text("File comparison").font(.headline)
                    diffText(message).font(.system(size: 12 * textScale, design: .monospaced)).textSelection(.enabled)
                } else { Text(message).font(.system(size: 13 * textScale)).textSelection(.enabled) }
            }
            if raw.isEmpty && message.isEmpty && activity == nil && work == nil && context == nil {
                Label("Select a task, action, job or file change", systemImage: "sidebar.right").font(.headline)
                Text("Inspect real output and receipts here. No conversation transcript is collected.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if raw.isEmpty && message.isEmpty && activity != nil {
                Text("Recorded activity shown. Use Refresh to inspect this job's retained output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !raw.isEmpty {
                DisclosureGroup("Technical metadata") {
                    Text(ObserverModel.pretty(DetailPresentation.metadata(work?.raw ?? raw)))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detailField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13 * textScale)).textSelection(.enabled)
        }
    }

    private func output(_ title: String, text: String, range: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(range).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text(text.isEmpty ? "No bytes in this page." : text)
                .font(.system(size: 12 * textScale, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffText(_ text: String) -> Text {
        // +/- markers carry meaning without color. Bounded input, linear work.
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().reduce(Text("")) { display, item in
            let line = String(item.element)
            let color: Color = line.hasPrefix("+") ? ObserverStyle.added
                : line.hasPrefix("-") ? ObserverStyle.removed : .primary
            return display + Text((item.offset == 0 ? "" : "\n") + line).foregroundColor(color)
        }
    }
}
