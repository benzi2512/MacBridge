import Darwin
import Foundation

// Pipe callbacks may end inside a valid UTF-8 scalar. Hold at most three bytes
// until a later callback or EOF, instead of returning a cursor into that scalar.
// Already-invalid bytes keep the existing replacement-decoding behavior.
func streamingUTF8End(_ data: Data) -> Int {
    let end = data.endIndex
    guard !data.isEmpty else { return end }
    var lead = end - 1
    while lead > data.startIndex, end - lead < 4, data[lead] & 0xC0 == 0x80 {
        lead -= 1
    }
    let width: Int
    switch data[lead] {
    case 0xC2...0xDF: width = 2
    case 0xE0...0xEF: width = 3
    case 0xF0...0xF4: width = 4
    default: return end
    }
    guard end - lead < width else { return end }
    for i in (lead + 1)..<end where data[i] & 0xC0 != 0x80 { return end }
    if end - lead > 1 {
        let second = data[lead + 1]
        if (data[lead] == 0xE0 && second < 0xA0)
            || (data[lead] == 0xED && second > 0x9F)
            || (data[lead] == 0xF0 && second < 0x90)
            || (data[lead] == 0xF4 && second > 0x8F) { return end }
    }
    return lead
}

private struct AllowedExecutable {
    let id: String
    let invocationPath: String
}

private struct ProcessSnapshot {
    let taskID: String
    let networkGrant: LocalNetworkGrant?
    let running: Bool
    let exitCode: Int32?
    let terminationReason: String?
    let timedOut: Bool
    let cancelled: Bool
    let stdout: Data
    let stderr: Data
    let stdoutBaseOffset: Int
    let stderrBaseOffset: Int
    let stdoutTotalBytes: Int
    let stderrTotalBytes: Int
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let startedMilliseconds: Int64
    let endedMilliseconds: Int64?
}

private let runtimePathLock = NSLock()
private let runtimeCleanupQueue = DispatchQueue(
    label: "com.macbridge.local-mcp.runtime-cleanup",
    qos: .utility,
    attributes: .concurrent
)

func cleanupRuntimePath(_ runtime: URL) {
    // A terminating toolchain can still finish a last HOME/cache filesystem
    // operation while its process group is being reaped. Repeat removal for
    // a short, bounded settling window so a transient directory recreation
    // cannot leave empty .macbridge/runtime residue in the workspace.
    for attempt in 0..<8 {
        if attempt > 0 { Thread.sleep(forTimeInterval: 0.02) }
        cleanupRuntimePathOnce(runtime)
    }
}

func scheduleRuntimePathCleanup(_ runtime: URL, delay: TimeInterval = 1.0) {
    // Retain the bounded settling window without sleeping a dispatch worker.
    // Each callback is limited to this command's exact private runtime path.
    let start = DispatchTime.now() + delay
    for attempt in 0..<8 {
        runtimeCleanupQueue.asyncAfter(deadline: start + Double(attempt) * 0.02) {
            cleanupRuntimePathOnce(runtime)
        }
    }
}

private func cleanupRuntimePathOnce(_ runtime: URL) {
    runtimePathLock.lock()
    defer { runtimePathLock.unlock() }
    var status = stat()
    if lstat(runtime.path, &status) == 0 {
        prepareRuntimeForRemoval(runtime)
        try? FileManager.default.removeItem(at: runtime)
    }
    // Remove only empty parents created by this runtime. rmdir never follows a
    // symlink and safely fails while another task or existing state uses them.
    _ = rmdir(runtime.deletingLastPathComponent().path)
    _ = rmdir(runtime.deletingLastPathComponent().deletingLastPathComponent().path)
}

private func prepareRuntimeForRemoval(_ url: URL) {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { return }
    if status.st_mode & S_IFMT == S_IFDIR {
        _ = chflags(url.path, 0)
        _ = chmod(url.path, 0o700)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return
        }
        for name in names {
            prepareRuntimeForRemoval(url.appendingPathComponent(name))
        }
    } else if status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 {
        _ = chflags(url.path, 0)
        _ = chmod(url.path, 0o600)
    }
}

private final class RunningCommand: @unchecked Sendable {
    let taskID: String
    // Sanitized display-only context. Never retain raw argv or script text here.
    let activityContext: String?
    let process: Process
    let runtimeURL: URL
    let maximumOutputBytes: Int
    let networkProxy: NetworkCommandProxy?
    let networkGrant: LocalNetworkGrant?
    let startedMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)

    private let lock = NSCondition()
    private let stdinLock = NSLock()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdinClosed = false
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutBaseOffset = 0
    private var stderrBaseOffset = 0
    private var stdoutTotalBytes = 0
    private var stderrTotalBytes = 0
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var running = true
    private var childExited = false
    private var stdoutReachedEOF = false
    private var stderrReachedEOF = false
    private var exitCode: Int32?
    private var terminationReason: String?
    private var endedMilliseconds: Int64?
    private var timedOut = false
    private var cancelled = false

    init(
        taskID: String,
        activityContext: String?,
        process: Process,
        runtimeURL: URL,
        maximumOutputBytes: Int,
        networkProxy: NetworkCommandProxy? = nil,
        networkGrant: LocalNetworkGrant? = nil
    ) {
        self.taskID = taskID
        self.activityContext = activityContext
        self.process = process
        self.runtimeURL = runtimeURL
        self.maximumOutputBytes = maximumOutputBytes
        self.networkProxy = networkProxy
        self.networkGrant = networkGrant
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        let inputDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        let inputFlags = fcntl(inputDescriptor, F_GETFL)
        guard inputFlags >= 0,
            fcntl(inputDescriptor, F_SETFL, inputFlags | O_NONBLOCK) == 0,
            fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) == 0
        else { throw LocalMCPError.operationFailed("process stdin setup failed") }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // FileHandle continues invoking a readability handler at EOF
                // until the handler is removed. Leaving it installed leaks a
                // dispatch source per completed command and eventually spins
                // hundreds of worker threads in a long-lived MCP process.
                handle.readabilityHandler = nil
                self?.reachedEOF(stream: .stdout)
                return
            }
            self?.append(data, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.reachedEOF(stream: .stderr)
                return
            }
            self?.append(data, stream: .stderr)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.networkProxy?.stop()
            let processGroup = process.processIdentifier
            if processGroup > 0 {
                _ = kill(-processGroup, SIGKILL)
            }
            self.stdinLock.lock()
            if !self.stdinClosed {
                try? self.stdinPipe.fileHandleForWriting.close()
                self.stdinClosed = true
            }
            self.stdinLock.unlock()
            cleanupRuntimePathOnce(self.runtimeURL)
            scheduleRuntimePathCleanup(self.runtimeURL, delay: 0.02)
            // Some toolchains finish a final cache/HOME mkdir after the
            // process group receives its terminal signal. Recheck this exact
            // UUID after quiescence without delaying the command response.
            scheduleRuntimePathCleanup(self.runtimeURL)
            self.lock.lock()
            self.childExited = true
            self.exitCode = process.terminationStatus
            self.terminationReason =
                process.terminationReason == .exit ? "exit" : "uncaught_signal"
            self.endedMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            self.finishIfReadyWhileLocked()
            self.lock.unlock()
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            stdinClosed = true
            lock.lock()
            running = false
            endedMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
            lock.broadcast()
            lock.unlock()
            throw error
        }
    }

    func wait(timeoutMilliseconds: Int) -> ProcessSnapshot {
        if !waitForCompletion(timeoutMilliseconds: timeoutMilliseconds) {
            markTimedOut()
            terminateProcessGroup()
            if !waitForCompletion(timeoutMilliseconds: 2_000) {
                forceKillProcessGroup()
                _ = waitForCompletion(timeoutMilliseconds: 1_000)
            }
        }
        return snapshot()
    }

    func cancel() -> ProcessSnapshot {
        networkProxy?.stop()
        lock.lock()
        guard running else {
            let completed = snapshotWhileLocked()
            lock.unlock()
            return completed
        }
        // A child that exited naturally may still be draining its pipes.
        // Waiting for those final bytes must not relabel its exit as a cancel.
        if !childExited { cancelled = true }
        lock.unlock()
        terminateProcessGroup()
        if !waitForCompletion(timeoutMilliseconds: 1_000) {
            forceKillProcessGroup()
        }
        return wait(timeoutMilliseconds: 1_000)
    }

    func expireNetworkGrant() {
        networkProxy?.stop()
        lock.lock()
        if running, !childExited { cancelled = true }
        lock.unlock()
        // No graceful one-second network window after an authorization expires.
        forceKillProcessGroup()
    }

    func waitForCompletion(timeoutMilliseconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        lock.lock()
        defer { lock.unlock() }
        while running {
            if !lock.wait(until: deadline) { return !running }
        }
        return true
    }

    func sendInput(
        _ data: Data,
        closeAfterWriting: Bool
    ) throws -> (snapshot: ProcessSnapshot, bytesWritten: Int, stdinClosed: Bool) {
        guard data.count <= 65_536 else {
            throw LocalMCPError.limitExceeded("process input")
        }
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard !stdinClosed, snapshot().running else {
            throw LocalMCPError.conflict("process stdin is closed")
        }
        var bytesWritten = 0
        if !data.isEmpty {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                while bytesWritten < rawBuffer.count {
                    let count = Darwin.write(
                        stdinPipe.fileHandleForWriting.fileDescriptor,
                        base.advanced(by: bytesWritten),
                        rawBuffer.count - bytesWritten
                    )
                    if count > 0 {
                        bytesWritten += count
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
                    if count < 0, errno == EPIPE {
                        try? stdinPipe.fileHandleForWriting.close()
                        stdinClosed = true
                        throw LocalMCPError.conflict("process stdin is closed")
                    }
                    throw LocalMCPError.operationFailed("process input write failed")
                }
            }
        }
        if closeAfterWriting, bytesWritten == data.count {
            do {
                try stdinPipe.fileHandleForWriting.close()
                stdinClosed = true
            } catch {
                throw LocalMCPError.operationFailed("process input close failed")
            }
        }
        return (snapshot(), bytesWritten, stdinClosed)
    }

    func snapshot() -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotWhileLocked()
    }

    private func snapshotWhileLocked() -> ProcessSnapshot {
        return ProcessSnapshot(
            taskID: taskID,
            networkGrant: networkGrant,
            running: running,
            exitCode: exitCode,
            terminationReason: terminationReason,
            timedOut: timedOut,
            cancelled: cancelled,
            stdout: stdout,
            stderr: stderr,
            stdoutBaseOffset: stdoutBaseOffset,
            stderrBaseOffset: stderrBaseOffset,
            stdoutTotalBytes: stdoutTotalBytes,
            stderrTotalBytes: stderrTotalBytes,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            startedMilliseconds: startedMilliseconds,
            endedMilliseconds: endedMilliseconds
        )
    }

    private enum Stream { case stdout, stderr }

    private func reachedEOF(stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: stdoutReachedEOF = true
        case .stderr: stderrReachedEOF = true
        }
        finishIfReadyWhileLocked()
    }

    private func finishIfReadyWhileLocked() {
        guard running, childExited, stdoutReachedEOF, stderrReachedEOF else { return }
        // A stopped snapshot promises that the output totals are final. This
        // also makes it safe for process_output to forget a drained session.
        running = false
        lock.broadcast()
    }

    private func append(_ data: Data, stream: Stream) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout:
            appendTail(
                data,
                buffer: &stdout,
                baseOffset: &stdoutBaseOffset,
                totalBytes: &stdoutTotalBytes,
                truncated: &stdoutTruncated
            )
        case .stderr:
            appendTail(
                data,
                buffer: &stderr,
                baseOffset: &stderrBaseOffset,
                totalBytes: &stderrTotalBytes,
                truncated: &stderrTruncated
            )
        }
    }

    private func appendTail(
        _ data: Data,
        buffer: inout Data,
        baseOffset: inout Int,
        totalBytes: inout Int,
        truncated: inout Bool
    ) {
        let (nextTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
        totalBytes = overflow ? Int.max : nextTotal
        buffer.append(data)
        guard buffer.count > maximumOutputBytes else { return }
        var dropCount = buffer.count - maximumOutputBytes
        // Capacity is a retention ceiling, unlike a response chunk target.
        // Advance to the next scalar boundary; retreating could exceed the
        // reserved per-stream budget by three bytes and conceal truncation.
        while dropCount < buffer.count, buffer[dropCount] & 0xC0 == 0x80 {
            dropCount += 1
        }
        buffer.removeSubrange(0..<dropCount)
        baseOffset += dropCount
        truncated = true
    }

    private func markTimedOut() {
        lock.lock()
        if running, !childExited { timedOut = true }
        lock.unlock()
    }

    private func terminateProcessGroup() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0, kill(-pid, SIGTERM) != 0, process.isRunning {
            process.terminate()
        }
    }

    private func forceKillProcessGroup() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 { _ = kill(-pid, SIGKILL) }
    }
}

public final class LocalProcessService: @unchecked Sendable {
    public static let maximumCompletedStatuses = 128
    public static let completedStatusLifetime: TimeInterval = 300
    private static let maximumTrackedProcesses = 32
    public static let maximumAggregateOutputBytes = 64 * 1_024 * 1_024

    private let workspaceService: LocalWorkspaceService
    private let selfExecutable: URL
    private let lock = NSLock()
    private var processes: [String: RunningCommand] = [:]
    // A synchronous response still owns its output even if another request
    // reads or cancels the job while that response is being prepared.
    private var synchronousResponsePins: Set<String> = []
    private var completedStatuses: [String: (expires: TimeInterval, metadata: JSONObject, activityContext: String?)] = [:]
    private var completedOrder: [String] = []
    private let completedStatusLimit: Int
    private let completedStatusTTL: TimeInterval
    private let monotonicNow: () -> TimeInterval
    private var startingProcesses = 0
    private var reservedOutputBytes = 0
    private let outputByteLimit: Int
    private let swiftInstallation = SwiftInstallation.select()

    public convenience init(workspaceService: LocalWorkspaceService, selfExecutable: URL) {
        self.init(workspaceService: workspaceService, selfExecutable: selfExecutable,
                  outputByteLimit: Self.maximumAggregateOutputBytes)
    }

    init(workspaceService: LocalWorkspaceService, selfExecutable: URL, outputByteLimit: Int,
         completedStatusLimit: Int = LocalProcessService.maximumCompletedStatuses,
         completedStatusTTL: TimeInterval = LocalProcessService.completedStatusLifetime,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(outputByteLimit >= 0)
        precondition(completedStatusLimit >= 0 && completedStatusLimit <= Self.maximumCompletedStatuses)
        precondition(completedStatusTTL >= 0 && completedStatusTTL.isFinite)
        self.workspaceService = workspaceService
        self.selfExecutable = selfExecutable
        self.outputByteLimit = outputByteLimit
        self.completedStatusLimit = completedStatusLimit
        self.completedStatusTTL = completedStatusTTL
        self.monotonicNow = monotonicNow
    }

    var trackedProcessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count + startingProcesses
    }

    deinit {
        lock.lock()
        let commands = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for command in commands {
            _ = command.cancel()
            cleanupRuntimePathOnce(command.runtimeURL)
        }
    }

    public func runCommand(
        workspaceID: String,
        executableID: String,
        arguments: [String],
        cwd: String,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int
    ) throws -> JSONObject {
        try prepareCommandRun(workspaceID: workspaceID, executableID: executableID,
            arguments: arguments, cwd: cwd, timeoutMilliseconds: timeoutMilliseconds,
            maximumOutputBytes: maximumOutputBytes)()
    }

    // Inspection tools must not inherit the write/process/network capabilities
    // of a user-authorized project command. Keep this mode internal to the fixed
    // Git inspection dispatcher rather than adding a caller-selectable tool flag.
    func runReadOnlyGit(
        workspaceID: String, arguments: [String], cwd: String,
        timeoutMilliseconds: Int, maximumOutputBytes: Int
    ) throws -> JSONObject {
        try prepareCommandRun(workspaceID: workspaceID, executableID: "git",
            arguments: arguments, cwd: cwd, timeoutMilliseconds: timeoutMilliseconds,
            maximumOutputBytes: maximumOutputBytes, readOnlyGit: true)()
    }

    // Start and validate in the caller's serialized admission path; only the
    // wait crosses onto a worker. Invoke the returned completion exactly once.
    func prepareCommandRun(
        workspaceID: String,
        executableID: String,
        arguments: [String],
        cwd: String,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int,
        readOnlyGit: Bool = false
    ) throws -> @Sendable () -> JSONObject {
        let command = try startCommandInternal(
            workspaceID: workspaceID,
            executableID: executableID,
            arguments: arguments,
            cwd: cwd,
            maximumOutputBytes: maximumOutputBytes,
            pinSynchronousResponse: true,
            readOnlyGit: readOnlyGit
        )
        let admittedAt = ProcessInfo.processInfo.systemUptime
        return { [self, command] in
            // Worker scheduling time must not extend the command's timeout.
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - admittedAt) * 1000)
            let snapshot = command.wait(timeoutMilliseconds: max(0, timeoutMilliseconds - elapsed))
            let result = snapshotJSON(snapshot, includeOutput: true)
            forget(command, releaseSynchronousResponse: true)
            return result
        }
    }

    public func startCommand(
        workspaceID: String,
        executableID: String,
        arguments: [String],
        cwd: String,
        maximumOutputBytes: Int
    ) throws -> JSONObject {
        let command = try startCommandInternal(
            workspaceID: workspaceID,
            executableID: executableID,
            arguments: arguments,
            cwd: cwd,
            maximumOutputBytes: maximumOutputBytes
        )
        return snapshotJSON(command.snapshot(), includeOutput: false)
    }

    func startNetworkCommand(workspaceID: String, grantID: String, executableID: String,
                             arguments: [String], maximumOutputBytes: Int) throws -> JSONObject {
        let workspace = try workspaceService.registry.workspace(id: workspaceID)
        let grant = try LocalNetworkGrant.resolve(id: grantID, workspace: workspace, service: workspaceService)
        let command = try startCommandInternal(workspaceID: workspaceID,
            executableID: executableID, arguments: arguments, cwd: grant.cwd,
            maximumOutputBytes: maximumOutputBytes, networkGrant: grant)
        return snapshotJSON(command.snapshot(), includeOutput: false)
    }

    public func processStatus(taskID rawID: String) throws -> JSONObject {
        guard let uuid = UUID(uuidString: rawID) else {
            throw LocalMCPError.invalidRequest("task_id must be a UUID")
        }
        let id = uuid.uuidString.lowercased()
        lock.lock()
        defer { lock.unlock() }
        pruneCompletedStatusesWhileLocked()
        if let command = processes[id] {
            var metadata = snapshotJSON(command.snapshot(), includeOutput: false)
            metadata["session_retained"] = true
            metadata["status_only"] = false
            return metadata
        }
        guard let completed = completedStatuses[id] else { throw LocalMCPError.processNotFound }
        return completed.metadata
    }

    public func observeProcess(taskID: String, maximumWaitMilliseconds: Int) throws -> JSONObject {
        guard (0...1000).contains(maximumWaitMilliseconds) else {
            throw LocalMCPError.invalidRequest("observation wait must be 0...1000 ms")
        }
        let before = try processStatus(taskID: taskID)
        if before["running"] as? Bool == true {
            _ = try process(taskID).waitForCompletion(timeoutMilliseconds: maximumWaitMilliseconds)
        }
        var result = try processStatus(taskID: taskID)
        result["observation_timed_out"] = result["running"] as? Bool == true
        result["output_consumed"] = false
        return result
    }

    // Shares the job's existing 32-live / 128-completed, five-minute lifecycle.
    // Lookup neither consumes output nor creates a new background cache/timer.
    func activityContext(taskID: String) -> String? {
        guard let uuid = UUID(uuidString: taskID) else { return nil }
        let id = uuid.uuidString.lowercased()
        lock.lock()
        defer { lock.unlock() }
        pruneCompletedStatusesWhileLocked()
        return processes[id]?.activityContext ?? completedStatuses[id]?.activityContext
    }

    public func outputTail(taskID: String, maximumBytes: Int) throws -> JSONObject {
        guard (4...65536).contains(maximumBytes) else {
            throw LocalMCPError.invalidRequest("invalid tail byte budget")
        }
        let snapshot = try process(taskID).snapshot()
        var result = snapshotJSON(snapshot, includeOutput: false)
        for (stream, data, base) in [
            ("stdout", snapshot.stdout, snapshot.stdoutBaseOffset),
            ("stderr", snapshot.stderr, snapshot.stderrBaseOffset),
        ] {
            let end = snapshot.running ? streamingUTF8End(data) : data.endIndex
            var start = max(0, end - maximumBytes)
            while start < end, data[start] & 0xC0 == 0x80 { start += 1 }
            result[stream] = String(decoding: data[start..<end], as: UTF8.self)
            result[stream + "_cursor"] = base + start
            result[stream + "_next_cursor"] = base + end
            result[stream + "_skipped_prefix_bytes"] = base + start
        }
        result["session_retained"] = true
        result["output_consumed"] = false
        return result
    }

    public func commandList() -> JSONObject {
        let rows: [JSONObject] = executablePaths.keys.sorted().map { id in
            ["executable": id, "available": (try? allowedExecutable(id)) != nil]
        }
        return ["commands": rows, "process_started": false, "network": "loopback_only"]
    }

    public func processOutput(
        taskID rawID: String,
        stdoutCursor: Int,
        stderrCursor: Int,
        maximumBytesPerStream: Int,
        consumeCompletedHandle: Bool = true
    ) throws -> JSONObject {
        let command = try process(rawID)
        let snapshot = command.snapshot()
        guard stdoutCursor >= 0, stdoutCursor <= snapshot.stdoutTotalBytes,
            stderrCursor >= 0, stderrCursor <= snapshot.stderrTotalBytes
        else { throw LocalMCPError.invalidRequest("output cursor is out of range") }
        let effectiveStdoutCursor = max(stdoutCursor, snapshot.stdoutBaseOffset)
        let effectiveStderrCursor = max(stderrCursor, snapshot.stderrBaseOffset)
        let relativeStdoutCursor = effectiveStdoutCursor - snapshot.stdoutBaseOffset
        let relativeStderrCursor = effectiveStderrCursor - snapshot.stderrBaseOffset
        let stdoutReadableEnd = snapshot.running ? streamingUTF8End(snapshot.stdout) : snapshot.stdout.endIndex
        let stderrReadableEnd = snapshot.running ? streamingUTF8End(snapshot.stderr) : snapshot.stderr.endIndex
        guard isUTF8Boundary(snapshot.stdout, at: relativeStdoutCursor),
            isUTF8Boundary(snapshot.stderr, at: relativeStderrCursor),
            relativeStdoutCursor <= stdoutReadableEnd, relativeStderrCursor <= stderrReadableEnd
        else { throw LocalMCPError.invalidRequest("output cursor splits a UTF-8 scalar") }
        let stdoutEnd = min(stdoutReadableEnd, textChunkEnd(
            snapshot.stdout, from: relativeStdoutCursor, maximumBytes: maximumBytesPerStream
        ))
        let stderrEnd = min(stderrReadableEnd, textChunkEnd(
            snapshot.stderr, from: relativeStderrCursor, maximumBytes: maximumBytesPerStream
        ))
        let stdoutNextCursor = snapshot.stdoutBaseOffset + stdoutEnd
        let stderrNextCursor = snapshot.stderrBaseOffset + stderrEnd
        var value = snapshotJSON(snapshot, includeOutput: false)
        value["stdout"] = String(decoding: snapshot.stdout[relativeStdoutCursor..<stdoutEnd], as: UTF8.self)
        value["stderr"] = String(decoding: snapshot.stderr[relativeStderrCursor..<stderrEnd], as: UTF8.self)
        value["stdout_requested_cursor"] = stdoutCursor
        value["stderr_requested_cursor"] = stderrCursor
        value["stdout_cursor"] = effectiveStdoutCursor
        value["stderr_cursor"] = effectiveStderrCursor
        value["stdout_next_cursor"] = stdoutNextCursor
        value["stderr_next_cursor"] = stderrNextCursor
        value["stdout_available_bytes"] = snapshot.stdout.count
        value["stderr_available_bytes"] = snapshot.stderr.count
        value["stdout_cursor_adjusted"] = effectiveStdoutCursor != stdoutCursor
        value["stderr_cursor_adjusted"] = effectiveStderrCursor != stderrCursor
        value["stdout_dropped_before_cursor"] = effectiveStdoutCursor - stdoutCursor
        value["stderr_dropped_before_cursor"] = effectiveStderrCursor - stderrCursor
        let fullyDrained =
            !snapshot.running && stdoutNextCursor == snapshot.stdoutTotalBytes
            && stderrNextCursor == snapshot.stderrTotalBytes
        let released = fullyDrained && consumeCompletedHandle && forget(command)
        value["session_retained"] = !released
        return value
    }

    public func processList() -> JSONObject {
        lock.lock()
        let commands = Array(processes.values)
        lock.unlock()
        let rows = commands.map { snapshotJSON($0.snapshot(), includeOutput: false) }
            .sorted {
                ($0["started_milliseconds"] as? Int64 ?? 0)
                    < ($1["started_milliseconds"] as? Int64 ?? 0)
            }
        return ["processes": rows]
    }

    public func processInput(
        taskID: String,
        content: String,
        encoding: String,
        closeStdin: Bool
    ) throws -> JSONObject {
        let data: Data
        switch encoding {
        case "utf8":
            data = Data(content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: content) else {
                throw LocalMCPError.invalidRequest("invalid base64 process input")
            }
            data = decoded
        default:
            throw LocalMCPError.invalidRequest("encoding must be utf8 or base64")
        }
        let result = try process(taskID).sendInput(data, closeAfterWriting: closeStdin)
        var value = snapshotJSON(result.snapshot, includeOutput: false)
        value["bytes_requested"] = data.count
        value["bytes_written"] = result.bytesWritten
        value["remaining_bytes"] = data.count - result.bytesWritten
        value["input_complete"] = result.bytesWritten == data.count
        value["stdin_closed"] = result.stdinClosed
        return value
    }

    public func cancelProcess(taskID rawID: String) throws -> JSONObject {
        let command = try process(rawID)
        let snapshot = command.cancel()
        let released = forget(command)
        var result = snapshotJSON(snapshot, includeOutput: true)
        result["session_retained"] = !released
        return result
    }

    private func startCommandInternal(
        workspaceID: String,
        executableID: String,
        arguments: [String],
        cwd: String,
        maximumOutputBytes: Int,
        pinSynchronousResponse: Bool = false,
        readOnlyGit: Bool = false,
        networkGrant: LocalNetworkGrant? = nil
    ) throws -> RunningCommand {
        guard !readOnlyGit || networkGrant == nil else {
            throw LocalMCPError.invalidRequest("read-only Git cannot use a network grant")
        }
        let grantDeadline = try networkGrant.map { DispatchTime.now() + (try $0.remainingSeconds()) }
        guard arguments.count <= 128,
            arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") })
        else { throw LocalMCPError.invalidRequest("command arguments exceed bounds") }
        guard (1...(16 * 1_024 * 1_024)).contains(maximumOutputBytes) else {
            throw LocalMCPError.invalidRequest("per-stream output capacity is out of range")
        }
        // Reserve both stream capacities before creating runtime directories or
        // starting a child. Retained completed handles keep their reservation.
        let outputReservation = maximumOutputBytes * 2
        try reserveProcessSlot(outputBytes: outputReservation)
        var slotReserved = true
        defer {
            if slotReserved { releaseProcessSlot(outputBytes: outputReservation) }
        }
        let executable = try allowedExecutable(executableID)
        let normalizedArguments = try normalizeArguments(
            executableID: executableID, arguments: arguments
        )
        let workingDirectory = try workspaceService.workspaceURL(
            workspaceID: workspaceID, relativePath: cwd
        )
        let workingStatus = try lstatValue(workingDirectory.path)
        guard workingStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LocalMCPError.wrongFileType
        }
        let workspace = try workspaceService.registry.workspace(id: workspaceID)
        let commandScope = try OperationSafety.commandScope(
            workspace: workspace,
            workingDirectory: workingDirectory
        )
        // Narrow workspaces retain their existing runtime location. Broad
        // access uses the user's private OS temp directory, never /.macbridge.
        let bridgeState: URL
        if workspace.allowsBroadAccess {
            let temporaryRoot = try canonicalExistingPath(FileManager.default.temporaryDirectory.path)
            bridgeState = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
                .appendingPathComponent(".macbridge-command-state-\(getuid())", isDirectory: true)
        } else {
            bridgeState = workspace.rootURL.appendingPathComponent(".macbridge", isDirectory: true)
        }
        let runtimeRoot = bridgeState.appendingPathComponent("runtime", isDirectory: true)
        let taskID = UUID().uuidString.lowercased()
        let runtime = runtimeRoot.appendingPathComponent(taskID, isDirectory: true)
        runtimePathLock.lock()
        do {
            try ensurePrivateDirectory(bridgeState)
            try ensurePrivateDirectory(runtimeRoot)
            try FileManager.default.createDirectory(
                at: runtime,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            runtimePathLock.unlock()
        } catch {
            runtimePathLock.unlock()
            throw error
        }
        var runtimeOwned = true
        defer {
            if runtimeOwned { cleanupRuntime(runtime) }
        }
        let home = runtime.appendingPathComponent("home", isDirectory: true)
        let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
        let cache = runtime.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profileURL = runtime.appendingPathComponent("command.sb")
        let networkProxy = try networkGrant.map { try NetworkCommandProxy(grant: $0) }
        var proxyTransferred = false
        defer { if !proxyTransferred { networkProxy?.stop() } }
        let profile = try sandboxProfile(
            workspace: commandScope,
            runtime: runtime,
            executable: executable.invocationPath,
            readOnlyGit: readOnlyGit,
            networkProxyPort: networkProxy?.port
        )
        try writeNewRuntimeProfile(Data(profile.utf8), to: profileURL)

        let process = Process()
        process.executableURL = selfExecutable
        process.arguments =
            [
                // command.sb is diagnostic only. The fresh runner consumes these
                // immutable argument bytes, never a child-writable policy file.
                "--runner-child", profile, executable.invocationPath,
            ] + normalizedArguments
        process.currentDirectoryURL = workingDirectory
        let accountHome = FileManager.default.homeDirectoryForCurrentUser
        let commandPath = [
            accountHome.appendingPathComponent(".local/bin").path,
            accountHome.appendingPathComponent(".cargo/bin").path,
            accountHome.appendingPathComponent(".bun/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Library/Developer/CommandLineTools/usr/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        var environment = [
            "HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "XDG_CACHE_HOME": cache.path,
            "PATH": commandPath,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if readOnlyGit { environment["GIT_NO_LAZY_FETCH"] = "1" }
        if let networkProxy { environment.merge(networkProxy.environment) { _, grant in grant } }
        if executableID == "swift" {
            environment.merge(
                [
                    "CLANG_MODULE_CACHE_PATH": cache.appendingPathComponent("clang").path,
                    "DEVELOPER_DIR": swiftInstallation.developer,
                    "SDKROOT": swiftInstallation.sdk,
                    "SWIFT_EXEC": swiftInstallation.swiftc,
                    "SWIFTPM_MODULECACHE_OVERRIDE":
                        cache
                        .appendingPathComponent("swiftpm").path,
                    "SWIFT_MODULE_CACHE_PATH": cache.appendingPathComponent("swift").path,
                    "xcrun_nocache": "1",
                ],
                uniquingKeysWith: { _, fixed in fixed }
            )
        }
        process.environment = environment
        let running = RunningCommand(
            taskID: taskID,
            activityContext: ActivityDetail.context(ActivityDetail.metadata(name: "command_start", arguments: [
                "executable": executableID, "arguments": arguments, "cwd": cwd,
            ])),
            process: process,
            runtimeURL: runtime,
            maximumOutputBytes: maximumOutputBytes,
            networkProxy: networkProxy,
            networkGrant: networkGrant
        )
        if let grantDeadline, DispatchTime.now() >= grantDeadline {
            throw LocalMCPError.operationFailed("network grant expired before process launch")
        }
        do {
            try running.start()
        } catch {
            throw LocalMCPError.operationFailed("process launch failed")
        }
        lock.lock()
        startingProcesses -= 1
        processes[taskID] = running
        if pinSynchronousResponse { synchronousResponsePins.insert(taskID) }
        lock.unlock()
        slotReserved = false
        runtimeOwned = false
        proxyTransferred = true
        if let grantDeadline {
            // One deadline per opted-in job; no polling, persistence or timer
            // when ordinary loopback-only commands are used.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: grantDeadline) { [weak running] in
                if let running, running.snapshot().running { running.expireNetworkGrant() }
            }
        }
        return running
    }

    private func reserveProcessSlot(outputBytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard processes.count + startingProcesses < Self.maximumTrackedProcesses else {
            throw LocalMCPError.limitExceeded(
                "tracked process count; drain output or cancel a process"
            )
        }
        guard outputBytes <= outputByteLimit - reservedOutputBytes else {
            throw LocalMCPError.limitExceeded(
                "aggregate process output budget; drain completed output or cancel a process, or request smaller output capacity"
            )
        }
        startingProcesses += 1
        reservedOutputBytes += outputBytes
    }

    private func releaseProcessSlot(outputBytes: Int) {
        lock.lock()
        startingProcesses -= 1
        reservedOutputBytes -= outputBytes
        lock.unlock()
    }

    private func process(_ rawID: String) throws -> RunningCommand {
        guard let uuid = UUID(uuidString: rawID) else {
            throw LocalMCPError.invalidRequest("task_id must be a UUID")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let value = processes[uuid.uuidString.lowercased()] else {
            throw LocalMCPError.processNotFound
        }
        return value
    }

    @discardableResult
    private func forget(_ command: RunningCommand, releaseSynchronousResponse: Bool = false) -> Bool {
        let snapshot = command.snapshot()
        lock.lock()
        defer { lock.unlock() }
        if releaseSynchronousResponse { synchronousResponsePins.remove(command.taskID) }
        guard !synchronousResponsePins.contains(command.taskID) else { return false }
        if processes[command.taskID] === command {
            processes.removeValue(forKey: command.taskID)
            reservedOutputBytes -= command.maximumOutputBytes * 2
            pruneCompletedStatusesWhileLocked()
            if !snapshot.running, completedStatusLimit > 0, completedStatusTTL > 0 {
                var metadata = snapshotJSON(snapshot, includeOutput: false)
                metadata["session_retained"] = false
                metadata["status_only"] = true
                // Retain no output, raw arguments, stdin, pipes or process objects.
                // Only the already-bounded, sanitized command/folder display label survives.
                completedStatuses[command.taskID] = (monotonicNow() + completedStatusTTL, metadata, command.activityContext)
                completedOrder.append(command.taskID)
                while completedOrder.count > completedStatusLimit {
                    completedStatuses.removeValue(forKey: completedOrder.removeFirst())
                }
            }
        }
        return true // Removed here or already absent; false means retained by the pin.
    }

    private func pruneCompletedStatusesWhileLocked() {
        let now = monotonicNow()
        completedOrder.removeAll { id in
            guard let entry = completedStatuses[id], entry.expires > now else {
                completedStatuses.removeValue(forKey: id)
                return true
            }
            return false
        }
    }

    private func isUTF8Boundary(_ data: Data, at offset: Int) -> Bool {
        offset == 0 || offset == data.count || data[offset] & 0xC0 != 0x80
    }

    private func textChunkEnd(_ data: Data, from offset: Int, maximumBytes: Int) -> Int {
        var end = min(data.count, offset + maximumBytes)
        var continuationBytes = 0
        while end < data.count, data[end] & 0xC0 == 0x80, continuationBytes < 3 {
            end += 1
            continuationBytes += 1
        }
        return end
    }

    private var executablePaths: [String: String] {
        [
            "zsh": "/bin/zsh",
            "bash": "/bin/bash",
            "sh": "/bin/sh",
            "swift": swiftInstallation.swift,
            "git": "/Library/Developer/CommandLineTools/usr/bin/git",
            "xcodebuild": "/usr/bin/xcodebuild",
            "make": "/usr/bin/make",
            "python3": "/Library/Developer/CommandLineTools/usr/bin/python3",
            "true": "/usr/bin/true",
            "cat": "/bin/cat",
            "printenv": "/usr/bin/printenv",
            "sleep": "/bin/sleep",
            "touch": "/usr/bin/touch",
        ]
    }

    private func allowedExecutable(_ id: String) throws -> AllowedExecutable {
        guard let path = executablePaths[id] else { throw LocalMCPError.unsupportedCommand }
        guard isTrustedSystemExecutable(path) else { throw LocalMCPError.unsupportedCommand }
        return AllowedExecutable(id: id, invocationPath: path)
    }

    private func normalizeArguments(executableID: String, arguments: [String]) throws -> [String] {
        guard executableID == "swift", let operation = arguments.first?.lowercased(),
            ["build", "package", "test"].contains(operation)
        else { return arguments }
        let blockedPrefixes = [
            "--cache-path", "--config-path", "--security-path", "--scratch-path",
            "--netrc", "--netrc-file", "--enable-keychain", "--disable-keychain",
            "--enable-netrc", "--disable-netrc", "--enable-prefetching",
            "--disable-prefetching", "--enable-dependency-cache",
            "--disable-dependency-cache", "--enable-experimental-prebuilts",
            "--disable-experimental-prebuilts", "--disable-automatic-resolution",
            "--force-resolved-versions", "--only-use-versions-from-resolved-file",
            "--manifest-cache", "--skip-update",
            "--package-path", "--sdk", "--toolchain", "--swift-sdk", "-Xswiftc",
            "-Xlinker", "-Xcc", "-Xcxx",
        ]
        guard
            arguments.dropFirst().allSatisfy({ argument in
                !blockedPrefixes.contains(where: {
                    argument == $0 || argument.hasPrefix("\($0)=")
                })
            })
        else { throw LocalMCPError.invalidRequest("conflicting SwiftPM option") }
        var result =
            arguments + [
                "--disable-sandbox",
                "--disable-keychain",
                "--disable-netrc",
                "--cache-path", ".build/.macbridge-swiftpm/cache",
                "--config-path", ".build/.macbridge-swiftpm/config",
                "--security-path", ".build/.macbridge-swiftpm/security",
                "--scratch-path", ".build",
                "--disable-dependency-cache",
                "--manifest-cache", "local",
                "--disable-prefetching",
                "--disable-experimental-prebuilts",
                "--disable-automatic-resolution",
                "--sdk", swiftInstallation.sdk,
            ]
        // Full Xcode supplies its own XCTest/Testing discovery and link flags.
        // Keep the existing CLT-only Swift Testing compatibility flags there;
        // do not override an Xcode project's deployment target or test runners.
        if operation == "test", swiftInstallation.developer == SwiftInstallation.commandLineTools.developer {
            #if arch(arm64)
                let target = "arm64-apple-macosx14.0"
            #else
                let target = "x86_64-apple-macosx14.0"
            #endif
            let frameworks = swiftInstallation.frameworks
            let testing = swiftInstallation.testingLibraries
            result += [
                "--enable-swift-testing",
                "-Xswiftc", "-target", "-Xswiftc", target,
                "-Xswiftc", "-F", "-Xswiftc", frameworks,
                "-Xlinker", "-F\(frameworks)",
                "-Xlinker", "-rpath", "-Xlinker", frameworks,
                "-Xlinker", "-rpath", "-Xlinker", testing,
            ]
        }
        return result
    }

    private func sandboxProfile(
        workspace: URL,
        runtime: URL,
        executable: String,
        readOnlyGit: Bool = false,
        networkProxyPort: UInt16? = nil
    ) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = [workspace.path, runtime.path, executable, home.path]
        guard values.allSatisfy({ !$0.contains("\n") && !$0.contains("\0") }) else {
            throw LocalMCPError.invalidPath("sandbox path")
        }
        func quote(_ value: String) -> String {
            "\""
                + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let stage = quote(workspace.path)
        let run = quote(runtime.path)
        let homePath = quote(home.path)
        let executablePath = quote(executable)
        let runtimeState = quote(runtime.deletingLastPathComponent().deletingLastPathComponent().path)
        let writableRuntime = ["home", "tmp", "cache"].map {
            "(subpath \(quote(runtime.appendingPathComponent($0).path)))"
        }.joined(separator: " ")
        let localBin = quote(home.appendingPathComponent(".local/bin").path)
        let cargoBin = quote(home.appendingPathComponent(".cargo/bin").path)
        let bunBin = quote(home.appendingPathComponent(".bun/bin").path)
        let swiftTemporaryRules: String
        if executable == swiftInstallation.swift {
            let systemTemporary = try canonicalExistingPath(
                FileManager.default.temporaryDirectory.path
            )
            guard systemTemporary.hasPrefix("/private/var/folders/"),
                systemTemporary.hasSuffix("/T"),
                systemTemporary.allSatisfy({
                    $0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-"
                })
            else {
                throw LocalMCPError.operationFailed(
                    "the private macOS temporary directory could not be validated"
                )
            }
            // SwiftPM uses Foundation's item-replacement API for output maps.
            // On macOS that API ignores TMPDIR and creates an NSIRD directory
            // below the per-user system temporary directory. Admit only those
            // Swift build/test replacement paths, not the surrounding temp tree.
            let replacementRegex =
                "^\(systemTemporary)/TemporaryItems/NSIRD_swift-(build|test|driver)_[A-Za-z0-9]+(/.*)?$"
            // xcrun opens its tool-location cache read/write and atomically
            // replaces it. Denying only the write made every lookup invoke
            // xcodebuild again. This admits its exact cache filenames only.
            let xcrunCacheRegex = "^\(systemTemporary)/xcrun_db(-[A-Za-z0-9]+)?$"
            swiftTemporaryRules = """
                ; xcrun checks the existing system-wide Xcode license receipt.
                ; Read only: never accept a license or change any preferences.
                (allow file-read-data
                    (literal "/Library/Preferences/com.apple.dt.Xcode.plist"))
                (allow file-read* file-test-existence
                    (regex #"\(replacementRegex)" #"\(xcrunCacheRegex)"))
                (allow file-write*
                    (regex #"\(replacementRegex)" #"\(xcrunCacheRegex)"))
                """
        } else {
            swiftTemporaryRules = ""
        }
        let processRules = readOnlyGit ? """
            (deny process-fork)
            (deny process-exec)
            (allow process-exec (literal \(executablePath)))
            """ : """
            (allow process-fork)
            (allow process-exec
                (literal \(executablePath))
                (subpath \(stage))
                (subpath "/Applications/Xcode.app")
                (subpath "/Library/Developer")
                (subpath "/opt/homebrew")
                (subpath "/usr/local")
                (subpath \(localBin))
                (subpath \(cargoBin))
                (subpath \(bunBin))
                (subpath "/usr/bin")
                (subpath "/usr/libexec")
                (subpath "/bin"))
            (deny process-exec
                (literal "/bin/launchctl")
                \(networkProxyPort == nil ? "(literal \"/usr/bin/curl\")" : "")
                (literal "/usr/bin/nc")
                (literal "/usr/bin/open")
                (literal "/usr/bin/osascript")
                (literal "/usr/bin/scp")
                (literal "/usr/bin/security")
                (literal "/usr/bin/ssh")
                (literal "/usr/bin/sudo"))
            """
        let workspaceWrites = readOnlyGit ? "" : "(allow file-write* (subpath \(stage)))"
        let networkRules = readOnlyGit ? "(deny network*)" : networkProxyPort.map { LocalNetworkGrant.sandboxRule(proxyPort: $0) } ?? """
            (allow network-inbound (local ip "localhost:*"))
            (allow network-outbound (remote ip "localhost:*"))
            """
        return """
            (version 1)
            (deny default)
            (import "system.sb")
            (allow signal (target same-sandbox))
            (allow process-info* (target same-sandbox))
            \(processRules)
            (allow file-read-metadata (subpath "/"))
            (allow file-read* file-test-existence file-map-executable
                (subpath \(stage))
                (subpath \(run))
                (subpath "/Applications/Xcode.app")
                (subpath "/Library/Apple")
                (subpath "/Library/Developer")
                (subpath "/opt/homebrew")
                (subpath "/usr/local")
                (subpath "/System")
                (subpath "/usr")
                (subpath "/bin")
                (subpath "/sbin")
                (subpath "/private/etc")
                (subpath "/private/var/db/timezone")
                (subpath "/dev"))
            (deny file-read* (subpath \(homePath)))
            (allow file-read* file-test-existence file-map-executable
                (subpath \(stage))
                (subpath \(run))
                (subpath \(localBin))
                (subpath \(cargoBin))
                (subpath \(bunBin)))
            (deny file-write*)
            \(workspaceWrites)
            ; Owner control/recovery state is not workspace command output.
            (deny file-write*
                (subpath \(runtimeState))
                (regex #"(^|/)[.][mM][aA][cC][bB][rR][iI][dD][gG][eE](/|$|-[cC][oO][pP][yY]-|-[wW][rR][iI][tT][eE]-)"))
            (allow file-write* \(writableRuntime) (literal "/dev/null"))
            \(swiftTemporaryRules)
            \(LocalFilesystemAccess.sandboxDenyRules())
            \(networkRules)
            (deny appleevent-send)
            (deny mach-register)
            (deny mach-lookup
                (global-name "com.apple.SecurityServer")
                (global-name "com.apple.security.agent")
                (global-name "com.apple.securityd")
                (global-name "com.apple.securityd.xpc")
                (global-name "com.apple.backgroundtaskmanagement.agent")
                (global-name "com.apple.coreservices.launchservicesd")
                (global-name "com.apple.sharedfilelistd"))
            """
    }

    private func snapshotJSON(_ snapshot: ProcessSnapshot, includeOutput: Bool) -> JSONObject {
        var value: JSONObject = [
            "task_id": snapshot.taskID,
            "running": snapshot.running,
            "timed_out": snapshot.timedOut,
            "cancelled": snapshot.cancelled,
            "started_milliseconds": snapshot.startedMilliseconds,
            "stdout_truncated": snapshot.stdoutTruncated,
            "stderr_truncated": snapshot.stderrTruncated,
            "stdout_retained_from_cursor": snapshot.stdoutBaseOffset,
            "stderr_retained_from_cursor": snapshot.stderrBaseOffset,
            "stdout_total_bytes": snapshot.stdoutTotalBytes,
            "stderr_total_bytes": snapshot.stderrTotalBytes,
            "stdout_dropped_bytes": snapshot.stdoutBaseOffset,
            "stderr_dropped_bytes": snapshot.stderrBaseOffset,
            "terminal_window_opened": false,
            "network": snapshot.networkGrant == nil ? "loopback_only" : "pinned_destination_via_job_local_proxy",
            "backend_called": true,
            "process_started": true,
            "execution_backend": "direct_process",
            "xpc_dispatched": false,
        ]
        if let grant = snapshot.networkGrant {
            value["network_grant_id"] = grant.id
            value["network_scope"] = "one_owner_pinned_ipv4_tcp_port_not_hostname_filtering"
            value["network_expires_at"] = ISO8601DateFormatter().string(from: grant.expiresAt)
            value["direct_network"] = "job_proxy_loopback_port_only"
        }
        if let code = snapshot.exitCode { value["exit_code"] = Int(code) }
        if let reason = snapshot.terminationReason { value["termination_reason"] = reason }
        if let ended = snapshot.endedMilliseconds { value["ended_milliseconds"] = ended }
        if includeOutput {
            value["stdout"] = String(decoding: snapshot.stdout, as: UTF8.self)
            value["stderr"] = String(decoding: snapshot.stderr, as: UTF8.self)
        }
        return value
    }

    private func cleanupRuntime(_ runtime: URL) {
        cleanupRuntimePathOnce(runtime)
    }

    private func writeNewRuntimeProfile(_ data: Data, to url: URL) throws {
        // This path is inside a fresh private UUID directory and is not published
        // to a child until writing succeeds. Foundation's atomic-write staging may
        // leave that directory for the account's OS temp root inside a nested job.
        // Exclusive local creation needs no extra temp-folder/sandbox permission.
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw LocalMCPError.operationFailed("could not write private command profile") }
            }
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR,
                status.st_uid == getuid(),
                status.st_mode & 0o022 == 0
            else {
                throw LocalMCPError.operationFailed(
                    "runtime directory is not a private current-user directory"
                )
            }
            return
        }
        guard errno == ENOENT else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        guard mkdir(url.path, 0o700) == 0 else {
            throw LocalMCPError.operationFailed(String(cString: strerror(errno)))
        }
        guard lstat(url.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == getuid(),
            status.st_mode & 0o077 == 0
        else {
            throw LocalMCPError.operationFailed("runtime directory verification failed")
        }
    }
}

public enum LocalRunnerChild {
    public static func execute(arguments: [String]) -> Never {
        guard arguments.count >= 2 else { Darwin._exit(64) }
        let profile = arguments[0]
        let executable = arguments[1]
        let commandArguments = Array(arguments.dropFirst(2))
        _ = umask(0o077)
        guard setpgid(0, 0) == 0 else { Darwin._exit(70) }
        let values = ["/usr/bin/sandbox-exec", "-p", profile, executable] + commandArguments
        var pointers: [UnsafeMutablePointer<CChar>] = []
        for value in values {
            guard let pointer = strdup(value) else { Darwin._exit(71) }
            pointers.append(pointer)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = pointers.map { Optional($0) }
        argv.append(nil)
        defer {
            for pointer in pointers {
                free(UnsafeMutableRawPointer(pointer))
            }
        }
        _ = argv.withUnsafeMutableBufferPointer { buffer in
            execv("/usr/bin/sandbox-exec", buffer.baseAddress!)
        }
        Darwin._exit(127)
    }
}
