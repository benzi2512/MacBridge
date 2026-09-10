import Darwin
import Foundation

public struct LocalWorkspaceConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let workspaces: [LocalWorkspaceConfigurationEntry]

    public init(version: Int = 1, workspaces: [LocalWorkspaceConfigurationEntry]) {
        self.version = version
        self.workspaces = workspaces
    }
}

public struct LocalWorkspaceConfigurationEntry: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let allowBroadAccess: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, path
        case allowBroadAccess = "allow_broad_access"
    }

    public init(id: String, name: String, path: String, allowBroadAccess: Bool? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.allowBroadAccess = allowBroadAccess
    }
}

public struct RegisteredLocalWorkspace: Equatable, Sendable {
    public let id: String
    public let name: String
    public let rootURL: URL
    public let rootHash: String
    public let allowsBroadAccess: Bool

    public init(
        id: String, name: String, rootURL: URL, rootHash: String,
        allowsBroadAccess: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.rootHash = rootHash
        self.allowsBroadAccess = allowsBroadAccess
    }

    public var json: JSONObject {
        var value: JSONObject = [
            "workspace_id": id,
            "display_name": name,
            "root_hash": rootHash,
            "absolute_paths": true,
        ]
        if allowsBroadAccess {
            value["access_scope"] = "user_filesystem_excluding_credentials"
            value["root_path"] = rootURL.path
        }
        return value
    }
}

public final class LocalWorkspaceRegistry: @unchecked Sendable {
    public static var defaultConfigurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macbridge/workspaces.json")
    }

    private let byID: [String: RegisteredLocalWorkspace]

    public convenience init(configurationURL: URL) throws {
        let path = configurationURL.path
        let status = try lstatValue(path)
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == getuid(),
            status.st_nlink == 1,
            status.st_mode & 0o022 == 0
        else {
            throw LocalMCPError.invalidConfiguration(
                "configuration must be a current-user regular file that is not group/other writable"
            )
        }
        // Preserve trusted ancestor aliases such as /var -> /private/var, but
        // never follow a replaced leaf or memory-map mutable configuration.
        let parent = try canonicalExistingPath(configurationURL.deletingLastPathComponent().path)
        let safeURL = URL(fileURLWithPath: parent).appendingPathComponent(configurationURL.lastPathComponent)
        let data = try LocalFileReader.withFile(url: safeURL) { descriptor in
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == status.st_dev,
                  opened.st_ino == status.st_ino, opened.st_uid == getuid(),
                  opened.st_mode & 0o022 == 0 else {
                throw LocalMCPError.invalidConfiguration("configuration changed while opening")
            }
            return try LocalFileReader.read(descriptor: descriptor, maximumBytes: 1_048_576)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let configuration = try decoder.decode(LocalWorkspaceConfiguration.self, from: data)
        try self.init(configuration: configuration)
    }

    /// Validates an explicit configuration without writing it or granting a
    /// client access. First-run setup uses the same scope checks as the owner.
    public init(configuration: LocalWorkspaceConfiguration) throws {
        guard configuration.version == 1,
            !configuration.workspaces.isEmpty,
            configuration.workspaces.count <= 64
        else { throw LocalMCPError.invalidConfiguration("unsupported version or workspace count") }

        let home = try? canonicalExistingPath(FileManager.default.homeDirectoryForCurrentUser.path)
        let protectedRoots: [String] =
            home.map { home in
                [
                    "\(home)/.ssh",
                    "\(home)/.gnupg",
                    "\(home)/.aws",
                    "\(home)/.azure",
                    "\(home)/.kube",
                    "\(home)/Library/Keychains",
                    "\(home)/Library/Safari",
                    "\(home)/Library/Containers/com.apple.Safari",
                    "\(home)/Library/Application Support/Google/Chrome",
                    "\(home)/Library/Application Support/Chromium",
                    "\(home)/Library/Application Support/BraveSoftware",
                    "\(home)/Library/Application Support/Firefox",
                ]
            } ?? []
        var values: [String: RegisteredLocalWorkspace] = [:]
        for entry in configuration.workspaces {
            guard let uuid = UUID(uuidString: entry.id),
                !entry.name.isEmpty, entry.name.utf8.count <= 128,
                entry.path.hasPrefix("/"), entry.path.utf8.count <= 4_096
            else { throw LocalMCPError.invalidConfiguration("invalid workspace entry") }
            let id = uuid.uuidString.lowercased()
            guard values[id] == nil else {
                throw LocalMCPError.invalidConfiguration("duplicate workspace id")
            }
            let rootStatus = try lstatValue(entry.path)
            let standardized = URL(fileURLWithPath: entry.path).standardizedFileURL.path
            let canonical = try canonicalExistingPath(entry.path)
            let isAncestorOfHome = home.map { $0.hasPrefix(canonical + "/") } ?? false
            let overlapsProtectedRoot = protectedRoots.contains { protected in
                canonical == protected || canonical.hasPrefix(protected + "/")
                    || protected.hasPrefix(canonical + "/")
            }
            guard rootStatus.st_mode & S_IFMT == S_IFDIR,
                // Foundation may standardize existing /private/tmp paths to
                // /tmp. The exact realpath spelling is valid too; neither
                // alternative accepts traversal or a symlink workspace leaf.
                (standardized == entry.path || canonical == entry.path),
                !LocalFilesystemAccess.isSensitive(canonical),
                entry.allowBroadAccess == true
                    || (canonical != "/" && canonical != home
                        && !isAncestorOfHome && !overlapsProtectedRoot)
            else {
                throw LocalMCPError.invalidConfiguration(
                    "workspace must be a non-symlink directory; broad roots require explicit allow_broad_access"
                )
            }
            let rootURL = URL(fileURLWithPath: canonical, isDirectory: true)
            values[id] = RegisteredLocalWorkspace(
                id: id,
                name: entry.name,
                rootURL: rootURL,
                rootHash: LocalHash.sha256(Data(canonical.utf8)),
                allowsBroadAccess: entry.allowBroadAccess == true
            )
        }
        byID = values
    }

    public var workspaces: [RegisteredLocalWorkspace] {
        byID.values.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.id < rhs.id : lhs.name < rhs.name
        }
    }

    public func workspace(id rawID: String) throws -> RegisteredLocalWorkspace {
        guard let uuid = UUID(uuidString: rawID),
            let value = byID[uuid.uuidString.lowercased()]
        else { throw LocalMCPError.unknownWorkspace }
        return value
    }
}
