import Darwin
import Foundation

struct MediaShareRecord: Codable {
    let requestID: String
    let workspaceID: String
    let path: String
    let sha256: String
    let bytes: Int
    let mime: String
    let ext: String
    let objectKey: String
    let issued: Int64
    let seconds: Int
    var state: String

    var expires: Int64 { issued + Int64(seconds) }
    var mediaType: String { mime.hasPrefix("image/") ? "IMAGE" : "VIDEO" }
    func validate() throws {
        _ = try MediaShareID.parse(requestID)
        _ = try MediaShareID.parse(workspaceID)
        let parts = objectKey.split(separator: "/")
        guard requestID == requestID.lowercased(), workspaceID == workspaceID.lowercased(),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              bytes > 0, bytes <= MediaFile.maximumBytes, path.utf8.count <= 4_096,
              path.hasPrefix("/"), !LocalFilesystemAccess.isSensitive(path),
              (60...3_600).contains(seconds), issued > 0, issued < 4_000_000_000,
              ["pending", "ready", "outcome_unknown", "revoked", "missing"].contains(state),
              ["jpg": "image/jpeg", "png": "image/png", "gif": "image/gif",
               "mp4": "video/mp4", "mov": "video/quicktime"][ext] == mime,
              parts.count == 3, parts[0] == "macbridge-transfers",
              UUID(uuidString: String(parts[1])) != nil, parts[2] == "media." + ext else {
            throw LocalMCPError.operationFailed("invalid private media receipt")
        }
    }
}

/// Private bounded ledger and a non-blocking inter-process lease. Persist before
/// PUT, so a crashed/lost response is reconciled by HEAD, never automatic PUT.
final class MediaShareJournal {
    private struct State: Codable {
        let version: Int
        let binding: String
        var records: [MediaShareRecord]
    }
    private let directoryFD: Int32
    private let lockFD: Int32
    private let stateURL: URL
    private var state: State
    static let maximumRecords = 1_024
    static let maximumStateBytes = 1_048_576

    init(configurationURL: URL, binding: String) throws {
        let directory = configurationURL.deletingLastPathComponent()
        let dir = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard dir >= 0 else { throw LocalMCPError.operationFailed("private media state directory unavailable") }
        var ds = stat()
        guard fstat(dir, &ds) == 0, ds.st_uid == getuid(), ds.st_mode & 0o077 == 0 else {
            Darwin.close(dir)
            throw LocalMCPError.operationFailed("media owner directory must have mode 0700")
        }
        let lock = openat(dir, "media-share.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        var ls = stat()
        guard lock >= 0, fstat(lock, &ls) == 0, ls.st_mode & S_IFMT == S_IFREG,
              ls.st_uid == getuid(), ls.st_nlink == 1, ls.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { Darwin.close(lock) }
            Darwin.close(dir)
            throw LocalMCPError.operationFailed("media lease unavailable; another operation may be active")
        }
        let url = directory.appendingPathComponent("media-shares.json")
        var loaded = State(version: 1, binding: binding, records: [])
        do {
            var st = stat()
            if lstat(url.path, &st) == 0 {
                let data = try MediaPrivateFile.read(url, limit: Self.maximumStateBytes)
                loaded = try JSONDecoder().decode(State.self, from: data)
                guard loaded.version == 1, loaded.binding == binding,
                      loaded.records.count <= Self.maximumRecords,
                      Set(loaded.records.map(\.requestID)).count == loaded.records.count,
                      Set(loaded.records.map(\.objectKey)).count == loaded.records.count else {
                    throw LocalMCPError.conflict("media binding changed or receipt ledger is invalid; retain it for reconciliation")
                }
                for record in loaded.records { try record.validate() }
            } else if errno != ENOENT {
                throw LocalMCPError.operationFailed("could not inspect private media receipts")
            }
        } catch {
            flock(lock, LOCK_UN); Darwin.close(lock); Darwin.close(dir)
            throw error
        }
        // Transfer descriptor ownership only after all throwing validation. A
        // failed initializer must not manually close and then deinit-close an FD.
        directoryFD = dir
        lockFD = lock
        stateURL = url
        state = loaded
    }

    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD); Darwin.close(directoryFD) }

    func record(_ requestID: String) -> MediaShareRecord? { state.records.first { $0.requestID == requestID } }
    var outstandingBytes: Int {
        state.records.filter { !["revoked", "missing"].contains($0.state) }.reduce(0) { $0 + $1.bytes }
    }

    func save(_ record: MediaShareRecord) throws {
        try record.validate()
        var updated = state
        if let i = updated.records.firstIndex(where: { $0.requestID == record.requestID }) {
            updated.records[i] = record
        } else {
            guard updated.records.count < Self.maximumRecords else {
                throw LocalMCPError.limitExceeded("media receipt ledger is full; no retained receipt was evicted")
            }
            updated.records.append(record)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        guard data.count <= Self.maximumStateBytes else { throw LocalMCPError.limitExceeded("media receipt byte limit reached") }
        let name = ".media-share-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalMCPError.operationFailed("could not persist media receipt") }
        defer { Darwin.close(fd); _ = unlinkat(directoryFD, name, 0) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, renameat(directoryFD, name, directoryFD, stateURL.lastPathComponent) == 0,
              fsync(directoryFD) == 0 else {
            throw LocalMCPError.operationFailed("media receipt persistence could not be confirmed")
        }
        state = updated
    }
}
