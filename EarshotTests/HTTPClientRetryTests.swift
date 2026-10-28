import XCTest
@testable import Earshot

final class NetworkLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) { lock.withLock { storage.append(message) } }
    var messages: [String] { lock.withLock { storage } }
}

/// Tests the ``HTTPClient`` retry loop end to end through ``MockURLProtocol``.
/// A zero-delay ``RetryPolicy`` (`.immediate`) keeps the suite fast.
final class HTTPClientRetryTests: XCTestCase {

    private let url = URL(string: "https://example.com/feed.xml")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A configured `HTTPClient` whose backoff never actually sleeps, even if a
    /// non-zero policy is supplied.
    private func makeClient(policy: RetryPolicy = .immediate) -> HTTPClient {
        HTTPClient(
            session: MockURLProtocol.makeSession(),
            retryPolicy: policy,
            sleep: { _ in }
        )
    }

    // MARK: Retry succeeds

    func test_5xxThen200_succeedsAfterRetry() async throws {
        let body = Data("<rss/>".utf8)
        MockURLProtocol.setOutcomes([
            .response(statusCode: 503, data: Data()),
            .response(statusCode: 200, data: body),
        ])

        let data = try await makeClient().data(from: url)
        XCTAssertEqual(data, body)
    }

    func test_timedOutThen200_succeedsAfterRetry() async throws {
        let body = Data("ok".utf8)
        MockURLProtocol.setOutcomes([
            .failure(URLError(.timedOut)),
            .response(statusCode: 200, data: body),
        ])

        let data = try await makeClient().data(from: url)
        XCTAssertEqual(data, body)
    }

    func test_networkConnectionLostThen200_succeedsAfterRetry() async throws {
        let body = Data("ok".utf8)
        MockURLProtocol.setOutcomes([
            .failure(URLError(.networkConnectionLost)),
            .response(statusCode: 200, data: body),
        ])

        let data = try await makeClient().data(from: url)
        XCTAssertEqual(data, body)
    }

    // MARK: Non-transient fails fast

    func test_4xx_doesNotRetry_andFailsFast() async {
        // Only one outcome queued: if the client retried it would consume a
        // second (missing) outcome and surface a different error.
        MockURLProtocol.setOutcomes([
            .response(statusCode: 404, data: Data()),
        ])

        do {
            _ = try await makeClient().data(from: url)
            XCTFail("Expected a 404 to throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .server(status: 404))
        } catch {
            XCTFail("Expected HTTPError.server, got \(error)")
        }
    }

    // MARK: Exhaustion

    func test_persistent5xx_exhaustsRetries_andSurfacesServerError() async {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 500, data: Data()),
            .response(statusCode: 500, data: Data()),
            .response(statusCode: 500, data: Data()),
        ])

        do {
            _ = try await makeClient().data(from: url)
            XCTFail("Expected exhausted retries to throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .server(status: 500))
        } catch {
            XCTFail("Expected HTTPError.server, got \(error)")
        }
    }

    func test_persistentTimeout_exhaustsRetries_andSurfacesTransport() async {
        MockURLProtocol.setOutcomes([
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
        ])

        do {
            _ = try await makeClient().data(from: url)
            XCTFail("Expected exhausted retries to throw")
        } catch let error as HTTPError {
            guard case .transport = error else {
                return XCTFail("Expected HTTPError.transport, got \(error)")
            }
        } catch {
            XCTFail("Expected HTTPError, got \(error)")
        }
    }

    func test_maxAttemptsOne_5xx_doesNotRetry() async {
        // A single-attempt policy must not retry even a transient 5xx: only one
        // outcome is queued, so a retry would surface a different error.
        let client = makeClient(policy: RetryPolicy(maxAttempts: 1, backoff: [0]))
        MockURLProtocol.setOutcomes([
            .response(statusCode: 500, data: Data()),
        ])

        do {
            _ = try await client.data(from: url)
            XCTFail("Expected a 500 to throw")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .server(status: 500))
        } catch {
            XCTFail("Expected HTTPError.server, got \(error)")
        }
    }

    // MARK: Bad URL never reaches the network

    func test_badURL_throwsImmediately() async {
        do {
            _ = try await makeClient().data(from: "not a url")
            XCTFail("Expected badURL")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .badURL)
        } catch {
            XCTFail("Expected HTTPError.badURL, got \(error)")
        }
    }

    func testRetryAndTransportDiagnosticsOmitURLsAndErrorText() async throws {
        let capture = NetworkLogCapture()
        let secretURL = try XCTUnwrap(URL(string: "https://user:password@private.example/signed-path-token?access_token=query-secret"))
        let error = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "transport-secret \(secretURL.absoluteString)"])
        MockURLProtocol.setOutcomes([.failure(error), .failure(error), .failure(error)])
        let client = HTTPClient(session: MockURLProtocol.makeSession(), retryPolicy: .immediate,
                                sleep: { _ in }, log: { _, message in capture.append(message) })
        do {
            _ = try await client.data(from: secretURL)
            XCTFail("Expected the transport request to fail")
        } catch { }
        XCTAssertEqual(capture.messages, [
            "Retrying HTTPS request after attempt 1: URL error -1001",
            "Retrying HTTPS request after attempt 2: URL error -1001",
            "Transport error for HTTPS request: URL error -1001"
        ])
        for message in capture.messages {
            XCTAssertFalse(message.contains("private.example"))
            XCTAssertFalse(message.contains("signed-path-token"))
            XCTAssertFalse(message.contains("query-secret"))
            XCTAssertFalse(message.contains("transport-secret"))
            XCTAssertFalse(message.contains(secretURL.absoluteString))
        }
    }

    func testHTTPStatusAndRetryDiagnosticsOmitSignedURL() async throws {
        let capture = NetworkLogCapture()
        let secretURL = try XCTUnwrap(URL(string: "https://private.example/signed-path-token?access_token=query-secret"))
        MockURLProtocol.setOutcomes([.response(statusCode: 503, data: Data()),
                                     .response(statusCode: 200, data: Data("ok".utf8))])
        let client = HTTPClient(session: MockURLProtocol.makeSession(), retryPolicy: .immediate,
                                sleep: { _ in }, log: { _, message in capture.append(message) })
        _ = try await client.data(from: secretURL)
        XCTAssertEqual(capture.messages, ["HTTP 503 for HTTPS request",
                                          "Retrying HTTPS request after attempt 1: HTTP status 503"])
        XCTAssertFalse(capture.messages.joined().contains("signed-path-token"))
        XCTAssertFalse(capture.messages.joined().contains("query-secret"))
        XCTAssertFalse(capture.messages.joined().contains(secretURL.absoluteString))
    }

    func testWrappedAndUnknownErrorDiagnosticsNeverExposeFreeFormText() {
        let secret = "https://private.example/signed-path?token=query-secret"
        XCTAssertEqual(NetworkDiagnostic.reason(HTTPError.transport(secret)), "transport error")
        XCTAssertEqual(NetworkDiagnostic.reason(FeedError.network(secret)), "other error")
        XCTAssertEqual(NetworkDiagnostic.reason(TranscriptError.network(secret)), "other error")
        let custom = NSError(domain: secret, code: 55, userInfo: [NSLocalizedDescriptionKey: secret])
        XCTAssertEqual(NetworkDiagnostic.reason(custom), "other error")
    }

    func testDownloadDiagnosticsNeverExposeSourceOrServerContentType() throws {
        let url = try XCTUnwrap(URL(string: "https://private.example/signed-token.mp3?token=query-secret"))
        let dangerousType = "text/html; token=header-secret; url=\(url.absoluteString)"
        let rejected = NetworkDiagnostic.downloadRejection(url: url, status: 403,
                                                            contentType: dangerousType, byteCount: 19)
        XCTAssertEqual(rejected, "Download rejected for HTTPS request: HTTP 403, content category non-media, bytes 19")
        let error = NSError(domain: NSCocoaErrorDomain, code: 513,
                            userInfo: [NSLocalizedDescriptionKey: "move-secret \(url.absoluteString)"])
        let moveFailed = NetworkDiagnostic.downloadMoveFailure(url: url, error: error)
        XCTAssertEqual(moveFailed, "Download file move failed for HTTPS request: Cocoa error 513")
        for message in [rejected, moveFailed] {
            for secret in ["private.example", "signed-token", "query-secret", "header-secret", "move-secret", url.absoluteString] {
                XCTAssertFalse(message.contains(secret))
            }
        }
        XCTAssertTrue(NetworkDiagnostic.downloadRejection(url: url, status: 200,
                                                           contentType: "audio/mpeg", byteCount: 0).contains("content category audio"))
        XCTAssertTrue(NetworkDiagnostic.downloadRejection(url: url, status: 200,
                                                           contentType: "custom-secret", byteCount: 0).contains("content category other"))
        XCTAssertTrue(NetworkDiagnostic.downloadRejection(url: url, status: 200,
                                                           contentType: "", byteCount: 0).contains("content category missing"))
    }
}
