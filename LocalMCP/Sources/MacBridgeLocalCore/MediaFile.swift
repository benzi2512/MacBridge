import CryptoKit
import Darwin
import Foundation

/// Descriptor-stable reads; publication uploads a private immutable snapshot.
/// Magic-byte checks classify media, not malware scanning or content approval.
enum MediaFile {
    static let maximumBytes = 256 * 1_024 * 1_024
    struct Proof {
        let path: String
        let sha256: String
        let bytes: Int
        let mime: String
        let ext: String
        var mediaType: String { mime.hasPrefix("image/") ? "IMAGE" : "VIDEO" }
        var json: JSONObject {
            ["path": path, "sha256": sha256, "byte_count": bytes, "mime_type": mime,
             "media_type": mediaType, "network_request": false, "source_modified": false]
        }
    }
    final class Snapshot {
        let url: URL
        let directory: URL
        init() throws {
            // Foundation's resolvingSymlinksInPath can fold /private/var back
            // to /var, which O_NOFOLLOW_ANY correctly rejects. Keep realpath's
            // exact spelling; honor the isolated process's explicit temp root.
            let temporary = ProcessInfo.processInfo.environment["TMPDIR"]
                ?? FileManager.default.temporaryDirectory.path
            let base = URL(fileURLWithPath: try canonicalExistingPath(temporary))
            var template = Array(base.appendingPathComponent("mb-media-XXXXXX").path.utf8CString)
            guard mkdtemp(&template) != nil else {
                throw LocalMCPError.operationFailed("could not allocate a private media snapshot directory")
            }
            directory = URL(fileURLWithPath: String(cString: template))
            url = directory.appendingPathComponent("payload")
        }
        deinit {
            // Only the exact payload and empty directory created by mkdtemp.
            _ = unlink(url.path)
            _ = rmdir(directory.path)
        }
    }

    static func resolve(workspace: RegisteredLocalWorkspace, path: String, mediaRoot: URL? = nil) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".") else {
            throw LocalMCPError.invalidRequest("invalid media path")
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.rootURL.appendingPathComponent(path)
        let root = workspace.rootURL.path
        guard (root == "/" || url.path.hasPrefix(root + "/")),
              !LocalFilesystemAccess.isSensitive(url.path),
              mediaRoot.map({ url.path.hasPrefix($0.path + "/") }) ?? true else {
            throw LocalMCPError.invalidRequest("media file is outside the approved root")
        }
        return url
    }

    static func read(workspace: RegisteredLocalWorkspace, path: String, mediaRoot: URL? = nil,
                     snapshot: Snapshot? = nil) throws -> Proof {
        let url = try resolve(workspace: workspace, path: path, mediaRoot: mediaRoot)
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw LocalMCPError.operationFailed("media file is unavailable or contains a symlink") }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid(), before.st_size > 0, before.st_size <= maximumBytes,
              !SearchFileReader.isDataless(before) else {
            throw LocalMCPError.invalidRequest("media must be an owned single-link regular file, present locally and at most 256 MiB")
        }
        var prefix = [UInt8](repeating: 0, count: 64)
        let prefixCount = pread(fd, &prefix, prefix.count, 0)
        guard prefixCount > 0 else { throw LocalMCPError.operationFailed("could not inspect media header") }
        let media = try classify(Array(prefix.prefix(prefixCount)), extension: url.pathExtension.lowercased())
        let destination = snapshot.map { Darwin.open($0.url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600) } ?? -1
        guard snapshot == nil || destination >= 0 else {
            throw LocalMCPError.operationFailed("could not create a private media snapshot")
        }
        defer { if destination >= 0 { Darwin.close(destination) } }
        let start = DispatchTime.now().uptimeNanoseconds
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var offset: Int64 = 0
        while offset < before.st_size {
            guard DispatchTime.now().uptimeNanoseconds - start < 30_000_000_000 else {
                throw LocalMCPError.limitExceeded("media snapshot exceeded its 30-second read budget")
            }
            let count = pread(fd, &buffer, min(buffer.count, Int(before.st_size - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LocalMCPError.conflict("media changed or could not be read") }
            hash.update(data: Data(buffer.prefix(count)))
            if destination >= 0 {
                try buffer.withUnsafeBytes { bytes in
                    var written = 0
                    while written < count {
                        let n = Darwin.write(destination, bytes.baseAddress!.advanced(by: written), count - written)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw LocalMCPError.operationFailed("private media snapshot write failed") }
                        written += n
                    }
                }
            }
            offset += Int64(count)
        }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              MediaPrivateFile.stable(before, after), current.st_dev == after.st_dev, current.st_ino == after.st_ino,
              snapshot == nil || fsync(destination) == 0 else {
            throw LocalMCPError.conflict("media changed during snapshot; nothing was published")
        }
        return Proof(path: url.path, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                     bytes: Int(before.st_size), mime: media.0, ext: media.1)
    }

    static func classify(_ b: [UInt8], extension ext: String) throws -> (String, String) {
        if ["jpg", "jpeg"].contains(ext), b.starts(with: [0xff, 0xd8, 0xff]) { return ("image/jpeg", "jpg") }
        if ext == "png", b.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return ("image/png", "png") }
        if ext == "gif", b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)) {
            return ("image/gif", "gif")
        }
        if ["mp4", "mov"].contains(ext), b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let size = b[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if size >= 8, ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "qt  "].contains(brand) {
                return ext == "mov" ? ("video/quicktime", "mov") : ("video/mp4", "mp4")
            }
        }
        throw LocalMCPError.invalidRequest("unsupported media or extension/header mismatch; use JPEG, PNG, GIF, MP4 or MOV")
    }
}
