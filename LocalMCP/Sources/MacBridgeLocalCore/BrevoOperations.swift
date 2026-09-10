import Darwin
import CoreFoundation
import Foundation

/// Owner-bound Brevo transport and compatibility reads.
/// Domain action builders, never caller-controlled HTTP routes, use this transport.
enum BrevoOperations {
    // Internal dependency injection for offline tests; never exposed in MCP arguments.
    typealias Transport = (String, String, [URLQueryItem], JSONObject?, Bool) throws -> JSONObject
    private static let baseURL = URL(string: "https://api.brevo.com/v3/")!
    // Used only with the internal injected transport, never with a live key.
    static let fixtureAccount = "account@example.invalid"
    struct Session {
        let perform: Transport
        let expectedAccountEmail: String
    }
    private static let maximumResponseBytes = 5 * 1_024 * 1_024
    private static let maximumBodyBytes = 262_144

    final class ResponseBox: @unchecked Sendable {
        let lock = NSLock()
        var data: Data?
        var response: URLResponse?
        var error: Error?

        func set(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            self.data = data
            self.response = response
            self.error = error
            lock.unlock()
        }

        func snapshot() -> (Data?, URLResponse?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (data, response, error)
        }

        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard chunk.count <= maximumResponseBytes - (data?.count ?? 0) else { return false }
            if data == nil { data = Data() }
            data?.append(chunk)
            return true
        }

        func complete(_ failure: Error?) {
            lock.lock(); defer { lock.unlock() }
            error = failure
        }
    }

    final class NoRedirectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let box = ResponseBox()
        let finished = DispatchSemaphore(value: 0)

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            box.set(data: Data(), response: response, error: nil)
            completionHandler(response.expectedContentLength > maximumResponseBytes ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if !box.append(data) { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            box.complete(error)
            finished.signal()
        }
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static func makeSession(delegate: NoRedirectDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func executeRead(_ a: JSONObject, transport: Transport? = nil) throws -> JSONObject {
        try a.requireOnlyKeys([
            "action", "campaign_id", "type", "status", "statistics", "start_date",
            "end_date", "limit", "offset", "sort", "include_html_content", "ip", "domain",
        ])
        let action = try a.requiredString("action", maximumBytes: 32)
        guard ["account", "campaigns", "campaign", "senders", "lists"].contains(action) else {
            throw LocalMCPError.invalidRequest("Unknown brevo_read action")
        }
        _ = try BrevoSafety.dates(a)
        if a["include_html_content"] != nil { _ = try a.optionalBool("include_html_content", default: false) }
        if action == "campaign" { _ = try positiveCampaignID(a) }
        let session = try boundSession(transport)
        let perform = session.perform
        let account = try BrevoSafety.verifyAccount(perform, expectedAccountEmail: session.expectedAccountEmail)
        func read(_ path: String, _ query: [URLQueryItem] = []) throws -> JSONObject {
            try BrevoSafety.result(perform("GET", path, query, nil, false), includeContent: a["include_html_content"] as? Bool == true)
        }
        switch action {
        case "account":
            return account
        case "campaigns":
            let limit = try a.optionalInt("limit", default: 100, range: 1...100)
            let offset = try a.optionalInt("offset", default: 0, range: 0...Int.max)
            let start = try a.optionalString("start_date", maximumBytes: 64)
            let end = try a.optionalString("end_date", maximumBytes: 64)
            if (start == nil) != (end == nil) {
                throw LocalMCPError.invalidRequest("start_date and end_date must be supplied together")
            }
            var query = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "excludeHtmlContent", value: "true"),
            ]
            appendQuery(&query, "type", try a.optionalString("type", maximumBytes: 16))
            appendQuery(&query, "status", try a.optionalString("status", maximumBytes: 32))
            appendQuery(&query, "statistics", try a.optionalString("statistics", maximumBytes: 32))
            appendQuery(&query, "startDate", start)
            appendQuery(&query, "endDate", end)
            appendQuery(&query, "sort", try a.optionalString("sort", maximumBytes: 8))
            return try BrevoSafety.page(read("emailCampaigns", query), key: "campaigns", limit: limit, offset: offset)
        case "campaign":
            let id = try positiveCampaignID(a)
            var query: [URLQueryItem] = []
            appendQuery(&query, "statistics", try a.optionalString("statistics", maximumBytes: 32))
            if !(try a.optionalBool("include_html_content", default: false)) {
                query.append(URLQueryItem(name: "excludeHtmlContent", value: "true"))
            }
            return try read("emailCampaigns/\(id)", query)
        case "senders":
            var query: [URLQueryItem] = []
            appendQuery(&query, "ip", try a.optionalString("ip", maximumBytes: 128))
            appendQuery(&query, "domain", try a.optionalString("domain", maximumBytes: 255))
            return try read("senders", query)
        case "lists":
            let limit = try a.optionalInt("limit", default: 50, range: 1...50)
            let offset = try a.optionalInt("offset", default: 0, range: 0...Int.max)
            var query = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            appendQuery(&query, "sort", try a.optionalString("sort", maximumBytes: 8))
            return try BrevoSafety.page(read("contacts/lists", query), key: "lists", limit: limit, offset: offset)
        default:
            throw LocalMCPError.invalidRequest("Unknown brevo_read action")
        }
    }

    static func executeCampaign(_ a: JSONObject, transport: Transport? = nil) throws -> JSONObject {
        try BrevoCampaignActions.execute(a, transport: transport)
    }

    static func accountProjection(_ raw: JSONObject) throws -> JSONObject {
        guard let email = raw["email"] as? String else {
            throw LocalMCPError.operationFailed("Brevo returned an unexpected account response")
        }
        var result: JSONObject = ["email": email]
        for key in ["organization_id", "user_id", "companyName", "plan", "planVerticals", "enterprise"] {
            if let value = raw[key] { result[key] = sanitize(value, secret: "") }
        }
        result["reset_date_note"] = "Plan start/end dates are returned as provided; they are not a guaranteed next credit reset."
        // Preserve only feature booleans, never relay passwords or tracker keys.
        result["transactional_enabled"] = raw["relay_enabled"] ?? (raw["relay"] as? JSONObject)?["enabled"]
        result["automation_enabled"] = raw["automation_enabled"] ?? (raw["marketingAutomation"] as? JSONObject)?["enabled"]
        return result
    }

    static func boundSession(_ injected: Transport? = nil) throws -> Session {
        if let injected { return Session(perform: injected, expectedAccountEmail: fixtureAccount) }
        let configuration = try BrevoConfiguration.load()
        return Session(perform: {
            try request(method: $0, path: $1, query: $2, body: $3, isWrite: $4, apiKey: configuration.apiKey)
        }, expectedAccountEmail: configuration.accountEmail)
    }

    private static func request(
        method: String, path: String, query: [URLQueryItem], body: JSONObject?, isWrite: Bool,
        apiKey: String
    ) throws -> JSONObject {
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"), !path.contains("#") else {
            throw LocalMCPError.invalidRequest("Internal Brevo path refused")
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // The fixed route builder encodes every variable path component once.
        guard !path.contains("?"), path.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw LocalMCPError.invalidRequest("Internal Brevo path refused")
        }
        components.percentEncodedPath = "/v3/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, url.scheme == "https", url.host == "api.brevo.com" else {
            throw LocalMCPError.operationFailed("Brevo API origin validation failed")
        }
        let key = apiKey
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = isWrite ? 25 : 20
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoded = try LocalJSON.encode(body)
            guard encoded.count <= maximumBodyBytes else {
                throw LocalMCPError.limitExceeded("Brevo request body exceeds 256 KiB")
            }
            request.httpBody = encoded
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let delegate = NoRedirectDelegate()
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        let wait = delegate.finished.wait(timeout: .now() + (isWrite ? 30 : 25))
        if wait == .timedOut {
            task.cancel()
            if isWrite {
                throw LocalMCPError.operationFailed("WRITE_OUTCOME_UNKNOWN: Brevo write timed out; reconcile campaign state before any retry")
            }
            throw LocalMCPError.operationFailed("Brevo read timed out; no automatic retry was attempted")
        }
        let (dataValue, responseValue, errorValue) = delegate.box.snapshot()
        if errorValue != nil {
            if isWrite {
                throw LocalMCPError.operationFailed("WRITE_OUTCOME_UNKNOWN: Brevo write transport failed; reconcile campaign state before any retry")
            }
            throw LocalMCPError.operationFailed("Brevo read transport failed; no automatic retry was attempted")
        }
        guard let response = responseValue as? HTTPURLResponse else {
            throw LocalMCPError.operationFailed(isWrite
                ? "WRITE_OUTCOME_UNKNOWN: Brevo write returned no HTTP response; reconcile before retry"
                : "Brevo read returned no HTTP response")
        }
        return try decodeResponse(dataValue ?? Data(), status: response.statusCode, secret: key, isWrite: isWrite)
    }

    static func decodeResponse(_ data: Data, status: Int, secret: String, isWrite: Bool) throws -> JSONObject {
        guard data.count <= maximumResponseBytes else {
            throw LocalMCPError.limitExceeded(isWrite
                ? "WRITE_OUTCOME_UNKNOWN: oversized Brevo response; reconcile before retry"
                : "Brevo response exceeds 5 MiB")
        }

        var decoded: Any = [:]
        if !data.isEmpty {
            do { decoded = try JSONSerialization.jsonObject(with: data) }
            catch {
                throw LocalMCPError.operationFailed(isWrite
                    ? "WRITE_OUTCOME_UNKNOWN: Brevo write returned invalid JSON; reconcile before retry"
                    : "Brevo returned invalid JSON")
            }
        }
        let cleaned = sanitize(decoded, secret: secret)
        guard (200...299).contains(status) else {
            let detail = safeVendorError(cleaned)
            if isWrite && status >= 500 {
                throw LocalMCPError.operationFailed("WRITE_OUTCOME_UNKNOWN: Brevo HTTP \(status); reconcile before retry")
            }
            throw LocalMCPError.operationFailed("Brevo HTTP \(status): \(detail)\(isWrite ? "; no automatic retry" : "")")
        }
        if status == 204 || data.isEmpty {
            return ["http_status": status]
        }
        guard let object = cleaned as? JSONObject else {
            throw LocalMCPError.operationFailed(isWrite
                ? "WRITE_OUTCOME_UNKNOWN: unexpected Brevo response shape; reconcile before retry"
                : "Brevo returned an unexpected JSON shape")
        }
        var result = object
        result["http_status"] = status
        return result
    }

    static func sanitize(_ value: Any, secret: String) -> Any {
        if let string = value as? String {
            let cleaned = secret.isEmpty ? string : string.replacingOccurrences(of: secret, with: "[REDACTED]")
            return cleaned.replacingOccurrences(of: #"(?i)(xkeysib-[A-Za-z0-9_-]+|Bearer\s+[A-Za-z0-9._~+/-]+=*)"#, with: "[REDACTED]", options: .regularExpression)
        }
        if let array = value as? [Any] { return array.map { sanitize($0, secret: secret) } }
        if let object = value as? JSONObject {
            var result: JSONObject = [:]
            for (key, item) in object {
                let safeKey = secret.isEmpty ? key : key.replacingOccurrences(of: secret, with: "[REDACTED]")
                let lower = key.lowercased()
                if lower == "relay" || lower == "marketingautomation",
                   let enabled = (item as? JSONObject)?["enabled"] as? Bool {
                    result[lower == "relay" ? "relay_enabled" : "automation_enabled"] = enabled
                }
                if lower.contains("password") || lower.contains("secret") || lower.contains("token") ||
                   lower.contains("apikey") || lower.contains("api_key") || lower.contains("accesskey") ||
                   lower == "relay" || lower == "marketingautomation" || lower == "trackerkey" ||
                   lower == "auth" || lower == "authorization" || lower == "headers" ||
                   lower == "export_url" || lower == "download_url" ||
                   (["invalid_emails", "duplicate_contact_id", "duplicate_ext_id", "duplicate_email_id", "duplicate_phone_id", "duplicate_whatsapp_id", "duplicate_landline_number_id"].contains(lower) && item is String) {
                    result[safeKey] = "[REDACTED]"
                } else if lower == "url",
                          let url = item as? String, url.hasPrefix("https://"), let components = URLComponents(string: url) {
                    result[safeKey] = "[REDACTED: webhook path/query]"
                    result["target_origin"] = components.host.map { "https://" + $0 } ?? "[unavailable]"
                } else {
                    result[safeKey] = sanitize(item, secret: secret)
                }
            }
            return result
        }
        return value
    }

    private static func safeVendorError(_ value: Any) -> String {
        guard let object = value as? JSONObject else { return "No structured error" }
        let code = object["code"] as? String ?? "error"
        let message = object["message"] as? String ?? "Request rejected"
        return String("\(code): \(message)".prefix(700))
    }

    static func parseBodyJSON(_ text: String) throws -> JSONObject {
        guard let data = text.data(using: .utf8), data.count <= maximumBodyBytes else {
            throw LocalMCPError.limitExceeded("Brevo body_json exceeds 256 KiB")
        }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw LocalMCPError.invalidRequest("body_json must contain valid JSON") }
        guard let object = value as? JSONObject, !object.isEmpty else {
            throw LocalMCPError.invalidRequest("body_json must contain a non-empty JSON object")
        }
        return object
    }

    static func validateCampaignBody(_ body: JSONObject, creating: Bool) throws {
        // Do not delegate coercion of publication controls to the vendor.
        // Invalid types must fail before any account read or write is dispatched.
        if let raw = body["sendAtBestTime"] {
            guard let boolean = raw as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                throw LocalMCPError.invalidRequest("sendAtBestTime must be a boolean")
            }
        }
        for field in ["scheduledAt", "status"] where body[field] != nil {
            guard body[field] is String else {
                throw LocalMCPError.invalidRequest("\(field) must be a string")
            }
        }
        if creating {
            guard let name = body["name"] as? String, !name.isEmpty,
                  let sender = body["sender"] as? JSONObject else {
                throw LocalMCPError.invalidRequest("Campaign creation requires name and sender")
            }
            _ = name
            let sources = ["htmlContent", "htmlUrl", "templateId"].filter { body[$0] != nil }
            guard sources.count == 1 else {
                throw LocalMCPError.invalidRequest("Campaign creation requires exactly one content source")
            }
            if body["abTesting"] as? Bool != true {
                guard let subject = body["subject"] as? String, !subject.isEmpty else {
                    throw LocalMCPError.invalidRequest("Campaign creation requires subject when A/B is off")
                }
            }
            let senderFields = [sender["id"], sender["email"]].compactMap { $0 }
            guard senderFields.count == 1 else {
                throw LocalMCPError.invalidRequest("Sender requires exactly one of id or email")
            }
        }
        if let sender = body["sender"] as? JSONObject {
            let senderFields = [sender["id"], sender["email"]].compactMap { $0 }
            guard senderFields.count == 1 else {
                throw LocalMCPError.invalidRequest("Sender requires exactly one of id or email")
            }
        }
        if let scheduled = body["scheduledAt"] as? String {
            guard scheduled.hasSuffix("Z") || scheduled.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) != nil,
                  let date = ISO8601DateFormatter().date(from: scheduled), date > Date() else {
                throw LocalMCPError.invalidRequest("scheduledAt must be a future timezone-qualified date-time")
            }
        }
    }

    static func publicationRequested(_ body: JSONObject?) -> Bool {
        guard let body else { return false }
        return body["scheduledAt"] != nil || body["sendAtBestTime"] as? Bool == true || body["status"] != nil
    }

    static func positiveCampaignID(_ a: JSONObject) throws -> Int {
        let value = try a.optionalInt("campaign_id", default: 0, range: 0...Int.max)
        guard value > 0 else { throw LocalMCPError.invalidRequest("campaign_id must be a positive integer") }
        return value
    }

    static func validatedEmails(_ a: JSONObject) throws -> [String] {
        guard let values = a["email_to"] as? [String], !values.isEmpty, values.count <= 20 else {
            throw LocalMCPError.invalidRequest("email_to must contain 1-20 addresses")
        }
        for value in values {
            do { try BrevoSafety.email(value) }
            catch { throw LocalMCPError.invalidRequest("email_to contains an invalid address") }
        }
        guard Set(values.map { $0.lowercased() }).count == values.count else {
            throw LocalMCPError.invalidRequest("email_to contains duplicate recipients")
        }
        return values
    }

    private static func appendQuery(_ query: inout [URLQueryItem], _ name: String, _ value: String?) {
        if let value, !value.isEmpty { query.append(URLQueryItem(name: name, value: value)) }
    }
}
