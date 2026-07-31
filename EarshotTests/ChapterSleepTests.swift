import XCTest
@testable import Earshot

final class ChapterParserTests: XCTestCase {

    func testParsePodcastIndexJSON() {
        let json = """
        {"version":"1.2.0","chapters":[
          {"startTime":0,"title":"Intro"},
          {"startTime":61.5,"title":"Topic","img":"https://x/img.jpg"},
          {"startTime":120,"title":"Hidden","toc":false},
          {"title":"No start time"}
        ]}
        """.data(using: .utf8)!

        let chapters = ChapterParser.parsePodcastIndexJSON(json)

        XCTAssertEqual(chapters.map(\.title), ["Intro", "Topic"]) // toc:false + missing start dropped
        XCTAssertEqual(chapters[1].startTime, 61.5)
        XCTAssertEqual(chapters[1].imageURL, "https://x/img.jpg")
        XCTAssertEqual(chapters.map(\.index), [0, 1])
    }

    func testParsePodcastIndexJSONTitleFallback() {
        let json = #"{"chapters":[{"startTime":0},{"startTime":30}]}"#.data(using: .utf8)!
        let chapters = ChapterParser.parsePodcastIndexJSON(json)
        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "Chapter 2"])
    }

    func testParsePodcastIndexJSONInvalid() {
        XCTAssertTrue(ChapterParser.parsePodcastIndexJSON(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ChapterParser.parsePodcastIndexJSON(Data(#"{"foo":1}"#.utf8)).isEmpty)
    }

    func testParseDescriptionChapters() {
        let html = "<p>0:00 Introduction</p><p>5:30 - Deep Dive</p><p>1:02:03 Wrap up</p>"
        let chapters = ChapterParser.parseDescriptionChapters(html)
        XCTAssertEqual(chapters.map(\.title), ["Introduction", "Deep Dive", "Wrap up"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 330, 3723])
    }

    func testParseDescriptionChaptersSortsAndTrailingTimestamp() {
        let html = "Topic two - 5:00\nTopic one 0:30"
        let chapters = ChapterParser.parseDescriptionChapters(html)
        XCTAssertEqual(chapters.map(\.startTime), [30, 300]) // sorted ascending
        XCTAssertEqual(chapters.first?.title, "Topic one")
    }

    func testParseDescriptionChaptersIgnoresLoneTimestamp() {
        // Fewer than 2 timestamps -> not a chapter list.
        XCTAssertTrue(ChapterParser.parseDescriptionChapters("See you at 9:00 tomorrow").isEmpty)
    }

    func testParseTimestamp() {
        XCTAssertEqual(ChapterParser.parseTimestamp("0:00"), 0)
        XCTAssertEqual(ChapterParser.parseTimestamp("5:30"), 330)
        XCTAssertEqual(ChapterParser.parseTimestamp("1:02:03"), 3723)
        XCTAssertNil(ChapterParser.parseTimestamp("5:99")) // seconds out of range
        XCTAssertNil(ChapterParser.parseTimestamp("nope"))
    }

    func testActiveChapterIndex() {
        let chapters = [
            Chapter(index: 0, startTime: 0, title: "A"),
            Chapter(index: 1, startTime: 60, title: "B"),
            Chapter(index: 2, startTime: 120, title: "C"),
        ]
        XCTAssertEqual(chapters.activeChapterIndex(at: 0), 0)
        XCTAssertEqual(chapters.activeChapterIndex(at: 75), 1)
        XCTAssertEqual(chapters.activeChapterIndex(at: 200), 2)
    }
}

final class SleepTimerLogicTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRemainingAndExpiry() {
        let end = now.addingTimeInterval(120)
        XCTAssertEqual(SleepTimerLogic.remaining(endDate: end, now: now), 120)
        XCTAssertEqual(SleepTimerLogic.remaining(endDate: now, now: now.addingTimeInterval(10)), 0)
        XCTAssertFalse(SleepTimerLogic.isExpired(endDate: end, now: now))
        XCTAssertTrue(SleepTimerLogic.isExpired(endDate: end, now: now.addingTimeInterval(121)))
    }

    func testAnnouncement() {
        XCTAssertEqual(SleepTimerLogic.announcement(endOfEpisode: true, remaining: nil), "Sleep timer set: end of episode")
        XCTAssertEqual(SleepTimerLogic.announcement(endOfEpisode: false, remaining: 300), "Sleep timer: 5 minutes")
        XCTAssertEqual(SleepTimerLogic.announcement(endOfEpisode: false, remaining: 45), "Sleep timer: 45 seconds")
        XCTAssertEqual(SleepTimerLogic.announcement(endOfEpisode: false, remaining: nil), "Sleep timer off")
    }

    func testClock() {
        XCTAssertEqual(SleepTimerLogic.clock(330), "5:30")
        XCTAssertEqual(SleepTimerLogic.clock(9), "0:09")
    }

    func testPresetDurations() {
        XCTAssertNil(SleepTimerPreset.endOfEpisode.duration)
        XCTAssertEqual(SleepTimerPreset.fiveMinutes.duration, 300)
        XCTAssertEqual(SleepTimerPreset.sixtyMinutes.duration, 3600)
    }
}

@MainActor
final class SleepTimerControllerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSetCountdownPreset() {
        let timer = SleepTimerController()
        timer.set(.fiveMinutes, now: now)
        XCTAssertTrue(timer.isActive)
        XCTAssertFalse(timer.endOfEpisode)
        XCTAssertEqual(timer.remainingSeconds, 300)
    }

    func testSetEndOfEpisode() {
        let timer = SleepTimerController()
        timer.set(.endOfEpisode, now: now)
        XCTAssertTrue(timer.isActive)
        XCTAssertTrue(timer.endOfEpisode)
        XCTAssertNil(timer.remainingSeconds)
    }

    func testExtend() {
        let timer = SleepTimerController()
        timer.set(.fiveMinutes, now: now)
        timer.extend(by: 300, now: now)
        XCTAssertEqual(timer.remainingSeconds, 600)
    }

    func testExtendIgnoredForEndOfEpisode() {
        let timer = SleepTimerController()
        timer.set(.endOfEpisode, now: now)
        timer.extend(by: 300, now: now)
        XCTAssertNil(timer.remainingSeconds)
    }

    func testCancel() {
        let timer = SleepTimerController()
        timer.set(.tenMinutes, now: now)
        timer.cancel()
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remainingSeconds)
    }

    func testEndOfEpisodeFiresOnEpisodeEnded() {
        let timer = SleepTimerController()
        var fired = false
        timer.onExpired = { fired = true }
        timer.set(.endOfEpisode, now: now)

        timer.episodeEnded()

        XCTAssertTrue(fired)
        XCTAssertFalse(timer.isActive)
    }

    func testEpisodeEndedNoopForCountdown() {
        let timer = SleepTimerController()
        var fired = false
        timer.onExpired = { fired = true }
        timer.set(.fiveMinutes, now: now)

        timer.episodeEnded()

        XCTAssertFalse(fired)
        XCTAssertTrue(timer.isActive)
    }

    // MARK: Cancel-on-episode-switch behaviour (issue #379)

    // Cancelling a countdown timer clears all state and does not call onExpired.
    func testCancelCountdownDoesNotFireOnExpired() {
        let timer = SleepTimerController()
        var fired = false
        timer.onExpired = { fired = true }
        timer.set(.thirtyMinutes, now: now)
        XCTAssertTrue(timer.isActive)

        timer.cancel()

        XCTAssertFalse(fired, "cancel() must not fire onExpired")
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remainingSeconds)
        XCTAssertFalse(timer.endOfEpisode)
    }

    // Cancelling an end-of-episode timer clears state without firing onExpired.
    func testCancelEndOfEpisodeDoesNotFireOnExpired() {
        let timer = SleepTimerController()
        var fired = false
        timer.onExpired = { fired = true }
        timer.set(.endOfEpisode, now: now)
        XCTAssertTrue(timer.isActive)

        timer.cancel()

        XCTAssertFalse(fired, "cancel() must not fire onExpired")
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(timer.endOfEpisode)
    }

    // After cancel, extend is a no-op (guarded by isActive).
    func testExtendAfterCancelIsNoop() {
        let timer = SleepTimerController()
        timer.set(.fiveMinutes, now: now)
        timer.cancel()
        timer.extend(by: 300, now: now) // must not crash or re-activate
        XCTAssertFalse(timer.isActive)
        XCTAssertNil(timer.remainingSeconds)
    }

    // Extend by the default 5-minute amount increases remaining for a countdown timer.
    func testExtendByFiveMinutesDefaultAmount() throws {
        let timer = SleepTimerController()
        timer.set(.tenMinutes, now: now)
        // Default extend is SleepTimerLogic.extendBy (300 s)
        timer.extend(now: now)
        // 10 min + 5 min = 15 min
        let remaining = try XCTUnwrap(timer.remainingSeconds)
        XCTAssertEqual(remaining, 900, accuracy: 1.0)
    }
}
