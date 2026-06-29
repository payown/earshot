import XCTest
@testable import Earshot

/// Unit tests for the pure chapter-row presentation mapper (#509): the mapping
/// from (now-playing / included / skipped) state to markers, indicators, status
/// words, the rotor action name, and the combined VoiceOver label.
final class ChapterRowStateTests: XCTestCase {

    // MARK: Marker (leading now-playing badge)

    func testMarkerIsFilledPlayWhenCurrent() {
        let state = ChapterRowState(isCurrent: true, isSkipped: false)
        XCTAssertEqual(state.markerSystemImage, "play.circle.fill")
    }

    func testMarkerIsHollowWhenNotCurrent() {
        let state = ChapterRowState(isCurrent: false, isSkipped: false)
        XCTAssertEqual(state.markerSystemImage, "circle")
    }

    // MARK: Indicator (trailing included/skipped icon)

    func testIndicatorIsCheckmarkWhenIncluded() {
        // Included is the default — a checkmark, realizing "selected, deselect
        // to skip".
        let state = ChapterRowState(isCurrent: false, isSkipped: false)
        XCTAssertEqual(state.indicatorSystemImage, "checkmark.circle.fill")
    }

    func testIndicatorIsSlashWhenSkipped() {
        let state = ChapterRowState(isCurrent: false, isSkipped: true)
        XCTAssertEqual(state.indicatorSystemImage, "circle.slash")
    }

    // MARK: Status word (state in words, never color-only)

    func testStatusWordNowPlayingWhenCurrentAndIncluded() {
        let state = ChapterRowState(isCurrent: true, isSkipped: false)
        XCTAssertEqual(state.statusWord, "Now playing")
    }

    func testStatusWordSkippedWhenSkipped() {
        let state = ChapterRowState(isCurrent: false, isSkipped: true)
        XCTAssertEqual(state.statusWord, "Skipped")
    }

    func testStatusWordSkippedWinsOverNowPlaying() {
        // A deselected current chapter is about to be jumped over — "Skipped"
        // is the more important signal.
        let state = ChapterRowState(isCurrent: true, isSkipped: true)
        XCTAssertEqual(state.statusWord, "Skipped")
    }

    func testStatusWordNilWhenPlainIncludedRow() {
        let state = ChapterRowState(isCurrent: false, isSkipped: false)
        XCTAssertNil(state.statusWord)
    }

    // MARK: Rotor action name (reflects current state)

    func testToggleActionNameIsSkipWhenIncluded() {
        let state = ChapterRowState(isCurrent: false, isSkipped: false)
        XCTAssertEqual(state.toggleActionName, "Skip this chapter")
    }

    func testToggleActionNameIsIncludeWhenSkipped() {
        let state = ChapterRowState(isCurrent: false, isSkipped: true)
        XCTAssertEqual(state.toggleActionName, "Include this chapter")
    }

    // MARK: Combined accessibility label

    func testLabelLeadsWithNumberedTitleAndTime() {
        let state = ChapterRowState(isCurrent: false, isSkipped: false)
        let label = state.accessibilityLabel(
            number: 3, title: "Interview", spokenTime: "5 minutes")
        XCTAssertEqual(label, "3. Interview, 5 minutes")
    }

    func testLabelAppendsNowPlaying() {
        let state = ChapterRowState(isCurrent: true, isSkipped: false)
        let label = state.accessibilityLabel(
            number: 1, title: "Intro", spokenTime: "0 seconds")
        XCTAssertEqual(label, "1. Intro, 0 seconds, now playing")
    }

    func testLabelAppendsSkipped() {
        let state = ChapterRowState(isCurrent: false, isSkipped: true)
        let label = state.accessibilityLabel(
            number: 2, title: "Ad break", spokenTime: "2 minutes")
        XCTAssertEqual(label, "2. Ad break, 2 minutes, skipped")
    }

    func testLabelAppendsBothNowPlayingAndSkipped() {
        let state = ChapterRowState(isCurrent: true, isSkipped: true)
        let label = state.accessibilityLabel(
            number: 4, title: "Sponsor", spokenTime: "10 minutes")
        XCTAssertEqual(label, "4. Sponsor, 10 minutes, now playing, skipped")
    }

    func testLabelIsNeverEmpty() {
        // Even a blank title yields a non-empty label (number + comma + time),
        // so VoiceOver never reads an empty value as a pause.
        let state = ChapterRowState(isCurrent: false, isSkipped: false)
        let label = state.accessibilityLabel(
            number: 1, title: "", spokenTime: "0 seconds")
        XCTAssertFalse(label.isEmpty)
    }
}
