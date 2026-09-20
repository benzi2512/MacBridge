import Darwin
import Foundation

/// Narrow accident guard at the two mutation choke points. This is not an
/// authorization service or a claim that arbitrary workspace code is benign.
/// It prevents a broad workspace from turning a routine project command or a
/// recoverable remove into a machine-wide/home-wide operation.
enum OperationSafety {
    struct CommandScopePolicy {
        let rootURL: URL
        let readOnly: Bool
    }

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

    /// Refuse any mutation of a protected object or a directory that contains it.
    /// The identity walk also catches alternate casing on case-insensitive APFS.
    static func validateMutationTarget(_ target: URL, protectedPaths: Set<String>) throws {
        guard !protectedPaths.isEmpty else { return }
        let targetPath = target.standardizedFileURL.path
        var targetStatus = stat()
        let targetExists = lstat(targetPath, &targetStatus) == 0
        for protectedPath in protectedPaths {
            let protected = URL(fileURLWithPath: protectedPath).standardizedFileURL
            let protectedValue = protected.path
            if targetPath == protectedValue
                || protectedValue.hasPrefix(targetPath == "/" ? "/" : targetPath + "/") {
                throw LocalMCPError.sensitivePathBlocked
            }
            guard targetExists else { continue }
            var ancestor = protected
            while true {
                var ancestorStatus = stat()
                if lstat(ancestor.path, &ancestorStatus) == 0,
                   ancestorStatus.st_dev == targetStatus.st_dev,
                   ancestorStatus.st_ino == targetStatus.st_ino {
                    throw LocalMCPError.sensitivePathBlocked
                }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
    }

    /// Narrow/bounded workspaces keep their normal project-wide command scope.
    /// A broad root (or a configured top-level data folder) is different: the
    /// command receives only its explicit cwd subtree. The caller can still work
    /// anywhere by choosing a specific project/folder, but not use `/` or the
    /// account home as an implicit machine-wide command sandbox.
    static func commandScopePolicy(
        workspace: RegisteredLocalWorkspace,
        workingDirectory: URL
    ) throws -> CommandScopePolicy {
        let root = workspace.rootURL.standardizedFileURL.path
        guard workspace.allowsBroadAccess || isProtectedAnchor(root) else {
            return CommandScopePolicy(rootURL: workspace.rootURL, readOnly: false)
        }
        let cwd = workingDirectory.standardizedFileURL.path
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL.path
        // A caller may explicitly inspect the Downloads root, but that broad
        // user-data anchor must never become a command-writable workspace.
        if matchesAnchor(cwd, anchors: [downloads]) {
            return CommandScopePolicy(rootURL: workingDirectory, readOnly: true)
        }
        guard !isProtectedAnchor(cwd) else {
            throw LocalMCPError.invalidPath(
                "broad commands require an explicit cwd below a project or task folder"
            )
        }
        return CommandScopePolicy(rootURL: workingDirectory, readOnly: false)
    }

    static func commandScope(
        workspace: RegisteredLocalWorkspace,
        workingDirectory: URL
    ) throws -> URL {
        try commandScopePolicy(
            workspace: workspace, workingDirectory: workingDirectory
        ).rootURL
    }
}
