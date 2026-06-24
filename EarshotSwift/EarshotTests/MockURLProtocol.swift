import Foundation
@testable import Earshot

/// A `URLProtocol` subclass that intercepts requests on a test `URLSession` so
/// networking tests never touch the real network.
///
/// Each instance pops the next queued outcome from ``MockURLProtocol/outcomes``
/// (first-in, first-out), which lets a single test script a sequence such as
/// "500 then 200" to exercise the retry loop. Outcomes are stored in a
/// `URLSessionConfiguration.protocolClasses` session built by
/// ``MockURLProtocol/makeSession()``.
///
/// Concurrency: the queue is guarded by a lock so it is safe to mutate from the
/// test and read from URLSession's delegate queue.
final class MockURLProtocol: URLProtocol {

    /// A scripted response for one intercepted request: either an HTTP status
    /// with a body, or a transport-level `URLError`.
    enum Outcome {
        case response(statusCode: Int, data: Data)
        case failure(URLError)
    }

    private static let lock = NSLock()
    private static var outcomes: [Outcome] = []
    private static var capturedRequests: [URLRequest] = []

    /// The URLs of every request intercepted since the last ``reset()``, in order.
    /// Lets a test assert how the service built its request (e.g. that a search
    /// term was confined to the `term` query item and could not inject extra
    /// parameters).
    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests.compactMap(\.url)
    }

    /// Replaces the queued outcomes. Call before issuing requests.
    static func setOutcomes(_ outcomes: [Outcome]) {
        lock.lock()
        defer { lock.unlock() }
        self.outcomes = outcomes
    }

    /// Clears any remaining queued outcomes (call in tearDown).
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        outcomes = []
        capturedRequests = []
    }

    private static func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
    }

    private static func nextOutcome() -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        guard !outcomes.isEmpty else { return nil }
        return outcomes.removeFirst()
    }

    /// A `URLSession` configured to route every request through this protocol,
    /// while keeping Earshot's real timeout configuration.
    static func makeSession() -> URLSession {
        let config = EarshotURLSession.makeConfiguration()
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        Self.record(request)

        guard let outcome = Self.nextOutcome() else {
            client.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        switch outcome {
        case .failure(let error):
            client.urlProtocol(self, didFailWithError: error)
        case .response(let statusCode, let data):
            let url = request.url ?? URL(string: "https://example.invalid")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
