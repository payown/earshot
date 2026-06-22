import XCTest
@testable import Earshot

/// Pure unit tests for ``RetryPolicy``: the transient/non-transient
/// classification and the backoff schedule, with no networking involved.
final class RetryPolicyTests: XCTestCase {

    // MARK: Transient classification

    func test_isTransient_serverError5xx_isTransient() {
        XCTAssertTrue(RetryPolicy.isTransient(HTTPError.server(status: 500)))
        XCTAssertTrue(RetryPolicy.isTransient(HTTPError.server(status: 503)))
        XCTAssertTrue(RetryPolicy.isTransient(HTTPError.server(status: 599)))
    }

    func test_isTransient_clientError4xx_isNotTransient() {
        XCTAssertFalse(RetryPolicy.isTransient(HTTPError.server(status: 400)))
        XCTAssertFalse(RetryPolicy.isTransient(HTTPError.server(status: 404)))
        XCTAssertFalse(RetryPolicy.isTransient(HTTPError.server(status: 429)))
    }

    func test_isTransient_badURL_isNotTransient() {
        XCTAssertFalse(RetryPolicy.isTransient(HTTPError.badURL))
    }

    func test_isTransient_connectivityURLErrors_areTransient() {
        for code in RetryPolicy.transientURLErrorCodes {
            XCTAssertTrue(RetryPolicy.isTransient(URLError(code)),
                          "\(code) should be transient")
        }
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.timedOut)))
        XCTAssertTrue(RetryPolicy.isTransient(URLError(.networkConnectionLost)))
    }

    func test_isTransient_nonTransientURLErrors_areNotTransient() {
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.cancelled)))
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.badURL)))
        XCTAssertFalse(RetryPolicy.isTransient(URLError(.unsupportedURL)))
    }

    func test_isTransient_parseError_isNotTransient() {
        struct Decoding: Error {}
        XCTAssertFalse(RetryPolicy.isTransient(Decoding()))
        XCTAssertFalse(RetryPolicy.isTransient(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))))
    }

    func test_isTransient_transportError_isNotTransient() {
        // .transport carries no status/code; the fall-through branch must not
        // classify a bare transport message as retryable.
        XCTAssertFalse(RetryPolicy.isTransient(HTTPError.transport("connection reset")))
    }

    // MARK: Backoff schedule

    func test_delay_firstAttempt_hasNoDelay() {
        XCTAssertEqual(RetryPolicy.standard.delay(beforeAttempt: 1), 0)
    }

    func test_delay_followsSchedule() {
        let policy = RetryPolicy(maxAttempts: 3, backoff: [1, 2])
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 1, "1s before the 2nd attempt")
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 2, "2s before the 3rd attempt")
    }

    func test_delay_clampsToLastValueWhenScheduleShorter() {
        let policy = RetryPolicy(maxAttempts: 5, backoff: [1, 2])
        XCTAssertEqual(policy.delay(beforeAttempt: 4), 2)
        XCTAssertEqual(policy.delay(beforeAttempt: 5), 2)
    }

    // MARK: shouldRetry

    func test_shouldRetry_transientWithAttemptsLeft_isTrue() {
        XCTAssertTrue(RetryPolicy.standard.shouldRetry(HTTPError.server(status: 500), afterAttempt: 1))
        XCTAssertTrue(RetryPolicy.standard.shouldRetry(HTTPError.server(status: 500), afterAttempt: 2))
    }

    func test_shouldRetry_lastAttempt_isFalse() {
        XCTAssertFalse(RetryPolicy.standard.shouldRetry(HTTPError.server(status: 500), afterAttempt: 3))
    }

    func test_shouldRetry_nonTransient_isFalseEvenWithAttemptsLeft() {
        XCTAssertFalse(RetryPolicy.standard.shouldRetry(HTTPError.server(status: 404), afterAttempt: 1))
    }

    func test_shouldRetry_maxAttemptsOne_neverRetriesTransient() {
        // maxAttempts == 1 disables retrying entirely, even for a 5xx.
        let policy = RetryPolicy(maxAttempts: 1, backoff: [1, 2])
        XCTAssertFalse(policy.shouldRetry(HTTPError.server(status: 500), afterAttempt: 1))
    }
}
