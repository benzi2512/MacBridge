import AppKit
import Darwin
import SwiftUI
import MacBridgeLocalCore

enum ObserverPollingCadence {
    static func delayNanoseconds(appActive: Bool, activeWork: Bool, lowPower: Bool,
                                 consecutiveFailures: Int, menuBarOnly: Bool = false) -> UInt64 {
        // A disconnected owner cannot provide live progress. Back off without
        // retrying faster than the foreground/background baseline; Connect
        // remains an immediate, explicit read and resets this backoff.
        let baseline: UInt64 = menuBarOnly ? 30 : appActive ? (activeWork ? 1 : 3) : 5
        let failureDelay: UInt64 = consecutiveFailures > 0
            ? min(30, 3 * UInt64(1 << min(consecutiveFailures - 1, 4))) : 0
        return max(max(baseline, failureDelay), lowPower ? 5 : 0) * 1_000_000_000
    }
}

@MainActor
final class ObserverModel: ObservableObject {
    typealias Exchange = @MainActor ([String: Any]) async throws -> [String: Any]
    private(set) var snapshot: [String: Any] = [:]
    @Published var detail = ""
    @Published var detailResult: [String: Any] = [:]
    @Published var detailKind: DetailPresentation.Kind = .metadata
    @Published var notice = "Connect to an observer-enabled MacBridge owner. This window never starts MCP."
    @Published var connected = false
    @Published var busy = false
    @Published var commandInFlight = false
    @Published var selection: String? {
        didSet {
            // Clear old detail synchronously. A later SwiftUI callback must not
            // erase the expiry message refresh() sets after deselecting a handle.
            if oldValue != selection { resetDetailNavigation() }
        }
    }
    @Published var workspace = "all"
    @Published var receipt: String?
    @Published var receiptDetail: [String: Any] = [:]
    @Published private(set) var outputPage: OutputPage?
    @Published private(set) var detailLoading = false
    @Published var selectedFilePreview: SelectedFilePreview?
    @Published private(set) var previewLoading = false
    @Published private(set) var previewNotice = ""
    var previewsVisible = false
    @Published var filePreviewLive = true
    private var previewRequests = FilePreviewRequestGate()
    private var previewBlockedEvent: String?
    @Published private(set) var previousOutputPages: [OutputCursor] = []
    private var outputCursor = OutputCursor()
    private var detailRequest = UUID()
    private(set) var directory = ""
    @Published private(set) var owner: String?
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private var snapshotRequest: (id: UUID, generation: UUID)?
    private var consecutiveSnapshotFailures = 0
    private var rediscoverOwner = false
    private var contextNow = Date()
    private var nextContextExpiry: Date?
    // Both the dashboard and compact surfaces read the same derived feed many
    // times per update. Retain only All and one workspace, never a feed history.
    // Health is part of the key because refresh updates it after the snapshot.
    private struct CachedFeed {
        let workspace: String
        let connected: Bool
        let stale: Bool
        let value: ActivityFeed
    }
    private var allFeedCache: CachedFeed?
    private var workspaceFeedCache: CachedFeed?
    // Internal synthetic transport seam; normal app initialization always uses
    // the private, peer-validated ObserverSocket exchange below.
    private let exchangeOverride: Exchange?
    // A visible status item must not stay falsely Connected forever when every
    // window is closed. Reuse the one loop at a low-frequency 30-second cadence.
    var menuBarVisible = false

    init(exchange: Exchange? = nil) {
        exchangeOverride = exchange
    }

    deinit { polling?.cancel() }

    var jobs: [[String: Any]] { snapshot["jobs"] as? [[String: Any]] ?? [] }
    var workItems: [[String: Any]] { snapshot["work_items"] as? [[String: Any]] ?? [] }
    var transactions: [[String: Any]] { snapshot["transactions"] as? [[String: Any]] ?? [] }
    var allHistory: [[String: Any]] {
        Array((snapshot["history"] as? [[String: Any]] ?? []).reversed())
    }
    var history: [[String: Any]] {
        // Use the same explicit parent scope as the visible feed, otherwise a
        // grouped process receipt could appear but lose selection/detail here.
        activityFeed.items.filter { $0.kind == .call }.map(\.raw)
    }
    var activityFeed: ActivityFeed {
        makeActivityFeed(workspace: workspace)
    }
    var allActivityFeed: ActivityFeed {
        makeActivityFeed(workspace: "all")
    }
    private func makeActivityFeed(workspace: String) -> ActivityFeed {
        let stale = busy || snapshot["snapshot_stale"] as? Bool == true || snapshot["jobs"] == nil
        let cached = workspace == "all" ? allFeedCache : workspaceFeedCache
        if let cached, cached.workspace == workspace, cached.connected == connected, cached.stale == stale {
            return cached.value
        }
        let value = ActivityFeed(history: allHistory, jobs: jobs, workItems: workItems,
            workspaces: snapshot["workspaces"] as? [[String: Any]] ?? [],
            workspace: workspace, connected: connected, stale: stale, now: contextNow)
        let entry = CachedFeed(workspace: workspace, connected: connected, stale: stale, value: value)
        if workspace == "all" { allFeedCache = entry } else { workspaceFeedCache = entry }
        return value
    }

    func selectGlobalActivity(_ id: String) {
        let visible = activityFeed
        if !visible.items.contains(where: { $0.id == id })
            && !visible.groups.contains(where: { $0.id == id })
            && !visible.contextGroups.contains(where: { $0.id == id }) {
            workspace = "all"
        }
        selection = id
    }
    var selectedActivity: ActivityItem? {
        activityFeed.items.first { $0.id == selection }
    }
    var selectedWork: WorkActivity? { activityFeed.groups.first { $0.id == selection } }
    var selectedContext: ContextActivity? { activityFeed.contextGroups.first { $0.id == selection } }
    var selectedActivityContext: ContextActivity? {
        guard let id = selectedActivity?.id else { return nil }
        return activityFeed.contextGroups.first { $0.children.contains { $0.id == id } }
    }
    var selectedActivityWork: WorkActivity? {
        guard let workID = selectedActivity?.workID else { return nil }
        return activityFeed.groups.first { $0.workID == workID }
    }
    var canControl: Bool { connected && !busy && !commandInFlight && snapshot["snapshot_stale"] as? Bool != true }
    var outputPagingAvailable: Bool { snapshot["observer_output_pagination"] as? Bool == true }
    var canInspect: Bool { canControl && !detailLoading }
    var activitySummary: String {
        let feed = activityFeed
        guard connected else { return "Activity unavailable · MacBridge is not connected" }
        let activeTasks = feed.groups.filter { $0.active }
        if !activeTasks.isEmpty {
            let waiting = activeTasks.filter { !$0.executing }.count
            return "\(activeTasks.count) active \(activeTasks.count == 1 ? "task" : "tasks")"
                + (waiting > 0 ? " · \(waiting) waiting or awaiting an update" : " · executing MB work")
        }
        if feed.runningCount > 0 {
            return "\(feed.runningCount) in progress" + (feed.jobsCurrent ? "" : " · background job state is not current")
        }
        let recentContexts = feed.contextGroups.filter { $0.recent }.count
        if recentContexts > 0 {
            return "\(recentContexts) recent \(recentContexts == 1 ? "work context" : "work contexts") · no process running"
        }
        return feed.jobsCurrent ? "No MB work running in this workspace · recent actions below"
            : "Owner busy · background job state is not current"
    }
    var selectedJob: [String: Any]? { jobs.first { "job:" + ($0["task_id"] as? String ?? "") == selection } }
    var selectedTransaction: [String: Any]? { transactions.first { "tx:" + ($0["transaction_id"] as? String ?? "") == selection } }
    var selectedPreviewEventID: String? {
        guard snapshot["observer_file_preview"] as? Bool == true,
              let item = selectedActivity, item.kind == .call,
              item.raw["state"] as? String == "returned",
              ["file_read", "file_read_lines", "file_tail", "file_stat", "file_write", "file_patch", "file_apply_edits", "file_append"]
                .contains(item.raw["tool"] as? String ?? "") else { return nil }
        return item.raw["id"] as? String
    }
    var canOpenPreview: Bool {
        guard canControl, previewRequests.actionID == nil, let preview = selectedFilePreview,
              preview.matchesSelection(owner: owner, eventID: selectedPreviewEventID,
                                       connected: connected, stale: snapshot["snapshot_stale"] as? Bool == true) else { return false }
        return true
    }

    func reconnect() {
        guard !commandInFlight, !directory.isEmpty else { return }
        attach(directory)
    }

    func resumeObservation() {
        // Wake/activation refreshes only the observer. Neither this method nor
        // the read loop starts a core, touches credentials or retries a control.
        // Do not cancel an in-flight snapshot on repeated activation events:
        // the existing single-flight gate coalesces these immediate reads.
        guard !directory.isEmpty else { return }
        guard polling != nil else {
            startPolling(refreshImmediately: true)
            return
        }
        Task { [weak self] in await self?.refresh(automatic: true) }
    }

    func chooseOwner() {
        let panel = NSOpenPanel()
        panel.title = "Choose the private observer directory"
        panel.message = "Select a 0700 directory belonging to a running observer-enabled MCP. No server will be launched."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path { attach(path) }
    }

    func attach(_ path: String) {
        guard !commandInFlight else { return }
        generation = UUID()
        consecutiveSnapshotFailures = 0
        rediscoverOwner = false
        if let canonical = realpath(path, nil) {
            directory = String(cString: canonical)
            free(canonical)
        } else { directory = path }
        owner = nil
        updateSnapshot([:]); selection = nil; detail = ""
        resetDetailNavigation()
        connected = false
        notice = "Connecting to the selected owner…"
        startPolling(refreshImmediately: true)
    }

    func startPolling(refreshImmediately: Bool = false) {
        polling?.cancel()
        polling = nil
        // An unattached model has nothing to poll. App startup explicitly
        // selects the known private endpoint even before its socket exists.
        guard !directory.isEmpty else { return }
        polling = Task { [weak self] in
            // Connect is an explicit user action. Read its first snapshot even
            // while AppKit is settling the open panel/window occlusion state.
            // Offline retries use backoff; connected reads stay visibility-bound.
            var explicitRefresh = refreshImmediately
            while !Task.isCancelled {
                // Release the model before sleeping. Holding `self` inside this
                // loop would otherwise keep it alive until stopPolling is called.
                guard let delay = await self?.pollingCycle(refreshImmediately: explicitRefresh) else { return }
                // Consume the explicit first read in this cycle, then sleep.
                // A visible window must not issue a second immediate snapshot.
                explicitRefresh = false
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
        }
    }

    func pollingCycle(refreshImmediately: Bool, visibleWindow: Bool? = nil) async -> UInt64 {
        // A startup race must recover even when only the menu bar is shown.
        // Offline retries are bounded by the backoff. A status item without
        // windows uses the same loop at a slower 30-second cadence.
        let visible = visibleWindow ?? (!NSApp.isHidden && NSApp.windows.contains(where: {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }))
        if refreshImmediately || !connected || visible || menuBarVisible {
            await refresh(automatic: !refreshImmediately)
        }
        let activeWork = busy || jobs.contains { $0["running"] as? Bool == true }
        return ObserverPollingCadence.delayNanoseconds(appActive: NSApp.isActive, activeWork: activeWork,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, consecutiveFailures: consecutiveSnapshotFailures,
            menuBarOnly: !visible && menuBarVisible)
    }

    func stopPolling() { polling?.cancel(); polling = nil }

    // Preserve the freshest raw metadata without redrawing the entire window
    // for clocks that the view does not display. All other fields, including
    // stale/busy flags, owner identity and job output counts, remain observable.
    func updateSnapshot(_ result: [String: Any], now: Date = Date()) {
        var previous = snapshot
        var next = result
        for key in ["snapshot_ms", "uptime_milliseconds"] {
            previous.removeValue(forKey: key)
            next.removeValue(forKey: key)
        }
        let changed = !NSDictionary(dictionary: previous).isEqual(to: next)
        // A clock correction can move a retained timestamp into the future.
        // Re-evaluate then as well as at the normal Recent boundary.
        let expired = now < contextNow || (nextContextExpiry.map { now >= $0 } ?? false)
        if changed || expired {
            objectWillChange.send()
        }
        snapshot = result
        contextNow = now
        if changed || expired {
            allFeedCache = nil
            workspaceFeedCache = nil
            // Reuse the visible-window refresh cycle; publish once at a Recent
            // boundary, not on every clock tick. No new timer or history store.
            // Include hidden workspaces so switching scope cannot leave a
            // Recent row stuck after its deadline on clock-only snapshots.
            let all = allActivityFeed
            nextContextExpiry = all.contextGroups
                .flatMap { context -> [Date] in
                    let updated = context.updatedMilliseconds / 1000
                    guard updated.isFinite, updated > 0 else { return [] }
                    // A future-dated receipt becomes Recent when the local
                    // clock catches up; do not keep its cached Idle state.
                    return [Date(timeIntervalSince1970: updated),
                            Date(timeIntervalSince1970: updated + ContextActivity.recentWindowSeconds)]
                }
                .filter { $0 > now }.min()
        }
    }

    private func exchange(_ request: [String: Any]) async throws -> [String: Any] {
        if let exchangeOverride { return try await exchangeOverride(request) }
        let payload = try JSONSerialization.data(withJSONObject: request)
        let path = directory
        let response = try await Task.detached(priority: .utility) {
            try ObserverSocket.request(directory: path, payload: payload)
        }.value
        guard let wrapper = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw NSError(domain: "MB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid owner response"])
        }
        guard wrapper["ok"] as? Bool == true else {
            throw NSError(domain: "MB", code: 2, userInfo: [NSLocalizedDescriptionKey: wrapper["error"] as? String ?? "Owner rejected request"])
        }
        return wrapper["result"] as? [String: Any] ?? [:]
    }

    func refresh(automatic: Bool = false) async {
        let ticket = generation
        guard !directory.isEmpty, !commandInFlight else { return }
        // Automatic snapshots are single-flight. An explicit post-action read
        // must not be discarded behind an older poll; it supersedes that read.
        if automatic, snapshotRequest?.generation == ticket { return }
        let requestID = UUID()
        snapshotRequest = (requestID, ticket)
        defer { if snapshotRequest?.id == requestID { snapshotRequest = nil } }
        var request: [String: Any] = ["action": "snapshot"]
        let discovering = rediscoverOwner
        if let owner, !discovering { request["instance_id"] = owner }
        do {
            let result = try await exchange(request)
            guard ticket == generation, snapshotRequest?.id == requestID,
                  !Task.isCancelled, !commandInFlight else { return }
            guard let actual = result["instance_id"] as? String, UUID(uuidString: actual) != nil else {
                throw NSError(domain: "MB", code: 3, userInfo: [NSLocalizedDescriptionKey: "Owner identity unavailable"])
            }
            if let owner, owner != actual, !discovering {
                throw NSError(domain: "MB", code: 4, userInfo: [NSLocalizedDescriptionKey: "Owner changed; checking the current owner on the next refresh"])
            }
            if let owner, owner != actual {
                // Invalidate every old-owner read before exposing the replacement.
                // Only snapshot discovery is retried; controls are never replayed.
                generation = UUID()
                snapshotRequest = (requestID, generation)
                selection = nil
                workspace = "all"
                resetDetailNavigation()
                if let receipt, !receipt.hasPrefix("Previous owner · ") {
                    self.receipt = "Previous owner · " + receipt
                }
                receiptDetail = [:]
            }
            consecutiveSnapshotFailures = 0
            rediscoverOwner = false
            updateSnapshot(result)
            if !connected { connected = true }
            let currentBusy = result["busy"] as? Bool == true
            if busy != currentBusy { busy = currentBusy }
            // Publish owner after its snapshot so compact surfaces can recapture
            // current IDs once, without disturbing same-owner reading order.
            if owner != actual { owner = actual }
            if let selected = selection, selected.hasPrefix("event:") {
                if let event = history.first(where: { "event:" + ($0["id"] as? String ?? "") == selected }) {
                    if !NSDictionary(dictionary: detailResult).isEqual(to: event) { detailResult = event }
                    if detailKind != .event { detailKind = .event }
                } else {
                    selection = nil; resetDetailNavigation()
                }
            }
            if let selection,
               (selection.hasPrefix("job:") && selectedJob == nil || selection.hasPrefix("tx:") && selectedTransaction == nil
                || selection.hasPrefix("work:") && selectedWork == nil
                || selection.hasPrefix("context:") && selectedContext == nil) {
                self.selection = nil
                detail = "This handle is no longer active on the owner. See recent activity or the backend receipt."
            }
            let currentNotice = busy ? "Owner busy · cached snapshot. Controls unavailable." : "Connected to local owner · ChatGPT/tunnel reachability is not inferred."
            if notice != currentNotice { notice = currentNotice }
            if previewsVisible && filePreviewLive { _ = await refreshFilePreview() }
        } catch {
            guard ticket == generation, snapshotRequest?.id == requestID,
                  !Task.isCancelled, !commandInFlight else { return }
            recordSnapshotFailure(error)
        }
    }

    func recordSnapshotFailure(_ error: Error) {
        rediscoverOwner = true
        let firstFailure = consecutiveSnapshotFailures == 0
        consecutiveSnapshotFailures = min(5, consecutiveSnapshotFailures + 1)
        if connected { connected = false }
        if busy { busy = false }
        if firstFailure {
            resetDetailNavigation()
            detail = "Owner unavailable. Previous detail is stale and has been cleared; the next refresh will check the current owner without replaying actions."
        }
        let currentNotice = "Offline / unknown · " + Self.explanation(error)
        if notice != currentNotice { notice = currentNotice }
    }

    func resetDetailNavigation() {
        detailRequest = UUID()
        detailLoading = false
        outputPage = nil
        detailResult = [:]; detail = ""; detailKind = .metadata
        previousOutputPages = []
        outputCursor = OutputCursor()
        clearFilePreview()
    }

    func clearFilePreview() {
        previewRequests.invalidateRead(); previewLoading = false
        previewBlockedEvent = nil
        selectedFilePreview = nil; previewNotice = ""
    }

    /// Uses the existing visible-window refresh cycle. Unchanged replies carry
    /// only a stat version; no new timer, file watcher or whole-file hash.
    @discardableResult
    func refreshFilePreview(force: Bool = false, forAction actionID: UUID? = nil) async -> SelectedFilePreview? {
        guard previewsVisible, canControl, let owner,
              let event = selectedPreviewEventID else { return nil }
        guard force || previewBlockedEvent != event else { return nil }
        guard let requestID = previewRequests.beginRead(forAction: actionID) else { return nil }
        let ticket = generation, chosen = selection
        if force || selectedFilePreview == nil { previewLoading = true }
        defer { if previewRequests.finishRead(requestID), previewLoading { previewLoading = false } }
        var request: [String: Any] = ["action": "file_preview", "instance_id": owner, "event_id": event]
        if !force, let previous = selectedFilePreview, previous.eventID == event, previous.owner == owner {
            request["known_version"] = previous.version
        }
        do {
            let response = try await exchange(request)
            guard ticket == generation, chosen == selection, owner == self.owner,
                  previewRequests.requestID == requestID, previewsVisible else { return nil }
            guard let next = SelectedFilePreview(response, expectedOwner: owner, expectedEvent: event, previous: selectedFilePreview) else {
                throw NSError(domain: "MB", code: 5, userInfo: [NSLocalizedDescriptionKey: "File preview could not be verified"])
            }
            if selectedFilePreview?.version != next.version || selectedFilePreview?.path != next.path {
                selectedFilePreview = next
            }
            if !previewNotice.isEmpty { previewNotice = "" }
            previewBlockedEvent = nil
            return next
        } catch {
            guard ticket == generation, chosen == selection, previewRequests.requestID == requestID else { return nil }
            selectedFilePreview = nil
            previewBlockedEvent = event
            previewNotice = "Preview unavailable: " + Self.explanation(error)
            return nil
        }
    }

    func openSelectedFile(reveal: Bool) async {
        guard canOpenPreview, let chosen = selection,
              let actionID = previewRequests.beginAction() else { return }
        // Publish only explicit action transitions, never unchanged auto-polls.
        objectWillChange.send()
        defer { if previewRequests.finishAction(actionID) { objectWillChange.send() } }
        // Revalidate with the owner immediately before any explicit OS action.
        guard let preview = await refreshFilePreview(force: true, forAction: actionID), selection == chosen,
              preview.owner == owner, preview.eventID == selectedPreviewEventID, canControl else { return }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([preview.url]) }
        else {
            let configuration = NSWorkspace.OpenConfiguration()
            do {
                _ = try await NSWorkspace.shared.open([preview.url],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                    configuration: configuration)
            } catch {
                guard selection == chosen else { return }
                previewNotice = "Could not open TextEdit: " + error.localizedDescription
            }
        }
    }

    func navigateOutput(_ direction: Int) async {
        guard canInspect, selectedJob != nil, outputPagingAvailable else { return }
        if direction == 0 {
            previousOutputPages = []; outputCursor = OutputCursor()
        } else if direction < 0 {
            guard let previous = previousOutputPages.popLast() else { return }
            outputCursor = previous
        } else {
            guard let page = outputPage, page.hasMore || page.running else { return }
            if outputCursor != page.next {
                previousOutputPages.append(outputCursor)
                if previousOutputPages.count > 256 { previousOutputPages.removeFirst() }
                outputCursor = page.next
            }
        }
        await inspectSelection()
    }

    func inspectSelection() async {
        guard canInspect, let owner else { return }
        let ticket = generation
        let chosen = selection
        let requestID = UUID()
        detailRequest = requestID
        detailLoading = true
        defer { if detailRequest == requestID { detailLoading = false } }
        var request: [String: Any]
        if let job = selectedJob {
            request = ["action": "output", "instance_id": owner, "task_id": job["task_id"] ?? ""]
            if outputPagingAvailable {
                request["stdout_cursor"] = outputCursor.stdout
                request["stderr_cursor"] = outputCursor.stderr
            }
        } else if let tx = selectedTransaction {
            request = ["action": "transaction", "instance_id": owner,
                       "transaction_id": tx["transaction_id"] ?? "", "workspace_id": tx["workspace_id"] ?? ""]
        } else {
            if let work = selectedWork {
                detailResult = work.raw; detailKind = .metadata; detail = ""
            } else if selectedContext != nil {
                detailResult = [:]; detailKind = .metadata; detail = ""
            } else if let event = history.first(where: { "event:" + ($0["id"] as? String ?? "") == selection }) {
                detailResult = event; detailKind = .event; detail = ""
            }
            _ = await refreshFilePreview(force: true)
            return
        }
        do {
            let result = try await exchange(request)
            guard ticket == generation, chosen == selection, detailRequest == requestID else { return }
            detailResult = result
            if let comparison = TextComparison.render(result) {
                detailKind = .change; detail = comparison
            } else if let page = OutputPage(result) {
                detailKind = .output
                outputPage = page
                detail = ""
            } else { outputPage = nil; detailKind = .metadata; detail = "Owner returned metadata only; no text preview is available." }
        } catch {
            guard ticket == generation, chosen == selection, detailRequest == requestID else { return }
            outputPage = nil
            detailResult = [:]; detailKind = .metadata
            detail = "Unavailable: " + Self.explanation(error) + "\nNo action was replayed."
        }
    }

    func control(_ action: PendingControl) async {
        receiptDetail = [:]
        guard canControl, owner == action.owner else {
            receipt = "Owner changed or is unavailable. Nothing sent."
            return
        }
        let ticket = generation
        do {
            commandInFlight = true
            defer { commandInFlight = false }
            do {
                var request: [String: Any] = ["action": action.kind, "instance_id": action.owner]
                if action.kind == "cancel" { request["task_id"] = action.id }
                else { request["transaction_id"] = action.id; request["workspace_id"] = action.workspace }
                let result = try await exchange(request)
                guard ticket == generation else { return }
                receiptDetail = result
                receipt = DetailPresentation.receiptSummary(result, action: action.kind)
            } catch {
                guard ticket == generation else { return }
                receipt = "No automatic retry. If transport was interrupted, the outcome is unknown; refresh and inspect state.\n" + error.localizedDescription
            }
        }
        await refresh()
    }

    static func pretty(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "Details unavailable" }
        return text
    }

    static func explanation(_ error: Error) -> String {
        (error as? LocalMCPError)?.description ?? error.localizedDescription
    }
}

struct PendingControl {
    let kind: String
    let owner: String
    let id: String
    var workspace = ""
}

struct ObserverView: View {
    @StateObject private var model: ObserverModel
    @State private var pending: PendingControl?
    @State private var confirm = false
    @State private var showDetails = false
    @State private var showChatHelp = false
    @State private var showSidebar = true
    @State private var textScale: CGFloat = 1
    @State private var activityQuery = ""
    @State private var activityFilter: ActivityPresentation.Filter = .all
    @State private var expandedWorks = Set<String>()
    @State private var readingOrder: ActivityReadingOrder?
    @State private var inspectorTab = InspectorTab.activity
    @FocusState private var searchFocused: Bool
    private let accent = ObserverStyle.accent
    private let managesLifecycle: Bool
    private let recoveryPreferences: ObserverPreferences?
    private let openSettings: (() -> Void)?
    private let openSetup: (() -> Void)?

    @MainActor
    init(model: ObserverModel? = nil, initialFilter: ActivityPresentation.Filter = .all, showsDetails: Bool = false,
         initialTextScale: CGFloat = 1, showsSidebar: Bool = true, managesLifecycle: Bool = true,
         recoveryPreferences: ObserverPreferences? = nil, openSettings: (() -> Void)? = nil,
         openSetup: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: model ?? ObserverModel())
        _activityFilter = State(initialValue: initialFilter)
        _showDetails = State(initialValue: showsDetails)
        _showSidebar = State(initialValue: showsSidebar)
        _textScale = State(initialValue: min(1.15, max(0.85, initialTextScale)))
        self.managesLifecycle = managesLifecycle
        self.recoveryPreferences = recoveryPreferences
        self.openSettings = openSettings
        self.openSetup = openSetup
    }
    private var confirmationText: String {
        let id = pending?.id ?? ""
        let owner = pending?.owner ?? ""
        return "Only \(id) on owner \(owner). No action will be replayed on reconnect."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(showSidebar ? "Hide workspaces" : "Show workspaces")
                MacBridgeMark(size: 28, style: .monochrome)
                Text("MacBridge").font(.headline)
                Spacer()
                if let recoveryPreferences {
                    WidgetRecoveryButton(preferences: recoveryPreferences)
                }
                Label(model.connected ? (model.busy ? "Busy" : "Connected") : "Offline",
                      systemImage: model.connected ? "circle.inset.filled" : "circle.dashed")
                    .foregroundStyle(model.connected ? ObserverStyle.running : ObserverStyle.idle)
                    .font(.callout)
                Button { model.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.commandInFlight || model.directory.isEmpty)
                    .help("Refresh local connection. Does not restart MCP or refresh ChatGPT's tool registry.")
                    .accessibilityLabel("Refresh connection")
                HStack(spacing: 4) {
                    Button { textScale = max(0.85, textScale - 0.1) } label: { Image(systemName: "minus") }
                        .help("Smaller text").keyboardShortcut("-").disabled(textScale <= 0.85)
                    Button("\(Int((textScale * 100).rounded()))%") { textScale = 1 }
                        .font(.caption.monospacedDigit()).help("Reset text size").keyboardShortcut("0")
                    Button { textScale = min(1.15, textScale + 0.1) } label: { Image(systemName: "plus") }
                        .help("Larger text").keyboardShortcut("+").disabled(textScale >= 1.15)
                }
                if model.directory.isEmpty {
                    Button("Connect…", action: model.chooseOwner).disabled(model.commandInFlight)
                }
                Menu {
                    Button("Choose connection…", action: model.chooseOwner).keyboardShortcut("o")
                        .disabled(model.commandInFlight)
                    Button("ChatGPT connection help…") { showChatHelp = true }
                    if let openSetup { Button("Set up local connection…", action: openSetup) }
                    if let openSettings { Button("Settings…", action: openSettings).keyboardShortcut(",") }
                } label: { Image(systemName: "ellipsis") }
                    .help("Connection options and help")
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(showDetails ? "Hide details" : "Show details")
                .accessibilityLabel(showDetails ? "Hide details" : "Show details")
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            HSplitView {
              if showSidebar {
                VStack(alignment: .leading, spacing: 12) {
                    Text("WORKSPACES").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
                    List(selection: $model.workspace) {
                        Label("All observed activity", systemImage: "square.stack.3d.up").tag("all")
                        ForEach(model.snapshot["workspaces"] as? [[String: Any]] ?? [], id: \.workspaceKey) { item in
                            Label(item["display_name"] as? String ?? "Workspace", systemImage: "folder")
                                .tag(item["workspace_id"] as? String ?? "")
                        }
                    }.listStyle(.sidebar)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Jobs keep running when closed").font(.caption2).lineLimit(1)
                            .help("This window observes one headless runtime. Closing it does not stop MCP or its jobs.")
                    }.foregroundStyle(.secondary).padding(16)
                }.padding(.top, 18).frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                    .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .scrollContentBackground(.hidden)
                    .padding(8)
              }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Activity").font(.title2.weight(.semibold))
                        Spacer()
                        if readingOrder != nil {
                            Button("Show latest") { readingOrder = nil }
                                .font(.caption)
                                .help("Resume live ordering and show new rows. While reading, positions stay fixed and statuses and counts still update; completed rows can remain visible.")
                        }
                        if let count = model.snapshot["transaction_count"] as? Int, count > 100 {
                            Text("100 of \(count) changes shown").font(.caption).foregroundStyle(ObserverStyle.waiting)
                        }
                    }
                    Text(model.connected ? (model.busy ? "Busy · last snapshot" : "Local runtime connected") : model.notice)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(model.notice)
                    if model.snapshot.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "cable.connector").font(.largeTitle).foregroundStyle(accent)
                            Text("Observe a running MacBridge").font(.headline)
                            Text("No demo jobs. No second MCP. Connect to see actual tool activity, jobs and changes.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        let feed = model.activityFeed
                        let currentOrder = ActivityReadingOrder(feed: feed, transactions: model.transactions,
                            owner: model.owner, workspace: model.workspace, query: activityQuery, filter: activityFilter)
                        let order = readingOrder.flatMap {
                            $0.matches(owner: model.owner, workspace: model.workspace, query: activityQuery, filter: activityFilter) ? $0 : nil
                        } ?? currentOrder
                        Label(model.activitySummary, systemImage: "list.bullet.rectangle")
                            .font(.callout.weight(.medium)).foregroundStyle(accent)
                            .lineLimit(1).help(model.activitySummary)
                            .accessibilityIdentifier("activity-summary")
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Find tasks, chat labels, commands or files", text: $activityQuery).focused($searchFocused)
                                .textFieldStyle(.plain).accessibilityLabel("Find tasks, chat labels, commands or files")
                                .onChange(of: activityQuery) { value in
                                    if value.count > 256 { activityQuery = String(value.prefix(256)) }
                                }
                            if !activityQuery.isEmpty {
                                Button { activityQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).accessibilityLabel("Clear activity search")
                            }
                            Button("Find") { searchFocused = true }.keyboardShortcut("f")
                        }.padding(8).background(ObserverReadingSurface())
                        Picker("Activity filter", selection: $activityFilter) {
                            ForEach(ActivityPresentation.Filter.allCases, id: \.self) { filter in
                                Text("\(filter.rawValue) (\(feed.displayCount(query: activityQuery, filter: filter)))").tag(filter)
                            }
                        }.pickerStyle(.segmented).accessibilityLabel("Activity filter")
                        List(selection: $model.selection) {
                            if !order.groupIDs.isEmpty {
                                Section("Tasks · \(order.groupIDs.count)") {
                                    ForEach(order.groupIDs, id: \.self) { workID in
                                        let work = feed.groups.first { $0.id == workID }
                                        DisclosureGroup(isExpanded: Binding(
                                            get: { expandedWorks.contains(workID) },
                                            set: { if $0 { expandedWorks.insert(workID) } else { expandedWorks.remove(workID) } }
                                        )) {
                                            if (order.childIDs[workID] ?? []).isEmpty {
                                                Text("No recent steps retained. The task status is kept separately.")
                                                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                                            }
                                            ForEach(order.childIDs[workID] ?? [], id: \.self) { id in
                                                stableActivityRow(id, feed: feed).tag(id)
                                            }
                                        } label: {
                                            if let work { workRow(work) }
                                            else { unavailableReadingRow(workID) }
                                        }.tag(workID)
                                    }
                                }
                            }
                            if !order.contextIDs.isEmpty {
                                Section("By context · \(order.contextIDs.count)") {
                                    ForEach(order.contextIDs, id: \.self) { contextID in
                                        let context = feed.contextGroups.first { $0.id == contextID }
                                        DisclosureGroup(isExpanded: Binding(
                                            get: { expandedWorks.contains(contextID) },
                                            set: { if $0 { expandedWorks.insert(contextID) } else { expandedWorks.remove(contextID) } }
                                        )) {
                                            ForEach(order.childIDs[contextID] ?? [], id: \.self) { id in
                                                stableActivityRow(id, feed: feed).tag(id)
                                            }
                                        } label: {
                                            if let context { CompactActivityRow(content: CompactRowContent(context: context)).accessibilityIdentifier(contextID) }
                                            else { unavailableReadingRow(contextID) }
                                        }.tag(contextID)
                                    }
                                }
                            }
                            if !order.liveIDs.isEmpty {
                                Section("Ungrouped · \(readingOrder == nil ? "in progress" : "reading view") · \(order.liveIDs.count)") {
                                    ForEach(order.liveIDs, id: \.self) { id in stableActivityRow(id, feed: feed).tag(id) }
                                }
                            }
                            if order.isEmpty {
                                Text(feed.emptyMessage(filter: activityFilter, query: activityQuery))
                                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
                                    .accessibilityIdentifier("activity-empty-state")
                            }
                            if !order.recentIDs.isEmpty {
                                Section("Ungrouped · recent actions · \(order.recentIDs.count)") {
                                    ForEach(order.recentIDs, id: \.self) { id in stableActivityRow(id, feed: feed).tag(id) }
                                }
                            }
                            if !order.retainedIDs.isEmpty {
                                Section("Ungrouped · retained processes · \(order.retainedIDs.count)") {
                                    ForEach(order.retainedIDs, id: \.self) { id in stableActivityRow(id, feed: feed).tag(id) }
                                }
                            }
                            if activityFilter == .all && activityQuery.isEmpty {
                                Section("Saved file changes") {
                                    ForEach(order.transactionIDs, id: \.self) { id in
                                        if let tx = model.transactions.first(where: { "tx:" + $0.transactionKey == id }) {
                                            row(title: tx["path"] as? String ?? "Path", subtitle: tx["kind"] as? String ?? "Transaction",
                                                icon: "doc.badge.clock", active: false).tag(id)
                                        } else { unavailableReadingRow(id).tag(id) }
                                    }
                                }
                            }
                        }.listStyle(.inset)
                            .scrollContentBackground(.hidden)
                            .background(ObserverReadingSurface())
                    }
                    Text("MB activity · tasks and inferred contexts")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help("Explicit tasks stay Active until finished. Inferred contexts group recorded folders and remain Recent for two minutes between calls; they are not verified chat identities and do not grant controls. Only bounded MB history is used.")
                }.padding(14).frame(minWidth: 320, idealWidth: 450)
                if showDetails {
                  VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Details").font(.headline)
                        Spacer()
                        Button("Refresh") { Task { await model.inspectSelection() } }
                            .disabled(!model.canInspect || model.selection == nil)
                            .keyboardShortcut("r")
                    }
                    if let job = model.selectedJob, job["running"] as? Bool == true, let owner = model.owner {
                        Button("Cancel selected job…", role: .destructive) {
                            pending = PendingControl(kind: "cancel", owner: owner, id: job.jobKey); confirm = true
                        }.disabled(!model.canControl)
                    }
                    if let tx = model.selectedTransaction, let owner = model.owner {
                        Button("Restore selected transaction…") {
                            pending = PendingControl(kind: "restore", owner: owner, id: tx.transactionKey,
                                                     workspace: tx["workspace_id"] as? String ?? "")
                            confirm = true
                        }.disabled(!model.canControl)
                    }
                    Picker("Inspector section", selection: $inspectorTab) {
                        ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if inspectorTab == .output, model.selectedJob != nil, model.outputPagingAvailable {
                        HStack {
                            Button("First available") { Task { await model.navigateOutput(0) } }
                                .disabled(!model.canInspect)
                            Button("Previous") { Task { await model.navigateOutput(-1) } }
                                .disabled(!model.canInspect || model.previousOutputPages.isEmpty)
                            Button(model.outputPage?.hasMore == true ? "Next page" : "Read newer output") {
                                Task { await model.navigateOutput(1) }
                            }.disabled(!model.canInspect || !(model.outputPage?.hasMore == true || model.outputPage?.running == true))
                        }.controlSize(.small)
                    }
                    Text(model.detailLoading ? "Loading details…" : "Bounded previews · full metadata below")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .help("Output pages are 8 KiB per stream and do not consume process handles. File and diff previews are bounded; omitted content is labeled.")
                    ScrollView(.vertical) {
                      VStack(alignment: .leading, spacing: 14) {
                       if inspectorTab == .activity {
                        ObserverDetailView(raw: model.detailResult, kind: model.detailKind,
                                           message: model.detail, page: model.outputPage, connected: model.connected,
                                           activity: model.selectedActivity, work: model.selectedWork,
                                           activityWork: model.selectedActivityWork, context: model.selectedContext,
                                           activityContext: model.selectedActivityContext)
                       } else {
                        InspectorContentView(model: model, tab: inspectorTab)
                       }
                      }.padding(12)
                    }.id(model.selection).background(ObserverReadingSurface())
                    DisclosureGroup("Runtime identity") {
                        Text((model.snapshot["build_id"] as? String ?? "Unknown") + "\n"
                             + (model.snapshot["mcp_executable_sha256"] as? String ?? ""))
                            .font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }.padding(14).frame(minWidth: 420, idealWidth: 460)
                }
            }
        }
        .environment(\.observerTextScale, textScale)
        // Extend only material under the native title bar, never the controls.
        .background { ObserverWindowSurface().ignoresSafeArea() }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { if geometry.size.width < 1024 { showSidebar = false } }
                .onChange(of: geometry.size.width) { width in if width < 1024 { showSidebar = false } }
        })
        .tint(accent)
        .frame(minWidth: 820, minHeight: 460)
        .onAppear {
            model.previewsVisible = showDetails
            guard managesLifecycle else { return }
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--observer-directory"), args.indices.contains(i + 1) {
                model.attach(args[i + 1])
            } else { model.startPolling() }
        }
        .onDisappear { if managesLifecycle { model.stopPolling() } }
        .onChange(of: model.selection) { selected in
            if selected != nil {
                showDetails = true; model.previewsVisible = true
                if readingOrder == nil {
                    readingOrder = ActivityReadingOrder(feed: model.activityFeed, transactions: model.transactions,
                        owner: model.owner, workspace: model.workspace, query: activityQuery, filter: activityFilter)
                }
            }
            Task { await model.inspectSelection() }
        }
        .onChange(of: showDetails) { visible in
            model.previewsVisible = visible
            if visible { Task { await model.inspectSelection() } }
            else { model.clearFilePreview() }
        }
        .onChange(of: model.workspace) { _ in
            readingOrder = nil; model.selection = nil; model.resetDetailNavigation()
        }
        .onChange(of: model.owner) { _ in readingOrder = nil; expandedWorks.removeAll() }
        .onChange(of: activityFilter) { _ in readingOrder = nil; model.selection = nil }
        .onChange(of: activityQuery) { _ in readingOrder = nil; model.selection = nil }
        .alert("Confirm owner-scoped action", isPresented: $confirm) {
            Button("Keep current state", role: .cancel) { pending = nil }
            Button(pending?.kind == "cancel" ? "Cancel job" : "Restore", role: .destructive) {
                if let action = pending { Task { await model.control(action) } }; pending = nil
            }
        } message: {
            Text(confirmationText)
        }
        .sheet(isPresented: $showChatHelp) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reconnect MacBridge in ChatGPT").font(.title2.weight(.semibold))
                Text("This window can verify the local MacBridge owner. ChatGPT keeps a separate tool registry for each chat, and MacBridge cannot refresh that registry from this app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Mention @MacBridge Developer again in the affected chat, then retry a read-only health check.", systemImage: "1.circle.fill")
                    Label("If the tool is still missing or disabled, the block is in ChatGPT's chat registry, not this local owner.", systemImage: "2.circle.fill")
                    Label("Branch in new chat may help diagnose the registry, but it is not a reliable repair and can fail again on a later turn.", systemImage: "3.circle.fill")
                }
                Text("One live branch recovered a single call and then dropped again. MacBridge therefore does not present branching or this window's Refresh button as a fix for ChatGPT.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { showChatHelp = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 560)
        }
        .sheet(isPresented: Binding(get: { model.receipt != nil }, set: { if !$0 { model.receipt = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Backend result").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.receipt ?? "").textSelection(.enabled)
                        if !model.receiptDetail.isEmpty {
                            DisclosureGroup("Technical receipt") {
                                Text(ObserverModel.pretty(model.receiptDetail)).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Close") { model.receipt = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 560, height: 340)
        }
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        CompactActivityRow(content: CompactRowContent(item: item)).accessibilityIdentifier(item.id)
    }

    @ViewBuilder
    private func stableActivityRow(_ id: String, feed: ActivityFeed) -> some View {
        if let item = feed.items.first(where: { $0.id == id }) { activityRow(item) }
        else { unavailableReadingRow(id) }
    }

    private func unavailableReadingRow(_ id: String) -> some View {
        CompactActivityRow(content: CompactRowContent(unavailableItemID: id))
            .disabled(true)
    }

    private func workRow(_ work: WorkActivity) -> some View {
        CompactActivityRow(content: CompactRowContent(work: work)).accessibilityIdentifier(work.id)
    }

    private func row(title: String, subtitle: String, icon: String, active: Bool, failed: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(failed ? ObserverStyle.failure : (active ? accent : .secondary)).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 5)
    }
}

struct WidgetRecoveryButton: View {
    @ObservedObject var preferences: ObserverPreferences

    var body: some View {
        if !preferences.showFloatingTab {
            Button("Show Widget", systemImage: "rectangle.portrait.trailinghalf.inset.filled") {
                preferences.showFloatingTab = true
            }
            .accessibilityIdentifier("show-floating-widget")
            .help("Restore the edge widget. MacBridge jobs are not restarted.")
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    var workspaceKey: String { self["workspace_id"] as? String ?? "" }
    var jobKey: String { self["task_id"] as? String ?? "" }
    var transactionKey: String { self["transaction_id"] as? String ?? "" }
    var eventKey: String { self["id"] as? String ?? "" }
}
