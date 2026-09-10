import Foundation
import SwiftUI

/// Serializes ordinary preview reads without dropping an explicit Open/Reveal.
/// A user action may supersede one read; its older response cannot clear the
/// replacement request or permit a second explicit action.
struct FilePreviewRequestGate {
    private(set) var requestID = UUID()
    private(set) var reading = false
    private(set) var actionID: UUID?

    mutating func beginAction() -> UUID? {
        guard actionID == nil else { return nil }
        let id = UUID(); actionID = id
        return id
    }

    mutating func finishAction(_ id: UUID) -> Bool {
        guard actionID == id else { return false }
        actionID = nil
        return true
    }

    mutating func beginRead(forAction id: UUID? = nil) -> UUID? {
        if let id {
            guard actionID == id else { return nil }
        } else {
            guard actionID == nil, !reading else { return nil }
        }
        requestID = UUID(); reading = true
        return requestID
    }

    mutating func finishRead(_ id: UUID) -> Bool {
        guard requestID == id else { return false }
        reading = false
        return true
    }

    mutating func invalidateRead() {
        requestID = UUID(); reading = false
    }
}

struct SelectedFilePreview {
    static let limit = 16_384
    let owner: String
    let eventID: String
    let workspaceID: String
    let path: String
    let version: String
    let text: String
    let totalBytes: Int
    let truncated: Bool

    init?(_ raw: [String: Any], expectedOwner: String, expectedEvent: String, previous: Self?) {
        guard raw["instance_id"] as? String == expectedOwner, raw["event_id"] as? String == expectedEvent,
              let workspace = raw["workspace_id"] as? String, !workspace.isEmpty,
              let path = raw["path"] as? String, Self.isLexicallyAbsoluteFilePath(path),
              let version = raw["version"] as? String, !version.isEmpty,
              let total = raw["total_bytes"] as? Int, total >= 0,
              let truncated = raw["truncated"] as? Bool,
              raw["preview_limit_bytes"] as? Int == Self.limit else { return nil }
        let content: String
        if raw["unchanged"] as? Bool == true {
            guard let previous, previous.owner == expectedOwner, previous.eventID == expectedEvent,
                  previous.path == path, previous.workspaceID == workspace, previous.version == version else { return nil }
            content = previous.text
        } else {
            guard let text = raw["text"] as? String, text.utf8.count <= Self.limit + 3 else { return nil }
            content = text
        }
        owner = expectedOwner; eventID = expectedEvent; workspaceID = workspace
        self.path = path; self.version = version; text = content; totalBytes = total; self.truncated = truncated
    }
    private static func isLexicallyAbsoluteFilePath(_ path: String) -> Bool {
        // The owner already verified the current file and its exact kernel path.
        // Foundation standardization can rewrite /private/tmp to /tmp on macOS;
        // reject ambiguous components without changing that confirmed identity.
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    var url: URL { URL(fileURLWithPath: path) }
    func matchesSelection(owner: String?, eventID: String?, connected: Bool, stale: Bool) -> Bool {
        connected && !stale && self.owner == owner && self.eventID == eventID
    }
}

struct SelectedFilePreviewView: View {
    let preview: SelectedFilePreview?
    let message: String
    let loading: Bool
    @Environment(\.observerTextScale) private var textScale
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("File preview", systemImage: "doc.text").font(.headline)
                Spacer()
                Text(loading ? "Updating…" : "Read-only").font(.caption).foregroundStyle(.secondary)
            }
            if let preview {
                Text(preview.path).font(.system(size: 11 * textScale)).lineLimit(1).truncationMode(.middle).help(preview.path)
                Text(preview.truncated ? "First 16 KiB of \(preview.totalBytes) bytes" : "\(preview.totalBytes) bytes · current file contents")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Updates use the file's stat metadata, not a whole-file content hash. Only this selected file's bounded text prefix is read. Open/Reveal revalidate its current path before the explicit action.")
                Text(preview.text.isEmpty ? "Empty file" : preview.text)
                    .font(.system(size: 12 * textScale, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ObserverTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var observerTextScale: CGFloat {
        get { self[ObserverTextScaleKey.self] }
        set { self[ObserverTextScaleKey.self] = newValue }
    }
}
