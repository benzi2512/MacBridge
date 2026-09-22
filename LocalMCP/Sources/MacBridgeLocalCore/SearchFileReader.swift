import Darwin
import Foundation

enum SearchBudgetLimit: Error {
    case time, bytes
}

// Cooperative budgets, not a promise that macOS can interrupt a blocked syscall.
// The search loop checks time between directories, entries, reads and matches.
final class SearchBudget {
    private let now: () -> UInt64
    private let start: UInt64
    private let duration: UInt64
    let maximumBytes: Int
    private(set) var bytesRead = 0

    init(milliseconds: Int, maximumBytes: Int,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        start = now()
        duration = UInt64(milliseconds) * 1_000_000
        self.maximumBytes = maximumBytes
    }

    func checkTime() throws {
        if now() &- start >= duration { throw SearchBudgetLimit.time }
    }

    func requireBytes(_ count: Int) throws {
        guard count <= maximumBytes - bytesRead else { throw SearchBudgetLimit.bytes }
    }

    func recordRead(_ count: Int) { bytesRead += count }
}

enum SearchReadIssue: Error {
    case oversized, dataless, changed, unsupported
}

enum SearchFileReader {
    static func isDataless(_ status: stat) -> Bool {
        LocalFileReader.isDataless(status)
    }

    // Never mmap search input, hydrate a known dataless placeholder, follow a
    // symlink, or allocate based on an unchecked/growing file size. O_NONBLOCK
    // prevents waiting for FIFO open; it is NOT an I/O deadline for regular files.
    static func read(_ url: URL, expected: stat, maximumBytes: Int,
                     budget: SearchBudget) throws -> Data {
        try budget.checkTime()
        if isDataless(expected) { throw SearchReadIssue.dataless }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0 else { throw SearchReadIssue.unsupported }
        if isDataless(before) { throw SearchReadIssue.dataless }
        guard before.st_size <= maximumBytes else { throw SearchReadIssue.oversized }
        guard before.st_dev == expected.st_dev, before.st_ino == expected.st_ino,
              before.st_size == expected.st_size else { throw SearchReadIssue.changed }
        let size = Int(before.st_size)
        try budget.requireBytes(size)
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < size {
                try budget.checkTime()
                let count = Darwin.pread(fd, base.advanced(by: offset),
                                         min(65_536, size - offset), off_t(offset))
                if count > 0 {
                    offset += count
                    budget.recordRead(count)
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count == 0 {
                    throw SearchReadIssue.changed
                } else {
                    throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
                }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { throw SearchReadIssue.changed }
        try budget.checkTime()
        return data
    }
}
