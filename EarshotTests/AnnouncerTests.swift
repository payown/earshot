import XCTest
import UIKit
@testable import Earshot

/// Unit tests for the VoiceOver announcement attribute wiring (#688). The
/// `UIAccessibility.post` side effect isn't unit-testable, but the attribute
/// builder — queue behavior plus the pinned speech language that stops
/// mid-utterance voice switching — is.
final class AnnouncerTests: XCTestCase {

    func testPoliteIncludesQueueAndLanguage() {
        let attrs = Announcer.announcementAttributes(assertive: false, languageTag: "en-US")
        XCTAssertEqual(attrs[.accessibilitySpeechLanguage] as? String, "en-US")
        XCTAssertEqual(attrs[.accessibilitySpeechQueueAnnouncement] as? Bool, true)
    }

    func testAssertiveOmitsQueueButKeepsLanguage() {
        let attrs = Announcer.announcementAttributes(assertive: true, languageTag: "es-ES")
        XCTAssertNil(attrs[.accessibilitySpeechQueueAnnouncement])
        XCTAssertEqual(attrs[.accessibilitySpeechLanguage] as? String, "es-ES")
    }

    func testNilLanguageOmitsLanguageKey() {
        let attrs = Announcer.announcementAttributes(assertive: false, languageTag: nil)
        XCTAssertNil(attrs[.accessibilitySpeechLanguage])
        XCTAssertEqual(attrs[.accessibilitySpeechQueueAnnouncement] as? Bool, true)
    }

    func testEmptyLanguageOmitsLanguageKey() {
        let attrs = Announcer.announcementAttributes(assertive: false, languageTag: "")
        XCTAssertNil(attrs[.accessibilitySpeechLanguage])
    }

    /// The pinned language must be a BCP-47 tag (hyphens), not POSIX (underscores),
    /// or VoiceOver ignores it.
    func testLocaleTagIsBCP47() {
        if let tag = Announcer.localeBCP47 {
            XCTAssertFalse(tag.isEmpty)
            XCTAssertFalse(tag.contains("_"), "expected BCP-47 (en-US), got POSIX: \(tag)")
        }
    }
}
