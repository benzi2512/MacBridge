import Foundation

// Per-run response lifetime/error state. Shared mutation is protected by lock;
// the DispatchGroup keeps EOF from dropping a previously admitted response.
final class PendingToolResponses: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var failed = false
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
}
