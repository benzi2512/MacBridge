import Foundation

/// Small deterministic metadata lookup. Never loads host functions or executes a tool.
enum ToolDiscovery {
    static let categories = ["workspace", "files", "search", "edit", "process", "git", "undo", "external"]
    static let aliases = ["workspace_list": "workspace_overview"]
    // A short entry point, not a second callable surface. Explicit searches and
    // names still cover the full catalog; no operation or permission is hidden.
    static let starterNames = ["developer_inspect", "developer_task", "workspace_overview", "directory_list", "file_read_many",
        "file_read", "file_search", "file_patch", "file_write", "command_start",
        "process_output", "process_cancel", "transaction_restore"]

    private static let searchTools: Set<String> = ["file_search", "file_search_many", "directory_find"]
    private static let editTools: Set<String> = ["file_write", "file_write_many", "file_patch",
        "file_apply_edits", "file_append", "directory_create", "path_copy", "path_move", "path_remove"]
    private static let phrases: [String: String] = [
        "bridge_capabilities": "health runtime identity build hash kiem tra ket noi",
        "bridge_activity_view": "show activity card UI xem hoat dong trong chat",
        "bridge_activity": "read runtime activity snapshot doc trang thai runtime",
        "tool_catalog": "find tool schema catalog tim cong cu tham so",
        "developer_inspect": "codex developer inspect repo review diff read only audit kiem tra du an thay doi",
        "developer_task": "codex developer execute task run tests continue workflow command agent lap trinh dieu phoi",
        "work_task": "parent task activity chat label group progress begin finish cong viec tong nhom hoat dong",
        "workspace_overview": "list workspaces configured roots danh sach workspace",
        "workspace_inspect": "project markers inspect workspace nhan dien project",
        "workspace_reload": "reload workspace configuration nap lai cau hinh",
        "directory_list": "list directory folder contents liet ke thu muc",
        "desktop_open": "open folder Finder pop show reveal file Preview TextEdit mo thu muc hien len man hinh application",
        "computer_control": "computer app UI accessibility snapshot press click button type text dieu khien ung dung bam nut",
        "directory_summary": "directory totals count size thong ke thu muc",
        "directory_find": "find filename basename glob tim ten file pattern",
        "file_stat": "one file metadata hash thong tin mot file",
        "file_stat_many": "many file metadata batch hash thong tin nhieu file",
        "file_read": "read one file binary base64 byte chunk doc mot file",
        "file_read_many": "read many files batch doc nhieu file",
        "file_read_lines": "read text line range doc dong van ban",
        "file_tail": "last file bytes tail file log cuoi file",
        "file_compare": "compare two files hash so sanh hai file",
        "file_search": "search content directory tree tim noi dung trong thu muc",
        "file_search_many": "search explicit files batch tim noi dung nhieu file",
        "file_write": "create write replace one file tao ghi mot file",
        "file_write_many": "create write many files batch tao ghi nhieu file",
        "file_patch": "replace all occurrences thay tat ca lan xuat hien",
        "file_apply_edits": "edit multiple replacements one file sua nhieu cho trong mot file",
        "file_append": "append bytes end file them vao cuoi file",
        "directory_create": "create directory tao thu muc",
        "path_copy": "copy file directory sao chep",
        "path_move": "move rename file directory di chuyen doi ten",
        "path_remove": "remove recoverable delete path xoa khoi phuc duoc",
        "transaction_restore": "restore undo rollback khoi phuc hoan tac",
        "transaction_list": "list undo receipts giao dich dang giu",
        "transaction_accept": "keep changes release undo giu thay doi bo undo",
        "command_list": "available executable commands lenh ho tro",
        "command_run": "short synchronous command lenh ngan dong bo",
        "command_start": "build test chay nen background long job",
        "network_command": "shell internet approved destination network grant mang duoc duyet",
        "process_status": "job status trang thai job khong doc log",
        "process_status_many": "many job status trang thai nhieu job",
        "process_output": "status output incremental logs doc log va trang thai cursor drain",
        "process_output_many": "many job output batch log doc log nhieu job",
        "process_output_tail": "latest job log peek xem log job moi nhat",
        "process_wait": "bounded wait completion cho job ngan",
        "process_list": "list jobs danh sach job",
        "process_input": "stdin interactive input gui du lieu vao job",
        "process_cancel": "cancel stop job huy dung job",
        "git_status": "git changes working tree trang thai git",
        "git_diff": "git diff staged unstaged thay doi code",
        "git_log": "git history recent commits lich su commit",
        "git_show": "git commit summary thong tin commit",
        "git_branches": "git branches nhanh hien tai",
        "git_worktrees": "git worktrees checkout danh sach worktree",
        "git_blame": "git blame line authors tac gia dong code",
        "git_file_list": "git tracked indexed paths danh sach file git",
        "brevo_read": "brevo email marketing account campaigns senders lists credits doc email campaign thong ke danh sach sender",
        "brevo_campaign": "brevo email campaign create update send test send now schedule tao sua gui email",
        "brevo_contacts": "brevo contacts contact customer consent blacklist attributes search import khach hang dong y dang ky",
        "brevo_lists": "brevo lists list folder cohort membership add remove contacts danh sach nhom",
        "brevo_segments": "brevo segments segment filter rules members phan khuc",
        "brevo_automations": "brevo automations workflow welcome abandoned checkout flow status limitations luong tu dong",
        "brevo_templates": "brevo templates template html subject active mau email",
        "brevo_events": "brevo custom events event track shopify order checkout su kien",
        "brevo_transactional": "brevo transactional delivery message logs bounce duplicate emails timeline loi gui",
        "brevo_deliverability": "brevo domain authentication dkim spf dmarc suppression blacklist sender",
        "brevo_webhooks": "brevo webhooks webhook subscription delivery events receiver",
        "brevo_reports": "brevo reports statistics revenue attribution conversion weekly doanh thu bao cao",
    ]

    static func category(for name: String) -> String {
        if name.hasPrefix("brevo_") { return "external" }
        if name.hasPrefix("git_") { return "git" }
        if name.hasPrefix("transaction_") { return "undo" }
        if name.hasPrefix("process_") || name.hasPrefix("command_") || name == "network_command" { return "process" }
        if searchTools.contains(name) { return "search" }
        if editTools.contains(name) { return "edit" }
        if name.hasPrefix("workspace_") || name.hasPrefix("bridge_") || name == "tool_catalog" || name == "work_task" || name == "developer_task" || name == "developer_inspect" { return "workspace" }
        return "files"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "đ", with: "d")
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private static func tokens(_ value: String) -> Set<String> {
        let ignored: Set<String> = ["a", "an", "the", "to", "in", "of", "for", "and", "with", "using",
            "use", "tool", "tools", "please", "macbridge", "mb", "toi", "cho", "hay", "giup", "cua", "va", "voi", "de", "bang"]
        let singular = ["files": "file", "jobs": "job", "lines": "line", "edits": "edit", "campaigns": "campaign"]
        return Set(normalized(value).split(separator: " ").map { singular[String($0)] ?? String($0) }).subtracting(ignored)
    }

    private static func score(_ spec: JSONObject, query: String) -> Int {
        let name = spec["name"] as! String, canonical = aliases[name] ?? name
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = normalized(aliases[key] ?? query)
        if exact == normalized(canonical) || exact == normalized(name) { return 10_000 }
        let wanted = tokens(query)
        guard !wanted.isEmpty else { return 0 }
        let hint = phrases[canonical] ?? ""
        let phraseBonus = exact.count >= 4 && normalized(hint).contains(exact) ? 500 : 0
        // Shared object words must not outweigh the requested action, e.g.
        // "delete a file" must not prefer every file_* tool over path_remove.
        let generic: Set<String> = ["file", "job", "path", "folder", "directory", "campaign", "thu", "muc"]
        func weight(_ matches: Set<String>) -> Int {
            matches.reduce(0) { $0 + (generic.contains($1) ? 1 : 3) }
        }
        return phraseBonus + weight(wanted.intersection(tokens(canonical))) * 12
            + weight(wanted.intersection(tokens(hint))) * 8
            + wanted.intersection(tokens(spec["description"] as? String ?? "")).count
    }

    static func catalog(_ arguments: JSONObject) throws -> JSONObject {
        try arguments.requireOnlyKeys(["names", "query", "category", "detail", "limit"])
        let all = LocalMCPServer.toolSpecs
        var names: Set<String>?
        if let raw = arguments["names"] {
            guard let values = raw as? [Any], !values.isEmpty, values.count <= all.count,
                  values.allSatisfy({ ($0 as? String).map { !$0.isEmpty && $0.utf8.count <= 128 } ?? false }) else {
                throw LocalMCPError.invalidRequest("names must contain 1-\(all.count) tool names")
            }
            names = Set(values.compactMap { $0 as? String })
            guard names!.isSubset(of: Set(all.compactMap { $0["name"] as? String })) else {
                throw LocalMCPError.invalidRequest("unknown tool name; search tool_catalog with query or category")
            }
        }
        let query = try arguments.optionalString("query", maximumBytes: 512)
        if let query, normalized(query).isEmpty { throw LocalMCPError.invalidRequest("query must contain letters or numbers") }
        let category = try arguments.optionalString("category", maximumBytes: 32)
        if let category, !categories.contains(category) { throw LocalMCPError.invalidRequest("unknown tool category") }
        // Explicit names preserve the existing exact-schema shortcut. Empty calls are compact.
        let detail = try arguments.optionalString("detail", maximumBytes: 16) ?? (names == nil ? "index" : "schemas")
        guard ["index", "schemas"].contains(detail) else { throw LocalMCPError.invalidRequest("invalid detail") }
        let filtered = query != nil || category != nil
        let starter = names == nil && !filtered && detail == "index" && arguments["limit"] == nil
        let limit = try arguments.optionalInt("limit", default: filtered ? 5 : (starter ? starterNames.count : all.count), range: 1...all.count)
        var selected = all.filter { spec in
            let name = spec["name"] as! String
            if let names, !names.contains(name) { return false }
            if names == nil, (detail == "index" || filtered), aliases[name] != nil { return false }
            if let category, Self.category(for: name) != category { return false }
            return true
        }
        if let query {
            selected = selected.map { ($0, score($0, query: query)) }.filter { $0.1 > 0 }
                .sorted { lhs, rhs in
                    lhs.1 == rhs.1 ? (lhs.0["name"] as! String) < (rhs.0["name"] as! String) : lhs.1 > rhs.1
                }.map { $0.0 }
        } else if starter {
            let rank = Dictionary(uniqueKeysWithValues: starterNames.enumerated().map { ($0.element, $0.offset) })
            selected.sort { lhs, rhs in
                let a = lhs["name"] as! String, b = rhs["name"] as! String
                let ar = rank[a] ?? Int.max, br = rank[b] ?? Int.max
                return ar == br ? a < b : ar < br
            }
        }
        let matched = selected.count
        selected = Array(selected.prefix(limit))
        let rows: [JSONObject] = detail == "schemas" ? selected : selected.map { spec in
            let name = spec["name"] as! String, schema = spec["inputSchema"] as! JSONObject
            let description = spec["description"] as! String
            return ["name": name, "canonical_name": aliases[name] ?? name,
                    "deprecated": aliases[name] != nil, "category": Self.category(for: name),
                    "description": String(description.prefix(180)), "description_truncated": description.count > 180,
                    "required": schema["required"] ?? [],
                    "parameters": (schema["properties"] as? JSONObject ?? [:]).keys.sorted(),
                    "annotations": spec["annotations"] ?? [:]]
        }
        return ["tools": rows, "detail": detail, "selection": starter ? "starter" : "lookup", "returned_count": rows.count,
                "matched_count": matched, "truncated": matched > rows.count,
                "catalog_count": all.count,
                "canonical_count": all.filter { aliases[$0["name"] as! String] == nil }.count,
                "catalog_sha256": LocalMCPServer.catalogSHA256,
                "categories": categories.map { category in
                    ["name": category, "count": all.filter { aliases[$0["name"] as! String] == nil && Self.category(for: $0["name"] as! String) == category }.count] as JSONObject
                },
                "instructions": "Use already-loaded callable schemas directly; otherwise use host discovery. Search query/category for a short list, names for exact schemas, or limit=\(all.count) for the full index. Use work_task for explicit multi-step activity grouping. Check each batch result; output includes job status and cursors. This lookup never executes or grants permission.",
                "host_callable_loading_guaranteed": false]
    }
}
