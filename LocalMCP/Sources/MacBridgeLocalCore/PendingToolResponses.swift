import Foundation

// Per-run response lifetime/error state. Shared mutation is protected by lock;
// the DispatchGroup keeps EOF from dropping a previously admitted response.
final class PendingToolResponses: @unchecked Sendable {
    static let maximumOutstanding = 32
    // A command stream can require six JSON bytes for each retained control
    // byte. Keep active and completed-but-undelivered replies under one fixed
    // worst-case serialization budget instead of bounding only their count.
    static let maximumEstimatedBytes = 386 * 1_024 * 1_024
    let group = DispatchGroup()
    private let lock = NSLock()
    private var failed = false
    private var outstanding = 0
    private var estimatedBytes = 0
    var writeFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
    func recordWriteFailure() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    /// Reserve one complete async response lifetime: computing, queued for the
    /// shared writer, and writing. This bound is deliberately separate from
    /// per-tool execution limits because those leases are released before a
    /// potentially stalled tunnel drains stdout.
    func reserve(estimatedBytes bytes: Int = 0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bytes >= 0, outstanding < Self.maximumOutstanding,
              bytes <= Self.maximumEstimatedBytes - estimatedBytes else { return false }
        outstanding += 1
        estimatedBytes += bytes
        return true
    }

    func release(estimatedBytes bytes: Int = 0) {
        lock.lock()
        assert(outstanding > 0 && bytes >= 0 && estimatedBytes >= bytes,
               "unbalanced pending response reservation")
        outstanding = max(0, outstanding - 1)
        estimatedBytes = max(0, estimatedBytes - bytes)
        lock.unlock()
    }

    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstanding
    }

    var estimatedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return estimatedBytes
    }
}
