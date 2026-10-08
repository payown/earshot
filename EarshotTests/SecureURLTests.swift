import XCTest
@testable import Earshot

/// Verifies the opportunistic HTTPS upgrade applied to non-media fetches under
/// the media-only ATS policy (#387, ADR 001).
final class SecureURLTests: XCTestCase {
    private func upgraded(_ string: String) -> String? {
        guard let url = URL(string: string) else { return nil }
        return SecureURL.upgradedForNonMedia(url).absoluteString
    }

    func testHTTPUpgradedToHTTPS() {
        XCTAssertEqual(upgraded("http://example.com/feed.xml"), "https://example.com/feed.xml")
    }

    func testHTTPSLeftUnchanged() {
        XCTAssertEqual(upgraded("https://example.com/feed.xml"), "https://example.com/feed.xml")
    }

    func testPathQueryAndFragmentPreserved() {
        XCTAssertEqual(
            upgraded("http://host.example/a/b.mp3?x=1&y=2#z"),
            "https://host.example/a/b.mp3?x=1&y=2#z"
        )
    }

    func testExplicitPort80Dropped() {
        XCTAssertEqual(upgraded("http://host.example:80/f.xml"), "https://host.example/f.xml")
    }

    func testNonDefaultPortPreserved() {
        XCTAssertEqual(upgraded("http://host.example:8080/f.xml"), "https://host.example:8080/f.xml")
    }

    func testFileSchemeUnchanged() {
        XCTAssertEqual(upgraded("file:///tmp/x.mp3"), "file:///tmp/x.mp3")
    }

    func testUppercaseSchemeUpgraded() {
        XCTAssertEqual(upgraded("HTTP://host.example/f"), "https://host.example/f")
    }

    func testBBCMediaSelectorUsesHTTPSVariantWithoutLosingQuery() throws {
        let source = try XCTUnwrap(URL(string:
            "http://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/audio/proto/http/vpid/p0p9r146.mp3?foo=bar"
        ))
        XCTAssertEqual(
            SecureURL.preferredMediaHTTPS(source).absoluteString,
            "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/audio/proto/https/vpid/p0p9r146.mp3?foo=bar"
        )
    }

    func testBBCSelectorRewriteIsLimitedToExactHostAndPath() throws {
        for string in [
            "http://other.example/audio/proto/http/episode.mp3",
            "http://open.live.bbc.co.uk.evil.example/audio/proto/http/episode.mp3",
            "http://open.live.bbc.co.uk/audio/proto/httpish/episode.mp3",
        ] {
            let source = try XCTUnwrap(URL(string: string))
            XCTAssertEqual(
                SecureURL.preferredMediaHTTPS(source),
                SecureURL.upgradedForNonMedia(source)
            )
        }
    }
}
