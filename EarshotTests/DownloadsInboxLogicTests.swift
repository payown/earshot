import XCTest
@testable import Earshot

final class DownloadsInboxLogicTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }

    // MARK: InboxLogic — exclusion

    func testExcludedWhenOptedOutAndNotIncluded() {
        XCTAssertTrue(InboxLogic.isExcluded(inboxExcluded: true, inboxIncluded: false))
    }

    func testIncludedOverrideWins() {
        XCTAssertFalse(InboxLogic.isExcluded(inboxExcluded: true, inboxIncluded: true))
    }

    func testNotExcludedByDefault() {
        XCTAssertFalse(InboxLogic.isExcluded(inboxExcluded: false, inboxIncluded: false))
    }

    // MARK: InboxLogic — age dismissal

    func testAgeDismissesUnplayedOlderThanCutoff() {
        let items = [
            (id: 1, pubDate: Optional(hoursAgo(50)), positionSeconds: 0),
            (id: 2, pubDate: Optional(hoursAgo(10)), positionSeconds: 0),
        ]
        XCTAssertEqual(InboxLogic.idsToDismissForAge(items, ageLimitHours: 24, now: now), [1])
    }

    func testAgeNeverDismissesStartedEpisodes() {
        let items = [(id: 1, pubDate: Optional(hoursAgo(50)), positionSeconds: 120)]
        XCTAssertEqual(InboxLogic.idsToDismissForAge(items, ageLimitHours: 24, now: now), [])
    }

    func testAgeIgnoresMissingPubDate() {
        let items = [(id: 1, pubDate: Optional<Date>.none, positionSeconds: 0)]
        XCTAssertEqual(InboxLogic.idsToDismissForAge(items, ageLimitHours: 24, now: now), [])
    }

    // MARK: InboxLogic — count cap

    func testCountCapDismissesOldestBeyondCap() {
        // newest-first ids; cap 2 keeps [10, 9], dismisses [8, 7].
        XCTAssertEqual(InboxLogic.idsToDismissForCount([10, 9, 8, 7], cap: 2), [8, 7])
    }

    func testCountCapNoOpWhenUnderCap() {
        XCTAssertEqual(InboxLogic.idsToDismissForCount([10, 9], cap: 3), [])
    }

    func testCountCapZeroDismissesAll() {
        XCTAssertEqual(InboxLogic.idsToDismissForCount([3, 2, 1], cap: 0), [3, 2, 1])
    }

    func testInboxDisplayExpandsInBoundedHundredEpisodeBatches() {
        XCTAssertEqual(InboxLogic.nextDisplayLimit(current: 100, total: 2_088), 200)
        XCTAssertEqual(InboxLogic.nextDisplayLimit(current: 2_000, total: 2_088), 2_088)
        XCTAssertEqual(InboxLogic.nextDisplayLimit(current: 100, total: 42), 42)
    }

    // MARK: InboxLogic — title + count (#422)

    func testInboxTitleShowsCountWhenNonEmpty() {
        XCTAssertEqual(InboxLogic.inboxTitle(count: 12), "Inbox (12)")
        XCTAssertEqual(InboxLogic.inboxTitle(count: 1), "Inbox (1)")
    }

    func testInboxTitleNeverShowsZero() {
        XCTAssertEqual(InboxLogic.inboxTitle(count: 0), "Inbox")
        XCTAssertFalse(InboxLogic.inboxTitle(count: 0).contains("("))
    }

    func testInboxTitleAccessibilityLabelReadsNaturally() {
        XCTAssertEqual(InboxLogic.inboxTitleAccessibilityLabel(count: 12), "Inbox, 12 episodes")
        XCTAssertEqual(InboxLogic.inboxTitleAccessibilityLabel(count: 1), "Inbox, 1 episode")
    }

    func testInboxTitleAccessibilityLabelEmptyOmitsCount() {
        XCTAssertEqual(InboxLogic.inboxTitleAccessibilityLabel(count: 0), "Inbox")
    }

    // MARK: InboxLogic — played-state dismissal (#546)

    func testMarkingPlayedDismissesFromInbox() {
        XCTAssertTrue(InboxLogic.inboxDismissedAfterPlayedChange(nowPlayed: true, wasDismissed: false))
    }

    func testMarkingPlayedStaysDismissed() {
        XCTAssertTrue(InboxLogic.inboxDismissedAfterPlayedChange(nowPlayed: true, wasDismissed: true))
    }

    func testMarkingUnplayedDoesNotResurfaceDismissed() {
        // Sticky: a previously-triaged (dismissed) episode marked unplayed must
        // not jump back into the inbox.
        XCTAssertTrue(InboxLogic.inboxDismissedAfterPlayedChange(nowPlayed: false, wasDismissed: true))
    }

    func testMarkingUnplayedLeavesUndismissedAlone() {
        XCTAssertFalse(InboxLogic.inboxDismissedAfterPlayedChange(nowPlayed: false, wasDismissed: false))
    }

    // MARK: InboxRepository.markPlayed — end-to-end (#546)

    @MainActor
    func testMarkPlayedRemovesEpisodeFromInboxAndKeepsItOut() throws {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        let ep = Episode(guid: "e1", title: "Ep 1", audioURL: "https://x/e1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxEpisodes().map(\.guid), ["e1"], "seeded episode should start in the inbox")

        repo.markPlayed(ep)
        XCTAssertTrue(ep.isPlayed)
        XCTAssertTrue(ep.inboxDismissed)
        XCTAssertTrue(repo.inboxEpisodes().isEmpty, "marking played should clear it from the inbox")

        // Marking unplayed again must not resurface it (#546: sticky dismissal).
        ep.isPlayed = false
        try ctx.save()
        XCTAssertTrue(ep.inboxDismissed)
        XCTAssertTrue(repo.inboxEpisodes().isEmpty, "an un-played episode must not jump back into the inbox")
    }

    @MainActor
    func testDismissRemovesEpisodeWithoutMarkingItPlayed() throws {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        let episode = Episode(guid: "dismiss", title: "Dismiss", audioURL: "https://x/dismiss.mp3")
        episode.podcast = podcast
        ctx.insert(podcast)
        ctx.insert(episode)
        try ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxEpisodes().map(\.guid), ["dismiss"])

        repo.dismiss(episode)

        XCTAssertTrue(episode.inboxDismissed)
        XCTAssertFalse(episode.isPlayed)
        XCTAssertTrue(repo.inboxEpisodes().isEmpty)
    }

    // MARK: EpisodeActionsBuilder — Mark-played Quick Action, both directions (#546)

    @MainActor
    func testMarkPlayedQuickActionDismissesFromInboxThenStaysStickyWhenToggledUnplayed() throws {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        let ep = Episode(guid: "e1", title: "Ep 1", audioURL: "https://x/e1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        let inbox = InboxRepository(context: ctx)
        XCTAssertEqual(inbox.inboxEpisodes().map(\.guid), ["e1"], "seeded episode should start in the inbox")

        // Build the Quick Action while unplayed and run it. The played direction
        // must mark played AND dismiss from the inbox durably.
        let playedItems = buildEpisodeActions(
            episode: ep, order: [.markPlayed], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}
        )
        XCTAssertEqual(playedItems.map(\.label), ["Mark as played"])
        playedItems.first?.run()
        XCTAssertTrue(ep.isPlayed)
        XCTAssertTrue(ep.inboxDismissed)
        XCTAssertTrue(inbox.inboxEpisodes().isEmpty, "mark-played Quick Action should clear it from the inbox")

        // Rebuild (label is state-derived) and run the unplayed direction. It
        // must un-play the episode but leave the dismissal sticky (#546), so a
        // triaged episode never jumps back into the inbox.
        let unplayedItems = buildEpisodeActions(
            episode: ep, order: [.markPlayed], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}
        )
        XCTAssertEqual(unplayedItems.map(\.label), ["Mark as unplayed"])
        unplayedItems.first?.run()
        XCTAssertFalse(ep.isPlayed)
        XCTAssertTrue(ep.inboxDismissed, "marking unplayed must not clear a prior dismissal")
        XCTAssertTrue(inbox.inboxEpisodes().isEmpty, "an un-played episode must not jump back into the inbox")
    }

    // MARK: QueueRepository.markPlayedAndRemove — completion dismisses inbox (#546)

    @MainActor
    func testQueueMarkPlayedAndRemoveDismissesEpisodeFromInbox() throws {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        let ep = Episode(guid: "e1", title: "Ep 1", audioURL: "https://x/e1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        // Queue the episode, then complete it. markPlayedAndRemove only acts on
        // a queued episode (it removes the queue item), so it must be enqueued
        // first to exercise the completion path.
        let queue = QueueRepository(context: ctx)
        queue.add(ep)
        queue.markPlayedAndRemove(ep)

        let inbox = InboxRepository(context: ctx)
        XCTAssertTrue(ep.isPlayed)
        XCTAssertTrue(ep.inboxDismissed, "completion path must set inboxDismissed")
        XCTAssertTrue(inbox.inboxEpisodes().isEmpty, "a completed episode must leave the inbox")
    }

    // MARK: InboxRepository — opt-in inclusion (#668)

    /// With "Opt-in podcasts only" ON, only podcasts explicitly opted in via
    /// `inboxIncluded` surface new episodes in the inbox — regression coverage
    /// for #668, where no UI anywhere ever wrote `inboxIncluded`, so opt-in mode
    /// left every subscriber with a permanently empty inbox and no way out.
    @MainActor
    func testOptInModeIncludesOnlyOptedInPodcast() throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.inboxOptInOnly)

        let included = Podcast(feedURL: "https://x/in.xml", title: "Included Show", inboxIncluded: true)
        ctx.insert(included)
        let includedEp = Episode(guid: "in1", title: "In Ep", audioURL: "https://x/in1.mp3")
        includedEp.podcast = included
        ctx.insert(includedEp)

        let excluded = Podcast(feedURL: "https://x/out.xml", title: "Excluded Show", inboxIncluded: false)
        ctx.insert(excluded)
        let excludedEp = Episode(guid: "out1", title: "Out Ep", audioURL: "https://x/out1.mp3")
        excludedEp.podcast = excluded
        ctx.insert(excludedEp)

        try ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(
            repo.inboxEpisodes().map(\.guid), ["in1"],
            "only the podcast with inboxIncluded == true surfaces in the opt-in inbox"
        )
    }

    /// A podcast that has never been opted in (`inboxIncluded` defaults false)
    /// stays out of the inbox while opt-in mode is on, matching the pre-existing
    /// `InboxRepository.isExcluded` enforcement this fix now has a UI path for.
    @MainActor
    func testOptInModeExcludesPodcastNeverOptedIn() throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.inboxOptInOnly)

        let podcast = Podcast(feedURL: "https://x/default.xml", title: "Default Show")
        ctx.insert(podcast)
        let ep = Episode(guid: "d1", title: "Default Ep", audioURL: "https://x/d1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        XCTAssertTrue(InboxRepository(context: ctx).inboxEpisodes().isEmpty, "a never-opted-in podcast stays out of the opt-in inbox")
    }

    /// Toggling `inboxIncluded` on for a previously-excluded podcast, then
    /// re-fetching, brings its new episode into the opt-in inbox — this is the
    /// exact effect the new Quick Action / swipe action / settings Toggle (#668)
    /// all drive.
    @MainActor
    func testTogglingInboxIncludedBringsPodcastIntoOptInInbox() throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.inboxOptInOnly)

        let podcast = Podcast(feedURL: "https://x/toggle.xml", title: "Toggle Show", inboxIncluded: false)
        ctx.insert(podcast)
        let ep = Episode(guid: "t1", title: "Toggle Ep", audioURL: "https://x/t1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertTrue(repo.inboxEpisodes().isEmpty, "precondition: excluded before opting in")

        podcast.inboxIncluded = true
        try ctx.save()

        XCTAssertEqual(repo.inboxEpisodes().map(\.guid), ["t1"], "opting in surfaces the podcast's episode in the inbox")
    }

    // MARK: InboxRepository — normal-mode exclusion (#671)

    /// With "Opt-in podcasts only" OFF (the default), every podcast is in the
    /// inbox EXCEPT one explicitly excluded via `inboxExcluded` — the mirror
    /// image of the opt-in coverage above. Regression coverage for #671, the
    /// companion gap #668 deliberately left out of scope: no UI anywhere wrote
    /// `inboxExcluded` either.
    @MainActor
    func testNormalModeExcludesOnlyExcludedPodcast() throws {
        let ctx = TestStore.freshContext()
        // optInOnly defaults to false; set explicitly for clarity/robustness.
        AppSettingsStore(context: ctx).setBool(false, for: SettingsKey.inboxOptInOnly)

        let included = Podcast(feedURL: "https://x/in.xml", title: "Included Show", inboxExcluded: false)
        ctx.insert(included)
        let includedEp = Episode(guid: "in1", title: "In Ep", audioURL: "https://x/in1.mp3")
        includedEp.podcast = included
        ctx.insert(includedEp)

        let excluded = Podcast(feedURL: "https://x/out.xml", title: "Excluded Show", inboxExcluded: true)
        ctx.insert(excluded)
        let excludedEp = Episode(guid: "out1", title: "Out Ep", audioURL: "https://x/out1.mp3")
        excludedEp.podcast = excluded
        ctx.insert(excludedEp)

        try ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(
            repo.inboxEpisodes().map(\.guid), ["in1"],
            "the excluded podcast's episode never surfaces in the normal-mode inbox"
        )
    }

    /// A podcast that has never been excluded (`inboxExcluded` defaults false)
    /// stays in the inbox in normal mode, matching the pre-existing
    /// `InboxRepository.isExcluded` enforcement this fix now has a UI path for.
    @MainActor
    func testNormalModeIncludesPodcastNeverExcluded() throws {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/default.xml", title: "Default Show")
        ctx.insert(podcast)
        let ep = Episode(guid: "d1", title: "Default Ep", audioURL: "https://x/d1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        XCTAssertEqual(
            InboxRepository(context: ctx).inboxEpisodes().map(\.guid), ["d1"],
            "a never-excluded podcast stays in the normal-mode inbox by default"
        )
    }

    /// Toggling `inboxExcluded` on for a previously-included podcast, then
    /// re-fetching, removes its new episode from the normal-mode inbox — this is
    /// the exact effect the new Quick Action / swipe action / settings Toggle
    /// (#671) all drive.
    @MainActor
    func testTogglingInboxExcludedRemovesPodcastFromNormalModeInbox() throws {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/toggle.xml", title: "Toggle Show", inboxExcluded: false)
        ctx.insert(podcast)
        let ep = Episode(guid: "t1", title: "Toggle Ep", audioURL: "https://x/t1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxEpisodes().map(\.guid), ["t1"], "precondition: included before excluding")

        podcast.inboxExcluded = true
        try ctx.save()

        XCTAssertTrue(repo.inboxEpisodes().isEmpty, "excluding removes the podcast's episode from the normal-mode inbox")
    }

    /// A podcast can carry both `inboxExcluded == true` (set while in normal
    /// mode) and `inboxIncluded == true` (set while in opt-in mode) if the user
    /// switches "Opt-in podcasts only" back and forth and toggles both
    /// per-podcast switches at different times — the two fields are independent
    /// SwiftData properties, nothing clears one when the other is set. In normal
    /// mode, `InboxRepository`'s private `isExcluded` helper delegates straight
    /// to `InboxLogic.isExcluded(inboxExcluded:inboxIncluded:)`, whose pure-function
    /// contract (asserted at the top of this file) says an explicit re-include
    /// wins over exclusion. This is the end-to-end proof of that contract through
    /// `InboxRepository` specifically for normal mode, so a future change to the
    /// private helper's routing can't silently break the override.
    @MainActor
    func testNormalModeExplicitlyIncludedOverridesExcludedFlag() throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setBool(false, for: SettingsKey.inboxOptInOnly)

        let podcast = Podcast(
            feedURL: "https://x/both.xml", title: "Both Flags Show",
            inboxExcluded: true, inboxIncluded: true
        )
        ctx.insert(podcast)
        let ep = Episode(guid: "b1", title: "Both Ep", audioURL: "https://x/b1.mp3")
        ep.podcast = podcast
        ctx.insert(ep)
        try ctx.save()

        XCTAssertEqual(
            InboxRepository(context: ctx).inboxEpisodes().map(\.guid), ["b1"],
            "an explicit inboxIncluded=true overrides inboxExcluded=true even in normal mode"
        )
    }

    // MARK: ExpirationLogic

    func testQueueItemExpiresOlderThanAgeLimit() {
        XCTAssertTrue(ExpirationLogic.isExpired(addedAt: daysAgo(10), ageLimitDays: 7, now: now))
    }

    func testQueueItemNotExpiredWithinAgeLimit() {
        XCTAssertFalse(ExpirationLogic.isExpired(addedAt: daysAgo(3), ageLimitDays: 7, now: now))
    }

    func testRecentlyExpiredPurgesAfterSevenDays() {
        XCTAssertTrue(ExpirationLogic.shouldPurge(expiredAt: daysAgo(8), now: now))
        XCTAssertFalse(ExpirationLogic.shouldPurge(expiredAt: daysAgo(6), now: now))
    }

    // MARK: DownloadGate (Wi-Fi)

    func testDownloadAllowedWhenNotWifiOnly() {
        XCTAssertTrue(DownloadGate.allowed(wifiOnly: false, isOnWifi: false))
    }

    func testDownloadBlockedWhenWifiOnlyAndNotOnWifi() {
        XCTAssertFalse(DownloadGate.allowed(wifiOnly: true, isOnWifi: false))
    }

    func testDownloadAllowedWhenWifiOnlyAndOnWifi() {
        XCTAssertTrue(DownloadGate.allowed(wifiOnly: true, isOnWifi: true))
    }
}
