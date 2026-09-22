import Foundation

/// One compact, deterministic gateway over existing MacBridge capabilities.
/// ChatGPT remains the reasoning layer; this code only bundles common repo work,
/// creates one retained parent, and advances one bounded background command.
enum DeveloperTask {
    static let inspectActions = ["inspect_repo", "review_diff"]
    static let taskActions = ["execute_task", "run_tests", "continue_task"]
    static let actions = inspectActions + taskActions

    static func execute(
        surface: String,
        _ a: JSONObject,
        workID: String?,
        workActivity: WorkActivity,
        workspace w: LocalWorkspaceService,
        processes p: LocalProcessService
    ) throws -> JSONObject {
        try a.requireOnlyKeys([
            "action", "workspace_id", "cwd", "title", "chat_label", "workflow_id",
            "executable", "arguments", "test_kind", "maximum_output_bytes",
            "maximum_commits", "staged", "path",
        ])
        let action = try a.requiredString("action", maximumBytes: 32)
        let allowedActions = surface == "developer_inspect" ? inspectActions : taskActions
        guard allowedActions.contains(action) else {
            throw LocalMCPError.invalidRequest(
                "action is not available on \(surface); use the matching developer surface"
            )
        }
        switch action {
        case "inspect_repo":
            let id = try a.requiredString("workspace_id", maximumBytes: 36)
            let cwd = try a.optionalString("cwd", maximumBytes: 4096) ?? "."
            let maximumCommits = try a.optionalInt(
                "maximum_commits", default: 12, range: 1...50
            )
            let children: [(String, JSONObject)] = [
                ("inspection", try ExpandedToolOperations.execute(
                    "workspace_inspect", ["workspace_id": id, "path": cwd],
                    workspace: w, processes: p
                )),
                ("git_status", try ExpandedToolOperations.execute(
                    "git_status", ["workspace_id": id, "cwd": cwd,
                                   "maximum_output_bytes": 65_536],
                    workspace: w, processes: p
                )),
                ("git_branches", try ExpandedToolOperations.execute(
                    "git_branches", ["workspace_id": id, "cwd": cwd,
                                     "maximum_output_bytes": 32_768],
                    workspace: w, processes: p
                )),
                ("git_log", try ExpandedToolOperations.execute(
                    "git_log", ["workspace_id": id, "cwd": cwd,
                                "maximum_commits": maximumCommits,
                                "maximum_output_bytes": 65_536],
                    workspace: w, processes: p
                )),
            ]
            return aggregate(
                action: action, children: children,
                base: [
                "developer_action": action,
                "next_actions": ["execute_task", "run_tests", "review_diff"],
                "authority_changed": false,
                ]
            )
        case "review_diff":
            let id = try a.requiredString("workspace_id", maximumBytes: 36)
            let cwd = try a.optionalString("cwd", maximumBytes: 4096) ?? "."
            var diff: JSONObject = [
                "workspace_id": id, "cwd": cwd,
                "maximum_output_bytes": 262_144,
                "staged": try a.optionalBool("staged", default: false),
            ]
            if let path = try a.optionalString("path", maximumBytes: 4096) {
                diff["path"] = path
            }
            let children: [(String, JSONObject)] = [
                ("git_status", try ExpandedToolOperations.execute(
                    "git_status", ["workspace_id": id, "cwd": cwd,
                                   "maximum_output_bytes": 65_536],
                    workspace: w, processes: p
                )),
                ("git_diff", try ExpandedToolOperations.execute(
                    "git_diff", diff, workspace: w, processes: p
                )),
            ]
            return aggregate(
                action: action, children: children,
                base: [
                "developer_action": action,
                "authority_changed": false,
                ]
            )
        case "execute_task", "run_tests":
            guard let workID else {
                throw LocalMCPError.operationFailed("developer parent was not created")
            }
            let id = try a.requiredString("workspace_id", maximumBytes: 36)
            let cwd = try a.optionalString("cwd", maximumBytes: 4096) ?? "."
            let command = try command(for: action, arguments: a, workspaceID: id,
                                      cwd: cwd, workspace: w)
            let maximumOutput = try a.optionalInt(
                "maximum_output_bytes", default: 262_144, range: 1_024...262_144
            )
            var result = try p.startCommand(
                workspaceID: id, executableID: command.executable,
                arguments: command.arguments, cwd: cwd,
                maximumOutputBytes: maximumOutput
            )
            result["developer_action"] = action
            result["workflow_id"] = workID
            result["work_id"] = workID
            result["next_action"] = "continue_task"
            result["selected_executable"] = command.executable
            result["selected_by"] = command.selectedBy
            result["authority_changed"] = false
            return result
        case "continue_task":
            guard let workID else {
                throw LocalMCPError.invalidRequest("workflow_id is not a retained developer task")
            }
            let supplied = try a.requiredString("workflow_id", maximumBytes: 36).lowercased()
            guard supplied == workID else {
                throw LocalMCPError.conflict("workflow_id does not match the retained parent")
            }
            let taskID = try workActivity.latestJobID(workID)
            let status = try p.processStatus(taskID: taskID)
            let running = status["running"] as? Bool == true
            var result: JSONObject = [
                "developer_action": action, "workflow_id": workID,
                "work_id": workID, "task_id": taskID, "running": running,
                "authority_changed": false,
            ]
            if running {
                result["process"] = try p.outputTail(taskID: taskID, maximumBytes: 8192)
                result["next_action"] = "continue_task"
                result["workflow_terminal"] = false
            } else {
                let process: JSONObject
                if status["session_retained"] as? Bool == true {
                    process = try p.processOutput(
                        taskID: taskID, stdoutCursor: 0, stderrCursor: 0,
                        maximumBytesPerStream: 262_144
                    )
                } else {
                    process = status
                }
                let exit = process["exit_code"] as? Int ?? status["exit_code"] as? Int
                result["process"] = process
                result["exit_code"] = exit ?? NSNull()
                result["workflow_terminal"] = true
                result["workflow_terminal_status"] = exit == 0 ? "completed" : "failed"
                result["next_action"] = "review_diff"
            }
            return result
        default:
            preconditionFailure("validated action")
        }
    }

    /// Promote bounded child receipts into one truthful parent status without
    /// copying command output into the summary. A successful gateway call can
    /// still be partial when one or more inspected child operations failed.
    private static func aggregate(
        action: String,
        children: [(String, JSONObject)],
        base: JSONObject
    ) -> JSONObject {
        var result = base
        var childResults: [JSONObject] = []
        var errorCount = 0
        var partialCount = 0
        for (step, child) in children {
            result[step] = child
            let failed = (child["exit_code"] as? Int).map { $0 != 0 } == true
                || child["timed_out"] as? Bool == true
                || child["cancelled"] as? Bool == true
                || child["isError"] as? Bool == true
                || child["error"] != nil
                || child["status"] as? String == "error"
            let truncated = child["complete"] as? Bool == false
                || child["partial"] as? Bool == true
                || child["truncated"] as? Bool == true
                || child["stdout_truncated"] as? Bool == true
                || child["stderr_truncated"] as? Bool == true
            if failed { errorCount += 1 }
            if truncated { partialCount += 1 }
            var receipt: JSONObject = [
                "step": step,
                "status": failed ? "failed" : (truncated ? "partial" : "completed"),
            ]
            for key in ["exit_code", "timed_out", "cancelled", "complete",
                        "stdout_truncated", "stderr_truncated"] where child[key] != nil {
                receipt[key] = child[key]
            }
            childResults.append(receipt)
        }
        let partial = errorCount > 0 || partialCount > 0
        result["child_count"] = children.count
        result["child_error_count"] = errorCount
        result["child_partial_count"] = partialCount
        result["child_results"] = childResults
        result["error_count"] = errorCount
        result["complete"] = !partial
        result["partial"] = partial
        result["overall_status"] = errorCount == children.count && !children.isEmpty
            ? "failed" : (partial ? "partial" : "completed")
        result["developer_action"] = action
        return result
    }

    private static func command(
        for action: String,
        arguments a: JSONObject,
        workspaceID: String,
        cwd: String,
        workspace w: LocalWorkspaceService
    ) throws -> (executable: String, arguments: [String], selectedBy: String) {
        if action == "execute_task" {
            return (
                try a.requiredString("executable", maximumBytes: 64),
                try a.requiredStringArray("arguments"),
                "caller_explicit"
            )
        }
        let extra = a["arguments"] == nil ? [] : try a.requiredStringArray("arguments")
        let kind = try a.optionalString("test_kind", maximumBytes: 16) ?? "auto"
        switch kind {
        case "swift": return ("swift", ["test", "--jobs", "2"] + extra, "test_kind")
        case "make": return ("make", ["test"] + extra, "test_kind")
        case "custom":
            return (
                try a.requiredString("executable", maximumBytes: 64), extra,
                "caller_explicit"
            )
        case "auto":
            func marker(_ name: String) -> String {
                if cwd == "." { return name }
                if cwd.hasPrefix("/") {
                    return URL(fileURLWithPath: cwd, isDirectory: true)
                        .appendingPathComponent(name).path
                }
                return cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    + "/" + name
            }
            if (try? w.statPath(
                workspaceID: workspaceID,
                path: marker("Package.swift"),
                includeSHA256: false
            )) != nil {
                return ("swift", ["test", "--jobs", "2"] + extra, "Package.swift")
            }
            if (try? w.statPath(
                workspaceID: workspaceID,
                path: marker("Makefile"),
                includeSHA256: false
            )) != nil {
                return ("make", ["test"] + extra, "Makefile")
            }
            throw LocalMCPError.invalidRequest(
                "automatic tests support Package.swift or Makefile; choose test_kind custom with an explicit supported executable"
            )
        default:
            throw LocalMCPError.invalidRequest("test_kind must be auto, swift, make or custom")
        }
    }
}
