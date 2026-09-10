import Foundation

/// Enumerates actual membership, never sums potentially overlapping list counts.
/// The result is a delivery upper bound, not proof of Shopify consent.
enum BrevoAudience {
    static func resolve(_ recipients: JSONObject, perform: BrevoOperations.Transport) throws -> JSONObject {
        try recipients.requireOnlyKeys(["listIds", "lists", "exclusionListIds", "exclusionLists", "segmentIds", "segments", "exclusionSegmentIds", "exclusionSegments"])
        func ids(_ primary: String, _ legacy: String) throws -> [Int] {
            guard recipients[primary] == nil || recipients[legacy] == nil else {
                throw LocalMCPError.invalidRequest("Ambiguous recipient aliases")
            }
            let raw = recipients[primary] ?? recipients[legacy] ?? []
            try BrevoToolCatalog.validate(raw, schema: BrevoToolCatalog.ids)
            let values = raw as! [Int]
            guard Set(values).count == values.count else { throw LocalMCPError.invalidRequest("Duplicate audience sources") }
            return values
        }
        let lists = try ids("listIds", "lists"), segments = try ids("segmentIds", "segments")
        let excludedLists = try ids("exclusionListIds", "exclusionLists")
        let excludedSegments = try ids("exclusionSegmentIds", "exclusionSegments")
        guard !lists.isEmpty || !segments.isEmpty else { throw LocalMCPError.invalidRequest("No explicit campaign audience") }
        guard lists.count + segments.count + excludedLists.count + excludedSegments.count <= 20 else {
            throw LocalMCPError.limitExceeded("Audience has more than 20 sources; prepare a bounded cohort first")
        }
        var requests = 0, returned = 0
        let deadline = Date().addingTimeInterval(20)
        func fetch(_ id: Int, segment: Bool) throws -> [JSONObject] {
            var contacts: [JSONObject] = [], offset = 0, seen = Set<Int>(), expectedTotal: Int?
            while true {
                guard requests < 32, returned < 3200, Date() < deadline else {
                    throw LocalMCPError.limitExceeded("Audience preflight incomplete: 32-page/20-second budget; no send allowed")
                }
                var query = [URLQueryItem(name: "limit", value: "100"), .init(name: "offset", value: String(offset)), .init(name: "sort", value: "asc")]
                if segment { query.append(.init(name: "segmentId", value: String(id))) }
                requests += 1
                let raw = try perform("GET", segment ? "contacts" : "contacts/lists/\(id)/contacts", query, nil, false)
                let page = try BrevoSafety.page(raw, key: "contacts", limit: 100, offset: offset)
                guard let total = raw["count"] as? Int, total <= 3200,
                      expectedTotal == nil || total == expectedTotal else { throw LocalMCPError.conflict("Audience count changed or is unavailable/too large") }
                expectedTotal = total
                guard let pageContacts = raw["contacts"] as? [JSONObject] else { throw LocalMCPError.operationFailed("Invalid audience contacts") }
                for contact in pageContacts {
                    let contactID = try contact.optionalInt("id", default: 0, range: 1...Int.max)
                    guard seen.insert(contactID).inserted else { throw LocalMCPError.conflict("Audience pages overlap or changed; re-read") }
                    try BrevoSafety.email(contact.requiredString("email", maximumBytes: 254))
                    _ = try contact.requiredString("modifiedAt", maximumBytes: 64)
                    try BrevoToolCatalog.validate(contact["emailBlacklisted"] ?? NSNull(), schema: BrevoToolCatalog.boolean)
                    contacts.append(contact); returned += 1
                }
                if page["has_more"] as? Bool == false {
                    guard contacts.count == total else { throw LocalMCPError.conflict("Audience count is inconsistent") }
                    return contacts
                }
                offset = page["next_offset"] as! Int
            }
        }
        var included: [String: JSONObject] = [:], excluded = Set<String>()
        for (source, segment) in lists.map({ ($0, false) }) + segments.map({ ($0, true) }) {
            for contact in try fetch(source, segment: segment) {
                let email = (contact["email"] as! String).lowercased()
                if let old = included[email], old["emailBlacklisted"] as? Bool != contact["emailBlacklisted"] as? Bool ||
                    old["modifiedAt"] as? String != contact["modifiedAt"] as? String {
                    throw LocalMCPError.conflict("Contact changed between audience pages")
                }
                included[email] = contact
            }
        }
        for (source, segment) in excludedLists.map({ ($0, false) }) + excludedSegments.map({ ($0, true) }) {
            for contact in try fetch(source, segment: segment) { excluded.insert((contact["email"] as! String).lowercased()) }
        }
        let eligible = included.filter { email, contact in
            !excluded.contains(email) && contact["emailBlacklisted"] as? Bool == false
        }
        let fingerprints: [JSONObject] = eligible.keys.sorted().map { email in
            ["email": email, "id": included[email]!["id"]!, "modifiedAt": included[email]!["modifiedAt"] ?? NSNull()]
        }
        return ["recipient_count": eligible.count, "recipient_count_kind": "upper_bound_before_other_vendor_suppression",
            "unique_included": included.count, "excluded_or_blacklisted": included.count - eligible.count,
            "audience_version": LocalHash.sha256(try LocalJSON.encode([
                "recipients": ["listIds": lists.sorted(), "segmentIds": segments.sorted(),
                    "exclusionListIds": excludedLists.sorted(), "exclusionSegmentIds": excludedSegments.sorted()],
                "contacts": fingerprints])),
            "complete_membership_read": true, "read_requests": requests,
            "consent_verified": false, "shopify_consent_source": "not_read_by_this_adapter",
            "note": "Membership snapshot only. Other suppression may reduce delivery. Lists/segments can change before scheduling executes. This is not a verified marketing-consent cohort."]
    }
}
