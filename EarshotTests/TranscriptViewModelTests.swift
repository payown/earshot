import XCTest
@testable import Earshot

/// Tests ``TranscriptViewModel`` state transitions (#451): the nil/blank-URL
/// shortcut folds to `.failed(.empty)` without a network call, and a real fetch
/// (through ``MockURLProtocol``) drives `.loaded` / `.failed`.
@MainActor
final class TranscriptViewModelTests: XCTestCase {

    private let vttURL = "https://example.com/transcript.vtt"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeModel() -> TranscriptViewModel {
        let http = HTTPClient(
            session: MockURLProtocol.makeSession(),
            retryPolicy: .immediate,
            sleep: { _ in }
        )
        return TranscriptViewModel(service: TranscriptService(http: http))
    }

    func test_load_nilURL_failsEmptyWithoutNetworking() async {
        let model = makeModel()
        await model.load(urlString: nil)
        XCTAssertEqual(model.state, .failed(.empty))
        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    func test_load_blankURL_failsEmptyWithoutNetworking() async {
        let model = makeModel()
        await model.load(urlString: "   ")
        XCTAssertEqual(model.state, .failed(.empty))
        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    func test_load_validVTT_reachesLoaded() async {
        let body = Data("""
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        Hello world
        """.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let model = makeModel()
        await model.load(urlString: vttURL)
        XCTAssertEqual(model.state, .loaded([
            TranscriptSegment(speaker: nil, text: "Hello world", startSeconds: 0)
        ]))
    }

    func test_load_serverError_reachesFailed() async {
        MockURLProtocol.setOutcomes([.response(statusCode: 404, data: Data())])

        let model = makeModel()
        await model.load(urlString: vttURL)
        guard case .failed(.network) = model.state else {
            return XCTFail("Expected .failed(.network), got \(model.state)")
        }
    }
}
