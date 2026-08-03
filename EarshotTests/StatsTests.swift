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

    @discardableResult
    private func makeCompletedEpisode(
        _ ctx: ModelContext,
        podcast: Podcast,
        guid: String,
        playedAt: Date
    ) -> Episode {
        let episode = Episode(guid: guid, title: guid, audioURL: "https://x/\(guid).mp3")
        episode.podcast = podcast
        episode.status = .played
        episode.playedAt = playedAt
        ctx.insert(episode)
        return episode
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

    func testFolderAnnouncementNamesScopeAndUpdatedTotalOnce() {
        XCTAssertEqual(
            StatsFolderAnnouncement.text(scopeName: "News › Daily", totalSeconds: 3_720),
            "News › Daily. Total listening 1 hour 2 minutes."
        )
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

    func testFolderScopeIncludesCurrentSubtreeAndExcludesOutsidePodcast() {
        let ctx = TestStore.freshContext()
        let rootPodcast = makePodcast(ctx, "Root Show")
        let childPodcast = makePodcast(ctx, "Child Show")
        let outsidePodcast = makePodcast(ctx, "Outside Show")
        makeSession(ctx, podcast: rootPodcast, seconds: 60, date: now)
        makeSession(ctx, podcast: childPodcast, seconds: 120, date: now)
        makeSession(ctx, podcast: outsidePodcast, seconds: 240, date: now)
        let folders = FolderRepository(context: ctx)
        let root = folders.createFolder(name: "News")
        let child = folders.createSubfolder(named: "Daily", under: root)
        folders.add(rootPodcast, to: root)
        folders.add(childPodcast, to: child)
        let scope = Set(folders.subtreeSubscriptions(of: root).map(\.persistentModelID))

        let stats = StatsRepository(context: ctx).stats(
            for: .allTime,
            now: now,
            podcastIDs: scope
        )

        XCTAssertEqual(stats.totalSeconds, 180)
        XCTAssertEqual(Set(stats.perPodcast.map(\.podcastTitle)), ["Root Show", "Child Show"])
    }

    func testPodcastInMultipleFoldersIsCountedOnceWithinFolderScope() {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Shared Show")
        makeSession(ctx, podcast: podcast, seconds: 90, date: now)
        let folders = FolderRepository(context: ctx)
        let root = folders.createFolder(name: "Root")
        let child = folders.createSubfolder(named: "Child", under: root)
        folders.add(podcast, to: root)
        folders.add(podcast, to: child)
        let scope = Set(folders.subtreeSubscriptions(of: root).map(\.persistentModelID))

        let stats = StatsRepository(context: ctx).stats(
            for: .allTime,
            now: now,
            podcastIDs: scope
        )

        XCTAssertEqual(scope.count, 1, "Subtree membership is de-duplicated by podcast identity")
        XCTAssertEqual(stats.totalSeconds, 90)
        XCTAssertEqual(stats.perPodcast.first?.episodeCount, 1)
    }

    func testUnfiledScopeIncludesOnlyPodcastsWithNoCurrentFolderMembership() {
        let ctx = TestStore.freshContext()
        let filed = makePodcast(ctx, "Filed")
        let unfiled = makePodcast(ctx, "Unfiled")
        makeSession(ctx, podcast: filed, seconds: 60, date: now)
        makeSession(ctx, podcast: unfiled, seconds: 120, date: now)
        let folders = FolderRepository(context: ctx)
        let folder = folders.createFolder(name: "News")
        folders.add(filed, to: folder)
        let scope = Set(folders.unfiledPodcasts().map(\.persistentModelID))

        let stats = StatsRepository(context: ctx).stats(
            for: .allTime,
            now: now,
            podcastIDs: scope
        )

        XCTAssertEqual(stats.totalSeconds, 120)
        XCTAssertEqual(stats.perPodcast.map(\.podcastTitle), ["Unfiled"])
    }

    func testFolderScopeUsesCurrentMembershipForHistoricalSessions() {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Moving Show")
        makeSession(ctx, podcast: podcast, seconds: 180, date: now.addingTimeInterval(-30 * 86_400))
        let folders = FolderRepository(context: ctx)
        let oldFolder = folders.createFolder(name: "Old")
        let newFolder = folders.createFolder(name: "New")
        folders.add(podcast, to: oldFolder)
        folders.setMemberships(for: podcast, folders: [newFolder])

        let oldScope = Set(folders.subtreeSubscriptions(of: oldFolder).map(\.persistentModelID))
        let newScope = Set(folders.subtreeSubscriptions(of: newFolder).map(\.persistentModelID))

        XCTAssertEqual(
            StatsRepository(context: ctx).stats(for: .allTime, now: now, podcastIDs: oldScope),
            .empty
        )
        XCTAssertEqual(
            StatsRepository(context: ctx).stats(for: .allTime, now: now, podcastIDs: newScope)
                .totalSeconds,
            180
        )
    }

    func testFolderScopeAppliesToPeriodCompletedEpisodesAndStreak() {
        let ctx = TestStore.freshContext()
        let inside = makePodcast(ctx, "Inside")
        let outside = makePodcast(ctx, "Outside")
        makeSession(ctx, podcast: inside, seconds: 100, date: now)
        makeSession(ctx, podcast: inside, seconds: 50, date: now.addingTimeInterval(-40 * 86_400))
        makeSession(ctx, podcast: outside, seconds: 200, date: now)
        makeCompletedEpisode(ctx, podcast: inside, guid: "inside", playedAt: now)
        makeCompletedEpisode(ctx, podcast: outside, guid: "outside", playedAt: now)
        let folders = FolderRepository(context: ctx)
        let folder = folders.createFolder(name: "Inside")
        folders.add(inside, to: folder)
        let scope = Set(folders.subtreeSubscriptions(of: folder).map(\.persistentModelID))

        let stats = StatsRepository(context: ctx).stats(
            for: .thisWeek,
            now: now,
            includeStreak: true,
            podcastIDs: scope
        )

        XCTAssertEqual(stats.totalSeconds, 100, "The old in-scope session is outside This Week")
        XCTAssertEqual(stats.episodesCompleted, 1, "Outside completed episodes are excluded")
        XCTAssertEqual(stats.currentStreakDays, 1, "Only in-scope session dates feed the streak")
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

    // MARK: removeSessions(for:) — dangling-session cleanup on unsubscribe (#377)

    /// The new primitive deletes exactly the target podcast's sessions and returns
    /// the count removed; another podcast's sessions are left intact.
    func testRemoveSessionsForPodcastDeletesOnlyThatPodcastsAndReturnsCount() throws {
        let ctx = TestStore.freshContext()
        let doomed = makePodcast(ctx, "Doomed")
        let keeper = makePodcast(ctx, "Keeper")
        makeSession(ctx, podcast: doomed, seconds: 60, date: now)
        makeSession(ctx, podcast: doomed, seconds: 30, date: now)
        makeSession(ctx, podcast: keeper, seconds: 90, date: now)
        try ctx.save()

        let removed = StatsRepository(context: ctx).removeSessions(for: doomed)

        XCTAssertEqual(removed, 2, "Both of the doomed podcast's sessions are removed")
        let remaining = try ctx.fetch(FetchDescriptor<ListeningSession>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.podcast?.title, "Keeper")
    }

    /// A podcast with no listening sessions is a clean no-op: nothing is deleted,
    /// the return count is zero, and no unrelated rows are touched (exercises the
    /// `guard !toDelete.isEmpty` early return).
    func testRemoveSessionsForPodcastWithNoSessionsIsNoOpReturningZero() throws {
        let ctx = TestStore.freshContext()
        let empty = makePodcast(ctx, "Empty")
        let other = makePodcast(ctx, "Other")
        makeSession(ctx, podcast: other, seconds: 60, date: now)
        try ctx.save()

        let removed = StatsRepository(context: ctx).removeSessions(for: empty)

        XCTAssertEqual(removed, 0, "No sessions reference this podcast, so nothing is removed")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ListeningSession>()).count, 1, "Unrelated session untouched")
    }

    /// Regression guard: removing one podcast's sessions must not perturb a
    /// surviving podcast's aggregated stats — totals, time-saved, per-podcast
    /// breakdown, and episode counts all match what they were before the cleanup.
    func testSurvivingPodcastStatsUnaffectedAfterRemovingAnothers() throws {
        let ctx = TestStore.freshContext()
        let doomed = makePodcast(ctx, "Doomed")
        let keeper = makePodcast(ctx, "Keeper")
        makeSession(ctx, podcast: doomed, seconds: 60, speed: 2.0, date: now)
        makeSession(ctx, podcast: keeper, seconds: 120, speed: 1.5, date: now)
        makeSession(ctx, podcast: keeper, seconds: 60, speed: 1.0, date: now)
        try ctx.save()

        StatsRepository(context: ctx).removeSessions(for: doomed)

        let stats = StatsRepository(context: ctx).stats(for: .allTime, now: now)
        XCTAssertEqual(stats.totalSeconds, 180, "Only the keeper's 120 + 60 remain")
        XCTAssertEqual(stats.timeSavedSeconds, 40, "120@1.5x saves 40; the doomed 60@2x is gone")
        XCTAssertEqual(stats.perPodcast.map(\.podcastTitle), ["Keeper"], "Doomed no longer appears")
        XCTAssertEqual(stats.perPodcast.first?.episodeCount, 2)
        XCTAssertFalse(
            stats.perPodcast.contains { $0.podcastTitle == "Unknown Podcast" },
            "No dangling session survives to show as Unknown Podcast"
        )
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
