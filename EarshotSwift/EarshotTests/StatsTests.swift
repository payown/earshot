import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class StatsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let p = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func makeSession(
        _ ctx: ModelContext, podcast: Podcast, seconds: Int, speed: Double = 1.0, date: Date
    ) -> ListeningSession {
        let s = ListeningSession(podcast: podcast, durationSeconds: seconds, speed: speed, date: date)
        ctx.insert(s)
        return s
    }

    // MARK: StatsLogic (pure)

    func testTimeSavedBySpeed() {
        XCTAssertEqual(StatsLogic.timeSavedBySpeed(durationSeconds: 60, speed: 2.0), 30)
        XCTAssertEqual(StatsLogic.timeSavedBySpeed(durationSeconds: 100, speed: 1.0), 0)
        XCTAssertEqual(StatsLogic.timeSavedBySpeed(durationSeconds: 100, speed: 0.8), 0)
        XCTAssertEqual(StatsLogic.timeSavedBySpeed(durationSeconds: 90, speed: 1.5), 30)
    }

    func testIsListeningStepFiltersSeeks() {
        XCTAssertTrue(StatsLogic.isListeningStep(1))
        XCTAssertTrue(StatsLogic.isListeningStep(6))
        XCTAssertFalse(StatsLogic.isListeningStep(0))
        XCTAssertFalse(StatsLogic.isListeningStep(-15)) // skip back
        XCTAssertFalse(StatsLogic.isListeningStep(30))  // skip forward
    }

    func testCurrentStreakCountsConsecutiveDaysEndingToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day: TimeInterval = 86_400
        // today, yesterday, two-days-ago, then a gap, then 4 days ago.
        let dates = [now, now - day, now - 2 * day, now - 4 * day]
        XCTAssertEqual(StatsLogic.currentStreak(sessionDates: dates, now: now, calendar: cal), 3)
    }

    func testStreakIsZeroWhenNothingToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dates = [now - 86_400] // only yesterday
        XCTAssertEqual(StatsLogic.currentStreak(sessionDates: dates, now: now, calendar: cal), 0)
    }

    // MARK: StatsRepository aggregation

    func testAggregatesTotalsTimeSavedAndPerPodcast() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        let b = makePodcast(ctx, "Beta")
        makeSession(ctx, podcast: a, seconds: 60, speed: 2.0, date: now)
        makeSession(ctx, podcast: a, seconds: 30, speed: 1.0, date: now)
        makeSession(ctx, podcast: b, seconds: 120, speed: 1.5, date: now)

        let stats = StatsRepository(context: ctx).stats(for: .allTime, now: now)

        XCTAssertEqual(stats.totalSeconds, 210)
        XCTAssertEqual(stats.timeSavedSeconds, 30 + 40) // 60@2x=30, 120@1.5x=40
        // Beta (120) sorts before Alpha (90).
        XCTAssertEqual(stats.perPodcast.map(\.podcastTitle), ["Beta", "Alpha"])
        XCTAssertEqual(stats.perPodcast.first?.episodeCount, 1)
    }

    func testPeriodFiltersOldSessions() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        makeSession(ctx, podcast: a, seconds: 100, date: now)
        makeSession(ctx, podcast: a, seconds: 50, date: now.addingTimeInterval(-40 * 86_400))

        let week = StatsRepository(context: ctx).stats(for: .thisWeek, now: now)
        let all = StatsRepository(context: ctx).stats(for: .allTime, now: now)

        XCTAssertEqual(week.totalSeconds, 100)
        XCTAssertEqual(all.totalSeconds, 150)
    }

    func testStreakOnlyComputedWhenIncluded() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        makeSession(ctx, podcast: a, seconds: 100, date: now)

        XCTAssertEqual(StatsRepository(context: ctx).stats(for: .allTime, now: now, includeStreak: false).currentStreakDays, 0)
        XCTAssertGreaterThanOrEqual(StatsRepository(context: ctx).stats(for: .allTime, now: now, includeStreak: true).currentStreakDays, 1)
    }

    func testEpisodesCompletedCountsPlayedSince() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        let played = Episode(guid: "p", title: "Played", audioURL: "x")
        played.podcast = a
        played.isPlayed = true // sets playedAt = .now (recent, within this week)
        ctx.insert(played)
        let unplayed = Episode(guid: "u", title: "Unplayed", audioURL: "x")
        unplayed.podcast = a
        ctx.insert(unplayed)

        let stats = StatsRepository(context: ctx).stats(for: .allTime, now: .now)
        XCTAssertEqual(stats.episodesCompleted, 1)
    }

    func testApplyRetentionDeletesOldSessions() throws {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        makeSession(ctx, podcast: a, seconds: 10, date: now)
        makeSession(ctx, podcast: a, seconds: 10, date: now.addingTimeInterval(-100 * 86_400))
        try ctx.save()

        StatsRepository(context: ctx).applyRetention(days: 90, now: now)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ListeningSession>()).count, 1)
    }

    func testApplyRetentionZeroKeepsEverything() throws {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        makeSession(ctx, podcast: a, seconds: 10, date: now.addingTimeInterval(-1000 * 86_400))
        try ctx.save()

        StatsRepository(context: ctx).applyRetention(days: 0, now: now)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ListeningSession>()).count, 1)
    }

    func testDeleteAllHistory() throws {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha")
        makeSession(ctx, podcast: a, seconds: 10, date: now)
        makeSession(ctx, podcast: a, seconds: 10, date: now)
        try ctx.save()

        StatsRepository(context: ctx).deleteAllHistory()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ListeningSession>()).count, 0)
    }

    func testCSVExportHasHeaderAndRows() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "Alpha, Inc")
        makeSession(ctx, podcast: a, seconds: 42, speed: 1.5, date: now)

        let csv = StatsRepository(context: ctx).csv(now: now)
        let lines = csv.split(separator: "\n")

        XCTAssertEqual(lines.first, "date,podcast,episode,duration_seconds,speed")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"Alpha, Inc\""), "comma-containing field is quoted")
        XCTAssertTrue(lines[1].contains("42"))
        XCTAssertTrue(lines[1].contains("1.5"))
    }
}
