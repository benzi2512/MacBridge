import Foundation

struct MediaHTTPReply {
    let status: Int
    let headers: [String: String]
}

/// One request with no application retry or redirect; no cookies, cache,
/// listener or shell. A network failure is not proof the provider did no work.
enum MediaShareTransport {
    typealias Perform = (URLRequest, URL?) throws -> MediaHTTPReply
    static func perform(_ request: URLRequest, file: URL?) throws -> MediaHTTPReply {
        let delegate = Delegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task: URLSessionTask
        if let file { task = session.uploadTask(with: request, fromFile: file) }
        else { task = session.dataTask(with: request) }
        task.resume()
        guard delegate.finished.wait(timeout: .now() + 125) == .success else {
            task.cancel()
            throw LocalMCPError.operationFailed("media transport timed out; do not replay an uncertain publication")
        }
        return try delegate.result()
    }

    final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var response: HTTPURLResponse?
        private var failed = false
        private var bodyBytes = 0

        func result() throws -> MediaHTTPReply {
            lock.lock(); defer { lock.unlock() }
            guard !failed, let response else {
                throw LocalMCPError.operationFailed("media transport failed; provider text and URLs are withheld")
            }
            var headers: [String: String] = [:]
            for key in ["Content-Length", "Content-Type", "x-amz-meta-sha256", "ETag"] {
                if let value = response.value(forHTTPHeaderField: key), value.utf8.count <= 256 {
                    headers[key.lowercased()] = value
                }
            }
            return MediaHTTPReply(status: response.statusCode, headers: headers)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            self.response = response as? HTTPURLResponse
            let oversized = dataTask.originalRequest?.httpMethod != "HEAD" && response.expectedContentLength > 16_384
            failed = failed || oversized
            lock.unlock()
            completionHandler(oversized ? .cancel : .allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            bodyBytes += data.count
            let oversized = bodyBytes > 16_384
            failed = failed || oversized
            lock.unlock()
            if oversized { dataTask.cancel() }
            // Do not retain/log provider error bodies: they may echo signatures.
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); failed = failed || error != nil; lock.unlock()
            finished.signal()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}
