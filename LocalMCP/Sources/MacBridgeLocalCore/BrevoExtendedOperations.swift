import Foundation
import CoreFoundation

enum BrevoExtendedOperations {
    struct Plan {
        var method = "GET"
        var path: String
        var query: [URLQueryItem] = []
        var body: JSONObject?
        var pageKey: String?
        var preflight: String?
        var preflightQuery: [URLQueryItem] = []
        var expectedID: Int?
        var count: Int?
        var mayCommunicate = false
        var sensitive = false
        var activate = false
        var destructive = false
    }
    static func execute(_ tool: String, _ a: JSONObject, transport: BrevoOperations.Transport? = nil) throws -> JSONObject {
        let action = try a.requiredString("action", maximumBytes: 40)
        guard let entry = BrevoToolCatalog.groups[tool]?[action] else {
            throw LocalMCPError.invalidRequest("Unsupported Brevo action; consult the tool schema/capabilities")
        }
        try BrevoToolCatalog.validate(a, schema: BrevoToolCatalog.object(
            entry.fields.merging(["action": BrevoToolCatalog.string(40)]) { x, _ in x }, required: ["action"] + entry.required))
        if action == "capabilities" { return capabilities(tool) }
        var plan = try makePlan(tool, action, a)
        let apply = a["apply"] as? Bool == true
        if entry.writes && !apply {
            return ["dry_run": true, "outcome": "dry_run", "write_occurred": false, "outcome_certain": true,
                "action": action, "method": plan.method, "endpoint": "/v3/" + plan.path,
                "target_id": plan.expectedID.map { $0 as Any } ?? NSNull(),
                "affected_contact_count": plan.count.map { $0 as Any } ?? NSNull(),
                "changed_fields": plan.body?.keys.sorted() ?? [],
                "body": BrevoOperations.sanitize(plan.body ?? [:], secret: ""),
                "may_communicate": plan.mayCommunicate, "customer_communication": "none_dry_run",
                "required_gates": ["apply", "confirm_write", "verified_account_email"] +
                    (plan.destructive ? ["confirm_destructive"] : []) + (plan.sensitive ? ["confirm_sensitive"] : []) +
                    (plan.activate ? ["confirm_activate"] : []),
                "validation_errors": [], "pending_checks": ["live_account", "object_version", "current_state", "server_validation"],
                "estimated_quota_effect": plan.mayCommunicate ? "unknown until delivery/automation preflight" : "no_email_send",
                "credential_read": false, "network_request": false]
        }
        if entry.writes {
            try BrevoSafety.requireWriteConsent(a)
            if plan.destructive { try BrevoSafety.gate(a, "confirm_destructive") }
            if plan.sensitive { try BrevoSafety.gate(a, "confirm_sensitive") }
            if plan.activate { try BrevoSafety.gate(a, "confirm_activate") }
            if plan.mayCommunicate, let count = plan.count { try BrevoSafety.countGate(a, count: count) }
        }
        let session = try BrevoOperations.boundSession(transport)
        if entry.writes { try BrevoSafety.confirmWrite(a, expectedAccountEmail: session.expectedAccountEmail) }
        let perform = session.perform
        _ = try BrevoSafety.verifyAccount(perform, expectedAccountEmail: session.expectedAccountEmail)
        if let path = plan.preflight {
            let current = try perform("GET", path, plan.preflightQuery, nil, false)
            try BrevoSafety.checkVersion(a, current: current)
            if let id = plan.expectedID {
                guard let actual = try? current.optionalInt("id", default: 0, range: 1...Int.max), actual == id else {
                    throw LocalMCPError.conflict("Brevo object ID mismatch")
                }
            }
            if tool == "brevo_templates" {
                if action == "delete", current["isActive"] as? Bool != false { throw LocalMCPError.conflict("Only inactive templates may be deleted") }
                if action == "update", current["isActive"] as? Bool != false {
                    try BrevoSafety.gate(a, "confirm_activate"); plan.mayCommunicate = true
                }
                if action == "duplicate" {
                    guard let html = current["htmlContent"] as? String, let subject = current["subject"] as? String,
                          let sourceSender = current["sender"] as? JSONObject else {
                        throw LocalMCPError.operationFailed("Template response cannot be duplicated safely")
                    }
                    var sender = sourceSender
                    if let id = sourceSender["id"] as? String, let number = Int(id) { sender = ["id": number] }
                    else if let id = sourceSender["id"] as? Int { sender = ["id": id] }
                    else { sender = sourceSender.filter { ["email", "name"].contains($0.key) } }
                    plan.body = ["templateName": a["name"]!, "htmlContent": html, "subject": subject, "sender": sender, "isActive": false]
                }
            }
        }
        if entry.writes {
            do {
                let raw = try perform(plan.method, plan.path, plan.query, plan.body, true)
                return BrevoSafety.receipt(try BrevoSafety.result(raw), mayCommunicate: plan.mayCommunicate)
            } catch {
                let unknown = String(describing: error).contains("WRITE_OUTCOME_UNKNOWN")
                return ["outcome": unknown ? "outcome_unknown" : "rejected", "dry_run": false,
                    "write_occurred": unknown ? NSNull() : false, "outcome_certain": !unknown,
                    "customer_communication": unknown ? "unknown" : "not_confirmed",
                    "credential_read": true, "network_request": true, "automatic_retry": false,
                    "error": String(describing: error), "reconcile": "Read the target or process status; do not automatically retry this request."]
            }
        }
        var raw: JSONObject
        if tool == "brevo_webhooks", action == "list", a["type"] == nil {
            // Brevo otherwise silently defaults to transactional webhooks only.
            var webhooks: [JSONObject] = [], failures: [JSONObject] = []
            for type in ["marketing", "transactional", "inbound"] {
                do {
                    let page = try perform("GET", "webhooks", plan.query + [.init(name: "type", value: type)], nil, false)
                    guard let items = page["webhooks"] as? [JSONObject], items.count <= 1000 else {
                        throw LocalMCPError.operationFailed("Unexpected or oversized webhook inventory")
                    }
                    webhooks += items
                } catch { failures.append(["type": type, "error": String(describing: error)]) }
            }
            raw = ["webhooks": webhooks, "count": failures.isEmpty ? webhooks.count as Any : NSNull(),
                "returned_count": webhooks.count, "complete": failures.isEmpty, "type_errors": failures,
                "types_requested": ["marketing", "transactional", "inbound"],
                "pagination_note": "Vendor endpoint returns all webhooks per type; no documented pagination."]
        } else { raw = try perform(plan.method, plan.path, plan.query, plan.body, false) }
        if let key = plan.pageKey {
            raw = try BrevoSafety.page(raw, key: key, limit: a["limit"] as? Int ?? 50, offset: a["offset"] as? Int ?? 0)
        }
        var result = try BrevoSafety.result(raw, includeContent: a["include_content"] as? Bool == true)
        result["metadata"] = ["outcome": "read", "write_occurred": false, "credential_read": true, "network_request": true]
        if tool == "brevo_contacts" || tool == "brevo_lists" || tool == "brevo_segments" {
            result["consent_note"] = "Membership/blacklist are Brevo facts, not proof of Shopify marketing consent. Missing fields are unknown."
        }
        if tool == "brevo_automations" { result["capability_limitations"] = capabilities(tool)["limitations"] }
        if tool == "brevo_deliverability", action == "domains" {
            result["has_more"] = (raw["current_page"] as? Int ?? 1) < (raw["total_pages"] as? Int ?? 1)
            result["pagination_note"] = "Vendor may report pages but documents no page input here; do not infer unseen domains."
        }
        return result
    }
    static func capabilities(_ tool: String) -> JSONObject {
        let limitations: [String]
        switch tool {
        case "brevo_automations":
            limitations = ["The public v3 API index documents no workflow list, status, editor, step, current-contact-state, or execution-log endpoint.",
                "Attribution by known workflow ID is available; it does not prove active/paused state, entries, completions, or email-step execution.",
                "Use templates, custom events and transactional events as supporting evidence only. Welcome/Abandoned Checkout status remains unverified without an official workflow API."]
        case "brevo_segments":
            limitations = ["Index returns ID/name/category/updatedAt, not filter definitions. Members/count are available through GET contacts?segmentId.",
                "No public segment create/update/delete/refresh or rule-definition endpoint is documented in the reviewed v3 index."]
        default:
            limitations = ["Webhooks support list/get/create/update/delete; no enabled/status toggle is documented.",
                "Auth/custom headers are never exposed or accepted through chat. Destination paths/query are redacted.",
                "Webhook URL creation/update requires separate destination activation approval; remote receiver security remains the caller's responsibility."]
        }
        return ["status": "documented_capability_limit", "limitations": limitations,
            "source": "https://developers.brevo.com/llms.txt", "reviewed_on": "2026-09-09",
            "write_occurred": false, "credential_read": false, "network_request": false]
    }
    static func makePlan(_ tool: String, _ action: String, _ a: JSONObject) throws -> Plan {
        func id(_ key: String) throws -> String { String(try a.optionalInt(key, default: 0, range: 1...Int.max)) }
        func component(_ key: String) throws -> String { try BrevoSafety.component(a.requiredString(key)) }
        func mapped(_ mapping: [String: String]) -> JSONObject {
            mapping.reduce(into: [:]) { if let value = a[$1.key] { $0[$1.value] = value } }
        }
        func query(_ mapping: [String: String], repeatKeys: Bool = false) -> [URLQueryItem] {
            mapping.keys.sorted().flatMap { key -> [URLQueryItem] in
                guard let value = a[key] else { return [] }
                let name = mapping[key]!
                if let values = value as? [Any] {
                    let strings = values.map { String(describing: $0) }
                    return repeatKeys ? strings.map { .init(name: name, value: $0) } : [.init(name: name, value: strings.joined(separator: ","))]
                }
                if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return [.init(name: name, value: n.boolValue ? "true" : "false")] }
                return [.init(name: name, value: String(describing: value))]
            }
        }
        func paged(_ path: String, _ key: String, max: Int = 100) throws -> Plan {
            let limit = try a.optionalInt("limit", default: 50, range: 1...max)
            var p = Plan(path: path)
            p.pageKey = key
            p.query = [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(a["offset"] as? Int ?? 0))]
            p.query += query(["sort": "sort"])
            return p
        }
        func mutation(_ method: String, _ path: String, _ body: JSONObject? = nil, existing: String? = nil, idKey: String? = nil) -> Plan {
            var p = Plan(path: path); p.method = method; p.body = body; p.preflight = existing
            if let key = idKey { p.expectedID = a[key] as? Int }
            p.destructive = method == "DELETE"
            return p
        }
        func nonempty(_ body: JSONObject) throws -> JSONObject {
            guard !body.isEmpty else { throw LocalMCPError.invalidRequest("No Brevo fields to change") }; return body
        }
        func attributes(_ values: JSONObject) throws {
            for (key, value) in values {
                guard key.range(of: #"^[A-Z][A-Z0-9_]{0,99}$"#, options: .regularExpression) != nil else { throw LocalMCPError.invalidRequest("Brevo attributes must have uppercase names") }
                guard value is String || value is NSNumber || value is [String] else { throw LocalMCPError.invalidRequest("Invalid contact attribute value type") }
            }
        }
        if let value = a["email"] as? String { try BrevoSafety.email(value) }
        if let domain = a["domain"] as? String { try BrevoSafety.domain(domain) }
        if let values = a["attributes"] as? JSONObject { try attributes(values) }
        let dateQuery = try BrevoSafety.dates(a, maximumDays: tool == "brevo_transactional" ? (action == "messages" ? 31 : 90) : nil)
        var p: Plan
        switch tool {
        case "brevo_contacts":
            switch action {
            case "list":
                guard a["list_ids"] == nil || a["segment_id"] == nil else { throw LocalMCPError.invalidRequest("Choose list_ids or segment_id, not both") }
                if let filter = a["filter"] as? String, !filter.hasPrefix("equals(") || !filter.hasSuffix(")") { throw LocalMCPError.invalidRequest("Only documented equals attribute filter is supported") }
                p = try paged("contacts", "contacts")
                p.query += query(["modified_since": "modifiedSince", "created_since": "createdSince", "contact_ids": "ids", "list_ids": "listIds", "segment_id": "segmentId", "filter": "filter"])
            case "get", "history":
                let ident = try component("identifier")
                p = Plan(path: "contacts/" + ident + (action == "history" ? "/campaignStats" : ""))
                if action == "get" { p.query = query(["identifier_type": "identifierType"]) }
                else if let type = a["identifier_type"] as? String, !["email_id", "contact_id"].contains(type) { throw LocalMCPError.invalidRequest("Contact history supports email or numeric ID only") }
            case "attributes": p = Plan(path: "contacts/attributes")
            case "create", "update":
                if action == "create", a["unlink_list_ids"] != nil { throw LocalMCPError.invalidRequest("Cannot unlink lists on contact creation") }
                if action == "update", a["email"] != nil { throw LocalMCPError.invalidRequest("Use attributes.EMAIL for an explicit sensitive email change") }
                var body = mapped(["email": "email", "attributes": "attributes", "ext_id": "ext_id", "list_ids": "listIds", "unlink_list_ids": "unlinkListIds", "email_blacklisted": "emailBlacklisted", "sms_blacklisted": "smsBlacklisted", "smtp_blacklist_senders": "smtpBlacklistSender"])
                if let email = (body["attributes"] as? JSONObject)?["EMAIL"] as? String { try BrevoSafety.email(email) }
                if action == "create" {
                    if a["smtp_blacklist_senders"] != nil { throw LocalMCPError.invalidRequest("SMTP blacklist changes use version-checked contact update") }
                    body["updateEnabled"] = false; body["forceMerge"] = false
                    p = mutation("POST", "contacts", body)
                } else {
                    _ = try nonempty(body); body["forceMerge"] = false
                    let path = try "contacts/" + component("identifier")
                    p = mutation("PUT", path, body, existing: path)
                    p.query = query(["identifier_type": "identifierType"]); p.preflightQuery = p.query
                }
                p.count = 1; p.mayCommunicate = true; p.activate = true
                p.sensitive = a["email_blacklisted"] != nil || a["sms_blacklisted"] != nil || a["smtp_blacklist_senders"] != nil ||
                    (a["attributes"] as? JSONObject)?.keys.contains(where: { $0 == "EMAIL" || $0.contains("CONSENT") || $0.contains("OPTIN") || $0.contains("SUBSCRIB") }) == true
            case "import":
                let contacts = a["contacts"] as! [JSONObject]
                guard !(a["list_ids"] as! [Int]).isEmpty else { throw LocalMCPError.invalidRequest("Import requires an explicit destination list") }
                for contact in contacts {
                    try BrevoSafety.email(contact["email"] as! String)
                    let values = contact["attributes"] as? JSONObject ?? [:]
                    try attributes(values)
                    guard !values.keys.contains(where: { $0 == "EMAIL" || $0.contains("CONSENT") || $0.contains("OPTIN") || $0.contains("SUBSCRIB") || $0.contains("BLACKLIST") }) else {
                        throw LocalMCPError.invalidRequest("Bulk import cannot change identity/consent/suppression; use version-checked individual updates")
                    }
                }
                guard Set(contacts.map { ($0["email"] as! String).lowercased() }).count == contacts.count else { throw LocalMCPError.invalidRequest("Duplicate contact emails in import") }
                // No remote file URLs, notification URL, consent writes, or blind overwrite of existing contacts.
                guard a["update_existing"] as? Bool != true else { throw LocalMCPError.invalidRequest("Bulk overwrite has no per-contact version check; use version-checked update instead") }
                p = mutation("POST", "contacts/import", ["jsonBody": contacts, "listIds": a["list_ids"]!, "disableNotification": true, "updateExistingContacts": false, "emptyContactsAttributes": false])
                p.count = contacts.count; p.mayCommunicate = true; p.activate = true
            case "process": p = Plan(path: try "processes/" + id("process_id"))
            case "processes": p = try paged("processes", "processes", max: 50)
            case "consent_groups":
                p = try paged("contacts/consent-groups", "consentGroups", max: 50); p.query += query(["name": "name", "signup_mode": "signupMode"])
            case "consent_group": p = Plan(path: try "contacts/consent-groups/" + id("consent_group_id"))
            case "create_attribute", "update_attribute", "delete_attribute":
                let category = a["attribute_category"] as! String, name = a["attribute_name"] as! String
                guard name.range(of: #"^[A-Z][A-Z0-9_]{0,99}$"#, options: .regularExpression) != nil else { throw LocalMCPError.invalidRequest("Invalid attribute name") }
                if action == "update_attribute", a["attribute_type"] != nil || a["is_recurring"] != nil { throw LocalMCPError.invalidRequest("Attribute update cannot change type/is_recurring") }
                let body = mapped(["attribute_type": "type", "enumeration": "enumeration", "multi_category_options": "multiCategoryOptions", "value": "value", "is_recurring": "isRecurring"])
                p = mutation(action == "delete_attribute" ? "DELETE" : action == "create_attribute" ? "POST" : "PUT",
                    "contacts/attributes/\(category)/\(name)", action == "delete_attribute" ? nil : try nonempty(body),
                    existing: action == "create_attribute" ? nil : "contacts/attributes")
                p.sensitive = true
            default: throw LocalMCPError.invalidRequest("Unknown contact action")
            }
        case "brevo_lists":
            switch action {
            case "list": p = try paged("contacts/lists", "lists", max: 50)
            case "get": p = Plan(path: try "contacts/lists/" + id("list_id"))
            case "members":
                p = try paged("contacts/lists/" + id("list_id") + "/contacts", "contacts"); p.query += query(["modified_since": "modifiedSince"])
            case "folders": p = try paged("contacts/folders", "folders", max: 50)
            case "folder": p = Plan(path: try "contacts/folders/" + id("folder_id"))
            case "folder_lists": p = try paged("contacts/folders/" + id("folder_id") + "/lists", "lists", max: 50)
            case "create": p = mutation("POST", "contacts/lists", mapped(["name": "name", "folder_id": "folderId"])); p.count = 0
            case "update", "delete":
                let path = try "contacts/lists/" + id("list_id")
                p = mutation(action == "delete" ? "DELETE" : "PUT", path,
                    action == "delete" ? nil : try nonempty(mapped(["name": "name", "folder_id": "folderId"])), existing: path, idKey: "list_id")
            case "add_members", "remove_members":
                guard (a["emails"] == nil) != (a["contact_ids"] == nil) else { throw LocalMCPError.invalidRequest("Provide emails or contact_ids, not both") }
                if let emails = a["emails"] as? [String] { for email in emails { try BrevoSafety.email(email) } }
                let members = a["emails"] as? [Any] ?? a["contact_ids"] as! [Any]
                guard Set(members.map { String(describing: $0).lowercased() }).count == members.count else { throw LocalMCPError.invalidRequest("Duplicate list members") }
                let path = try "contacts/lists/" + id("list_id")
                p = mutation("POST", path + "/contacts/" + (action == "add_members" ? "add" : "remove"), mapped(["emails": "emails", "contact_ids": "ids"]), existing: path, idKey: "list_id")
                p.count = members.count; p.mayCommunicate = true; p.activate = true
            case "create_folder": p = mutation("POST", "contacts/folders", ["name": a["name"]!])
            case "update_folder":
                let path = try "contacts/folders/" + id("folder_id")
                p = mutation("PUT", path, ["name": a["name"]!], existing: path, idKey: "folder_id")
            default: throw LocalMCPError.invalidRequest("Unknown list action")
            }
        case "brevo_segments":
            if action == "list" { p = try paged("contacts/segments", "segments", max: 50) }
            else { p = try paged("contacts", "contacts"); p.query += query(["segment_id": "segmentId"]) }
        case "brevo_templates":
            if action == "list" {
                p = try paged("smtp/templates", "templates"); p.query += query(["is_active": "templateStatus"])
            } else if action == "get" { p = Plan(path: try "smtp/templates/" + id("template_id")) }
            else {
                let path = action == "create" ? "smtp/templates" : try "smtp/templates/" + id("template_id")
                var body = mapped(["name": "templateName", "subject": "subject", "sender": "sender", "html_content": "htmlContent", "reply_to": "replyTo", "tag": "tag", "to_field": "toField", "is_active": "isActive"])
                if let sender = body["sender"] as? JSONObject {
                    guard (sender["id"] == nil) != (sender["email"] == nil) else { throw LocalMCPError.invalidRequest("Sender requires exactly one id or email") }
                    if let email = sender["email"] as? String { try BrevoSafety.email(email) }
                }
                if let html = body["htmlContent"] as? String, html.count < 11 { throw LocalMCPError.invalidRequest("Template HTML must have more than 10 characters") }
                if action == "create" { body["isActive"] = a["is_active"] as? Bool ?? false }
                if action == "activate" || action == "deactivate" { body = ["isActive": action == "activate"] }
                p = mutation(action == "delete" ? "DELETE" : ["create", "duplicate"].contains(action) ? "POST" : "PUT",
                    action == "duplicate" ? "smtp/templates" : path,
                    action == "delete" ? nil : try nonempty(body), existing: action == "create" ? nil : path, idKey: action == "create" ? nil : "template_id")
                p.activate = body["isActive"] as? Bool == true
                p.mayCommunicate = p.activate || action == "update"
            }
        case "brevo_events":
            if action == "list" {
                p = try paged("events", "events")
                p.query += query(["contact_ids": "contact_id", "event_names": "event_name", "object_types": "object_type"], repeatKeys: true)
            } else {
                let events = action == "track_batch" ? a["events"] as! [JSONObject] : [mapped(["event_name": "event_name", "identifiers": "identifiers", "event_date": "event_date", "event_properties": "event_properties"])]
                for event in events {
                    guard (event["event_name"] as! String).range(of: #"^[A-Za-z0-9_-]{1,255}$"#, options: .regularExpression) != nil,
                          let identifiers = event["identifiers"] as? JSONObject, identifiers.count == 1 else { throw LocalMCPError.invalidRequest("Event needs a valid name and exactly one contact identifier") }
                    if let email = identifiers["email_id"] as? String { try BrevoSafety.email(email) }
                    if let props = event["event_properties"] as? JSONObject, try LocalJSON.encode(props).count > 50000 { throw LocalMCPError.limitExceeded("Event properties exceed 50 KB") }
                    if let date = event["event_date"] as? String { _ = try BrevoSafety.dates(["start_date": date, "end_date": date]) }
                }
                let count = Set(try events.map { try LocalHash.sha256(LocalJSON.encode($0["identifiers"]!)) }).count
                p = mutation("POST", action == "track_batch" ? "events/batch" : "events", action == "track_batch" ? ["events": events] : events[0])
                p.count = count; p.mayCommunicate = true; p.activate = true
            }
        case "brevo_transactional":
            switch action {
            case "messages":
                guard a["email"] != nil || a["template_id"] != nil || a["message_id"] != nil else { throw LocalMCPError.invalidRequest("messages requires email, template_id or message_id") }
                if a["days"] != nil { throw LocalMCPError.invalidRequest("messages uses dates, not days") }
                p = try paged("smtp/emails", "transactionalEmails")
            case "events": p = try paged("smtp/statistics/events", "events")
            case "content": p = Plan(path: try "smtp/emails/" + component("uuid"))
            case "scheduled":
                let message = a["message_id"] as! String
                guard message.hasPrefix("<"), message.hasSuffix(">"), message.contains("@") else { throw LocalMCPError.invalidRequest("scheduled requires a message ID, not an unpaginated batch ID") }
                p = Plan(path: try "smtp/emailStatus/" + component("message_id"))
            default: throw LocalMCPError.invalidRequest("Unknown transactional action")
            }
            if action == "messages" || action == "events" { p.query += query(["email": "email", "template_id": "templateId", "message_id": "messageId", "event": "event", "days": "days"]) }
        case "brevo_deliverability":
            switch action {
            case "senders": p = Plan(path: "senders"); p.query = query(["domain": "domain", "ip": "ip"])
            case "domains": p = Plan(path: "senders/domains")
            case "domain": p = Plan(path: try "senders/domains/" + component("domain"))
            case "ips": p = Plan(path: "senders/ips")
            case "sender_ips": p = Plan(path: try "senders/" + id("sender_id") + "/ips")
            case "blocked_contacts":
                p = try paged("smtp/blockedContacts", "contacts"); p.query += query(["senders": "senders"])
            case "blocked_domains": p = Plan(path: "smtp/blockedDomains")
            case "block_domain":
                p = mutation("POST", "smtp/blockedDomains", ["domain": a["domain"]!], existing: "smtp/blockedDomains"); p.sensitive = true
            case "unblock_domain":
                p = mutation("DELETE", try "smtp/blockedDomains/" + component("domain"), existing: "smtp/blockedDomains"); p.sensitive = true
            case "unblock_contact":
                p = mutation("DELETE", try "smtp/blockedContacts/" + component("email"), existing: try "contacts/" + component("email"))
                p.count = 1; p.sensitive = true
            default: throw LocalMCPError.invalidRequest("Unknown deliverability action")
            }
        case "brevo_webhooks":
            if action == "list" { p = Plan(path: "webhooks"); p.query = query(["type": "type", "sort": "sort"]) }
            else if action == "get" { p = Plan(path: try "webhooks/" + id("webhook_id")) }
            else {
                if let url = a["url"] as? String { try BrevoSafety.webhookURL(url) }
                let path = action == "create" ? "webhooks" : try "webhooks/" + id("webhook_id")
                p = mutation(action == "delete" ? "DELETE" : action == "create" ? "POST" : "PUT", path,
                    action == "delete" ? nil : try nonempty(mapped(["url": "url", "description": "description", "events": "events", "type": "type", "batched": "batched"])),
                    existing: action == "create" ? nil : path, idKey: action == "create" ? nil : "webhook_id")
                p.activate = action != "delete"
            }
        case "brevo_reports", "brevo_automations":
            switch action {
            case "daily":
                p = try paged("smtp/statistics/reports", "reports"); p.query += query(["days": "days", "tag": "tag"])
            case "aggregate": p = Plan(path: "smtp/statistics/aggregatedReport"); p.query = query(["days": "days", "tag": "tag"])
            case "attribution":
                p = Plan(path: "ecommerce/attribution/metrics")
                p.query = query(["campaign_ids": "emailCampaignId[]", "workflow_ids": "automationWorkflowEmailId[]"], repeatKeys: true)
                p.query += dateQuery.map { .init(name: $0.name == "startDate" ? "periodFrom" : "periodTo", value: $0.value) }
                return p
            case "attribution_detail", "attribution_products":
                p = Plan(path: try "ecommerce/attribution/" + (action == "attribution_detail" ? "metrics/" : "products/") + component("source") + "/" + id("source_id"))
            case "campaign_ab": p = Plan(path: try "emailCampaigns/" + id("campaign_id") + "/abTestCampaignResult")
            case "account_activity":
                p = try paged("organization/activities", "logs"); p.query += query(["email": "email"])
            default: throw LocalMCPError.invalidRequest("Unknown report action")
            }
        default: throw LocalMCPError.invalidRequest("Unknown Brevo tool")
        }
        p.query += dateQuery
        return p
    }
}
