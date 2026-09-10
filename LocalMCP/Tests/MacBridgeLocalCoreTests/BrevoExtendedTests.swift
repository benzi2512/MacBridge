import Foundation
import XCTest
@testable import MacBridgeLocalCore

/// No network or real credentials. Every live branch injects a recording fixture.
final class BrevoExtendedTests: XCTestCase {
    private let revision = "2026-09-09T12:00:00Z"
    private func sample(_ tool: String, _ action: String) -> JSONObject {
        let defaults: JSONObject = ["identifier": "one@example.invalid", "email": "one@example.invalid",
            "list_id": 1, "folder_id": 1, "template_id": 1, "process_id": 1, "consent_group_id": 1,
            "segment_id": 1, "sender_id": 1, "campaign_id": 1, "webhook_id": 1, "source_id": 1,
            "attribute_name": "QA_SAMPLE", "attribute_category": "normal", "attribute_type": "text",
            "name": "Disposable fixture", "subject": "Fixture subject", "html_content": "<p>Fixture content only</p>",
            "sender": ["id": 1], "event_name": "fixture_event", "identifiers": ["email_id": "one@example.invalid"],
            "workflow_ids": [1], "domain": "example.invalid", "uuid": "fixture-uuid",
            "message_id": "<fixture@example.invalid>", "url": "https://receiver.example.invalid/events",
            "events": ["delivered"], "type": "transactional", "source": "email_campaign",
            "list_ids": [1], "contacts": [["email": "one@example.invalid"]]]
        var a: JSONObject = ["action": action]
        for key in BrevoToolCatalog.groups[tool]![action]!.required { a[key] = defaults[key] }
        switch (tool, action) {
        case ("brevo_contacts", "update"): a["attributes"] = ["FIRSTNAME": "Fixture"]
        case ("brevo_contacts", "update_attribute"): a["multi_category_options"] = ["Fixture"]
        case ("brevo_lists", "update"): a["name"] = "Renamed fixture"
        case ("brevo_lists", "add_members"), ("brevo_lists", "remove_members"): a["emails"] = ["one@example.invalid"]
        case ("brevo_templates", "update"): a["subject"] = "Reviewed fixture"
        case ("brevo_webhooks", "update"): a["description"] = "Fixture update"
        case ("brevo_events", "track_batch"): a["events"] = [["event_name": "fixture", "identifiers": ["email_id": "one@example.invalid"]]]
        case ("brevo_transactional", "messages"): a["email"] = "one@example.invalid"
        default: break
        }
        return a
    }
    private func live(_ input: JSONObject) -> JSONObject {
        input.merging(["apply": true, "confirm_write": true, "verified_account_email": "account@example.invalid",
            "confirm_activate": true, "confirm_sensitive": true, "confirm_destructive": true,
            "expected_modified_at": revision, "maximum_recipients": 1, "expected_recipient_count": 1]) { a, _ in a }
    }
    final class Fake {
        struct Call { let method: String; let path: String; let query: [URLQueryItem]; let body: JSONObject?; let write: Bool }
        var calls: [Call] = []
        var account = "account@example.invalid"
        var response: JSONObject = ["id": 1, "modifiedAt": "2026-09-09T12:00:00Z", "isActive": false]
        var writes: [Call] { calls.filter(\.write) }
        var mutation: JSONObject = ["http_status": 204]
        var failWrite = false
        func run(_ method: String, _ path: String, _ query: [URLQueryItem], _ body: JSONObject?, _ write: Bool) throws -> JSONObject {
            calls.append(Call(method: method, path: path, query: query, body: body, write: write))
            if path == "account" { return ["email": account, "plan": [["type": "subscription", "credits": 321]]] }
            if write {
                if failWrite { throw LocalMCPError.operationFailed("WRITE_OUTCOME_UNKNOWN: synthetic timeout") }
                return mutation
            }
            return response
        }
    }
    func testEveryNewWriteHasOfflineDryRunAndEveryActionHasAnExecutablePlan() throws {
        var covered = 0, writes = 0
        for (tool, entries) in BrevoToolCatalog.groups {
            for (action, entry) in entries {
                let a = sample(tool, action), fake = Fake()
                if action == "capabilities" {
                    XCTAssertEqual(try BrevoExtendedOperations.execute(tool, a, transport: fake.run)["network_request"] as? Bool, false)
                } else {
                    let plan = try BrevoExtendedOperations.makePlan(tool, action, a)
                    XCTAssertFalse(plan.path.isEmpty)
                    XCTAssertFalse(plan.path.contains("://"))
                    XCTAssertEqual(plan.method != "GET", entry.writes, tool + "/" + action)
                    if entry.writes {
                        let out = try BrevoExtendedOperations.execute(tool, a, transport: fake.run)
                        XCTAssertEqual(out["dry_run"] as? Bool, true)
                        XCTAssertEqual(out["credential_read"] as? Bool, false)
                        XCTAssertTrue(fake.calls.isEmpty)
                        writes += 1
                    }
                }
                covered += 1
            }
        }
        XCTAssertGreaterThan(covered, 65); XCTAssertGreaterThan(writes, 25)
    }
    func testEveryWriteChecksAccountAndFlags() throws {
        for (tool, entries) in BrevoToolCatalog.groups {
            for (action, entry) in entries where entry.writes {
                for wrong in ["unapproved@example.invalid", "other@example.invalid"] {
                    let fake = Fake(); fake.account = wrong
                    XCTAssertThrowsError(try BrevoExtendedOperations.execute(tool, live(sample(tool, action)), transport: fake.run))
                    XCTAssertTrue(fake.writes.isEmpty, tool + action)
                }
                var a = live(sample(tool, action)); a["confirm_write"] = false
                let fake = Fake()
                XCTAssertThrowsError(try BrevoExtendedOperations.execute(tool, a, transport: fake.run))
                XCTAssertTrue(fake.calls.isEmpty)
            }
        }
    }
    func testWrongAccountIsAlsoRefusedForReads() throws {
        let f = Fake(); f.account = "unapproved@example.invalid"
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_contacts", ["action": "get", "identifier": "one@example.invalid"], transport: f.run))
        XCTAssertEqual(f.calls.count, 1)
    }
    func testStrictTypesAndActionSpecificArgumentsAreCheckedBeforeCredentials() throws {
        for key in ["apply", "confirm_write", "confirm_activate", "confirm_sensitive", "confirm_destructive"] {
            for value: Any in [1, "true", NSNull()] {
                let f = Fake(); var a = sample("brevo_lists", "create"); a[key] = value
                XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_lists", a, transport: f.run))
                XCTAssertTrue(f.calls.isEmpty)
            }
        }
        for extra in ["credential_path", "api_key", "http_method", "url", "transport", "unlink_list_ids"] {
            let f = Fake()
            XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_contacts", ["action": "get", "identifier": "x", extra: "bad"], transport: f.run))
            XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testListCreateRenameDeleteAndVersions() throws {
        let f = Fake(); f.mutation = ["id": 501, "http_status": 201]
        _ = try BrevoExtendedOperations.execute("brevo_lists", live(sample("brevo_lists", "create")), transport: f.run)
        XCTAssertEqual(f.writes[0].path, "contacts/lists")
        XCTAssertEqual(f.writes[0].body?["folderId"] as? Int, 1)
        f.response = ["id": 1, "name": "Original", "folderId": 1, "totalSubscribers": 0]
        var a = live(sample("brevo_lists", "update")); a.removeValue(forKey: "expected_modified_at")
        a["expected_version"] = try BrevoSafety.version(f.response)
        _ = try BrevoExtendedOperations.execute("brevo_lists", a, transport: f.run)
        XCTAssertEqual(f.writes.last?.method, "PUT")
        f.response["name"] = "Concurrent edit"
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_lists", a, transport: f.run))
        var deletion = live(sample("brevo_lists", "delete")); deletion["confirm_destructive"] = false
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_lists", deletion, transport: f.run))
        deletion["confirm_destructive"] = true; deletion.removeValue(forKey: "expected_modified_at")
        deletion["expected_version"] = try BrevoSafety.version(f.response)
        _ = try BrevoExtendedOperations.execute("brevo_lists", deletion, transport: f.run)
        XCTAssertEqual(f.writes.last?.method, "DELETE")
    }
    func testPaginationNeverInventsTotalOrSilentlyTruncates() throws {
        let unknown = try BrevoSafety.page(["events": [[:]]], key: "events", limit: 1, offset: 4)
        XCTAssertTrue(unknown["count"] is NSNull)
        XCTAssertEqual(unknown["has_more"] as? Bool, true); XCTAssertEqual(unknown["next_offset"] as? Int, 5)
        let known = try BrevoSafety.page(["contacts": [[:]], "count": 5], key: "contacts", limit: 2, offset: 4)
        XCTAssertEqual(known["has_more"] as? Bool, false)
        XCTAssertThrowsError(try BrevoSafety.page(["contacts": [], "count": 5], key: "contacts", limit: 2, offset: 0))
        XCTAssertThrowsError(try BrevoSafety.page(["contacts": [[:], [:]]], key: "contacts", limit: 1, offset: 0))
    }
    func testMembershipAndSensitiveFieldsNeedDistinctGates() throws {
        let f = Fake()
        for (tool, action, gate) in [("brevo_lists", "add_members", "confirm_activate"), ("brevo_contacts", "update", "confirm_sensitive")] {
            var a = live(sample(tool, action))
            if tool == "brevo_contacts" { a["attributes"] = ["EMAIL": "changed@example.invalid"] }
            a[gate] = false
            XCTAssertThrowsError(try BrevoExtendedOperations.execute(tool, a, transport: f.run))
            XCTAssertTrue(f.writes.isEmpty)
        }
        var args = live(sample("brevo_lists", "add_members")); args["expected_recipient_count"] = 2
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_lists", args, transport: f.run))
        args["expected_recipient_count"] = 1
        _ = try BrevoExtendedOperations.execute("brevo_lists", args, transport: f.run)
        XCTAssertEqual(f.writes.count, 1)
        XCTAssertEqual(f.writes[0].body?["emails"] as? [String], ["one@example.invalid"])
    }
    func testImportNeverBlindlyOverwritesOrBulkUnblacklists() throws {
        let f = Fake()
        var a = live(sample("brevo_contacts", "import")); a["update_existing"] = true
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_contacts", a, transport: f.run))
        a["update_existing"] = false; f.mutation = ["processId": 33, "http_status": 202]
        let result = try BrevoExtendedOperations.execute("brevo_contacts", a, transport: f.run)
        XCTAssertEqual(result["outcome"] as? String, "accepted"); XCTAssertEqual(result["processId"] as? Int, 33)
        XCTAssertEqual(f.writes[0].body?["disableNotification"] as? Bool, true)
        XCTAssertEqual(f.writes[0].body?["updateExistingContacts"] as? Bool, false)
        XCTAssertNil(f.writes[0].body?["notifyUrl"]); XCTAssertNil(f.writes[0].body?["emailBlacklist"])
    }
    func testUnknownWriteOutcomeAndPartialBatchAreNotRetriedOrMarkedComplete() throws {
        let f = Fake(); f.failWrite = true
        let result = try BrevoExtendedOperations.execute("brevo_lists", live(sample("brevo_lists", "create")), transport: f.run)
        XCTAssertEqual(result["outcome"] as? String, "outcome_unknown"); XCTAssertTrue(result["write_occurred"] is NSNull)
        XCTAssertEqual(f.writes.count, 1)
        f.failWrite = false; f.mutation = ["http_status": 207, "successful_events": 1, "failed_events": 1]
        let batch = try BrevoExtendedOperations.execute("brevo_events", live(sample("brevo_events", "track_batch")), transport: f.run)
        XCTAssertEqual(batch["outcome"] as? String, "partial"); XCTAssertEqual(batch["outcome_certain"] as? Bool, false)
    }
    func testWebhookSecretsAndAccountFeatureProjection() throws {
        let secret = "fixture-secret-value"
        let raw: JSONObject = ["webhooks": [["id": 1, "events": ["delivered"], "url": "https://example.invalid/\(secret)?token=\(secret)",
            "auth": ["token": secret], "headers": [["key": "X-Custom", "value": secret]]]]]
        let result = try BrevoSafety.result(raw)
        XCTAssertFalse(String(decoding: try LocalJSON.encode(result), as: UTF8.self).contains(secret))
        let nested = (result["webhooks"] as! [JSONObject])[0]
        XCTAssertEqual(nested["target_origin"] as? String, "https://example.invalid")
        let twice = BrevoOperations.sanitize(result, secret: "") as! JSONObject
        XCTAssertEqual((twice["webhooks"] as! [JSONObject])[0]["target_origin"] as? String, "https://example.invalid")
        let account = try BrevoOperations.decodeResponse(try LocalJSON.encode(["email": "account@example.invalid", "relay": ["enabled": true, "password": secret],
            "marketingAutomation": ["enabled": true, "key": secret]]), status: 200, secret: secret, isWrite: false)
        let projection = try BrevoOperations.accountProjection(account)
        XCTAssertEqual(projection["automation_enabled"] as? Bool, true)
        XCTAssertFalse(String(decoding: try LocalJSON.encode(projection), as: UTF8.self).contains(secret))
    }
    func testWebhookURLSecurityAndUnsupportedActions() throws {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=secret", "https://localhost/a", "https://127.0.0.1", "https://example.local", "https://example.com:8443"] {
            XCTAssertThrowsError(try BrevoSafety.webhookURL(url), url)
        }
        for (tool, action) in [("brevo_automations", "activate"), ("brevo_segments", "create"), ("brevo_webhooks", "activate"), ("brevo_transactional", "send")] {
            let f = Fake()
            XCTAssertThrowsError(try BrevoExtendedOperations.execute(tool, ["action": action], transport: f.run))
            XCTAssertTrue(f.calls.isEmpty)
        }
    }
    func testTemplateActiveEditsVersionChecksAndContentMinimization() throws {
        let f = Fake(); f.response["htmlContent"] = "<p>Secret business content</p>"; f.response["isActive"] = true
        let read = try BrevoExtendedOperations.execute("brevo_templates", ["action": "get", "template_id": 1], transport: f.run)
        XCTAssertNil(read["htmlContent"]); XCTAssertNotNil(read["content_omitted"])
        var a = live(sample("brevo_templates", "update")); a["confirm_activate"] = false
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_templates", a, transport: f.run))
        a["confirm_activate"] = true; a["expected_modified_at"] = "stale"
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_templates", a, transport: f.run))
        XCTAssertTrue(f.writes.isEmpty)
    }
    func testDatePairsAndExactPathEncoding() throws {
        XCTAssertThrowsError(try BrevoSafety.dates(["start_date": "2026-09-01"]))
        XCTAssertThrowsError(try BrevoSafety.dates(["start_date": "2026-09-02", "end_date": "2026-09-01"]))
        XCTAssertThrowsError(try BrevoSafety.dates(["days": 1, "start_date": "2026-09-01", "end_date": "2026-09-02"]))
        XCTAssertEqual(try BrevoSafety.component("a+b@example.invalid"), "a%2Bb%40example.invalid")
        XCTAssertThrowsError(try BrevoSafety.component(".."))
        XCTAssertEqual(try BrevoSafety.component("id/a?b#c"), "id%2Fa%3Fb%23c")
    }
    func testReadQueriesUseDocumentedPathsAndFilters() throws {
        let contacts = try BrevoExtendedOperations.makePlan("brevo_contacts", "list", ["action": "list", "segment_id": 3, "limit": 10, "offset": 5])
        XCTAssertTrue(contacts.query.contains(.init(name: "segmentId", value: "3")))
        XCTAssertTrue(contacts.query.contains(.init(name: "offset", value: "5")))
        let events = try BrevoExtendedOperations.makePlan("brevo_events", "list", ["action": "list", "contact_ids": [1, 2]])
        XCTAssertEqual(events.query.filter { $0.name == "contact_id" }.map(\.value), ["1", "2"])
        let workflow = try BrevoExtendedOperations.makePlan("brevo_automations", "attribution", ["action": "attribution", "workflow_ids": [12]])
        XCTAssertEqual(workflow.path, "ecommerce/attribution/metrics")
        XCTAssertEqual(workflow.query.first?.name, "automationWorkflowEmailId[]")
    }
    func testEveryNewWriteRoutesThroughRealMCPDispatcherInDryRun() throws {
        let f = try Fixture(); defer { f.remove() }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let server = try LocalMCPServer(configurationURL: f.config,
            selfExecutable: products.appendingPathComponent("macbridge-mcp"))
        var count = 0
        for (tool, entries) in BrevoToolCatalog.groups {
            for (action, entry) in entries where entry.writes {
                let output = try server.callTool(name: tool, arguments: sample(tool, action))
                XCTAssertEqual(output["dry_run"] as? Bool, true, tool + "/" + action)
                XCTAssertEqual(output["write_occurred"] as? Bool, false)
                XCTAssertEqual(output["credential_read"] as? Bool, false)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 25)
    }
    func testCatalogIsStableAndGroupSchemasKeepTheirBroadestActionBounds() throws {
        let expected = try LocalJSON.encode(BrevoToolCatalog.specs())
        for _ in 0..<20 { XCTAssertEqual(try LocalJSON.encode(BrevoToolCatalog.specs()), expected) }
        let reports = try XCTUnwrap(BrevoToolCatalog.specs().first { $0["name"] as? String == "brevo_reports" })
        let fields = (reports["inputSchema"] as! JSONObject)["properties"] as! JSONObject
        XCTAssertEqual((fields["days"] as! JSONObject)["maximum"] as? Int, 90)
        let f = Fake()
        XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_reports", ["action": "daily", "days": 90], transport: f.run))
        XCTAssertTrue(f.calls.isEmpty)
    }
    func testWebhookInventoryCoversAllTypesAndReportsPartialFailures() throws {
        var types: [String] = []
        let transport: BrevoOperations.Transport = { _, path, query, _, _ in
            if path == "account" { return ["email": "account@example.invalid"] }
            let type = query.first { $0.name == "type" }!.value!
            types.append(type)
            if type == "inbound" { throw LocalMCPError.operationFailed("Brevo HTTP 403: feature unavailable") }
            return ["webhooks": [["id": type == "marketing" ? 1 : 2, "type": type, "events": ["delivered"],
                "url": "https://example.invalid/secret-path?token=synthetic-secret"]]]
        }
        let out = try BrevoExtendedOperations.execute("brevo_webhooks", ["action": "list"], transport: transport)
        XCTAssertEqual(types, ["marketing", "transactional", "inbound"])
        XCTAssertEqual((out["webhooks"] as? [JSONObject])?.count, 2)
        XCTAssertEqual(out["complete"] as? Bool, false)
        XCTAssertTrue(out["count"] is NSNull)
        XCTAssertEqual((out["type_errors"] as? [JSONObject])?.count, 1)
        XCTAssertFalse(String(decoding: try LocalJSON.encode(out), as: UTF8.self).contains("synthetic-secret"))
    }
    func testImportRejectsConsentBackdoorsAndProcessLinksStayRedacted() throws {
        for key in ["EMAIL", "MARKETING_CONSENT", "OPTIN", "SUBSCRIBED", "EMAIL_BLACKLIST"] {
            let f = Fake(); var a = sample("brevo_contacts", "import")
            a["contacts"] = [["email": "one@example.invalid", "attributes": [key: "forbidden"]]]
            XCTAssertThrowsError(try BrevoExtendedOperations.execute("brevo_contacts", a, transport: f.run))
            XCTAssertTrue(f.calls.isEmpty)
        }
        let out = try BrevoSafety.result(["id": 1, "status": "completed",
            "info": ["import": ["invalid_emails": "https://example.invalid/capability-secret",
                "duplicate_contact_id": NSNull()]], "export_url": "https://example.invalid/capability-secret"])
        XCTAssertFalse(String(decoding: try LocalJSON.encode(out), as: UTF8.self).contains("capability-secret"))
        XCTAssertEqual(out["status"] as? String, "completed")
    }
    func testCampaignLegacyBodyCannotBypassTypedValidation() throws {
        for body: JSONObject in [["sender": ["id": true]], ["recipients": ["listIds": [true]]],
            ["subject": 1], ["templateId": "1"], ["htmlUrl": "https://example.invalid/content"],
            ["attachmentUrl": "https://example.invalid/file"], ["status": "queued"],
            ["abTesting": 1], ["sendAtBestTime": "true"]] {
            let f = Fake()
            let a: JSONObject = ["action": "update", "campaign_id": 77,
                "body_json": String(decoding: try LocalJSON.encode(body), as: UTF8.self)]
            XCTAssertThrowsError(try BrevoCampaignActions.execute(a, transport: f.run))
            XCTAssertTrue(f.calls.isEmpty)
        }
    }
}
