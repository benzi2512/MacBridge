import CoreFoundation
import Foundation

enum BrevoSafety {
    static func component(_ text: String) throws -> String {
        guard !text.isEmpty, text != ".", text != "..", !text.contains("\0"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else {
            throw LocalMCPError.invalidRequest("Invalid Brevo identifier")
        }
        return encoded
    }
    static func verifyAccount(_ perform: BrevoOperations.Transport, expectedAccountEmail: String) throws -> JSONObject {
        let account = try perform("GET", "account", [], nil, false)
        guard (account["email"] as? String)?.lowercased() == expectedAccountEmail else {
            throw LocalMCPError.conflict("Brevo account mismatch: request refused; expected the locally configured account")
        }
        return try BrevoOperations.accountProjection(account)
    }
    static func requireWriteConsent(_ a: JSONObject) throws {
        guard a["confirm_write"] as? Bool == true else { throw LocalMCPError.invalidRequest("Live Brevo writes require confirm_write=true") }
        guard let email = a["verified_account_email"] as? String, !email.isEmpty else {
            throw LocalMCPError.invalidRequest("verified_account_email is required")
        }
        try self.email(email)
    }
    static func confirmWrite(_ a: JSONObject, expectedAccountEmail: String) throws {
        try requireWriteConsent(a)
        guard (a["verified_account_email"] as? String)?.lowercased() == expectedAccountEmail else {
            throw LocalMCPError.conflict("verified_account_email does not match the locally configured account")
        }
    }
    static func gate(_ a: JSONObject, _ name: String) throws {
        guard a[name] as? Bool == true else { throw LocalMCPError.invalidRequest("This Brevo action additionally requires \(name)=true") }
    }
    static func version(_ raw: JSONObject) throws -> String {
        var stable = raw
        for key in ["http_status", "version", "metadata", "content_omitted"] { stable.removeValue(forKey: key) }
        return LocalHash.sha256(try LocalJSON.encode(stable))
    }
    static func checkVersion(_ a: JSONObject, current: JSONObject) throws {
        if let expected = a["expected_modified_at"] as? String {
            guard (current["modifiedAt"] as? String ?? current["updatedAt"] as? String) == expected else {
                throw LocalMCPError.conflict("Brevo object changed; read current modifiedAt before retry")
            }
        } else {
            guard let expected = a["expected_version"] as? String, expected == (try version(current)) else {
                throw LocalMCPError.conflict("Brevo object changed or expected_version missing; read its current version first")
            }
        }
    }
    static func countGate(_ a: JSONObject, count: Int) throws {
        guard let maxValue = a["maximum_recipients"], let expectedValue = a["expected_recipient_count"] else {
            throw LocalMCPError.invalidRequest("Recipient-sensitive action needs maximum_recipients and expected_recipient_count from preflight")
        }
        let maximum = try ["n": maxValue].optionalInt("n", default: 0, range: 0...10000)
        let expected = try ["n": expectedValue].optionalInt("n", default: 0, range: 0...10000)
        guard count <= maximum, count == expected else { throw LocalMCPError.conflict("Recipient count mismatch: resolved \(count), expected \(expected), maximum \(maximum); no write sent") }
    }
    static func dates(_ a: JSONObject, maximumDays: Int? = nil) throws -> [URLQueryItem] {
        let start = a["start_date"] as? String, end = a["end_date"] as? String
        guard (start == nil) == (end == nil), !(start != nil && a["days"] != nil) else {
            throw LocalMCPError.invalidRequest("Use start_date/end_date together, not with days")
        }
        if let start, let end {
            func date(_ s: String) -> Date? {
                let iso = ISO8601DateFormatter()
                if s.count == 10 { return iso.date(from: s + "T00:00:00Z") }
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
            guard let from = date(start), let to = date(end), from <= to,
                  maximumDays.map({ to.timeIntervalSince(from) <= Double($0) * 86400 }) ?? true else {
                throw LocalMCPError.invalidRequest("Invalid or excessive Brevo date range")
            }
            return [.init(name: "startDate", value: start), .init(name: "endDate", value: end)]
        }
        return []
    }
    static func email(_ value: String) throws {
        guard value.utf8.count <= 254,
              value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_\x60{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil else {
            throw LocalMCPError.invalidRequest("Invalid email address")
        }
    }
    static func domain(_ value: String) throws {
        guard value.range(of: #"^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$"#, options: .regularExpression) != nil else {
            throw LocalMCPError.invalidRequest("Invalid domain name")
        }
    }
    static func webhookURL(_ text: String) throws {
        guard let url = URLComponents(string: text), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", !host.contains(":"), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else {
            throw LocalMCPError.invalidRequest("Webhook needs a public HTTPS hostname, no credentials/query/fragment/non-443 port")
        }
        try domain(host)
    }
    static func page(_ raw: JSONObject, key: String, limit: Int, offset: Int) throws -> JSONObject {
        guard let values = raw[key] as? [Any], values.count <= limit else {
            throw LocalMCPError.operationFailed("Unexpected Brevo page; results not truncated or treated as complete")
        }
        let countValue = raw["count"] ?? raw["total"]
        let total: Int?
        if let countValue, !(countValue is NSNull) {
            total = try ["count": countValue].optionalInt("count", default: 0, range: 0...Int.max)
        } else { total = nil }
        guard limit > 0, offset >= 0, offset <= Int.max - values.count else {
            throw LocalMCPError.operationFailed("Invalid Brevo pagination bounds")
        }
        if let total, !values.isEmpty, offset + values.count > total {
            throw LocalMCPError.operationFailed("Brevo page exceeds its reported total")
        }
        var result = raw
        result["count"] = total.map { $0 as Any } ?? NSNull()
        result["limit"] = limit; result["offset"] = offset; result["returned_count"] = values.count
        let more = total.map { offset + values.count < $0 } ?? (values.count == limit)
        result["has_more"] = more
        result["count_source"] = total == nil ? "not_returned_by_vendor" : "vendor"
        if more {
            guard !values.isEmpty else { throw LocalMCPError.operationFailed("Brevo pagination stalled; do not infer completeness") }
            result["next_offset"] = offset + values.count
        }
        return result
    }
    static func result(_ raw: JSONObject, includeContent: Bool = false) throws -> JSONObject {
        var safe = BrevoOperations.sanitize(raw, secret: "") as? JSONObject ?? [:]
        func project(_ object: JSONObject) throws -> JSONObject {
            var o = object
            o["version"] = try version(object)
            if !includeContent {
                var omitted: [String] = []
                for key in ["htmlContent", "textContent", "body", "html"] where o[key] != nil {
                    o.removeValue(forKey: key); omitted.append(key)
                }
                if !omitted.isEmpty { o["content_omitted"] = omitted }
            }
            return o
        }
        safe = try project(safe)
        for key in ["contacts", "lists", "folders", "templates", "webhooks", "consentGroups"] {
            if let list = safe[key] as? [JSONObject] { safe[key] = try list.map(project) }
        }
        return safe
    }
    static func receipt(_ raw: JSONObject, mayCommunicate: Bool) -> JSONObject {
        let partial = raw["http_status"] as? Int == 207 ||
            ((raw["contacts"] as? JSONObject)?["failure"] as? [Any])?.isEmpty == false
        let queued = raw["processId"] != nil || raw["http_status"] as? Int == 202
        var result = raw
        result["dry_run"] = false
        result["outcome"] = partial ? "partial" : (queued ? "accepted" : "succeeded")
        result["request_accepted"] = true
        result["write_occurred"] = queued || partial ? NSNull() : true
        result["outcome_certain"] = !queued && !partial
        result["credential_read"] = true; result["network_request"] = true
        result["customer_communication"] = mayCommunicate ? "not_verified; action can affect delivery" : "not_sent_by_this_action"
        result["automatic_retry"] = false
        result["reconcile"] = "Re-read the object or poll process_id. Do not replay a whole partial batch."
        return result
    }
}
