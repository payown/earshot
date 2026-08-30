import XCTest
@testable import Earshot

final class PodcastDescriptionPresentationTests: XCTestCase {
    func testPresentationRejectsMissingOrWhitespaceOnlyDescriptions() {
        XCTAssertNil(PodcastDescriptionPresentation(title: "Show", descriptionHTML: nil))
        XCTAssertNil(PodcastDescriptionPresentation(title: "Show", descriptionHTML: "  \n "))
    }

    func testPresentationRetainsTitleAndFullHTML() throws {
        let html = "<p>First paragraph.</p><p>Second paragraph.</p>"
        let presentation = try XCTUnwrap(
            PodcastDescriptionPresentation(title: "Show", descriptionHTML: html)
        )

        XCTAssertEqual(presentation.title, "Show")
        XCTAssertEqual(presentation.descriptionHTML, html)
        XCTAssertEqual(
            EpisodeSummary.paragraphs(presentation.descriptionHTML),
            ["First paragraph.", "Second paragraph."]
        )
    }
}
