import Darwin
import Foundation

private struct ResolvedWorkspacePath {
    let workspace: RegisteredLocalWorkspace
    let relativePath: String
    let url: URL
    let status: stat?
}

private enum UndoAction {
    case restoreFile(
        workspaceID: String,
        relativePath: String,
        previousData: Data?,
        previousMode: Int,
        expectedCurrentSHA256: String
    )
    case removeCreatedPath(
        workspaceID: String,
        relativePath: String,
        expectedTreeSHA256: String
    )
    case moveBack(
        workspaceID: String,
        sourceRelativePath: String,
        destinationRelativePath: String,
        expectedDestinationTreeSHA256: String
    )
    case restoreRemovedPath(
        workspaceID: String,
        originalRelativePath: String,
        recoveryRelativePath: String,
        expectedRecoveryTreeSHA256: String
    )
}

private struct StoredTransaction {
    let action: UndoAction
    let sequence: Int

    var retainedFileBytes: Int {
        if case .restoreFile(_, _, let data, _, _) = action { return data?.count ?? 0 }
        return 0
    }
}

private struct TraversalDiagnostics {
    private(set) var skippedCount = 0
    private(set) var skippedPaths: [String] = []

    mutating func skip(_ relativePath: String) {
        skippedCount += 1
        if skippedPaths.count < 20 { skippedPaths.append(relativePath) }
    }

    var json: JSONObject {
        [
            "partial": skippedCount > 0,
            "skipped_inaccessible_paths": skippedCount,
            "skipped_path_samples": skippedPaths,
        ]
    }
}

private struct DirectoryNameStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        owner = value.st_uid
        group = value.st_gid
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

private struct DirectoryNamePageIndex {
    let path: String
    let stamp: DirectoryNameStamp
    let sortedNames: [String]
    let cacheable: Bool
    let enumerationLimited: Bool
    var rawCursor = 0
    var names: [String] = []
}

public final class LocalWorkspaceService: @unchecked Sendable {
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static let maximumTreeEntries = 10_000
    public static let maximumTreeBytes: Int64 = 500_000_000
    public static let maximumRetainedTransactions = 1_024
    public static let maximumRetainedUndoFileBytes = 64 * 1_024 * 1_024

    public let registry: LocalWorkspaceRegistry
    // Held from mutation preflight through transaction publication, and throughout
    // restore. Recursive because publication/read-only metadata also take this lock.
    private let transactionLock = NSRecursiveLock()
    private var transactions: [String: StoredTransaction] = [:]
    private var retainedUndoFileBytes = 0
    private var nextTransactionSequence = 0
    private let transactionCursorNamespace = UUID().uuidString.lowercased()
    private let transactionLimit: Int
    private let undoFileByteLimit: Int
    // Internal deterministic race injection; never configured by CLI or MCP.
    private let beforeCopyPublicationForTesting: (() throws -> Void)?
    private let relocationProtectedPathsForTesting: Set<String>
    // One bounded name index, never file content or cached file metadata. It is
    // only a flat-directory fast path; recursive traversal keeps its existing
    // semantics. A new registry/owner starts empty. No timer or background work.
    private let directoryNameLock = NSLock()
    private var directoryNameIndex: DirectoryNamePageIndex?
    private static let maximumDirectoryNameBytes = 4 * 1_024 * 1_024
    private let observerFilePreviews = ObserverFilePreview()

    public convenience init(registry: LocalWorkspaceRegistry) {
        self.init(registry: registry, transactionLimit: Self.maximumRetainedTransactions,
                  undoFileByteLimit: Self.maximumRetainedUndoFileBytes)
    }

    init(registry: LocalWorkspaceRegistry, transactionLimit: Int, undoFileByteLimit: Int,
         beforeCopyPublicationForTesting: (() throws -> Void)? = nil,
         relocationProtectedPathsForTesting: Set<String> = []) {
        precondition(transactionLimit >= 0 && undoFileByteLimit >= 0)
        self.registry = registry
        self.transactionLimit = transactionLimit
        self.undoFileByteLimit = undoFileByteLimit
        self.beforeCopyPublicationForTesting = beforeCopyPublicationForTesting
        self.relocationProtectedPathsForTesting = Set(relocationProtectedPathsForTesting.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
    }

    var retainedTransactionCount: Int {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return transactions.count
    }

    public func workspaceOverview() -> JSONObject {
        ["workspaces": registry.workspaces.map(\.json)]
    }

    // Metadata only: never reads files or exposes the retained before-content.
    // A monotonic keyset cursor continues correctly when earlier rows are
    // accepted/restored between pages. It is owner-local, not a snapshot token.
    public func listTransactions(cursor: String? = nil, maximumTransactions: Int = 100) throws -> JSONObject {
        guard (1...100).contains(maximumTransactions) else {
            throw LocalMCPError.invalidRequest("transaction cursor/page size is out of range")
        }
        transactionLock.lock()
        defer { transactionLock.unlock() }
        var afterSequence = 0
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard cursor.utf8.count <= 64, parts.count == 2,
                parts[0] == transactionCursorNamespace,
                let sequence = Int(parts[1]), sequence > 0,
                String(sequence) == parts[1], sequence <= nextTransactionSequence else {
                throw LocalMCPError.conflict("transaction cursor is invalid or from another registry; restart listing")
            }
            afterSequence = sequence
        }
        let eligible = transactions.filter { $0.value.sequence > afterSequence }
            .sorted { $0.value.sequence < $1.value.sequence }
        let page = eligible.prefix(maximumTransactions)
        var result: JSONObject = [
            "transactions": page.map { transactionMetadata(id: $0.key, stored: $0.value) },
            "retained_transaction_count": transactions.count,
            "retained_undo_file_bytes": retainedUndoFileBytes,
            "returned_transactions": page.count,
            "complete": eligible.count <= maximumTransactions,
            "latest_sequence": nextTransactionSequence,
            "scope": "owner-local metadata; no file reads; not a durable or fixed snapshot",
        ]
        if eligible.count > maximumTransactions, let last = page.last {
            result["next_cursor"] = "\(transactionCursorNamespace):\(last.value.sequence)"
        }
        return result
    }

    private func transactionMetadata(id: String, stored: StoredTransaction) -> JSONObject {
        var result: JSONObject = [
            "transaction_id": id, "sequence": stored.sequence,
            "retained_undo_file_bytes": stored.retainedFileBytes,
        ]
        switch stored.action {
        case .restoreFile(let workspace, let path, _, _, _):
            result["workspace_id"] = workspace; result["path"] = path; result["kind"] = "file"
        case .removeCreatedPath(let workspace, let path, _):
            result["workspace_id"] = workspace; result["path"] = path; result["kind"] = "created_path"
        case .moveBack(let workspace, let source, let destination, _):
            result["workspace_id"] = workspace; result["path"] = source; result["kind"] = "moved_path"
            result["destination_path"] = destination
        case .restoreRemovedPath(let workspace, let path, let recovery, let digest):
            result["workspace_id"] = workspace; result["path"] = path; result["kind"] = "removed_path"
            result["recovery_path"] = recovery
            result["expected_recovery_tree_sha256"] = digest
        }
        return result
    }

    // Explicitly discard selected owner-local undo, not the current file state.
    // Validate the complete batch before release. No path resolution, recursive
    // deletion, recovery purge, hashing, or filesystem mutation happens here.
    public func acceptTransactions(_ rawIDs: [String]) throws -> JSONObject {
        guard (1...128).contains(rawIDs.count) else {
            throw LocalMCPError.invalidRequest("select between 1 and 128 transaction IDs")
        }
        let ids = try rawIDs.map { raw -> String in
            guard let uuid = UUID(uuidString: raw) else {
                throw LocalMCPError.invalidRequest("transaction IDs must be UUIDs")
            }
            return uuid.uuidString.lowercased()
        }
        guard Set(ids).count == ids.count else {
            throw LocalMCPError.invalidRequest("duplicate transaction IDs are not allowed")
        }
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let selected = try ids.map { id -> (String, StoredTransaction) in
            guard let stored = transactions[id] else {
                throw LocalMCPError.conflict("transaction is unknown or no longer retained; no undo released")
            }
            return (id, stored)
        }
        let releasedBytes = selected.reduce(0) { $0 + $1.1.retainedFileBytes }
        let receipts: [JSONObject] = selected.map { id, stored in
            var receipt = transactionMetadata(id: id, stored: stored)
            receipt["automatic_restore_available"] = false
            if case .restoreRemovedPath = stored.action {
                receipt["recovery_payload_preserved"] = true
                receipt["manual_recovery_required"] = true
            }
            return receipt
        }
        for id in ids { transactions.removeValue(forKey: id) }
        retainedUndoFileBytes -= releasedBytes
        return [
            "operation": "transaction_accept", "accepted": receipts,
            "accepted_count": ids.count, "released_undo_file_bytes": releasedBytes,
            "retained_transaction_count": transactions.count,
            "retained_undo_file_bytes": retainedUndoFileBytes,
            "backend_called": true, "undo_released": true,
            "filesystem_mutation_performed": false,
            "execution_backend": "owner_transaction_registry",
            "current_file_state_validated": false,
            "meaning": "Selected undo released; current files untouched. This does not prove task success or free disk recovery.",
        ]
    }

    func observerTransactions() -> [JSONObject] {
        transactionLock.lock()
        let selected = Array(transactions.prefix(100))
        transactionLock.unlock()
        return selected.map { observerMetadata(id: $0.key, action: $0.value.action) }
            .sorted { ($0["transaction_id"] as? String ?? "") < ($1["transaction_id"] as? String ?? "") }
    }

    private func observerMetadata(id: String, action: UndoAction) -> JSONObject {
        let workspace: String
        let path: String
        let kind: String
        switch action {
        case .restoreFile(let w, let p, _, _, _): workspace = w; path = p; kind = "file"
        case .removeCreatedPath(let w, let p, _): workspace = w; path = p; kind = "created path"
        case .moveBack(let w, let p, _, _): workspace = w; path = p; kind = "moved path"
        case .restoreRemovedPath(let w, let p, _, _): workspace = w; path = p; kind = "removed path"
        }
        return ["transaction_id": id, "workspace_id": workspace,
                "path": String(path.prefix(512)), "kind": kind,
                "provenance": "owner-local file-tool transaction"]
    }

    func observerTransaction(id: String, workspaceID: String) throws -> JSONObject {
        transactionLock.lock()
        let stored = transactions[id]
        transactionLock.unlock()
        guard let stored else { throw LocalMCPError.conflict("transaction is unknown or already restored") }
        var detail = observerMetadata(id: id, action: stored.action)
        guard detail["workspace_id"] as? String == workspaceID else {
            throw LocalMCPError.conflict("transaction belongs to another workspace")
        }
        detail["preview_limit_bytes"] = 8192
        detail["restore_requires_current_state_validation"] = true
        if case .restoreFile(let workspace, let path, let previous, _, let expected) = stored.action {
            let current = try readFile(workspaceID: workspace, path: path,
                                       encoding: "base64", maximumBytes: 8195)
            let file = current["file"] as? JSONObject ?? [:]
            let data = Data(base64Encoded: file["content"] as? String ?? "") ?? Data()
            func preview(_ value: Data) -> (String, Bool) {
                var end = min(8192, value.count)
                let lower = max(0, end - 3)
                // Extra bytes distinguish a split scalar from an invalid tail.
                if end < value.count {
                    while end > lower, value[end] & 0xC0 == 0x80 { end -= 1 }
                }
                let slice = Data(value.prefix(end))
                if slice.contains(0) { return ("[Binary content; text preview unavailable]", false) }
                if let text = String(data: slice, encoding: .utf8) { return (text, true) }
                return ("[Binary or non-UTF8 content; text preview unavailable]", false)
            }
            let before = previous.map(preview) ?? ("", true)
            let after = preview(data)
            detail["before"] = previous == nil ? "[File did not exist]" : before.0
            detail["after"] = after.0
            detail["before_exists"] = previous != nil
            detail["before_is_text"] = before.1
            detail["after_is_text"] = after.1
            detail["before_sha256"] = previous.map(LocalHash.sha256) ?? "absent"
            detail["expected_after_sha256"] = expected
            detail["current_sha256"] = file["sha256"] ?? NSNull()
            detail["before_truncated"] = (previous?.count ?? 0) > 8192
            detail["after_truncated"] = (file["total_byte_count"] as? Int ?? Int.max) > 8192
            detail["comparison"] = "bounded before/current comparison; not shell-attributed changes"
        } else {
            detail["comparison"] = "Path transaction metadata only; text diff unavailable"
        }
        return detail
    }

    func observerRestore(id: String, workspaceID: String,
                         perform: () throws -> JSONObject) throws -> JSONObject {
        transactionLock.lock()
        let action = transactions[id]?.action
        transactionLock.unlock()
        guard let action,
              observerMetadata(id: id, action: action)["workspace_id"] as? String == workspaceID else {
            throw LocalMCPError.conflict("unknown transaction or wrong workspace")
        }
        var result = try perform()
        var verified = false
        switch action {
        case .restoreFile(let w, let p, let previous, _, _):
            if let previous {
                let current = try statPath(workspaceID: w, path: p)["path"] as? JSONObject
                let digest = current?["sha256"] as? String
                verified = digest == LocalHash.sha256(previous)
                result["readback_sha256"] = digest ?? NSNull()
            } else {
                verified = try resolveDestination(workspaceID: w, path: p).status == nil
            }
        case .removeCreatedPath(let w, let p, _):
            verified = try resolveDestination(workspaceID: w, path: p).status == nil
        case .moveBack(let w, let source, let destination, let digest):
            let restored = try resolveExisting(workspaceID: w, path: source)
            verified = try treeDigest(restored.url) == digest
                && resolveDestination(workspaceID: w, path: destination).status == nil
        case .restoreRemovedPath(let w, let p, _, let digest):
            verified = try treeDigest(resolveExisting(workspaceID: w, path: p).url) == digest
        }
        result["readback_verified"] = verified
        if !verified { throw LocalMCPError.conflict("restore completed but independent readback did not match; inspect state") }
        return result
    }

    public func listDirectory(
        workspaceID: String,
        path: String,
        recursive: Bool,
        maximumEntries: Int,
        cursor: Int = 0
    ) throws -> JSONObject {
        guard cursor >= 0, cursor <= Self.maximumTreeEntries,
              (1...Self.maximumTreeEntries).contains(maximumEntries) else {
            throw LocalMCPError.invalidRequest("directory cursor is out of range")
        }
        let root = try resolveExisting(workspaceID: workspaceID, path: path, allowRoot: true)
        guard let rootStatus = root.status, rootStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LocalMCPError.wrongFileType
        }
        if !recursive {
            return try listFlatDirectory(root, status: rootStatus,
                                         maximumEntries: maximumEntries, cursor: cursor)
        }
        var queue: [(URL, String)] = [(root.url, root.relativePath)]
        var queueIndex = 0
        var diagnostics = TraversalDiagnostics()
        var entries: [JSONObject] = []
        var visibleEntryCount = 0
        var scannedEntries = 0
        var hasMore = false
        var traversalLimited = false
        traversal: while queueIndex < queue.count {
            guard scannedEntries < Self.maximumTreeEntries else {
                traversalLimited = true
                break
            }
            let (directory, relativeDirectory) = queue[queueIndex]
            queueIndex += 1
            let names: [String]
            do {
                let page = try WorkspaceDirectory(directory).names()
                names = page.values
                traversalLimited = traversalLimited || page.limited
            } catch {
                if directory == root.url { throw error }
                diagnostics.skip(relativeDirectory)
                continue
            }
            for name in names {
                guard scannedEntries < Self.maximumTreeEntries else {
                    traversalLimited = true
                    break traversal
                }
                let relative = relativeDirectory == "." ? name : "\(relativeDirectory)/\(name)"
                if isSensitive(relative) { continue }
                let target = directory.appendingPathComponent(name)
                if isSensitive(target.path) { continue }
                let status: stat
                do { status = try lstatValue(target.path) }
                catch {
                    diagnostics.skip(relative)
                    scannedEntries += 1
                    continue
                }
                let kind = pathKind(status)
                scannedEntries += 1
                if visibleEntryCount >= cursor {
                    guard entries.count < maximumEntries else {
                        hasMore = true
                        break traversal
                    }
                    entries.append(metadata(relativePath: relative, status: status, kind: kind))
                }
                visibleEntryCount += 1
                if recursive, kind == "directory", !isSensitive(relative) {
                    queue.append((target, relative))
                }
            }
            if !recursive { break }
        }
        guard cursor <= visibleEntryCount else {
            throw LocalMCPError.invalidRequest("directory cursor is past the final entry")
        }
        let complete = !hasMore && !traversalLimited && diagnostics.skippedCount == 0
        var result: JSONObject = [
            "entries": entries,
            "cursor": cursor,
            "returned_entries": entries.count,
            "scanned_entries": scannedEntries,
            "complete": complete,
            "truncated": !complete,
            "limit_reached": traversalLimited,
        ]
        result.merge(diagnostics.json) { _, new in new }
        if hasMore { result["next_cursor"] = cursor + entries.count }
        return result
    }

    private func listFlatDirectory(
        _ root: ResolvedWorkspacePath, status: stat, maximumEntries: Int, cursor: Int
    ) throws -> JSONObject {
        let stamp = DirectoryNameStamp(status)
        directoryNameLock.lock()
        let cached = directoryNameIndex
        directoryNameLock.unlock()
        let cacheHit = cached?.path == root.url.path && cached?.stamp == stamp
        var index: DirectoryNamePageIndex
        var enumeratedEntries = 0
        if cacheHit, let cached {
            index = cached
        } else {
            // Replace, rather than accumulate, cached folder indexes.
            directoryNameLock.lock()
            directoryNameIndex = nil
            directoryNameLock.unlock()
            let page = try WorkspaceDirectory(root.url).names()
            let sorted = page.values
            enumeratedEntries = sorted.count
            let cacheable = sorted.count <= Self.maximumTreeEntries * 2
                && sorted.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumDirectoryNameBytes
            index = DirectoryNamePageIndex(path: root.url.path, stamp: stamp,
                                           sortedNames: sorted, cacheable: cacheable,
                                           enumerationLimited: page.limited)
        }
        // Extend the visible-name index only as far as this page plus one
        // lookahead entry. Eagerly filtering an entire folder makes a cold
        // first page much slower even though subsequent pages are quick.
        let needed = min(Self.maximumTreeEntries + 1, cursor + maximumEntries + 1)
        while index.names.count < needed, index.rawCursor < index.sortedNames.count {
            let name = index.sortedNames[index.rawCursor]
            index.rawCursor += 1
            let relative = root.relativePath == "." ? name : "\(root.relativePath)/\(name)"
            if isSensitive(relative) || isSensitive(root.url.appendingPathComponent(name).path) { continue }
            index.names.append(name)
        }
        let visibleCount = min(Self.maximumTreeEntries, index.names.count)
        let limited = index.names.count > Self.maximumTreeEntries || index.enumerationLimited
        guard cursor <= visibleCount else {
            throw LocalMCPError.invalidRequest("directory cursor is past the final entry")
        }
        let end = min(visibleCount, cursor + maximumEntries)
        var diagnostics = TraversalDiagnostics()
        var entries: [JSONObject] = []
        for name in index.names[cursor..<end] {
            let relative = root.relativePath == "." ? name : "\(root.relativePath)/\(name)"
            do {
                // Re-read only this page's metadata, without following links.
                // File edits do not necessarily change the parent directory stamp.
                let value = try lstatValue(root.url.appendingPathComponent(name).path)
                entries.append(metadata(relativePath: relative, status: value, kind: pathKind(value)))
            } catch { diagnostics.skip(relative) }
        }
        guard DirectoryNameStamp(try lstatValue(root.url.path)) == stamp else {
            throw LocalMCPError.conflict("directory changed during listing; restart at cursor 0")
        }
        if index.cacheable {
            directoryNameLock.lock()
            directoryNameIndex = index
            directoryNameLock.unlock()
        }
        // Integer cursors remain live offsets, not snapshot/ownership tokens.
        // Between-request changes invalidate names; callers needing a consistent
        // changing-tree snapshot must restart. A cache hit never reuses metadata.
        let hasMore = end < visibleCount
        let complete = !hasMore && !limited && diagnostics.skippedCount == 0
        var result: JSONObject = [
            "entries": entries, "cursor": cursor, "returned_entries": entries.count,
            "scanned_entries": end - cursor, "enumerated_entries": enumeratedEntries,
            "name_index_cache_hit": cacheHit,
            "complete": complete, "truncated": !complete,
            "limit_reached": !hasMore && limited,
            "enumeration_limited": index.enumerationLimited,
            "ordering_scope": index.enumerationLimited ? "sorted_bounded_enumeration_not_global_prefix" : "complete_directory_names",
        ]
        result.merge(diagnostics.json) { _, new in new }
        if hasMore { result["next_cursor"] = end }
        return result
    }

    public func statPath(workspaceID: String, path: String, includeSHA256: Bool = true) throws -> JSONObject {
        let resolved = try resolveExisting(workspaceID: workspaceID, path: path, allowRoot: true)
        guard let status = resolved.status else { throw LocalMCPError.notFound }
        var value = metadata(
            relativePath: resolved.relativePath,
            status: status,
            kind: pathKind(status)
        )
        if includeSHA256, status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1,
            status.st_size <= Self.maximumFileBytes,
            !isSensitive(resolved.relativePath)
        {
            value["sha256"] = try LocalHash.sha256(fileAt: resolved.url)
        }
        return ["path": value]
    }

    /// Current selected-file preview. Only the observer's retained-event route
    /// calls this; ordinary MCP tools and snapshots do not acquire file bodies.
    func observerFilePreview(workspaceID: String, path: String, knownVersion: String?) throws -> JSONObject {
        let resolved = try resolveExisting(workspaceID: workspaceID, path: path)
        guard !isSensitive(resolved.relativePath), let status = resolved.status else {
            throw LocalMCPError.sensitivePathBlocked
        }
        var result = try observerFilePreviews.read(url: resolved.url, root: resolved.workspace.rootURL.path,
                                                   expected: status, knownVersion: knownVersion)
        result["relative_path"] = resolved.relativePath
        result["workspace_id"] = resolved.workspace.id
        return result
    }

    public func readFile(
        workspaceID: String,
        path: String,
        encoding: String,
        maximumBytes: Int,
        offset: Int = 0
    ) throws -> JSONObject {
        guard offset >= 0 else {
            throw LocalMCPError.invalidRequest("file offset is out of range")
        }
        let resolved = try resolveExisting(workspaceID: workspaceID, path: path)
        guard !isSensitive(resolved.relativePath) else {
            throw LocalMCPError.sensitivePathBlocked
        }
        let descriptor = Darwin.open(
            resolved.url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1,
            status.st_size >= 0,
            status.st_size <= off_t(Int.max),
            offset <= Int(status.st_size)
        else { throw LocalMCPError.wrongFileType }
        let totalBytes = Int(status.st_size)
        let requestedBytes = min(maximumBytes, totalBytes - offset)
        let readLimit: Int
        switch encoding {
        case "utf8": readLimit = min(totalBytes - offset, requestedBytes + 3)
        case "base64": readLimit = requestedBytes
        default: throw LocalMCPError.invalidRequest("encoding must be utf8 or base64")
        }
        var data = Data(count: readLimit)
        var bytesRead = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while bytesRead < rawBuffer.count {
                let count = Darwin.pread(
                    descriptor,
                    base.advanced(by: bytesRead),
                    rawBuffer.count - bytesRead,
                    off_t(offset + bytesRead)
                )
                if count > 0 {
                    bytesRead += count
                    continue
                }
                if count == 0 { break }
                if errno == EINTR { continue }
                throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
            }
        }
        if bytesRead < data.count { data.removeSubrange(bytesRead..<data.count) }
        let content: String
        switch encoding {
        case "utf8":
            if offset > 0, let first = data.first, first & 0xC0 == 0x80 {
                throw LocalMCPError.invalidRequest("file offset splits a UTF-8 scalar")
            }
            var end = min(requestedBytes, data.count)
            while end < data.count, data[end] & 0xC0 == 0x80 { end += 1 }
            if end < data.count { data.removeSubrange(end..<data.count) }
            guard let value = String(data: data, encoding: .utf8) else {
                throw LocalMCPError.operationFailed("file is not valid UTF-8")
            }
            content = value
        case "base64":
            content = data.base64EncodedString()
        default: preconditionFailure("encoding was validated before reading")
        }
        let nextOffset = offset + data.count
        let chunkSHA256 = LocalHash.sha256(data)
        var file: JSONObject = [
            "relative_path": resolved.relativePath,
            "byte_offset": offset,
            "byte_count": data.count,
            "total_byte_count": totalBytes,
            "next_offset": nextOffset,
            "eof": nextOffset == totalBytes,
            "encoding": encoding,
            "content": content,
            "chunk_sha256": chunkSHA256,
        ]
        if offset == 0, nextOffset == totalBytes { file["sha256"] = chunkSHA256 }
        return ["file": file]
    }

    public func searchFiles(
        workspaceID: String,
        path: String,
        query: String,
        caseSensitive: Bool,
        maximumResults: Int,
        maximumFileBytes: Int,
        mode: String = "content",
        cursor: Int = 0,
        includeIgnored: Bool = false,
        maximumDurationMilliseconds: Int = 5_000,
        maximumTotalReadBytes: Int = 32 * 1_024 * 1_024
    ) throws -> JSONObject {
        guard !query.isEmpty, query.utf8.count <= 4_096 else {
            throw LocalMCPError.invalidRequest("bounded non-empty query required")
        }
        guard mode == "content" || mode == "name" else {
            throw LocalMCPError.invalidRequest("search mode must be content or name")
        }
        guard cursor >= 0 else {
            throw LocalMCPError.invalidRequest("search cursor is out of range")
        }
        guard (1...10_000).contains(maximumDurationMilliseconds),
              (1...(64 * 1_024 * 1_024)).contains(maximumTotalReadBytes) else {
            throw LocalMCPError.invalidRequest("search execution budget is out of range")
        }
        let budget = SearchBudget(milliseconds: maximumDurationMilliseconds,
                                  maximumBytes: maximumTotalReadBytes)
        let root = try resolveExisting(workspaceID: workspaceID, path: path, allowRoot: true)
        guard let rootStatus = root.status, rootStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LocalMCPError.wrongFileType
        }
        var queue: [(URL, String)] = [(root.url, root.relativePath)]
        var queueIndex = 0
        var diagnostics = TraversalDiagnostics()
        let needle = caseSensitive ? query : query.lowercased()
        // Byte matching is equivalent only for this conservative subset. CR in
        // either input falls back because the legacy splitter treats CRLF as a
        // single Character; LF-containing queries must never match across lines.
        let asciiNeedle: Data? = caseSensitive && query.utf8.allSatisfy({
            $0 < 0x80 && $0 != 0x0D && $0 != 0x0A
        }) ? Data(query.utf8) : nil
        var matches: [JSONObject] = []
        var scannedFiles = 0
        var scannedEntries = 0
        var skippedDirectories = 0
        var skippedOversizedFiles = 0
        var skippedNonUTF8Files = 0
        var skippedUnsupportedFiles = 0
        var skippedDatalessFiles = 0
        var matchCount = 0
        var hasMore = false
        var traversalLimited = false
        var budgetLimit: String?
        do {
            traversal: while queueIndex < queue.count {
                try budget.checkTime()
                guard scannedEntries < Self.maximumTreeEntries else {
                    traversalLimited = true
                    break
                }
                let (directory, relativeDirectory) = queue[queueIndex]
                queueIndex += 1
                let names: [String]
                do {
                    let page = try WorkspaceDirectory(directory).names()
                    names = page.values
                    traversalLimited = traversalLimited || page.limited
                } catch {
                    if directory == root.url { throw error }
                    diagnostics.skip(relativeDirectory)
                    continue
                }
                for name in names {
                    try budget.checkTime()
                    guard scannedEntries < Self.maximumTreeEntries else {
                        traversalLimited = true
                        break traversal
                    }
                    scannedEntries += 1
                    let relative = relativeDirectory == "." ? name : "\(relativeDirectory)/\(name)"
                    if isSensitive(relative) {
                        continue
                    }
                    let target = directory.appendingPathComponent(name)
                    if isSensitive(target.path) { continue }
                    let status: stat
                    do { status = try lstatValue(target.path) }
                    catch {
                        diagnostics.skip(relative)
                        continue
                    }
                    switch status.st_mode & S_IFMT {
                    case S_IFDIR:
                        if shouldSkipSearchDirectory(name: name, includeIgnored: includeIgnored) {
                            skippedDirectories += 1
                            continue
                        }
                        if mode == "name", matchesQuery(relative, needle, caseSensitive: caseSensitive) {
                            if matchCount >= cursor {
                                guard matches.count < maximumResults else {
                                    hasMore = true
                                    break traversal
                                }
                                matches.append([
                                    "relative_path": relative,
                                    "kind": "directory",
                                ])
                            }
                            matchCount += 1
                        }
                        queue.append((target, relative))
                    case S_IFREG:
                        if mode == "name" {
                            if matchesQuery(relative, needle, caseSensitive: caseSensitive) {
                                if matchCount >= cursor {
                                    guard matches.count < maximumResults else {
                                        hasMore = true
                                        break traversal
                                    }
                                    matches.append([
                                        "relative_path": relative,
                                        "kind": "file",
                                    ])
                                }
                                matchCount += 1
                            }
                            continue
                        }
                        guard status.st_nlink == 1, status.st_size >= 0 else {
                            skippedUnsupportedFiles += 1
                            continue
                        }
                        guard status.st_size <= maximumFileBytes else {
                            skippedOversizedFiles += 1
                            continue
                        }
                        scannedFiles += 1
                        let data: Data
                        do {
                            data = try SearchFileReader.read(target, expected: status,
                                maximumBytes: maximumFileBytes, budget: budget)
                        } catch let limit as SearchBudgetLimit {
                            throw limit
                        } catch SearchReadIssue.dataless {
                            skippedDatalessFiles += 1
                            continue
                        } catch SearchReadIssue.oversized {
                            skippedOversizedFiles += 1
                            continue
                        }
                        catch {
                            diagnostics.skip(relative)
                            continue
                        }
                        if let asciiNeedle, isASCIIWithoutCR(data) {
                            var searchStart = data.startIndex
                            var lineNumber = 1
                            while searchStart < data.endIndex,
                                let hit = data.range(of: asciiNeedle, in: searchStart..<data.endIndex)
                            {
                                try budget.checkTime()
                                if matchCount >= cursor, matches.count >= maximumResults {
                                    hasMore = true
                                    break traversal
                                }
                                let line = asciiLineCoordinates(
                                    data, searchStart: searchStart, hit: hit, lineNumber: lineNumber
                                )
                                if matchCount >= cursor {
                                    let previewEnd = min(line.start + 500, line.end)
                                    matches.append([
                                        "relative_path": relative,
                                        "line": line.number,
                                        "preview": String(decoding: data[line.start..<previewEnd], as: UTF8.self),
                                    ])
                                }
                                matchCount += 1
                                // One result per matching line, not per occurrence.
                                searchStart = line.end < data.endIndex ? line.end + 1 : data.endIndex
                                lineNumber = line.number + 1
                            }
                            // Handled no-match files must not fall through and scan again.
                            continue
                        }
                        guard let text = String(data: data, encoding: .utf8) else {
                            skippedNonUTF8Files += 1
                            continue
                        }
                        var remaining = text[...]
                        var lineNumber = 1
                        while true {
                            try budget.checkTime()
                            // Character-based LF splitting preserves the previous split semantics,
                            // including empty/trailing lines and CRLF grapheme clusters.
                            let newline = remaining.firstIndex(of: "\n")
                            let line = newline.map { remaining[..<$0] } ?? remaining
                            let matchesNeedle = caseSensitive
                                ? line.contains(needle) : line.lowercased().contains(needle)
                            if matchesNeedle {
                                if matchCount >= cursor {
                                    guard matches.count < maximumResults else {
                                        hasMore = true
                                        break traversal
                                    }
                                    matches.append([
                                        "relative_path": relative,
                                        "line": lineNumber,
                                        "preview": String(line.prefix(500)),
                                    ])
                                }
                                matchCount += 1
                            }
                            guard let newline else { break }
                            remaining = remaining[remaining.index(after: newline)...]
                            lineNumber += 1
                        }
                    default:
                        continue
                    }
                }
            }
        } catch SearchBudgetLimit.time {
            budgetLimit = "time_budget"
        } catch SearchBudgetLimit.bytes {
            budgetLimit = "read_byte_budget"
        }
        guard cursor <= matchCount || budgetLimit != nil || traversalLimited else {
            throw LocalMCPError.invalidRequest("search cursor is past the final match")
        }
        let contentSkipped = skippedOversizedFiles + skippedNonUTF8Files + skippedUnsupportedFiles + skippedDatalessFiles
        let complete = !hasMore && !traversalLimited && budgetLimit == nil && diagnostics.skippedCount == 0 && contentSkipped == 0
        var result: JSONObject = [
            "matches": matches,
            "mode": mode,
            "cursor": cursor,
            "returned_results": matches.count,
            "scanned_files": scannedFiles,
            "scanned_entries": scannedEntries,
            "skipped_default_directories": skippedDirectories,
            "skipped_oversized_files": skippedOversizedFiles,
            "skipped_non_utf8_files": skippedNonUTF8Files,
            "skipped_unsupported_files": skippedUnsupportedFiles,
            "skipped_dataless_files": skippedDatalessFiles,
            "read_bytes": budget.bytesRead,
            "maximum_total_read_bytes": maximumTotalReadBytes,
            "maximum_duration_milliseconds": maximumDurationMilliseconds,
            "deadline_enforcement": "cooperative_between_filesystem_operations",
            "complete": complete,
            "truncated": !complete,
            "limit_reached": traversalLimited || budgetLimit != nil,
        ]
        result.merge(diagnostics.json) { _, new in new }
        result["partial"] = diagnostics.skippedCount > 0 || contentSkipped > 0 || budgetLimit != nil || traversalLimited
        if let budgetLimit { result["stop_reason"] = budgetLimit }
        else if traversalLimited { result["stop_reason"] = "entry_budget" }
        // A stopped traversal has no resumable snapshot. Do not invent a cursor
        // that would repeatedly rescan the same prefix and never make progress.
        if budgetLimit != nil || traversalLimited { result["retry_guidance"] = "Narrow path or partition the directory; do not replay the same broad search." }
        if hasMore { result["next_cursor"] = cursor + matches.count }
        return result
    }

    public func writeFile(
        workspaceID: String,
        path: String,
        content: String,
        encoding: String,
        expectedSHA256: String?
    ) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let data: Data
        switch encoding {
        case "utf8": data = Data(content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: content) else {
                throw LocalMCPError.invalidRequest("invalid base64 content")
            }
            data = decoded
        default: throw LocalMCPError.invalidRequest("encoding must be utf8 or base64")
        }
        guard data.count <= Self.maximumFileBytes else {
            throw LocalMCPError.limitExceeded("file write")
        }
        let resolved = try resolveDestination(workspaceID: workspaceID, path: path)
        guard !isSensitive(resolved.relativePath) else {
            throw LocalMCPError.sensitivePathBlocked
        }
        let previousData: Data?
        let previousMode: Int
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        let name = resolved.url.lastPathComponent
        if let status = try parent.status(name) {
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                status.st_size >= 0, status.st_size <= Self.maximumFileBytes
            else { throw LocalMCPError.wrongFileType }
            guard let expectedSHA256, LocalHash.isSHA256(expectedSHA256) else {
                throw LocalMCPError.conflict("expected_sha256 is required when replacing a file")
            }
            let fd = try parent.openFile(name)
            defer { close(fd) }
            previousData = try LocalFileReader.read(descriptor: fd, maximumBytes: Self.maximumFileBytes)
            guard LocalHash.sha256(previousData!) == expectedSHA256 else {
                throw LocalMCPError.conflict("expected_sha256 does not match current content")
            }
            previousMode = posixMode(status)
        } else {
            guard expectedSHA256 == nil else {
                throw LocalMCPError.conflict("expected_sha256 supplied for a new file")
            }
            previousData = nil
            previousMode = 0o644
        }
        try requireUndoCapacity(fileBytes: previousData?.count ?? 0)
        try parent.atomicWrite(data, name: name, mode: previousMode, replacing: previousData != nil)
        let finalSHA256 = LocalHash.sha256(data)
        let transactionID = storeTransaction(
            .restoreFile(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                previousData: previousData,
                previousMode: previousMode,
                expectedCurrentSHA256: finalSHA256
            )
        )
        return mutationResult(
            operation: "file_write",
            transactionID: transactionID,
            details: [
                "relative_path": resolved.relativePath,
                "byte_count": data.count,
                "sha256": finalSHA256,
                "created": previousData == nil,
            ]
        )
    }

    public func patchFile(
        workspaceID: String,
        path: String,
        oldText: String,
        newText: String,
        replaceAll: Bool,
        expectedSHA256: String
    ) throws -> JSONObject {
        guard !oldText.isEmpty, oldText.utf8.count <= Self.maximumFileBytes,
            newText.utf8.count <= Self.maximumFileBytes,
            LocalHash.isSHA256(expectedSHA256)
        else { throw LocalMCPError.invalidRequest("invalid patch bounds") }
        let read = try readFile(
            workspaceID: workspaceID,
            path: path,
            encoding: "utf8",
            maximumBytes: Self.maximumFileBytes
        )
        guard let file = read["file"] as? JSONObject,
            let current = file["content"] as? String,
            file["sha256"] as? String == expectedSHA256
        else { throw LocalMCPError.conflict("patch base does not match expected_sha256") }
        var occurrences = 0
        var removedBytes = 0
        var searchStart = current.startIndex
        while searchStart < current.endIndex,
            let range = current.range(of: oldText, range: searchStart..<current.endIndex)
        {
            occurrences += 1
            removedBytes += current[range].utf8.count
            // A second match already makes a single-replacement patch ambiguous.
            if !replaceAll, occurrences == 2 { break }
            searchStart = range.upperBound
        }
        guard occurrences > 0 else { throw LocalMCPError.conflict("old_text was not found") }
        guard replaceAll || occurrences == 1 else {
            throw LocalMCPError.conflict(
                "old_text occurs more than once; set replace_all=true or provide a unique match"
            )
        }
        let replacementBytes = newText.utf8.count.multipliedReportingOverflow(by: occurrences)
        let resultBytes = (current.utf8.count - removedBytes).addingReportingOverflow(replacementBytes.partialValue)
        guard !replacementBytes.overflow, !resultBytes.overflow, resultBytes.partialValue <= Self.maximumFileBytes else {
            throw LocalMCPError.limitExceeded("patched file exceeds file byte limit")
        }
        let patched: String
        if replaceAll {
            patched = current.replacingOccurrences(of: oldText, with: newText)
        } else if let range = current.range(of: oldText) {
            patched = current.replacingCharacters(in: range, with: newText)
        } else {
            throw LocalMCPError.conflict("old_text was not found")
        }
        var result = try writeFile(
            workspaceID: workspaceID,
            path: path,
            content: patched,
            encoding: "utf8",
            expectedSHA256: expectedSHA256
        )
        result["operation"] = "file_patch"
        result["replacements"] = replaceAll ? occurrences : 1
        return result
    }

    public func appendFile(
        workspaceID: String,
        path: String,
        content: String,
        encoding: String,
        expectedSHA256: String
    ) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard LocalHash.isSHA256(expectedSHA256) else {
            throw LocalMCPError.invalidRequest("expected_sha256 must be a SHA-256 digest")
        }
        let appendedData: Data
        switch encoding {
        case "utf8": appendedData = Data(content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: content) else {
                throw LocalMCPError.invalidRequest("invalid base64 content")
            }
            appendedData = decoded
        default: throw LocalMCPError.invalidRequest("encoding must be utf8 or base64")
        }
        let resolved = try resolveExisting(workspaceID: workspaceID, path: path)
        guard !isSensitive(resolved.relativePath), let status = resolved.status,
            status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
            status.st_size >= 0, status.st_size <= Self.maximumFileBytes
        else { throw LocalMCPError.wrongFileType }
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        let name = resolved.url.lastPathComponent
        let fd = try parent.openFile(name)
        defer { close(fd) }
        let previousData = try LocalFileReader.read(descriptor: fd, maximumBytes: Self.maximumFileBytes)
        guard LocalHash.sha256(previousData) == expectedSHA256 else {
            throw LocalMCPError.conflict("expected_sha256 does not match current content")
        }
        let (finalCount, overflow) = previousData.count.addingReportingOverflow(
            appendedData.count
        )
        guard !overflow, finalCount <= Self.maximumFileBytes else {
            throw LocalMCPError.limitExceeded("file append")
        }
        try requireUndoCapacity(fileBytes: previousData.count)
        var finalData = previousData
        finalData.append(appendedData)
        try parent.atomicWrite(finalData, name: name, mode: posixMode(status), replacing: true)
        let finalSHA256 = LocalHash.sha256(finalData)
        let transactionID = storeTransaction(
            .restoreFile(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                previousData: previousData,
                previousMode: posixMode(status),
                expectedCurrentSHA256: finalSHA256
            )
        )
        return mutationResult(
            operation: "file_append",
            transactionID: transactionID,
            details: [
                "relative_path": resolved.relativePath,
                "appended_byte_count": appendedData.count,
                "byte_count": finalData.count,
                "sha256": finalSHA256,
            ]
        )
    }

    public func createDirectory(workspaceID: String, path: String) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let resolved = try resolveDestination(workspaceID: workspaceID, path: path)
        guard resolved.status == nil else { throw LocalMCPError.conflict("path already exists") }
        try requireUndoCapacity(fileBytes: 0)
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        try parent.makeDirectory(resolved.url.lastPathComponent, mode: 0o755)
        let digest = try parent.digest(resolved.url.lastPathComponent, logicalPath: resolved.url.path)
        let transactionID = storeTransaction(
            .removeCreatedPath(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                expectedTreeSHA256: digest
            )
        )
        return mutationResult(
            operation: "directory_create",
            transactionID: transactionID,
            details: ["relative_path": resolved.relativePath, "tree_sha256": digest]
        )
    }

    public func copyPath(
        workspaceID: String,
        sourcePath: String,
        destinationPath: String
    ) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let source = try resolveExisting(workspaceID: workspaceID, path: sourcePath)
        try OperationSafety.validateRelocation(
            source: source.url,
            workspace: source.workspace
        )
        let destination = try resolveDestination(workspaceID: workspaceID, path: destinationPath)
        guard !destination.relativePath.hasPrefix(source.relativePath + "/") else {
            throw LocalMCPError.conflict("destination cannot be inside the source")
        }
        guard destination.status == nil else {
            throw LocalMCPError.conflict("destination already exists")
        }
        try requireUndoCapacity(fileBytes: 0)
        let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
        let destinationParent = try WorkspaceDirectory(destination.url.deletingLastPathComponent())
        let digest = try sourceParent.digest(source.url.lastPathComponent, logicalPath: source.url.path)
        let stagingName = ".macbridge-copy-" + UUID().uuidString.lowercased()
        try destinationParent.makeDirectory(stagingName)
        let staging = try destinationParent.child(stagingName)
        let stagingIdentity = try staging.identity()
        // The requested destination is never cleanup state. Publish only after
        // the complete, privately staged copy agrees with the source snapshot.
        defer { try? destinationParent.removeTree(stagingName, expected: stagingIdentity) }
        var budget = WorkspaceDirectory.TreeBudget()
        try sourceParent.copy(source.url.lastPathComponent, to: staging, as: "payload",
                              logicalPath: source.url.path, budget: &budget)
        guard try staging.digest("payload", logicalPath: destination.url.path) == digest else {
            throw LocalMCPError.conflict("source changed during copy; destination was not published")
        }
        try beforeCopyPublicationForTesting?()
        try destinationParent.requireIdentity(stagingName, expected: stagingIdentity)
        try staging.rename("payload", to: destinationParent, as: destination.url.lastPathComponent)
        let transactionID = storeTransaction(
            .removeCreatedPath(workspaceID: destination.workspace.id,
                relativePath: destination.relativePath, expectedTreeSHA256: digest)
        )
        return mutationResult(operation: "path_copy", transactionID: transactionID,
            details: ["source_path": source.relativePath, "destination_path": destination.relativePath,
                      "tree_sha256": digest])
    }

    public func movePath(
        workspaceID: String,
        sourcePath: String,
        destinationPath: String
    ) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let source = try resolveExisting(workspaceID: workspaceID, path: sourcePath)
        try OperationSafety.validateRelocation(source: source.url, workspace: source.workspace,
                                               additionalProtectedPaths: relocationProtectedPathsForTesting)
        let destination = try resolveDestination(workspaceID: workspaceID, path: destinationPath)
        guard !destination.relativePath.hasPrefix(source.relativePath + "/") else {
            throw LocalMCPError.conflict("destination cannot be inside the source")
        }
        guard destination.status == nil else {
            throw LocalMCPError.conflict("destination already exists")
        }
        try requireUndoCapacity(fileBytes: 0)
        let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
        let destinationParent = try WorkspaceDirectory(destination.url.deletingLastPathComponent())
        let digest = try sourceParent.digest(source.url.lastPathComponent, logicalPath: source.url.path)
        try sourceParent.rename(source.url.lastPathComponent, to: destinationParent, as: destination.url.lastPathComponent)
        let transactionID = storeTransaction(
            .moveBack(
                workspaceID: source.workspace.id,
                sourceRelativePath: source.relativePath,
                destinationRelativePath: destination.relativePath,
                expectedDestinationTreeSHA256: digest
            )
        )
        return mutationResult(
            operation: "path_move",
            transactionID: transactionID,
            details: [
                "source_path": source.relativePath,
                "destination_path": destination.relativePath,
                "tree_sha256": digest,
            ]
        )
    }

    public func removePath(workspaceID: String, path: String) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let source = try resolveExisting(workspaceID: workspaceID, path: path)
        try OperationSafety.validateRecoverableRemoval(
            target: source.url,
            workspace: source.workspace
        )
        guard !source.relativePath.split(separator: "/").contains(".macbridge")
        else { throw LocalMCPError.invalidPath(".macbridge is reserved runtime state") }
        try requireUndoCapacity(fileBytes: 0)
        let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
        let digest = try sourceParent.digest(source.url.lastPathComponent, logicalPath: source.url.path)
        let transactionID = UUID().uuidString.lowercased()
        // Broad roots may be read-only or on another volume. Keep recovery
        // alongside the removed item, so no write to /.macbridge is needed.
        let recoveryParent = source.workspace.allowsBroadAccess
            ? source.url.deletingLastPathComponent() : source.workspace.rootURL
        let state = recoveryParent.appendingPathComponent(
            ".macbridge", isDirectory: true
        )
        let recoveryRoot = state.appendingPathComponent("recovery", isDirectory: true)
        let recoveryParentHandle = source.workspace.allowsBroadAccess
            ? sourceParent : try WorkspaceDirectory(source.workspace.rootURL)
        let stateHandle = try recoveryParentHandle.privateChild(".macbridge")
        let recoveryHandle = try stateHandle.privateChild("recovery")
        let recovery = recoveryRoot.appendingPathComponent(transactionID, isDirectory: false)
        try sourceParent.rename(source.url.lastPathComponent, to: recoveryHandle, as: transactionID)
        let prefix = source.workspace.rootURL.path == "/" ? "/" : source.workspace.rootURL.path + "/"
        let recoveryRelativePath = String(recovery.path.dropFirst(prefix.count))
        storeTransaction(
            id: transactionID,
            action: .restoreRemovedPath(
                workspaceID: source.workspace.id,
                originalRelativePath: source.relativePath,
                recoveryRelativePath: recoveryRelativePath,
                expectedRecoveryTreeSHA256: digest
            )
        )
        return mutationResult(
            operation: "path_remove",
            transactionID: transactionID,
            details: [
                "relative_path": source.relativePath,
                "recovery_path": recoveryRelativePath,
                "tree_sha256": digest,
                "recovery_scope": "same-workspace; automatic restore requires this MCP process",
            ]
        )
    }

    public func restoreTransaction(_ rawID: String) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let uuid = UUID(uuidString: rawID) else {
            throw LocalMCPError.invalidRequest("transaction_id must be a UUID")
        }
        let id = uuid.uuidString.lowercased()
        transactionLock.lock()
        guard let transaction = transactions[id] else {
            transactionLock.unlock()
            throw LocalMCPError.conflict("transaction is unknown or already restored")
        }
        transactionLock.unlock()

        switch transaction.action {
        case .restoreFile(
            let workspaceID, let relativePath, let previousData, let previousMode,
            let expectedCurrentSHA256
        ):
            let current = try resolveExisting(workspaceID: workspaceID, path: relativePath)
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let name = current.url.lastPathComponent
            let fd = try parent.openFile(name)
            defer { close(fd) }
            guard let status = current.status, status.st_mode & S_IFMT == S_IFREG,
                status.st_nlink == 1,
                try LocalHash.sha256(descriptor: fd) == expectedCurrentSHA256
            else { throw LocalMCPError.conflict("file changed after the transaction") }
            if let previousData {
                try parent.atomicWrite(previousData, name: name, mode: previousMode, replacing: true)
            } else {
                try parent.unlink(name)
            }
        case .removeCreatedPath(let workspaceID, let relativePath, let expectedDigest):
            let current = try resolveExisting(workspaceID: workspaceID, path: relativePath)
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let snapshot = try parent.snapshot(current.url.lastPathComponent, logicalPath: current.url.path)
            guard snapshot.digest == expectedDigest else {
                throw LocalMCPError.conflict("created path changed after the transaction")
            }
            try parent.removeVerifiedTree(snapshot)
        case .moveBack(
            let workspaceID, let sourceRelativePath, let destinationRelativePath,
            let expectedDigest
        ):
            let source = try resolveDestination(workspaceID: workspaceID, path: sourceRelativePath)
            guard source.status == nil else {
                throw LocalMCPError.conflict("original move source is no longer empty")
            }
            let destination = try resolveExisting(
                workspaceID: workspaceID, path: destinationRelativePath
            )
            let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
            let destinationParent = try WorkspaceDirectory(destination.url.deletingLastPathComponent())
            guard try destinationParent.digest(destination.url.lastPathComponent, logicalPath: destination.url.path) == expectedDigest else {
                throw LocalMCPError.conflict("moved path changed after the transaction")
            }
            try destinationParent.rename(destination.url.lastPathComponent, to: sourceParent, as: source.url.lastPathComponent)
        case .restoreRemovedPath(
            let workspaceID, let originalRelativePath, let recoveryRelativePath,
            let expectedDigest
        ):
            let original = try resolveDestination(
                workspaceID: workspaceID, path: originalRelativePath
            )
            guard original.status == nil else {
                throw LocalMCPError.conflict("removed path destination is no longer empty")
            }
            let recovery = try resolveExisting(
                workspaceID: workspaceID, path: recoveryRelativePath
            )
            let originalParent = try WorkspaceDirectory(original.url.deletingLastPathComponent())
            let recoveryParent = try WorkspaceDirectory(recovery.url.deletingLastPathComponent())
            guard try recoveryParent.digest(recovery.url.lastPathComponent, logicalPath: recovery.url.path) == expectedDigest else {
                throw LocalMCPError.conflict("recovery path changed after removal")
            }
            try recoveryParent.rename(recovery.url.lastPathComponent, to: originalParent, as: original.url.lastPathComponent)
            let recoveryRoot = recovery.url.deletingLastPathComponent()
            let state = recoveryRoot.deletingLastPathComponent()
            try? WorkspaceDirectory(state).unlink(recoveryRoot.lastPathComponent, directory: true)
            try? WorkspaceDirectory(state.deletingLastPathComponent()).unlink(state.lastPathComponent, directory: true)
        }

        transactionLock.lock()
        transactions.removeValue(forKey: id)
        retainedUndoFileBytes -= transaction.retainedFileBytes
        transactionLock.unlock()
        return [
            "operation": "transaction_restore",
            "transaction_id": id,
            "backend_called": true,
            "mutation_performed": true,
            "execution_backend": "direct_filesystem",
        ]
    }

    public func workspaceURL(workspaceID: String, relativePath: String) throws -> URL {
        try resolveExisting(
            workspaceID: workspaceID, path: relativePath, allowRoot: true
        ).url
    }

    private func resolveExisting(
        workspaceID: String,
        path: String,
        allowRoot: Bool = false
    ) throws -> ResolvedWorkspacePath {
        let workspace = try registry.workspace(id: workspaceID)
        let (relative, components) = try relativeComponents(
            path, workspace: workspace, allowRoot: allowRoot
        )
        var current = workspace.rootURL
        let rootStatus = try lstatValue(current.path)
        guard rootStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LocalMCPError.invalidPath("registered workspace root changed")
        }
        var finalStatus: stat? = rootStatus
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: false)
            let status = try lstatValue(current.path)
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw LocalMCPError.invalidPath("symbolic links are not followed")
            }
            if index < components.count - 1, status.st_mode & S_IFMT != S_IFDIR {
                throw LocalMCPError.wrongFileType
            }
            finalStatus = status
        }
        return ResolvedWorkspacePath(
            workspace: workspace,
            relativePath: relative,
            url: current,
            status: finalStatus
        )
    }

    private func resolveDestination(
        workspaceID: String,
        path: String
    ) throws -> ResolvedWorkspacePath {
        let workspace = try registry.workspace(id: workspaceID)
        let (relative, components) = try relativeComponents(
            path, workspace: workspace, allowRoot: false
        )
        var current = workspace.rootURL
        let rootStatus = try lstatValue(current.path)
        guard rootStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LocalMCPError.invalidPath("registered workspace root changed")
        }
        for component in components.dropLast() {
            current.appendPathComponent(component, isDirectory: true)
            let status = try lstatValue(current.path)
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw LocalMCPError.wrongFileType
            }
        }
        current.appendPathComponent(components.last!, isDirectory: false)
        var targetStatus = stat()
        let exists = lstat(current.path, &targetStatus) == 0
        if exists, targetStatus.st_mode & S_IFMT == S_IFLNK {
            throw LocalMCPError.invalidPath("symbolic links are not followed")
        }
        if !exists, errno != ENOENT {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        return ResolvedWorkspacePath(
            workspace: workspace,
            relativePath: relative,
            url: current,
            status: exists ? targetStatus : nil
        )
    }

    private func relativeComponents(
        _ path: String,
        workspace: RegisteredLocalWorkspace,
        allowRoot: Bool
    ) throws -> (String, [String]) {
        guard !path.contains("\0"), !path.contains("\n"),
            path.utf8.count <= 4_096
        else { throw LocalMCPError.invalidPath(path) }
        var scopedPath = path
        if path.hasPrefix("/") {
            // Absolute spelling is not broader access: convert only paths
            // inside this exact root, then apply the same component checks.
            let root = workspace.rootURL.path
            let prefix = root == "/" ? "/" : root + "/"
            guard path == root || path.hasPrefix(prefix) else {
                throw LocalMCPError.invalidPath("path is outside the registered root")
            }
            scopedPath = path == root ? "." : String(path.dropFirst(prefix.count))
        }
        if scopedPath.isEmpty || scopedPath == "." {
            guard allowRoot else { throw LocalMCPError.invalidPath(path) }
            return (".", [])
        }
        let values = scopedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty,
            values.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw LocalMCPError.invalidPath(path) }
        let relative = values.joined(separator: "/")
        guard !isSensitive(workspace.rootURL.appendingPathComponent(relative).path) else {
            throw LocalMCPError.sensitivePathBlocked
        }
        return (relative, values)
    }

    private func isSensitive(_ relativePath: String) -> Bool {
        LocalFilesystemAccess.isSensitive(relativePath)
    }

    private func shouldSkipSearchDirectory(name: String, includeIgnored: Bool) -> Bool {
        let value = name.lowercased()
        if value == ".git" || value == ".macbridge" { return true }
        guard !includeIgnored else { return false }
        return [
            ".build", ".cache", ".next", "build", "cache", "coverage",
            "deriveddata", "dist", "node_modules", "vendor",
        ].contains(value)
    }

    private func matchesQuery(_ value: String, _ needle: String, caseSensitive: Bool) -> Bool {
        if caseSensitive { return value.contains(needle) }
        return value.lowercased().contains(needle)
    }

    private func isASCIIWithoutCR(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                if byte >= 0x80 || byte == 0x0D { return false }
            }
            return true
        }
    }

    private func asciiLineCoordinates(
        _ data: Data, searchStart: Int, hit: Range<Int>, lineNumber: Int
    ) -> (start: Int, end: Int, number: Int) {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let base = data.startIndex
            var start = searchStart
            var number = lineNumber
            for index in searchStart..<hit.lowerBound {
                if bytes[index - base] == 0x0A {
                    start = index + 1
                    number += 1
                }
            }
            var end = hit.upperBound
            while end < data.endIndex, bytes[end - base] != 0x0A { end += 1 }
            return (start, end, number)
        }
    }

    private func pathKind(_ status: stat) -> String {
        switch status.st_mode & S_IFMT {
        case S_IFREG: return status.st_nlink == 1 ? "file" : "hardlink-blocked"
        case S_IFDIR: return "directory"
        case S_IFLNK: return "symlink-blocked"
        default: return "special-blocked"
        }
    }

    private func metadata(relativePath: String, status: stat, kind: String) -> JSONObject {
        [
            "relative_path": relativePath,
            "kind": kind,
            "byte_count": max(0, status.st_size),
            "mode": posixMode(status),
            "modified_milliseconds":
                Int64(status.st_mtimespec.tv_sec) * 1_000
                + Int64(status.st_mtimespec.tv_nsec / 1_000_000),
        ]
    }

    private func treeDigest(_ root: URL) throws -> String {
        try WorkspaceDirectory(root.deletingLastPathComponent()).digest(root.lastPathComponent, logicalPath: root.path)
    }

    // Caller holds transactionLock until mutation and publication both finish.
    private func requireUndoCapacity(fileBytes: Int) throws {
        guard transactions.count < transactionLimit, nextTransactionSequence < Int.max,
              fileBytes <= undoFileByteLimit - retainedUndoFileBytes else {
            throw LocalMCPError.limitExceeded(
                "retained undo budget; restore or explicitly accept selected transactions before another mutation"
            )
        }
    }

    private func storeTransaction(_ action: UndoAction) -> String {
        let id = UUID().uuidString.lowercased()
        storeTransaction(id: id, action: action)
        return id
    }

    private func storeTransaction(id: String, action: UndoAction) {
        transactionLock.lock()
        nextTransactionSequence += 1
        let transaction = StoredTransaction(action: action, sequence: nextTransactionSequence)
        transactions[id] = transaction
        retainedUndoFileBytes += transaction.retainedFileBytes
        transactionLock.unlock()
    }

    private func mutationResult(
        operation: String,
        transactionID: String,
        details: JSONObject
    ) -> JSONObject {
        var result = details
        result["operation"] = operation
        result["transaction_id"] = transactionID
        result["backend_called"] = true
        result["mutation_performed"] = true
        result["execution_backend"] = "direct_filesystem"
        return result
    }
}
