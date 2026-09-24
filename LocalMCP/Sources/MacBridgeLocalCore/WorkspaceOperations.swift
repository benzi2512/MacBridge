import Darwin
import Foundation

private struct ResolvedWorkspacePath {
    let workspace: RegisteredLocalWorkspace
    let relativePath: String
    let url: URL
    let status: stat?
}

private indirect enum UndoAction {
    case restoreFile(
        workspaceID: String,
        relativePath: String,
        previousData: Data?,
        previousMode: Int,
        expectedCurrentStamp: FileRevisionStamp
    )
    case removeCreatedPath(
        workspaceID: String,
        relativePath: String,
        expectedTreeSHA256: String,
        expectedTreeRevisionSHA256: String,
        expectedTreeRevisionRows: [String: String],
        expectedStableMetadataRows: [String: String],
        expectedRootMetadataSHA256: String,
        expectedRootStamp: TreeRootStamp
    )
    case moveBack(
        workspaceID: String,
        sourceRelativePath: String,
        destinationRelativePath: String,
        expectedDestinationTreeSHA256: String,
        expectedDestinationTreeRevisionSHA256: String,
        expectedRootStamp: TreeRootStamp
    )
    case restoreRemovedPath(
        workspaceID: String,
        originalRelativePath: String,
        recoveryRelativePath: String,
        expectedRecoveryTreeSHA256: String,
        expectedRecoveryTreeRevisionSHA256: String,
        expectedRootStamp: TreeRootStamp
    )
    /// Recovery-only receipt used when a rename completed but a complete tree
    /// snapshot could not be obtained. It may move the same root inode back to
    /// its original spelling, but never authorizes deleting its contents.
    case restoreRelocatedPath(
        workspaceID: String,
        originalRelativePath: String,
        recoveryRelativePath: String,
        expectedRootStamp: TreeRootStamp
    )
    case composite([UndoAction])
}

private struct StoredTransaction {
    var action: UndoAction
    let sequence: Int
    var workID: String?

    var retainedFileBytes: Int {
        func bytes(_ action: UndoAction) -> Int {
            switch action {
            case .restoreFile(_, _, let data, _, _): return data?.count ?? 0
            case .composite(let actions): return actions.reduce(0) { $0 + bytes($1) }
            default: return 0
            }
        }
        return bytes(action)
    }
}

public struct AtomicFileWriteRequest: Sendable {
    public let path: String
    public let content: String
    public let expectedSHA256: String?
    public let createOnly: Bool

    public init(path: String, content: String, expectedSHA256: String?, createOnly: Bool) {
        self.path = path
        self.content = content
        self.expectedSHA256 = expectedSHA256
        self.createOnly = createOnly
    }
}

private struct PreparedAtomicFileWrite {
    let workspaceID: String
    let relativePath: String
    let url: URL
    let parent: WorkspaceDirectory
    let data: Data
    let previousData: Data?
    let previousMode: Int
    let previousStamp: FileRevisionStamp?
    let postSHA256: String
}

private struct FileRevisionStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let links: nlink_t
    let owner: uid_t
    let group: gid_t
    let flags: UInt32
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let sha256: String

    init(_ status: stat, sha256: String) {
        device = status.st_dev
        inode = status.st_ino
        mode = status.st_mode
        links = status.st_nlink
        owner = status.st_uid
        group = status.st_gid
        flags = status.st_flags
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
        self.sha256 = sha256
    }

    var modifiedMilliseconds: Int64 {
        Int64(modifiedSeconds) * 1_000 + Int64(modifiedNanoseconds / 1_000_000)
    }

    /// Content finalization releases rollback only; it does not write the file.
    /// Finder and file providers may replace or retimestamp an unchanged file
    /// after publication, so inode and timestamps are not stable evidence here.
    /// Keep the stable security-relevant metadata and exact bytes bound instead.
    /// macOS may derive UF_HIDDEN from a dotfile name after publication, so
    /// st_flags is not stable enough to gate rollback release either.
    func matchesFinalizedWrite(_ other: FileRevisionStamp) -> Bool {
        device == other.device && mode == other.mode && links == other.links
            && owner == other.owner && group == other.group && size == other.size
            && sha256 == other.sha256
    }
}

private struct TreeRootStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let links: nlink_t
    let owner: uid_t
    let group: gid_t
    let size: off_t
    let flags: UInt32
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        links = value.st_nlink; owner = value.st_uid; group = value.st_gid
        size = value.st_size; flags = value.st_flags
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }

    /// Child creation/removal legitimately changes a directory's link count,
    /// size and timestamps. These fields identify metadata that the child
    /// mutation itself cannot explain and therefore must never be blessed by
    /// retargeting an older bridge-owned tree undo.
    func hasSameStableRoot(as other: TreeRootStamp) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode
            && owner == other.owner && group == other.group && flags == other.flags
    }

    func hasSameIdentity(as other: TreeRootStamp) -> Bool {
        device == other.device && inode == other.inode
            && mode & S_IFMT == other.mode & S_IFMT
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
    private let afterRelocationBeforeSnapshotForTesting: ((String, URL, URL) throws -> Void)?
    private let afterQuarantineRenameForTesting: ((WorkspaceDirectory, String, String) throws -> Void)?
    private let beforeQuarantineEntryRemovalForTesting: ((String) throws -> Void)?
    private let relocationProtectedPathsForTesting: Set<String>
    private let protectedMutationPaths: Set<String>
    // One bounded name index, never file content or cached file metadata. It is
    // only a flat-directory fast path; recursive traversal keeps its existing
    // semantics. A new registry/owner starts empty. No timer or background work.
    private let directoryNameLock = NSLock()
    private var directoryNameIndex: DirectoryNamePageIndex?
    private static let maximumDirectoryNameBytes = 4 * 1_024 * 1_024
    private let observerFilePreviews = ObserverFilePreview()

    public convenience init(registry: LocalWorkspaceRegistry, protectedMutationPaths: Set<String> = []) {
        self.init(registry: registry, transactionLimit: Self.maximumRetainedTransactions,
                  undoFileByteLimit: Self.maximumRetainedUndoFileBytes,
                  protectedMutationPaths: protectedMutationPaths)
    }

    init(registry: LocalWorkspaceRegistry, transactionLimit: Int, undoFileByteLimit: Int,
         beforeCopyPublicationForTesting: (() throws -> Void)? = nil,
         afterRelocationBeforeSnapshotForTesting: ((String, URL, URL) throws -> Void)? = nil,
         afterQuarantineRenameForTesting: ((WorkspaceDirectory, String, String) throws -> Void)? = nil,
         beforeQuarantineEntryRemovalForTesting: ((String) throws -> Void)? = nil,
         relocationProtectedPathsForTesting: Set<String> = [],
         protectedMutationPaths: Set<String> = []) {
        precondition(transactionLimit >= 0 && undoFileByteLimit >= 0)
        self.registry = registry
        self.transactionLimit = transactionLimit
        self.undoFileByteLimit = undoFileByteLimit
        self.beforeCopyPublicationForTesting = beforeCopyPublicationForTesting
        self.afterRelocationBeforeSnapshotForTesting = afterRelocationBeforeSnapshotForTesting
        self.afterQuarantineRenameForTesting = afterQuarantineRenameForTesting
        self.beforeQuarantineEntryRemovalForTesting = beforeQuarantineEntryRemovalForTesting
        self.relocationProtectedPathsForTesting = Set(relocationProtectedPathsForTesting.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        self.protectedMutationPaths = Set(protectedMutationPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
    }

    var retainedTransactionCount: Int {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return transactions.count
    }

    func retainedTransactionIDs() -> Set<String> {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return Set(transactions.keys)
    }

    func associateTransactions(_ rawIDs: [String], workID: String?) {
        guard let workID else { return }
        transactionLock.lock()
        defer { transactionLock.unlock() }
        for raw in rawIDs {
            guard let id = UUID(uuidString: raw)?.uuidString.lowercased(),
                  var stored = transactions[id] else { continue }
            stored.workID = workID
            transactions[id] = stored
        }
    }

    /// Confirm that a retained, work-owned write transaction describes the
    /// exact artifact bytes still present at the requested workspace path.
    /// This is runtime-local evidence, not durable scheduler storage.
    func verifyArtifactPersistence(
        workspaceID: String,
        path: String,
        sha256: String,
        transactionID rawTransactionID: String,
        workID: String
    ) throws {
        guard LocalHash.isSHA256(sha256),
              let transactionID = UUID(uuidString: rawTransactionID)?.uuidString.lowercased(),
              let normalizedWorkID = UUID(uuidString: workID)?.uuidString.lowercased() else {
            throw LocalMCPError.invalidRequest("artifact persistence evidence is malformed")
        }
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let stored = transactions[transactionID], stored.workID == normalizedWorkID else {
            throw LocalMCPError.conflict("write transaction is not retained by this work item")
        }
        let resolved = try resolveExisting(workspaceID: workspaceID, path: path)
        let expectedPath = resolved.relativePath
        func proves(_ action: UndoAction) -> Bool {
            switch action {
            case .restoreFile(let candidateWorkspace, let candidatePath, _, _, let postStamp):
                return candidateWorkspace.lowercased() == workspaceID.lowercased()
                    && candidatePath == expectedPath && postStamp.sha256 == sha256.lowercased()
            case .composite(let actions): return actions.contains(where: proves)
            default: return false
            }
        }
        guard proves(stored.action) else {
            throw LocalMCPError.conflict("transaction does not prove this artifact path and hash")
        }
        guard try LocalHash.sha256(fileAt: resolved.url) == sha256.lowercased() else {
            throw LocalMCPError.casConflict(
                expectedSHA256: sha256.lowercased(),
                currentSHA256: try LocalHash.sha256(fileAt: resolved.url),
                modifiedMilliseconds: Int64((resolved.status?.st_mtimespec.tv_sec ?? 0)) * 1_000
            )
        }
    }

    public func workspaceOverview() -> JSONObject {
        ["workspaces": registry.workspaces.map(\.json)]
    }

    /// Deterministically choose the most-specific registered workspace for one
    /// canonical local path. This never registers or widens access.
    public func resolveWorkspace(path: String) throws -> JSONObject {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.contains("\0"), !path.contains("\n"), !path.hasPrefix("~") else {
            throw LocalMCPError.invalidPath("workspace_resolve requires one absolute local path")
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var status = stat()
        let exists = lstat(path, &status) == 0
        let canonical: String
        if exists {
            canonical = try canonicalExistingPath(path)
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw LocalMCPError.invalidPath("symbolic links are not workspace identities")
            }
        } else {
            guard errno == ENOENT else { throw LocalMCPError.operationFailed(String(cString: strerror(errno))) }
            canonical = standardized
        }
        guard !LocalFilesystemAccess.isSensitive(canonical) else {
            throw LocalMCPError.sensitivePathBlocked
        }
        let matches = registry.workspaces.filter { workspace in
            let root = workspace.rootURL.path
            return canonical == root || canonical.hasPrefix(root == "/" ? "/" : root + "/")
        }.sorted { $0.rootURL.path.count > $1.rootURL.path.count }
        guard let workspace = matches.first else { throw LocalMCPError.unknownWorkspace }
        let root = workspace.rootURL.path
        let relative = canonical == root ? "." : String(canonical.dropFirst(root == "/" ? 1 : root.count + 1))
        return [
            "workspace_id": workspace.id, "display_name": workspace.name,
            "relative_path": relative, "canonical_path": canonical,
            "exists": exists, "match_policy": "most_specific_registered_root",
            "access_changed": false,
        ]
    }

    /// A bridge-mutation-consistent batch read. Each path is fingerprinted
    /// before and after the read; any external change rejects the whole result.
    public func readFilesSnapshot(workspaceID: String, paths: [String], encoding: String,
                                  maximumBytesPerFile: Int, maximumTotalBytes: Int) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let before = try statPaths(workspaceID: workspaceID, paths: paths, includeSHA256: true)
        var result = try readFiles(workspaceID: workspaceID, paths: paths, encoding: encoding,
                                   maximumBytesPerFile: maximumBytesPerFile,
                                   maximumTotalBytes: maximumTotalBytes)
        let after = try statPaths(workspaceID: workspaceID, paths: paths, includeSHA256: true)
        let beforeRows = try LocalJSON.encode(before["results"] ?? [])
        let afterRows = try LocalJSON.encode(after["results"] ?? [])
        guard beforeRows == afterRows else {
            throw LocalMCPError.conflict("one or more files changed during snapshot read")
        }
        result["snapshot_atomic"] = true
        result["snapshot_consistent"] = true
        result["snapshot_token"] = LocalHash.sha256(beforeRows)
        result["consistency_scope"] = "bridge mutation lock plus pre/post filesystem fingerprints"
        return result
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
            "blocking_reload_count": transactions.count,
            "warning": transactions.isEmpty ? "none" : "Retained undo blocks workspace reload and shared-runtime restart decisions until each transaction is classified.",
        ]
        let grouped = Dictionary(grouping: transactions.values.compactMap { $0.workID }, by: { $0 })
        result["work_groups"] = grouped.keys.sorted().map { ["work_id": $0, "transaction_count": grouped[$0]?.count ?? 0] as JSONObject }
        if eligible.count > maximumTransactions, let last = page.last {
            result["next_cursor"] = "\(transactionCursorNamespace):\(last.value.sequence)"
        }
        return result
    }

    private func transactionMetadata(id: String, stored: StoredTransaction) -> JSONObject {
        var result: JSONObject = [
            "transaction_id": id, "sequence": stored.sequence,
            "retained_undo_file_bytes": stored.retainedFileBytes,
            "recoverable": true, "blocks_reload": true,
            "review_classification": "requires_review",
            "automatic_accept_allowed": false,
        ]
        if let workID = stored.workID { result["work_id"] = workID }
        switch stored.action {
        case .restoreFile(let workspace, let path, let before, _, let after):
            result["workspace_id"] = workspace; result["path"] = path; result["kind"] = "file"
            result["pre_sha256"] = before.map(LocalHash.sha256) ?? "absent"
            result["post_sha256"] = after.sha256
        case .removeCreatedPath(let workspace, let path, _, _, _, _, _, _):
            result["workspace_id"] = workspace; result["path"] = path; result["kind"] = "created_path"
        case .moveBack(let workspace, let source, let destination, _, _, _):
            result["workspace_id"] = workspace; result["path"] = source; result["kind"] = "moved_path"
            result["destination_path"] = destination
        case .restoreRemovedPath(let workspace, let path, let recovery, let digest, _, _):
            result["workspace_id"] = workspace; result["path"] = path; result["kind"] = "removed_path"
            result["recovery_path"] = recovery
            result["expected_recovery_tree_sha256"] = digest
        case .restoreRelocatedPath(let workspace, let path, let recovery, _):
            result["workspace_id"] = workspace; result["path"] = path
            result["kind"] = "relocated_recovery"
            result["recovery_path"] = recovery
            result["recovery_preserves_current_tree"] = true
        case .composite(let actions):
            result["kind"] = "file_batch"
            result["operation_count"] = actions.count
            result["paths"] = actions.compactMap { action -> String? in
                if case .restoreFile(_, let path, _, _, _) = action { return path }
                return nil
            }
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
            } else if case .restoreRelocatedPath = stored.action {
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

    /// Finalize one single-file write transaction after revalidating its exact
    /// workspace path, preimage, postimage and full post-write revision. This
    /// recovery route exists for a later owner turn when the creator capability
    /// is no longer available. It cannot finalize batches, moves or removals.
    public func finalizeFileTransaction(
        transactionID rawID: String,
        workspaceID: String,
        path: String,
        expectedPreSHA256: String,
        expectedPostSHA256: String
    ) throws -> JSONObject {
        guard let transactionID = UUID(uuidString: rawID)?.uuidString.lowercased(),
              expectedPreSHA256 == "absent" || LocalHash.isSHA256(expectedPreSHA256),
              LocalHash.isSHA256(expectedPostSHA256) else {
            throw LocalMCPError.invalidRequest("file-finalization evidence is malformed")
        }
        let expectedPreimage = expectedPreSHA256.lowercased()
        let expectedSHA256 = expectedPostSHA256.lowercased()
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let stored = transactions[transactionID] else {
            throw LocalMCPError.conflict(
                "transaction is unknown or no longer retained; no undo released"
            )
        }
        guard case .restoreFile(
            let retainedWorkspaceID, let retainedPath, let previousData, _, let postStamp
        ) = stored.action else {
            throw LocalMCPError.conflict(
                "only one single-file write transaction can use evidence finalization"
            )
        }
        guard retainedWorkspaceID.lowercased() == workspaceID.lowercased(),
              (previousData.map(LocalHash.sha256) ?? "absent") == expectedPreimage,
              postStamp.sha256 == expectedSHA256 else {
            throw LocalMCPError.conflict(
                "file-finalization evidence does not match the retained transaction"
            )
        }
        let resolved = try resolveExisting(workspaceID: workspaceID, path: path)
        guard resolved.relativePath == retainedPath else {
            throw LocalMCPError.conflict(
                "file-finalization path does not match the retained transaction"
            )
        }
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        let current = try fileRevision(parent: parent, name: resolved.url.lastPathComponent)
        guard current.stamp.matchesFinalizedWrite(postStamp) else {
            throw LocalMCPError.casConflict(
                expectedSHA256: expectedSHA256,
                currentSHA256: current.stamp.sha256,
                modifiedMilliseconds: current.stamp.modifiedMilliseconds
            )
        }
        var receipt = transactionMetadata(id: transactionID, stored: stored)
        receipt["automatic_restore_available"] = false
        transactions.removeValue(forKey: transactionID)
        retainedUndoFileBytes -= stored.retainedFileBytes
        return [
            "operation": "transaction_finalize_file",
            "finalized": receipt,
            "finalized_count": 1,
            "released_undo_file_bytes": stored.retainedFileBytes,
            "retained_transaction_count": transactions.count,
            "retained_undo_file_bytes": retainedUndoFileBytes,
            "backend_called": true,
            "undo_released": true,
            "filesystem_mutation_performed": false,
            "current_file_state_validated": true,
            "verification_scope": "one unchanged single-file write",
            "execution_backend": "owner_transaction_registry",
            "meaning": "Verified file write kept; its in-memory automatic rollback was released. Other transactions were untouched.",
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
        case .removeCreatedPath(let w, let p, _, _, _, _, _, _): workspace = w; path = p; kind = "created path"
        case .moveBack(let w, let p, _, _, _, _): workspace = w; path = p; kind = "moved path"
        case .restoreRemovedPath(let w, let p, _, _, _, _): workspace = w; path = p; kind = "removed path"
        case .restoreRelocatedPath(let w, let p, _, _): workspace = w; path = p; kind = "relocated recovery"
        case .composite(let actions):
            workspace = actions.compactMap { action -> String? in
                if case .restoreFile(let w, _, _, _, _) = action { return w }
                return nil
            }.first ?? ""
            path = actions.compactMap { action -> String? in
                if case .restoreFile(_, let p, _, _, _) = action { return p }
                return nil
            }.joined(separator: ", ")
            kind = "file batch"
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
            detail["expected_after_sha256"] = expected.sha256
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
        let verified = try verifyRestoredUndo(action, result: &result)
        result["readback_verified"] = verified
        if !verified { throw LocalMCPError.conflict("restore completed but independent readback did not match; inspect state") }
        return result
    }

    private func verifyRestoredUndo(_ action: UndoAction, result: inout JSONObject) throws -> Bool {
        switch action {
        case .restoreFile(let w, let p, let previous, _, _):
            if let previous {
                let current = try statPath(workspaceID: w, path: p)["path"] as? JSONObject
                let digest = current?["sha256"] as? String
                let verified = digest == LocalHash.sha256(previous)
                result["readback_sha256"] = digest ?? NSNull()
                return verified
            } else {
                return try resolveDestination(workspaceID: w, path: p).status == nil
            }
        case .removeCreatedPath(let w, let p, _, _, _, _, _, _):
            return try resolveDestination(workspaceID: w, path: p).status == nil
        case .moveBack(let w, let source, let destination, let digest, _, _):
            let restored = try resolveExisting(workspaceID: w, path: source)
            return try treeDigest(restored.url) == digest
                && resolveDestination(workspaceID: w, path: destination).status == nil
        case .restoreRemovedPath(let w, let p, _, let digest, _, _):
            return try treeDigest(resolveExisting(workspaceID: w, path: p).url) == digest
        case .restoreRelocatedPath(let w, let original, let recovery, let stamp):
            let restored = try resolveExisting(workspaceID: w, path: original)
            let recoveryMissing = try resolveDestination(
                workspaceID: w, path: recovery
            ).status == nil
            return TreeRootStamp(try lstatValue(restored.url.path))
                .hasSameStableRoot(as: stamp) && recoveryMissing
        case .composite(let actions):
            for item in actions {
                if try !verifyRestoredUndo(item, result: &result) { return false }
            }
            return true
        }
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
        let descriptor = try LocalFileReader.openFile(url: resolved.url)
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
        // A bounded page read must not turn into an implicit multi-gigabyte scan.
        // Preserve the whole-file digest for ordinary project files, but report
        // it as unavailable for files beyond the existing mutation/hash limit.
        let wholeSHA256 = totalBytes <= Self.maximumFileBytes
            ? try LocalHash.sha256(
                descriptor: descriptor, maximumBytes: Int64(Self.maximumFileBytes)
            ) : nil
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == status.st_dev, after.st_ino == status.st_ino,
              after.st_size == status.st_size,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec else {
            throw LocalMCPError.conflict("file changed during read")
        }
        let modifiedMilliseconds = Int64(status.st_mtimespec.tv_sec) * 1_000
            + Int64(status.st_mtimespec.tv_nsec / 1_000_000)
        let versionToken = LocalHash.sha256(Data(
            "\(status.st_dev):\(status.st_ino):\(status.st_size):\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(wholeSHA256 ?? "unavailable")".utf8
        ))
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
            "whole_sha256_available": wholeSHA256 != nil,
            "modified_milliseconds": modifiedMilliseconds,
            "inode": UInt64(status.st_ino),
            "device": UInt64(status.st_dev),
            "version_token": versionToken,
        ]
        if let wholeSHA256 { file["sha256"] = wholeSHA256 }
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
        expectedSHA256: String?,
        createOnly: Bool = false
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
        try OperationSafety.validateMutationTarget(resolved.url, protectedPaths: protectedMutationPaths)
        guard !isSensitive(resolved.relativePath) else {
            throw LocalMCPError.sensitivePathBlocked
        }
        let previousData: Data?
        let previousMode: Int
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        let name = resolved.url.lastPathComponent
        var previousStamp: FileRevisionStamp?
        if try parent.status(name) != nil {
            let revision = try fileRevision(parent: parent, name: name)
            let status = revision.status
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                status.st_size >= 0, status.st_size <= Self.maximumFileBytes
            else { throw LocalMCPError.wrongFileType }
            let currentSHA = revision.stamp.sha256
            let modified = revision.stamp.modifiedMilliseconds
            if createOnly {
                throw LocalMCPError.createOnlyConflict(
                    currentSHA256: currentSHA, modifiedMilliseconds: modified
                )
            }
            guard let expectedSHA256, LocalHash.isSHA256(expectedSHA256) else {
                throw LocalMCPError.conflict("expected_sha256 is required when replacing a file")
            }
            previousData = revision.data
            previousStamp = revision.stamp
            guard currentSHA == expectedSHA256.lowercased() else {
                throw LocalMCPError.casConflict(
                    expectedSHA256: expectedSHA256.lowercased(),
                    currentSHA256: currentSHA, modifiedMilliseconds: modified
                )
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
        let published = try parent.atomicWrite(
            data, name: name, mode: previousMode, replacing: previousData != nil
        ) { [self] in
            try verifyPreimage(parent: parent, name: name, expected: previousStamp)
        }
        let finalSHA256 = LocalHash.sha256(data)
        let finalStamp = FileRevisionStamp(published, sha256: finalSHA256)
        let transactionID = storeTransaction(
            .restoreFile(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                previousData: previousData,
                previousMode: previousMode,
                expectedCurrentStamp: finalStamp
            )
        )
        return mutationResult(
            operation: "file_write",
            transactionID: transactionID,
            details: [
                "relative_path": resolved.relativePath,
                "byte_count": data.count,
                "sha256": finalSHA256,
                "pre_sha256": previousData.map(LocalHash.sha256) ?? "absent",
                "post_sha256": finalSHA256,
                "created": previousData == nil,
                "create_only": createOnly,
            ]
        )
    }

    /// Preflights every destination before publishing any write and retains one
    /// composite undo transaction for the complete batch. A write-time failure
    /// is compensated in reverse order before the error is returned.
    public func writeFilesAtomic(
        workspaceID: String,
        requests: [AtomicFileWriteRequest]
    ) throws -> JSONObject {
        guard (1...16).contains(requests.count) else {
            throw LocalMCPError.invalidRequest("select between 1 and 16 files")
        }
        transactionLock.lock()
        defer { transactionLock.unlock() }

        var prepared: [PreparedAtomicFileWrite] = []
        var destinationKeys = Set<String>()
        var totalWriteBytes = 0
        var totalUndoBytes = 0
        for request in requests {
            let data = Data(request.content.utf8)
            guard data.count <= 262_144 else {
                throw LocalMCPError.limitExceeded("one batch file exceeds 256 KiB")
            }
            totalWriteBytes += data.count
            guard totalWriteBytes <= 1_048_576 else {
                throw LocalMCPError.limitExceeded("batch content exceeds 1 MiB")
            }
            let resolved = try resolveDestination(workspaceID: workspaceID, path: request.path)
            try OperationSafety.validateMutationTarget(
                resolved.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
            let name = resolved.url.lastPathComponent
            let parentPath = resolved.url.deletingLastPathComponent()
            let parentStatus = try lstatValue(parentPath.path)
            let caseSensitive = (try? parentPath.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames) ?? true
            let normalizedName = name.precomposedStringWithCanonicalMapping
            let destinationKey = "\(parentStatus.st_dev):\(parentStatus.st_ino)\0"
                + (caseSensitive ? normalizedName : normalizedName.folding(
                    options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
                ))
            guard destinationKeys.insert(destinationKey).inserted else {
                throw LocalMCPError.invalidRequest("duplicate or aliased destination paths")
            }
            let previousData: Data?
            let previousMode: Int
            let previousStamp: FileRevisionStamp?
            if try parent.status(name) != nil {
                let revision = try fileRevision(parent: parent, name: name)
                let status = revision.status
                guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                      status.st_size >= 0, status.st_size <= Self.maximumFileBytes else {
                    throw LocalMCPError.wrongFileType
                }
                let currentSHA = revision.stamp.sha256
                let modified = revision.stamp.modifiedMilliseconds
                if request.createOnly {
                    throw LocalMCPError.createOnlyConflict(
                        currentSHA256: currentSHA, modifiedMilliseconds: modified
                    )
                }
                guard let expected = request.expectedSHA256, LocalHash.isSHA256(expected) else {
                    throw LocalMCPError.conflict("expected_sha256 is required when replacing a file")
                }
                guard currentSHA == expected.lowercased() else {
                    throw LocalMCPError.casConflict(
                        expectedSHA256: expected.lowercased(),
                        currentSHA256: currentSHA, modifiedMilliseconds: modified
                    )
                }
                previousData = revision.data
                previousMode = posixMode(status)
                previousStamp = revision.stamp
            } else {
                guard request.expectedSHA256 == nil else {
                    throw LocalMCPError.conflict("expected_sha256 supplied for a new file")
                }
                previousData = nil
                previousMode = 0o644
                previousStamp = nil
            }
            totalUndoBytes += previousData?.count ?? 0
            prepared.append(PreparedAtomicFileWrite(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                url: resolved.url,
                parent: parent,
                data: data,
                previousData: previousData,
                previousMode: previousMode,
                previousStamp: previousStamp,
                postSHA256: LocalHash.sha256(data)
            ))
        }
        try requireUndoCapacity(fileBytes: totalUndoBytes)

        var committed: [(item: PreparedAtomicFileWrite, stamp: FileRevisionStamp)] = []
        do {
            for item in prepared {
                let parent = item.parent
                let published = try parent.atomicWrite(
                    item.data,
                    name: item.url.lastPathComponent,
                    mode: item.previousMode,
                    replacing: item.previousData != nil
                ) { [self] in
                    try verifyPreimage(
                        parent: parent,
                        name: item.url.lastPathComponent,
                        expected: item.previousStamp
                    )
                }
                committed.append((item, FileRevisionStamp(published, sha256: item.postSHA256)))
            }
        } catch {
            var failures: [(action: UndoAction, error: Error)] = []
            for committedItem in committed.reversed() {
                let item = committedItem.item
                do {
                    let parent = item.parent
                    let written = try fileRevision(
                        parent: parent, name: item.url.lastPathComponent
                    )
                    guard written.stamp == committedItem.stamp else {
                        throw LocalMCPError.conflict("batch rollback refused because a written file changed")
                    }
                    if let previous = item.previousData {
                        let restored = try parent.atomicWrite(
                            previous, name: item.url.lastPathComponent,
                            mode: item.previousMode, replacing: true
                        ) { [self] in
                            try verifyPreimage(
                                parent: parent, name: item.url.lastPathComponent,
                                expected: written.stamp
                            )
                        }
                        retargetRetainedFileUndo(
                            workspaceID: item.workspaceID,
                            relativePath: item.relativePath,
                            restoredStamp: FileRevisionStamp(
                                restored, sha256: LocalHash.sha256(previous)
                            )
                        )
                    } else {
                        try verifyPreimage(
                            parent: parent, name: item.url.lastPathComponent,
                            expected: written.stamp
                        )
                        try parent.unlink(item.url.lastPathComponent)
                    }
                } catch {
                    failures.append((
                        .restoreFile(
                            workspaceID: item.workspaceID,
                            relativePath: item.relativePath,
                            previousData: item.previousData,
                            previousMode: item.previousMode,
                            expectedCurrentStamp: committedItem.stamp
                        ), error
                    ))
                }
            }
            if !failures.isEmpty {
                let transactionID = storeTransaction(.composite(failures.map(\.action)))
                throw LocalMCPError.partial(
                    "batch publication failed; compensation recovered every still-safe write and retained \(failures.count) conflicted write(s) under transaction_id \(transactionID). First failure: \(failures[0].error)"
                )
            }
            if committed.isEmpty { throw error }
            throw LocalMCPError.compensated(
                "batch publication failed; earlier file contents and POSIX modes were restored, but inode, extended attributes, ACLs or other filesystem metadata may differ. Original failure: \(error)"
            )
        }

        let actions = committed.map {
            UndoAction.restoreFile(
                workspaceID: $0.item.workspaceID,
                relativePath: $0.item.relativePath,
                previousData: $0.item.previousData,
                previousMode: $0.item.previousMode,
                expectedCurrentStamp: $0.stamp
            )
        }
        let transactionID = storeTransaction(.composite(actions))
        let rows: [JSONObject] = prepared.map {
            [
                "path": $0.relativePath,
                "status": "ok",
                "byte_count": $0.data.count,
                "pre_sha256": $0.previousData.map(LocalHash.sha256) ?? "absent",
                "post_sha256": $0.postSHA256,
                "created": $0.previousData == nil,
            ]
        }
        return mutationResult(
            operation: "file_write_many",
            transactionID: transactionID,
            details: [
                "results": rows,
                "success_count": rows.count,
                "error_count": 0,
                "complete": true,
                "batch_atomic": false,
                "all_or_compensated": true,
                "compensation_scope": "file content and POSIX mode; inode, extended attributes, ACLs and other filesystem metadata are not preserved",
                "crash_atomic": false,
                "external_writer_isolation": false,
                "atomicity_scope": "serialized in this runtime; every publication revalidates its preimage and a detected failure triggers verified compensation",
                "total_byte_count": totalWriteBytes,
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
              let currentSHA = file["sha256"] as? String else {
            throw LocalMCPError.operationFailed("unexpected file revision response")
        }
        guard currentSHA == expectedSHA256.lowercased() else {
            throw LocalMCPError.casConflict(
                expectedSHA256: expectedSHA256.lowercased(),
                currentSHA256: currentSHA,
                modifiedMilliseconds: file["modified_milliseconds"] as? Int64 ?? 0
            )
        }
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
        try OperationSafety.validateMutationTarget(resolved.url, protectedPaths: protectedMutationPaths)
        guard !isSensitive(resolved.relativePath), let status = resolved.status,
            status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
            status.st_size >= 0, status.st_size <= Self.maximumFileBytes
        else { throw LocalMCPError.wrongFileType }
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        let name = resolved.url.lastPathComponent
        let revision = try fileRevision(parent: parent, name: name)
        let previousData = revision.data
        guard revision.stamp.sha256 == expectedSHA256.lowercased() else {
            throw LocalMCPError.casConflict(
                expectedSHA256: expectedSHA256.lowercased(),
                currentSHA256: revision.stamp.sha256,
                modifiedMilliseconds: revision.stamp.modifiedMilliseconds
            )
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
        let published = try parent.atomicWrite(
            finalData, name: name, mode: posixMode(status), replacing: true
        ) { [self] in
            try verifyPreimage(parent: parent, name: name, expected: revision.stamp)
        }
        let finalSHA256 = LocalHash.sha256(finalData)
        let finalStamp = FileRevisionStamp(published, sha256: finalSHA256)
        let transactionID = storeTransaction(
            .restoreFile(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                previousData: previousData,
                previousMode: posixMode(status),
                expectedCurrentStamp: finalStamp
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

    private func storeCreatedPathUndo(
        workspaceID: String,
        relativePath: String,
        expected: WorkspaceDirectory.TreeSnapshot,
        currentRootStatus: stat
    ) -> String {
        storeTransaction(
            .removeCreatedPath(
                workspaceID: workspaceID,
                relativePath: relativePath,
                expectedTreeSHA256: expected.digest,
                expectedTreeRevisionSHA256: expected.revisionDigest,
                expectedTreeRevisionRows: expected.revisionRows,
                expectedStableMetadataRows: expected.stableMetadataRows,
                expectedRootMetadataSHA256: expected.root.metadataDigest,
                expectedRootStamp: TreeRootStamp(currentRootStatus)
            )
        )
    }

    private func publishedTreeMatchesPreparedTree(
        _ published: WorkspaceDirectory.TreeSnapshot,
        expected: WorkspaceDirectory.TreeSnapshot
    ) -> Bool {
        published.digest == expected.digest
            && published.descendantRevisionDigest == expected.descendantRevisionDigest
            && published.stableMetadataRows == expected.stableMetadataRows
            && published.root.metadataDigest == expected.root.metadataDigest
            && TreeRootStamp(published.root.version).hasSameStableRoot(
                as: TreeRootStamp(expected.root.version)
            )
    }

    /// A conservative created-path receipt intentionally combines the exact
    /// post-publication root stamp with a tree captured before the bridge-owned
    /// rename. The rename may change volatile root revision fields, but it must
    /// not authorize any descendant or stable-metadata change.
    private func createdPathSnapshotMatchesUndo(
        _ snapshot: WorkspaceDirectory.TreeSnapshot,
        expectedDigest: String,
        expectedRevisionDigest: String,
        expectedRevisionRows: [String: String],
        expectedStableMetadataRows: [String: String],
        expectedRootMetadataDigest: String,
        expectedRootStamp: TreeRootStamp
    ) -> Bool {
        guard snapshot.digest == expectedDigest,
              snapshot.root.metadataDigest == expectedRootMetadataDigest,
              TreeRootStamp(snapshot.root.version) == expectedRootStamp else {
            return false
        }
        if snapshot.revisionDigest == expectedRevisionDigest { return true }
        let expectedDescendantRevisionDigest = LocalHash.sha256(Data(
            expectedRevisionRows.filter { $0.key != "." }.map(\.value).sorted()
                .joined(separator: "\n").utf8
        ))
        return snapshot.descendantRevisionDigest == expectedDescendantRevisionDigest
            && snapshot.stableMetadataRows == expectedStableMetadataRows
    }

    public func createDirectory(workspaceID: String, path: String) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let resolved = try resolveDestination(workspaceID: workspaceID, path: path)
        try OperationSafety.validateMutationTarget(resolved.url, protectedPaths: protectedMutationPaths)
        guard resolved.status == nil else { throw LocalMCPError.conflict("path already exists") }
        try requireUndoCapacity(fileBytes: 0)
        let parent = try WorkspaceDirectory(resolved.url.deletingLastPathComponent())
        let target = resolved.url.lastPathComponent
        let staged = ".macbridge-directory-" + UUID().uuidString.lowercased()
        try parent.makeDirectory(staged, mode: 0o755)
        guard let stagedStatus = try parent.status(staged) else { throw LocalMCPError.notFound }
        var published = false
        defer { if !published { try? parent.removeTree(staged, expected: stagedStatus) } }
        let stagedSnapshot = try parent.snapshot(staged, logicalPath: resolved.url.path)
        try parent.requireIdentity(staged, expected: stagedStatus)
        try parent.rename(staged, to: parent, as: target)
        published = true
        guard let publicationRootStatus = try? parent.status(target),
              TreeRootStamp(publicationRootStatus).hasSameIdentity(
                as: TreeRootStamp(stagedSnapshot.root.version)
              ) else {
            throw LocalMCPError.partial(
                "directory was published but its initial identity could not be proven; no automatic recovery receipt was issued"
            )
        }
        var publicationError: Error?
        var publishedSnapshot: WorkspaceDirectory.TreeSnapshot?
        do {
            try afterRelocationBeforeSnapshotForTesting?(
                "create",
                resolved.url.deletingLastPathComponent().appendingPathComponent(staged),
                resolved.url
            )
            publishedSnapshot = try parent.snapshot(target, logicalPath: resolved.url.path)
        } catch {
            publicationError = error
        }
        guard let currentRootStatus = try? parent.status(target),
              TreeRootStamp(currentRootStatus).hasSameIdentity(
                as: TreeRootStamp(stagedSnapshot.root.version)
              ) else {
            throw LocalMCPError.partial(
                "directory was published but its current identity could not be proven; no automatic recovery receipt was issued"
            )
        }
        if let publishedSnapshot,
           publishedTreeMatchesPreparedTree(publishedSnapshot, expected: stagedSnapshot),
           TreeRootStamp(publishedSnapshot.root.version) == TreeRootStamp(publicationRootStatus),
           TreeRootStamp(currentRootStatus) == TreeRootStamp(publicationRootStatus) {
            let transactionID = storeCreatedPathUndo(
                workspaceID: resolved.workspace.id,
                relativePath: resolved.relativePath,
                expected: publishedSnapshot,
                currentRootStatus: currentRootStatus
            )
            return mutationResult(
                operation: "directory_create",
                transactionID: transactionID,
                details: [
                    "relative_path": resolved.relativePath,
                    "tree_sha256": publishedSnapshot.digest,
                ]
            )
        }
        let transactionID = storeCreatedPathUndo(
            workspaceID: resolved.workspace.id,
            relativePath: resolved.relativePath,
            expected: stagedSnapshot,
            currentRootStatus: publicationRootStatus
        )
        let reason = publicationError.map(String.init(describing:))
            ?? "the public directory changed before verification"
        throw LocalMCPError.partial(
            "directory was published but not adopted into undo; conservative recovery transaction retained as \(transactionID). Inspect current contents before accepting or restoring. Cause: \(reason)"
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
        try OperationSafety.validateMutationTarget(destination.url, protectedPaths: protectedMutationPaths)
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
        let preparedSnapshot = try staging.snapshot(
            "payload", logicalPath: destination.url.path
        )
        guard preparedSnapshot.digest == digest else {
            throw LocalMCPError.conflict("source changed during copy; destination was not published")
        }
        try beforeCopyPublicationForTesting?()
        try destinationParent.requireIdentity(stagingName, expected: stagingIdentity)
        try staging.rename("payload", to: destinationParent, as: destination.url.lastPathComponent)
        guard let publicationRootStatus = try? destinationParent.status(
                destination.url.lastPathComponent
              ),
              TreeRootStamp(publicationRootStatus).hasSameIdentity(
                as: TreeRootStamp(preparedSnapshot.root.version)
              ) else {
            throw LocalMCPError.partial(
                "copy was published but its initial identity could not be proven; no automatic recovery receipt was issued"
            )
        }
        var publicationError: Error?
        var destinationSnapshot: WorkspaceDirectory.TreeSnapshot?
        do {
            try afterRelocationBeforeSnapshotForTesting?(
                "copy", source.url, destination.url
            )
            destinationSnapshot = try destinationParent.snapshot(
                destination.url.lastPathComponent, logicalPath: destination.url.path
            )
        } catch {
            publicationError = error
        }
        guard let currentRootStatus = try? destinationParent.status(
                destination.url.lastPathComponent
              ),
              TreeRootStamp(currentRootStatus).hasSameIdentity(
                as: TreeRootStamp(preparedSnapshot.root.version)
              ) else {
            throw LocalMCPError.partial(
                "copy was published but its current identity could not be proven; no automatic recovery receipt was issued"
            )
        }
        if let destinationSnapshot,
           publishedTreeMatchesPreparedTree(destinationSnapshot, expected: preparedSnapshot),
           TreeRootStamp(destinationSnapshot.root.version) == TreeRootStamp(publicationRootStatus),
           TreeRootStamp(currentRootStatus) == TreeRootStamp(publicationRootStatus) {
            let transactionID = storeCreatedPathUndo(
                workspaceID: destination.workspace.id,
                relativePath: destination.relativePath,
                expected: destinationSnapshot,
                currentRootStatus: currentRootStatus
            )
            return mutationResult(
                operation: "path_copy", transactionID: transactionID,
                details: [
                    "source_path": source.relativePath,
                    "destination_path": destination.relativePath,
                    "tree_sha256": digest,
                ]
            )
        }
        let transactionID = storeCreatedPathUndo(
            workspaceID: destination.workspace.id,
            relativePath: destination.relativePath,
            expected: preparedSnapshot,
            currentRootStatus: publicationRootStatus
        )
        let reason = publicationError.map(String.init(describing:))
            ?? "the public copy changed before verification"
        throw LocalMCPError.partial(
            "copy was published but not adopted into undo; conservative recovery transaction retained as \(transactionID). Inspect current contents before accepting or restoring. Cause: \(reason)"
        )
    }

    public func movePath(
        workspaceID: String,
        sourcePath: String,
        destinationPath: String
    ) throws -> JSONObject {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let source = try resolveExisting(workspaceID: workspaceID, path: sourcePath)
        try OperationSafety.validateMutationTarget(source.url, protectedPaths: protectedMutationPaths)
        try OperationSafety.validateRelocation(source: source.url, workspace: source.workspace,
                                               additionalProtectedPaths: relocationProtectedPathsForTesting)
        let destination = try resolveDestination(workspaceID: workspaceID, path: destinationPath)
        try OperationSafety.validateMutationTarget(destination.url, protectedPaths: protectedMutationPaths)
        guard !destination.relativePath.hasPrefix(source.relativePath + "/") else {
            throw LocalMCPError.conflict("destination cannot be inside the source")
        }
        guard destination.status == nil else {
            throw LocalMCPError.conflict("destination already exists")
        }
        try requireUndoCapacity(fileBytes: 0)
        let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
        let destinationParent = try WorkspaceDirectory(destination.url.deletingLastPathComponent())
        let sourceSnapshot = try sourceParent.snapshot(
            source.url.lastPathComponent, logicalPath: source.url.path
        )
        let digest = sourceSnapshot.digest
        try sourceParent.rename(source.url.lastPathComponent, to: destinationParent, as: destination.url.lastPathComponent)
        let destinationSnapshot: WorkspaceDirectory.TreeSnapshot
        do {
            try afterRelocationBeforeSnapshotForTesting?("move", source.url, destination.url)
            destinationSnapshot = try destinationParent.snapshot(
                destination.url.lastPathComponent, logicalPath: destination.url.path
            )
        } catch let snapshotError {
            var reversedAndVerified = false
            var reversalRenameSucceeded = false
            do {
                try destinationParent.rename(
                    destination.url.lastPathComponent, to: sourceParent,
                    as: source.url.lastPathComponent
                )
                reversalRenameSucceeded = true
                if let restored = try sourceParent.status(source.url.lastPathComponent),
                   TreeRootStamp(restored).hasSameStableRoot(
                        as: TreeRootStamp(sourceSnapshot.root.version)
                   ),
                   try destinationParent.status(destination.url.lastPathComponent) == nil {
                    reversedAndVerified = true
                }
            } catch {
                // Fall through to an identity-bound recovery receipt below.
            }
            if reversedAndVerified {
                throw LocalMCPError.conflict(
                    "move snapshot failed after publication; move was reversed: \(snapshotError)"
                )
            }
            if reversalRenameSucceeded {
                throw LocalMCPError.partial(
                    "move snapshot failed after publication; the object was renamed back to its public source, but concurrent metadata changes prevented exact reversal verification; no receipt was issued for the now-empty destination"
                )
            }
            guard let recoveryStatus = try? destinationParent.status(
                    destination.url.lastPathComponent
                  ),
                  TreeRootStamp(recoveryStatus).hasSameIdentity(
                    as: TreeRootStamp(sourceSnapshot.root.version)
                  ) else {
                throw LocalMCPError.partial(
                    "move snapshot and automatic reversal failed; the destination could not be identity-proven, so no automatic recovery receipt was issued"
                )
            }
            let recoveryTransactionID = storeTransaction(
                .restoreRelocatedPath(
                    workspaceID: source.workspace.id,
                    originalRelativePath: source.relativePath,
                    recoveryRelativePath: destination.relativePath,
                    expectedRootStamp: TreeRootStamp(recoveryStatus)
                )
            )
            throw LocalMCPError.partial(
                "move snapshot failed after publication and automatic reversal failed; "
                + "identity-bound recovery transaction retained as \(recoveryTransactionID): \(snapshotError)"
            )
        }
        guard destinationSnapshot.digest == sourceSnapshot.digest,
              destinationSnapshot.descendantRevisionDigest == sourceSnapshot.descendantRevisionDigest,
              destinationSnapshot.root.metadataDigest == sourceSnapshot.root.metadataDigest,
              TreeRootStamp(destinationSnapshot.root.version)
                .hasSameStableRoot(as: TreeRootStamp(sourceSnapshot.root.version)) else {
            do {
                try destinationParent.rename(
                    destination.url.lastPathComponent, to: sourceParent,
                    as: source.url.lastPathComponent
                )
            } catch {
                let recoveryTransactionID = storeTransaction(
                    .moveBack(
                        workspaceID: source.workspace.id,
                        sourceRelativePath: source.relativePath,
                        destinationRelativePath: destination.relativePath,
                        expectedDestinationTreeSHA256: destinationSnapshot.digest,
                        expectedDestinationTreeRevisionSHA256: destinationSnapshot.revisionDigest,
                        expectedRootStamp: TreeRootStamp(destinationSnapshot.root.version)
                    )
                )
                throw LocalMCPError.partial(
                    "move source changed during publication and automatic reversal failed; "
                    + "recovery transaction retained as \(recoveryTransactionID): \(error)"
                )
            }
            throw LocalMCPError.conflict("move source changed during publication; move was reversed")
        }
        let destinationStatus = destinationSnapshot.root.version
        let transactionID = storeTransaction(
            .moveBack(
                workspaceID: source.workspace.id,
                sourceRelativePath: source.relativePath,
                destinationRelativePath: destination.relativePath,
                expectedDestinationTreeSHA256: digest,
                expectedDestinationTreeRevisionSHA256: destinationSnapshot.revisionDigest,
                expectedRootStamp: TreeRootStamp(destinationStatus)
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
        try OperationSafety.validateMutationTarget(source.url, protectedPaths: protectedMutationPaths)
        try OperationSafety.validateRecoverableRemoval(
            target: source.url,
            workspace: source.workspace
        )
        guard !source.relativePath.split(separator: "/").contains(".macbridge")
        else { throw LocalMCPError.invalidPath(".macbridge is reserved runtime state") }
        try requireUndoCapacity(fileBytes: 0)
        let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
        let sourceSnapshot = try sourceParent.snapshot(
            source.url.lastPathComponent, logicalPath: source.url.path
        )
        let digest = sourceSnapshot.digest
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
        let recoverySnapshot: WorkspaceDirectory.TreeSnapshot
        do {
            try afterRelocationBeforeSnapshotForTesting?("remove", source.url, recovery)
            recoverySnapshot = try recoveryHandle.snapshot(
                transactionID, logicalPath: recovery.path
            )
        } catch let snapshotError {
            var reversedAndVerified = false
            var reversalRenameSucceeded = false
            do {
                try recoveryHandle.rename(
                    transactionID, to: sourceParent, as: source.url.lastPathComponent
                )
                reversalRenameSucceeded = true
                if let restored = try sourceParent.status(source.url.lastPathComponent),
                   TreeRootStamp(restored).hasSameStableRoot(
                        as: TreeRootStamp(sourceSnapshot.root.version)
                   ),
                   try recoveryHandle.status(transactionID) == nil {
                    reversedAndVerified = true
                }
            } catch {
                // Fall through to an identity-bound recovery receipt below.
            }
            if reversedAndVerified {
                throw LocalMCPError.conflict(
                    "removal snapshot failed after publication; removal was reversed: \(snapshotError)"
                )
            }
            if reversalRenameSucceeded {
                throw LocalMCPError.partial(
                    "removal snapshot failed after publication; the object was renamed back to its public path, but concurrent metadata changes prevented exact reversal verification; no receipt was issued for the now-empty recovery path"
                )
            }
            guard let recoveryStatus = try? recoveryHandle.status(transactionID),
                  TreeRootStamp(recoveryStatus).hasSameIdentity(
                    as: TreeRootStamp(sourceSnapshot.root.version)
                  ) else {
                throw LocalMCPError.partial(
                    "removal snapshot and automatic reversal failed; the recovery entry could not be identity-proven, so no automatic recovery receipt was issued"
                )
            }
            storeTransaction(
                id: transactionID,
                action: .restoreRelocatedPath(
                    workspaceID: source.workspace.id,
                    originalRelativePath: source.relativePath,
                    recoveryRelativePath: recoveryRelativePath,
                    expectedRootStamp: TreeRootStamp(recoveryStatus)
                )
            )
            throw LocalMCPError.partial(
                "removal snapshot failed after publication and automatic reversal failed; "
                + "identity-bound recovery transaction retained as \(transactionID) at \(recoveryRelativePath): \(snapshotError)"
            )
        }
        guard recoverySnapshot.digest == sourceSnapshot.digest,
              recoverySnapshot.descendantRevisionDigest == sourceSnapshot.descendantRevisionDigest,
              recoverySnapshot.root.metadataDigest == sourceSnapshot.root.metadataDigest,
              TreeRootStamp(recoverySnapshot.root.version)
                .hasSameStableRoot(as: TreeRootStamp(sourceSnapshot.root.version)) else {
            do {
                try recoveryHandle.rename(
                    transactionID, to: sourceParent, as: source.url.lastPathComponent
                )
            } catch {
                storeTransaction(
                    id: transactionID,
                    action: .restoreRemovedPath(
                        workspaceID: source.workspace.id,
                        originalRelativePath: source.relativePath,
                        recoveryRelativePath: recoveryRelativePath,
                        expectedRecoveryTreeSHA256: recoverySnapshot.digest,
                        expectedRecoveryTreeRevisionSHA256: recoverySnapshot.revisionDigest,
                        expectedRootStamp: TreeRootStamp(recoverySnapshot.root.version)
                    )
                )
                throw LocalMCPError.partial(
                    "removal source changed during publication and automatic reversal failed; "
                    + "recovery transaction retained as \(transactionID) at \(recoveryRelativePath): \(error)"
                )
            }
            throw LocalMCPError.conflict("removal source changed during publication; removal was reversed")
        }
        let recoveryStatus = recoverySnapshot.root.version
        storeTransaction(
            id: transactionID,
            action: .restoreRemovedPath(
                workspaceID: source.workspace.id,
                originalRelativePath: source.relativePath,
                recoveryRelativePath: recoveryRelativePath,
                expectedRecoveryTreeSHA256: digest,
                expectedRecoveryTreeRevisionSHA256: recoverySnapshot.revisionDigest,
                expectedRootStamp: TreeRootStamp(recoveryStatus)
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

        if case .composite(let actions) = transaction.action {
            var failures: [(action: UndoAction, error: Error)] = []
            var restoredCount = 0
            for action in actions.reversed() {
                do {
                    try validateUndoRestorable(action)
                    try restoreUndo(action)
                    restoredCount += 1
                } catch {
                    failures.append((action, error))
                }
            }
            if !failures.isEmpty {
                var updated = transaction
                updated.action = .composite(failures.map(\.action).reversed())
                transactions[id] = updated
                retainedUndoFileBytes -= transaction.retainedFileBytes - updated.retainedFileBytes
                throw LocalMCPError.partial(
                    "composite restore recovered \(restoredCount) safe member(s); \(failures.count) conflicted member(s) remain under the same transaction_id. First failure: \(failures[0].error)"
                )
            }
        } else {
            try validateUndoRestorable(transaction.action)
            try restoreUndo(transaction.action)
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

    private func restoreUndo(_ action: UndoAction) throws {
        switch action {
        case .restoreFile(
            let workspaceID, let relativePath, let previousData, let previousMode,
            let expectedCurrentStamp
        ):
            let current = try resolveExisting(workspaceID: workspaceID, path: relativePath)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let name = current.url.lastPathComponent
            let revision = try fileRevision(parent: parent, name: name)
            guard revision.status.st_mode & S_IFMT == S_IFREG,
                revision.status.st_nlink == 1,
                revision.stamp == expectedCurrentStamp
            else { throw LocalMCPError.conflict("file changed after the transaction") }
            if let previousData {
                let published = try parent.atomicWrite(
                    previousData, name: name, mode: previousMode, replacing: true
                ) { [self] in
                    try verifyPreimage(parent: parent, name: name, expected: revision.stamp)
                }
                let restoredStamp = FileRevisionStamp(
                    published, sha256: LocalHash.sha256(previousData)
                )
                retargetRetainedFileUndo(
                    workspaceID: workspaceID, relativePath: relativePath,
                    restoredStamp: restoredStamp
                )
            } else {
                try verifyPreimage(parent: parent, name: name, expected: revision.stamp)
                try parent.unlink(name)
            }
            retargetMatchingCreatedAncestorUndo(
                workspaceID: workspaceID, changedRelativePath: relativePath
            )
        case .removeCreatedPath(let workspaceID, let relativePath, let expectedDigest,
                                let expectedRevision, let expectedRevisionRows,
                                let expectedStableMetadataRows, let expectedMetadata,
                                let expectedRootStamp):
            let current = try resolveExisting(workspaceID: workspaceID, path: relativePath)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let snapshot = try parent.snapshot(current.url.lastPathComponent, logicalPath: current.url.path)
            guard createdPathSnapshotMatchesUndo(
                snapshot,
                expectedDigest: expectedDigest,
                expectedRevisionDigest: expectedRevision,
                expectedRevisionRows: expectedRevisionRows,
                expectedStableMetadataRows: expectedStableMetadataRows,
                expectedRootMetadataDigest: expectedMetadata,
                expectedRootStamp: expectedRootStamp
            ) else {
                throw LocalMCPError.conflict("created path changed after the transaction")
            }
            do {
                try parent.quarantineAndRemoveVerifiedTree(
                    snapshot,
                    afterRenameForTesting: afterQuarantineRenameForTesting,
                    beforeEntryRemovalForTesting: beforeQuarantineEntryRemovalForTesting
                )
            } catch let rollback as QuarantineRemovalRolledBack {
                throw LocalMCPError.partial(
                    "tree cleanup changed during undo; the residual tree was restored to its public path, but the original receipt was deliberately not widened to include concurrent additions: \(rollback.cause)"
                )
            } catch let relocated as QuarantineRemovalRelocated {
                let parentComponents = relativePath.split(separator: "/").dropLast()
                let recoveryRelativePath = (parentComponents.map(String.init)
                    + [relocated.recoveryName]).joined(separator: "/")
                let converted = retargetRelocatedCreatedPathUndo(
                    workspaceID: workspaceID, relativePath: relativePath,
                    recoveryRelativePath: recoveryRelativePath,
                    originalStamp: expectedRootStamp,
                    recoveryStamp: TreeRootStamp(relocated.rootVersion)
                )
                guard converted else {
                    throw LocalMCPError.partial(
                        "tree cleanup and public rollback both failed; the residual tree was preserved at \(recoveryRelativePath), but the original receipt could not be converted automatically"
                    )
                }
                throw LocalMCPError.partial(
                    "tree cleanup and public rollback both failed; the residual tree was preserved at \(recoveryRelativePath) under an identity-bound recovery receipt"
                )
            }
            retargetMatchingCreatedAncestorUndo(
                workspaceID: workspaceID, changedRelativePath: relativePath
            )
        case .moveBack(
            let workspaceID, let sourceRelativePath, let destinationRelativePath,
            let expectedDigest, let expectedRevision, let expectedRootStamp
        ):
            let source = try resolveDestination(workspaceID: workspaceID, path: sourceRelativePath)
            try OperationSafety.validateMutationTarget(
                source.url, protectedPaths: protectedMutationPaths
            )
            guard source.status == nil else {
                throw LocalMCPError.conflict("original move source is no longer empty")
            }
            let destination = try resolveExisting(
                workspaceID: workspaceID, path: destinationRelativePath
            )
            try OperationSafety.validateMutationTarget(
                destination.url, protectedPaths: protectedMutationPaths
            )
            let sourceParent = try WorkspaceDirectory(source.url.deletingLastPathComponent())
            let destinationParent = try WorkspaceDirectory(destination.url.deletingLastPathComponent())
            let destinationSnapshot = try destinationParent.snapshot(
                destination.url.lastPathComponent, logicalPath: destination.url.path
            )
            guard TreeRootStamp(destinationSnapshot.root.version) == expectedRootStamp,
                  destinationSnapshot.digest == expectedDigest,
                  destinationSnapshot.revisionDigest == expectedRevision else {
                throw LocalMCPError.conflict("moved path changed after the transaction")
            }
            try destinationParent.rename(destination.url.lastPathComponent, to: sourceParent, as: source.url.lastPathComponent)
            let restored = try sourceParent.snapshot(
                source.url.lastPathComponent, logicalPath: source.url.path
            )
            retargetRetainedTreeUndo(
                workspaceID: workspaceID, relativePath: sourceRelativePath,
                digest: expectedDigest, revisionDigest: restored.revisionDigest,
                revisionRows: restored.revisionRows,
                stableMetadataRows: restored.stableMetadataRows,
                rootMetadataDigest: restored.root.metadataDigest,
                restoredStamp: TreeRootStamp(restored.root.version)
            )
            if restored.root.version.st_mode & S_IFMT == S_IFREG,
               restored.root.version.st_size >= 0,
               restored.root.version.st_size <= Self.maximumFileBytes,
               hasRetainedFileUndo(
                    workspaceID: workspaceID, relativePath: sourceRelativePath
               ) {
                let revision = try fileRevision(
                    parent: sourceParent, name: source.url.lastPathComponent
                )
                retargetRetainedFileUndo(
                    workspaceID: workspaceID, relativePath: sourceRelativePath,
                    restoredStamp: revision.stamp
                )
            }
            retargetMatchingCreatedAncestorUndo(
                workspaceID: workspaceID, changedRelativePath: destinationRelativePath
            )
            retargetMatchingCreatedAncestorUndo(
                workspaceID: workspaceID, changedRelativePath: sourceRelativePath
            )
        case .restoreRemovedPath(
            let workspaceID, let originalRelativePath, let recoveryRelativePath,
            let expectedDigest, let expectedRevision, let expectedRootStamp
        ):
            let original = try resolveDestination(
                workspaceID: workspaceID, path: originalRelativePath
            )
            try OperationSafety.validateMutationTarget(
                original.url, protectedPaths: protectedMutationPaths
            )
            guard original.status == nil else {
                throw LocalMCPError.conflict("removed path destination is no longer empty")
            }
            let recovery = try resolveExisting(
                workspaceID: workspaceID, path: recoveryRelativePath
            )
            try OperationSafety.validateMutationTarget(
                recovery.url, protectedPaths: protectedMutationPaths
            )
            let originalParent = try WorkspaceDirectory(original.url.deletingLastPathComponent())
            let recoveryParent = try WorkspaceDirectory(recovery.url.deletingLastPathComponent())
            let recoverySnapshot = try recoveryParent.snapshot(
                recovery.url.lastPathComponent, logicalPath: recovery.url.path
            )
            guard TreeRootStamp(recoverySnapshot.root.version) == expectedRootStamp,
                  recoverySnapshot.digest == expectedDigest,
                  recoverySnapshot.revisionDigest == expectedRevision else {
                throw LocalMCPError.conflict("recovery path changed after removal")
            }
            try recoveryParent.rename(recovery.url.lastPathComponent, to: originalParent, as: original.url.lastPathComponent)
            let restored = try originalParent.snapshot(
                original.url.lastPathComponent, logicalPath: original.url.path
            )
            retargetRetainedTreeUndo(
                workspaceID: workspaceID, relativePath: originalRelativePath,
                digest: expectedDigest, revisionDigest: restored.revisionDigest,
                revisionRows: restored.revisionRows,
                stableMetadataRows: restored.stableMetadataRows,
                rootMetadataDigest: restored.root.metadataDigest,
                restoredStamp: TreeRootStamp(restored.root.version)
            )
            if restored.root.version.st_mode & S_IFMT == S_IFREG,
               restored.root.version.st_size >= 0,
               restored.root.version.st_size <= Self.maximumFileBytes,
               hasRetainedFileUndo(
                    workspaceID: workspaceID, relativePath: originalRelativePath
               ) {
                let revision = try fileRevision(
                    parent: originalParent, name: original.url.lastPathComponent
                )
                retargetRetainedFileUndo(
                    workspaceID: workspaceID, relativePath: originalRelativePath,
                    restoredStamp: revision.stamp
                )
            }
            retargetMatchingCreatedAncestorUndo(
                workspaceID: workspaceID, changedRelativePath: originalRelativePath
            )
            let recoveryRoot = recovery.url.deletingLastPathComponent()
            let state = recoveryRoot.deletingLastPathComponent()
            try? WorkspaceDirectory(state).unlink(recoveryRoot.lastPathComponent, directory: true)
            try? WorkspaceDirectory(state.deletingLastPathComponent()).unlink(state.lastPathComponent, directory: true)
        case .restoreRelocatedPath(
            let workspaceID, let originalRelativePath, let recoveryRelativePath,
            let expectedRootStamp
        ):
            let original = try resolveDestination(
                workspaceID: workspaceID, path: originalRelativePath
            )
            try OperationSafety.validateMutationTarget(
                original.url, protectedPaths: protectedMutationPaths
            )
            guard original.status == nil else {
                throw LocalMCPError.conflict("recovery destination is no longer empty")
            }
            let recovery = try resolveExisting(
                workspaceID: workspaceID, path: recoveryRelativePath
            )
            try OperationSafety.validateMutationTarget(
                recovery.url, protectedPaths: protectedMutationPaths
            )
            let currentStamp = TreeRootStamp(try lstatValue(recovery.url.path))
            guard currentStamp.hasSameStableRoot(as: expectedRootStamp) else {
                throw LocalMCPError.conflict("relocated recovery root identity changed")
            }
            let originalParent = try WorkspaceDirectory(original.url.deletingLastPathComponent())
            let recoveryParent = try WorkspaceDirectory(recovery.url.deletingLastPathComponent())
            try recoveryParent.rename(
                recovery.url.lastPathComponent, to: originalParent,
                as: original.url.lastPathComponent
            )
            // Recovery-only receipts deliberately preserve arbitrary current
            // contents and metadata. They therefore cannot prove that an older
            // destructive undo is safe to retarget.
        case .composite(let actions):
            for action in actions.reversed() { try restoreUndo(action) }
        }
    }

    /// An earlier bridge transaction may become current again after a later
    /// bridge-owned undo publishes its exact bytes on a new inode. Retarget
    /// only that known internal transition; an external same-byte replacement
    /// never passes through this path and remains a conflict.
    private func retargetRetainedFileUndo(
        workspaceID: String, relativePath: String, restoredStamp: FileRevisionStamp
    ) {
        func retarget(_ action: UndoAction) -> UndoAction {
            switch action {
            case .restoreFile(let workspace, let path, let data, let mode, let expected)
                where workspace.lowercased() == workspaceID.lowercased()
                    && expected.sha256 == restoredStamp.sha256:
                guard sameResolvedEntry(
                    workspaceID: workspace, first: path, second: relativePath
                ) else { return action }
                return .restoreFile(
                    workspaceID: workspace, relativePath: path, previousData: data,
                    previousMode: mode, expectedCurrentStamp: restoredStamp
                )
            case .composite(let actions):
                return .composite(actions.map(retarget))
            default: return action
            }
        }
        for (id, stored) in transactions {
            var updated = stored
            updated.action = retarget(stored.action)
            transactions[id] = updated
        }
    }

    private func retargetRetainedTreeUndo(
        workspaceID: String, relativePath: String, digest: String, revisionDigest: String,
        revisionRows: [String: String],
        stableMetadataRows: [String: String],
        rootMetadataDigest: String,
        restoredStamp: TreeRootStamp
    ) {
        func retarget(_ action: UndoAction) -> UndoAction {
            switch action {
            case .removeCreatedPath(let workspace, let path, let expected, _, _, _, _, _)
                where workspace.lowercased() == workspaceID.lowercased() && expected == digest:
                guard sameResolvedEntry(
                    workspaceID: workspace, first: path, second: relativePath
                ) else { return action }
                return .removeCreatedPath(
                    workspaceID: workspace, relativePath: path,
                    expectedTreeSHA256: expected,
                    expectedTreeRevisionSHA256: revisionDigest,
                    expectedTreeRevisionRows: revisionRows,
                    expectedStableMetadataRows: stableMetadataRows,
                    expectedRootMetadataSHA256: rootMetadataDigest,
                    expectedRootStamp: restoredStamp
                )
            case .moveBack(let workspace, let source, let destination, let expected, _, _)
                where workspace.lowercased() == workspaceID.lowercased() && expected == digest:
                guard sameResolvedEntry(
                    workspaceID: workspace, first: destination, second: relativePath
                ) else { return action }
                return .moveBack(
                    workspaceID: workspace, sourceRelativePath: source,
                    destinationRelativePath: destination,
                    expectedDestinationTreeSHA256: expected,
                    expectedDestinationTreeRevisionSHA256: revisionDigest,
                    expectedRootStamp: restoredStamp
                )
            case .restoreRemovedPath(let workspace, let original, let recovery, let expected, _, _)
                where workspace.lowercased() == workspaceID.lowercased() && expected == digest:
                guard sameResolvedEntry(
                    workspaceID: workspace, first: recovery, second: relativePath
                ) else { return action }
                return .restoreRemovedPath(
                    workspaceID: workspace, originalRelativePath: original,
                    recoveryRelativePath: recovery,
                    expectedRecoveryTreeSHA256: expected,
                    expectedRecoveryTreeRevisionSHA256: revisionDigest,
                    expectedRootStamp: restoredStamp
                )
            case .composite(let actions): return .composite(actions.map(retarget))
            default: return action
            }
        }
        for (id, stored) in transactions {
            var updated = stored
            updated.action = retarget(stored.action)
            transactions[id] = updated
        }
    }

    /// When bridge-owned file undos return a created ancestor to the exact tree
    /// digest recorded by its older undo, refresh only the volatile directory
    /// revision fields. Stable root identity and metadata must still match, so
    /// an unrelated replacement, chmod, chown or flags change remains a conflict.
    private func retargetMatchingCreatedAncestorUndo(
        workspaceID: String, changedRelativePath: String
    ) {
        func retarget(_ action: UndoAction) -> UndoAction {
            switch action {
            case .removeCreatedPath(
                let workspace, let path, let expected, _, let expectedRows, let expectedStableRows,
                let expectedMetadata, let oldStamp
            )
                where workspace.lowercased() == workspaceID.lowercased():
                guard isResolvedAncestor(
                    workspaceID: workspace, ancestor: path,
                    descendant: changedRelativePath
                ) else { return action }
                guard let current = try? resolveExisting(workspaceID: workspace, path: path),
                      let parent = try? WorkspaceDirectory(current.url.deletingLastPathComponent()),
                      let snapshot = try? parent.snapshot(
                        current.url.lastPathComponent, logicalPath: current.url.path
                      ),
                      snapshot.digest == expected,
                      unaffectedTreeRowsMatch(
                        expected: expectedRows, current: snapshot.revisionRows,
                        expectedStable: expectedStableRows,
                        currentStable: snapshot.stableMetadataRows,
                        ancestorPath: path, changedPath: changedRelativePath,
                        ancestorURL: current.url
                      ),
                      snapshot.root.metadataDigest == expectedMetadata else { return action }
                let newStamp = TreeRootStamp(snapshot.root.version)
                guard newStamp.hasSameStableRoot(as: oldStamp) else { return action }
                return .removeCreatedPath(
                    workspaceID: workspace, relativePath: path,
                    expectedTreeSHA256: expected,
                    expectedTreeRevisionSHA256: snapshot.revisionDigest,
                    expectedTreeRevisionRows: snapshot.revisionRows,
                    expectedStableMetadataRows: snapshot.stableMetadataRows,
                    expectedRootMetadataSHA256: expectedMetadata,
                    expectedRootStamp: newStamp
                )
            case .composite(let actions): return .composite(actions.map(retarget))
            default: return action
            }
        }
        for (id, stored) in transactions {
            var updated = stored
            updated.action = retarget(stored.action)
            transactions[id] = updated
        }
    }

    @discardableResult
    private func retargetRelocatedCreatedPathUndo(
        workspaceID: String, relativePath: String, recoveryRelativePath: String,
        originalStamp: TreeRootStamp, recoveryStamp: TreeRootStamp
    ) -> Bool {
        var converted = false
        func retarget(_ action: UndoAction) -> UndoAction {
            switch action {
            case .removeCreatedPath(let workspace, let path, _, _, _, _, _, let stamp)
                where workspace.lowercased() == workspaceID.lowercased():
                guard path == relativePath, stamp == originalStamp,
                recoveryStamp.hasSameIdentity(as: originalStamp) else { return action }
                converted = true
                return .restoreRelocatedPath(
                    workspaceID: workspace,
                    originalRelativePath: path,
                    recoveryRelativePath: recoveryRelativePath,
                    expectedRootStamp: recoveryStamp
                )
            case .composite(let actions): return .composite(actions.map(retarget))
            default: return action
            }
        }
        for (id, stored) in transactions {
            var updated = stored
            updated.action = retarget(stored.action)
            transactions[id] = updated
        }
        return converted
    }

    private func hasRetainedFileUndo(
        workspaceID: String, relativePath: String
    ) -> Bool {
        func matches(_ action: UndoAction) -> Bool {
            switch action {
            case .restoreFile(let workspace, let path, _, _, _):
                return workspace.lowercased() == workspaceID.lowercased()
                    && sameResolvedEntry(
                        workspaceID: workspace, first: path, second: relativePath
                    )
            case .composite(let actions): return actions.contains(where: matches)
            default: return false
            }
        }
        return transactions.values.contains { matches($0.action) }
    }

    private func sameResolvedEntry(
        workspaceID: String, first: String, second: String
    ) -> Bool {
        guard let lhs = try? resolveExisting(workspaceID: workspaceID, path: first),
              let rhs = try? resolveExisting(workspaceID: workspaceID, path: second),
              let a = lhs.status, let b = rhs.status else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private func isResolvedAncestor(
        workspaceID: String, ancestor: String, descendant: String
    ) -> Bool {
        guard let root = try? resolveExisting(workspaceID: workspaceID, path: ancestor),
              let rootStatus = root.status,
              let changed = try? resolveDestination(workspaceID: workspaceID, path: descendant)
        else { return false }
        var candidate = changed.url.deletingLastPathComponent()
        let boundary = changed.workspace.rootURL.standardizedFileURL.path
        while candidate.standardizedFileURL.path.hasPrefix(boundary) {
            var value = stat()
            if lstat(candidate.path, &value) == 0,
               value.st_dev == rootStatus.st_dev, value.st_ino == rootStatus.st_ino {
                return true
            }
            if candidate.standardizedFileURL.path == boundary { break }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return false
    }

    private func unaffectedTreeRowsMatch(
        expected: [String: String], current: [String: String],
        expectedStable: [String: String], currentStable: [String: String],
        ancestorPath: String, changedPath: String, ancestorURL: URL
    ) -> Bool {
        let ancestorParts = ancestorPath.split(separator: "/")
        let changedParts = changedPath.split(separator: "/")
        guard changedParts.count > ancestorParts.count else { return false }
        let relativeChanged = changedParts.dropFirst(ancestorParts.count)
            .map(String.init).joined(separator: "/")
        let caseSensitive = (try? ancestorURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? true
        func key(_ value: String) -> String {
            let normalized = value.precomposedStringWithCanonicalMapping
            return caseSensitive ? normalized : LocalFilesystemAccess.policyFold(normalized)
        }
        let changedKey = key(relativeChanged)
        func causallyChanged(_ rowPath: String) -> Bool {
            let rowKey = key(rowPath)
            return rowKey == "." || rowKey == changedKey
                || rowKey.hasPrefix(changedKey + "/")
                || changedKey.hasPrefix(rowKey + "/")
        }
        let expectedUnchanged = expected.filter { !causallyChanged($0.key) }
        let currentUnchanged = current.filter { !causallyChanged($0.key) }
        guard expectedUnchanged.count == currentUnchanged.count else { return false }
        for (path, value) in expectedUnchanged {
            guard let pair = currentUnchanged.first(where: { key($0.key) == key(path) }),
                  pair.value == value else { return false }
        }
        // Directories on the causal path legitimately change size/link/time,
        // but their identity, ownership, flags, xattrs and ACLs must not.
        func insideChangedSubtree(_ rowPath: String) -> Bool {
            let rowKey = key(rowPath)
            return rowKey == changedKey || rowKey.hasPrefix(changedKey + "/")
        }
        let expectedMetadata = expectedStable.filter { !insideChangedSubtree($0.key) }
        let currentMetadata = currentStable.filter { !insideChangedSubtree($0.key) }
        guard expectedMetadata.count == currentMetadata.count else { return false }
        for (path, value) in expectedMetadata {
            guard let pair = currentMetadata.first(where: { key($0.key) == key(path) }),
                  pair.value == value else { return false }
        }
        return true
    }

    private func validateUndoRestorable(_ action: UndoAction) throws {
        switch action {
        case .restoreFile(let workspaceID, let relativePath, _, _, let expected):
            let current = try resolveExisting(workspaceID: workspaceID, path: relativePath)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let revision = try fileRevision(parent: parent, name: current.url.lastPathComponent)
            guard revision.status.st_mode & S_IFMT == S_IFREG,
                  revision.status.st_nlink == 1, revision.stamp == expected else {
                throw LocalMCPError.conflict("file changed after the transaction")
            }
        case .removeCreatedPath(let workspaceID, let relativePath, let expected,
                                let expectedRevision, let expectedRevisionRows,
                                let expectedStableMetadataRows, let expectedMetadata, let stamp):
            let current = try resolveExisting(workspaceID: workspaceID, path: relativePath)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let snapshot = try parent.snapshot(current.url.lastPathComponent, logicalPath: current.url.path)
            guard createdPathSnapshotMatchesUndo(
                snapshot,
                expectedDigest: expected,
                expectedRevisionDigest: expectedRevision,
                expectedRevisionRows: expectedRevisionRows,
                expectedStableMetadataRows: expectedStableMetadataRows,
                expectedRootMetadataDigest: expectedMetadata,
                expectedRootStamp: stamp
            ) else {
                throw LocalMCPError.conflict("created path changed after the transaction")
            }
        case .moveBack(let workspaceID, let source, let destination, let expected,
                       let expectedRevision, let stamp):
            let sourcePath = try resolveDestination(workspaceID: workspaceID, path: source)
            try OperationSafety.validateMutationTarget(
                sourcePath.url, protectedPaths: protectedMutationPaths
            )
            guard sourcePath.status == nil else {
                throw LocalMCPError.conflict("original move source is no longer empty")
            }
            let current = try resolveExisting(workspaceID: workspaceID, path: destination)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let snapshot = try parent.snapshot(current.url.lastPathComponent, logicalPath: current.url.path)
            guard TreeRootStamp(snapshot.root.version) == stamp,
                  snapshot.digest == expected, snapshot.revisionDigest == expectedRevision else {
                throw LocalMCPError.conflict("moved path changed after the transaction")
            }
        case .restoreRemovedPath(let workspaceID, let original, let recovery, let expected,
                                 let expectedRevision, let stamp):
            let originalPath = try resolveDestination(workspaceID: workspaceID, path: original)
            try OperationSafety.validateMutationTarget(
                originalPath.url, protectedPaths: protectedMutationPaths
            )
            guard originalPath.status == nil else {
                throw LocalMCPError.conflict("removed path destination is no longer empty")
            }
            let current = try resolveExisting(workspaceID: workspaceID, path: recovery)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            let parent = try WorkspaceDirectory(current.url.deletingLastPathComponent())
            let snapshot = try parent.snapshot(current.url.lastPathComponent, logicalPath: current.url.path)
            guard TreeRootStamp(snapshot.root.version) == stamp,
                  snapshot.digest == expected, snapshot.revisionDigest == expectedRevision else {
                throw LocalMCPError.conflict("recovery path changed after removal")
            }
        case .restoreRelocatedPath(
            let workspaceID, let original, let recovery, let stamp
        ):
            let originalPath = try resolveDestination(
                workspaceID: workspaceID, path: original
            )
            try OperationSafety.validateMutationTarget(
                originalPath.url, protectedPaths: protectedMutationPaths
            )
            guard originalPath.status == nil else {
                throw LocalMCPError.conflict("recovery destination is no longer empty")
            }
            let current = try resolveExisting(workspaceID: workspaceID, path: recovery)
            try OperationSafety.validateMutationTarget(
                current.url, protectedPaths: protectedMutationPaths
            )
            guard TreeRootStamp(try lstatValue(current.url.path))
                .hasSameStableRoot(as: stamp) else {
                throw LocalMCPError.conflict("relocated recovery root identity changed")
            }
        case .composite(let actions):
            for item in actions { try validateUndoRestorable(item) }
        }
    }

    public func workspaceURL(workspaceID: String, relativePath: String) throws -> URL {
        try resolveExisting(
            workspaceID: workspaceID, path: relativePath, allowRoot: true
        ).url
    }

    func diagnosticAvailability() -> (registered: Int, available: Int) {
        let workspaces = registry.workspaces
        let available = workspaces.reduce(into: 0) { count, workspace in
            var status = stat()
            if lstat(workspace.rootURL.path, &status) == 0,
               status.st_mode & S_IFMT == S_IFDIR,
               (try? WorkspaceDirectory(workspace.rootURL)) != nil {
                count += 1
            }
        }
        return (workspaces.count, available)
    }

    private func fileRevision(
        parent: WorkspaceDirectory,
        name: String
    ) throws -> (data: Data, status: stat, stamp: FileRevisionStamp) {
        let fd = try parent.openFile(name)
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= Self.maximumFileBytes else {
            throw LocalMCPError.wrongFileType
        }
        let data = try LocalFileReader.read(
            descriptor: fd, maximumBytes: Self.maximumFileBytes
        )
        let stamp = FileRevisionStamp(status, sha256: LocalHash.sha256(data))
        return (data, status, stamp)
    }

    private func verifyPreimage(
        parent: WorkspaceDirectory,
        name: String,
        expected: FileRevisionStamp?
    ) throws {
        guard let expected else {
            guard try parent.status(name) == nil else {
                if let current = try? fileRevision(parent: parent, name: name) {
                    throw LocalMCPError.createOnlyConflict(
                        currentSHA256: current.stamp.sha256,
                        modifiedMilliseconds: current.stamp.modifiedMilliseconds
                    )
                }
                throw LocalMCPError.conflict("new-file destination appeared before publication")
            }
            return
        }
        let current = try fileRevision(parent: parent, name: name)
        guard current.stamp == expected else {
            throw LocalMCPError.casConflict(
                expectedSHA256: expected.sha256,
                currentSHA256: current.stamp.sha256,
                modifiedMilliseconds: current.stamp.modifiedMilliseconds
            )
        }
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
        let transaction = StoredTransaction(action: action, sequence: nextTransactionSequence, workID: nil)
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
        result["recoverable"] = true
        result["blocks_reload"] = true
        return result
    }
}
