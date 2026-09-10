import Foundation

/// Composes existing workspace and process boundaries; no new transport or authority.
enum ExpandedToolOperations {
    static func execute(_ name: String, _ a: JSONObject, workspace w: LocalWorkspaceService,
                        processes p: LocalProcessService) throws -> JSONObject {
        guard let spec = LocalMCPServer.toolSpecs.first(where: { $0["name"] as? String == name }),
              let schema = spec["inputSchema"] as? JSONObject,
              let properties = schema["properties"] as? JSONObject else {
            throw LocalMCPError.invalidRequest("Unknown direct-local tool.")
        }
        try a.requireOnlyKeys(Set(properties.keys))
        for key in schema["required"] as? [String] ?? [] {
            guard a[key] != nil else { throw LocalMCPError.invalidRequest("Missing required field: \(key)") }
        }
        func ws() throws -> String { try a.requiredString("workspace_id", maximumBytes: 36) }
        func path() throws -> String { try a.requiredString("path", maximumBytes: 4096) }
        func task() throws -> String { try a.requiredString("task_id", maximumBytes: 36) }
        switch name {
        case "tool_catalog":
            return try ToolDiscovery.catalog(a)
        case "workspace_inspect", "directory_summary", "directory_find":
            let id = try ws(), root = try a.optionalString("path", maximumBytes: 4096) ?? "."
            let recursive = name == "workspace_inspect" ? false : try a.optionalBool("recursive", default: false)
            let limit = name == "workspace_inspect" ? 256 : try a.optionalInt("maximum_entries", default: 1000, range: 1...10000)
            var result = try w.listDirectory(workspaceID: id, path: root, recursive: recursive, maximumEntries: limit)
            let entries = result.removeValue(forKey: "entries") as? [JSONObject] ?? []
            if name == "directory_find" {
                let pattern = try a.requiredString("pattern", maximumBytes: 256)
                guard !pattern.contains("/"), !pattern.contains("\0") else { throw LocalMCPError.invalidRequest("basename glob required") }
                result["matches"] = entries.filter {
                    glob(pattern, URL(fileURLWithPath: $0["relative_path"] as? String ?? "").lastPathComponent)
                }
            } else if name == "directory_summary" {
                var counts: [String: Int] = [:]
                var bytes: Int64 = 0
                for e in entries {
                    let kind = e["kind"] as? String ?? "unknown"
                    counts[kind, default: 0] += 1
                    if kind == "file" {
                        let size = (e["byte_count"] as? NSNumber)?.int64Value ?? 0
                        let sum = bytes.addingReportingOverflow(size)
                        guard !sum.overflow else { throw LocalMCPError.limitExceeded("logical byte count") }
                        bytes = sum.partialValue
                    }
                }
                result["counts"] = counts; result["logical_file_bytes"] = bytes
                result["allocated_disk_usage_measured"] = false
            } else {
                let markers: Set<String> = ["Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Makefile", "README.md", ".git"]
                result["project_markers"] = entries.filter { markers.contains(URL(fileURLWithPath: $0["relative_path"] as? String ?? "").lastPathComponent) }
                result["workspace_id"] = id
                result["directory"] = try w.statPath(workspaceID: id, path: root, includeSHA256: false)["path"]
                result["access_changed"] = false
            }
            result["scanned_returned_entries"] = entries.count
            return result
        case "file_read_lines":
            let data = try wholeFile(w, try ws(), try path())
            let text = try utf8(data), lines = splitLines(text)
            let start = try a.optionalInt("start_line", default: 1, range: 1...1000000)
            let maximum = try a.optionalInt("maximum_lines", default: 200, range: 1...2000)
            let lower = min(start - 1, lines.count), upper = min(lower + maximum, lines.count)
            return ["content": lines[lower..<upper].joined(), "start_line": start,
                    "returned_lines": upper - lower, "total_lines": lines.count,
                    "next_line": upper < lines.count ? upper + 1 : NSNull(), "eof": upper == lines.count,
                    "sha256": LocalHash.sha256(data), "snapshot_atomic": false]
        case "file_tail":
            let id = try ws(), filePath = try path()
            let maximum = try a.optionalInt("maximum_bytes", default: 8192, range: 4...262144)
            let stat = try w.statPath(workspaceID: id, path: filePath, includeSHA256: false)["path"] as? JSONObject ?? [:]
            let size = (stat["byte_count"] as? NSNumber)?.intValue ?? 0
            let offset = max(0, size - maximum)
            let file = try w.readFile(workspaceID: id, path: filePath, encoding: "base64", maximumBytes: maximum, offset: offset)["file"] as? JSONObject ?? [:]
            guard file["total_byte_count"] as? Int == size, file["eof"] as? Bool == true,
                  let data = Data(base64Encoded: file["content"] as? String ?? "") else {
                throw LocalMCPError.conflict("file changed during tail; read again")
            }
            var skip = 0
            while offset > 0, skip < min(3, data.count), data[skip] & 0xC0 == 0x80 { skip += 1 }
            let tail = Data(data.dropFirst(skip))
            return ["content": try utf8(tail), "byte_offset": offset + skip, "byte_count": tail.count,
                    "total_byte_count": size, "skipped_prefix_bytes": offset + skip, "eof": true,
                    "chunk_sha256": LocalHash.sha256(tail), "snapshot_atomic": false]
        case "file_compare":
            let id = try ws()
            let lhs = try wholeFile(w, id, a.requiredString("left_path", maximumBytes: 4096))
            let rhs = try wholeFile(w, id, a.requiredString("right_path", maximumBytes: 4096))
            var first: Int?
            for i in 0..<min(lhs.count, rhs.count) where lhs[i] != rhs[i] { first = i; break }
            if first == nil, lhs.count != rhs.count { first = min(lhs.count, rhs.count) }
            return ["equal": first == nil, "first_different_byte": first.map { $0 as Any } ?? NSNull(),
                    "left_sha256": LocalHash.sha256(lhs), "right_sha256": LocalHash.sha256(rhs),
                    "left_bytes": lhs.count, "right_bytes": rhs.count, "snapshot_atomic": false]
        case "file_search_many":
            let id = try ws(), paths = try strings(a, "paths", maximum: 16)
            let query = try a.requiredString("query", maximumBytes: 4096)
            let sensitive = try a.optionalBool("case_sensitive", default: true)
            let limit = try a.optionalInt("maximum_results_per_file", default: 50, range: 1...200)
            var budget = 4 * 1048576, results: [JSONObject] = []
            for filePath in paths {
                do {
                    guard budget > 0 else { throw LocalMCPError.limitExceeded("aggregate read budget") }
                    // Reserve before the read so failures also count against the I/O budget.
                    let allowance = min(budget, 1048576); budget -= allowance
                    let data = try wholeFile(w, id, filePath, limit: allowance)
                    budget += allowance - data.count
                    let lines = splitLines(try utf8(data))
                    var matches: [JSONObject] = [], more = false
                    for (i, line) in lines.enumerated() {
                        if line.range(of: query, options: sensitive ? [.literal] : [.literal, .caseInsensitive]) != nil {
                            if matches.count == limit { more = true; break }
                            matches.append(["line": i + 1, "text": String(line.prefix(512)), "text_truncated": line.count > 512])
                        }
                    }
                    results.append(["path": filePath, "status": "ok", "matches": matches, "complete": !more,
                                    "sha256": LocalHash.sha256(data)])
                } catch { results.append(itemError(filePath, error)) }
            }
            return ["results": results, "snapshot_atomic": false]
        case "file_apply_edits":
            let id = try ws(), filePath = try path()
            let expected = try a.requiredString("expected_sha256", maximumBytes: 64)
            let items = try objects(a, "edits", maximum: 32)
            let original = try wholeFile(w, id, filePath)
            _ = try utf8(original)
            guard LocalHash.sha256(original) == expected.lowercased() else { throw LocalMCPError.conflict("SHA-256 mismatch") }
            var edits: [(Range<Data.Index>, Data)] = []
            for item in items {
                try item.requireOnlyKeys(["old_text", "new_text"])
                let old = Data(try item.requiredString("old_text", maximumBytes: 262144).utf8)
                let replacement = Data(try boundedText(item, "new_text", 262144).utf8)
                guard let match = original.range(of: old),
                      original.range(of: old, in: (match.lowerBound + 1)..<original.endIndex) == nil else {
                    throw LocalMCPError.conflict("each old_text must occur exactly once in the original")
                }
                guard !edits.contains(where: { $0.0.overlaps(match) }) else { throw LocalMCPError.conflict("overlapping edits") }
                edits.append((match, replacement))
            }
            var updated = original
            for (range, data) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
                updated.replaceSubrange(range, with: data)
            }
            guard updated.count <= 1048576 else { throw LocalMCPError.limitExceeded("edited file exceeds 1 MiB") }
            var result = try w.writeFile(workspaceID: id, path: filePath, content: utf8(updated), encoding: "utf8", expectedSHA256: expected)
            result["edits_applied"] = edits.count
            return result
        case "file_write_many":
            let id = try ws(), items = try objects(a, "files", maximum: 16)
            var inputs: [(String, String, String?)] = [], total = 0
            for item in items {
                try item.requireOnlyKeys(["path", "content", "expected_sha256"])
                let filePath = try item.requiredString("path", maximumBytes: 4096)
                let content = try boundedText(item, "content", 262144)
                total += content.utf8.count
                guard total <= 1048576 else { throw LocalMCPError.limitExceeded("batch content exceeds 1 MiB") }
                inputs.append((filePath, content, try item.optionalString("expected_sha256", maximumBytes: 64)))
            }
            guard Set(inputs.map { $0.0 }).count == inputs.count else { throw LocalMCPError.invalidRequest("duplicate paths") }
            var results: [JSONObject] = [], success = 0
            for (filePath, content, expected) in inputs {
                do {
                    let receipt = try w.writeFile(workspaceID: id, path: filePath, content: content, encoding: "utf8", expectedSHA256: expected)
                    results.append(["path": filePath, "status": "ok", "receipt": receipt]); success += 1
                } catch { results.append(itemError(filePath, error)) }
            }
            return ["results": results, "success_count": success, "error_count": items.count - success,
                    "batch_atomic": false, "complete": success == items.count, "backend_called": true,
                    "mutation_performed": success > 0]
        case "command_list": return p.commandList()
        case "process_wait":
            return try p.observeProcess(taskID: task(), maximumWaitMilliseconds: a.optionalInt("maximum_wait_milliseconds", default: 1000, range: 0...1000))
        case "process_output_tail":
            return try p.outputTail(taskID: task(), maximumBytes: a.optionalInt("maximum_bytes_per_stream", default: 8192, range: 4...65536))
        case "process_status_many":
            return ["results": try strings(a, "task_ids", maximum: 32).map { id -> JSONObject in
                do { return ["task_id": id, "status": "ok", "result": try p.processStatus(taskID: id)] }
                catch { return itemError(id, error) }
            }]
        case "process_output_many":
            let items = try objects(a, "jobs", maximum: 8)
            let limit = try a.optionalInt("maximum_bytes_per_stream", default: 8192, range: 4...32768)
            // Validate all schemas before any consuming read.
            let requests = try items.map { item -> (String, Int, Int) in
                try item.requireOnlyKeys(["task_id", "stdout_cursor", "stderr_cursor"])
                return (try item.requiredString("task_id", maximumBytes: 36),
                        try item.optionalInt("stdout_cursor", default: 0, range: 0...Int.max),
                        try item.optionalInt("stderr_cursor", default: 0, range: 0...Int.max))
            }
            guard Set(requests.map { $0.0.lowercased() }).count == requests.count else { throw LocalMCPError.invalidRequest("duplicate tasks") }
            return ["results": requests.map { id, out, err -> JSONObject in
                do { return ["task_id": id, "status": "ok", "result": try p.processOutput(taskID: id, stdoutCursor: out, stderrCursor: err, maximumBytesPerStream: limit)] }
                catch { return itemError(id, error) }
            }]
        case "brevo_read":
            return try BrevoOperations.executeRead(a)
        case "brevo_campaign":
            return try BrevoOperations.executeCampaign(a)
        case let tool where BrevoToolCatalog.groups[tool] != nil:
            return try BrevoExtendedOperations.execute(tool, a)
        default:
            return try git(name, a, w, p)
        }
    }

    private static func wholeFile(_ w: LocalWorkspaceService, _ id: String, _ path: String, limit: Int = 1048576) throws -> Data {
        let response = try w.readFile(workspaceID: id, path: path, encoding: "base64", maximumBytes: limit)
        guard let file = response["file"] as? JSONObject, file["eof"] as? Bool == true,
              (file["total_byte_count"] as? Int ?? Int.max) <= limit,
              let data = Data(base64Encoded: file["content"] as? String ?? "") else {
            throw LocalMCPError.limitExceeded("file exceeds bounded read or changed during read")
        }
        return data
    }

    private static func utf8(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw LocalMCPError.invalidRequest("file is not UTF-8") }
        return text
    }

    private static func splitLines(_ text: String) -> [String] {
        // LF, not Character splitting: Swift treats CRLF as a single grapheme.
        guard !text.isEmpty else { return [] }
        var pieces = text.components(separatedBy: "\n")
        let terminated = pieces.removeLast()
        pieces = pieces.map { $0 + "\n" }
        if !terminated.isEmpty { pieces.append(terminated) }
        return pieces
    }

    private static func strings(_ a: JSONObject, _ key: String, maximum: Int) throws -> [String] {
        let values = try a.requiredStringArray(key, maximumItems: maximum)
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else {
            throw LocalMCPError.invalidRequest("non-empty bounded array required: \(key)")
        }
        return values
    }

    private static func objects(_ a: JSONObject, _ key: String, maximum: Int) throws -> [JSONObject] {
        guard let items = a[key] as? [JSONObject], !items.isEmpty, items.count <= maximum else {
            throw LocalMCPError.invalidRequest("bounded object array required: \(key)")
        }
        return items
    }

    private static func boundedText(_ a: JSONObject, _ key: String, _ maximum: Int) throws -> String {
        guard let text = a[key] as? String, text.utf8.count <= maximum else { throw LocalMCPError.invalidRequest("bounded string required: \(key)") }
        return text
    }

    private static func itemError(_ path: String, _ error: Error) -> JSONObject {
        ["requested_id_or_path": path, "status": "error",
         "message": (error as? LocalMCPError)?.description ?? "Operation failed."]
    }

    private static func glob(_ pattern: String, _ value: String) -> Bool {
        // Linear-space wildcard matching, no user-controlled regular expression.
        let p = Array(pattern), s = Array(value)
        var i = 0, j = 0, star: Int?, retry = 0
        while j < s.count {
            if i < p.count, p[i] == "?" || p[i] == s[j] { i += 1; j += 1 }
            else if i < p.count, p[i] == "*" { star = i; i += 1; retry = j }
            else if let k = star { retry += 1; j = retry; i = k + 1 }
            else { return false }
        }
        while i < p.count, p[i] == "*" { i += 1 }
        return i == p.count
    }

    private static func git(_ name: String, _ a: JSONObject, _ w: LocalWorkspaceService, _ p: LocalProcessService) throws -> JSONObject {
        let id = try a.requiredString("workspace_id", maximumBytes: 36)
        let cwd = try a.optionalString("cwd", maximumBytes: 4096) ?? "."
        func revision() throws -> String {
            let value = try a.optionalString("revision", maximumBytes: 40) ?? "HEAD"
            guard value == "HEAD" || ((7...40).contains(value.count) && value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })) else {
                throw LocalMCPError.invalidRequest("revision must be HEAD or a hexadecimal commit ID")
            }
            return value
        }
        func literalPath() throws -> String {
            let value = try a.requiredString("path", maximumBytes: 4096)
            guard !value.hasPrefix("/"), !value.contains("\0"), !value.split(separator: "/").contains("..") else { throw LocalMCPError.invalidRequest("repository-relative path required") }
            let root = try w.workspaceURL(workspaceID: id, relativePath: cwd)
            // Existing path boundary check when present; deleted paths are checked by
            // their containing directory and the sensitive-path filter, never opened.
            let target = root.appendingPathComponent(value)
            guard !LocalFilesystemAccess.isSensitive(target.path) else { throw LocalMCPError.sensitivePathBlocked }
            _ = try w.workspaceURL(workspaceID: id, relativePath: cwd)
            return value
        }
        var argv = ["--no-pager", "--no-optional-locks", "--literal-pathspecs",
                    "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                    "-c", "core.untrackedCache=false", "-c", "submodule.recurse=false",
                    "-c", "color.ui=false", "-c", "diff.external=", "-c", "credential.helper="]
        switch name {
        case "git_status": argv += ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=all"]
        case "git_diff":
            argv += ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all"]
            if try a.optionalBool("staged", default: false) { argv.append("--cached") }
            argv.append("--"); if a["path"] != nil { argv.append(try literalPath()) }
        case "git_log": argv += ["log", "-n", String(try a.optionalInt("maximum_commits", default: 20, range: 1...100)), "--format=%H%x09%cI%x09%s", try revision(), "--"]
        case "git_show": argv += ["show", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--format=fuller", "--stat", try revision(), "--"]
        case "git_branches": argv += ["for-each-ref", "--format=%(HEAD)%09%(refname:short)%09%(objectname)", "refs/heads/"]
        case "git_worktrees": argv += ["worktree", "list", "--porcelain"]
        case "git_blame":
            let start = try a.optionalInt("start_line", default: 1, range: 1...1000000)
            let count = try a.optionalInt("maximum_lines", default: 100, range: 1...200)
            argv += ["blame", "--no-textconv", "--line-porcelain", "-L", "\(start),+\(count)", "--", try literalPath()]
        case "git_file_list":
            argv += ["ls-files", "-z", "--cached"]
            if try a.optionalBool("include_untracked", default: false) { argv += ["--others", "--exclude-standard"] }
            argv.append("--")
        default: throw LocalMCPError.invalidRequest("Unknown expanded tool")
        }
        var result = try p.runReadOnlyGit(workspaceID: id, arguments: argv, cwd: cwd,
            timeoutMilliseconds: 10000, maximumOutputBytes: a.optionalInt("maximum_output_bytes", default: 65536, range: 1024...262144))
        result["git_operation"] = name
        result["output_format"] = name == "git_file_list" ? "nul_delimited_paths" : "git_text"
        return result
    }
}
