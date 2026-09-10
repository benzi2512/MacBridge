import Foundation
import XCTest
@testable import MacBridgeLocalCore

/// Recording fixtures only. No production account, list, customer or API request is used.
final class BrevoAudienceTests: XCTestCase {
    private let revision = "2026-09-09T12:00:00Z"
    private func contact(_ id: Int, blocked: Bool = false) -> JSONObject {
        ["id": id, "email": "fixture\(id)@example.invalid", "modifiedAt": revision, "emailBlacklisted": blocked]
    }
    final class FixtureTransport {
        var calls: [(method: String, path: String, body: JSONObject?, write: Bool)] = []
        var lists: [Int: [JSONObject]] = [:]
        var current: JSONObject = ["id": 77, "modifiedAt": "2026-09-09T12:00:00Z", "status": "draft",
            "recipients": ["lists": [13], "exclusionLists": [16]]]
        var account = "account@example.invalid"
        var pageOverride: ((Int, Int, JSONObject) -> JSONObject)?
        var changeCampaignDuringScan = false
        var writes: Int { calls.filter(\.write).count }
        func run(_ method: String, _ path: String, _ query: [URLQueryItem], _ body: JSONObject?, _ write: Bool) throws -> JSONObject {
            calls.append((method, path, body, write))
            if path == "account" { return ["email": account] }
            if write { return ["http_status": 204] }
            if path == "emailCampaigns/77" { return current }
            let segments = path.split(separator: "/")
            let list = path == "contacts" ? Int(query.first { $0.name == "segmentId" }!.value!)! : Int(segments[2])!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            let data = lists[list] ?? []
            if changeCampaignDuringScan { current["modifiedAt"] = "2026-09-09T12:01:00Z" }
            let page: JSONObject = ["contacts": Array(data.dropFirst(offset).prefix(100)), "count": data.count]
            return pageOverride?(list, offset, page) ?? page
        }
    }
    private func live(_ action: String, audience: JSONObject) -> JSONObject {
        ["action": action, "campaign_id": 77, "apply": true, "confirm_write": true,
            "verified_account_email": "account@example.invalid", "expected_modified_at": revision,
            "expected_audience_version": audience["audience_version"]!,
            "expected_recipient_count": audience["recipient_count"]!, "maximum_recipients": 300,
            "confirm_send": "77"]
    }
    func testOverlappingListsDeduplicateAndHonorExclusionsAndBlacklist() throws {
        let f = FixtureTransport()
        f.lists[9] = (1...150).map { contact($0) }
        f.lists[13] = (101...200).map { contact($0, blocked: $0 == 200) }
        f.lists[16] = [contact(149), contact(150)]
        let result = try BrevoAudience.resolve(["listIds": [9, 13], "exclusionListIds": [16]], perform: f.run)
        XCTAssertEqual(result["unique_included"] as? Int, 200)
        XCTAssertEqual(result["recipient_count"] as? Int, 197)
        XCTAssertEqual(result["excluded_or_blacklisted"] as? Int, 3)
        XCTAssertEqual(result["consent_verified"] as? Bool, false)
        XCTAssertFalse(String(decoding: try LocalJSON.encode(result), as: UTF8.self).contains("@example.invalid"))
        XCTAssertEqual(f.writes, 0)
    }
    func testPilot1243CannotBeAttachedOrSentUnder300Ceiling() throws {
        for action in ["update", "send_now", "schedule"] {
            let f = FixtureTransport(); f.lists[13] = (1...1243).map { contact($0) }; f.lists[16] = []
            let audience = try BrevoAudience.resolve(["listIds": [13], "exclusionListIds": [16]], perform: f.run)
            XCTAssertEqual(audience["recipient_count"] as? Int, 1243)
            var a = live(action, audience: audience); a["expected_recipient_count"] = 300
            if action == "update" { a["recipients"] = ["listIds": [13], "exclusionListIds": [16]] }
            if action == "schedule" { a["scheduled_at"] = "2099-01-01T12:00:00Z" }
            XCTAssertThrowsError(try BrevoCampaignActions.execute(a, transport: f.run)) { error in
                XCTAssertTrue(String(describing: error).contains("Recipient count mismatch"))
            }
            XCTAssertEqual(f.writes, 0)
        }
    }
    func testBoundedPilotAttachmentIsUnsentAndDoesNotClaimConsent() throws {
        let f = FixtureTransport(); f.lists[501] = (1...300).map { contact($0) }; f.lists[16] = [contact(300)]
        let r: JSONObject = ["listIds": [501], "exclusionListIds": [16]]
        let audience = try BrevoAudience.resolve(r, perform: f.run)
        var a = live("update", audience: audience); a.removeValue(forKey: "confirm_send"); a["recipients"] = r
        let out = try BrevoCampaignActions.execute(a, transport: f.run)
        XCTAssertEqual(f.writes, 1)
        let write = f.calls.last!
        XCTAssertEqual(write.method, "PUT"); XCTAssertEqual(write.path, "emailCampaigns/77")
        XCTAssertEqual((write.body?["recipients"] as? JSONObject)?["listIds"] as? [Int], [501])
        XCTAssertEqual((write.body?["recipients"] as? JSONObject)?["exclusionListIds"] as? [Int], [16])
        XCTAssertNil(write.body?["scheduledAt"])
        XCTAssertEqual((out["audience"] as? JSONObject)?["recipient_count"] as? Int, 299)
        XCTAssertEqual((out["audience"] as? JSONObject)?["consent_verified"] as? Bool, false)
        XCTAssertEqual(out["customer_communication"] as? String, "not_sent_by_this_action")
    }
    func testPreflightSupportsProposedAudienceAndStableLegacyAliases() throws {
        let f = FixtureTransport(); f.lists[13] = [contact(1)]; f.lists[16] = []
        let proposed = try BrevoCampaignActions.execute(["action": "preflight",
            "recipients": ["listIds": [13], "exclusionListIds": [16]]], transport: f.run)
        let current = try BrevoCampaignActions.execute(["action": "preflight", "campaign_id": 77], transport: f.run)
        XCTAssertEqual((proposed["audience"] as! JSONObject)["audience_version"] as? String,
                       (current["audience"] as! JSONObject)["audience_version"] as? String)
        XCTAssertTrue(proposed["campaign_id"] is NSNull)
        XCTAssertEqual(f.writes, 0)
    }
    func testCampaignAndAudienceRevisionsMustBothStillMatch() throws {
        let f = FixtureTransport(); f.lists[13] = [contact(1)]; f.lists[16] = []
        let audience = try BrevoAudience.resolve(["listIds": [13], "exclusionListIds": [16]], perform: f.run)
        var a = live("send_now", audience: audience)
        f.lists[13] = [contact(2)] // Same count is not the same reviewed audience.
        XCTAssertThrowsError(try BrevoCampaignActions.execute(a, transport: f.run))
        f.lists[13] = [contact(1)]; f.changeCampaignDuringScan = true
        XCTAssertThrowsError(try BrevoCampaignActions.execute(a, transport: f.run))
        XCTAssertEqual(f.writes, 0)
        a["confirm_send"] = "new"
        XCTAssertThrowsError(try BrevoCampaignActions.execute(a, transport: f.run))
        XCTAssertEqual(f.writes, 0)
    }
    func testPaginationFailsClosedOnUnstableOrMalformedMembership() throws {
        let invalid: [(Int, Int, JSONObject) -> JSONObject] = [
            { _, _, raw in var r = raw; r["count"] = true; return r },
            { _, _, raw in var r = raw; r["count"] = 100.5; return r },
            { _, _, raw in var r = raw; r.removeValue(forKey: "count"); return r },
            { _, offset, raw in var r = raw; if offset > 0 { r["count"] = 102 }; return r },
            { _, offset, raw in var r = raw; if offset > 0 { r["contacts"] = [] }; return r },
            { _, _, raw in var r = raw; var c = (r["contacts"] as! [JSONObject]); c[0].removeValue(forKey: "emailBlacklisted"); r["contacts"] = c; return r },
            { _, _, raw in var r = raw; var c = (r["contacts"] as! [JSONObject]); c[0].removeValue(forKey: "modifiedAt"); r["contacts"] = c; return r },
            { _, offset, raw in var r = raw; if offset > 0 { var c = r["contacts"] as! [JSONObject]; c[0]["id"] = 1; r["contacts"] = c }; return r },
        ]
        for override in invalid {
            let f = FixtureTransport(); f.lists[13] = (1...101).map { contact($0) }; f.pageOverride = override
            XCTAssertThrowsError(try BrevoAudience.resolve(["listIds": [13]], perform: f.run))
            XCTAssertEqual(f.writes, 0)
        }
    }
    func testUnknownBlacklistsAmbiguousSourcesAndOversizedAudiencesAreRefused() throws {
        let f = FixtureTransport(); f.lists[13] = [contact(1)]
        for r: JSONObject in [["listIds": [13, 13]], ["listIds": [13], "lists": [13]], ["listIds": []],
                               ["listIds": Array(1...21)], ["listIds": [true]]] {
            XCTAssertThrowsError(try BrevoAudience.resolve(r, perform: f.run))
        }
        f.pageOverride = { _, _, raw in var r = raw; r["count"] = 4000; return r }
        XCTAssertThrowsError(try BrevoAudience.resolve(["listIds": [13]], perform: f.run))
        XCTAssertEqual(f.writes, 0)
    }
    func testNoReadOrWriteAfterWrongAccountAndNoNetworkInDryRun() throws {
        let f = FixtureTransport(); f.account = "unapproved@example.invalid"
        XCTAssertThrowsError(try BrevoCampaignActions.execute(["action": "preflight", "campaign_id": 77], transport: f.run))
        XCTAssertEqual(f.calls.count, 1)
        f.calls = []
        let preview = try BrevoCampaignActions.execute(["action": "update", "campaign_id": 77,
            "recipients": ["listIds": [13], "exclusionListIds": [16]]], transport: f.run)
        XCTAssertTrue(f.calls.isEmpty); XCTAssertTrue(preview["affected_recipient_count"] is NSNull)
    }
}
