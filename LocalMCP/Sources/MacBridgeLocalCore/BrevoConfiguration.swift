import Darwin
import Foundation

/// Per-owner configuration; never selected or supplied by a remote tool call.
/// Account and key are read together so one operation cannot mix configurations.
struct BrevoConfiguration {
    let accountEmail: String
    let apiKey: String

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macbridge/brevo.env")
    }

    static func load(from url: URL = defaultURL) throws -> BrevoConfiguration {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            throw LocalMCPError.operationFailed("Brevo owner configuration is unavailable (OS error \(code))")
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1,
              before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= 16_384 else {
            throw LocalMCPError.operationFailed("Brevo configuration must be a private owner-only regular file")
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16_385) ?? Data()
        var after = stat(), current = stat()
        guard data.count == before.st_size, fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_uid == after.st_uid, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              current.st_dev == after.st_dev, current.st_ino == after.st_ino,
              current.st_mode == after.st_mode, current.st_nlink == 1 else {
            throw LocalMCPError.conflict("Brevo configuration changed while being read")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> BrevoConfiguration {
        guard !data.isEmpty, data.count <= 16_384, let text = String(data: data, encoding: .utf8) else {
            throw LocalMCPError.operationFailed("Brevo configuration is invalid")
        }
        var fields: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                throw LocalMCPError.operationFailed("Brevo configuration has invalid syntax")
            }
            let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard ["BREVO_API_KEY", "BREVO_ACCOUNT_EMAIL"].contains(name), fields[name] == nil else {
                throw LocalMCPError.operationFailed("Brevo configuration contains an unexpected or duplicate field")
            }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value.removeFirst(); value.removeLast()
            }
            fields[name] = value
        }
        guard let key = fields["BREVO_API_KEY"], (16...8_192).contains(key.utf8.count),
              key.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              let email = fields["BREVO_ACCOUNT_EMAIL"] else {
            throw LocalMCPError.operationFailed("Brevo key and explicit account binding are required")
        }
        try BrevoSafety.email(email)
        return BrevoConfiguration(accountEmail: email.lowercased(), apiKey: key)
    }
}
