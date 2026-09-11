import Foundation
import XCTest
@testable import MacBridgeLocalCore

/// Delegate contracts only. Dummy URLSession tasks are never resumed.
final class MediaTransportTests: XCTestCase {
    func testRedirectIsNotFollowed() throws {
        let d = MediaShareTransport.Delegate(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/fixture")!
        let task = session.dataTask(with: url)
        let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil,
            headerFields: ["Location": "https://other.invalid/"])!
        var completed = false
        d.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                     newRequest: URLRequest(url: URL(string: "https://other.invalid/")!)) { request in
            XCTAssertNil(request); completed = true
        }
        XCTAssertTrue(completed)
    }
    func testResponseDoesNotKeepProviderSecretsOrUnboundedHeaders() throws {
        let d = MediaShareTransport.Delegate(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/fixture")!, task = session.dataTask(with: URL(string: "https://example.invalid/fixture")!)
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil,
            headerFields: ["Content-Length": "12", "Location": "https://secret.invalid", "Set-Cookie": "secret",
                           "ETag": String(repeating: "x", count: 257)])!
        d.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        d.urlSession(session, dataTask: task, didReceive: Data("private-body".utf8))
        d.urlSession(session, task: task, didCompleteWithError: nil)
        let result = try d.result()
        XCTAssertEqual(result.status, 403); XCTAssertEqual(result.headers, ["content-length": "12"])
    }
    func testOversizedResponseCancelsInsteadOfRetainingBody() {
        let d = MediaShareTransport.Delegate(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/fixture")!, task = session.dataTask(with: URL(string: "https://example.invalid/fixture")!)
        d.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 500,
            httpVersion: nil, headerFields: ["Content-Length": "16385"])!) { XCTAssertEqual($0, .cancel) }
        XCTAssertThrowsError(try d.result())
    }
    func testChunkedBodyLimitAlsoFailsClosed() {
        let d = MediaShareTransport.Delegate(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/fixture")!, task = session.dataTask(with: URL(string: "https://example.invalid/fixture")!)
        d.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: [:])!) { XCTAssertEqual($0, .allow) }
        d.urlSession(session, dataTask: task, didReceive: Data(repeating: 1, count: 16_385))
        XCTAssertThrowsError(try d.result())
    }
    func testHEADMayDescribeLargeMediaWithoutReadingBody() throws {
        let d = MediaShareTransport.Delegate(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/fixture")!
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let task = session.dataTask(with: request)
        d.urlSession(session, dataTask: task, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": "67108864"])!) { XCTAssertEqual($0, .allow) }
        d.urlSession(session, task: task, didCompleteWithError: nil)
        XCTAssertEqual(try d.result().headers["content-length"], "67108864")
    }
    func testTransportErrorDoesNotExposeRequestOrProviderText() {
        let d = MediaShareTransport.Delegate(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid/fixture")!)
        d.urlSession(session, task: task, didCompleteWithError: NSError(domain: "private-provider-sentinel", code: 1))
        XCTAssertThrowsError(try d.result()) { XCTAssertFalse(String(describing: $0).contains("private-provider-sentinel")) }
    }
}
