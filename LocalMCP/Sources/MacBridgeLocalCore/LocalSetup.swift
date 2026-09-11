import Darwin
import Foundation

/// Explicit, on-device first-run provisioning. This is not an MCP action and
/// never starts a process, installs a service, reads credentials or overwrites
/// a registry. A client still needs its own reviewed connection configuration.
public struct LocalSetupPlan: Sendable {
    public let configuration: LocalWorkspaceConfiguration
    public let configurationPath: String
    public let observerDirectory: String
    public let executablePath: String
    private let homePath: String

    public init(workspaceURL: URL, executableURL: URL,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let home = try canonicalExistingPath(homeDirectory.path)
        let homeStatus = try lstatValue(home)
        guard homeStatus.st_mode & S_IFMT == S_IFDIR, homeStatus.st_uid == getuid(),
              homeStatus.st_mode & 0o022 == 0 else {
            throw LocalMCPError.invalidConfiguration("setup requires an owned, non-writable-by-others home directory")
        }
        let rootStatus = try lstatValue(workspaceURL.path)
        let root = try canonicalExistingPath(workspaceURL.path)
        guard rootStatus.st_mode & S_IFMT == S_IFDIR, root != home,
              !home.hasPrefix(root + "/"), root != "/" else {
            throw LocalMCPError.invalidConfiguration("choose a project folder, not an account home or whole disk")
        }
        let executable = try Self.validatedBundledExecutable(executableURL)
        homePath = home
        configurationPath = home + "/.config/macbridge/workspaces.json"
        observerDirectory = home + "/.config/macbridge/observer"
        executablePath = executable
        guard (observerDirectory + "/observer.sock").utf8.count <= 103 else {
            throw LocalMCPError.invalidConfiguration("default observer path is too long; use an explicitly configured short private directory")
        }
        configuration = LocalWorkspaceConfiguration(workspaces: [
            LocalWorkspaceConfigurationEntry(id: UUID().uuidString.lowercased(),
                name: String(workspaceURL.lastPathComponent.prefix(64)), path: root)
        ])
        // This initializer performs exactly the owner's credential, symlink,
        // broad-root, count and identity checks without touching disk.
        _ = try LocalWorkspaceRegistry(configuration: configuration)
    }

    public var clientConfiguration: String {
        get throws {
            let value: [String: Any] = ["mcpServers": ["MacBridge": [
                "command": executablePath,
                "args": ["--config", configurationPath, "--observer-directory", observerDirectory]
            ]]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    public func createConfiguration() throws {
        // The app may have moved while the owner reviewed the proposal. Reject
        // a stale/missing core before creating even a configuration directory,
        // so fixing its location leaves the original plan safely retryable.
        // This validates the local path, not publisher identity or a signature;
        // the client still owns the later decision to start the executable.
        _ = try Self.validatedBundledExecutable(URL(fileURLWithPath: executablePath))
        // Revalidate selected scope immediately before any write. Existing
        // symlinks are never traversed by the destination directory walk.
        _ = try LocalWorkspaceRegistry(configuration: configuration)
        let homeFD = open(homePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard homeFD >= 0 else { throw setupError("cannot open the owned home directory") }
        defer { close(homeFD) }
        try validateDirectory(homeFD, privateOnly: false)
        let configFD = try childDirectory(".config", parent: homeFD, privateOnly: false)
        defer { close(configFD) }
        let bridgeFD = try childDirectory("macbridge", parent: configFD, privateOnly: true)
        defer { close(bridgeFD) }
        var existing = stat()
        guard fstatat(bridgeFD, "workspaces.json", &existing, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw setupError("workspace configuration already exists; setup will not replace it")
        }
        let observerFD = try childDirectory("observer", parent: bridgeFD, privateOnly: true)
        defer { close(observerFD) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        let temporary = ".setup-" + UUID().uuidString.lowercased()
        let descriptor = openat(bridgeFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw setupError("cannot reserve a new private configuration") }
        defer {
            close(descriptor)
            // Only the exact new temporary leaf is removed. Existing files,
            // credentials, sockets and recovery records are never deleted.
            unlinkat(bridgeFD, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw setupError("could not finish writing the new configuration") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw setupError("could not sync the new configuration") }
        // Atomic, no-replace publication. A second setup/client racing us wins
        // without having its data overwritten; our temporary leaf is removed.
        guard renameatx_np(bridgeFD, temporary, bridgeFD, "workspaces.json", UInt32(RENAME_EXCL)) == 0 else {
            throw setupError("configuration appeared or changed during setup; nothing was overwritten")
        }
        guard fsync(bridgeFD) == 0 else {
            throw setupError("configuration was created, but directory sync failed; inspect it before continuing")
        }
    }

    private static func validatedBundledExecutable(_ url: URL) throws -> String {
        let executable = url.path
        guard executable.hasPrefix("/"),
              executable.hasSuffix("/MacBridge.app/Contents/MacOS/macbridge-mcp"),
              !executable.hasPrefix("/Volumes/"), !executable.contains("/AppTranslocation/"),
              !executable.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw LocalMCPError.invalidConfiguration("move MacBridge.app to a permanent Applications folder before setup")
        }
        let status = try lstatValue(executable)
        guard status.st_mode & S_IFMT == S_IFREG, status.st_mode & 0o111 != 0,
              try canonicalExistingPath(executable) == executable else {
            throw LocalMCPError.invalidConfiguration("the bundled MacBridge core is missing, not executable or is a symlink")
        }
        return executable
    }

    private func childDirectory(_ name: String, parent: Int32, privateOnly: Bool) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw setupError("cannot create the private configuration directory")
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw setupError("refusing a missing, symlink or inaccessible configuration directory") }
        do { try validateDirectory(descriptor, privateOnly: privateOnly) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private func validateDirectory(_ descriptor: Int32, privateOnly: Bool) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == getuid(), value.st_mode & (privateOnly ? 0o077 : 0o022) == 0 else {
            throw setupError("existing configuration directories have unexpected ownership or permissions; setup will not change them")
        }
    }

    private func setupError(_ message: String) -> LocalMCPError {
        .invalidConfiguration(message)
    }
}
