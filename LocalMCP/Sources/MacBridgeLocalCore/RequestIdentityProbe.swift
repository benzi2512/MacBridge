import CryptoKit
import Foundation

/// A short, explicitly enabled local diagnostic, NOT a chat identity resolver.
/// Never keeps arguments, headers, unknown key names or raw metadata values.
final class RequestIdentityProbe: @unchecked Sendable {
    static let maximumSamples = 32
    private let lock = NSLock()
    private var key = SymmetricKey(size: .bits256)
    private var enabled = false
    private var samples: [JSONObject] = []
    private static let identityNames: Set<String> = [
        "chatid", "conversationid", "threadid", "runid", "turnid", "sessionid", "requestid", "correlationid",
    ]
    private static let containers: Set<String> = ["context", "openai", "mcp", "client", "request", "session"]

    func start() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        key = SymmetricKey(size: .bits256)
        samples.removeAll(keepingCapacity: false)
        enabled = true
        return snapshotLocked()
    }

    func stop() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        enabled = false
        samples.removeAll(keepingCapacity: false)
        key = SymmetricKey(size: .bits256)
        return snapshotLocked()
    }

    func snapshot() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    func observe(tool: @autoclosure () -> String, metadata: Any?) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        var fields: [JSONObject] = []
        var omitted = 0
        var visited = 0
        func scan(_ object: JSONObject, prefix: String, depth: Int) {
            // Do not sort or walk an arbitrarily large dictionary for diagnostics.
            guard object.count <= 24 else { omitted += object.count; return }
            for (offset, entry) in object.sorted(by: { $0.key < $1.key }).enumerated() {
                guard visited < 64 else { omitted += object.count - offset; break }
                visited += 1
                let (name, value) = entry
                guard fields.count < 24, name.utf8.count <= 64 else { omitted += 1; continue }
                let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
                guard pieces.count == 1 || (pieces.count == 2
                    && ["openai", "mcp", "com.openai"].contains(String(pieces[0]))) else {
                    omitted += 1; continue
                }
                let leaf = String(pieces.last ?? "")
                let normalized = leaf.lowercased().replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                let path = prefix + name
                if Self.identityNames.contains(normalized) {
                    var field: JSONObject = ["field": path, "type": Self.kind(value)]
                    if let string = value as? String, !string.isEmpty, string.utf8.count <= 512 {
                        // Length-prefix the path and separate the value type to avoid
                        // cross-field/type aliasing. The fresh HMAC key never leaves RAM.
                        let data = Data("\(path.utf8.count):\(path):string:\(string)".utf8)
                        field["equality_tag"] = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
                            .map { String(format: "%02x", $0) }.joined()
                    }
                    fields.append(field)
                } else if depth < 2, Self.containers.contains(normalized), let nested = value as? JSONObject {
                    scan(nested, prefix: path + ".", depth: depth + 1)
                } else { omitted += 1 }
            }
        }
        if let object = metadata as? JSONObject { scan(object, prefix: "", depth: 0) }
        samples.append(["sequence": samples.count + 1, "tool": tool(),
            "meta_type": metadata.map(Self.kind) ?? "absent", "fields": fields,
            "omitted_fields": omitted, "inspected_nodes": visited])
        if samples.count == Self.maximumSamples { enabled = false }
    }

    private static func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is JSONObject { return "object" }
        if value is [Any] { return "array" }
        if value is NSNumber { return "number_or_boolean" }
        return "other"
    }

    private func snapshotLocked() -> JSONObject {
        ["enabled": enabled, "maximum_samples": Self.maximumSamples, "samples": samples,
         "scope": "local_diagnostic_not_chat_identity", "raw_values_retained": false,
         "coverage": "allowlisted_identity_names_only; omitted_fields_do_not_prove_identity_absent"]
    }
}
