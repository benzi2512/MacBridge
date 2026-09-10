import Foundation

/// Small in-memory activity grouping, never an authorization or ChatGPT identity.
/// No timer, inferred current chat, filesystem state, or background worker.
final class WorkActivity: @unchecked Sendable {
    static let maximumItems = 32
    static let maximumJobsPerItem = 128
    static let staleMilliseconds: Int64 = 120_000
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
        var activeCalls = 0
        var jobs: [String] = []
        // Deduplicate observed exits only while their job mapping is retained.
        // The cumulative error count survives eviction; this set stays bounded.
        var failedJobs: Set<String> = []
    }
    private let lock = NSLock()
    private var items: [Item] = []
    private var jobOwners: [String: String] = [:]
    private var runningJobs: Set<String> = []

    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func index(_ id: String) throws -> Int {
        guard UUID(uuidString: id) != nil, let index = items.firstIndex(where: { $0.id == id.lowercased() }) else {
            throw LocalMCPError.invalidRequest("work_id is not a retained work item in this runtime")
        }
        return index
    }

    func manage(_ arguments: JSONObject, validWorkspaces: Set<String>, jobs: [JSONObject],
                now: Int64 = WorkActivity.now) throws -> JSONObject {
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
            try arguments.requireOnlyKeys(["action", "title", "chat_label", "workspace_id"])
            let title = try label(arguments, "title", required: true)!
            let chat = try label(arguments, "chat_label", required: false)
            let workspace = try arguments.optionalString("workspace_id", maximumBytes: 36)?.lowercased()
            if let workspace, !validWorkspaces.contains(workspace) {
                throw LocalMCPError.invalidRequest("workspace_id is not registered; work labels do not grant access")
            }
            if items.count == Self.maximumItems {
                guard let old = items.firstIndex(where: {
                    ["completed", "failed"].contains($0.state) && $0.activeCalls == 0
                        && !$0.jobs.contains(where: { runningJobs.contains($0) })
                }) else {
                    throw LocalMCPError.limitExceeded("32 work items are retained; finish an existing task before beginning another")
                }
                let removed = items.remove(at: old)
                for job in removed.jobs { jobOwners.removeValue(forKey: job) }
            }
            let id = UUID().uuidString.lowercased()
            items.append(Item(id: id, title: title, chatLabel: chat, workspaceID: workspace,
                              started: now, updated: now))
            return snapshot(items.last!, now: now)
        }
        guard action == "update" || action == "finish" else {
            throw LocalMCPError.invalidRequest("work_task action must be begin, update, finish or list")
        }
        try arguments.requireOnlyKeys(action == "update"
            ? ["action", "work_id", "title", "chat_label", "status", "workspace_id"]
            : ["action", "work_id", "status", "workspace_id"])
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
        if let title { items[i].title = title }
        if let chat { items[i].chatLabel = chat }
        items[i].state = state
        items[i].updated = now
        return snapshot(items[i], now: now)
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
            while items[i].jobs.count >= Self.maximumJobsPerItem {
                guard let old = items[i].jobs.firstIndex(where: { !runningJobs.contains($0) }) else {
                    throw LocalMCPError.limitExceeded("work item job retention is full; no command started")
                }
                let removed = items[i].jobs.remove(at: old)
                jobOwners.removeValue(forKey: removed)
                items[i].failedJobs.remove(removed)
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
            if failed || batchFailed || (result["error_count"] as? Int ?? 0) > 0 {
                items[i].errors += 1
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
        let job = rawID.lowercased(), changed = runningJobs.contains(job) != running
        if running { runningJobs.insert(job) } else { runningJobs.remove(job) }
        if let i = try? index(owner) {
            let firstFailure = !running && (result["exit_code"] as? Int ?? 0) != 0
                && items[i].failedJobs.insert(job).inserted
            if firstFailure { items[i].errors += 1 }
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
        if job["running"] as? Bool == true { runningJobs.insert(jobID.lowercased()) }
    }

    private func linkJobLocked(_ job: String, workID: String, index i: Int) {
        guard jobOwners[job] == nil else { return }
        while items[i].jobs.count >= Self.maximumJobsPerItem {
            guard let old = items[i].jobs.firstIndex(where: { !runningJobs.contains($0) }) else { return }
            let removed = items[i].jobs.remove(at: old)
            jobOwners.removeValue(forKey: removed)
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
        runningJobs = Set(jobs.filter { $0["running"] as? Bool == true }.compactMap { ($0["task_id"] as? String)?.lowercased() })
        // A list/observer snapshot may be the only observation of an exit.
        // Missing rows carry no outcome; only mapped terminal results count.
        for job in jobs { reconcileRunningJob(job, ownerID: nil, now: now) }
    }

    private func snapshots(now: Int64) -> [JSONObject] { items.map { snapshot($0, now: now) } }

    private func snapshot(_ item: Item, now: Int64) -> JSONObject {
        let executing = item.activeCalls > 0 || item.jobs.contains(where: { runningJobs.contains($0) })
        let phase = item.state == "active" ? (executing ? "executing" : "waiting_next_step") : item.state
        var result: JSONObject = [
            "work_id": item.id, "title": item.title, "state": item.state, "phase": phase,
            "started_ms": item.started, "updated_ms": item.updated, "call_count": item.calls,
            "error_count": item.errors, "active_call_count": item.activeCalls, "job_ids": item.jobs,
            "stale": item.state == "active" && !executing && now - item.updated >= Self.staleMilliseconds,
            "chat_label_authenticated": false,
        ]
        if let chat = item.chatLabel { result["chat_label"] = chat }
        if let workspace = item.workspaceID { result["workspace_id"] = workspace }
        return result
    }
}
