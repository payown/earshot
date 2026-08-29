import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class FeedConditionalRefreshTests: XCTestCase {
    private let url = "https://example.com/feed.xml"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func service() -> FeedService {
        FeedService(client: HTTPClient(
            session: MockURLProtocol.makeSession(),
            retryPolicy: .immediate,
            sleep: { _ in }
        ))
    }

    private var validFeed: Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Show</title>
        <item><guid>one</guid><title>One</title>
        <enclosure url="https://example.com/one.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """.utf8)
    }

    func testConditionalRequestSendsETagAndLastModified() async throws {
        MockURLProtocol.setOutcomes([.response(statusCode: 304, data: Data())])
        let original = FeedHTTPValidators(
            etag: "\"abc\"",
            lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
            representationURL: nil
        )

        let result = try await service().refresh(FeedRefreshRequest(
            urlString: url,
            validators: original,
            trigger: .manualToolbar
        ))

        guard case .notModified = result else { return XCTFail("Expected 304 result") }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests[0].value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(
            MockURLProtocol.requests[0].value(forHTTPHeaderField: "If-Modified-Since"),
            "Wed, 21 Oct 2015 07:28:00 GMT"
        )
    }

    func testNotModifiedReturnsWithoutBodyOrParse() async throws {
        MockURLProtocol.setOutcomes([.response(statusCode: 304, data: Data("not xml".utf8))])

        let result = try await service().refresh(FeedRefreshRequest(
            urlString: url,
            validators: FeedHTTPValidators(etag: "\"abc\"", lastModified: nil, representationURL: nil),
            trigger: .foreground
        ))

        guard case let .notModified(validators) = result else {
            return XCTFail("Expected not modified")
        }
        XCTAssertEqual(validators?.etag, "\"abc\"")
    }

    func testModifiedResponseReturnsReplacementValidators() async throws {
        MockURLProtocol.setOutcomes([.responseWithHeaders(
            statusCode: 200,
            data: validFeed,
            headers: [
                "ETag": "\"new\"",
                "Last-Modified": "Thu, 22 Oct 2015 07:28:00 GMT",
            ]
        )])

        let result = try await service().refresh(FeedRefreshRequest(
            urlString: url,
            validators: FeedHTTPValidators(etag: "\"old\"", lastModified: nil, representationURL: nil),
            trigger: .manualPullToRefresh
        ))

        guard case let .modified(parsed, validators) = result else {
            return XCTFail("Expected modified")
        }
        XCTAssertEqual(parsed.title, "Show")
        XCTAssertEqual(validators?.etag, "\"new\"")
        XCTAssertEqual(validators?.lastModified, "Thu, 22 Oct 2015 07:28:00 GMT")
    }

    func testMissingModifiedResponseValidatorsClearStaleValues() async throws {
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: validFeed)])
        let result = try await service().refresh(FeedRefreshRequest(
            urlString: url,
            validators: FeedHTTPValidators(etag: "\"old\"", lastModified: "yesterday", representationURL: nil),
            trigger: .foreground
        ))
        guard case let .modified(_, validators) = result else {
            return XCTFail("Expected modified")
        }
        XCTAssertNil(validators)
    }

    func testPreconditionFailureRetriesUnconditionallyOnce() async throws {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 412, data: Data()),
            .responseWithHeaders(statusCode: 200, data: validFeed, headers: ["ETag": "\"replacement\""]),
        ])

        let result = try await service().refresh(FeedRefreshRequest(
            urlString: url,
            validators: FeedHTTPValidators(etag: "\"stale\"", lastModified: nil, representationURL: nil),
            trigger: .backgroundTask
        ))

        guard case let .modified(_, validators) = result else {
            return XCTFail("Expected recovered modified result")
        }
        XCTAssertEqual(validators?.etag, "\"replacement\"")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(MockURLProtocol.requests[0].value(forHTTPHeaderField: "If-None-Match"), "\"stale\"")
        XCTAssertNil(MockURLProtocol.requests[1].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testBackgroundRefreshDoesNotUseGenericBackoffRetries() async {
        MockURLProtocol.setOutcomes([.response(statusCode: 503, data: Data())])
        do {
            _ = try await service().refresh(FeedRefreshRequest(
                urlString: url, validators: nil, trigger: .backgroundTask
            ))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(MockURLProtocol.requests.count, 1)
        }
    }

    func testManualRefreshRetainsTransientRetryPolicy() async throws {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 503, data: Data()),
            .response(statusCode: 200, data: validFeed),
        ])
        _ = try await service().refresh(FeedRefreshRequest(
            urlString: url, validators: nil, trigger: .manualToolbar
        ))
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testNon304Non2xxStillThrows() async {
        MockURLProtocol.setOutcomes([.response(statusCode: 404, data: Data())])
        do {
            _ = try await service().refresh(FeedRefreshRequest(
                urlString: url, validators: nil, trigger: .manualToolbar
            ))
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(MockURLProtocol.requests.count, 1)
        }
    }

    func testValidatorEnvelopeRoundTripsLocallyAndMalformedFallsBack() throws {
        let context = TestStore.freshContext()
        let validators = FeedHTTPValidators(
            etag: "\"roundtrip\"",
            lastModified: "today",
            representationURL: "https://cdn.example.com/feed.xml"
        )
        try FeedRefreshValidatorStore.set(validators, feedURL: "HTTPS://Example.com/feed.xml ", in: context)
        try context.save()

        XCTAssertEqual(
            FeedRefreshValidatorStore.validators(feedURL: url, in: context),
            validators
        )

        try LocalAppSettingIdentity.setValue(
            "not-json",
            for: FeedRefreshValidatorStore.key(feedURL: url),
            in: context
        )
        XCTAssertNil(FeedRefreshValidatorStore.validators(feedURL: url, in: context))
    }

    func testValidatorKeyUsesCanonicalSubscriptionIdentity() {
        XCTAssertEqual(
            FeedRefreshValidatorStore.key(feedURL: " HTTPS://EXAMPLE.COM/feed.xml "),
            FeedRefreshValidatorStore.key(feedURL: "https://example.com/feed.xml")
        )
    }
}
