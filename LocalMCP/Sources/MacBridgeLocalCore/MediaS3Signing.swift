import CryptoKit
import Foundation

/// AWS SigV4 using system CryptoKit. No SDK, shell, clock cache or network.
/// Generic internals allow published AWS test vectors; runtime paths are R2-bound.
enum MediaS3Signing {
    static let emptySHA256 = LocalHash.sha256(Data())

    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        text.utf8.map { b in
            if (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b)
                || [45, 46, 95, 126].contains(b) || (keepSlash && b == 47) {
                return String(UnicodeScalar(b))
            }
            return String(format: "%%%02X", b)
        }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private static func signature(canonical: String, time: String, region: String, secret: String) -> String {
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
        }
        let day = String(time.prefix(8))
        let scope = day + "/" + region + "/s3/aws4_request"
        let key = hmac(hmac(hmac(hmac(Data(("AWS4" + secret).utf8), day), region), "s3"), "aws4_request")
        return hmac(key, "AWS4-HMAC-SHA256\n" + time + "\n" + scope + "\n" + LocalHash.sha256(Data(canonical.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func presignedGET(host: String, path: String, access: String, secret: String,
                             region: String = "auto", issued: Date, seconds: Int) -> URL {
        let time = timestamp(issued)
        let scope = String(time.prefix(8)) + "/" + region + "/s3/aws4_request"
        let values = ["X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": access + "/" + scope,
                      "X-Amz-Date": time, "X-Amz-Expires": String(seconds), "X-Amz-SignedHeaders": "host"]
        let query = values.keys.sorted().map { encode($0) + "=" + encode(values[$0]!) }.joined(separator: "&")
        let canonical = "GET\n" + encode(path, keepSlash: true) + "\n" + query + "\nhost:" + host
            + "\n\nhost\nUNSIGNED-PAYLOAD"
        let sig = signature(canonical: canonical, time: time, region: region, secret: secret)
        return URL(string: "https://" + host + encode(path, keepSlash: true) + "?" + query + "&X-Amz-Signature=" + sig)!
    }

    static func signedRequest(method: String, host: String, path: String, access: String, secret: String,
                              region: String = "auto", date: Date, payloadSHA256: String = emptySHA256,
                              headers extra: [String: String] = [:]) -> URLRequest {
        let time = timestamp(date)
        var headers = extra
        headers["host"] = host
        headers["x-amz-content-sha256"] = payloadSHA256
        headers["x-amz-date"] = time
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map {
            $0 + ":" + headers[$0]!.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + "\n"
        }.joined()
        let signed = names.joined(separator: ";")
        let canonical = method + "\n" + encode(path, keepSlash: true) + "\n\n" + canonicalHeaders
            + "\n" + signed + "\n" + payloadSHA256
        let sig = signature(canonical: canonical, time: time, region: region, secret: secret)
        let scope = String(time.prefix(8)) + "/" + region + "/s3/aws4_request"
        var request = URLRequest(url: URL(string: "https://" + host + encode(path, keepSlash: true))!)
        request.httpMethod = method
        headers["authorization"] = "AWS4-HMAC-SHA256 Credential=" + access + "/" + scope
            + ",SignedHeaders=" + signed + ",Signature=" + sig
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}
