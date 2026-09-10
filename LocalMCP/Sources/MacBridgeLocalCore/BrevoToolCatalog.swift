import CoreFoundation
import Foundation

/// Shared catalog/runtime validation. No caller-supplied HTTP routes.
enum BrevoToolCatalog {
    static func string(_ max: Int = 255) -> JSONObject { ["type": "string", "minLength": 1, "maxLength": max] }
    static func integer(_ max: Int = Int.max, min: Int = 1) -> JSONObject { ["type": "integer", "minimum": min, "maximum": max] }
    static var boolean: JSONObject { ["type": "boolean"] }
    static func choice(_ values: [String]) -> JSONObject { ["type": "string", "enum": values] }
    static func array(_ item: JSONObject, max: Int = 100, min: Int = 1) -> JSONObject {
        ["type": "array", "minItems": min, "maxItems": max, "items": item]
    }
    static func object(_ fields: JSONObject, required: [String] = []) -> JSONObject {
        ["type": "object", "additionalProperties": false, "properties": fields, "required": required]
    }
    static var ids: JSONObject { array(integer(), max: 100, min: 0) }
    // Vendor-defined attribute/property names, not an arbitrary request body.
    static var attributes: JSONObject { ["type": "object", "maxProperties": 100, "additionalProperties": true] }
    static var sender: JSONObject { object(["id": integer(), "email": string(254), "name": string()]) }
    static var recipients: JSONObject { object(["listIds": ids, "exclusionListIds": ids,
                                    "segmentIds": ids, "exclusionSegmentIds": ids]) }
    static var write: JSONObject { [
        "apply": boolean, "confirm_write": boolean, "verified_account_email": string(254),
        "expected_modified_at": string(64), "expected_version": string(64),
        "confirm_destructive": boolean, "confirm_sensitive": boolean, "confirm_activate": boolean,
        "maximum_recipients": integer(10000, min: 0), "expected_recipient_count": integer(10000, min: 0),
    ] }
    static var page: JSONObject { ["limit": integer(100), "offset": integer(10000000, min: 0), "sort": choice(["asc", "desc"])] }
    static var dates: JSONObject { ["start_date": string(64), "end_date": string(64)] }
    static var templateFields: JSONObject { [
        "name": string(), "subject": string(998), "sender": sender, "html_content": string(250000),
        "reply_to": string(254), "tag": string(), "to_field": string(), "is_active": boolean,
    ] }
    struct Action {
        let fields: JSONObject
        let required: [String]
        let writes: Bool
        init(_ fields: JSONObject = [:], _ required: [String] = [], writes: Bool = false) {
            self.fields = fields.merging(writes ? BrevoToolCatalog.write : [:]) { a, _ in a }
            self.required = required; self.writes = writes
        }
    }
    static func merge(_ values: JSONObject...) -> JSONObject {
        values.reduce(into: [:]) { result, value in result.merge(value) { _, b in b } }
    }
    static var groups: [String: [String: Action]] {
        let contact = ["identifier": string(254), "identifier_type": choice(["email_id", "contact_id", "ext_id", "phone_id", "whatsapp_id", "landline_number_id"])]
        let contactFields: JSONObject = ["email": string(254), "attributes": attributes, "ext_id": string(),
            "list_ids": ids, "unlink_list_ids": ids, "email_blacklisted": boolean, "sms_blacklisted": boolean,
            "smtp_blacklist_senders": array(string(254), max: 100, min: 0)]
        let attr: JSONObject = ["attribute_name": string(100), "attribute_category": choice(["normal", "transactional", "category", "calculated", "global"])]
        let attrFields: JSONObject = ["attribute_type": choice(["text", "date", "float", "boolean", "id", "category", "multiple-choice", "user"]),
            "enumeration": array(object(["value": integer(1000000, min: 0), "label": string(200)], required: ["value", "label"])),
            "multi_category_options": array(string(200)), "value": string(4096), "is_recurring": boolean]
        let list: JSONObject = ["list_id": integer()]
        let folder: JSONObject = ["folder_id": integer()]
        let template: JSONObject = ["template_id": integer()]
        let eventsQuery: JSONObject = ["contact_ids": array(integer(), max: 20), "event_names": array(string(), max: 20), "object_types": array(string(), max: 20)]
        let event: JSONObject = ["event_name": string(), "identifiers": object([
            "contact_id": integer(), "email_id": string(254), "ext_id": string(), "phone_id": string(32),
            "whatsapp_id": string(32), "landline_number_id": string(32)]),
            "event_date": string(64), "event_properties": attributes]
        let trans: JSONObject = ["email": string(254), "template_id": integer(), "message_id": string(512), "days": integer(90)]
        let webhook: JSONObject = ["webhook_id": integer()]
        let webhookFields: JSONObject = ["url": string(2048), "description": string(1000), "batched": boolean,
            "events": array(choice(["sent", "hardBounce", "softBounce", "blocked", "spam", "delivered", "request", "click", "invalid", "deferred", "opened", "uniqueOpened", "unsubscribed", "listAddition", "contactUpdated", "contactDeleted", "reply"]), max: 20)]
        let attribution: JSONObject = ["campaign_ids": array(integer(), max: 50), "workflow_ids": array(integer(), max: 50)]
        let conversion: JSONObject = ["source": choice(["email_campaign", "sms_campaign", "automation_workflow_email", "automation_workflow_sms"]), "source_id": integer()]
        return [
            "brevo_contacts": [
                "list": Action(merge(page, ["modified_since": string(64), "created_since": string(64), "contact_ids": array(integer(), max: 20), "list_ids": ids, "segment_id": integer(), "filter": string(1000)])),
                "get": Action(merge(contact, dates), ["identifier"]), "history": Action(merge(contact, dates), ["identifier"]),
                "attributes": Action(), "create": Action(contactFields, ["email"], writes: true),
                "update": Action(merge(contact, contactFields), ["identifier"], writes: true),
                "import": Action(["contacts": array(object(["email": string(254), "attributes": attributes], required: ["email"]), max: 100), "list_ids": ids, "update_existing": boolean], ["contacts", "list_ids"], writes: true),
                "process": Action(["process_id": integer()], ["process_id"]), "processes": Action(page),
                "create_attribute": Action(merge(attr, attrFields), ["attribute_name", "attribute_category", "attribute_type"], writes: true),
                "update_attribute": Action(merge(attr, attrFields), ["attribute_name", "attribute_category"], writes: true),
                "delete_attribute": Action(attr, ["attribute_name", "attribute_category"], writes: true),
                "consent_groups": Action(merge(page, ["name": string(), "signup_mode": choice(["manual", "automatic"])])),
                "consent_group": Action(["consent_group_id": integer()], ["consent_group_id"]),
            ],
            "brevo_lists": [
                "list": Action(page), "get": Action(merge(list, dates), ["list_id"]),
                "members": Action(merge(list, page, ["modified_since": string(64)]), ["list_id"]),
                "folders": Action(page), "folder": Action(folder, ["folder_id"]), "folder_lists": Action(merge(folder, page), ["folder_id"]),
                "create": Action(["name": string(), "folder_id": integer()], ["name", "folder_id"], writes: true),
                "update": Action(merge(list, ["name": string(), "folder_id": integer()]), ["list_id"], writes: true),
                "delete": Action(list, ["list_id"], writes: true),
                "add_members": Action(merge(list, ["emails": array(string(254), max: 100), "contact_ids": array(integer(), max: 100)]), ["list_id"], writes: true),
                "remove_members": Action(merge(list, ["emails": array(string(254), max: 100), "contact_ids": array(integer(), max: 100)]), ["list_id"], writes: true),
                "create_folder": Action(["name": string()], ["name"], writes: true),
                "update_folder": Action(merge(folder, ["name": string()]), ["folder_id", "name"], writes: true),
            ],
            "brevo_segments": ["list": Action(page), "members": Action(merge(page, ["segment_id": integer()]), ["segment_id"]), "capabilities": Action()],
            "brevo_automations": ["capabilities": Action(), "attribution": Action(merge(attribution, dates), ["workflow_ids"])],
            "brevo_templates": [
                "list": Action(merge(page, ["is_active": boolean, "include_content": boolean])),
                "get": Action(merge(template, ["include_content": boolean]), ["template_id"]),
                "create": Action(templateFields, ["name", "subject", "sender", "html_content"], writes: true),
                "update": Action(merge(template, templateFields), ["template_id"], writes: true),
                "duplicate": Action(merge(template, ["name": string()]), ["template_id", "name"], writes: true),
                "activate": Action(template, ["template_id"], writes: true), "deactivate": Action(template, ["template_id"], writes: true),
                "delete": Action(template, ["template_id"], writes: true),
            ],
            "brevo_events": ["list": Action(merge(page, dates, eventsQuery)),
                "track": Action(event, ["event_name", "identifiers"], writes: true),
                "track_batch": Action(["events": array(object(event, required: ["event_name", "identifiers"]), max: 100)], ["events"], writes: true)],
            "brevo_transactional": [
                "messages": Action(merge(page, dates, trans)),
                "events": Action(merge(page, dates, trans, ["event": choice(["bounces", "hardBounces", "softBounces", "delivered", "spam", "requests", "opened", "clicks", "invalid", "deferred", "blocked", "unsubscribed", "error", "loadedByProxy"])])),
                "content": Action(["uuid": string(128), "include_content": boolean], ["uuid"]),
                "scheduled": Action(["message_id": string(512)], ["message_id"]),
            ],
            "brevo_deliverability": [
                "senders": Action(["domain": string(), "ip": string(128)]), "domains": Action(), "domain": Action(["domain": string()], ["domain"]),
                "ips": Action(), "sender_ips": Action(["sender_id": integer()], ["sender_id"]),
                "blocked_contacts": Action(merge(page, dates, ["senders": array(string(254), max: 20)])), "blocked_domains": Action(),
                "block_domain": Action(["domain": string()], ["domain"], writes: true),
                "unblock_domain": Action(["domain": string()], ["domain"], writes: true),
                "unblock_contact": Action(["email": string(254)], ["email"], writes: true),
            ],
            "brevo_webhooks": [
                "list": Action(["type": choice(["marketing", "transactional", "inbound"]), "sort": choice(["asc", "desc"])]), "get": Action(webhook, ["webhook_id"]),
                "create": Action(merge(webhookFields, ["type": choice(["marketing", "transactional"])]), ["url", "events", "type"], writes: true),
                "update": Action(merge(webhook, webhookFields), ["webhook_id"], writes: true), "delete": Action(webhook, ["webhook_id"], writes: true),
                "capabilities": Action(),
            ],
            "brevo_reports": [
                "daily": Action(merge(page, dates, ["days": integer(30), "tag": string()])),
                "aggregate": Action(merge(dates, ["days": integer(90), "tag": string()])),
                "attribution": Action(merge(attribution, dates)),
                "attribution_detail": Action(conversion, ["source", "source_id"]),
                "attribution_products": Action(conversion, ["source", "source_id"]),
                "campaign_ab": Action(["campaign_id": integer()], ["campaign_id"]),
                "account_activity": Action(merge(page, dates, ["email": string(254)])),
            ],
        ]
    }
    static let descriptions: [String: String] = [
        "brevo_contacts": "Configured-account contacts, attributes, membership, factual consent/blacklists, history, import and process status. Shopify remains consent authority; Brevo membership is not consent. No force merge, remote import URL or bulk unblacklist.",
        "brevo_lists": "Lists/folders and bounded members. Create/update/delete lists and add/remove up to 100 explicit members. Returned version is a pre-read hash, not vendor atomic CAS. Folder counts may be deprecated; use members for real counts.",
        "brevo_segments": "Documented segment index (ID/name/category/updatedAt) and paginated members via contacts. Public API does not document segment rule CRUD; capabilities explains the limitation.",
        "brevo_automations": "Revenue attribution for supplied workflow IDs, plus capability limits. No documented workflow inventory/editor/steps/contact-state/log API. Never infer active status from templates or attribution.",
        "brevo_templates": "Transactional/automation templates: list/get, create/update/duplicate, activate/deactivate/delete. Content omitted by default. Active edits/activation require confirm_activate; no email send action.",
        "brevo_events": "Read custom events; ingest one or up to 100 events. Ingestion can trigger workflows: confirm_activate and exact affected-contact count required. No retry; queued/partial is not delivery.",
        "brevo_transactional": "Read-only message metadata, delivery/bounce events, explicit content and scheduled state. No transactional send. Historical events are not live workflow step state.",
        "brevo_deliverability": "Sender/domain authentication, IPs and gated suppression operations. No DNS changes. Absent SPF fields mean unavailable, not healthy.",
        "brevo_webhooks": "Marketing/transactional webhooks. Auth/header secrets and URL path/query hidden. Destinations require confirm_activate; URL credentials refused. No invented enable/disable endpoint.",
        "brevo_reports": "SMTP daily/aggregate reports, campaign A/B, ecommerce attribution, account activity. Missing workflow metrics remain unavailable. Missing vendor total gives count=null, not an invented total.",
    ]
    static func specs() -> [JSONObject] {
        let all = groups
        return all.keys.sorted().map { name in
            let actions = all[name]!
            // Stable union: action dictionary iteration must not alter catalog fingerprints.
            var fields = actions.keys.sorted().reduce(into: JSONObject()) { result, action in
                result.merge(actions[action]!.fields) { a, _ in a }
            }
            if name == "brevo_reports" { fields["days"] = integer(90) } // Daily still validates <=30.
            fields["action"] = choice(actions.keys.sorted())
            let writes = actions.values.contains { $0.writes }
            return ["name": name, "title": name.replacingOccurrences(of: "_", with: " "),
                "description": descriptions[name]! + (writes ? " Writes default dry-run. Live: apply, confirm_write, verified_account_email. Existing: expected_modified_at or returned expected_version. Deletion/sensitive/activation gates separate. No automatic write retries." : ""),
                "inputSchema": object(fields, required: ["action"]),
                "annotations": ["readOnlyHint": !writes, "destructiveHint": writes, "idempotentHint": !writes, "openWorldHint": true]]
        }
    }
    static func validate(_ value: Any, schema: JSONObject, path: String = "arguments", depth: Int = 0) throws {
        guard depth <= 12 else { throw LocalMCPError.limitExceeded("Brevo nesting limit") }
        func fail() throws { throw LocalMCPError.invalidRequest("Invalid Brevo field: \(path)") }
        switch schema["type"] as? String {
        case "string":
            guard let s = value as? String, !s.contains("\0"), s.count >= (schema["minLength"] as? Int ?? 0), s.utf8.count <= (schema["maxLength"] as? Int ?? 4096) else { return try fail() }
            if let options = schema["enum"] as? [String], !options.contains(s) { try fail() }
        case "boolean":
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return try fail() }
        case "integer":
            _ = try [path: value].optionalInt(path, default: 0, range: (schema["minimum"] as? Int ?? 0)...(schema["maximum"] as? Int ?? Int.max))
        case "array":
            guard let items = value as? [Any], items.count >= (schema["minItems"] as? Int ?? 0), items.count <= (schema["maxItems"] as? Int ?? 100), let item = schema["items"] as? JSONObject else { return try fail() }
            for v in items { try validate(v, schema: item, path: path + "[]", depth: depth + 1) }
        case "object":
            guard let obj = value as? JSONObject, obj.count <= (schema["maxProperties"] as? Int ?? 128) else { return try fail() }
            let fields = schema["properties"] as? JSONObject ?? [:]
            if schema["additionalProperties"] as? Bool == false { try obj.requireOnlyKeys(Set(fields.keys)) }
            for key in schema["required"] as? [String] ?? [] where obj[key] == nil { throw LocalMCPError.invalidRequest("Required Brevo field: \(key)") }
            for (key, v) in obj {
                if let field = fields[key] as? JSONObject { try validate(v, schema: field, path: path + "." + key, depth: depth + 1) }
            }
            guard try LocalJSON.encode(obj).count <= 262144 else { throw LocalMCPError.limitExceeded("Brevo object exceeds 256 KiB") }
        default: try fail()
        }
    }
}
