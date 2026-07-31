import XCTest
@testable import Earshot

/// Tests ``TranscriptService/load(from:)`` end to end through ``MockURLProtocol``
/// (#451). Format is resolved from the URL extension (the mock sends no
/// `Content-Type` header), so a `.vtt` URL exercises the real WebVTT parse path.
/// Every expected failure surfaces as a typed ``TranscriptError`` — never a throw.
final class TranscriptServiceTests: XCTestCase {

    private let vttURL = "https://example.com/transcript.vtt"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A service whose HTTP client routes through the mock protocol and never sleeps.
    private func makeService(maxBytes: Int = 5_000_000) -> TranscriptService {
        let http = HTTPClient(
            session: MockURLProtocol.makeSession(),
            retryPolicy: .immediate,
            sleep: { _ in }
        )
        return TranscriptService(http: http, maxBytes: maxBytes)
    }

    // MARK: Success

    func test_load_vttBody_parsesSegments() async {
        let body = Data("""
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        Hello world
        """.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let result = await makeService().load(from: vttURL)
        switch result {
        case .success(let segments):
            XCTAssertEqual(segments.map(\.text), ["Hello world"])
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    // MARK: Network failure

    func test_load_httpErrorResponse_returnsNetwork() async {
        // 404 is not retried, so a single outcome is enough.
        MockURLProtocol.setOutcomes([.response(statusCode: 404, data: Data())])

        let result = await makeService().load(from: vttURL)
        guard case .failure(.network) = result else {
            return XCTFail("Expected .network failure, got \(result)")
        }
    }

    // MARK: Empty body

    func test_load_emptyBody_returnsEmpty() async {
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: Data())])

        let result = await makeService().load(from: vttURL)
        XCTAssertEqual(result, .failure(.empty))
    }

    /// A well-formed fetch whose body parses to zero segments is also `.empty`.
    func test_load_bodyParsesToZeroSegments_returnsEmpty() async {
        // A VTT header with no cues yields no segments.
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: Data("WEBVTT\n\n".utf8))])

        let result = await makeService().load(from: vttURL)
        XCTAssertEqual(result, .failure(.empty))
    }

    // MARK: Invalid URL (never reaches the network)

    func test_load_nonHTTPScheme_returnsInvalidURL() async {
        let result = await makeService().load(from: "ftp://example.com/t.vtt")
        XCTAssertEqual(result, .failure(.invalidURL))
        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    // MARK: Size cap

    func test_load_bodyOverMaxBytes_returnsTooLarge() async {
        let big = Data(count: 100)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: big)])

        let result = await makeService(maxBytes: 10).load(from: vttURL)
        XCTAssertEqual(result, .failure(.tooLarge(bytes: 100)))
    }
}
