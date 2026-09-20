import CryptoKit
import Darwin
import Foundation

public typealias JSONObject = [String: Any]

public struct RecoveryTransactionReceipt: Sendable {
    public let instanceID: String
    public let transactionID: String
    public let transactionControlToken: String

    public init(
        instanceID: String,
        transactionID: String,
        transactionControlToken: String
    ) {
        self.instanceID = instanceID
        self.transactionID = transactionID
        self.transactionControlToken = transactionControlToken
    }

    var jsonObject: JSONObject {
        [
            "instance_id": instanceID,
            "transaction_id": transactionID,
            "transaction_control_token": transactionControlToken,
            "transaction_resolution": [
                "required_before_task_completion": true,
                "instruction": "Verify the intended current state, then accept to keep it or restore to roll it back. Do not leave a completed scheduled or normal-Chat mutation retained.",
                "keep_changes": [
                    "tool": "transaction_accept",
                    "arguments": [
                        "instance_id": instanceID,
                        "transaction_ids": [transactionID],
                        "transaction_control_tokens": [transactionControlToken],
                    ] as JSONObject,
                ] as JSONObject,
                "rollback": [
                    "tool": "transaction_restore",
                    "arguments": [
                        "transaction_id": transactionID,
                        "transaction_control_token": transactionControlToken,
                    ] as JSONObject,
                ] as JSONObject,
            ] as JSONObject,
        ]
    }
}

public enum LocalMCPError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case invalidConfiguration(String)
    case unknownWorkspace
    case invalidPath(String)
    case sensitivePathBlocked
    case notFound
    case wrongFileType
    case conflict(String)
    case casConflict(expectedSHA256: String, currentSHA256: String, modifiedMilliseconds: Int64)
    case createOnlyConflict(currentSHA256: String, modifiedMilliseconds: Int64)
    case limitExceeded(String)
    case unsupportedCommand
    case processNotFound
    case compensated(String)
    case partial(String)
    case recoveryRequired(String, recoveryTransactions: [RecoveryTransactionReceipt])
    case operationFailed(String)

    public var description: String {
        switch self {
        case .invalidRequest(let value): value
        case .invalidConfiguration(let value): "Invalid workspace configuration: \(value)"
        case .unknownWorkspace: "Unknown registered workspace."
        case .invalidPath(let value): "Invalid workspace path: \(value)"
        case .sensitivePathBlocked: "Sensitive credential path is blocked."
        case .notFound: "Path not found."
        case .wrongFileType: "Path has an unsupported file type."
        case .conflict(let value): "State conflict: \(value)"
        case .casConflict: "State conflict: expected_sha256 does not match current content"
        case .createOnlyConflict: "State conflict: create_only target already exists"
        case .limitExceeded(let value): "Limit exceeded: \(value)"
        case .unsupportedCommand: "Command is not in the local executable allowlist."
        case .processNotFound: "Unknown process task."
        case .compensated(let value): "Operation was compensated after starting: \(value)"
        case .partial(let value): "Operation completed only in part: \(value)"
        case .recoveryRequired(let value, _): value
        case .operationFailed(let value): "Operation failed: \(value)"
        }
    }

    /// Stable, machine-readable error metadata. The legacy string remains in
    /// tool results for older clients; new clients should branch on `code` and
    /// `operation_outcome`, never on localized prose.
    public var detail: JSONObject {
        let code: String
        let retrySafe: Bool
        let action: String
        let outcome: String
        switch self {
        case .invalidRequest: code = "INVALID_REQUEST"; retrySafe = false; action = "correct_request"; outcome = "not_started"
        case .invalidConfiguration: code = "INVALID_CONFIGURATION"; retrySafe = false; action = "repair_owner_configuration"; outcome = "not_started"
        case .unknownWorkspace: code = "WORKSPACE_NOT_FOUND"; retrySafe = false; action = "call_workspace_overview_or_workspace_resolve"; outcome = "not_started"
        case .invalidPath: code = "INVALID_PATH"; retrySafe = false; action = "correct_scoped_path"; outcome = "not_started"
        case .sensitivePathBlocked: code = "PERMISSION_DENIED"; retrySafe = false; action = "choose_noncredential_path"; outcome = "not_started"
        case .notFound: code = "PATH_NOT_FOUND"; retrySafe = true; action = "refresh_path_state"; outcome = "not_started"
        case .wrongFileType: code = "UNSUPPORTED_FILE_TYPE"; retrySafe = false; action = "choose_supported_regular_file_or_directory"; outcome = "not_started"
        case .conflict: code = "STATE_CONFLICT"; retrySafe = false; action = "read_current_state"; outcome = "not_started"
        case .casConflict: code = "CAS_CONFLICT"; retrySafe = false; action = "read_current_revision"; outcome = "not_started"
        case .createOnlyConflict: code = "CREATE_ONLY_CONFLICT"; retrySafe = false; action = "choose_new_path_or_read_current_revision"; outcome = "not_started"
        case .limitExceeded: code = "LIMIT_EXCEEDED"; retrySafe = false; action = "reduce_scope_or_release_retained_state"; outcome = "not_started"
        case .unsupportedCommand: code = "COMMAND_NOT_ALLOWED"; retrySafe = false; action = "call_command_list"; outcome = "not_started"
        case .processNotFound: code = "PROCESS_NOT_FOUND"; retrySafe = false; action = "call_process_list"; outcome = "not_started"
        case .compensated: code = "OPERATION_COMPENSATED"; retrySafe = false; action = "inspect_content_and_metadata_before_retry"; outcome = "compensated_content_and_mode_metadata_identity_may_differ"
        case .partial, .recoveryRequired: code = "OPERATION_PARTIAL"; retrySafe = false; action = "inspect_then_use_recovery_transaction"; outcome = "partially_completed_remaining_undo_retained"
        case .operationFailed: code = "OPERATION_FAILED"; retrySafe = false; action = "inspect_before_retry"; outcome = "unknown"
        }
        var value: JSONObject = [
            "code": code,
            "layer": "core",
            "message": description,
            "retry_safe": retrySafe,
            "recommended_action": action,
            "operation_outcome": outcome,
        ]
        if case .casConflict(let expected, let current, let modified) = self {
            value["expected_sha256"] = expected
            value["current_sha256"] = current
            value["current_modified_milliseconds"] = modified
        }
        if case .createOnlyConflict(let hash, let modified) = self {
            value["current_sha256"] = hash
            value["current_modified_milliseconds"] = modified
        }
        if case .recoveryRequired(_, let transactions) = self {
            value["recovery_transactions"] = transactions.map(\.jsonObject)
        }
        return value
    }
}

public func localErrorDetail(_ error: Error) -> JSONObject {
    if let error = error as? LocalMCPError { return error.detail }
    return [
        "code": "INTERNAL_ERROR", "layer": "core",
        "message": "Direct local operation failed.",
        "retry_safe": false, "recommended_action": "inspect_before_retry",
        "operation_outcome": "unknown",
    ]
}

public enum LocalJSON {
    public static func decodeObject(_ data: Data) throws -> JSONObject {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? JSONObject else {
            throw LocalMCPError.invalidRequest("JSON object required.")
        }
        return object
    }

    public static func encode(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw LocalMCPError.operationFailed("response is not valid JSON")
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

extension Dictionary where Key == String, Value == Any {
    public func requireOnlyKeys(_ allowed: Set<String>) throws {
        let unexpected = Set(keys).subtracting(allowed)
        guard unexpected.isEmpty else {
            throw LocalMCPError.invalidRequest(
                "Unexpected parameter(s): \(unexpected.sorted().joined(separator: ", "))."
            )
        }
    }

    public func requiredString(_ key: String, maximumBytes: Int = 65_536) throws -> String {
        guard let value = self[key] as? String, !value.isEmpty,
            value.utf8.count <= maximumBytes
        else { throw LocalMCPError.invalidRequest("Non-empty string required for \(key).") }
        return value
    }

    public func optionalString(_ key: String, maximumBytes: Int = 65_536) throws -> String? {
        guard let raw = self[key] else { return nil }
        guard let value = raw as? String, value.utf8.count <= maximumBytes else {
            throw LocalMCPError.invalidRequest("String required for \(key).")
        }
        return value
    }

    public func requiredBool(_ key: String) throws -> Bool {
        guard let value = self[key] as? Bool else {
            throw LocalMCPError.invalidRequest("Boolean required for \(key).")
        }
        return value
    }

    public func optionalBool(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard self[key] != nil else { return defaultValue }
        return try requiredBool(key)
    }

    public func optionalInt(
        _ key: String,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = self[key] else { return defaultValue }
        guard let number = raw as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            range.contains(number.intValue),
            NSNumber(value: number.intValue) == number
        else { throw LocalMCPError.invalidRequest("Bounded integer required for \(key).") }
        return number.intValue
    }

    public func requiredStringArray(
        _ key: String,
        maximumItems: Int = 128,
        maximumItemBytes: Int = 16_384
    ) throws -> [String] {
        guard let raw = self[key] as? [Any], raw.count <= maximumItems else {
            throw LocalMCPError.invalidRequest("Bounded string array required for \(key).")
        }
        var result: [String] = []
        for item in raw {
            guard let value = item as? String, value.utf8.count <= maximumItemBytes,
                !value.contains("\0")
            else {
                throw LocalMCPError.invalidRequest("Bounded string array required for \(key).")
            }
            result.append(value)
        }
        return result
    }
}

public enum LocalHash {
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)

    private static func hexadecimal(_ digest: SHA256.Digest) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hexadecimalDigits[Int(byte >> 4)])
            bytes.append(hexadecimalDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func sha256(_ data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    public static func sha256(fileAt url: URL, maximumBytes: Int64 = 2_000_000_000) throws -> String
    {
        try LocalFileReader.withFile(url: url) {
            try sha256(descriptor: $0, maximumBytes: maximumBytes)
        }
    }

    static func sha256(descriptor: Int32, maximumBytes: Int64 = 2_000_000_000) throws -> String {
        var hasher = SHA256()
        try LocalFileReader.chunks(descriptor: descriptor, maximumBytes: maximumBytes) {
            hasher.update(data: $0)
        }
        return hexadecimal(hasher.finalize())
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

// Mutable workspace data must never be memory-mapped or opened as a blocking
// special file. Both hashing and undo preimages use the same descriptor checks.
enum LocalFileReader {
    static func read(url: URL, maximumBytes: Int) throws -> Data {
        try withFile(url: url) { try read(descriptor: $0, maximumBytes: maximumBytes) }
    }

    // Caller retains ownership of the descriptor; pread leaves its offset intact.
    static func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        try chunks(descriptor: descriptor, maximumBytes: Int64(maximumBytes)) {
            result.append($0)
        }
        return result
    }

    static func withFile<T>(url: URL, body: (Int32) throws -> T) throws -> T {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        let result = try body(descriptor)
        var current = stat()
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
              sameVersion(opened, current) else {
            throw LocalMCPError.conflict("file changed while reading")
        }
        return result
    }

    static func chunks(descriptor: Int32, maximumBytes: Int64,
                       consume: (Data) throws -> Void) throws {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0 else { throw LocalMCPError.wrongFileType }
        guard maximumBytes >= 0, before.st_size <= maximumBytes else {
            throw LocalMCPError.limitExceeded("file read")
        }
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < before.st_size {
            let count = Int(min(off_t(buffer.count), before.st_size - offset))
            let received = Darwin.pread(descriptor, &buffer, count, offset)
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                throw LocalMCPError.conflict("file changed while reading")
            }
            try consume(Data(buffer.prefix(received)))
            offset += off_t(received)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameVersion(before, after) else {
            throw LocalMCPError.conflict("file changed while reading")
        }
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

func canonicalExistingPath(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
        let pointer = realpath(path, nil)
    else { throw LocalMCPError.invalidPath(path) }
    defer { free(pointer) }
    return String(cString: pointer)
}

func lstatValue(_ path: String) throws -> stat {
    var value = stat()
    guard lstat(path, &value) == 0 else {
        if errno == ENOENT { throw LocalMCPError.notFound }
        throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
    }
    return value
}

/// Selection and launch must use the same trust rule. Merely being executable
/// is not enough: an untrusted preferred tool must not hide a usable fallback.
func isTrustedSystemExecutable(_ path: String) -> Bool {
    guard let canonical = try? canonicalExistingPath(path),
        let metadata = try? lstatValue(canonical)
    else { return false }
    return hasTrustedSystemExecutableMetadata(metadata, executable: access(path, X_OK) == 0)
}

func hasTrustedSystemExecutableMetadata(_ metadata: stat, executable: Bool) -> Bool {
    metadata.st_mode & S_IFMT == S_IFREG
        && metadata.st_uid == 0
        && metadata.st_mode & 0o022 == 0
        && executable
}

func posixMode(_ value: stat) -> Int {
    Int(value.st_mode & 0o7777)
}
