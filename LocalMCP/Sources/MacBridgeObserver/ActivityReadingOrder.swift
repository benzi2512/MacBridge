import Foundation

/// Holds only bounded row IDs, never prior payloads or live-state overrides.
/// Resolving the same IDs against each new feed keeps statuses current without
/// letting new rows or an active-first sort move the place being read.
struct ActivityReadingOrder {
    static let maximumRows = 512
    let owner: String?
    let workspace: String
    let query: String
    let filter: ActivityPresentation.Filter
    let groupIDs: [String]
    let contextIDs: [String]
    let childIDs: [String: [String]]
    let liveIDs: [String]
    let recentIDs: [String]
    let retainedIDs: [String]
    let transactionIDs: [String]

    init(feed: ActivityFeed, transactions: [[String: Any]], owner: String?, workspace: String,
         query: String, filter: ActivityPresentation.Filter) {
        self.owner = owner; self.workspace = workspace; self.query = query; self.filter = filter
        var remaining = Self.maximumRows
        func take(_ ids: [String]) -> [String] {
            let result = Array(ids.prefix(remaining)); remaining -= result.count
            return result
        }
        let groups = feed.matchingGroups(query: query, filter: filter)
        groupIDs = take(groups.map(\.id))
        var children: [String: [String]] = [:]
        for group in groups where groupIDs.contains(group.id) {
            children[group.id] = take(group.visibleChildren.map(\.id))
        }
        let contexts = feed.matchingContexts(query: query, filter: filter)
        contextIDs = take(contexts.map(\.id))
        for context in contexts where contextIDs.contains(context.id) {
            children[context.id] = take(context.visibleChildren.map(\.id))
        }
        childIDs = children
        let items = feed.matchingUngrouped(query: query, filter: filter)
        liveIDs = take(items.filter { $0.presentation.running }.map(\.id))
        recentIDs = take(items.filter { !$0.presentation.running && $0.kind == .call }.map(\.id))
        retainedIDs = take(items.filter { !$0.presentation.running && $0.kind == .job }.map(\.id))
        transactionIDs = filter == .all && query.isEmpty
            ? take(transactions.filter { workspace == "all" || $0["workspace_id"] as? String == workspace }
                .compactMap { ($0["transaction_id"] as? String).map { "tx:" + $0 } }) : []
    }

    func matches(owner: String?, workspace: String, query: String, filter: ActivityPresentation.Filter) -> Bool {
        self.owner == owner && self.workspace == workspace && self.query == query && self.filter == filter
    }

    var isEmpty: Bool {
        groupIDs.isEmpty && contextIDs.isEmpty && liveIDs.isEmpty && recentIDs.isEmpty
            && retainedIDs.isEmpty && transactionIDs.isEmpty
    }
}
