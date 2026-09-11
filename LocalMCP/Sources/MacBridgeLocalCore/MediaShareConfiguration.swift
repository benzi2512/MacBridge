import CryptoKit
import Darwin
import Foundation

/// A separate owner binding; no tool arguments can choose an endpoint or key.
struct MediaShareConfiguration {
    let endpoint: URL
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String
    let workspaceID: String
    let root: URL

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macbridge/media-share.json")
    }

    var binding: String {
        LocalHash.sha256(Data([endpoint.absoluteString, bucket, workspaceID, root.path]
            .joined(separator: "\n").utf8))
    }

    static func load(from url: URL = defaultURL) throws -> Self {
        let data = try MediaPrivateFile.read(url, limit: 16_384)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        let a = try LocalJSON.decodeObject(data)
        try a.requireOnlyKeys(["version", "endpoint", "bucket", "access_key_id",
                              "secret_access_key", "workspace_id", "media_root"])
        guard try a.optionalInt("version", default: 0, range: 0...1) == 1 else {
            throw LocalMCPError.invalidConfiguration("media configuration version must be 1")
        }
        let text = try a.requiredString("endpoint", maximumBytes: 160)
        guard let url = URL(string: text), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              let host = c.host, host == host.lowercased(),
              host.range(of: #"^[a-f0-9]{32}(\.(eu|us|fedramp))?\.r2\.cloudflarestorage\.com$"#,
                         options: .regularExpression) != nil else {
            throw LocalMCPError.invalidConfiguration("media endpoint must be a fixed HTTPS R2 S3 account endpoint")
        }
        let bucket = try a.requiredString("bucket", maximumBytes: 63)
        guard bucket.range(of: #"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil else {
            throw LocalMCPError.invalidConfiguration("media bucket name must use lower-case letters, digits and hyphens")
        }
        let access = try a.requiredString("access_key_id", maximumBytes: 128)
        let secret = try a.requiredString("secret_access_key", maximumBytes: 128)
        guard (16...128).contains(access.count), access.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              secret.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw LocalMCPError.invalidConfiguration("media configuration requires R2 S3 access credentials")
        }
        let workspace = try MediaShareID.parse(a.requiredString("workspace_id", maximumBytes: 36))
        let rootPath = try a.requiredString("media_root", maximumBytes: 4_096)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let root = URL(fileURLWithPath: rootPath)
        guard rootPath.hasPrefix("/"), !rootPath.contains("\0"),
              (try? canonicalExistingPath(rootPath)) == rootPath,
              root.pathComponents.count >= 4, rootPath != home,
              !home.hasPrefix(rootPath + "/"),
              root.deletingLastPathComponent().path != home,
              !LocalFilesystemAccess.isSensitive(rootPath) else {
            throw LocalMCPError.invalidConfiguration("media root must be one narrow non-sensitive directory")
        }
        let fd = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else {
            throw LocalMCPError.invalidConfiguration("media root is unavailable or contains a symlink")
        }
        defer { Darwin.close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & 0o022 == 0 else {
            throw LocalMCPError.invalidConfiguration("media root must be owner-owned and not writable by others")
        }
        return Self(endpoint: URL(string: "https://" + host)!, bucket: bucket,
                    accessKeyID: access, secretAccessKey: secret, workspaceID: workspace, root: root)
    }
}

enum MediaShareID {
    static func parse(_ value: String) throws -> String {
        guard value.count == 36, let id = UUID(uuidString: value) else {
            throw LocalMCPError.invalidRequest("media IDs must be UUIDs")
        }
        return id.uuidString.lowercased()
    }
}

enum MediaPrivateFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else {
            throw LocalMCPError.operationFailed("media owner configuration/state is unavailable; no credentials or URL were read")
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0,
              before.st_size > 0, before.st_size <= limit, !SearchFileReader.isDataless(before) else {
            throw LocalMCPError.operationFailed("media configuration/state must be a bounded owner-only regular file")
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        var after = stat(), current = stat()
        guard data.count == before.st_size, fstat(fd, &after) == 0, lstat(url.path, &current) == 0,
              stable(before, after), current.st_dev == after.st_dev, current.st_ino == after.st_ino else {
            throw LocalMCPError.conflict("media configuration/state changed during read")
        }
        return data
    }

    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
