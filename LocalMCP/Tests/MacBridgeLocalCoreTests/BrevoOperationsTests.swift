import Foundation
import XCTest

@testable import MacBridgeLocalCore

/// All account/campaign responses are synthetic. Every operation injects an
/// in-memory transport. Delegate tests use suspended local URLSession tasks and
/// call callbacks directly; no task is resumed and no real credential is read.
final class BrevoOperationsTests: XCTestCase {
    private let campaignID = 76001
    private let modifiedAt = "2026-09-08T10:00:00Z"

    func testEveryCampaignActionDefaultsToOfflinePreview() throws {
        for action in ["create", "update", "send_test", "send_now"] {
            let fake = FakeTransport()
            let result = try BrevoOperations.executeCampaign(arguments(action), transport: fake.perform)
            XCTAssertEqual(result["dry_run"] as? Bool, true, action)
            XCTAssertEqual(result["credential_read"] as? Bool, false, action)
            XCTAssertEqual(result["network_request"] as? Bool, false, action)
            XCTAssertEqual(result["may_send"] as? Bool, action.hasPrefix("send_"), action)
            XCTAssertTrue(fake.calls.isEmpty, action)
        }
    }

    func testApplyFalseRemainsOfflineEvenWithAllConfirmations() throws {
        let fake = FakeTransport()
        var args = liveArguments("send_now")
        args["apply"] = false
        let result = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(result["dry_run"] as? Bool, true)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testApplyRequiresExplicitWriteConfirmationBeforeAnyTransportCall() throws {
        for confirmation in [nil, false] as [Bool?] {
            let fake = FakeTransport()
            var args = liveArguments("update")
            args["confirm_write"] = confirmation
            assertRejected(args, fake: fake, containing: "confirm_write")
            XCTAssertTrue(fake.calls.isEmpty)
        }
    }

    func testMissingOrWrongVerifiedAccountStopsBeforeAnyTransportCall() throws {
        for email in [nil, "other@example.invalid"] as [String?] {
            let fake = FakeTransport()
            var args = liveArguments("update")
            args["verified_account_email"] = email
            assertRejected(args, fake: fake, containing: "verified_account_email")
            XCTAssertTrue(fake.calls.isEmpty)
        }
    }

    func testActualCredentialAccountMustMatchTheProductionAccount() throws {
        for account: JSONObject in [["email": "other@example.invalid"], [:], ["email": NSNull()]] {
            let fake = FakeTransport(account: account)
            assertRejected(liveArguments("update"), fake: fake, containing: "account mismatch")
            XCTAssertEqual(fake.calls.map(\.path), ["account"])
            XCTAssertTrue(fake.writes.isEmpty)
        }
    }

    func testAccountEmailComparisonAcceptsCaseDifferences() throws {
        let fake = transport(account: ["email": "ACCOUNT@EXAMPLE.INVALID"])
        var args = liveArguments("update")
        args["verified_account_email"] = "ACCOUNT@EXAMPLE.INVALID"
        _ = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(fake.writes.count, 1)
    }

    func testExistingCampaignRequiresAnExactModifiedAtMatch() throws {
        for expected in [nil, "2026-09-08T09:59:59Z"] as [String?] {
            let fake = transport()
            var args = liveArguments("update")
            args["expected_modified_at"] = expected
            assertRejected(args, fake: fake)
            XCTAssertEqual(fake.calls.map(\.path), ["account", "emailCampaigns/\(campaignID)"])
            XCTAssertTrue(fake.writes.isEmpty)
        }
        let fake = transport(current: ["id": campaignID, "status": "draft"])
        assertRejected(liveArguments("update"), fake: fake, containing: "campaign changed")
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testResponseCampaignIDMustBeTheExactRequestedInteger() throws {
        for returnedID: Any in [campaignID + 1, Double(campaignID) + 0.5, "76001", true, NSNull()] {
            let fake = transport(current: ["id": returnedID, "modifiedAt": modifiedAt, "status": "draft"])
            assertRejected(liveArguments("update"), fake: fake, containing: "campaign ID")
            XCTAssertTrue(fake.writes.isEmpty, "Unexpected write for returned ID \(returnedID)")
        }
    }

    func testCampaignIDRejectsMissingNonpositiveFractionalAndBooleanValuesOffline() throws {
        for raw: Any? in [nil, 0, -1, 7.5, true, "76001"] {
            let fake = FakeTransport()
            var args = arguments("send_now")
            args["campaign_id"] = raw
            assertRejected(args, fake: fake, containing: "campaign_id")
            XCTAssertTrue(fake.calls.isEmpty)
        }
    }

    func testSendNowRequiresAnExactDraftStatus() throws {
        for status: Any in ["queued", "sent", "suspended", "inProcess", "inReview", "archive", "Draft", "", NSNull()] {
            let fake = transport(current: ["id": campaignID, "modifiedAt": modifiedAt, "status": status])
            assertRejected(liveArguments("send_now"), fake: fake, containing: "draft")
            XCTAssertTrue(fake.writes.isEmpty, "Unexpected write for status \(status)")
        }
        let fake = transport(current: ["id": campaignID, "modifiedAt": modifiedAt])
        assertRejected(liveArguments("send_now"), fake: fake, containing: "draft")
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testSendNowAndSendTestRequireMatchingSendConfirmation() throws {
        for action in ["send_now", "send_test"] {
            for confirmation in [nil, "new", "76002"] as [String?] {
                let fake = transport()
                var args = liveArguments(action)
                args["confirm_send"] = confirmation
                assertRejected(args, fake: fake, containing: "confirm_send")
                XCTAssertTrue(fake.writes.isEmpty, action)
            }
        }
    }

    func testSendNowIssuesOneMutationAfterAccountAndCampaignPreflight() throws {
        let fake = transport()
        let result = try BrevoOperations.executeCampaign(liveArguments("send_now"), transport: fake.perform)
        XCTAssertEqual(fake.calls.map(\.method), ["GET", "GET", "GET", "GET", "POST"])
        XCTAssertEqual(fake.calls.map(\.path), ["account", "emailCampaigns/\(campaignID)", "contacts/lists/1/contacts", "emailCampaigns/\(campaignID)", "emailCampaigns/\(campaignID)/sendNow"])
        XCTAssertEqual(fake.calls.map(\.isWrite), [false, false, false, false, true])
        XCTAssertNil(fake.writes.first?.body)
        XCTAssertEqual(fake.calls[1].query, [URLQueryItem(name: "excludeHtmlContent", value: "true")])
        XCTAssertEqual(result["http_status"] as? Int, 204)
        XCTAssertTrue((result["note"] as? String)?.contains("not inbox-delivery proof") == true)
    }

    func testDraftCreationDoesNotRequireSendConfirmationOrExistingCampaignRead() throws {
        let fake = transport()
        var args = liveArguments("create")
        args.removeValue(forKey: "confirm_send")
        args.removeValue(forKey: "expected_modified_at")
        _ = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(fake.calls.map(\.path), ["account", "emailCampaigns"])
        XCTAssertEqual(fake.writes.map(\.method), ["POST"])
        XCTAssertEqual(fake.writes.first?.body?["name"] as? String, "Offline fixture draft")
    }

    func testNewCampaignPublicationRequiresNewConfirmation() throws {
        for publication: JSONObject in [["scheduledAt": "2099-01-01T12:00:00Z"], ["sendAtBestTime": true]] {
            for confirmation in [nil, String(campaignID)] as [String?] {
                let fake = transport()
                var args = liveArguments("create")
                args["body_json"] = try bodyJSON(createBody.merging(publication) { _, value in value })
                args["confirm_send"] = confirmation
                assertRejected(args, fake: fake, containing: "confirm_send")
                XCTAssertTrue(fake.writes.isEmpty)
            }
        }
        let fake = transport()
        var args = liveArguments("create")
        args["body_json"] = try bodyJSON(createBody.merging(["scheduledAt": "2099-01-01T12:00:00Z", "recipients": ["listIds": [1]]]) { _, value in value })
        args["confirm_send"] = "new"
        _ = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(fake.writes.count, 1)
    }

    func testUpdateOfScheduledCampaignIsRefusedUntilCancelledEvenWithSendGate() throws {
        for status in ["queued", "inProcess", "inReview", "suspended", "sent", "archive"] {
            let fake = transport(current: ["id": campaignID, "modifiedAt": modifiedAt, "status": status])
            var args = liveArguments("update")
            args.removeValue(forKey: "confirm_send")
            assertRejected(args, fake: fake, containing: "draft")
            XCTAssertTrue(fake.writes.isEmpty, status)
        }
        let fake = transport(current: ["id": campaignID, "modifiedAt": modifiedAt, "status": "queued"])
        assertRejected(liveArguments("update"), fake: fake, containing: "draft")
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testDraftUpdateWithoutPublicationNeedsNoSendConfirmation() throws {
        let fake = transport()
        var args = liveArguments("update")
        args.removeValue(forKey: "confirm_send")
        _ = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(fake.writes.map(\.method), ["PUT"])
    }

    func testStatusTransitionsAndBestTimeOrExplicitSchedulingRequireSendConfirmation() throws {
        for patch: JSONObject in [["status": "queued"], ["status": "draft"], ["status": "suspended"],
                                  ["sendAtBestTime": true], ["scheduledAt": "2099-01-01T12:00:00+00:00"]] {
            let fake = transport()
            var args = liveArguments("update")
            args["body_json"] = try bodyJSON(patch)
            args.removeValue(forKey: "confirm_send")
            assertRejected(args, fake: fake, containing: patch["status"] == nil ? "confirm_send" : "status")
            XCTAssertTrue(fake.writes.isEmpty)
        }
    }

    func testInvalidTestRecipientsNeverCauseAMutation() throws {
        let invalid: [Any] = [[], "reviewer@example.invalid", [NSNull()],
                              Array(repeating: "reviewer@example.invalid", count: 21),
                              [""], ["person"], ["person@domain"], ["a@@example.invalid"],
                              ["person@example.invalid\nBcc: other@example.invalid"],
                              [String(repeating: "x", count: 245) + "@example.invalid"]]
        for apply in [false, true] {
            for recipients in invalid {
                let fake = transport()
                var args = liveArguments("send_test")
                args["apply"] = apply
                args["email_to"] = recipients
                assertRejected(args, fake: fake, containing: "email_to")
                XCTAssertTrue(fake.writes.isEmpty)
                if !apply { XCTAssertTrue(fake.calls.isEmpty) }
            }
            let fake = transport()
            var args = liveArguments("send_test")
            args["apply"] = apply
            args.removeValue(forKey: "email_to")
            assertRejected(args, fake: fake, containing: "email_to")
            XCTAssertTrue(fake.writes.isEmpty)
        }
    }

    func testSendTestUsesOnlyExplicitRecipientsAndOneMutation() throws {
        let fake = transport()
        var args = liveArguments("send_test")
        let recipients = ["reviewer@example.invalid", "second@example.invalid"]
        args["email_to"] = recipients
        args["expected_recipient_count"] = 2
        args["maximum_recipients"] = 2
        _ = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertEqual(fake.writes.first?.path, "emailCampaigns/\(campaignID)/sendTest")
        XCTAssertEqual(fake.writes.first?.body?["emailTo"] as? [String], recipients)
        XCTAssertEqual(Set(fake.writes.first?.body?.keys.map { $0 } ?? []), ["emailTo"])
    }

    func testInvalidBodyJSONAndCreationContentFailBeforeTransport() throws {
        for raw in ["not-json", "{}", "[]", "null", "{\"subject\":"] {
            let fake = FakeTransport()
            var args = liveArguments("update")
            args["body_json"] = raw
            assertRejected(args, fake: fake, containing: "body_json")
            XCTAssertTrue(fake.calls.isEmpty)
        }
        var missingSubject = createBody
        missingSubject.removeValue(forKey: "subject")
        var missingContent = createBody
        missingContent.removeValue(forKey: "htmlContent")
        let invalidBodies = [missingSubject, missingContent,
                             createBody.merging(["templateId": 1]) { _, value in value },
                             createBody.merging(["sender": ["id": 1, "email": "sender@example.invalid"]]) { _, value in value }]
        for body in invalidBodies {
            let fake = FakeTransport()
            var args = liveArguments("create")
            args["body_json"] = try bodyJSON(body)
            assertRejected(args, fake: fake)
            XCTAssertTrue(fake.calls.isEmpty)
        }
    }

    func testInvalidScheduleTimezoneAndPastDateFailOffline() throws {
        for scheduled in ["2099-01-01T12:00:00", "2000-01-01T12:00:00Z", "not-a-dateZ"] {
            let fake = FakeTransport()
            var args = liveArguments("update")
            args["body_json"] = try bodyJSON(["scheduledAt": scheduled])
            assertRejected(args, fake: fake, containing: "scheduledAt")
            XCTAssertTrue(fake.calls.isEmpty)
        }
    }

    func testSendAtBestTimeRejectsNonBooleanValuesBeforeAnyTransport() throws {
        let malformed: [Any] = ["true", "false", 0, 1, 0.5, NSNull(), [], ["value": true]]
        for action in ["create", "update"] {
            for apply in [false, true] {
                for value in malformed {
                    let fake = FakeTransport()
                    var args = liveArguments(action)
                    let patch: JSONObject = ["sendAtBestTime": value]
                    let body = action == "create" ? createBody.merging(patch) { _, value in value } : patch
                    args["body_json"] = try bodyJSON(body)
                    args["apply"] = apply
                    args.removeValue(forKey: "confirm_send")
                    assertRejected(args, fake: fake, containing: "sendAtBestTime")
                    XCTAssertTrue(fake.calls.isEmpty, "Malformed publication flag reached transport: \(value)")
                }
            }
        }
    }

    func testScheduledAtAndStatusRejectNonStringValuesBeforeAnyTransport() throws {
        let malformed: [Any] = [true, false, 0, 1, 0.5, NSNull(), [], ["value": "queued"]]
        for field in ["scheduledAt", "status"] {
            for action in ["create", "update"] {
                for apply in [false, true] {
                    for value in malformed {
                        let fake = FakeTransport()
                        var args = liveArguments(action)
                        let patch: JSONObject = [field: value]
                        let body = action == "create" ? createBody.merging(patch) { _, value in value } : patch
                        args["body_json"] = try bodyJSON(body)
                        args["apply"] = apply
                        assertRejected(args, fake: fake, containing: field)
                        XCTAssertTrue(fake.calls.isEmpty, "Malformed \(field) reached transport: \(value)")
                    }
                }
            }
        }
    }

    func testBooleanFalseBestTimeFlagStillAllowsADraftUpdateWithoutSendConfirmation() throws {
        let fake = transport()
        var args = liveArguments("update")
        args["body_json"] = try bodyJSON(["subject": "Synthetic draft edit", "sendAtBestTime": false])
        args.removeValue(forKey: "confirm_send")
        _ = try BrevoOperations.executeCampaign(args, transport: fake.perform)
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertEqual(fake.writes.first?.body?["sendAtBestTime"] as? Bool, false)
    }

    func testUnknownCampaignParametersAndActionsFailBeforeTransport() throws {
        for extra in ["api_key", "url", "transport", "credential_path", "invented"] {
            let fake = FakeTransport()
            var args = liveArguments("update")
            args[extra] = "synthetic untrusted value"
            assertRejected(args, fake: fake, containing: "Unexpected parameter")
            XCTAssertTrue(fake.calls.isEmpty)
        }
        let fake = FakeTransport()
        assertRejected(["action": "delete", "campaign_id": campaignID], fake: fake, containing: "action")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testCatalogSchemasAreClosedAndDoNotExposeTransportOrCredentials() throws {
        for name in ["brevo_read", "brevo_campaign"] {
            let spec = try XCTUnwrap(ExpandedToolCatalog.specs().first { $0["name"] as? String == name })
            let schema = try XCTUnwrap(spec["inputSchema"] as? JSONObject)
            let properties = try XCTUnwrap(schema["properties"] as? JSONObject)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            for forbidden in ["api_key", "url", "transport", "credential_path"] { XCTAssertNil(properties[forbidden]) }
            let annotations = try XCTUnwrap(spec["annotations"] as? JSONObject)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, name == "brevo_read")
            XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
            if name == "brevo_campaign" { XCTAssertEqual(annotations["idempotentHint"] as? Bool, false) }
        }
    }

    func testPreflightFailureDoesNotRetryOrAttemptAMutation() throws {
        let fake = transport()
        fake.failureAtCall = 1
        assertRejected(liveArguments("send_now"), fake: fake, containing: "synthetic transport failure")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testMutationTransportFailureIsNeverRetriedForAnyAction() throws {
        for action in ["create", "update", "send_test", "send_now"] {
            let fake = transport()
            fake.failWrites = true
            let result = try BrevoOperations.executeCampaign(liveArguments(action), transport: fake.perform)
            XCTAssertEqual(result["outcome"] as? String, "outcome_unknown")
            XCTAssertEqual(result["automatic_retry"] as? Bool, false)
            XCTAssertEqual(fake.writes.count, 1, action)
            XCTAssertEqual(fake.calls.count, action == "create" ? 2 : action == "send_now" ? 5 : 3, action)
        }
    }

    func testWriteResponseFailuresAreExplicitlyUnknown() throws {
        let responses: [(Data, Int)] = [
            (Data("{\"message\":\"synthetic unavailable\"}".utf8), 500),
            (Data(), 503),
            (Data("<html>synthetic gateway failure</html>".utf8), 502),
            (Data("invalid-json".utf8), 200),
            (Data("[]".utf8), 200),
            (Data(repeating: 0x20, count: 5 * 1_024 * 1_024 + 1), 200),
        ]
        for (data, status) in responses {
            XCTAssertThrowsError(try BrevoOperations.decodeResponse(data, status: status, secret: "fixture-secret", isWrite: true)) { error in
                XCTAssertTrue(String(describing: error).contains("WRITE_OUTCOME_UNKNOWN"), "Unexpected error: \(error)")
            }
        }
    }

    func testReadResponseFailuresDoNotClaimAnUnknownWriteOutcome() throws {
        for data in [Data("invalid-json".utf8), Data("[]".utf8), Data(repeating: 0x20, count: 5 * 1_024 * 1_024 + 1)] {
            XCTAssertThrowsError(try BrevoOperations.decodeResponse(data, status: 200, secret: "fixture-secret", isWrite: false)) { error in
                XCTAssertFalse(String(describing: error).contains("WRITE_OUTCOME_UNKNOWN"))
            }
        }
    }

    func testRejectedHTTPStatusesRemainErrorsWithoutRetry() throws {
        let data = try LocalJSON.encode(["code": "synthetic_error", "message": "Rejected fixture"])
        for status in [301, 302, 307, 308, 400, 401, 402, 403, 404, 429] {
            XCTAssertThrowsError(try BrevoOperations.decodeResponse(data, status: status, secret: "fixture-secret", isWrite: true)) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("HTTP \(status)"))
                XCTAssertTrue(message.contains("no automatic retry"))
            }
        }
    }

    func testSuccessfulEmptyResponseIsAcceptanceWithoutInventedDeliveryState() throws {
        for status in [201, 204] {
            let response = try BrevoOperations.decodeResponse(Data(), status: status, secret: "fixture-secret", isWrite: true)
            XCTAssertEqual(response["http_status"] as? Int, status)
            XCTAssertEqual(Set(response.keys), ["http_status"])
        }
    }

    func testResponseRedactionRemovesSecretsRecursively() throws {
        let syntheticSecret = "synthetic-regression-secret"
        let fixture: JSONObject = [
            "id": campaignID,
            "message": "Do not return \(syntheticSecret)",
            "nested": ["apiKey": "synthetic value", "password": "synthetic value", "token": "synthetic value"],
            "array": [["safe": syntheticSecret], ["safe": "visible fixture"]],
            "relay": ["data": "synthetic value"],
            "marketingAutomation": ["data": "synthetic value"],
            "trackerKey": "synthetic value",
        ]
        let response = try BrevoOperations.decodeResponse(try LocalJSON.encode(fixture), status: 200, secret: syntheticSecret, isWrite: false)
        let rendered = try bodyJSON(response)
        XCTAssertFalse(rendered.contains(syntheticSecret))
        XCTAssertFalse(rendered.contains("synthetic value"))
        XCTAssertTrue(rendered.contains("visible fixture"))
        XCTAssertEqual(response["id"] as? Int, campaignID)
        XCTAssertEqual(response["relay"] as? String, "[REDACTED]")
    }

    func testResponseRedactionRemovesSecretOccurrencesFromJSONKeysAtEveryDepth() throws {
        let syntheticSecret = "fixturecredential012345"
        let fixture: JSONObject = [
            syntheticSecret: "synthetic root value",
            "prefix-\(syntheticSecret)-suffix": ["visible": "synthetic nested value"],
            "nested": [syntheticSecret: ["visible": "synthetic deeply nested value"]],
            "array": [["inner": ["prefix-\(syntheticSecret)": "synthetic array value"]]],
            "apiKey-\(syntheticSecret)": "synthetic credential field value",
            "unrelated": "retained public fixture",
        ]
        for isWrite in [false, true] {
            let response = try BrevoOperations.decodeResponse(try LocalJSON.encode(fixture), status: 200,
                                                             secret: syntheticSecret, isWrite: isWrite)
            let rendered = try bodyJSON(response)
            XCTAssertFalse(rendered.contains(syntheticSecret), "Secret survived in a response property name")
            XCTAssertNil(response[syntheticSecret])
            XCTAssertEqual(response["unrelated"] as? String, "retained public fixture")
        }
    }

    func testVendorErrorIsRedactedAndBounded() throws {
        let syntheticSecret = "synthetic-regression-secret"
        let fixture: JSONObject = ["code": "synthetic_error", "message": syntheticSecret + String(repeating: "x", count: 2_000)]
        XCTAssertThrowsError(try BrevoOperations.decodeResponse(try LocalJSON.encode(fixture), status: 400, secret: syntheticSecret, isWrite: true)) { error in
            let message = String(describing: error)
            XCTAssertFalse(message.contains(syntheticSecret))
            XCTAssertTrue(message.contains("[REDACTED]"))
            XCTAssertLessThan(message.count, 800)
        }
    }

    func testResponseCollectorEnforcesFiveMiBLimitBeforeAppending() throws {
        let box = BrevoOperations.ResponseBox()
        let half = Data(repeating: 0x61, count: 5 * 1_024 * 1_024 / 2)
        XCTAssertTrue(box.append(half))
        XCTAssertTrue(box.append(half))
        XCTAssertFalse(box.append(Data([0x62])))
        let (bytes, _, _) = box.snapshot()
        XCTAssertEqual(bytes?.count, 5 * 1_024 * 1_024)
        XCTAssertEqual(bytes?.last, 0x61)
    }

    func testRedirectDelegateRejectsBothSameOriginAndCrossOriginRedirectsOffline() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let initialURL = try XCTUnwrap(URL(string: "https://example.invalid/fixture"))
        // Creating a suspended task does not send a request. Never call resume().
        let task = session.dataTask(with: initialURL)
        defer { task.cancel() }
        let delegate = BrevoOperations.NoRedirectDelegate()
        for target in ["https://example.invalid/second", "https://other.example.invalid/second"] {
            let targetURL = try XCTUnwrap(URL(string: target))
            let response = try XCTUnwrap(HTTPURLResponse(url: initialURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]))
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: targetURL)) { request in
                called = true
                XCTAssertNil(request)
            }
            XCTAssertTrue(called)
        }
    }

    func testResponseDelegateCancelsAdvertisedOversizeWithoutStartingATask() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/fixture"))
        let task = session.dataTask(with: url)
        defer { task.cancel() }
        for (length, expected) in [(5 * 1_024 * 1_024 + 1, URLSession.ResponseDisposition.cancel),
                                   (5 * 1_024 * 1_024, URLSession.ResponseDisposition.allow)] {
            let delegate = BrevoOperations.NoRedirectDelegate()
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(length)]))
            var disposition: URLSession.ResponseDisposition?
            delegate.urlSession(session, dataTask: task, didReceive: response) { disposition = $0 }
            XCTAssertEqual(disposition, expected)
        }
    }

    private var createBody: JSONObject {
        ["name": "Offline fixture draft", "sender": ["id": 1],
         "subject": "Synthetic regression fixture", "htmlContent": "<p>Offline fixture only.</p>"]
    }

    private func bodyJSON(_ body: JSONObject) throws -> String {
        String(decoding: try LocalJSON.encode(body), as: UTF8.self)
    }

    private func arguments(_ action: String) -> JSONObject {
        var args: JSONObject = ["action": action]
        if action != "create" { args["campaign_id"] = campaignID }
        // These two dictionaries are fixed JSON fixtures owned by this test.
        if action == "create" { args["body_json"] = try! bodyJSON(createBody) }
        if action == "update" { args["body_json"] = try! bodyJSON(["subject": "Reviewed synthetic edit"]) }
        if action == "send_test" { args["email_to"] = ["reviewer@example.invalid"] }
        return args
    }

    private func liveArguments(_ action: String) -> JSONObject {
        var args = arguments(action)
        args["apply"] = true
        args["confirm_write"] = true
        args["verified_account_email"] = "account@example.invalid"
        args["expected_modified_at"] = modifiedAt
        args["confirm_send"] = action == "create" ? "new" : String(campaignID)
        args["maximum_recipients"] = 1
        args["expected_recipient_count"] = 1
        let audienceFake = FakeTransport()
        args["expected_audience_version"] = try! BrevoAudience.resolve(["listIds": [1]], perform: audienceFake.perform)["audience_version"]
        return args
    }

    private func transport(account: JSONObject = ["email": "account@example.invalid"], current: JSONObject? = nil) -> FakeTransport {
        FakeTransport(account: account, campaign: current ?? ["id": campaignID, "modifiedAt": modifiedAt, "status": "draft", "recipients": ["lists": [1], "exclusionLists": []]])
    }

    private func assertRejected(_ args: @autoclosure () throws -> JSONObject, fake: FakeTransport,
                                containing expected: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BrevoOperations.executeCampaign(args(), transport: fake.perform), file: file, line: line) { error in
            if let expected { XCTAssertTrue(String(describing: error).contains(expected), "Unexpected error: \(error)", file: file, line: line) }
        }
    }

    private final class FakeTransport {
        struct Call {
            let method: String
            let path: String
            let query: [URLQueryItem]
            let body: JSONObject?
            let isWrite: Bool
        }

        var calls: [Call] = []
        var account: JSONObject
        var campaign: JSONObject
        var failureAtCall: Int?
        var failWrites = false
        var writes: [Call] { calls.filter(\.isWrite) }

        init(account: JSONObject = ["email": "account@example.invalid"], campaign: JSONObject = [:]) {
            self.account = account
            self.campaign = campaign
        }

        func perform(_ method: String, _ path: String, _ query: [URLQueryItem], _ body: JSONObject?, _ isWrite: Bool) throws -> JSONObject {
            calls.append(Call(method: method, path: path, query: query, body: body, isWrite: isWrite))
            if calls.count == failureAtCall { throw LocalMCPError.operationFailed("synthetic transport failure") }
            if isWrite {
                if failWrites { throw LocalMCPError.operationFailed("WRITE_OUTCOME_UNKNOWN: synthetic write transport failure") }
                return ["http_status": 204]
            }
            if method == "GET", path == "account" { return account }
            if method == "GET", path == "contacts/lists/1/contacts" {
                return ["count": 1, "contacts": [["id": 1, "email": "one@example.invalid", "emailBlacklisted": false, "modifiedAt": "2026-09-09T12:00:00Z"]]]
            }
            if method == "GET", path.hasPrefix("emailCampaigns/") { return campaign }
            throw LocalMCPError.operationFailed("Unexpected synthetic transport route")
        }
    }
}
