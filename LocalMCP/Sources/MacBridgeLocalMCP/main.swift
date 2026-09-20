import Darwin
import Foundation
import MacBridgeLocalCore

let arguments = Array(CommandLine.arguments.dropFirst())

private func failUsage() -> Never {
    FileHandle.standardError.write(
        Data(
            ("usage: macbridge-mcp [--config /absolute/path/workspaces.json] "
                + "[--surface desktop-local|web-tunnel] [--observer-directory /private/owned/directory]\n").utf8
        )
    )
    exit(64)
}

if arguments.first == "--runner-child" {
    LocalRunnerChild.execute(arguments: Array(arguments.dropFirst()))
}
if arguments.first == "--runner-child-direct" {
    LocalRunnerChild.execute(arguments: Array(arguments.dropFirst()), supervised: false)
}

if arguments == ["--version"] {
    print(LocalMCPServer.version)
    exit(0)
}

var configurationURL = LocalWorkspaceRegistry.defaultConfigurationURL
var connectorSurface = MacBridgeConnectorSurface.desktopLocal
var configurationWasSet = false
var surfaceWasSet = false
var observerDirectory: String?
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--observer-directory":
        if observerDirectory != nil || index + 1 >= arguments.count { failUsage() }
        observerDirectory = arguments[index + 1]
        index += 2
    case "--config":
        if configurationWasSet || index + 1 >= arguments.count { failUsage() }
        configurationURL = URL(fileURLWithPath: arguments[index + 1])
        configurationWasSet = true
        index += 2
    case "--surface":
        if surfaceWasSet || index + 1 >= arguments.count { failUsage() }
        guard let parsed = MacBridgeConnectorSurface(rawValue: arguments[index + 1]) else {
            failUsage()
        }
        connectorSurface = parsed
        surfaceWasSet = true
        index += 2
    default:
        failUsage()
    }
}

do {
    let executable = URL(fileURLWithPath: try canonicalExecutablePath(CommandLine.arguments[0]))
    let server = try LocalMCPServer(
        configurationURL: configurationURL,
        selfExecutable: executable,
        connectorSurface: connectorSurface,
        observationEnabled: observerDirectory != nil
    )
    let observer = try observerDirectory.map { try LocalObserverEndpoint(directory: $0, server: server) }
    defer { observer?.stop() }
    try server.run()
} catch {
    let message: String
    if let local = error as? LocalMCPError {
        message = local.description
    } else {
        message = "MacBridge direct-local startup failed."
    }
    FileHandle.standardError.write(Data("MACBRIDGE_LOCAL_STARTUP_FAIL \(message)\n".utf8))
    exit(78)
}

private func canonicalExecutablePath(_ path: String) throws -> String {
    let candidate: String
    if path.hasPrefix("/") {
        candidate = path
    } else {
        candidate =
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).path
    }
    guard let pointer = realpath(candidate, nil) else {
        throw LocalMCPError.operationFailed("cannot resolve executable path")
    }
    defer { free(pointer) }
    return String(cString: pointer)
}
