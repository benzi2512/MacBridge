import Foundation

/// Small in-memory activity grouping, never an authorization or ChatGPT identity.
/// No timer, inferred current chat, filesystem state, or background worker.
final class WorkActivity: @unchecked Sendable {
    static let maximumItems = 32
    static let maximumJobsPerItem = 128
    static let staleMilliseconds: Int64 = 120_000
    private struct SchedulerContext {
        let scheduleID: String
        let runID: String
        let scheduledFor: String
        let firedAt: String
        let attempt: Int
        let nativeTaskID: String?
        let nativeRunID: String?
        let invocationKind: String?
        let parentTaskID: String?
        var phase: String = "fired"
        var artifactPath: String?
        var artifactSHA256: String?
        var writeTransactionID: String?
        var persistedAt: String?
        var acknowledgementID: String?
    }
    private struct Item {
        let id: String
        var title: String
        var chatLabel: String?
        let workspaceID: String?
        var state = "active"
        let started: Int64
        var updated: Int64
        var calls = 0
        var errors = 0
        var childErrors = 0
        var activeCalls = 0
        var jobs: [String] = []
        var failureReports: [JSONObject] = []
        var failureReportCount = 0
        // Deduplicate observed exits only while their job mapping is retained.
        // The cumulative error count survives eviction; this set stays bounded.
        var failedJobs: Set<String> = []
        var scheduler: SchedulerContext?
    }
    private let lock = NSLock()
    private var items: [Item] = []
    private var jobOwners: [String: String] = [:]
    private var runningJobs: Set<String> = []
    private var terminalJobs: Set<String> = []

    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func index(_ id: String) throws -> Int {
        guard UUID(uuidString: id) != nil, let index = items.firstIndex(where: { $0.id == id.lowercased() }) else {
            throw LocalMCPError.invalidRequest("work_id is not a retained work item in this runtime")
        }
        return index
    }

    func manage(_ arguments: JSONObject, validWorkspaces: Set<String>, jobs: [JSONObject],
                now: Int64 = WorkActivity.now,
                persistenceVerified: Bool = false) throws -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        refreshJobs(jobs, now: now)
        let action = try arguments.requiredString("action", maximumBytes: 16)
        if action == "list" {
            try arguments.requireOnlyKeys(["action", "workspace_id"])
            let workspace = try arguments.optionalString("workspace_id", maximumBytes: 36)?.lowercased()
            if let workspace, !validWorkspaces.contains(workspace) {
                throw LocalMCPError.invalidRequest("workspace_id is not registered; work labels do not grant access")
            }
            let selected = snapshots(now: now).filter { workspace == nil || $0["workspace_id"] as? String == workspace }
            return ["work_items": selected, "chat_labels_authenticated": false]
        }
        if action == "begin" {
            try arguments.requireOnlyKeys(["action", "title", "chat_label", "workspace_id", "scheduler_context"])
            let title = try label(arguments, "title", required: true)!
            let chat = try label(arguments, "chat_label", required: false)
            let workspace = try arguments.optionalString("workspace_id", maximumBytes: 36)?.lowercased()
            if let workspace, !validWorkspaces.contains(workspace) {
                throw LocalMCPError.invalidRequest("workspace_id is not registered; work labels do not grant access")
            }
            let id = UUID().uuidString.lowercased()
            var scheduler: SchedulerContext?
            if let raw = arguments["scheduler_context"] {
                guard let value = raw as? JSONObject else {
                    throw LocalMCPError.invalidRequest("scheduler_context must be an object")
                }
                try value.requireOnlyKeys([
                    "schedule_id", "run_id", "scheduled_for", "fired_at", "attempt",
                    "native_task_id", "native_run_id", "invocation_kind", "parent_task_id",
                ])
                let scheduledFor = try value.requiredString("scheduled_for", maximumBytes: 64)
                let firedAt = try value.requiredString("fired_at", maximumBytes: 64)
                guard ISO8601DateFormatter().date(from: scheduledFor) != nil,
                      ISO8601DateFormatter().date(from: firedAt) != nil else {
                    throw LocalMCPError.invalidRequest("scheduled_for and fired_at must be ISO-8601 timestamps")
                }
                let invocationKind = try value.optionalString("invocation_kind", maximumBytes: 32)
                if let invocationKind, !["scheduled", "manual", "retry"].contains(invocationKind) {
                    throw LocalMCPError.invalidRequest("invocation_kind must be scheduled, manual or retry")
                }
                scheduler = SchedulerContext(
                    scheduleID: try value.requiredString("schedule_id", maximumBytes: 128),
                    runID: try value.requiredString("run_id", maximumBytes: 128),
                    scheduledFor: scheduledFor, firedAt: firedAt,
                    attempt: try value.optionalInt("attempt", default: 1, range: 1...1000),
                    nativeTaskID: try value.optionalString("native_task_id", maximumBytes: 128),
                    nativeRunID: try value.optionalString("native_run_id", maximumBytes: 128),
                    invocationKind: invocationKind,
                    parentTaskID: try value.optionalString("parent_task_id", maximumBytes: 128)
                )
                guard workspace != nil else {
                    throw LocalMCPError.invalidRequest(
                        "scheduled work requires workspace_id so persisted artifact evidence can be verified"
                    )
                }
            }
            if items.count == Self.maximumItems {
                guard let old = items.firstIndex(where: {
                    ["completed", "failed"].contains($0.state) && $0.activeCalls == 0
                        && !$0.jobs.contains(where: { runningJobs.contains($0) })
                }) else {
                    throw LocalMCPError.limitExceeded("32 work items are retained; finish an existing task before beginning another")
                }
                let removed = items.remove(at: old)
                for job in removed.jobs {
                    jobOwners.removeValue(forKey: job)
                    runningJobs.remove(job)
                    terminalJobs.remove(job)
                }
            }
            var item = Item(id: id, title: title, chatLabel: chat, workspaceID: workspace,
                            started: now, updated: now)
            item.scheduler = scheduler
            items.append(item)
            return snapshot(items.last!, now: now)
        }
        guard action == "update" || action == "finish" else {
            throw LocalMCPError.invalidRequest("work_task action must be begin, update, finish or list")
        }
        try arguments.requireOnlyKeys(action == "update"
            ? ["action", "work_id", "title", "chat_label", "status", "workspace_id",
               "scheduler_phase", "artifact_path", "artifact_sha256", "write_transaction_id",
               "persisted_at", "acknowledgement_id"]
            : ["action", "work_id", "status", "workspace_id", "scheduler_phase",
               "artifact_path", "artifact_sha256", "write_transaction_id",
               "persisted_at", "acknowledgement_id"])
        let i = try index(arguments.requiredString("work_id", maximumBytes: 36))
        // A client may repeat the workspace from begin. It is an assertion,
        // never a request to move the parent or widen its immutable scope.
        if let workspace = try arguments.optionalString("workspace_id", maximumBytes: 36)?.lowercased(),
           workspace != items[i].workspaceID {
            throw LocalMCPError.conflict("workspace_id does not match the work item's original workspace; no change performed")
        }
        guard ["active", "waiting_user"].contains(items[i].state) else {
            throw LocalMCPError.conflict("work item is finished; begin a new work item instead")
        }
        let state = try arguments.optionalString("status", maximumBytes: 20) ?? (action == "finish" ? "completed" : items[i].state)
        guard (action == "finish" ? ["completed", "failed"] : ["active", "waiting_user"]).contains(state) else {
            throw LocalMCPError.invalidRequest("unsupported work item state for this action")
        }
        if action == "finish" || state == "waiting_user" {
            guard items[i].activeCalls == 0, !items[i].jobs.contains(where: { runningJobs.contains($0) }) else {
                throw LocalMCPError.conflict("work item has active calls or running jobs; no state change performed")
            }
        }
        let title = try label(arguments, "title", required: false)
        let chat = try label(arguments, "chat_label", required: false)
        var candidate = items[i]
        if let title { candidate.title = title }
        if let chat { candidate.chatLabel = chat }
        try updateScheduler(
            item: &candidate, arguments: arguments, persistenceVerified: persistenceVerified
        )
        if action == "finish", state == "completed", let scheduler = candidate.scheduler,
           scheduler.phase != "acknowledged" {
            throw LocalMCPError.conflict("scheduled work must persist and acknowledge its artifact before completion")
        }
        candidate.state = state
        candidate.updated = now
        items[i] = candidate
        return snapshot(items[i], now: now)
    }

    private func updateScheduler(
        item: inout Item, arguments: JSONObject, persistenceVerified: Bool
    ) throws {
        let supplied = ["scheduler_phase", "artifact_path", "artifact_sha256",
                        "write_transaction_id", "persisted_at", "acknowledgement_id"]
            .contains { arguments[$0] != nil }
        guard supplied else { return }
        guard var scheduler = item.scheduler else {
            throw LocalMCPError.invalidRequest("scheduler lifecycle fields require scheduler_context from begin")
        }
        let phases = ["fired", "worker_started", "result_ready", "persisted", "acknowledged"]
        let next = try arguments.requiredString("scheduler_phase", maximumBytes: 32)
        guard let oldRank = phases.firstIndex(of: scheduler.phase),
              let newRank = phases.firstIndex(of: next), newRank >= oldRank,
              newRank <= oldRank + 1 else {
            throw LocalMCPError.conflict("scheduler lifecycle must advance one phase without regression")
        }
        if next == "result_ready" {
            scheduler.artifactPath = try arguments.requiredString("artifact_path", maximumBytes: 4_096)
            let hash = try arguments.requiredString("artifact_sha256", maximumBytes: 64).lowercased()
            guard LocalHash.isSHA256(hash) else { throw LocalMCPError.invalidRequest("artifact_sha256 must be SHA-256") }
            scheduler.artifactSHA256 = hash
        } else if next == "persisted" {
            guard scheduler.artifactSHA256 != nil, scheduler.artifactPath != nil else {
                throw LocalMCPError.conflict("result_ready artifact path and hash are missing")
            }
            let path = try arguments.requiredString("artifact_path", maximumBytes: 4_096)
            let hash = try arguments.requiredString("artifact_sha256", maximumBytes: 64).lowercased()
            guard path == scheduler.artifactPath, hash == scheduler.artifactSHA256 else {
                throw LocalMCPError.conflict("persisted evidence does not match result_ready artifact")
            }
            guard persistenceVerified else {
                throw LocalMCPError.conflict("persisted phase requires a retained work-owned write transaction matching the current artifact")
            }
            scheduler.writeTransactionID = try arguments.requiredString(
                "write_transaction_id", maximumBytes: 36
            ).lowercased()
            let timestamp = try arguments.requiredString("persisted_at", maximumBytes: 64)
            guard ISO8601DateFormatter().date(from: timestamp) != nil else {
                throw LocalMCPError.invalidRequest("persisted_at must be ISO-8601")
            }
            scheduler.persistedAt = timestamp
        } else if next == "acknowledged" {
            guard scheduler.persistedAt != nil else { throw LocalMCPError.conflict("persisted receipt is missing") }
            scheduler.acknowledgementID = try arguments.requiredString("acknowledgement_id", maximumBytes: 128)
        }
        scheduler.phase = next
        item.scheduler = scheduler
    }

    private func label(_ arguments: JSONObject, _ key: String, required: Bool) throws -> String? {
        let value = try arguments.optionalString(key, maximumBytes: 640)
        guard let value else {
            if required { throw LocalMCPError.invalidRequest("\(key) is required") }
            return nil
        }
        guard value.count <= 160, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
              }) else {
            throw LocalMCPError.invalidRequest("\(key) must contain 1-160 printable characters")
        }
        return value
    }

    /// Reserve activity before launching or admitting any long operation. The
    /// optional label does not supply workspace, OS permissions or job ownership.
    func beginCall(name: String, arguments: JSONObject, now: Int64 = WorkActivity.now) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let explicit = try arguments.optionalString("work_id", maximumBytes: 36)?.lowercased()
        var inherited: String?
        if name.hasPrefix("process_") {
            var jobs = arguments["task_ids"] as? [String] ?? []
            jobs += (arguments["jobs"] as? [JSONObject] ?? []).compactMap { $0["task_id"] as? String }
            if let job = arguments["task_id"] as? String { jobs.append(job) }
            let owners = jobs.map { jobOwners[$0.lowercased()] }
            if let first = owners.first ?? nil, owners.allSatisfy({ $0 == first }) { inherited = first }
            if let explicit, !jobs.isEmpty, owners.contains(where: { $0 != explicit }) {
                throw LocalMCPError.conflict("work_id cannot change or claim a process's originating work item")
            }
        }
        let id = explicit ?? inherited
        guard let id else { return nil }
        let i = try index(id)
        guard items[i].state == "active" || (name.hasPrefix("process_") && inherited == id) else {
            throw LocalMCPError.conflict("work item is not active; update waiting_user to active or begin a new work item")
        }
        if let scope = items[i].workspaceID,
           let requested = arguments["workspace_id"] as? String, requested.lowercased() != scope {
            throw LocalMCPError.conflict("work item workspace differs from the requested operation")
        }
        if name == "command_start" || name == "command_run" {
            if items[i].jobs.count >= Self.maximumJobsPerItem,
               !items[i].jobs.contains(where: { !runningJobs.contains($0) }) {
                throw LocalMCPError.limitExceeded("work item job retention is full; no command started")
            }
        }
        items[i].calls += 1
        items[i].activeCalls += 1
        items[i].updated = now
        return id
    }

    func finishCall(_ id: String?, name: String, result: JSONObject, failed: Bool,
                    now: Int64 = WorkActivity.now) {
        lock.lock(); defer { lock.unlock() }
        let batch = name == "process_status_many" || name == "process_output_many"
            ? result["results"] as? [JSONObject] ?? [] : []
        if !failed {
            // Batch process tools return one wrapper per request, with the real
            // status inside result. Missing/error rows are unknown, not stopped.
            // Mixed-owner legacy batches may have no parent call ID; update only
            // already-mapped jobs and never attach or reassign their ownership.
            for row in batch where row["status"] as? String == "ok" {
                guard let job = row["result"] as? JSONObject,
                      let outerID = row["task_id"] as? String,
                      let innerID = job["task_id"] as? String,
                      outerID.lowercased() == innerID.lowercased() else { continue }
                reconcileRunningJob(job, ownerID: id, now: now)
            }
            if name == "process_list", let jobs = result["processes"] as? [JSONObject] { refreshJobs(jobs, now: now) }
        }
        if let id, let i = try? index(id) {
            items[i].activeCalls = max(0, items[i].activeCalls - 1)
            items[i].updated = now
            // Failed calls/partial calls are separate from child exit outcomes.
            // A successful read of an old failed job is not another failed call.
            let batchFailed = batch.contains { $0["status"] as? String == "error" }
            let recordedFailure = failed || batchFailed || (result["error_count"] as? Int ?? 0) > 0
            if recordedFailure {
                items[i].errors += 1
                appendFailureReport(
                    index: i, tool: name, result: result,
                    status: failed ? "failed" : "partial", now: now
                )
            }
            if let count = result["child_error_count"] as? Int, count > 0 {
                items[i].childErrors += count
            }
            if !name.hasPrefix("process_"), let job = result["task_id"] as? String {
                linkJobLocked(job.lowercased(), workID: id, index: i)
            }
        }
        if !failed { reconcileRunningJob(result, ownerID: id, now: now) }
    }

    private func reconcileRunningJob(_ result: JSONObject, ownerID: String?, now: Int64) {
        guard let rawID = result["task_id"] as? String, UUID(uuidString: rawID) != nil,
              let owner = jobOwners[rawID.lowercased()], ownerID == nil || ownerID == owner,
              let running = result["running"] as? Bool else { return }
        let job = rawID.lowercased()
        if running, terminalJobs.contains(job) { return }
        let changed = runningJobs.contains(job) != running
        if running {
            runningJobs.insert(job)
        } else {
            runningJobs.remove(job)
            terminalJobs.insert(job)
        }
        if let i = try? index(owner) {
            let firstFailure = !running && (result["exit_code"] as? Int ?? 0) != 0
                && items[i].failedJobs.insert(job).inserted
            if firstFailure {
                items[i].errors += 1
                appendFailureReport(
                    index: i, tool: "child_process", result: result,
                    status: "failed", now: now
                )
            }
            if changed || firstFailure { items[i].updated = now }
        }
    }

    /// The dispatcher calls this immediately after launch, before releasing its
    /// operation lock, so pending command_run jobs already have their origin.
    func linkJob(_ job: JSONObject, workID: String?) {
        guard let workID, let jobID = job["task_id"] as? String else { return }
        lock.lock(); defer { lock.unlock() }
        guard let i = try? index(workID) else { return }
        linkJobLocked(jobID.lowercased(), workID: workID, index: i)
        if job["running"] as? Bool == true, !terminalJobs.contains(jobID.lowercased()) {
            runningJobs.insert(jobID.lowercased())
        }
    }

    private func linkJobLocked(_ job: String, workID: String, index i: Int) {
        guard jobOwners[job] == nil else { return }
        while items[i].jobs.count >= Self.maximumJobsPerItem {
            guard let old = items[i].jobs.firstIndex(where: { !runningJobs.contains($0) }) else { return }
            let removed = items[i].jobs.remove(at: old)
            jobOwners.removeValue(forKey: removed)
            terminalJobs.remove(removed)
            items[i].failedJobs.remove(removed)
        }
        jobOwners[job] = workID
        items[i].jobs.append(job)
    }

    func list(jobs: [JSONObject]?, now: Int64 = WorkActivity.now) -> [JSONObject] {
        lock.lock(); defer { lock.unlock() }
        if let jobs { refreshJobs(jobs, now: now) }
        return snapshots(now: now)
    }

    func latestJobID(_ rawWorkID: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let i = try index(rawWorkID)
        guard let id = items[i].jobs.last else {
            throw LocalMCPError.conflict("developer task has no retained process")
        }
        return id
    }

    private func refreshJobs(_ jobs: [JSONObject], now: Int64) {
        runningJobs = Set(jobs.filter { $0["running"] as? Bool == true }.compactMap {
            let id = ($0["task_id"] as? String)?.lowercased()
            return id.flatMap { terminalJobs.contains($0) ? nil : $0 }
        })
        // A list/observer snapshot may be the only observation of an exit.
        // Missing rows carry no outcome; only mapped terminal results count.
        for job in jobs { reconcileRunningJob(job, ownerID: nil, now: now) }
    }

    private func snapshots(now: Int64) -> [JSONObject] { items.map { snapshot($0, now: now) } }

    private func appendFailureReport(
        index: Int, tool: String, result: JSONObject, status: String, now: Int64
    ) {
        var report: JSONObject = [
            "schema_version": 1,
            "status": status,
            "step": String(tool.prefix(128)),
            "recorded_ms": now,
            "retention": "owner_memory_bounded",
            "durable_after_restart": false,
        ]
        for key in ["error_count", "child_error_count", "child_partial_count",
                    "overall_status", "exit_code", "timed_out", "cancelled",
                    "mutation_performed", "complete", "partial"] where result[key] != nil {
            report[key] = result[key]
        }
        if let detail = result["error_detail"] as? JSONObject {
            let allowed = [
                "code", "layer", "retry_safe", "recommended_action",
                "operation_outcome", "stage", "relative_path", "os_error_domain",
                "os_error_code", "logical_size_bytes", "allocated_blocks",
                "file_flags_hex", "content_read_attempted", "process_launched",
            ]
            var safe: JSONObject = [:]
            for key in allowed where detail[key] != nil { safe[key] = detail[key] }
            if !safe.isEmpty { report["error_detail"] = safe }
        }
        if let children = result["child_results"] as? [JSONObject] {
            report["child_results"] = children.prefix(16).map { child -> JSONObject in
                var safe: JSONObject = [:]
                for key in ["step", "status", "exit_code", "timed_out", "cancelled",
                            "complete", "stdout_truncated", "stderr_truncated"]
                    where child[key] != nil { safe[key] = child[key] }
                return safe
            }
        }
        items[index].failureReportCount += 1
        items[index].failureReports.append(report)
        if items[index].failureReports.count > 8 {
            items[index].failureReports.removeFirst(items[index].failureReports.count - 8)
        }
    }

    private func snapshot(_ item: Item, now: Int64) -> JSONObject {
        let executing = item.activeCalls > 0 || item.jobs.contains(where: { runningJobs.contains($0) })
        let phase = item.state == "active" ? (executing ? "executing" : "waiting_next_step") : item.state
        var result: JSONObject = [
            "work_id": item.id, "title": item.title, "state": item.state, "phase": phase,
            "started_ms": item.started, "updated_ms": item.updated, "call_count": item.calls,
            "error_count": item.errors, "child_error_count": item.childErrors,
            "failure_report_count": item.failureReportCount,
            "failure_reports": item.failureReports,
            "active_call_count": item.activeCalls, "job_ids": item.jobs,
            "stale": item.state == "active" && !executing && now - item.updated >= Self.staleMilliseconds,
            "chat_label_authenticated": false,
        ]
        if let chat = item.chatLabel { result["chat_label"] = chat }
        if let workspace = item.workspaceID { result["workspace_id"] = workspace }
        if let scheduler = item.scheduler {
            var value: JSONObject = [
                "schedule_id": scheduler.scheduleID, "run_id": scheduler.runID,
                "scheduled_for": scheduler.scheduledFor, "fired_at": scheduler.firedAt,
                "attempt": scheduler.attempt, "phase": scheduler.phase,
            ]
            if let path = scheduler.artifactPath { value["artifact_path"] = path }
            if let hash = scheduler.artifactSHA256 { value["artifact_sha256"] = hash }
            if let transaction = scheduler.writeTransactionID { value["write_transaction_id"] = transaction }
            if let persisted = scheduler.persistedAt { value["persisted_at"] = persisted }
            if let acknowledgement = scheduler.acknowledgementID { value["acknowledgement_id"] = acknowledgement }
            if let nativeTask = scheduler.nativeTaskID { value["native_task_id"] = nativeTask }
            if let nativeRun = scheduler.nativeRunID { value["native_run_id"] = nativeRun }
            if let kind = scheduler.invocationKind { value["invocation_kind"] = kind }
            if let parent = scheduler.parentTaskID { value["parent_task_id"] = parent }
            result["scheduler"] = value
        }
        return result
    }
}
