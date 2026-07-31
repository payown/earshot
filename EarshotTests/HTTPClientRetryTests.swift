import XCTest
@testable import Earshot

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
}
