import Darwin
import Foundation

public enum MacBridgeConnectorSurface: String, Sendable {
    case desktopLocal = "desktop-local"
    case webTunnel = "web-tunnel"

    var capabilityName: String {
        switch self {
        case .desktopLocal: "CHATGPT_DESKTOP_LOCAL"
        case .webTunnel: "CHATGPT_WEB_TUNNEL"
        }
    }

    var transportName: String {
        switch self {
        case .desktopLocal: "local_stdio"
        case .webTunnel: "outbound_tunnel_stdio"
        }
    }

    var runtimeProfile: String {
        switch self {
        case .desktopLocal: "direct-local"
        case .webTunnel: "web-tunnel-adapter"
        }
    }

    var runtimeArchitecture: String {
        switch self {
        case .desktopLocal: "single_process"
        case .webTunnel: "single_process_core_plus_outbound_adapter"
        }
    }

    var connectorNetwork: String {
        switch self {
        case .desktopLocal: "none"
        case .webTunnel: "outbound_tunnel_only"
        }
    }

    var instructions: String {
        switch self {
        case .desktopLocal:
            "Direct local MCP. File and process actions stay inside configured workspaces; commands have loopback-only networking and open no Terminal window."
        case .webTunnel:
            "MacBridge functional core behind an outbound Web tunnel adapter. File and process actions stay inside configured workspaces; commands have loopback-only networking and open no Terminal window."
        }
    }
}

public final class LocalMCPServer: @unchecked Sendable {
    public static let version = "0.4.0-feedback-hardening"
    public static let maximumFrameBytes = 24 * 1_024 * 1_024
    public static let supportedProtocolVersions = [
        "2026-07-28", "2025-11-25", "2025-06-18",
    ]
    private static var protocolCapabilities: JSONObject {
        ["tools": ["listChanged": true], "resources": ["listChanged": false]]
    }

    private var workspaceService: LocalWorkspaceService
    private var processService: LocalProcessService
    private let configurationURL: URL
    private let selfExecutable: URL
    private let connectorSurface: MacBridgeConnectorSurface
    // Snapshot the executable path once for this server lifetime. Replacing that
    // path during an upgrade must not relabel an already-running instance.
    private let executableHash: String
    private let instanceID = UUID().uuidString.lowercased()
    private let startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var initializeResponded = false
    private var initialized = false
    private var negotiatedProtocol = "2025-06-18"

    /// Changes whenever either the serving process or typed catalog changes.
    /// Hosts must invalidate callable-schema caches when this value changes.
    private var bindingEpoch: String {
        LocalHash.sha256(Data("\(instanceID):\(catalogDigest)".utf8))
    }
    private let operationLock = NSRecursiveLock()
    private let outputLock = NSLock()
    // Web-tunnel conversations intentionally share one runtime, but a public
    // UUID is only a locator. These bearer capabilities are returned only to
    // the creator and are never retained in activity/list responses.
    private let capabilityLock = NSLock()
    private var processControlTokens: [String: String] = [:]
    private var transactionControlTokens: [String: String] = [:]
    private var workControlTokens: [String: String] = [:]
    private var searchInProgress = false
    private static let maximumConcurrentCommandRuns = 8
    private var activeCommandRuns = 0
    private static let maximumConcurrentDeveloperInspections = 8
    private var activeDeveloperInspections = 0
    private static let maximumConcurrentProcessWaits = 8
    private var activeProcessWaits = 0
    // One admitted Brevo operation across the whole family, including direct
    // callTool callers. Protected by operationLock, never held across HTTP.
    private var brevoInProgress = false
    private var mediaInProgress = false
    private let mediaConfigurationURL: URL
    private let mediaTransportForTesting: MediaShareTransport.Perform?
    // Immutable test instrumentation; public/runtime initialization always uses
    // nil. There is no CLI, config, environment or MCP path that installs it.
    private let searchStartForTesting: (@Sendable () -> Void)?
    private let developerInspectionStartForTesting: (@Sendable () -> Void)?
    private let processWaitStartForTesting: (@Sendable () -> Void)?
    // Immutable offline-test dependency only; never configurable by MCP, CLI or environment.
    private let brevoTransportForTesting: BrevoOperations.Transport?
    private let desktopPresenterForTesting: DesktopOpen.Presenter?
    private let observerLock = NSLock()
    private var observerHistory: [JSONObject] = []
    private var observerCached: JSONObject = [:]
    private let workActivity = WorkActivity()
    private let requestIdentityProbe = RequestIdentityProbe()
    // Fixed-size diagnostics only: never retain a requested URI, _meta, HTML,
    // credentials or other request payload. Protected by observerLock.
    private var uiResourceReadCount = 0
    private var uiResourceReadOutcome = "not_requested"
    private let observationEnabled: Bool
    public convenience init(
        configurationURL: URL,
        selfExecutable: URL,
        connectorSurface: MacBridgeConnectorSurface = .desktopLocal,
        observationEnabled: Bool = false
    ) throws {
        try self.init(configurationURL: configurationURL, selfExecutable: selfExecutable,
                      connectorSurface: connectorSurface, observationEnabled: observationEnabled,
                      searchStartForTesting: nil)
    }

    init(configurationURL: URL, selfExecutable: URL,
         connectorSurface: MacBridgeConnectorSurface = .desktopLocal,
         observationEnabled: Bool = false,
         searchStartForTesting: (@Sendable () -> Void)?,
         brevoTransportForTesting: BrevoOperations.Transport? = nil,
         desktopPresenterForTesting: DesktopOpen.Presenter? = nil,
         mediaConfigurationURLForTesting: URL? = nil,
         mediaTransportForTesting: MediaShareTransport.Perform? = nil,
         developerInspectionStartForTesting: (@Sendable () -> Void)? = nil,
         processWaitStartForTesting: (@Sendable () -> Void)? = nil,
         workspaceServiceForTesting: LocalWorkspaceService? = nil) throws {
        let canonicalExecutable = URL(fileURLWithPath: try canonicalExistingPath(selfExecutable.path))
        let canonicalExecutableHash = try LocalHash.sha256(fileAt: canonicalExecutable)
        self.mediaConfigurationURL = mediaConfigurationURLForTesting ?? MediaShareConfiguration.defaultURL
        self.mediaTransportForTesting = mediaTransportForTesting
        self.searchStartForTesting = searchStartForTesting
        self.developerInspectionStartForTesting = developerInspectionStartForTesting
        self.processWaitStartForTesting = processWaitStartForTesting
        self.brevoTransportForTesting = brevoTransportForTesting
        self.desktopPresenterForTesting = desktopPresenterForTesting
        self.observationEnabled = observationEnabled
        // The configured executable may use a trusted installation alias (for
        // example SwiftPM's debug symlink); workspace readers never resolve aliases.
        executableHash = canonicalExecutableHash
        let registry = try LocalWorkspaceRegistry(configurationURL: configurationURL)
        let workspaceService = workspaceServiceForTesting ?? LocalWorkspaceService(
            registry: registry,
            protectedMutationPaths: [canonicalExecutable.path]
        )
        self.workspaceService = workspaceService
        processService = LocalProcessService(
            workspaceService: workspaceService,
            selfExecutable: canonicalExecutable
        )
        self.configurationURL = configurationURL
        self.selfExecutable = canonicalExecutable
        self.connectorSurface = connectorSurface
    }

    public func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) throws {
        let responses = PendingToolResponses()
        defer { responses.group.wait() }
        var buffer = Data()
        var scannedBytes = 0
        var discardingOversizedFrame = false
        var readBuffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let byteCount = readBuffer.withUnsafeMutableBytes { bytes in
                Darwin.read(input.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount == 0 { break }
            if byteCount < 0 {
                if errno == EINTR { continue }
                throw LocalMCPError.operationFailed("stdio read failed")
            }
            let chunk = Data(readBuffer.prefix(byteCount))
            buffer.append(chunk)
            while true {
                let searchStart = buffer.index(
                    buffer.startIndex,
                    offsetBy: min(scannedBytes, buffer.count)
                )
                if let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                    if discardingOversizedFrame {
                        buffer.removeSubrange(...newline)
                        scannedBytes = 0
                        discardingOversizedFrame = false
                        continue
                    }
                    let frame = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    scannedBytes = 0
                    if frame.isEmpty { continue }
                    if frame.count > Self.maximumFrameBytes {
                        try write(
                            rpcError(
                                id: NSNull(), code: -32_600,
                                message: "JSON-RPC frame too large."
                            ),
                            to: output
                        )
                        continue
                    }
                    try processFrame(Data(frame), output: output, responses: responses)
                    continue
                }
                if discardingOversizedFrame {
                    buffer.removeAll(keepingCapacity: true)
                    scannedBytes = 0
                } else if buffer.count > Self.maximumFrameBytes {
                    try write(
                        rpcError(
                            id: NSNull(), code: -32_600,
                            message: "JSON-RPC frame too large."
                        ),
                        to: output
                    )
                    buffer.removeAll(keepingCapacity: true)
                    scannedBytes = 0
                    discardingOversizedFrame = true
                } else {
                    scannedBytes = buffer.count
                }
                break
            }
        }
        if !discardingOversizedFrame, !buffer.isEmpty {
            try processFrame(buffer, output: output, responses: responses)
        }
        responses.group.wait()
        if responses.writeFailed {
            throw LocalMCPError.operationFailed("background tool response output failed")
        }
    }

    public func handle(_ message: JSONObject) -> JSONObject? {
        let isNotification = message["id"] == nil
        let id = message["id"] ?? NSNull()
        var resourceOutcome = "invalid_request"
        defer {
            if observationEnabled, message["method"] as? String == "resources/read" {
                observerLock.lock()
                if uiResourceReadCount < Int.max { uiResourceReadCount += 1 }
                uiResourceReadOutcome = resourceOutcome
                observerLock.unlock()
            }
        }
        do {
            try message.requireOnlyKeys(["jsonrpc", "id", "method", "params"])
            guard message["jsonrpc"] as? String == "2.0",
                let method = message["method"] as? String, !method.isEmpty
            else { throw LocalMCPError.invalidRequest("Invalid JSON-RPC request.") }
            switch method {
            case "initialize":
                let params = try object(message["params"], label: "initialize params")
                try params.requireOnlyKeys([
                    "protocolVersion", "capabilities", "clientInfo", "_meta",
                ])
                let requested = try params.requiredString("protocolVersion", maximumBytes: 32)
                guard params["capabilities"] is JSONObject,
                    params["clientInfo"] is JSONObject
                else { throw LocalMCPError.invalidRequest("MCP client identity is required.") }
                negotiatedProtocol =
                    Self.supportedProtocolVersions.contains(requested)
                    ? requested : "2025-11-25"
                initializeResponded = true
                return rpcSuccess(
                    id: id,
                    result: [
                        "protocolVersion": negotiatedProtocol,
                        "serverInfo": ["name": "macbridge-local", "version": Self.version],
                        "capabilities": Self.protocolCapabilities,
                        "instructions": connectorSurface.instructions + " " + Self.discoveryGuide,
                        "catalogEpoch": catalogDigest,
                        "bindingEpoch": bindingEpoch,
                    ]
                )
            case "notifications/initialized":
                guard initializeResponded else {
                    throw LocalMCPError.invalidRequest("Initialize first.")
                }
                initialized = true
                return nil
            case "server/discover":
                return rpcSuccess(
                    id: id,
                    result: [
                        "mode": "CHATGPT_FULL",
                        "supportedVersions": Self.supportedProtocolVersions,
                        "ttlMs": 0,
                        "cacheScope": "private",
                        "catalogEpoch": catalogDigest,
                        "bindingEpoch": bindingEpoch,
                        "connection": [
                            "surface": connectorSurface.capabilityName,
                            "transport": connectorSurface.transportName,
                            "publicListener": false,
                        ],
                        "capabilities": Self.protocolCapabilities,
                    ]
                )
            case "ping":
                return rpcSuccess(id: id, result: [:])
            case "resources/list":
                try requireInitializedForCurrentSurface()
                return rpcSuccess(id: id, result: ["resources": ActivityWidget.resourceDescriptors])
            case "resources/read":
                try requireInitializedForCurrentSurface()
                let params = try object(message["params"], label: "resource params")
                try params.requireOnlyKeys(["uri", "_meta"])
                let uri = try params.requiredString("uri", maximumBytes: 256)
                guard let contents = ActivityWidget.resourceContents(for: uri) else {
                    resourceOutcome = "unknown_uri"
                    return rpcError(id: id, code: -32_002, message: "Resource not found.")
                }
                resourceOutcome = "response_prepared"
                return rpcSuccess(id: id, result: ["contents": [contents]])
            case "tools/list":
                try requireInitializedForCurrentSurface()
                return rpcSuccess(
                    id: id,
                    result: ["tools": Self.toolSpecs, "catalogEpoch": catalogDigest,
                             "bindingEpoch": bindingEpoch]
                )
            case "tools/call":
                try requireInitializedForCurrentSurface()
                let params = try object(message["params"], label: "tool params")
                try params.requireOnlyKeys(["name", "arguments", "_meta"])
                let name = try params.requiredString("name", maximumBytes: 128)
                let arguments = try object(params["arguments"] ?? [:], label: "tool arguments")
                observeRequestIdentity(name: name, metadata: params["_meta"])
                do {
                    let result = try callTool(name: name, arguments: arguments)
                    return rpcSuccess(id: id, result: toolResult(result,
                        message: resultSummary(name: name, result: result, arguments: arguments),
                        isError: result["isError"] as? Bool == true))
                } catch {
                    return rpcSuccess(
                        id: id,
                        result: toolResult(
                            structuredError(error),
                            message: safeMessage(error),
                            isError: true
                        )
                    )
                }
            case "notifications/cancelled":
                return nil
            default:
                if isNotification { return nil }
                return rpcError(id: id, code: -32_601, message: "Method not found.")
            }
        } catch {
            if isNotification { return nil }
            return rpcError(id: id, code: -32_602, message: safeMessage(error))
        }
    }

    public func callTool(name: String, arguments: JSONObject) throws -> JSONObject {
        // UI reads must neither fill their own activity feed nor wait behind a
        // long synchronous operation. The snapshot explicitly marks cached data.
        if name == "bridge_activity_view" || name == "bridge_activity" {
            if name == "bridge_activity_view" {
                try arguments.requireOnlyKeys([])
            } else {
                try arguments.requireOnlyKeys(["instance_id", "task_id", "process_control_token"])
                guard try arguments.requiredString("instance_id", maximumBytes: 36) == instanceID else {
                    throw LocalMCPError.conflict("activity owner changed; open a new activity view")
                }
                if let taskID = try arguments.optionalString("task_id", maximumBytes: 36) {
                    let supplied = try arguments.optionalString("process_control_token", maximumBytes: 96)
                    try requireCapability(supplied, for: taskID, kind: .process, label: "process")
                } else if arguments["process_control_token"] != nil {
                    throw LocalMCPError.invalidRequest(
                        "process_control_token requires task_id"
                    )
                }
            }
            return try activitySnapshot(taskID: arguments.optionalString("task_id", maximumBytes: 36))
        }
        if name == "work_task" {
            return try manageWorkTask(arguments)
        }
        var effectiveArguments = try authorizeAndStripTransactionControl(
            name: name, arguments: arguments
        )
        var createdDeveloperWorkID: String?
        var createdDeveloperWorkToken: String?
        if name == "developer_task" {
            let action = try effectiveArguments.requiredString("action", maximumBytes: 32)
            if action == "execute_task" || action == "run_tests" {
                let title = try effectiveArguments.optionalString("title", maximumBytes: 640)
                    ?? (action == "run_tests" ? "Run project tests" : "Execute developer task")
                var begin: JSONObject = [
                    "action": "begin", "title": title,
                    "workspace_id": try effectiveArguments.requiredString("workspace_id", maximumBytes: 36),
                ]
                if let label = try effectiveArguments.optionalString("chat_label", maximumBytes: 640) {
                    begin["chat_label"] = label
                }
                let started: JSONObject = try {
                    operationLock.lock()
                    defer { operationLock.unlock() }
                    return try workActivity.manage(
                        begin,
                        validWorkspaces: Set(workspaceService.registry.workspaces.map { $0.id.lowercased() }),
                        jobs: processService.processList()["processes"] as? [JSONObject] ?? []
                    )
                }()
                guard let id = started["work_id"] as? String else {
                    throw LocalMCPError.operationFailed("developer parent was not retained")
                }
                effectiveArguments["work_id"] = id
                let token = registerCapability(for: id, kind: .work)
                effectiveArguments["work_control_token"] = token
                createdDeveloperWorkID = id
                createdDeveloperWorkToken = token
            } else if action == "continue_task" {
                effectiveArguments["work_id"] = try effectiveArguments.requiredString(
                    "workflow_id", maximumBytes: 36
                ).lowercased()
            }
        }
        effectiveArguments = try authorizeAndStripWorkControl(
            name: name, arguments: effectiveArguments
        )
        effectiveArguments = try authorizeAndStripProcessControl(
            name: name, arguments: effectiveArguments
        )
        let workID = try workActivity.beginCall(name: name, arguments: effectiveArguments)
        var prepared = effectiveArguments
        prepared.removeValue(forKey: "work_id")
        let transactionsBefore = Self.transactionCreatingTools.contains(name)
            ? workspaceService.retainedTransactionIDs() : []
        do {
            var result = try observedTool(
                name: name, arguments: effectiveArguments, workID: workID
            ) {
                try callPreparedTool(name: name, arguments: prepared, workID: workID)
            }
            if createsControllableProcess(name: name, arguments: prepared),
               let taskID = result["task_id"] as? String {
                result["process_control_token"] = registerCapability(
                    for: taskID, kind: .process
                )
            }
            if Self.transactionCreatingTools.contains(name) {
                workspaceService.associateTransactions(transactionIDs(in: result), workID: workID)
                if let workID { result["work_id"] = workID }
                result = protectNewTransactions(in: result)
            }
            if let createdDeveloperWorkToken {
                result["work_control_token"] = createdDeveloperWorkToken
            }
            if name == "developer_task", result["workflow_terminal"] as? Bool == true,
               let id = workID, let status = result["workflow_terminal_status"] as? String {
                operationLock.lock()
                defer { operationLock.unlock() }
                _ = try workActivity.manage(
                    ["action": "finish", "work_id": id, "status": status],
                    validWorkspaces: Set(workspaceService.registry.workspaces.map { $0.id.lowercased() }),
                    jobs: processService.processList()["processes"] as? [JSONObject] ?? []
                )
                removeCapability(for: id, kind: .work)
            }
            if name == "transaction_restore", let id = effectiveArguments["transaction_id"] as? String {
                removeCapability(for: id, kind: .transaction)
            } else if name == "transaction_accept",
                      let ids = effectiveArguments["transaction_ids"] as? [String] {
                for id in ids { removeCapability(for: id, kind: .transaction) }
            }
            return result
        } catch {
            var surfacedError: Error = error
            if Self.transactionCreatingTools.contains(name) {
                let newTransactions = workspaceService.retainedTransactionIDs()
                    .subtracting(transactionsBefore).sorted()
                if !newTransactions.isEmpty {
                    workspaceService.associateTransactions(newTransactions, workID: workID)
                    let receipts: [RecoveryTransactionReceipt] = newTransactions.map { id in
                        RecoveryTransactionReceipt(
                            instanceID: instanceID,
                            transactionID: id,
                            transactionControlToken: registerCapability(
                                for: id, kind: .transaction
                            )
                        )
                    }
                    surfacedError = LocalMCPError.recoveryRequired(
                        safeMessage(error), recoveryTransactions: receipts
                    )
                }
            }
            if let id = createdDeveloperWorkID {
                operationLock.lock()
                defer { operationLock.unlock() }
                _ = try? workActivity.manage(
                    ["action": "finish", "work_id": id, "status": "failed"],
                    validWorkspaces: Set(workspaceService.registry.workspaces.map { $0.id.lowercased() }),
                    jobs: processService.processList()["processes"] as? [JSONObject] ?? []
                )
                removeCapability(for: id, kind: .work)
            }
            throw surfacedError
        }
    }

    private static let transactionCreatingTools: Set<String> = [
        "file_write", "file_patch", "file_append", "directory_create",
        "path_copy", "path_move", "path_remove", "file_apply_edits", "file_write_many",
        "file_json_patch", "artifact_snapshot",
    ]

    private enum CapabilityKind { case process, transaction, work }

    private func newControlToken(for kind: CapabilityKind) -> String {
        // Transaction capabilities are echoed by the creating normal Chat to
        // resolve one named undo. Keep full UUID entropy but avoid an opaque
        // 64-hex string that host safety classifiers can mistake for a secret.
        // Process/work control remains the stronger legacy bearer format.
        if kind == .transaction { return UUID().uuidString.lowercased() }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func registerCapability(for rawID: String, kind: CapabilityKind) -> String {
        let id = rawID.lowercased()
        let retainedProcessIDs: Set<String>?
        switch kind {
        case .process:
            retainedProcessIDs = Set(
                (processService.processList()["processes"] as? [JSONObject] ?? [])
                    .compactMap { ($0["task_id"] as? String)?.lowercased() }
            )
        case .transaction, .work:
            retainedProcessIDs = nil
        }
        capabilityLock.lock()
        defer { capabilityLock.unlock() }
        if let retainedProcessIDs {
            processControlTokens = processControlTokens.filter {
                retainedProcessIDs.contains($0.key) || $0.key == id
            }
        }
        let existing: String?
        switch kind {
        case .process: existing = processControlTokens[id]
        case .transaction: existing = transactionControlTokens[id]
        case .work: existing = workControlTokens[id]
        }
        if let existing { return existing }
        let token = newControlToken(for: kind)
        switch kind {
        case .process: processControlTokens[id] = token
        case .transaction: transactionControlTokens[id] = token
        case .work: workControlTokens[id] = token
        }
        return token
    }

    private func removeCapability(for rawID: String, kind: CapabilityKind) {
        capabilityLock.lock()
        switch kind {
        case .process: processControlTokens.removeValue(forKey: rawID.lowercased())
        case .transaction: transactionControlTokens.removeValue(forKey: rawID.lowercased())
        case .work: workControlTokens.removeValue(forKey: rawID.lowercased())
        }
        capabilityLock.unlock()
    }

    private func requireCapability(
        _ supplied: String?, for rawID: String, kind: CapabilityKind, label: String
    ) throws {
        guard connectorSurface == .webTunnel else { return }
        capabilityLock.lock()
        let id = rawID.lowercased()
        let expected: String?
        switch kind {
        case .process: expected = processControlTokens[id]
        case .transaction: expected = transactionControlTokens[id]
        case .work: expected = workControlTokens[id]
        }
        capabilityLock.unlock()
        guard let expected, let supplied, timingSafeEqual(expected, supplied) else {
            throw LocalMCPError.conflict(
                "\(label) control capability is missing or invalid; no action performed"
            )
        }
    }

    private func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        let count = max(a.count, b.count)
        for index in 0..<count {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    private func manageWorkTask(_ arguments: JSONObject) throws -> JSONObject {
        let action = try arguments.requiredString("action", maximumBytes: 16)
        var prepared = arguments
        let supplied = try prepared.optionalString("work_control_token", maximumBytes: 96)
        prepared.removeValue(forKey: "work_control_token")
        if action == "update" || action == "finish" {
            let id = try prepared.requiredString("work_id", maximumBytes: 36)
            try requireCapability(supplied, for: id, kind: .work, label: "work")
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        var persistenceVerified = false
        if prepared["scheduler_phase"] as? String == "persisted" {
            let id = try prepared.requiredString("work_id", maximumBytes: 36)
            let workspaceID = try prepared.requiredString("workspace_id", maximumBytes: 36)
            let artifactPath = try prepared.requiredString("artifact_path", maximumBytes: 4_096)
            let artifactSHA = try prepared.requiredString("artifact_sha256", maximumBytes: 64).lowercased()
            let transactionID = try prepared.requiredString("write_transaction_id", maximumBytes: 36)
            try workspaceService.verifyArtifactPersistence(
                workspaceID: workspaceID,
                path: artifactPath,
                sha256: artifactSHA,
                transactionID: transactionID,
                workID: id
            )
            persistenceVerified = true
        }
        var result = try workActivity.manage(prepared,
            validWorkspaces: Set(workspaceService.registry.workspaces.map { $0.id.lowercased() }),
            jobs: processService.processList()["processes"] as? [JSONObject] ?? [],
            persistenceVerified: persistenceVerified)
        if action == "begin", let id = result["work_id"] as? String,
           connectorSurface == .webTunnel {
            result["work_control_token"] = registerCapability(for: id, kind: .work)
        } else if action == "finish", let id = prepared["work_id"] as? String {
            removeCapability(for: id, kind: .work)
        }
        return result
    }

    private func authorizeAndStripWorkControl(
        name: String, arguments: JSONObject
    ) throws -> JSONObject {
        var prepared = arguments
        let supplied = try prepared.optionalString("work_control_token", maximumBytes: 96)
        prepared.removeValue(forKey: "work_control_token")
        if let id = prepared["work_id"] as? String {
            try requireCapability(supplied, for: id, kind: .work, label: "work")
        }
        return prepared
    }

    private func authorizeAndStripProcessControl(
        name: String, arguments: JSONObject
    ) throws -> JSONObject {
        var prepared = arguments
        let protectedSingles: Set<String> = [
            "process_wait", "process_output", "process_output_tail", "process_input", "process_cancel",
        ]
        if protectedSingles.contains(name) {
            let id = try prepared.requiredString("task_id", maximumBytes: 36)
            let supplied = try prepared.optionalString("process_control_token", maximumBytes: 96)
            try requireCapability(supplied, for: id, kind: .process, label: "process")
            prepared.removeValue(forKey: "process_control_token")
        } else if name == "process_output_many" {
            guard let jobs = prepared["jobs"] as? [JSONObject], !jobs.isEmpty, jobs.count <= 8 else {
                throw LocalMCPError.invalidRequest("jobs must contain 1-8 objects")
            }
            prepared["jobs"] = try jobs.map { job -> JSONObject in
                var item = job
                let id = try item.requiredString("task_id", maximumBytes: 36)
                let supplied = try item.optionalString("process_control_token", maximumBytes: 96)
                try requireCapability(supplied, for: id, kind: .process, label: "process")
                item.removeValue(forKey: "process_control_token")
                return item
            }
        } else if name == "developer_task",
                  prepared["action"] as? String == "continue_task",
                  let workID = prepared["work_id"] as? String {
            let taskID = try workActivity.latestJobID(workID)
            let supplied = try prepared.optionalString("process_control_token", maximumBytes: 96)
            try requireCapability(supplied, for: taskID, kind: .process, label: "process")
            prepared.removeValue(forKey: "process_control_token")
        }
        return prepared
    }

    private func authorizeAndStripTransactionControl(
        name: String, arguments: JSONObject
    ) throws -> JSONObject {
        var prepared = arguments
        if name == "transaction_restore" {
            let id = try prepared.requiredString("transaction_id", maximumBytes: 36)
            let supplied = try prepared.optionalString("transaction_control_token", maximumBytes: 96)
            try requireCapability(supplied, for: id, kind: .transaction, label: "transaction")
            prepared.removeValue(forKey: "transaction_control_token")
        } else if name == "transaction_accept" {
            let ids = try prepared.requiredStringArray(
                "transaction_ids", maximumItems: 128, maximumItemBytes: 36
            )
            if connectorSurface == .webTunnel {
                let tokens = try prepared.requiredStringArray(
                    "transaction_control_tokens", maximumItems: 128, maximumItemBytes: 96
                )
                guard ids.count == tokens.count else {
                    throw LocalMCPError.invalidRequest(
                        "transaction IDs and control capabilities must have matching counts"
                    )
                }
                for (id, token) in zip(ids, tokens) {
                    try requireCapability(token, for: id, kind: .transaction, label: "transaction")
                }
            }
            prepared.removeValue(forKey: "transaction_control_tokens")
        }
        return prepared
    }

    private func createsControllableProcess(name: String, arguments: JSONObject) -> Bool {
        if name == "command_start" || name == "network_command" { return true }
        guard name == "developer_task", let action = arguments["action"] as? String else { return false }
        return action == "execute_task" || action == "run_tests"
    }

    private func protectNewTransactions(in object: JSONObject) -> JSONObject {
        func protect(_ value: Any) -> Any {
            if var child = value as? JSONObject {
                for (key, nested) in child { child[key] = protect(nested) }
                if let id = child["transaction_id"] as? String, UUID(uuidString: id) != nil {
                    let token = registerCapability(
                        for: id, kind: .transaction
                    )
                    child["transaction_control_token"] = token
                    child["transaction_resolution"] = [
                        "required_before_task_completion": true,
                        "instruction": "Verify the intended current state, then accept to keep it or restore to roll it back. Do not leave a completed scheduled or normal-Chat mutation retained.",
                        "keep_changes": [
                            "tool": "transaction_accept",
                            "arguments": [
                                "instance_id": instanceID,
                                "transaction_ids": [id],
                                "transaction_control_tokens": [token],
                            ] as JSONObject,
                        ] as JSONObject,
                        "rollback": [
                            "tool": "transaction_restore",
                            "arguments": [
                                "transaction_id": id,
                                "transaction_control_token": token,
                            ] as JSONObject,
                        ] as JSONObject,
                    ] as JSONObject
                }
                return child
            }
            if let array = value as? [Any] { return array.map(protect) }
            return value
        }
        return protect(object) as? JSONObject ?? object
    }

    private func transactionIDs(in value: Any) -> [String] {
        if let object = value as? JSONObject {
            var ids: [String] = []
            if let id = object["transaction_id"] as? String, UUID(uuidString: id) != nil {
                ids.append(id.lowercased())
            }
            for nested in object.values { ids += transactionIDs(in: nested) }
            return Array(Set(ids)).sorted()
        }
        if let array = value as? [Any] { return Array(Set(array.flatMap(transactionIDs))).sorted() }
        return []
    }

    private func callPreparedTool(name: String, arguments: JSONObject, workID: String?) throws -> JSONObject {
        if name == "developer_inspect" {
            let lease = try beginDeveloperInspection()
            defer { endDeveloperInspection() }
            return try executeDeveloperInspection(arguments, lease: lease)
        }
        if name == "developer_task" {
            operationLock.lock()
            defer { operationLock.unlock() }
            let result = try DeveloperTask.execute(
                surface: name, arguments, workID: workID, workActivity: workActivity,
                workspace: workspaceService, processes: processService
            )
            workActivity.linkJob(result, workID: workID)
            return result
        }
        if name == "file_search" {
            let workspace = try beginSearch()
            defer { endSearch() }
            return try executeSearch(arguments, workspace: workspace)
        }
        if name == "command_run" {
            let finish = try beginCommandRun(arguments, workID: workID)
            defer { endCommandRun() }
            return finish()
        }
        if name == "process_wait" {
            let lease = try beginProcessWait()
            defer { endProcessWait() }
            return try executeProcessWait(arguments, lease: lease)
        }
        if Self.isBrevoTool(name) {
            try beginBrevo()
            defer { endBrevo() }
            return try executeBrevoTool(name: name, arguments: arguments)
        }
        if Self.isMediaTool(name) {
            let workspace = try beginMedia(name, arguments)
            defer { operationLock.lock(); mediaInProgress = false; operationLock.unlock() }
            return try executeMedia(name, arguments, workspace: workspace)
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        let result = try executeTool(name: name, arguments: arguments)
        if !name.hasPrefix("process_") { workActivity.linkJob(result, workID: workID) }
        return result
    }

    private static func isBrevoTool(_ name: String) -> Bool {
        name == "brevo_read" || name == "brevo_campaign" || BrevoToolCatalog.groups[name] != nil
    }

    private static func isMediaTool(_ name: String) -> Bool { name == "media_inspect" || name == "media_share" }

    private func beginMedia(_ name: String, _ arguments: JSONObject) throws -> RegisteredLocalWorkspace? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !mediaInProgress else {
            throw LocalMCPError.limitExceeded("a media operation is already active; no additional request was started or queued")
        }
        let workspace: RegisteredLocalWorkspace?
        if name == "media_inspect", arguments["action"] as? String == "capabilities" { workspace = nil }
        else { workspace = try workspaceService.registry.workspace(id: arguments.requiredString("workspace_id", maximumBytes: 36)) }
        mediaInProgress = true
        return workspace
    }

    private func executeMedia(_ name: String, _ arguments: JSONObject, workspace: RegisteredLocalWorkspace?) throws -> JSONObject {
        try MediaShareOperations.execute(name, arguments, workspace: workspace,
            configurationURL: mediaConfigurationURL, transport: mediaTransportForTesting)
    }

    private func beginBrevo() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !brevoInProgress else {
            throw LocalMCPError.limitExceeded("a Brevo operation is already active; no additional request was started or queued")
        }
        brevoInProgress = true
    }

    private func endBrevo() {
        operationLock.lock()
        defer { operationLock.unlock() }
        brevoInProgress = false
    }

    private func executeBrevoTool(name: String, arguments: JSONObject) throws -> JSONObject {
        switch name {
        case "brevo_read":
            return try BrevoOperations.executeRead(arguments, transport: brevoTransportForTesting)
        case "brevo_campaign":
            return try BrevoOperations.executeCampaign(arguments, transport: brevoTransportForTesting)
        default:
            return try BrevoExtendedOperations.execute(name, arguments, transport: brevoTransportForTesting)
        }
    }

    // Small outcome metadata only, never per-item file content or batch payloads.
    private static let observedOutcomeKeys = [
        "complete", "partial", "error_count", "skipped_count", "success_count", "read_count",
        "edits_applied", "replacements",
    ]

    private func activitySnapshot(taskID: String?) throws -> JSONObject {
        let snapshot = try observerRequest(["action": "snapshot", "instance_id": instanceID])
        func select(_ row: JSONObject, _ keys: [String]) -> JSONObject {
            row.filter { keys.contains($0.key) }
        }
        let jobs = (snapshot["jobs"] as? [JSONObject] ?? []).suffix(32).map {
            select($0, ["task_id", "running", "exit_code", "cancelled", "started_milliseconds", "ended_milliseconds"])
        }
        let history = (snapshot["history"] as? [JSONObject] ?? []).suffix(24).map { row in
            var result = select(row, ["id", "tool", "state", "started_ms", "finished_ms", "path", "cwd", "task_id", "work_id", "detail", "workspace_id"])
            result["result"] = select(row["result"] as? JSONObject ?? [:],
                ["task_id", "running", "exit_code", "cancelled", "timed_out", "mutation_performed", "sha256", "operation"]
                    + Self.observedOutcomeKeys)
            return result
        }
        var result: JSONObject = [
            "schema_version": 1, "scope": "shared_runtime_not_chat_scoped",
            "instance_id": instanceID, "build_id": "\(Self.version)+\(String(executableHash.prefix(12)))",
            "catalog_count": Self.toolSpecs.count, "jobs": Array(jobs), "history": Array(history),
            "work_items": snapshot["work_items"] ?? [],
            "jobs_known": snapshot["jobs"] != nil,
            "jobs_truncated": (snapshot["jobs"] as? [JSONObject] ?? []).count > 32,
            "transaction_count": snapshot["transaction_count"] ?? NSNull(),
            "busy": snapshot["busy"] ?? false, "snapshot_stale": snapshot["snapshot_stale"] ?? true,
            "snapshot_ms": snapshot["snapshot_ms"] ?? NSNull(),
            "observed_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "ui_resource_delivery": snapshot["ui_resource_delivery"] ?? [:],
        ]
        if let taskID {
            if operationLock.try() {
                defer { operationLock.unlock() }
                do {
                    result["log"] = try processService.outputTail(taskID: taskID, maximumBytes: 4096)
                } catch {
                    result["log_error"] = "Log is no longer available for this retained job."
                }
            } else {
                result["log_error"] = "Runtime busy; log was not read."
            }
        }
        return result
    }

    private func observedTool(name: String, arguments: JSONObject, workID: String?,
                              execute: () throws -> JSONObject) throws -> JSONObject {
        let eventID = UUID().uuidString.lowercased()
        var event: JSONObject = [
            "id": eventID, "tool": name, "state": "running",
            "started_ms": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        for key in ["workspace_id", "task_id", "transaction_id", "path", "cwd"] {
            if let text = arguments[key] as? String { event[key] = String(text.prefix(512)) }
        }
        if let workID { event["work_id"] = workID }
        event["detail"] = ActivityDetail.metadata(name: name, arguments: arguments)
        if observationEnabled {
            observerLock.lock()
            observerHistory.append(event)
            if observerHistory.count > 64 { observerHistory.removeFirst(observerHistory.count - 64) }
            observerLock.unlock()
        }
        do {
            var result = try execute()
            if let workID { result["work_id"] = workID }
            let failed = result["isError"] as? Bool == true
            workActivity.finishCall(workID, name: name, result: result, failed: failed)
            if observationEnabled { finishObservation(eventID, result: result,
                error: failed ? "Tool reported an unsuccessful or uncertain outcome; inspect receipt" : nil) }
            return result
        } catch {
            workActivity.finishCall(workID, name: name, result: [:], failed: true)
            if observationEnabled { finishObservation(eventID, result: [:], error: safeMessage(error)) }
            throw error
        }
    }

    private func finishObservation(_ id: String, result: JSONObject, error: String?) {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard let index = observerHistory.firstIndex(where: { $0["id"] as? String == id }) else { return }
        observerHistory[index]["state"] = error == nil ? "returned" : "failed"
        observerHistory[index]["finished_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        var summary: JSONObject = [:]
        for key in ["task_id", "transaction_id", "running", "exit_code", "cancelled",
                    "timed_out", "mutation_performed", "sha256", "operation", "session_retained"]
                    + Self.observedOutcomeKeys {
            if let value = result[key] { summary[key] = value }
        }
        // No request content, stdin, environment or file_read content is retained.
        if let error { summary["error"] = String(error.prefix(512)) }
        for key in ["stdout", "stderr"] {
            if let value = result[key] as? String {
                summary[key] = String(value.suffix(1024))
                summary[key + "_preview_truncated"] = value.count > 1024
            }
        }
        observerHistory[index]["result"] = summary
    }

    public func observerRequest(_ request: JSONObject) throws -> JSONObject {
        guard observationEnabled else {
            throw LocalMCPError.invalidRequest("observer was not enabled for this owner")
        }
        let action = try request.requiredString("action", maximumBytes: 32)
        guard ["snapshot", "output", "transaction", "cancel", "restore", "file_preview", "identity_probe"].contains(action) else {
            throw LocalMCPError.invalidRequest("unsupported observer action")
        }
        if action == "identity_probe" {
            try request.requireOnlyKeys(["action", "instance_id", "operation"])
            guard request["instance_id"] as? String == instanceID else {
                throw LocalMCPError.conflict("observer owner changed; reconnect explicitly")
            }
            switch try request.requiredString("operation", maximumBytes: 8) {
            case "start": return requestIdentityProbe.start()
            case "read": return requestIdentityProbe.snapshot()
            case "stop": return requestIdentityProbe.stop()
            default: throw LocalMCPError.invalidRequest("identity probe operation must be start, read or stop")
            }
        }
        if action == "file_preview" {
            try request.requireOnlyKeys(["action", "instance_id", "event_id", "known_version"])
        } else if action == "output" {
            try request.requireOnlyKeys(["action", "instance_id", "task_id", "stdout_cursor", "stderr_cursor"])
        } else {
            try request.requireOnlyKeys(["action", "instance_id", "task_id", "transaction_id", "workspace_id"])
        }
        if action != "snapshot" || request["instance_id"] != nil {
            guard request["instance_id"] as? String == instanceID else {
                throw LocalMCPError.conflict("observer owner changed; reconnect explicitly")
            }
        }
        guard operationLock.try() else {
            if action != "snapshot" { throw LocalMCPError.conflict("owner busy; no action performed") }
            observerLock.lock()
            defer { observerLock.unlock() }
            var cached = observerCached
            cached["instance_id"] = instanceID
            cached["busy"] = true
            cached["snapshot_stale"] = true
            cached["history"] = observerHistory
            cached["work_items"] = workActivity.list(jobs: nil)
            cached["observer_file_preview"] = true
            cached["ui_resource_delivery"] = uiResourceDeliveryLocked
            return cached
        }
        defer { operationLock.unlock() }
        if action == "snapshot" {
            var snapshot = try executeTool(name: "bridge_capabilities", arguments: [:])
            snapshot["workspaces"] = workspaceService.workspaceOverview()["workspaces"]
            snapshot["jobs"] = processService.processList()["processes"]
            snapshot["work_items"] = workActivity.list(jobs: snapshot["jobs"] as? [JSONObject])
            snapshot["transactions"] = workspaceService.observerTransactions()
            snapshot["transaction_count"] = workspaceService.retainedTransactionCount
            snapshot["observer_file_preview"] = true
            snapshot["busy"] = brevoInProgress || mediaInProgress
            snapshot["snapshot_stale"] = false
            snapshot["snapshot_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
            observerLock.lock()
            snapshot["history"] = observerHistory
            snapshot["ui_resource_delivery"] = uiResourceDeliveryLocked
            observerCached = snapshot
            observerLock.unlock()
            return snapshot
        }
        if action == "file_preview" {
            let id = try request.requiredString("event_id", maximumBytes: 36).lowercased()
            guard UUID(uuidString: id) != nil else { throw LocalMCPError.invalidRequest("invalid observed file event") }
            let known = try request.optionalString("known_version", maximumBytes: 64)
            if let known, known.count != 64 || !known.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                throw LocalMCPError.invalidRequest("invalid preview version")
            }
            observerLock.lock()
            let event = observerHistory.first { $0["id"] as? String == id }
            observerLock.unlock()
            let eligible: Set<String> = ["file_read", "file_read_lines", "file_tail", "file_stat",
                "file_write", "file_patch", "file_apply_edits", "file_append"]
            guard let event, event["state"] as? String == "returned",
                  let tool = event["tool"] as? String, eligible.contains(tool),
                  let workspace = event["workspace_id"] as? String, UUID(uuidString: workspace) != nil,
                  let path = event["path"] as? String, !path.isEmpty, path.count < 512 else {
                throw LocalMCPError.invalidRequest("selected event does not retain an exact eligible file path")
            }
            var result = try workspaceService.observerFilePreview(workspaceID: workspace, path: path, knownVersion: known)
            result["instance_id"] = instanceID
            result["event_id"] = id
            return result
        }
        if action == "output" || action == "cancel" {
            let id = try request.requiredString("task_id", maximumBytes: 36)
            _ = try processService.processStatus(taskID: id)
            if action == "output" {
                return try processService.processOutput(
                    taskID: id,
                    stdoutCursor: request.optionalInt("stdout_cursor", default: 0, range: 0...Int.max),
                    stderrCursor: request.optionalInt("stderr_cursor", default: 0, range: 0...Int.max),
                    maximumBytesPerStream: 8192, consumeCompletedHandle: false
                )
            }
            // Owner IPC is instance-bound and never exposed through the Web
            // tool schema, so it deliberately bypasses per-chat bearer tokens.
            return try processService.cancelProcess(taskID: id)
        }
        let id = try request.requiredString("transaction_id", maximumBytes: 36)
        let workspace = try request.requiredString("workspace_id", maximumBytes: 36)
        let detail = try workspaceService.observerTransaction(id: id, workspaceID: workspace)
        if action == "transaction" { return detail }
        let result = try workspaceService.observerRestore(id: id, workspaceID: workspace) {
            try workspaceService.restoreTransaction(id)
        }
        removeCapability(for: id, kind: .transaction)
        return result
    }

    // Caller holds observerLock. A prepared response is NOT host receipt/render
    // acceptance; this only identifies the point reached inside this process.
    private var uiResourceDeliveryLocked: JSONObject {
        ["read_count": uiResourceReadCount, "last_outcome": uiResourceReadOutcome]
    }

    private func observeRequestIdentity(name: String, metadata: Any?) {
        guard observationEnabled else { return }
        // Unknown tool names can themselves contain user data; do not retain them.
        requestIdentityProbe.observe(tool: Self.toolSpecs.contains { $0["name"] as? String == name }
            ? name : "unknown_tool", metadata: metadata)
    }

    private func executeTool(name: String, arguments: JSONObject) throws -> JSONObject {
        switch name {
        case "bridge_diagnostic":
            try arguments.requireOnlyKeys([])
            let workspaceAvailability = workspaceService.diagnosticAvailability()
            let workspaceReady = workspaceAvailability.available > 0
            return [
                "status": workspaceReady ? "DEGRADED" : "BLOCKED",
                "server_alive": true,
                "core_catalog_ready": true,
                "registered_workspace_count": workspaceAvailability.registered,
                "available_workspace_count": workspaceAvailability.available,
                "workspace_actions_callable": workspaceReady,
                "file_actions_callable": NSNull(),
                "file_actions_verified": false,
                "scheduler_context_callable": true,
                "host_binding_ready": NSNull(),
                "host_binding_verified": false,
                "tunnel_state": connectorSurface == .webTunnel ? "CONNECTED_TO_CORE_HOST_STATE_UNKNOWN" : "LOCAL",
                "binding_epoch": bindingEpoch,
                "catalog_sha256": catalogDigest,
                "catalog_count": Self.toolSpecs.count,
                "recommended_action": workspaceReady
                    ? "The host must resolve and call bridge_capabilities, workspace_overview, file_stat and file_read under this binding_epoch. A file fixture is required before file actions can be reported as verified. Treat any missing schema as HOST_BINDING_MISSING and rebind before retrying."
                    : "Restore or reload at least one registered workspace root before file work; then probe file_stat and file_read with an explicit fixture.",
                "probe_tools": ["bridge_capabilities", "workspace_overview", "file_stat", "file_read"],
                "scope": "core-observable state only; host binding and tunnel control-plane health require host-side confirmation",
            ]
        case "bridge_capabilities":
            try arguments.requireOnlyKeys([])
            return [
                "chatgpt_mode": "CHATGPT_FULL",
                "connector_surface": connectorSurface.capabilityName,
                "transport": connectorSurface.transportName,
                "runtime_profile": connectorSurface.runtimeProfile,
                "runtime_architecture": connectorSurface.runtimeArchitecture,
                "build_id": "\(Self.version)+\(String(executableHash.prefix(12)))",
                "instance_id": instanceID,
                "uptime_milliseconds": Int64(
                    clamping: (DispatchTime.now().uptimeNanoseconds - startedUptimeNanoseconds)
                        / 1_000_000
                ),
                "workspace_boundary": "configuration_allowlist",
                "catastrophic_root_removal_blocked": true,
                "broad_command_scope": "explicit_cwd_subtree_excluding_protected_roots",
                "privileged_system_commands_blocked": true,
                "broad_filesystem_access": workspaceService.registry.workspaces.contains {
                    $0.allowsBroadAccess
                },
                "credential_paths_blocked": true,
                "desktop_open": "owner_opt_in_per_workspace_fixed_finder_preview_textedit",
                "desktop_open_enabled": workspaceService.registry.workspaces.contains { $0.allowsDesktopOpen },
                "observer_output_pagination": true,
                "catalog_count": Self.toolSpecs.count,
                "catalog_sha256": catalogDigest,
                "binding_epoch": bindingEpoch,
                "tool_names": Self.toolSpecs.compactMap { $0["name"] as? String },
                "tool_discovery": "Use host tool discovery to load missing callable schemas. tool_catalog returns the exact live catalog; catalog visibility does not grant permission or guarantee host loading.",
                "mcp_executable_sha256": executableHash,
                "terminal_window_opened": false,
                "network_default": "loopback_only",
                "network_command": "owner_pinned_ipv4_tcp_port_via_ephemeral_authenticated_loopback_proxy_cwd_expiry_max_one_hour",
                "connector_network": connectorSurface.connectorNetwork,
                "public_listener": false,
                "outbound_tunnel_adapter": connectorSurface == .webTunnel,
                "shell_execution": "headless_stdio",
                "interactive_process_input": true,
                "process_cancel_scope": "unique Seatbelt command boundary with an in-sandbox supervisor, plus root process group and birth-identity-checked descendant cleanup; bounded normal-workload containment, not hostile fork-bomb containment",
                "workspace_reload": true,
                "active_searches": searchInProgress ? 1 : 0,
                "maximum_concurrent_searches": 1,
                "command_run_nonblocking_dispatch": true,
                "active_command_runs": activeCommandRuns,
                "active_command_runs_scope": "active_command_run_execution_leases_not_background_jobs_or_delivery_ack",
                "maximum_concurrent_command_runs": Self.maximumConcurrentCommandRuns,
                "process_activity": processService.activityCounts(),
                "developer_inspect_nonblocking_dispatch": true,
                "active_developer_inspections": activeDeveloperInspections,
                "maximum_concurrent_developer_inspections": Self.maximumConcurrentDeveloperInspections,
                "process_wait_nonblocking_dispatch": true,
                "active_process_waits": activeProcessWaits,
                "maximum_concurrent_process_waits": Self.maximumConcurrentProcessWaits,
                "active_brevo_calls": brevoInProgress ? 1 : 0,
                "maximum_concurrent_brevo_calls": 1,
                "active_media_calls": mediaInProgress ? 1 : 0,
                "maximum_concurrent_media_calls": 1,
                "media_sharing": "owner_opt_in_private_r2_expiring_get_url_no_meta_api_or_public_listener",
                "workspace_reload_preserves_pending_undo": "refuse_until_restored_or_explicitly_accepted",
                "transaction_list_available": true,
                "transaction_accept_available": true,
                "transaction_accept_purges_disk_recovery": false,
                "maximum_retained_undo_transactions": LocalWorkspaceService.maximumRetainedTransactions,
                "maximum_retained_undo_file_bytes": LocalWorkspaceService.maximumRetainedUndoFileBytes,
                "retained_transaction_count": workspaceService.retainedTransactionCount,
                "workspace_reload_blocked_by_undo": workspaceService.retainedTransactionCount > 0,
                "scheduler_lifecycle": ["fired", "worker_started", "result_ready", "persisted", "acknowledged"],
                "scheduler_completion_requires_acknowledgement": true,
                "maximum_aggregate_process_output_bytes": LocalProcessService.maximumAggregateOutputBytes,
                "process_output_budget_policy": "reserve_both_stream_capacities_until_handle_release",
                "batch_file_operations": true,
                "maximum_batch_paths": LocalWorkspaceService.maximumBatchPaths,
                "maximum_batch_read_bytes": LocalWorkspaceService.maximumBatchReadBytes,
                "completed_process_status_limit": LocalProcessService.maximumCompletedStatuses,
                "completed_process_status_ttl_seconds": LocalProcessService.completedStatusLifetime,
                "sensitive_access_approval": "not_implemented_credentials_remain_blocked",
                "daemon_used": false,
                "xpc_used": false,
                "keychain_used": false,
            ]
        case "workspace_overview", "workspace_list":
            try arguments.requireOnlyKeys([])
            return workspaceService.workspaceOverview()
        case "workspace_resolve":
            try arguments.requireOnlyKeys(["path"])
            return try workspaceService.resolveWorkspace(
                path: arguments.requiredString("path", maximumBytes: 4_096)
            )
        case "workspace_reload":
            try arguments.requireOnlyKeys([])
            guard !mediaInProgress else {
                throw LocalMCPError.conflict("a media operation is active; workspace configuration was not reloaded")
            }
            guard activeCommandRuns == 0 else {
                throw LocalMCPError.conflict("one or more command_run responses are pending; workspace configuration was not reloaded")
            }
            guard activeDeveloperInspections == 0 else {
                throw LocalMCPError.conflict("one or more developer inspections are active; workspace configuration was not reloaded")
            }
            guard activeProcessWaits == 0 else {
                throw LocalMCPError.conflict("one or more process waits are active; workspace configuration was not reloaded")
            }
            guard !searchInProgress else {
                throw LocalMCPError.conflict("a search is active; workspace configuration was not reloaded")
            }
            guard processService.trackedProcessCount == 0 else {
                throw LocalMCPError.conflict(
                    "workspace configuration cannot reload while a process is tracked"
                )
            }
            guard workspaceService.retainedTransactionCount == 0 else {
                throw LocalMCPError.conflict(
                    "workspace configuration cannot reload while undo transactions are retained; restore or explicitly accept selected transactions first"
                )
            }
            let replacementWorkspaceService = LocalWorkspaceService(
                registry: try LocalWorkspaceRegistry(configurationURL: configurationURL),
                protectedMutationPaths: [selfExecutable.path]
            )
            workspaceService = replacementWorkspaceService
            processService = LocalProcessService(
                workspaceService: replacementWorkspaceService,
                selfExecutable: selfExecutable
            )
            capabilityLock.lock()
            processControlTokens.removeAll(keepingCapacity: true)
            capabilityLock.unlock()
            var result = replacementWorkspaceService.workspaceOverview()
            result["reloaded"] = true
            return result
        case "desktop_open":
            if let presenter = desktopPresenterForTesting {
                return try DesktopOpen.execute(arguments, workspace: workspaceService, presenter: presenter)
            }
            return try DesktopOpen.execute(arguments, workspace: workspaceService)
        case "directory_list":
            try arguments.requireOnlyKeys([
                "workspace_id", "path", "recursive", "maximum_entries", "cursor",
            ])
            return try workspaceService.listDirectory(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: try arguments.optionalString("path", maximumBytes: 4_096) ?? ".",
                recursive: arguments.optionalBool("recursive", default: false),
                maximumEntries: arguments.optionalInt(
                    "maximum_entries", default: 500, range: 1...10_000
                ),
                cursor: arguments.optionalInt(
                    "cursor", default: 0, range: 0...LocalWorkspaceService.maximumTreeEntries
                )
            )
        case "file_stat":
            try arguments.requireOnlyKeys(["workspace_id", "path"])
            return try workspaceService.statPath(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096)
            )
        case "file_stat_many":
            try arguments.requireOnlyKeys(["workspace_id", "paths", "include_sha256"])
            return try workspaceService.statPaths(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                paths: arguments.requiredStringArray("paths", maximumItems: 32, maximumItemBytes: 4096),
                includeSHA256: arguments.optionalBool("include_sha256", default: false)
            )
        case "file_read_many":
            try arguments.requireOnlyKeys(["workspace_id", "paths", "encoding", "maximum_bytes_per_file", "maximum_total_bytes", "snapshot_consistent"])
            let workspaceID = try arguments.requiredString("workspace_id", maximumBytes: 36)
            let paths = try arguments.requiredStringArray("paths", maximumItems: 32, maximumItemBytes: 4096)
            let encoding = try arguments.optionalString("encoding", maximumBytes: 16) ?? "utf8"
            let perFile = try arguments.optionalInt("maximum_bytes_per_file", default: 65_536, range: 1...262_144)
            let total = try arguments.optionalInt("maximum_total_bytes", default: 1_048_576, range: 4...1_048_576)
            if try arguments.optionalBool("snapshot_consistent", default: false) {
                return try workspaceService.readFilesSnapshot(
                    workspaceID: workspaceID, paths: paths, encoding: encoding,
                    maximumBytesPerFile: perFile, maximumTotalBytes: total
                )
            }
            return try workspaceService.readFiles(
                workspaceID: workspaceID, paths: paths, encoding: encoding,
                maximumBytesPerFile: perFile, maximumTotalBytes: total
            )
        case "file_read":
            try arguments.requireOnlyKeys([
                "workspace_id", "path", "encoding", "maximum_bytes", "offset",
            ])
            return try workspaceService.readFile(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096),
                encoding: try arguments.optionalString("encoding", maximumBytes: 16) ?? "utf8",
                maximumBytes: arguments.optionalInt(
                    "maximum_bytes", default: 1_048_576,
                    range: 1...LocalWorkspaceService.maximumFileBytes
                ),
                offset: arguments.optionalInt("offset", default: 0, range: 0...Int.max)
            )
        case "file_search":
            return try executeSearch(arguments, workspace: workspaceService)
        case "file_write":
            try arguments.requireOnlyKeys([
                "workspace_id", "path", "content", "encoding", "expected_sha256", "create_only",
            ])
            return try workspaceService.writeFile(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096),
                content: try stringAllowingEmpty(arguments, key: "content"),
                encoding: try arguments.optionalString("encoding", maximumBytes: 16) ?? "utf8",
                expectedSHA256: try arguments.optionalString(
                    "expected_sha256", maximumBytes: 64
                ),
                createOnly: try arguments.optionalBool("create_only", default: false)
            )
        case "file_patch":
            try arguments.requireOnlyKeys([
                "workspace_id", "path", "old_text", "new_text", "replace_all",
                "expected_sha256",
            ])
            return try workspaceService.patchFile(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096),
                oldText: arguments.requiredString(
                    "old_text", maximumBytes: LocalWorkspaceService.maximumFileBytes
                ),
                newText: try stringAllowingEmpty(arguments, key: "new_text"),
                replaceAll: arguments.optionalBool("replace_all", default: false),
                expectedSHA256: arguments.requiredString("expected_sha256", maximumBytes: 64)
            )
        case "file_append":
            try arguments.requireOnlyKeys([
                "workspace_id", "path", "content", "encoding", "expected_sha256",
            ])
            return try workspaceService.appendFile(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096),
                content: try stringAllowingEmpty(arguments, key: "content"),
                encoding: try arguments.optionalString("encoding", maximumBytes: 16) ?? "utf8",
                expectedSHA256: arguments.requiredString("expected_sha256", maximumBytes: 64)
            )
        case "directory_create":
            try arguments.requireOnlyKeys(["workspace_id", "path"])
            return try workspaceService.createDirectory(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096)
            )
        case "path_copy":
            try arguments.requireOnlyKeys([
                "workspace_id", "source_path", "destination_path",
            ])
            return try workspaceService.copyPath(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                sourcePath: arguments.requiredString("source_path", maximumBytes: 4_096),
                destinationPath: arguments.requiredString(
                    "destination_path", maximumBytes: 4_096
                )
            )
        case "path_move":
            try arguments.requireOnlyKeys([
                "workspace_id", "source_path", "destination_path",
            ])
            return try workspaceService.movePath(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                sourcePath: arguments.requiredString("source_path", maximumBytes: 4_096),
                destinationPath: arguments.requiredString(
                    "destination_path", maximumBytes: 4_096
                )
            )
        case "path_remove":
            try arguments.requireOnlyKeys(["workspace_id", "path"])
            return try workspaceService.removePath(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                path: arguments.requiredString("path", maximumBytes: 4_096)
            )
        case "transaction_restore":
            try arguments.requireOnlyKeys(["transaction_id"])
            return try workspaceService.restoreTransaction(
                arguments.requiredString("transaction_id", maximumBytes: 36)
            )
        case "transaction_list":
            try arguments.requireOnlyKeys(["cursor", "maximum_transactions"])
            var result = try workspaceService.listTransactions(
                cursor: arguments.optionalString("cursor", maximumBytes: 64),
                maximumTransactions: arguments.optionalInt("maximum_transactions", default: 100, range: 1...100)
            )
            result["instance_id"] = instanceID
            return result
        case "transaction_accept":
            try arguments.requireOnlyKeys(["instance_id", "transaction_ids"])
            guard try arguments.requiredString("instance_id", maximumBytes: 36) == instanceID else {
                throw LocalMCPError.conflict("owner changed; no undo released")
            }
            var result = try workspaceService.acceptTransactions(
                arguments.requiredStringArray("transaction_ids", maximumItems: 128, maximumItemBytes: 36)
            )
            result["instance_id"] = instanceID
            return result
        case "network_command":
            try arguments.requireOnlyKeys(["workspace_id", "grant_id", "executable", "arguments", "maximum_output_bytes"])
            return try processService.startNetworkCommand(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                grantID: arguments.requiredString("grant_id", maximumBytes: 36),
                executableID: arguments.requiredString("executable", maximumBytes: 64),
                arguments: arguments.requiredStringArray("arguments"),
                maximumOutputBytes: arguments.optionalInt("maximum_output_bytes", default: 262_144, range: 1...1_048_576))
        case "command_start":
            try arguments.requireOnlyKeys([
                "workspace_id", "executable", "arguments", "cwd", "maximum_output_bytes",
            ])
            return try processService.startCommand(
                workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
                executableID: arguments.requiredString("executable", maximumBytes: 64),
                arguments: arguments.requiredStringArray("arguments"),
                cwd: try arguments.optionalString("cwd", maximumBytes: 4_096) ?? ".",
                maximumOutputBytes: arguments.optionalInt(
                    "maximum_output_bytes", default: 1_048_576, range: 1...16_777_216
                )
            )
        case "process_status":
            try arguments.requireOnlyKeys(["task_id"])
            return try processService.processStatus(
                taskID: arguments.requiredString("task_id", maximumBytes: 36)
            )
        case "process_output":
            try arguments.requireOnlyKeys([
                "task_id", "stdout_cursor", "stderr_cursor", "maximum_bytes_per_stream",
            ])
            return try processService.processOutput(
                taskID: arguments.requiredString("task_id", maximumBytes: 36),
                stdoutCursor: arguments.optionalInt(
                    "stdout_cursor", default: 0, range: 0...Int.max
                ),
                stderrCursor: arguments.optionalInt(
                    "stderr_cursor", default: 0, range: 0...Int.max
                ),
                maximumBytesPerStream: arguments.optionalInt(
                    "maximum_bytes_per_stream", default: 65_536, range: 1...1_048_576
                )
            )
        case "process_list":
            try arguments.requireOnlyKeys([])
            return processService.processList()
        case "process_input":
            try arguments.requireOnlyKeys(["task_id", "content", "encoding", "close_stdin"])
            return try processService.processInput(
                taskID: arguments.requiredString("task_id", maximumBytes: 36),
                content: try stringAllowingEmpty(
                    arguments, key: "content", maximumBytes: 65_536
                ),
                encoding: try arguments.optionalString("encoding", maximumBytes: 16) ?? "utf8",
                closeStdin: arguments.optionalBool("close_stdin", default: false)
            )
        case "process_cancel":
            try arguments.requireOnlyKeys(["task_id"])
            return try processService.cancelProcess(
                taskID: arguments.requiredString("task_id", maximumBytes: 36)
            )
        default:
            return try ExpandedToolOperations.execute(name, arguments, workspace: workspaceService,
                                                      processes: processService)
        }
    }

    private var catalogDigest: String {
        Self.builtInCatalog.digest
    }

    private func processFrame(_ data: Data, output: FileHandle,
                              responses: PendingToolResponses) throws {
        // The headless stdio loop has no AppKit run loop to drain Foundation's
        // autoreleased temporaries. Bound their lifetime to one complete request,
        // including serialization; retained jobs/transactions keep their own ARC
        // references and must remain usable by later requests.
        try autoreleasepool {
            do {
                let message = try LocalJSON.decodeObject(data)
                if try dispatchLongTool(message, data: data, output: output, responses: responses) { return }
                if let response = handle(message) { try write(response, to: output) }
            } catch {
                try write(
                    rpcError(id: NSNull(), code: -32_700, message: safeMessage(error)),
                    to: output
                )
            }
        }
    }

    private func write(_ value: JSONObject, to output: FileHandle) throws {
        var data = try LocalJSON.encode(value)
        data.append(0x0A)
        outputLock.lock()
        defer { outputLock.unlock() }
        try output.write(contentsOf: data)
    }

    private func beginSearch() throws -> LocalWorkspaceService {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !searchInProgress else {
            throw LocalMCPError.limitExceeded("a file_search is already active; no additional search was started")
        }
        searchInProgress = true
        // Keep one immutable registry/scope for this search. Reload is refused
        // while this lease exists; other jobs, reads and mutations remain usable.
        return workspaceService
    }

    private func endSearch() {
        operationLock.lock()
        searchInProgress = false
        operationLock.unlock()
    }

    private func beginCommandRun(_ arguments: JSONObject, workID: String?) throws -> @Sendable () -> JSONObject {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard activeCommandRuns < Self.maximumConcurrentCommandRuns else {
            throw LocalMCPError.limitExceeded("\(Self.maximumConcurrentCommandRuns) command_run responses are already pending; no additional command was started; use command_start for further concurrent jobs")
        }
        try arguments.requireOnlyKeys([
            "workspace_id", "executable", "arguments", "cwd", "timeout_milliseconds",
            "maximum_output_bytes",
        ])
        let prepared = try processService.prepareIdentifiedCommandRun(
            workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
            executableID: arguments.requiredString("executable", maximumBytes: 64),
            arguments: arguments.requiredStringArray("arguments"),
            cwd: try arguments.optionalString("cwd", maximumBytes: 4_096) ?? ".",
            timeoutMilliseconds: arguments.optionalInt(
                "timeout_milliseconds", default: 300_000, range: 100...3_600_000),
            maximumOutputBytes: arguments.optionalInt(
                "maximum_output_bytes", default: 1_048_576, range: 1...16_777_216))
        // Link only the identity returned by this launch. Read-only developer
        // inspections may create their own short Git jobs outside this lock.
        workActivity.linkJob(["task_id": prepared.taskID, "running": true], workID: workID)
        activeCommandRuns += 1
        return prepared.finish
    }

    private func endCommandRun() {
        operationLock.lock()
        activeCommandRuns = max(0, activeCommandRuns - 1)
        operationLock.unlock()
    }

    private struct DeveloperInspectionLease: Sendable {
        let workspace: LocalWorkspaceService
        let processes: LocalProcessService
    }

    private func beginDeveloperInspection() throws -> DeveloperInspectionLease {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard activeDeveloperInspections < Self.maximumConcurrentDeveloperInspections else {
            throw LocalMCPError.limitExceeded(
                "\(Self.maximumConcurrentDeveloperInspections) developer inspections are already active; no additional inspection was started or queued"
            )
        }
        activeDeveloperInspections += 1
        // Keep one coherent registry/process pair for the whole inspection.
        // Reload is refused until every inspection lease is released.
        return DeveloperInspectionLease(workspace: workspaceService, processes: processService)
    }

    private func endDeveloperInspection() {
        operationLock.lock()
        activeDeveloperInspections = max(0, activeDeveloperInspections - 1)
        operationLock.unlock()
    }

    private func executeDeveloperInspection(
        _ arguments: JSONObject, lease: DeveloperInspectionLease
    ) throws -> JSONObject {
        developerInspectionStartForTesting?()
        return try DeveloperTask.execute(
            surface: "developer_inspect", arguments, workID: nil, workActivity: workActivity,
            workspace: lease.workspace, processes: lease.processes
        )
    }

    private struct ProcessWaitLease: Sendable {
        let workspace: LocalWorkspaceService
        let processes: LocalProcessService
    }

    private func beginProcessWait() throws -> ProcessWaitLease {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard activeProcessWaits < Self.maximumConcurrentProcessWaits else {
            throw LocalMCPError.limitExceeded(
                "\(Self.maximumConcurrentProcessWaits) process waits are already active; no additional wait was started or queued"
            )
        }
        activeProcessWaits += 1
        return ProcessWaitLease(workspace: workspaceService, processes: processService)
    }

    private func endProcessWait() {
        operationLock.lock()
        activeProcessWaits = max(0, activeProcessWaits - 1)
        operationLock.unlock()
    }

    private func executeProcessWait(
        _ arguments: JSONObject, lease: ProcessWaitLease
    ) throws -> JSONObject {
        processWaitStartForTesting?()
        return try ExpandedToolOperations.execute(
            "process_wait", arguments, workspace: lease.workspace, processes: lease.processes
        )
    }

    private func executeSearch(_ arguments: JSONObject,
                               workspace: LocalWorkspaceService) throws -> JSONObject {
        searchStartForTesting?()
        try arguments.requireOnlyKeys([
            "workspace_id", "path", "query", "case_sensitive", "maximum_results",
            "maximum_file_bytes", "mode", "cursor", "include_ignored",
            "maximum_duration_milliseconds", "maximum_total_read_bytes",
        ])
        return try workspace.searchFiles(
            workspaceID: arguments.requiredString("workspace_id", maximumBytes: 36),
            path: try arguments.optionalString("path", maximumBytes: 4_096) ?? ".",
            query: arguments.requiredString("query", maximumBytes: 4_096),
            caseSensitive: arguments.optionalBool("case_sensitive", default: true),
            maximumResults: arguments.optionalInt("maximum_results", default: 200, range: 1...1_000),
            maximumFileBytes: arguments.optionalInt("maximum_file_bytes", default: 1_048_576,
                range: 1...LocalWorkspaceService.maximumFileBytes),
            mode: try arguments.optionalString("mode", maximumBytes: 16) ?? "content",
            cursor: arguments.optionalInt("cursor", default: 0, range: 0...Int.max),
            includeIgnored: arguments.optionalBool("include_ignored", default: false),
            maximumDurationMilliseconds: arguments.optionalInt(
                "maximum_duration_milliseconds", default: 5_000, range: 1...10_000),
            maximumTotalReadBytes: arguments.optionalInt(
                "maximum_total_read_bytes", default: 32 * 1_024 * 1_024, range: 1...(64 * 1_024 * 1_024)))
    }

    private func dispatchLongTool(_ message: JSONObject, data: Data, output: FileHandle,
                                  responses: PendingToolResponses) throws -> Bool {
        guard message["method"] as? String == "tools/call",
              let params = message["params"] as? JSONObject,
              let name = params["name"] as? String,
              name == "file_search" || name == "command_run" || name == "developer_inspect"
                || name == "process_wait" || Self.isBrevoTool(name) || Self.isMediaTool(name)
                else { return false }
        // Validate protocol/session state on the input thread, in frame order.
        // Invalid envelopes retain handle()'s existing JSON-RPC error semantics.
        do {
            try message.requireOnlyKeys(["jsonrpc", "id", "method", "params"])
            guard message["jsonrpc"] as? String == "2.0" else { return false }
            try requireInitializedForCurrentSurface()
            try params.requireOnlyKeys(["name", "arguments", "_meta"])
            _ = try object(params["arguments"] ?? [:], label: "tool arguments")
        } catch { return false }
        observeRequestIdentity(name: name, metadata: params["_meta"])
        let execute: @Sendable (JSONObject) throws -> JSONObject
        let original = params["arguments"] as? JSONObject ?? [:]
        var activityArguments = original
        activityArguments.removeValue(forKey: "work_control_token")
        activityArguments.removeValue(forKey: "process_control_token")
        activityArguments.removeValue(forKey: "transaction_control_token")
        activityArguments.removeValue(forKey: "transaction_control_tokens")
        var workID: String?
        var responseReserved = false
        var responseByteBudget = 0
        do {
            var effective = try authorizeAndStripWorkControl(name: name, arguments: original)
            effective = try authorizeAndStripProcessControl(name: name, arguments: effective)
            activityArguments = effective
            if name == "command_run" {
                let requested = effective["maximum_output_bytes"] as? Int ?? 1_048_576
                let bounded = min(16_777_216, max(1, requested))
                responseByteBudget = bounded * 12 + 1_048_576
            } else {
                responseByteBudget = 1_048_576
            }
            guard responses.reserve(estimatedBytes: responseByteBudget) else {
                throw LocalMCPError.limitExceeded(
                    "the bounded completed/active response delivery budget is full; no additional operation was started"
                )
            }
            responseReserved = true
            workID = try workActivity.beginCall(name: name, arguments: effective)
            var prepared = effective
            prepared.removeValue(forKey: "work_id")
            if name == "file_search" {
                let workspace = try beginSearch()
                execute = { [self] arguments in try executeSearch(arguments, workspace: workspace) }
            } else if name == "command_run" {
                let finish = try beginCommandRun(prepared, workID: workID)
                execute = { _ in finish() }
            } else if name == "developer_inspect" {
                let lease = try beginDeveloperInspection()
                execute = { [self] arguments in
                    try executeDeveloperInspection(arguments, lease: lease)
                }
            } else if name == "process_wait" {
                let lease = try beginProcessWait()
                execute = { [self] arguments in try executeProcessWait(arguments, lease: lease) }
            } else if Self.isMediaTool(name) {
                let workspace = try beginMedia(name, prepared)
                execute = { [self] arguments in try executeMedia(name, arguments, workspace: workspace) }
            } else {
                try beginBrevo()
                execute = { [self] arguments in try executeBrevoTool(name: name, arguments: arguments) }
            }
        }
        catch {
            if responseReserved { responses.release(estimatedBytes: responseByteBudget) }
            // Preserve Issues history even when admission fails before a worker
            // exists. This records only the same bounded metadata as other calls.
            _ = try? observedTool(name: name, arguments: activityArguments, workID: workID) {
                throw error
            }
            try write(rpcSuccess(id: message["id"] ?? NSNull(), result: toolResult(
                structuredError(error), message: safeMessage(error), isError: true)), to: output)
            return true
        }
        responses.group.enter()
        let admittedWorkID = workID
        let admittedResponseByteBudget = responseByteBudget
        // One admitted worker per local long tool, one for the whole Brevo
        // family. No unbounded queue, automatic retry or idle polling.
        // Immutable frame bytes cross the queue, not a shared Any dictionary.
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                // Hold the global response reservation until serialization has
                // completed or failed. Per-family execution leases are released
                // separately before the writer can block.
                responses.release(estimatedBytes: admittedResponseByteBudget)
                responses.group.leave()
            }
            autoreleasepool {
                let response: JSONObject
                var responseID: Any = NSNull()
                do {
                    let request = try LocalJSON.decodeObject(data)
                    responseID = request["id"] ?? NSNull()
                    let params = try object(request["params"], label: "tool params")
                    let arguments = try object(params["arguments"] ?? [:], label: "tool arguments")
                    let payload: JSONObject
                    var handedToObservation = false
                    do {
                        var effective = try authorizeAndStripWorkControl(name: name, arguments: arguments)
                        effective = try authorizeAndStripProcessControl(name: name, arguments: effective)
                        var prepared = effective
                        prepared.removeValue(forKey: "work_id")
                        handedToObservation = true
                        let result = try observedTool(name: name, arguments: effective, workID: admittedWorkID) {
                            try execute(prepared)
                        }
                        payload = toolResult(result,
                            message: resultSummary(name: name, result: result, arguments: effective),
                            isError: result["isError"] as? Bool == true)
                    } catch {
                        // observedTool balances the activity after execution has
                        // begun. Authorization can fail before that boundary and
                        // must still close the admitted activity exactly once.
                        if !handedToObservation {
                            workActivity.finishCall(admittedWorkID, name: name, result: [:], failed: true)
                        }
                        payload = toolResult(structuredError(error), message: safeMessage(error), isError: true)
                    }
                    response = rpcSuccess(id: responseID, result: payload)
                } catch {
                    workActivity.finishCall(admittedWorkID, name: name, result: [:], failed: true)
                    let message = safeMessage(error)
                    response = rpcSuccess(id: responseID, result: toolResult(
                        structuredError(error), message: message, isError: true
                    ))
                }
                // Release the lease before publishing. A client cannot observe
                // the response before cleanup, while an adapter that stops
                // draining stdout cannot hold the global operation lock.
                operationLock.lock()
                if name == "file_search" { searchInProgress = false }
                else if name == "command_run" { activeCommandRuns = max(0, activeCommandRuns - 1) }
                else if name == "developer_inspect" {
                    activeDeveloperInspections = max(0, activeDeveloperInspections - 1)
                }
                else if name == "process_wait" { activeProcessWaits = max(0, activeProcessWaits - 1) }
                else if Self.isMediaTool(name) { mediaInProgress = false }
                else { brevoInProgress = false }
                operationLock.unlock()
                do { try write(response, to: output) }
                catch { responses.recordWriteFailure() }
            }
        }
        return true
    }

    private func resultSummary(name: String, result: JSONObject, arguments: JSONObject) -> String {
        let jobID = result["task_id"] as? String
        return ToolResultSummary.text(name: name, result: result, arguments: arguments,
            processContext: jobID.flatMap { processService.activityContext(taskID: $0) })
    }

    private func requireInitialized() throws {
        guard initializeResponded, initialized else {
            throw LocalMCPError.invalidRequest("MCP session is not initialized.")
        }
    }

    /// The outbound tunnel may reconnect a process-affine stdio target while the remote
    /// connector keeps its already-negotiated session and resumes with tools/list or tools/call.
    /// Accept that stateless compatibility path only for the explicitly selected web-tunnel
    /// surface. Direct desktop stdio remains strict and requires the normal MCP handshake.
    private func requireInitializedForCurrentSurface() throws {
        if connectorSurface == .webTunnel { return }
        try requireInitialized()
    }

    private func object(_ value: Any?, label: String) throws -> JSONObject {
        guard let object = value as? JSONObject else {
            throw LocalMCPError.invalidRequest("JSON object required for \(label).")
        }
        return object
    }

    private func stringAllowingEmpty(
        _ object: JSONObject,
        key: String,
        maximumBytes: Int = LocalWorkspaceService.maximumFileBytes
    ) throws -> String {
        guard let value = object[key] as? String,
            value.utf8.count <= maximumBytes
        else { throw LocalMCPError.invalidRequest("Bounded string required for \(key).") }
        return value
    }

    private func rpcSuccess(id: Any, result: JSONObject) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func rpcError(id: Any, code: Int, message: String) -> JSONObject {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
    }

    private func toolResult(
        _ structured: JSONObject,
        message: String,
        isError: Bool = false
    ) -> JSONObject {
        [
            "content": [["type": "text", "text": message]],
            "structuredContent": structured,
            "isError": isError,
        ]
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? LocalMCPError { return error.description }
        return "Direct local operation failed."
    }

    private func structuredError(_ error: Error) -> JSONObject {
        ["error": safeMessage(error), "error_detail": localErrorDetail(error)]
    }
}

extension LocalMCPServer {
    // All nested members are Swift value types constructed below, never mutable
    // Foundation reference containers. The private immutable snapshot is shared;
    // callers receive copy-on-write value snapshots through toolSpecs.
    private struct CatalogSnapshot: @unchecked Sendable {
        let specs: [JSONObject]
        let digest: String

        init() {
            let specs = LocalMCPServer.makeToolSpecs().map { original -> JSONObject in
                guard let name = original["name"] as? String,
                      !["work_task", "bridge_activity", "bridge_activity_view"].contains(name) else { return original }
                var spec = original
                var schema = spec["inputSchema"] as! JSONObject
                var properties = schema["properties"] as! JSONObject
                properties["work_id"] = ["type": "string", "format": "uuid", "maxLength": 36] as JSONObject
                properties["work_control_token"] = ["type": "string", "maxLength": 96] as JSONObject
                schema["properties"] = properties
                spec["inputSchema"] = schema
                return spec
            }
            guard let encoded = try? LocalJSON.encode(specs) else {
                preconditionFailure("The built-in MCP catalog must be valid JSON.")
            }
            self.specs = specs
            digest = LocalHash.sha256(encoded)
        }
    }

    private static let builtInCatalog = CatalogSnapshot()

    private static func stringSchema(maximumLength: Int) -> JSONObject {
        ["type": "string", "maxLength": maximumLength]
    }

    private static func integerSchema(minimum: Int, maximum: Int) -> JSONObject {
        ["type": "integer", "minimum": minimum, "maximum": maximum]
    }

    private static func booleanSchema() -> JSONObject { ["type": "boolean"] }

    private static func arraySchema(maximumItems: Int) -> JSONObject {
        [
            "type": "array",
            "maxItems": maximumItems,
            "items": ["type": "string", "maxLength": 16_384],
        ]
    }

    private static func spec(
        _ name: String,
        _ title: String,
        _ description: String,
        properties: JSONObject,
        required: [String],
        readOnly: Bool,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool = false
    ) -> JSONObject {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": [
                "type": "object",
                "additionalProperties": false,
                "properties": properties,
                "required": required,
            ],
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructiveHint ?? !readOnly,
                "idempotentHint": idempotentHint ?? readOnly,
                "openWorldHint": openWorldHint,
            ],
        ]
    }

    public static var toolSpecs: [JSONObject] {
        builtInCatalog.specs
    }

    static var catalogSHA256: String { builtInCatalog.digest }

    public static var discoveryGuide: String {
        "Reviewing a tool is not permission to execute it; never replay commands from earlier tasks. Reuse already-loaded schemas; host finds missing ones. tool_catalog: starters; query/category<=5; names return exact schemas; limit=current catalog count for full index; cannot load host tools. developer_inspect is read-only; developer_task adds no authority. Operator loop: set acceptance, inspect, act, verify tests/diff/errors, repair, finish when accepted. Multi-step: developer_task returns parent; else begin work_task and carry ID/token. Keep process/transaction tokens in chat; lists omit them. Verify and resolve each transaction: accept to keep or restore to roll back. Never nest parents; labels grant no identity/permission. Resume waiting_user as active. Finish after jobs stop; silence is not completion. Long-work checkpoint: IDs/cursors, transactions, verified results, next step; revalidate after restart. Evidence: actions, tests/diff/errors, log refs, truncation and unknowns. command_run times out; command_start returns task_id; process_output returns status/cursors. Inspect every batch result. Reconcile uncertain writes before retry. Respect host approvals and Work-mode gates."
    }

    private static func makeToolSpecs() -> [JSONObject] {
        let workspaceID = stringSchema(maximumLength: 36)
        let path = stringSchema(maximumLength: 4_096)
        let content = stringSchema(maximumLength: LocalWorkspaceService.maximumFileBytes)
        let sha = stringSchema(maximumLength: 64)
        let taskID = stringSchema(maximumLength: 36)
        let controlToken: JSONObject = ["type": "string", "maxLength": 96]
        var executable = stringSchema(maximumLength: 64)
        executable["description"] = "Supported command ID such as sh, python3, swift or git; not an absolute path such as /bin/sh. Pass argv separately in arguments. If unsure, consult command_list once for available IDs and reuse the result."
        return [
            spec("work_task", "Track a parent task",
                "Group a multi-step task; labels grant no access or authenticated identity. Optional scheduler_context requires workspace_id, is owner-memory state, and exposes fired→worker_started→result_ready→persisted→acknowledged. persisted requires a retained work-owned write transaction whose path and SHA still match the workspace artifact; this is evidence-backed within the current owner, not durable scheduling across restart. Scheduled work cannot finish completed before acknowledgement. begin returns work_id plus a creator-only work_control_token on the shared Web tunnel. Carry both for related calls and update/finish; tokens are never listed in activity.",
                properties: ["action": ["type": "string", "enum": ["begin", "update", "finish", "list"]],
                             "work_id": ["type": "string", "format": "uuid", "maxLength": 36],
                             "work_control_token": controlToken,
                             "title": stringSchema(maximumLength: 160), "chat_label": stringSchema(maximumLength: 160),
                             "workspace_id": workspaceID,
                             "scheduler_context": ["type": "object", "additionalProperties": false,
                                "properties": [
                                    "schedule_id": stringSchema(maximumLength: 128),
                                    "run_id": stringSchema(maximumLength: 128),
                                    "scheduled_for": stringSchema(maximumLength: 64),
                                    "fired_at": stringSchema(maximumLength: 64),
                                    "attempt": integerSchema(minimum: 1, maximum: 1000),
                                    "native_task_id": stringSchema(maximumLength: 128),
                                    "native_run_id": stringSchema(maximumLength: 128),
                                    "invocation_kind": ["type": "string", "enum": ["scheduled", "manual", "retry"]],
                                    "parent_task_id": stringSchema(maximumLength: 128),
                                ],
                                "required": ["schedule_id", "run_id", "scheduled_for", "fired_at"]],
                             "scheduler_phase": ["type": "string", "enum": ["worker_started", "result_ready", "persisted", "acknowledged"]],
                             "artifact_path": path,
                             "artifact_sha256": sha,
                             "write_transaction_id": taskID,
                             "persisted_at": stringSchema(maximumLength: 64),
                             "acknowledgement_id": stringSchema(maximumLength: 128),
                             "status": ["type": "string", "enum": ["active", "waiting_user", "completed", "failed"]]],
                required: ["action"], readOnly: false, destructiveHint: false, idempotentHint: false),
            spec(
                "bridge_capabilities", "Bridge capabilities",
                "Report the direct local runtime identity and boundaries.", properties: [:],
                required: [], readOnly: true),
            spec(
                "bridge_diagnostic", "Bridge diagnostic",
                "One-shot core diagnostic. Reports READY/DEGRADED/BLOCKED inputs without claiming host schemas are callable. Hosts must probe the named tools under binding_epoch and rebind when it changes.",
                properties: [:], required: [], readOnly: true),
            spec(
                "workspace_overview", "Workspace overview",
                "List registered workspaces. Relative paths or canonical absolute paths inside the selected root are accepted. Broad-access entries also disclose their root; credential paths remain blocked.",
                properties: [:], required: [], readOnly: true),
            spec(
                "workspace_resolve", "Resolve workspace",
                "Resolve one absolute local path to the most-specific registered workspace and relative path without registering or widening access.",
                properties: ["path": path], required: ["path"], readOnly: true),
            spec(
                "workspace_list", "Workspace list", "Deprecated compatibility alias; use workspace_overview for the same registered workspace list. Kept callable for existing chats.",
                properties: [:], required: [], readOnly: true),
            spec(
                "workspace_reload", "Reload workspaces",
                "Re-read the workspace allowlist without restarting; rejected while a process or undo transaction is retained. Restore pending transactions first.",
                properties: [:], required: [], readOnly: false),
            spec("media_inspect", "Inspect a creative transfer",
                "capabilities reads no credentials or network. prepare requires workspace_id/path and hashes one locally present JPEG/PNG/GIF/MP4/MOV, maximum 256 MiB, without sharing it. status requires workspace_id/request_id and reconciles only an existing private R2 receipt. No Meta API, picker, ad creation or URL renewal. Use prepare before asking to share a selected file; a local path cannot be passed to Meta Ads LOCAL_FILE upload.",
                properties: ["action": ["type": "string", "enum": ["capabilities", "prepare", "status"]],
                    "workspace_id": workspaceID, "path": path, "request_id": taskID],
                required: ["action"], readOnly: true, openWorldHint: true),
            spec("media_share", "Stage or revoke one approved creative",
                "Opt-in private R2 staging, disabled without owner-only storage/root configuration. publish requires workspace_id, request_id (stable UUID), path, expected_sha256 from prepare and confirm_public_link=true after the user's approval to share that exact file. expires_in_seconds defaults 900, range 60..3600. Returns a GET-only bearer media_url; anyone with it can download until expiry/revocation. No automatic PUT retry or link renewal. Pass URL to the existing Meta Ads URL upload only when authorized; verify its actual hash/video ID and readiness, then revoke with workspace_id/request_id. Expiry alone does not delete storage or downloaded copies. Unknown outcomes require status, not a new request ID. No caller endpoints, credentials, Meta writes, listeners or shell.",
                properties: ["action": ["type": "string", "enum": ["publish", "revoke"]],
                    "workspace_id": workspaceID, "path": path, "request_id": taskID,
                    "expected_sha256": sha, "confirm_public_link": booleanSchema(),
                    "expires_in_seconds": integerSchema(minimum: 60, maximum: 3_600)],
                required: ["action", "workspace_id", "request_id"], readOnly: false,
                destructiveHint: true, idempotentHint: true, openWorldHint: true),
            spec("desktop_open", "Open in Finder or a fixed viewer",
                "Pop up a local folder in Finder (action=folder), reveal a local item without executing it (reveal), open a supported document in fixed Preview/TextEdit, or activate finder/preview/textedit (application). Requires the owner's allow_desktop_open workspace setting. No browsers, URLs, custom handlers, arbitrary app paths or permission changes. request_accepted means macOS accepted it, not that the window was visually verified.",
                properties: ["workspace_id": workspaceID, "path": path,
                    "action": ["type": "string", "enum": DesktopOpen.actions],
                    "application": ["type": "string", "enum": DesktopOpen.applications.keys.sorted()]],
                required: ["workspace_id", "action"], readOnly: false, destructiveHint: false, idempotentHint: false),
            spec(
                "directory_list", "List directory",
                "List one workspace directory with deterministic cursor pagination.",
                properties: [
                    "workspace_id": workspaceID, "path": path, "recursive": booleanSchema(),
                    "maximum_entries": integerSchema(minimum: 1, maximum: 10_000),
                    "cursor": integerSchema(
                        minimum: 0, maximum: LocalWorkspaceService.maximumTreeEntries),
                ], required: ["workspace_id"], readOnly: true),
            spec(
                "file_stat", "File metadata",
                "Read non-following metadata and a file digest inside a registered workspace.",
                properties: ["workspace_id": workspaceID, "path": path],
                required: ["workspace_id", "path"], readOnly: true),
            spec(
                "file_stat_many", "Batch file metadata",
                "Inspect 1...32 paths in order, with per-item errors. SHA-256 is opt-in to avoid reading contents for metadata-only work. Not an atomic snapshot.",
                properties: ["workspace_id": workspaceID,
                    "paths": ["type": "array", "minItems": 1, "maxItems": 32, "items": path],
                    "include_sha256": booleanSchema()],
                required: ["workspace_id", "paths"], readOnly: true),
            spec(
                "file_read_many", "Batch read files",
                "Read initial chunks of 1...32 files within a shared byte budget. snapshot_consistent=true fingerprints every path before and after under the bridge mutation lock and rejects changed snapshots. Check each result, complete, EOF and next_offset; continue partial files using file_read.",
                properties: ["workspace_id": workspaceID,
                    "paths": ["type": "array", "minItems": 1, "maxItems": 32, "items": path],
                    "encoding": ["type": "string", "enum": ["utf8", "base64"]],
                    "maximum_bytes_per_file": integerSchema(minimum: 1, maximum: 262_144),
                    "maximum_total_bytes": integerSchema(minimum: 4, maximum: 1_048_576),
                    "snapshot_consistent": booleanSchema()],
                required: ["workspace_id", "paths"], readOnly: true),
            spec(
                "file_read", "Read file",
                "Read a bounded UTF-8 or base64 byte chunk with an explicit next offset and EOF marker.",
                properties: [
                    "workspace_id": workspaceID, "path": path,
                    "encoding": ["type": "string", "enum": ["utf8", "base64"]],
                    "maximum_bytes": integerSchema(
                        minimum: 1, maximum: LocalWorkspaceService.maximumFileBytes),
                    "offset": integerSchema(minimum: 0, maximum: Int.max),
                ], required: ["workspace_id", "path"], readOnly: true),
            spec(
                "file_search", "Search files",
                "Search names or bounded UTF-8 content with cursor pagination. Skips build/cache/vendor trees and reports unsearched dataless content. Cooperative time/read budgets return explicit partial results; narrow the path when a budget stops traversal. No mmap; known dataless placeholders are not opened. An OS-blocked syscall is not forcibly interruptible.",
                properties: [
                    "workspace_id": workspaceID, "path": path,
                    "query": stringSchema(maximumLength: 4_096), "case_sensitive": booleanSchema(),
                    "maximum_results": integerSchema(minimum: 1, maximum: 1_000),
                    "maximum_file_bytes": integerSchema(
                        minimum: 1, maximum: LocalWorkspaceService.maximumFileBytes),
                    "mode": ["type": "string", "enum": ["content", "name"]],
                    "cursor": integerSchema(minimum: 0, maximum: Int.max),
                    "include_ignored": booleanSchema(),
                    "maximum_duration_milliseconds": integerSchema(minimum: 1, maximum: 10_000),
                    "maximum_total_read_bytes": integerSchema(minimum: 1, maximum: 64 * 1_024 * 1_024),
                ], required: ["workspace_id", "query"], readOnly: true),
            spec(
                "file_write", "Write file",
                "Create or atomically replace one workspace file and return a rollback transaction.",
                properties: [
                    "workspace_id": workspaceID, "path": path, "content": content,
                    "encoding": ["type": "string", "enum": ["utf8", "base64"]],
                    "expected_sha256": sha, "create_only": booleanSchema(),
                ], required: ["workspace_id", "path", "content"], readOnly: false),
            spec(
                "file_patch", "Patch file",
                "Replace literal text against an expected file digest, optionally all occurrences via replace_all. For several unique edits in one file use file_apply_edits. Returns a rollback transaction.",
                properties: [
                    "workspace_id": workspaceID, "path": path, "old_text": content,
                    "new_text": content, "replace_all": booleanSchema(), "expected_sha256": sha,
                ], required: ["workspace_id", "path", "old_text", "new_text", "expected_sha256"],
                readOnly: false),
            spec(
                "file_append", "Append file",
                "Append UTF-8 or base64 bytes after verifying the current digest and return a rollback transaction.",
                properties: [
                    "workspace_id": workspaceID, "path": path, "content": content,
                    "encoding": ["type": "string", "enum": ["utf8", "base64"]],
                    "expected_sha256": sha,
                ], required: ["workspace_id", "path", "content", "expected_sha256"],
                readOnly: false),
            spec(
                "directory_create", "Create directory",
                "Create one workspace directory and return a rollback transaction.",
                properties: ["workspace_id": workspaceID, "path": path],
                required: ["workspace_id", "path"], readOnly: false),
            spec(
                "path_copy", "Copy path",
                "Copy one bounded file or directory tree within a registered workspace.",
                properties: [
                    "workspace_id": workspaceID, "source_path": path, "destination_path": path,
                ], required: ["workspace_id", "source_path", "destination_path"], readOnly: false),
            spec(
                "path_move", "Move path",
                "Move one bounded file or directory tree within a registered workspace.",
                properties: [
                    "workspace_id": workspaceID, "source_path": path, "destination_path": path,
                ], required: ["workspace_id", "source_path", "destination_path"], readOnly: false),
            spec(
                "path_remove", "Remove path recoverably",
                "Move one bounded workspace path into private same-workspace recovery and return a rollback transaction.",
                properties: ["workspace_id": workspaceID, "path": path],
                required: ["workspace_id", "path"], readOnly: false),
            spec(
                "transaction_restore", "Restore transaction",
                "Restore one in-process file or path transaction after verifying current state. On the shared Web tunnel, requires the transaction_control_token returned with the original mutation receipt; transaction_list never reveals it.",
                properties: ["transaction_id": stringSchema(maximumLength: 36),
                             "transaction_control_token": controlToken],
                required: ["transaction_id"], readOnly: false, destructiveHint: false),
            spec(
                "transaction_list", "List retained undo",
                "List up to 100 retained file-tool transactions as metadata only, with exact paths and retained-byte counts, without reading file contents. Follow next_cursor until complete; cursors expire on workspace reload or owner restart and pages are not a fixed snapshot. Returns instance_id for explicit acceptance. Missing undo is not proof an uncertain action succeeded.",
                properties: ["cursor": stringSchema(maximumLength: 64),
                             "maximum_transactions": integerSchema(minimum: 1, maximum: 100)],
                required: [], readOnly: true),
            spec(
                "transaction_accept", "Keep changes and release selected undo",
                "Irreversibly release only 1-128 named in-memory undo transactions when the user wants to keep the changes. Requires instance_id from this owner and, on the shared Web tunnel, one creator transaction_control_token per transaction ID in matching order. All IDs and capabilities are checked before any release; no accept-all, no file changes, no disk recovery deletion. Removal receipts include preserved recovery paths for manual recovery. Does not validate current files or prove task success; do not retry after uncertain delivery or accept merely to make a quota test pass.",
                properties: ["instance_id": stringSchema(maximumLength: 36),
                             "transaction_ids": ["type": "array", "minItems": 1,
                                                 "maxItems": 128, "uniqueItems": true,
                                                 "items": stringSchema(maximumLength: 36)],
                             "transaction_control_tokens": ["type": "array", "minItems": 1,
                                                 "maxItems": 128,
                                                 "items": controlToken]],
                required: ["instance_id", "transaction_ids"], readOnly: false, destructiveHint: true),
            spec(
                "command_run", "Run command",
                "Run one short supported executable or headless shell command and return its final output with loopback-only networking and a hard timeout. Its wait does not block other MCP requests. Up to eight command_run responses may be pending across chats; use command_start for builds, tests or further concurrent jobs.",
                properties: [
                    "workspace_id": workspaceID, "executable": executable,
                    "arguments": arraySchema(maximumItems: 128), "cwd": path,
                    "timeout_milliseconds": integerSchema(minimum: 100, maximum: 3_600_000),
                    "maximum_output_bytes": integerSchema(minimum: 1, maximum: 16_777_216),
                ], required: ["workspace_id", "executable", "arguments"], readOnly: false),
            spec("network_command", "Run with an owner-approved network grant",
                "Start a shell/project job with an existing owner-authored network grant ID. Grant fixes cwd, one IPv4 TCP port and expiry (max one hour). Child direct network is blocked except its authenticated ephemeral loopback CONNECT proxy; HTTPS_PROXY/ALL_PROXY are injected only into this job. Client must CONNECT to the exact granted IP:port; curl can use --connect-to to preserve the approved hostname and TLS checks. This is IP-level access, not hostname filtering; no DNS or system proxy change. Returns task_id plus a creator-only process_control_token on the shared Web tunnel; carry both to output/input/cancel tools. Proxy closes on job exit/cancel/expiry. Cannot create/extend grants, change destinations/cwd, access credentials or elevate. Ordinary command_run/start remain loopback-only. Never print proxy environment credentials.",
                properties: ["workspace_id": workspaceID, "grant_id": taskID,
                    "executable": executable, "arguments": arraySchema(maximumItems: 128),
                    "maximum_output_bytes": integerSchema(minimum: 1, maximum: 1_048_576)],
                required: ["workspace_id", "grant_id", "executable", "arguments"], readOnly: false, openWorldHint: true),
            spec(
                "command_start", "Start command",
                "Start builds, tests, long-running commands, or a persistent headless shell with a pollable handle and no Terminal window. No timeout_milliseconds: start once and retain task_id. On the shared Web tunnel it also returns a creator-only process_control_token; carry both to output/input/cancel/wait. process_output includes status and cursors; use process_status only when logs are not needed. process_cancel stops the job.",
                properties: [
                    "workspace_id": workspaceID, "executable": executable,
                    "arguments": arraySchema(maximumItems: 128), "cwd": path,
                    "maximum_output_bytes": integerSchema(minimum: 1, maximum: 16_777_216),
                ], required: ["workspace_id", "executable", "arguments"], readOnly: false),
            spec(
                "process_status", "Process status",
                "Read status without consuming logs. If logs are also needed, process_output already includes status. After final drain/cancellation, metadata-only status remains for up to 5 minutes and 128 completions; status_only has no output/input/cancel handle. Restart invalidates it.",
                properties: ["task_id": taskID], required: ["task_id"], readOnly: true),
            spec(
                "process_output", "Process output",
                "Read status plus bounded incremental stdout/stderr and next cursors for one job. Shared Web-tunnel jobs require the process_control_token returned by their start call. Includes running, exit_code, drop/truncation and session_retained; avoid a separate status call when sufficient. Fully draining completed output releases the handle unless its original command_run response is pending; check session_retained. Do not replay an uncertain consumed read blindly.",
                properties: [
                    "task_id": taskID, "stdout_cursor": integerSchema(minimum: 0, maximum: Int.max),
                    "stderr_cursor": integerSchema(minimum: 0, maximum: Int.max),
                    "process_control_token": controlToken,
                    "maximum_bytes_per_stream": integerSchema(minimum: 1, maximum: 1_048_576),
                ], required: ["task_id"], readOnly: true, idempotentHint: false),
            spec(
                "process_list", "Process list",
                "List processes and persistent shell sessions owned by this MCP instance.",
                properties: [:], required: [], readOnly: true),
            spec(
                "process_input", "Process input",
                "Non-blockingly write bounded UTF-8 or base64 input; retry only the reported remaining suffix after a partial write.",
                properties: [
                    "task_id": taskID, "content": stringSchema(maximumLength: 65_536),
                    "process_control_token": controlToken,
                    "encoding": ["type": "string", "enum": ["utf8", "base64"]],
                    "close_stdin": booleanSchema(),
                ], required: ["task_id", "content"], readOnly: false),
            spec(
                "process_cancel", "Cancel process",
                "Terminate one process group started by this MCP instance.",
                properties: ["task_id": taskID, "process_control_token": controlToken],
                required: ["task_id"], readOnly: false),
        ] + ExpandedToolCatalog.specs() + ActivityWidget.toolSpecs
    }
}
