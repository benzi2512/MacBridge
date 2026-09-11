import Foundation
import CoreFoundation

/// A bounded display receipt, not a command transcript or an authorization layer.
/// Only known input fields and an intentionally small command grammar are shown.
/// Arbitrary payloads cannot be reliably redacted: scripts, environment values,
/// opaque arguments, search text and file contents are therefore never copied.
enum ActivityDetail {
    static func metadata(name: String, arguments a: JSONObject) -> JSONObject {
        var result = JSONObject()
        var omitted = false
        var truncated = false
        let fileTools: Set<String> = [
            "file_read", "file_read_lines", "file_tail", "file_stat", "file_patch",
            "file_apply_edits", "file_write", "file_append", "file_search", "directory_list",
            "directory_summary", "directory_find", "directory_create", "path_remove", "workspace_inspect",
            "git_diff", "git_blame", "developer_inspect", "desktop_open",
        ]
        var paths: [String] = []
        if fileTools.contains(name), let path = a["path"] as? String { paths = [path] }
        if ["file_read_many", "file_stat_many", "file_search_many"].contains(name),
           let supplied = a["paths"] as? [String] { paths = supplied }
        if name == "file_write_many", let files = a["files"] as? [JSONObject] {
            paths = files.compactMap { $0["path"] as? String }
        }
        if name == "file_compare" { paths = ["left_path", "right_path"].compactMap { a[$0] as? String } }
        if ["path_copy", "path_move"].contains(name) {
            paths = ["source_path", "destination_path"].compactMap { a[$0] as? String }
        }
        if !paths.isEmpty {
            result["target_count"] = paths.count
            result["targets"] = paths.prefix(3).map { safePath($0, omitted: &omitted, truncated: &truncated) }
            if paths.count > 3 { truncated = true }
        }
        if (name.hasPrefix("git_") || name == "command_start" || name == "command_run"
            || name == "developer_task" || name == "developer_inspect"),
           let cwd = a["cwd"] as? String {
            result["cwd"] = safePath(cwd, omitted: &omitted, truncated: &truncated)
        }
        if (name == "developer_task" || name == "developer_inspect"), let action = a["action"] as? String,
           DeveloperTask.actions.contains(action) {
            result["developer_action"] = action
        }
        if name == "file_read_lines" || name == "git_blame" {
            // These are requested bounds. Do not label them as lines actually read.
            if let start = positiveInteger(a["start_line"], maximum: 1_000_000) { result["start_line"] = start }
            if let count = positiveInteger(a["maximum_lines"], maximum: 2_000) { result["maximum_lines"] = count }
        }
        if name == "file_apply_edits", let edits = a["edits"] as? [JSONObject], !edits.isEmpty {
            result["edit_count"] = edits.count
            result["edit_count_scope"] = "requested"
        } else if name == "file_patch" {
            // A replace-all patch is one requested edit, potentially many replacements.
            result["edit_count"] = 1
            result["edit_count_scope"] = "requested"
        }
        if ["command_start", "command_run", "network_command"].contains(name), let executable = a["executable"] as? String {
            result["command_preview"] = commandPreview(executable: executable,
                arguments: a["arguments"] as? [String] ?? [], omitted: &omitted, truncated: &truncated)
        }
        if name == "developer_task", let executable = a["executable"] as? String {
            result["command_preview"] = commandPreview(
                executable: executable,
                arguments: a["arguments"] as? [String] ?? [],
                omitted: &omitted,
                truncated: &truncated
            )
        }
        if omitted { result["preview_omitted"] = true }
        if truncated { result["preview_truncated"] = true }
        return result
    }

    static func context(_ metadata: JSONObject) -> String? {
        var parts: [String] = []
        if let action = metadata["developer_action"] as? String {
            parts.append(action.replacingOccurrences(of: "_", with: " "))
        }
        if let command = metadata["command_preview"] as? String { parts.append("command \(command)") }
        if let targets = metadata["targets"] as? [String], !targets.isEmpty {
            let count = metadata["target_count"] as? Int ?? targets.count
            parts.append("target\(count == 1 ? "" : "s") \(targets.joined(separator: ", "))")
            if count > targets.count { parts.append("\(count) targets total") }
        }
        if let cwd = metadata["cwd"] as? String { parts.append("folder \(cwd)") }
        if let start = metadata["start_line"] as? Int {
            if let count = metadata["maximum_lines"] as? Int {
                parts.append("requested lines \(start)–\(start + count - 1)")
            } else { parts.append("requested from line \(start)") }
        } else if let count = metadata["maximum_lines"] as? Int { parts.append("requested up to \(count) lines") }
        if metadata["preview_truncated"] as? Bool == true { parts.append("preview truncated") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func positiveInteger(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 1, number.doubleValue <= Double(maximum),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func safePath(_ path: String, omitted: inout Bool, truncated: inout Bool) -> String {
        // Do not make an unsafe path look legitimate by deleting controls or URL credentials.
        let pathCharacters = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " ._-/~()+"))
        guard !path.isEmpty, path.utf8.count <= 4_096, plain(path), !secretLike(path),
              path.unicodeScalars.allSatisfy({ pathCharacters.contains($0) }),
              !path.contains("://"), !path.contains("="), !path.contains("?"),
              !path.contains("#"), !path.contains("@"), !path.contains("\\") else {
            omitted = true; return "[path omitted]"
        }
        return bounded(path, maximumBytes: 192, truncated: &truncated)
    }

    private static func commandPreview(executable: String, arguments: [String],
                                       omitted: inout Bool, truncated: inout Bool) -> String {
        let programs: Set<String> = ["swift", "xcodebuild", "git", "npm", "npx", "node", "nodejs",
            "python", "python3", "bash", "zsh", "sh", "make", "cmake", "cargo", "rustc", "go",
            "rg", "ls", "pwd", "cat", "head", "tail", "wc", "find", "sed", "awk", "printf", "echo",
            "mkdir", "touch", "cp", "mv", "rm", "uname", "date", "true", "false"]
        guard programs.contains(executable) else { omitted = true; return "[executable and arguments omitted]" }
        if ["echo", "printf", "sed", "awk"].contains(executable), !arguments.isEmpty {
            omitted = true
            return "\(executable) [text/program arguments omitted]"
        }
        let commands: Set<String> = ["build", "test", "run", "package", "install", "ci", "lint", "check",
            "format", "clean", "status", "diff", "log", "show", "branch", "worktree", "list", "blame",
            "ls-files", "rev-parse", "add", "commit", "fetch", "pull", "push", "checkout", "switch",
            "describe", "version", "help", "init", "generate", "validate", "all"]
        let flags: Set<String> = ["--version", "-v", "--help", "-h", "--verbose", "--quiet", "-q",
            "--parallel", "--skip-build", "--enable-code-coverage", "--disable-sandbox", "--release",
            "--no-pager", "--porcelain", "--porcelain=v1", "--short", "--stat", "--staged", "--cached",
            "--name-only", "--name-status", "--oneline", "--all", "--check", "--dry-run", "--no-color",
            "--color=never", "--no-heading", "--files", "--hidden", "--glob-case-insensitive", "--null",
            "-B", "-l", "-i", "-a", "-n", "-r", "-R", "-f", "--"]
        let numericFlags: Set<String> = ["--jobs", "-j", "--max-count", "--max-depth", "--depth", "--lines"]
        let pathFlags: Set<String> = ["--cwd", "--directory", "--package-path", "--scratch-path", "-C"]
        let namedFlags: Set<String> = ["--filter", "--target", "--product", "--configuration", "-configuration", "-scheme"]
        let shells: Set<String> = ["bash", "zsh", "sh"]
        var pieces = [executable]
        var expected = ""
        var hideNext = false
        var needsSearchPattern = executable == "rg" && !arguments.contains("--files")
        for argument in arguments.prefix(128) {
            if hideNext { pieces.append("[argument omitted]"); omitted = true; hideNext = false; continue }
            if argument == "-c" || argument == "-e" || argument == "--eval" || argument == "--print" ||
                (shells.contains(executable) && argument.hasPrefix("-") && argument.dropFirst().contains("c")) {
                pieces.append(argument == "-c" || argument == "-e" ? argument : "[script option]")
                pieces.append("[script and remaining arguments omitted]"); omitted = true; break
            }
            if !expected.isEmpty {
                let kind = expected; expected = ""
                if kind == "number", argument.count <= 7, !argument.isEmpty, argument.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    pieces.append(argument)
                } else if kind == "path" { pieces.append(quote(safePath(argument, omitted: &omitted, truncated: &truncated)))
                } else if kind == "name", safeIdentifier(argument) { pieces.append(quote(argument))
                } else { pieces.append("[argument omitted]"); omitted = true }
                continue
            }
            guard plain(argument), argument.utf8.count <= 192, !secretLike(argument),
                  (!argument.contains("=") || flags.contains(argument)), !argument.contains("://"), !argument.contains("@") else {
                // Unknown options may carry a value in the next argument. Fail closed for that value too.
                hideNext = argument.hasPrefix("-") && !argument.contains("=")
                pieces.append("[argument omitted]"); omitted = true; continue
            }
            if numericFlags.contains(argument) { pieces.append(argument); expected = "number" }
            else if pathFlags.contains(argument) { pieces.append(argument); expected = "path" }
            else if namedFlags.contains(argument) { pieces.append(argument); expected = "name" }
            else if flags.contains(argument) { pieces.append(argument) }
            else if needsSearchPattern, !argument.hasPrefix("-") {
                pieces.append("[search pattern omitted]"); omitted = true; needsSearchPattern = false
            }
            else if commands.contains(argument) { pieces.append(argument) }
            else if fileOperand(argument) { pieces.append(quote(safePath(argument, omitted: &omitted, truncated: &truncated))) }
            else {
                pieces.append("[argument omitted]"); omitted = true
                hideNext = argument.hasPrefix("-")
            }
        }
        if arguments.count > 128 { truncated = true }
        return bounded(pieces.joined(separator: " "), maximumBytes: 512, truncated: &truncated)
    }

    private static func safeIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 96 && plain(text) && !secretLike(text) &&
            text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-:").contains($0) }
    }

    private static func fileOperand(_ text: String) -> Bool {
        if text == "." || text == ".." { return true }
        guard safeIdentifier(text) else { return false }
        return text.contains("/") || ["swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "txt",
            "html", "css", "sh", "yml", "yaml", "toml", "rs", "go", "c", "h", "cpp", "m", "mm"]
            .contains((text as NSString).pathExtension.lowercased())
    }

    private static func plain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format ||
                scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator
        }
    }

    private static func secretLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["password", "passwd", "authorization", "bearer", "api_key", "api-key", "apikey", "secret",
                "access_token", "access-token", "refresh_token", "refresh-token", "token=", "--token",
                "sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "akia", "-----begin", "eyjh"]
            .contains(where: { lower.contains($0) }) { return true }
        // Long unbroken token-like strings are opaque even without a familiar vendor prefix.
        var run = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { run += 1; if run >= 32 { return true } }
            else { run = 0 }
        }
        return false
    }

    private static func quote(_ text: String) -> String {
        text.contains(" ") ? "\"\(text)\"" : text
    }

    private static func bounded(_ text: String, maximumBytes: Int, truncated: inout Bool) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        truncated = true
        let suffix = "… [truncated]"
        var output = ""
        for character in text {
            guard output.utf8.count + String(character).utf8.count <= maximumBytes - suffix.utf8.count else { break }
            output.append(character)
        }
        return output + suffix
    }
}
