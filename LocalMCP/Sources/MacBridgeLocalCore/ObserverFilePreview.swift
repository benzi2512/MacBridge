import Darwin
import Foundation

/// On-demand selected-file reads for the authenticated local observer. This
/// caches one validated metadata version, never file content or a file watcher.
final class ObserverFilePreview {
    static let maximumBytes = 16 * 1024
    private let lock = NSLock()
    private var validatedVersion: (path: String, version: String)?

    func read(url: URL, root: String, expected: stat, knownVersion: String?) throws -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        guard expected.st_mode & S_IFMT == S_IFREG, expected.st_nlink == 1 else {
            throw LocalMCPError.wrongFileType
        }
        guard !SearchFileReader.isDataless(expected) else {
            throw LocalMCPError.operationFailed("file is not downloaded locally; preview did not read it")
        }
        // The same no-symlink-anywhere flag used by the bounded search reader;
        // NONBLOCK avoids a FIFO-open wait after a concurrent path replacement.
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw LocalMCPError.operationFailed("selected file could not be opened without following links") }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= off_t(Int.max),
              before.st_dev == expected.st_dev, before.st_ino == expected.st_ino else {
            throw LocalMCPError.conflict("selected file changed before preview")
        }
        guard !SearchFileReader.isDataless(before) else {
            throw LocalMCPError.operationFailed("file is not downloaded locally; preview did not read it")
        }
        let path = try confirmedPath(fd, root: root)
        let version = Self.version(before, path: path)
        var result: JSONObject = [
            "path": path, "version": version, "version_basis": "stat_metadata_not_content_hash",
            "total_bytes": Int(before.st_size), "preview_limit_bytes": Self.maximumBytes,
            "truncated": before.st_size > Self.maximumBytes, "unchanged": false,
            "validation_scope": "bounded_text_prefix_and_current_path",
        ]
        // A client-supplied version cannot bypass text validation on its own.
        if knownVersion == version, validatedVersion?.path == path, validatedVersion?.version == version {
            try verifyStillCurrent(fd, before: before, path: path, root: root)
            result["unchanged"] = true
            return result
        }
        let count = min(Int(before.st_size), Self.maximumBytes + 3)
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.pread(fd, base.advanced(by: offset), count - offset, off_t(offset))
                if received > 0 { offset += received }
                else if received < 0 && errno == EINTR { continue }
                else if received == 0 { throw LocalMCPError.conflict("selected file changed during preview") }
                else { throw LocalMCPError.operationFailed("selected file preview could not be read") }
            }
        }
        // Validate the scalar crossing the limit, but never return more than
        // 16 KiB. Three lookahead bytes are enough for a four-byte UTF-8 scalar.
        var validationEnd = min(Self.maximumBytes, data.count)
        while validationEnd < data.count, data[validationEnd] & 0xC0 == 0x80 { validationEnd += 1 }
        let validated = data.prefix(validationEnd)
        guard String(data: validated, encoding: .utf8) != nil,
              !validated.contains(where: { $0 < 0x20 && ![0x09, 0x0A, 0x0D].contains($0) || $0 == 0x7F }) else {
            validatedVersion = nil
            throw LocalMCPError.operationFailed("selected file is binary or is not a supported UTF-8 text preview")
        }
        var shownEnd = min(Self.maximumBytes, validationEnd)
        while shownEnd > 0, shownEnd < data.count, data[shownEnd] & 0xC0 == 0x80 { shownEnd -= 1 }
        guard let text = String(data: data.prefix(shownEnd), encoding: .utf8) else {
            throw LocalMCPError.operationFailed("selected file is not valid UTF-8")
        }
        try verifyStillCurrent(fd, before: before, path: path, root: root)
        validatedVersion = (path, version)
        result["text"] = text
        result["preview_bytes"] = shownEnd
        result["truncated"] = before.st_size > shownEnd
        return result
    }

    private func verifyStillCurrent(_ fd: Int32, before: stat, path: String, root: String) throws {
        var after = stat()
        guard fstat(fd, &after) == 0, Self.version(after, path: path) == Self.version(before, path: path),
              try confirmedPath(fd, root: root) == path else {
            throw LocalMCPError.conflict("selected file changed during preview; refresh it")
        }
        // Descriptor content is not sufficient for an Open/Reveal path: the
        // current path must still identify the same regular non-symlink file.
        let current = try lstatValue(path)
        guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              current.st_dev == after.st_dev, current.st_ino == after.st_ino,
              Self.version(current, path: path) == Self.version(after, path: path) else {
            throw LocalMCPError.conflict("selected file path was replaced; refresh it")
        }
    }

    private func confirmedPath(_ fd: Int32, root: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard buffer.withUnsafeMutableBufferPointer({ Darwin.fcntl(fd, F_GETPATH, $0.baseAddress!) }) == 0 else {
            throw LocalMCPError.operationFailed("selected file path could not be confirmed")
        }
        let path = String(cString: buffer)
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix), path != root,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else {
            throw LocalMCPError.invalidPath("selected file is outside the registered root or has an unsupported name")
        }
        guard !LocalFilesystemAccess.isSensitive(path) else { throw LocalMCPError.sensitivePathBlocked }
        return path
    }

    private static func version(_ s: stat, path: String) -> String {
        let stamp = [String(s.st_dev), String(s.st_ino), String(s.st_size), String(s.st_mode), String(s.st_nlink),
            String(s.st_uid), String(s.st_gid), String(s.st_flags), String(s.st_mtimespec.tv_sec),
            String(s.st_mtimespec.tv_nsec), String(s.st_ctimespec.tv_sec), String(s.st_ctimespec.tv_nsec)]
            .joined(separator: ":")
        return LocalHash.sha256(Data((path + "\n" + stamp).utf8))
    }
}
