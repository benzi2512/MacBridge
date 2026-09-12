import Foundation

// Per-run response lifetime/error state. Shared mutation is protected by lock;
// the DispatchGroup keeps EOF from dropping a previously admitted response.
final class PendingToolResponses: @unchecked Sendable {
    static let maximumOutstanding = 32
    let group = DispatchGroup()
    private let lock = NSLock()
    private var failed = false
    private var outstanding = 0
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
    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outstanding < Self.maximumOutstanding else { return false }
        outstanding += 1
        return true
    }

    func release() {
        lock.lock()
        assert(outstanding > 0, "unbalanced pending response reservation")
        outstanding = max(0, outstanding - 1)
        lock.unlock()
    }

    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstanding
    }
}
