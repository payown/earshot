import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Earshot

@MainActor
final class EpisodeShareItemsTests: XCTestCase {
    func testShortcutReceivesOneURLWithoutTitleText() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/episode.mp3"))
        let items = EpisodeShareItems.make(title: "Episode title", audioURL: url.absoluteString)
        XCTAssertEqual(items.count, 1)
        let source = try XCTUnwrap(items.first as? UIActivityItemSource)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        XCTAssertEqual(source.activityViewControllerPlaceholderItem(controller) as? URL, url)
        XCTAssertEqual(source.activityViewController(controller, itemForActivityType: nil) as? URL, url)
        XCTAssertEqual(source.activityViewController?(controller, dataTypeIdentifierForActivityType: nil), UTType.url.identifier)
    }

    func testTitleRemainsInPreviewAndMailSubjectButNotInCopiedLink() throws {
        let items = EpisodeShareItems.make(title: "An episode title", audioURL: "https://example.com/audio.mp3")
        let source = try XCTUnwrap(items.first as? EpisodeLinkShareItem)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let metadata = try XCTUnwrap(source.activityViewControllerLinkMetadata(controller))
        XCTAssertEqual(metadata.title, "An episode title")
        XCTAssertEqual(metadata.url?.absoluteString, "https://example.com/audio.mp3")
        XCTAssertEqual(metadata.originalURL, metadata.url)
        XCTAssertEqual(source.activityViewController(controller, subjectForActivityType: .mail), "An episode title")
        for activity in [UIActivity.ActivityType.copyToPasteboard, .message, .mail,
                         UIActivity.ActivityType(rawValue: "com.apple.shortcuts.RunShortcut")] {
            XCTAssertEqual((source.activityViewController(controller, itemForActivityType: activity) as? URL)?.absoluteString,
                           "https://example.com/audio.mp3")
        }
    }

    func testURLLookingTitleCannotBecomeAnotherURLInput() throws {
        let items = EpisodeShareItems.make(title: "https://example.com/wrong", audioURL: "https://example.com/right.mp3")
        XCTAssertEqual(items.count, 1)
        let source = try XCTUnwrap(items.first as? EpisodeLinkShareItem)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        XCTAssertEqual((source.activityViewController(controller, itemForActivityType: nil) as? URL)?.absoluteString,
                       "https://example.com/right.mp3")
    }

    func testPreservesHTTPAndSignedQueryWithoutRewritingTheMediaURL() throws {
        for value in ["http://example.com/episode.mp3", "https://example.com/play?token=a%2Bb&episode=12#part"] {
            let items = EpisodeShareItems.make(title: "Episode", audioURL: "  \(value)\n")
            let source = try XCTUnwrap(items.first as? EpisodeLinkShareItem)
            let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
            XCTAssertEqual((source.activityViewController(controller, itemForActivityType: nil) as? URL)?.absoluteString, value)
        }
    }

    func testInvalidOrNonWebAudioURLFallsBackToTitleOnly() {
        for value in ["", " \n", "episode.mp3", "/tmp/file.mp3", "file:///tmp/private.mp3", "javascript:alert(1)", "https://"] {
            let items = EpisodeShareItems.make(title: "Episode", audioURL: value)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first as? String, "Episode", value)
        }
    }
}
