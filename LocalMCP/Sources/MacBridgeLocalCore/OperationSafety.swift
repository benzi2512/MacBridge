import Darwin
import Foundation

/// Narrow accident guard at the two mutation choke points. This is not an
/// authorization service or a claim that arbitrary workspace code is benign.
/// It prevents a broad workspace from turning a routine project command or a
/// recoverable remove into a machine-wide/home-wide operation.
enum OperationSafety {
    private static var userDataAnchors: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [home] + ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]
            .map { URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent($0).path }
    }

    private static let systemAnchors: Set<String> = [
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes",
        "/bin", "/etc", "/opt", "/private", "/private/etc", "/private/tmp",
        "/private/var", "/sbin", "/tmp", "/usr", "/var",
    ]

    static func isProtectedAnchor(_ path: String) -> Bool {
        matchesAnchor(path, anchors: systemAnchors.union(userDataAnchors))
    }

    // APFS can preserve caller casing while resolving it to the same object.
    // Identity comparison also preserves distinct names on case-sensitive volumes.
    private static func matchesAnchor(_ path: String, anchors: Set<String>) -> Bool {
        if anchors.contains(path) { return true }
        var source = stat()
        guard lstat(path, &source) == 0 else { return false }
        return anchors.contains { anchor in
            var target = stat()
            return lstat(anchor, &target) == 0
                && source.st_dev == target.st_dev && source.st_ino == target.st_ino
        }
    }

    static func validateRecoverableRemoval(
        target: URL,
        workspace: RegisteredLocalWorkspace
    ) throws {
        let path = target.standardizedFileURL.path
        guard !matchesAnchor(path, anchors: [workspace.rootURL.standardizedFileURL.path]),
              !isProtectedAnchor(path) else {
            throw LocalMCPError.invalidPath(
                "protected root cannot be removed; select a narrower child path"
            )
        }
    }

    static func validateRelocation(
        source: URL,
        workspace: RegisteredLocalWorkspace,
        additionalProtectedPaths: Set<String> = []
    ) throws {
        let path = source.standardizedFileURL.path
        guard !matchesAnchor(path, anchors: [workspace.rootURL.standardizedFileURL.path]),
              !isProtectedAnchor(path), !matchesAnchor(path, anchors: additionalProtectedPaths) else {
            throw LocalMCPError.invalidPath(
                "protected root cannot be moved; select a narrower child path"
            )
        }
    }

    /// Narrow/bounded workspaces keep their normal project-wide command scope.
    /// A broad root (or a configured top-level data folder) is different: the
    /// command receives only its explicit cwd subtree. The caller can still work
    /// anywhere by choosing a specific project/folder, but not use `/` or the
    /// account home as an implicit machine-wide command sandbox.
    static func commandScope(
        workspace: RegisteredLocalWorkspace,
        workingDirectory: URL
    ) throws -> URL {
        let root = workspace.rootURL.standardizedFileURL.path
        guard workspace.allowsBroadAccess || isProtectedAnchor(root) else {
            return workspace.rootURL
        }
        let cwd = workingDirectory.standardizedFileURL.path
        guard !isProtectedAnchor(cwd) else {
            throw LocalMCPError.invalidPath(
                "broad commands require an explicit cwd below a project or task folder"
            )
        }
        return workingDirectory
    }
}
