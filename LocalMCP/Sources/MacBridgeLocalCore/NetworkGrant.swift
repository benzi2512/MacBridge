import Darwin
import Foundation

/// An owner-authored, expiring grant for one workspace, cwd and public IPv4:port.
/// IP pinning is deliberately NOT described as HTTPS hostname filtering: a
/// shared destination IP can serve multiple hosts. The child can only contact
/// its ephemeral authenticated loopback relay, which pins this TCP destination.
/// No system proxy, DNS, private/LAN egress or persistent listener is enabled.
public struct LocalNetworkGrant: Codable, Equatable, Sendable {
    public let id: String
    public let cwd: String
    public let ipv4: String
    public let port: Int
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, cwd, ipv4, port
        case expiresAt = "expires_at"
    }

    public init(id: String, cwd: String, ipv4: String, port: Int, expiresAt: Date) {
        self.id = id; self.cwd = cwd; self.ipv4 = ipv4; self.port = port; self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cwd = try container.decode(String.self, forKey: .cwd)
        ipv4 = try container.decode(String.self, forKey: .ipv4)
        port = try container.decode(Int.self, forKey: .port)
        let raw = try container.decode(String.self, forKey: .expiresAt)
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw LocalMCPError.invalidConfiguration("network grant requires an ISO-8601 expires_at")
        }
        expiresAt = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(cwd, forKey: .cwd)
        try container.encode(ipv4, forKey: .ipv4); try container.encode(port, forKey: .port)
        try container.encode(ISO8601DateFormatter().string(from: expiresAt), forKey: .expiresAt)
    }

    func validateShape() throws {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard UUID(uuidString: id) != nil, (1...65535).contains(port),
              !cwd.isEmpty, cwd.utf8.count <= 4096, !cwd.contains("\0"),
              parts.count == 4, parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy({ $0.isASCII && $0.isNumber })
                  && (part == "0" || !part.hasPrefix("0"))
                  && UInt8(part) != nil
              }) else { throw LocalMCPError.invalidConfiguration("invalid network grant") }
        let bytes = parts.map { UInt8($0)! }
        guard (1...223).contains(bytes[0]), ![10, 127].contains(bytes[0]),
              !(bytes[0] == 169 && bytes[1] == 254),
              !(bytes[0] == 172 && (16...31).contains(bytes[1])),
              !(bytes[0] == 192 && bytes[1] == 168),
              !(bytes[0] == 100 && (64...127).contains(bytes[1])),
              !(bytes[0] == 198 && (18...19).contains(bytes[1])) else {
            throw LocalMCPError.invalidConfiguration("network grant must name one public unicast IPv4 address, not a private or special destination")
        }
    }

    func remainingSeconds(now: Date = Date()) throws -> TimeInterval {
        try validateShape()
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0, seconds <= 3600 else {
            throw LocalMCPError.operationFailed("network grant is expired or more than one hour ahead; owner approval is required")
        }
        return seconds
    }

    static func sandboxRule(proxyPort: UInt16) -> String {
        "(allow network-outbound (remote tcp \"localhost:\(proxyPort)\"))"
    }

    static func resolve(id: String, workspace: RegisteredLocalWorkspace,
                        service: LocalWorkspaceService) throws -> LocalNetworkGrant {
        guard let grant = workspace.networkGrants.first(where: { $0.id == id }) else {
            throw LocalMCPError.operationFailed("no owner-approved network grant with this ID exists in this workspace")
        }
        _ = try grant.remainingSeconds()
        let url = try service.workspaceURL(workspaceID: workspace.id, relativePath: grant.cwd)
        _ = try OperationSafety.commandScope(workspace: workspace, workingDirectory: url)
        guard !OperationSafety.isProtectedAnchor(url.path) else {
            throw LocalMCPError.invalidPath("network grant requires a narrow project/task directory")
        }
        return grant
    }
}
