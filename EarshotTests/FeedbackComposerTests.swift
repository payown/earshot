import XCTest
@testable import Earshot

/// Unit tests for the pure Send Feedback construction logic (#392, PRD 12):
/// the anonymized system-info block, the mail body with/without system info, and
/// the percent-encoded `mailto:` fallback URL.
final class FeedbackComposerTests: XCTestCase {

    // MARK: systemInfoBlock

    func testSystemInfoBlockFormat() {
        let block = FeedbackComposer.systemInfoBlock(
            appVersion: "0.1.0",
            build: "113",
            iosVersion: "17.4",
            deviceModel: "iPhone16,2"
        )
        XCTAssertEqual(
            block,
            """
            ---
            System info (anonymized)
            App version: 0.1.0 (113)
            iOS: 17.4
            Device: iPhone16,2
            """
        )
    }

    func testSystemInfoBlockContainsNoPersonalData() {
        let block = FeedbackComposer.systemInfoBlock(
            appVersion: "1.0",
            build: "1",
            iosVersion: "18.0",
            deviceModel: "iPhone17,1"
        )
        // Only the four anonymized fields plus the header should be present.
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "---")
        XCTAssertEqual(lines[1], "System info (anonymized)")
        XCTAssertTrue(lines[2].hasPrefix("App version:"))
        XCTAssertTrue(lines[3].hasPrefix("iOS:"))
        XCTAssertTrue(lines[4].hasPrefix("Device:"))
    }

    // MARK: body

    func testBodyWithoutSystemInfoIsJustLeadIn() {
        let body = FeedbackComposer.body(systemInfo: nil)
        XCTAssertFalse(body.contains("System info"))
        XCTAssertTrue(body.contains("Tell us what's working"))
    }

    func testBodyWithEmptySystemInfoIsJustLeadIn() {
        let body = FeedbackComposer.body(systemInfo: "")
        XCTAssertFalse(body.contains("System info"))
    }

    func testBodyWithSystemInfoAppendsBlock() {
        let info = FeedbackComposer.systemInfoBlock(
            appVersion: "0.1.0",
            build: "113",
            iosVersion: "17.4",
            deviceModel: "iPhone16,2"
        )
        let body = FeedbackComposer.body(systemInfo: info)
        XCTAssertTrue(body.contains("Tell us what's working"))
        XCTAssertTrue(body.contains("System info (anonymized)"))
        XCTAssertTrue(body.contains("Device: iPhone16,2"))
        // The user's lead-in must come before the system block.
        let leadRange = try? XCTUnwrap(body.range(of: "Tell us what's working"))
        let infoRange = try? XCTUnwrap(body.range(of: "System info"))
        if let leadRange, let infoRange {
            XCTAssertTrue(leadRange.lowerBound < infoRange.lowerBound)
        }
    }

    // MARK: mailtoURL

    func testMailtoURLBasic() {
        let url = FeedbackComposer.mailtoURL(
            to: "michael@payown.media",
            subject: "Earshot feedback",
            body: "Hello"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "mailto:michael@payown.media?subject=Earshot%20feedback&body=Hello"
        )
    }

    func testMailtoURLEncodesNewlines() {
        let url = FeedbackComposer.mailtoURL(
            to: "michael@payown.media",
            subject: "Sub",
            body: "Line one\nLine two"
        )
        let string = url?.absoluteString ?? ""
        XCTAssertTrue(string.contains("Line%20one%0ALine%20two"))
    }

    func testMailtoURLEncodesQueryReservedCharacters() {
        let url = FeedbackComposer.mailtoURL(
            to: "michael@payown.media",
            subject: "a&b=c+d?e",
            body: "x"
        )
        let string = url?.absoluteString ?? ""
        // Reserved query chars must be percent-encoded, not left raw, so they
        // don't split the query into extra params.
        XCTAssertTrue(string.contains("subject=a%26b%3Dc%2Bd%3Fe"))
        XCTAssertFalse(string.contains("subject=a&b=c+d?e"))
    }

    func testMailtoURLEncodesSpecialCharacters() {
        let url = FeedbackComposer.mailtoURL(
            to: "michael@payown.media",
            subject: "100% sure: it's broken!",
            body: "café"
        )
        let string = url?.absoluteString ?? ""
        XCTAssertTrue(string.contains("100%25%20sure"))
        XCTAssertNotNil(url)
    }

    func testMailtoURLProducesParsableURL() {
        let url = FeedbackComposer.mailtoURL(
            to: FeedbackComposer.recipient,
            subject: FeedbackComposer.defaultSubject,
            body: FeedbackComposer.body(systemInfo: FeedbackComposer.systemInfoBlock(
                appVersion: "0.1.0",
                build: "113",
                iosVersion: "17.4",
                deviceModel: "iPhone16,2"
            ))
        )
        let parsed = try? XCTUnwrap(url)
        XCTAssertEqual(parsed?.scheme, "mailto")
    }
}
