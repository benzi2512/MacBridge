import SwiftUI

enum InspectorTab: String, CaseIterable { case activity = "Activity", file = "File", diff = "Diff", output = "Output" }

struct InspectorContentView: View {
    @ObservedObject var model: ObserverModel
    let tab: InspectorTab
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .file:
                HStack {
                    Toggle("Live", isOn: $model.filePreviewLive).toggleStyle(.switch).controlSize(.small)
                        .onChange(of: model.filePreviewLive) { live in
                            if live { Task { _ = await model.refreshFilePreview(force: true) } }
                        }
                    Spacer()
                    Button("Open in TextEdit") { Task { await model.openSelectedFile(reveal: false) } }
                        .disabled(!model.canOpenPreview)
                    Button("Reveal") { Task { await model.openSelectedFile(reveal: true) } }
                        .disabled(!model.canOpenPreview)
                }
                if model.selectedPreviewEventID != nil {
                    SelectedFilePreviewView(preview: model.selectedFilePreview, message: model.previewNotice, loading: model.previewLoading)
                } else {
                    Label("No file preview for this selection", systemImage: "doc")
                    Text("Select a retained single-file action. Binary, protected or ambiguous targets are not previewed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Saved file contents only — not unsaved editor keystrokes.").font(.caption2).foregroundStyle(.secondary)
            case .diff:
                if model.detailKind == .change, !model.detail.isEmpty {
                    ObserverDetailView(raw: model.detailResult, kind: .change, message: model.detail,
                                       page: nil, connected: model.connected)
                } else {
                    Label("No before/after snapshot selected", systemImage: "doc.badge.clock")
                    Text("Select a saved file change in Activity. A command receipt alone is not a file diff.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .output:
                if let page = model.outputPage {
                    output("Standard output", page.stdout)
                    output("Standard error", page.stderr)
                    if page.lostBytes > 0 { Text("Earlier output discarded: \(page.lostBytes) bytes").font(.caption) }
                    Text("Non-consuming snapshot. Use Read newer output; this view does not auto-scroll.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let receipt = model.detailResult["result"] as? [String: Any],
                          receipt["stdout"] is String || receipt["stderr"] is String {
                    output("Output receipt", receipt["stdout"] as? String ?? "")
                    output("Error receipt", receipt["stderr"] as? String ?? "")
                    Text("Bounded tool receipt; not a complete process archive.").font(.caption).foregroundStyle(.secondary)
                } else { Label("Select a job or command with retained output", systemImage: "terminal") }
            case .activity: EmptyView()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func output(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text.isEmpty ? "No retained bytes" : text).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
