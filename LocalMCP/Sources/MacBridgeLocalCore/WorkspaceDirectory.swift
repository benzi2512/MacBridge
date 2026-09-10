import Darwin
import Foundation

/// Keep the directory used by a mutation open. Every leaf operation is relative
/// to that descriptor, so a later replacement of a pathname cannot redirect it.
final class WorkspaceDirectory {
    let descriptor: Int32

    init(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        descriptor = fd
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    func identity() throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw Self.failure() }
        return value
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_size == rhs.st_size
            && lhs.st_flags == rhs.st_flags
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    func requireIdentity(_ name: String, expected: stat) throws {
        guard let current = try status(name), Self.sameIdentity(current, expected) else {
            throw LocalMCPError.conflict("directory entry changed; replacement was preserved")
        }
    }

    private func requireVersion(_ name: String, expected: stat) throws {
        guard let current = try status(name), Self.sameVersion(current, expected) else {
            throw LocalMCPError.conflict("tree entry changed; current data was preserved")
        }
    }

    private static func leaf(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw LocalMCPError.invalidPath("single directory entry required")
        }
    }

    static func failure() -> LocalMCPError {
        .operationFailed(String(cString: strerror(errno)))
    }

    func status(_ name: String) throws -> stat? {
        try Self.leaf(name)
        var value = stat()
        if fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw Self.failure()
    }

    func child(_ name: String) throws -> WorkspaceDirectory {
        try Self.leaf(name)
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        return WorkspaceDirectory(descriptor: fd)
    }

    func openFile(_ name: String) throws -> Int32 {
        try Self.leaf(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
            close(fd)
            throw LocalMCPError.wrongFileType
        }
        return fd
    }

    func makeDirectory(_ name: String, mode: mode_t = 0o700) throws {
        try Self.leaf(name)
        guard mkdirat(descriptor, name, mode) == 0 else { throw Self.failure() }
    }

    func privateChild(_ name: String) throws -> WorkspaceDirectory {
        if try status(name) == nil { try makeDirectory(name) }
        let directory = try child(name)
        var value = stat()
        guard fstat(directory.descriptor, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o022 == 0 else {
            throw LocalMCPError.operationFailed("recovery directory is not private to the current user")
        }
        return directory
    }

    func rename(_ name: String, to destination: WorkspaceDirectory, as target: String,
                replace: Bool = false) throws {
        try Self.leaf(name); try Self.leaf(target)
        let result = renameatx_np(descriptor, name, destination.descriptor, target,
                                 replace ? 0 : UInt32(RENAME_EXCL))
        guard result == 0 else {
            if errno == EEXIST { throw LocalMCPError.conflict("destination changed before publication; existing data preserved") }
            if errno == EXDEV { throw LocalMCPError.conflict("cross-volume move requires a separately verified copy and recoverable removal; no move performed") }
            throw Self.failure()
        }
    }

    func unlink(_ name: String, directory: Bool = false) throws {
        try Self.leaf(name)
        guard unlinkat(descriptor, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw Self.failure() }
    }

    struct Names {
        let values: [String]
        let limited: Bool
    }

    /// At most one bounded set is sorted. Never ask Foundation to materialize
    /// every entry before checking the traversal limit.
    func names(maximumCount: Int = 20_001, maximumBytes: Int = 4 * 1_024 * 1_024) throws -> Names {
        let fd = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(fd) else { close(fd); throw Self.failure() }
        defer { closedir(stream) }
        var values: [String] = [], bytes = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.failure() }
                return Names(values: values.sorted(), limited: false)
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard values.count < maximumCount, name.utf8.count <= maximumBytes - bytes else {
                return Names(values: values.sorted(), limited: true)
            }
            bytes += name.utf8.count
            values.append(name)
        }
    }

    func atomicWrite(_ data: Data, name: String, mode: Int, replacing: Bool) throws {
        try Self.leaf(name)
        let temporary = ".macbridge-write-" + UUID().uuidString.lowercased()
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(mode & 0o777))
        guard fd >= 0 else { throw Self.failure() }
        var created = stat()
        guard fstat(fd, &created) == 0 else { close(fd); throw Self.failure() }
        var published = false
        defer {
            // A successful rename consumed the name; never unlink a later
            // entry another actor may create at that now-vacant spelling.
            if !published, (try? requireIdentity(temporary, expected: created)) != nil {
                _ = unlinkat(descriptor, temporary, 0)
            }
            close(fd)
        }
        try Self.write(data, descriptor: fd)
        guard fsync(fd) == 0 else { throw Self.failure() }
        try requireIdentity(temporary, expected: created)
        try rename(temporary, to: self, as: name, replace: replacing)
        published = true
    }

    private static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw failure() }
            }
        }
    }

    struct TreeBudget {
        var entries = 0
        var bytes: Int64 = 0
        mutating func include(_ value: stat, depth: Int) throws {
            guard entries < LocalWorkspaceService.maximumTreeEntries, depth <= 128 else {
                throw LocalMCPError.limitExceeded("tree entry count or depth")
            }
            entries += 1
            if value.st_mode & S_IFMT == S_IFREG {
                guard value.st_nlink == 1, value.st_size >= 0,
                      value.st_size <= LocalWorkspaceService.maximumTreeBytes - bytes else {
                    throw LocalMCPError.limitExceeded("tree byte count or unsupported file")
                }
                bytes += value.st_size
            } else if value.st_mode & S_IFMT != S_IFDIR {
                throw LocalMCPError.wrongFileType
            }
        }
    }

    struct TreeEntry {
        let name: String
        let version: stat
        let children: [TreeEntry]
    }

    struct TreeSnapshot {
        let digest: String
        let root: TreeEntry
    }

    func digest(_ name: String, logicalPath: String) throws -> String {
        try snapshot(name, logicalPath: logicalPath).digest
    }

    /// The manifest shares the digest traversal's entry, byte and depth budgets.
    /// It is retained only for this operation, never persisted in an undo receipt.
    func snapshot(_ name: String, logicalPath: String,
                  afterDirectoryEnumerationForTesting: ((String) throws -> Void)? = nil) throws -> TreeSnapshot {
        var budget = TreeBudget(), rows: [String] = []
        let root = try snapshotEntry(name, logicalPath: logicalPath, relative: ".", depth: 0,
            budget: &budget, rows: &rows, afterDirectoryEnumeration: afterDirectoryEnumerationForTesting)
        return TreeSnapshot(digest: LocalHash.sha256(Data(rows.sorted().joined(separator: "\n").utf8)), root: root)
    }

    private func snapshotEntry(_ name: String, logicalPath: String, relative: String, depth: Int,
                               budget: inout TreeBudget, rows: inout [String],
                               afterDirectoryEnumeration: ((String) throws -> Void)?) throws -> TreeEntry {
        guard !LocalFilesystemAccess.isSensitive(logicalPath) else { throw LocalMCPError.sensitivePathBlocked }
        guard let value = try status(name) else { throw LocalMCPError.notFound }
        try budget.include(value, depth: depth)
        if value.st_mode & S_IFMT == S_IFREG {
            let fd = try openFile(name)
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, Self.sameVersion(opened, value) else {
                throw LocalMCPError.conflict("tree file changed")
            }
            let hash = try LocalHash.sha256(descriptor: fd, maximumBytes: value.st_size)
            try requireVersion(name, expected: value)
            rows.append("F\0\(relative)\0\(value.st_size)\0\(posixMode(value))\0\(hash)")
            return TreeEntry(name: name, version: value, children: [])
        } else {
            let directory = try child(name)
            guard Self.sameVersion(try directory.identity(), value) else { throw LocalMCPError.conflict("tree directory changed") }
            rows.append("D\0\(relative)\0\(posixMode(value))")
            let entries = try directory.names(maximumCount: LocalWorkspaceService.maximumTreeEntries - budget.entries)
            guard !entries.limited else { throw LocalMCPError.limitExceeded("tree entry count") }
            try afterDirectoryEnumeration?(logicalPath)
            var children: [TreeEntry] = []
            for child in entries.values {
                children.append(try directory.snapshotEntry(child, logicalPath: logicalPath + "/" + child,
                    relative: relative == "." ? child : relative + "/" + child,
                    depth: depth + 1, budget: &budget, rows: &rows,
                    afterDirectoryEnumeration: afterDirectoryEnumeration))
            }
            guard Self.sameVersion(try directory.identity(), value) else {
                throw LocalMCPError.conflict("tree directory changed during enumeration")
            }
            try requireVersion(name, expected: value)
            return TreeEntry(name: name, version: value, children: children)
        }
    }

    func copy(_ name: String, to destination: WorkspaceDirectory, as target: String,
              logicalPath: String, depth: Int = 0, budget: inout TreeBudget) throws {
        guard !LocalFilesystemAccess.isSensitive(logicalPath) else { throw LocalMCPError.sensitivePathBlocked }
        guard let value = try status(name) else { throw LocalMCPError.notFound }
        try budget.include(value, depth: depth)
        if value.st_mode & S_IFMT == S_IFDIR {
            let source = try child(name)
            guard Self.sameVersion(try source.identity(), value) else { throw LocalMCPError.conflict("copy directory changed") }
            try destination.makeDirectory(target)
            let output = try destination.child(target)
            let names = try source.names(maximumCount: LocalWorkspaceService.maximumTreeEntries - budget.entries)
            guard !names.limited else { throw LocalMCPError.limitExceeded("tree entry count") }
            for item in names.values {
                try source.copy(item, to: output, as: item, logicalPath: logicalPath + "/" + item,
                                depth: depth + 1, budget: &budget)
            }
            // Preserve quarantine and other metadata just as copyItem did;
            // copying data alone must not turn acquired bytes into unquarantined bytes.
            guard fcopyfile(source.descriptor, output.descriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw Self.failure()
            }
            guard Self.sameVersion(try source.identity(), value) else {
                throw LocalMCPError.conflict("copy directory changed during enumeration")
            }
            try requireVersion(name, expected: value)
        } else {
            let source = try openFile(name)
            defer { close(source) }
            var before = stat()
            guard fstat(source, &before) == 0, before.st_dev == value.st_dev, before.st_ino == value.st_ino,
                  before.st_size == value.st_size else { throw LocalMCPError.conflict("copy source changed") }
            let output = openat(destination.descriptor, target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw Self.failure() }
            defer { close(output) }
            var buffer = Data(count: 65_536), offset: Int64 = 0
            while offset < value.st_size {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    pread(source, bytes.baseAddress!, min(bytes.count, Int(value.st_size - offset)), off_t(offset))
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LocalMCPError.conflict("copy source changed during read") }
                try Self.write(buffer.prefix(count), descriptor: output)
                offset += Int64(count)
            }
            guard fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw Self.failure() }
            var after = stat()
            guard fstat(source, &after) == 0, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
                throw LocalMCPError.conflict("copy source changed during read")
            }
            guard fsync(output) == 0 else { throw Self.failure() }
        }
    }

    /// Check the entire manifest before starting, then consume only those entries.
    /// An addition after verification is never selected for deletion: rmdir fails
    /// if it remains. Per-entry checks also preserve changes observed during undo;
    /// they are not an atomic compare-and-unlink against arbitrary same-user code.
    func removeVerifiedTree(_ snapshot: TreeSnapshot,
                            beforeEntryRemovalForTesting: ((String) throws -> Void)? = nil) throws {
        try verifySnapshotEntry(snapshot.root)
        try removeSnapshotEntry(snapshot.root, beforeEntryRemoval: beforeEntryRemovalForTesting)
    }

    private func verifySnapshotEntry(_ entry: TreeEntry) throws {
        try requireVersion(entry.name, expected: entry.version)
        if entry.version.st_mode & S_IFMT == S_IFDIR {
            let directory = try child(entry.name)
            guard Self.sameVersion(try directory.identity(), entry.version) else {
                throw LocalMCPError.conflict("undo directory changed")
            }
            for child in entry.children { try directory.verifySnapshotEntry(child) }
            try requireVersion(entry.name, expected: entry.version)
        }
    }

    private func removeSnapshotEntry(_ entry: TreeEntry,
                                     beforeEntryRemoval: ((String) throws -> Void)?) throws {
        try beforeEntryRemoval?(entry.name)
        try requireVersion(entry.name, expected: entry.version)
        if entry.version.st_mode & S_IFMT == S_IFDIR {
            let directory = try child(entry.name)
            guard Self.sameVersion(try directory.identity(), entry.version) else {
                throw LocalMCPError.conflict("undo directory changed")
            }
            for child in entry.children {
                try directory.removeSnapshotEntry(child, beforeEntryRemoval: beforeEntryRemoval)
            }
            // Our own removals changed the directory version. Check identity,
            // and let rmdir refuse any newly added entries without visiting them.
            try requireIdentity(entry.name, expected: entry.version)
            try unlink(entry.name, directory: true)
        } else {
            try unlink(entry.name)
        }
    }

    /// Never follow links during recursive cleanup of a uniquely owned private
    /// staging directory. Undo targets must use removeVerifiedTree instead.
    func removeTree(_ name: String, expected: stat? = nil) throws {
        var remaining = LocalWorkspaceService.maximumTreeEntries + 1
        try removeTree(name, expected: expected, depth: 0, remaining: &remaining)
    }

    private func removeTree(_ name: String, expected: stat?, depth: Int, remaining: inout Int) throws {
        guard depth <= 128, remaining > 0 else { throw LocalMCPError.limitExceeded("tree cleanup budget") }
        guard let value = try status(name) else { return }
        if let expected, !Self.sameIdentity(value, expected) {
            throw LocalMCPError.conflict("cleanup entry was replaced; replacement was preserved")
        }
        remaining -= 1
        if value.st_mode & S_IFMT == S_IFDIR {
            let directory = try child(name)
            guard Self.sameIdentity(try directory.identity(), value) else { throw LocalMCPError.conflict("cleanup directory changed") }
            let names = try directory.names(maximumCount: LocalWorkspaceService.maximumTreeEntries)
            guard !names.limited else { throw LocalMCPError.limitExceeded("tree cleanup entries") }
            for item in names.values { try directory.removeTree(item, expected: nil, depth: depth + 1, remaining: &remaining) }
            try requireIdentity(name, expected: value)
            try unlink(name, directory: true)
        } else {
            try requireIdentity(name, expected: value)
            try unlink(name)
        }
    }
}
