import Foundation

enum BrevoCampaignActions {
    static let actions = ["create", "update", "duplicate", "archive", "schedule", "cancel_schedule", "send_test", "send_now", "preflight"]
    static let mapping = ["name": "name", "subject": "subject", "sender": "sender", "recipients": "recipients",
        "html_content": "htmlContent", "template_id": "templateId", "preview_text": "previewText", "tag": "tag",
        "reply_to": "replyTo", "scheduled_at": "scheduledAt", "utm_campaign": "utmCampaign",
        "utm_content": "utmContent", "utm_term": "utmTerm"]
    static var fields: JSONObject {
        var p = BrevoToolCatalog.write
        p.merge([
            "action": BrevoToolCatalog.choice(actions), "campaign_id": BrevoToolCatalog.integer(),
            "name": BrevoToolCatalog.string(), "subject": BrevoToolCatalog.string(998),
            "sender": BrevoToolCatalog.sender, "recipients": BrevoToolCatalog.recipients,
            "html_content": BrevoToolCatalog.string(250000), "template_id": BrevoToolCatalog.integer(),
            "preview_text": BrevoToolCatalog.string(1000), "tag": BrevoToolCatalog.string(),
            "reply_to": BrevoToolCatalog.string(254), "scheduled_at": BrevoToolCatalog.string(64),
            "utm_campaign": BrevoToolCatalog.string(), "utm_content": BrevoToolCatalog.string(), "utm_term": BrevoToolCatalog.string(),
            "body_json": BrevoToolCatalog.string(262144), "email_to": BrevoToolCatalog.array(BrevoToolCatalog.string(254), max: 20),
            "confirm_send": BrevoToolCatalog.string(32), "expected_audience_version": BrevoToolCatalog.string(64),
        ]) { _, b in b }
        return p
    }
    static func spec() -> JSONObject {
        ["name": "brevo_campaign", "title": "Brevo campaign",
            "description": "Configured-account campaign drafts and delivery. Prefer typed fields; body_json is legacy advanced input. preflight is read-only and resolves actual recipient membership/upper bound (not Shopify consent). All writes default dry-run. Live: apply, confirm_write, verified_account_email; existing campaigns need current expected_modified_at. Send/schedule additionally require confirm_send=campaign_id (new for create), expected_recipient_count, maximum_recipients and expected_audience_version. No automatic retry. Scheduled membership can change before send.",
            "inputSchema": BrevoToolCatalog.object(fields, required: ["action"]),
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]]
    }
    static func body(_ a: JSONObject, creating: Bool) throws -> JSONObject? {
        let typed = mapping.reduce(into: JSONObject()) { if let value = a[$1.key] { $0[$1.value] = value } }
        let result: JSONObject
        if let text = a["body_json"] as? String {
            guard typed.isEmpty else { throw LocalMCPError.invalidRequest("Use typed fields or legacy body_json, not both") }
            result = try BrevoOperations.parseBodyJSON(text)
        } else { result = typed }
        if result.isEmpty { return nil }
        var legacyFields = mapping.reduce(into: JSONObject()) { $0[$1.value] = fields[$1.key] }
        for key in ["footer", "header", "toField", "subjectA", "subjectB", "unsubscriptionPageId", "updateFormId"] {
            legacyFields[key] = BrevoToolCatalog.string(4096)
        }
        for key in ["abTesting", "inlineImageActivation", "mirrorActive", "ipWarmupEnable", "sendAtBestTime"] {
            legacyFields[key] = BrevoToolCatalog.boolean
        }
        legacyFields["winnerDelay"] = BrevoToolCatalog.integer(168)
        legacyFields["initialQuota"] = BrevoToolCatalog.integer(100000, min: 2)
        legacyFields["increaseRate"] = BrevoToolCatalog.integer(100, min: 0)
        legacyFields["splitRule"] = BrevoToolCatalog.integer(50)
        legacyFields["winnerCriteria"] = BrevoToolCatalog.choice(["open", "click"])
        legacyFields["params"] = BrevoToolCatalog.attributes
        legacyFields["emailExpirationDate"] = BrevoToolCatalog.object([
            "duration": BrevoToolCatalog.integer(3600), "unit": BrevoToolCatalog.choice(["days", "weeks", "months"])])
        // Inline content/template IDs only: no unreviewed remote HTML/attachment fetches.
        try BrevoToolCatalog.validate(result, schema: BrevoToolCatalog.object(legacyFields))
        if let email = (result["sender"] as? JSONObject)?["email"] as? String { try BrevoSafety.email(email) }
        if let email = result["replyTo"] as? String { try BrevoSafety.email(email) }
        try BrevoOperations.validateCampaignBody(result, creating: creating)
        return result
    }
    static func execute(_ a: JSONObject, transport: BrevoOperations.Transport? = nil) throws -> JSONObject {
        try BrevoToolCatalog.validate(a, schema: BrevoToolCatalog.object(fields, required: ["action"]))
        let action = a["action"] as! String
        let creating = action == "create"
        let id: Int? = creating || (action == "preflight" && a["campaign_id"] == nil) ? nil : try BrevoOperations.positiveCampaignID(a)
        let path = id.map { "emailCampaigns/\($0)" } ?? "emailCampaigns"
        var body = try body(a, creating: creating)
        if ["create", "update", "schedule"].contains(action), body == nil { throw LocalMCPError.invalidRequest("Campaign fields required") }
        if ["send_now", "send_test", "archive", "cancel_schedule"].contains(action), body != nil { throw LocalMCPError.invalidRequest("This action does not accept campaign edits") }
        if action == "duplicate" {
            guard let b = body, Set(b.keys) == ["name"] else { throw LocalMCPError.invalidRequest("duplicate requires only a new name and source campaign_id") }
        }
        if action == "schedule", body?["scheduledAt"] == nil { throw LocalMCPError.invalidRequest("schedule requires scheduled_at") }
        if action != "send_test", a["email_to"] != nil { throw LocalMCPError.invalidRequest("email_to is only for send_test") }
        var maySend = ["send_now", "send_test", "schedule"].contains(action) || BrevoOperations.publicationRequested(body)
        let method = ["create", "duplicate", "send_now", "send_test"].contains(action) ? "POST" : "PUT"
        let writePath = action == "send_now" ? path + "/sendNow" : action == "send_test" ? path + "/sendTest" :
            ["archive", "cancel_schedule"].contains(action) ? path + "/status" : action == "duplicate" ? "emailCampaigns" : path
        let emails = action == "send_test" ? try BrevoOperations.validatedEmails(a) : []
        if a["apply"] as? Bool != true && action != "preflight" {
            return ["dry_run": true, "action": action, "outcome": "dry_run", "write_occurred": false,
                "method": method, "endpoint": "/v3/" + writePath, "campaign_id": id.map { $0 as Any } ?? NSNull(),
                "body": BrevoOperations.sanitize(body ?? [:], secret: ""), "changed_fields": body?.keys.sorted() ?? [],
                "email_to": emails, "may_send": maySend, "affected_recipient_count": emails.isEmpty ? NSNull() : emails.count,
                "credential_read": false, "network_request": false, "validation_errors": [],
                "pending_checks": ["live account", "current campaign revision/state", "recipient preflight for any send"],
                "note": "Offline dry-run; existing campaign may already be scheduled. Call preflight to resolve its current audience. No email sent."]
        }
        if action != "preflight" { try BrevoSafety.requireWriteConsent(a) }
        let session = try BrevoOperations.boundSession(transport)
        if action != "preflight" { try BrevoSafety.confirmWrite(a, expectedAccountEmail: session.expectedAccountEmail) }
        let perform = session.perform
        let account = try BrevoSafety.verifyAccount(perform, expectedAccountEmail: session.expectedAccountEmail)
        var current: JSONObject?
        if let id {
            current = try perform("GET", path, [.init(name: "excludeHtmlContent", value: action == "duplicate" ? "false" : "true")], nil, false)
            guard let actual = try? current!.optionalInt("id", default: 0, range: 1...Int.max), actual == id else { throw LocalMCPError.conflict("campaign ID mismatch") }
            if action != "preflight" {
                // Preserve exact existing-campaign optimistic concurrency contract.
                let expected = try a.requiredString("expected_modified_at", maximumBytes: 64)
                guard current!["modifiedAt"] as? String == expected else { throw LocalMCPError.conflict("campaign changed; read it again") }
            }
        }
        if ["send_now", "schedule", "update"].contains(action) && current?["status"] as? String != "draft" {
            throw LocalMCPError.conflict("Only draft campaigns can be edited/sent; cancel/re-read scheduled work first")
        }
        if maySend {
            guard a["confirm_send"] as? String == (id.map(String.init) ?? "new") else { throw LocalMCPError.invalidRequest("confirm_send must match campaign_id (new for create)") }
            if action == "send_test" { try BrevoSafety.countGate(a, count: Set(emails.map { $0.lowercased() }).count) }
        }
        var checkedAudience: JSONObject?
        if action == "preflight" || body?["recipients"] != nil || maySend && action != "send_test" {
            if action == "preflight", a["apply"] as? Bool == true { throw LocalMCPError.invalidRequest("preflight is read-only; omit apply") }
            guard let recipients = body?["recipients"] as? JSONObject ?? current?["recipients"] as? JSONObject else { throw LocalMCPError.invalidRequest("Campaign has no resolvable recipients") }
            let audience = try BrevoAudience.resolve(recipients, perform: perform)
            checkedAudience = audience
            if action == "preflight" {
                return ["campaign_id": id.map { $0 as Any } ?? NSNull(), "modifiedAt": current?["modifiedAt"] ?? NSNull(),
                    "status": current?["status"] ?? NSNull(), "recipients": recipients, "audience": audience,
                    "account": account, "write_occurred": false, "credential_read": true]
            }
            try BrevoSafety.countGate(a, count: audience["recipient_count"] as! Int)
            guard let expected = a["expected_audience_version"] as? String, expected == audience["audience_version"] as? String else {
                throw LocalMCPError.conflict("Audience changed or expected_audience_version missing; repeat preflight")
            }
            if let before = current {
                let again = try perform("GET", path, [.init(name: "excludeHtmlContent", value: "true")], nil, false)
                guard again["modifiedAt"] as? String == before["modifiedAt"] as? String,
                      again["status"] as? String == before["status"] as? String else {
                    throw LocalMCPError.conflict("Campaign changed during audience preflight; no write sent")
                }
            }
        }
        switch action {
        case "archive": body = ["status": "archive"]
        case "cancel_schedule": body = ["status": "cancel"]
        case "send_test": body = ["emailTo": emails]
        case "duplicate":
            guard let raw = current, let html = raw["htmlContent"] as? String, let subject = raw["subject"] as? String,
                  let sourceSender = raw["sender"] as? JSONObject else { throw LocalMCPError.operationFailed("Campaign response cannot be duplicated safely") }
            let sender: JSONObject
            if let senderID = sourceSender["id"] as? Int { sender = ["id": senderID] }
            else { sender = sourceSender.filter { ["email", "name"].contains($0.key) } }
            body = ["name": body!["name"]!, "htmlContent": html, "subject": subject, "sender": sender]
            try BrevoOperations.validateCampaignBody(body!, creating: true)
            maySend = false // Clone is always an unscheduled draft without recipient lists.
        default: break
        }
        do {
            let raw = try perform(method, writePath, [], body, true)
            var result = BrevoSafety.receipt(try BrevoSafety.result(raw), mayCommunicate: maySend)
            result["audience"] = checkedAudience
            if action == "send_now" { result["note"] = "Brevo accepted immediate scheduling; this is not inbox-delivery proof." }
            if action == "schedule" || body?["scheduledAt"] != nil { result["audience_warning"] = "Verified now, not frozen until send. Lists/segments may change before delivery." }
            return result
        } catch {
            let unknown = String(describing: error).contains("WRITE_OUTCOME_UNKNOWN")
            return ["outcome": unknown ? "outcome_unknown" : "rejected", "write_occurred": unknown ? NSNull() : false,
                "outcome_certain": !unknown, "automatic_retry": false, "error": String(describing: error),
                "reconcile": "Read the campaign before any manual retry; never automatically repeat a send."]
        }
    }
}
