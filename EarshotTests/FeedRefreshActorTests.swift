import XCTest
import SwiftData
import os
@testable import Earshot

@Model
private final class SaveFailureProbe {
    var key: String
    var payload: String

    init(key: String, payload: String) {
        self.key = key
        self.payload = payload
    }
}

/// Proves the whole-library refresh writes happen on ``FeedRefreshActor``'s own
/// background context (not the caller's main context) while still producing the
/// same inserted/deduped episodes — the threading fix for VoiceOver sluggishness
/// during a large refresh (#382). Drives the `@ModelActor` directly via its
/// container, then asserts by reading the store through a *fresh, independent*
/// `ModelContext`.
@MainActor
final class FeedRefreshActorTests: XCTestCase {

    func testSwiftDataContextStateAfterRealSaveDisabledFailure() throws {
        let schema = Schema([SaveFailureProbe.self])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swiftdata-save-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "probe.store")
        var seedContainer: ModelContainer? = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: storeURL, cloudKitDatabase: .none
            )
        )
        _ = seedContainer?.mainContext
        seedContainer = nil
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: storeURL, allowsSave: false, cloudKitDatabase: .none
            )
        )
        let context = ModelContext(container)
        context.insert(SaveFailureProbe(key: "valid", payload: "valid"))

        let firstError: Error
        do {
            try context.save()
            return XCTFail("Expected save to fail")
        } catch {
            firstError = error
        }
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(context.insertedModelsArray.count, 1)
        XCTAssertEqual(context.changedModelsArray.count, 0)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<SaveFailureProbe>()), 0
        )

        let secondError: Error
        do {
            try context.save()
            return XCTFail("Expected retry to fail")
        } catch {
            secondError = error
        }
        context.insert(SaveFailureProbe(key: "later-valid", payload: "later-valid"))
        let thirdError: Error
        do {
            try context.save()
            return XCTFail("Expected later save to fail")
        } catch {
            thirdError = error
        }

        XCTAssertEqual((firstError as NSError).domain, (secondError as NSError).domain)
        XCTAssertEqual((firstError as NSError).code, (secondError as NSError).code)
        XCTAssertEqual((firstError as NSError).domain, (thirdError as NSError).domain)
        XCTAssertEqual((firstError as NSError).code, (thirdError as NSError).code)
        XCTAssertEqual(context.insertedModelsArray.count, 2)
        XCTAssertEqual(context.changedModelsArray.count, 0)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<SaveFailureProbe>()), 0
        )
    }

    func testRefreshAllReportsFailedFeedsWhenEveryBatchSaveFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "refresh-all-save-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "earshot.store")
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_780_000_000)
        var feeds: [String: ParsedFeed] = [:]

        do {
            let writable = try makeOnDiskEarshotContainer(at: storeURL, allowsSave: true)
            let context = ModelContext(writable)
            for index in 0..<15 {
                let feedURL = "https://example.com/feed-\(index).xml"
                let podcast = Podcast(
                    feedURL: feedURL, title: "Show \(index)", lastSeenPubDate: oldDate
                )
                let old = Episode(
                    guid: "old-\(index)", title: "Old \(index)",
                    audioURL: "https://example.com/old-\(index).mp3", pubDate: oldDate
                )
                old.podcast = podcast
                context.insert(podcast)
                context.insert(old)
                feeds[feedURL] = parsedFeed([
                    parsedEpisode("old-\(index)", oldDate),
                    parsedEpisode("new-\(index)", newDate),
                ])
            }
            try context.save()
        }

        let readOnly = try makeOnDiskEarshotContainer(at: storeURL, allowsSave: false)
        let actor = FeedRefreshActor(modelContainer: readOnly)
        let report = await actor.refreshAllReport(
            feed: OutOfOrderDistinctFeed(feeds: feeds),
            autoQueueEnabled: false,
            trigger: .manualToolbar,
            isCancelled: { false },
            onProgress: { _, _ in }
        )
        let durable = try ModelContext(readOnly).fetch(FetchDescriptor<Episode>())

        XCTAssertEqual(report.results.count, 0)
        XCTAssertEqual(report.failed, 15)
        XCTAssertEqual(report.intendedInsertions, 15)
        XCTAssertEqual(report.durableInsertions, 0)
        XCTAssertEqual(durable.filter { $0.guid.hasPrefix("old-") }.count, 15)
        XCTAssertEqual(durable.filter { $0.guid.hasPrefix("new-") }.count, 0)
        let hasPendingChanges = await actor.hasPendingChangesForTesting()
        XCTAssertFalse(hasPendingChanges)
    }

    func testDuplicateIdentityGraphDoesNotPoisonUnrelatedRefreshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "identity-repair-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "earshot.store")
        let container = try makeOnDiskEarshotContainer(at: storeURL, allowsSave: true)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_780_000_000)
        let duplicateFeedURL = "https://example.com/duplicate.xml"
        var feeds: [String: ParsedFeed] = [:]

        do {
            let context = ModelContext(container)
            let winner = Podcast(
                feedURL: duplicateFeedURL, title: "Winner",
                createdAt: Date(timeIntervalSince1970: 1), lastSeenPubDate: oldDate
            )
            let loser = Podcast(
                feedURL: duplicateFeedURL, title: "Loser",
                createdAt: Date(timeIntervalSince1970: 2), lastSeenPubDate: oldDate
            )
            context.insert(winner)
            context.insert(loser)
            for index in 0..<2 {
                let episode = Episode(
                    guid: "duplicate-guid", title: "Duplicate \(index)",
                    audioURL: "https://example.com/duplicate-\(index).mp3", pubDate: oldDate
                )
                episode.podcast = winner
                context.insert(episode)
            }
            let crossPodcast = Episode(
                guid: "duplicate-guid", title: "Cross podcast",
                audioURL: "https://example.com/cross.mp3", pubDate: oldDate
            )
            crossPodcast.podcast = loser
            context.insert(crossPodcast)
            feeds[duplicateFeedURL] = parsedFeed([parsedEpisode("duplicate-guid", newDate)])

            for index in 0..<4 {
                let feedURL = "https://example.com/healthy-\(index).xml"
                context.insert(Podcast(
                    feedURL: feedURL, title: "Healthy \(index)", lastSeenPubDate: oldDate
                ))
                feeds[feedURL] = parsedFeed([parsedEpisode("healthy-new-\(index)", newDate)])
            }
            try context.save()
        }

        let results = await FeedRefreshActor(modelContainer: container).refreshAll(
            feed: OutOfOrderDistinctFeed(feeds: feeds),
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { _, _ in }
        )
        let durable = try ModelContext(container).fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(durable.filter { $0.guid.hasPrefix("healthy-new-") }.count, 4)
        XCTAssertEqual(durable.filter { $0.guid == "duplicate-guid" }.count, 2)
    }

    private func makeOnDiskEarshotContainer(
        at storeURL: URL, allowsSave: Bool
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV11.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: storeURL, allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        )
    }

    private func cleanContainer() -> ModelContainer {
        _ = TestStore.freshContext() // wipe the shared in-memory store first
        return TestStore.container
    }

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    private func parsedEpisode(
        _ guid: String, _ date: Date, audioURL: String? = nil
    ) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: audioURL ?? "https://x/\(guid).mp3",
            description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func parsedEpisode(_ guid: String, _ date: Date, audioURL: String) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: audioURL,
            description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func undatedEpisode(_ guid: String) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            description: nil, pubDate: nil, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func parsedFeed(_ episodes: [ParsedEpisode]) -> ParsedFeed {
        ParsedFeed(
            title: "Show", artworkURL: nil, description: nil, author: "Host",
            websiteURL: nil, language: nil, category: nil, episodes: episodes
        )
    }

    /// Reads the store through a brand-new context, so the assertion can only
    /// pass if the actor persisted to the store (not to some caller's cached
    /// object graph).
    private func episodes(_ container: ModelContainer) throws -> [Episode] {
        try ModelContext(container).fetch(FetchDescriptor<Episode>())
    }

    /// Regression for the build-177 device trace: constructing a `@ModelActor`
    /// from this `@MainActor` test must not pin its ModelContext work to the main
    /// thread. The production repository uses this same factory at every call
    /// site.
    func testBackgroundFactoryDoesNotExecuteOnMainThread() async {
        let actor = await FeedRefreshActor.makeBackground(modelContainer: cleanContainer())
        let isOnMainThread = await actor.isExecutingOnMainThreadForTesting()

        XCTAssertFalse(isOnMainThread)
    }

    /// A new subscription has its backlog pre-dismissed (so refresh of an existing
    /// podcast must add only genuinely-new episodes). Seed one directly with a
    /// mark already set, then refresh on the actor and read from a fresh context.
    func testActorRefreshInsertsNewEpisodesOffTheCallerContext() async throws {
        let container = cleanContainer()
        // Seed a subscribed podcast (mark = d1) with episode "a" via a context we
        // then DISCARD, so the actor can't be reusing our object graph.
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.inboxDismissed = true
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)]))
        let outcome = try await actor.refreshOne(
            feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false
        )

        XCTAssertEqual(outcome?.added, 2, "b and c are new; a is deduped by guid")
        XCTAssertEqual(outcome?.newestNewEpisodeGUID, "c")
        // The store now holds all three, read through an independent context.
        let stored = try episodes(container)
        XCTAssertEqual(Set(stored.map(\.guid)), ["a", "b", "c"])
    }

    /// Deduplication: refreshing with the same feed twice never double-inserts.
    func testActorRefreshIsIdempotentByGUID() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            seedCtx.insert(Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1))
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))

        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)
        let second = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        XCTAssertEqual(second?.added, 0, "Second pass finds nothing new")
        XCTAssertEqual(try episodes(container).count, 2, "No duplicate rows")
    }

    func testFilterUsesSeparateTenKeptAndTenFilteredInsertionBudgets() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/split-budget.xml"
        do {
            let context = ModelContext(container)
            let podcast = Podcast(feedURL: feedURL, title: "Segments", lastSeenPubDate: d1)
            let old = Episode(guid: "old", title: "Old", audioURL: "https://x/old.mp3", pubDate: d1)
            old.podcast = podcast
            context.insert(podcast)
            context.insert(old)
            let configuration = EpisodeFilterConfiguration(
                isEnabled: true,
                mode: .filterMatching,
                rules: [EpisodeFilterRule(name: "Segments", titlePattern: "Segment*")]
            )
            try AppSettingIdentity.setValue(
                EpisodeFilterCodec.encode(configuration),
                for: SettingsKey.episodeFilterConfiguration(feedURL: feedURL),
                in: context
            )
            try context.save()
        }
        let items = (1...15).flatMap { index -> [ParsedEpisode] in
            let date = d1.addingTimeInterval(Double(index * 100))
            var kept = parsedEpisode("kept-\(index)", date)
            kept.title = "Full show \(index)"
            var filtered = parsedEpisode("filtered-\(index)", date.addingTimeInterval(1))
            filtered.title = "Segment \(index)"
            return [kept, filtered]
        }

        let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(items)),
            autoQueueEnabled: false
        )
        let stored = try episodes(container)

        XCTAssertEqual(outcome?.added, 10)
        XCTAssertEqual(outcome?.filteredCount, 10)
        XCTAssertEqual(outcome?.keptOverflowCount, 5)
        XCTAssertEqual(outcome?.filteredOverflowCount, 5)
        XCTAssertEqual(stored.filter { $0.guid.hasPrefix("kept-") }.count, 10)
        XCTAssertEqual(stored.filter { $0.guid.hasPrefix("filtered-") }.count, 10)
        XCTAssertTrue(
            stored.filter { $0.guid.hasPrefix("filtered-") }.allSatisfy(\.inboxDismissed)
        )
        XCTAssertTrue(
            stored.filter { $0.guid.hasPrefix("kept-") }.allSatisfy { !$0.inboxDismissed }
        )
    }

    func testTwentyFiveMixedCandidatesSelectsKeptBeforeApplyingBudgets() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/twenty-five-filtered.xml"
        do {
            let context = ModelContext(container)
            let podcast = Podcast(feedURL: feedURL, title: "Twenty five", lastSeenPubDate: d1)
            let old = Episode(
                guid: "old", title: "Old", audioURL: "https://x/old.mp3", pubDate: d1
            )
            old.podcast = podcast
            context.insert(podcast)
            context.insert(old)
            let configuration = EpisodeFilterConfiguration(
                isEnabled: true,
                mode: .filterMatching,
                rules: [EpisodeFilterRule(name: "Segments", titlePattern: "Segment*")]
            )
            try AppSettingIdentity.setValue(
                EpisodeFilterCodec.encode(configuration),
                for: SettingsKey.episodeFilterConfiguration(feedURL: feedURL),
                in: context
            )
            try context.save()
        }
        let catalog = (1...25).map { index -> ParsedEpisode in
            var item = parsedEpisode("candidate-\(index)", d1.addingTimeInterval(Double(index)))
            // The five wanted episodes are oldest and would all fall outside the
            // old newest-ten window if matching happened after prefixing.
            item.title = index <= 5 ? "Full show \(index)" : "Segment \(index)"
            return item
        }

        let optionalOutcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(catalog)),
            autoQueueEnabled: false
        )
        let outcome = try XCTUnwrap(optionalOutcome)
        let stored = try episodes(container)

        XCTAssertEqual(outcome.added, 5)
        XCTAssertEqual(outcome.filteredCount, 10)
        XCTAssertEqual(outcome.keptOverflowCount, 0)
        XCTAssertEqual(outcome.filteredOverflowCount, 10)
        XCTAssertEqual(
            Set(stored.filter { !$0.inboxDismissed && $0.guid.hasPrefix("candidate-") }.map(\.guid)),
            Set((1...5).map { "candidate-\($0)" })
        )
        XCTAssertEqual(stored.filter { $0.guid.hasPrefix("candidate-") }.count, 15)
    }

    func testKeepMatchingAllFilteredRecordsRuntimeSafetyWarning() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/runtime-guard.xml"
        do {
            let context = ModelContext(container)
            let podcast = Podcast(feedURL: feedURL, title: "Host migrated", lastSeenPubDate: d1)
            let old = Episode(guid: "old", title: "Old", audioURL: "https://x/old.mp3", pubDate: d1)
            old.podcast = podcast
            context.insert(podcast)
            context.insert(old)
            let configuration = EpisodeFilterConfiguration(
                isEnabled: true,
                mode: .keepMatching,
                rules: [EpisodeFilterRule(name: "Long shows", minimumDurationMinutes: 45)]
            )
            try AppSettingIdentity.setValue(
                EpisodeFilterCodec.encode(configuration),
                for: SettingsKey.episodeFilterConfiguration(feedURL: feedURL),
                in: context
            )
            try context.save()
        }
        let candidates = (1...3).map { parsedEpisode("missing-duration-\($0)", d1.addingTimeInterval(Double($0))) }

        let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(candidates)),
            autoQueueEnabled: false
        )
        let context = ModelContext(container)
        let stored = try context.fetch(FetchDescriptor<Episode>())

        XCTAssertEqual(outcome?.added, 0)
        XCTAssertEqual(outcome?.filteredCount, 3)
        XCTAssertTrue(outcome?.rejectedAllNewCandidates == true)
        XCTAssertTrue(stored.filter { $0.guid.hasPrefix("missing-duration-") }.allSatisfy(\.inboxDismissed))
        XCTAssertNotNil(
            LocalAppSettingIdentity.value(
                for: SettingsKey.episodeFilterSafetyWarning(feedURL: feedURL),
                in: context
            )
        )
    }

    func testBackgroundRefreshPersistsSafetyWarningReachableFromPodcastSettings() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/background-runtime-guard.xml"
        do {
            let context = ModelContext(container)
            let podcast = Podcast(feedURL: feedURL, title: "Background show", lastSeenPubDate: d1)
            let old = Episode(
                guid: "old", title: "Old", audioURL: "https://x/old.mp3", pubDate: d1
            )
            old.podcast = podcast
            context.insert(podcast)
            context.insert(old)
            let configuration = EpisodeFilterConfiguration(
                isEnabled: true,
                mode: .keepMatching,
                rules: [EpisodeFilterRule(name: "Full", titlePattern: "Full*")]
            )
            try AppSettingIdentity.setValue(
                EpisodeFilterCodec.encode(configuration),
                for: SettingsKey.episodeFilterConfiguration(feedURL: feedURL),
                in: context
            )
            try context.save()
        }
        var segment = parsedEpisode("segment", d2)
        segment.title = "Segment"

        let report = await FeedRefreshActor(modelContainer: container).refreshAllReport(
            feed: FakeFeed(parsedFeed([segment])),
            autoQueueEnabled: false,
            trigger: .backgroundTask,
            isCancelled: { false },
            onProgress: { _, _ in }
        )
        let settings = AppSettingsStore(context: ModelContext(container))

        XCTAssertTrue(report.results.first?.outcome.rejectedAllNewCandidates == true)
        XCTAssertTrue(settings.episodeFilterNeedsReview(forFeedURL: feedURL))
        XCTAssertNotNil(settings.episodeFilterSafetyWarning(forFeedURL: feedURL))
    }

    func testSyncedShellAlsoProtectsTenKeptSlotsFromFilteredSegments() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/synced-shell-filter.xml"
        do {
            let context = ModelContext(container)
            context.insert(Podcast(
                feedURL: feedURL,
                title: "Synced segments",
                lastSeenPubDate: d1
            ))
            let configuration = EpisodeFilterConfiguration(
                isEnabled: true,
                mode: .filterMatching,
                rules: [EpisodeFilterRule(name: "Segments", titlePattern: "Segment*")]
            )
            try AppSettingIdentity.setValue(
                EpisodeFilterCodec.encode(configuration),
                for: SettingsKey.episodeFilterConfiguration(feedURL: feedURL),
                in: context
            )
            try context.save()
        }
        let items = (1...12).flatMap { index -> [ParsedEpisode] in
            let date = d1.addingTimeInterval(Double(index * 100))
            var kept = parsedEpisode("shell-kept-\(index)", date)
            kept.title = "Full show \(index)"
            var filtered = parsedEpisode("shell-filtered-\(index)", date.addingTimeInterval(1))
            filtered.title = "Segment \(index)"
            return [kept, filtered]
        }

        let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(items)),
            autoQueueEnabled: false
        )
        let stored = try episodes(container)

        XCTAssertEqual(outcome?.added, 10)
        XCTAssertEqual(outcome?.filteredCount, 10)
        XCTAssertEqual(stored.filter { $0.guid.hasPrefix("shell-kept-") }.count, 10)
        XCTAssertEqual(stored.filter { $0.guid.hasPrefix("shell-filtered-") }.count, 10)
    }

    func testFilteredEpisodeNeverAutoQueuesWhileKeptEpisodeStillDoes() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/filtered-auto-queue.xml"
        do {
            let context = ModelContext(container)
            let podcast = Podcast(
                feedURL: feedURL,
                title: "Auto queue segments",
                autoQueue: true,
                lastSeenPubDate: d1
            )
            let old = Episode(guid: "old", title: "Old", audioURL: "https://x/old.mp3", pubDate: d1)
            old.podcast = podcast
            context.insert(podcast)
            context.insert(old)
            let configuration = EpisodeFilterConfiguration(
                isEnabled: true,
                mode: .filterMatching,
                rules: [EpisodeFilterRule(name: "Segments", titlePattern: "Segment*")]
            )
            try AppSettingIdentity.setValue(
                EpisodeFilterCodec.encode(configuration),
                for: SettingsKey.episodeFilterConfiguration(feedURL: feedURL),
                in: context
            )
            try context.save()
        }
        var kept = parsedEpisode("kept", d2)
        kept.title = "Full show"
        var filtered = parsedEpisode("filtered", d3)
        filtered.title = "Segment one"

        let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed([kept, filtered])),
            autoQueueEnabled: true
        )
        let stored = try episodes(container)
        let keptEpisode = try XCTUnwrap(stored.first { $0.guid == "kept" })
        let filteredEpisode = try XCTUnwrap(stored.first { $0.guid == "filtered" })

        XCTAssertEqual(outcome?.newEpisodeIDs.count, 1)
        XCTAssertEqual(keptEpisode.status, .inQueue)
        XCTAssertNotNil(keptEpisode.queueItem)
        XCTAssertTrue(keptEpisode.inboxDismissed)
        XCTAssertEqual(filteredEpisode.status, .newEpisode)
        XCTAssertNil(filteredEpisode.queueItem)
        XCTAssertTrue(filteredEpisode.inboxDismissed)
    }

    /// Regression for #778: two entries with the same GUID in one response must
    /// be collapsed before either unsaved row is inserted. Reversing their feed
    /// order selects the same canonical payload.
    func testActorRefreshDeduplicatesGUIDWithinSingleResponse() async throws {
        func refresh(with items: [ParsedEpisode]) async throws -> (Int, String) {
            let container = cleanContainer()
            let seedContext = ModelContext(container)
            seedContext.insert(Podcast(
                feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1
            ))
            try seedContext.save()

            let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
                feedURL: "https://x/feed.xml", feed: FakeFeed(parsedFeed(items)),
                autoQueueEnabled: false
            )
            let stored = try episodes(container)
            return (try XCTUnwrap(outcome).added, try XCTUnwrap(stored.first).audioURL)
        }

        let a = parsedEpisode("duplicate", d2, audioURL: "https://x/z.mp3")
        let b = parsedEpisode("duplicate", d2, audioURL: "https://x/a.mp3")
        let forward = try await refresh(with: [a, b])
        let reversed = try await refresh(with: [b, a])

        XCTAssertEqual(forward.0, 1)
        XCTAssertEqual(reversed.0, 1)
        XCTAssertEqual(forward.1, "https://x/a.mp3")
        XCTAssertEqual(reversed.1, forward.1, "Winner must not depend on feed item order")
    }

    /// A freshly-migrated shell (no episodes, no mark) backfills its whole catalog
    /// pre-dismissed and is flagged as a backfill (never notifies).
    func testActorBackfillsMigratedShellPreDismissed() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            seedCtx.insert(Podcast(feedURL: "https://x/feed.xml", title: "Shell"))
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))

        let outcome = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        XCTAssertTrue(outcome?.wasBackfill == true)
        let stored = try episodes(container)
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.inboxDismissed }, "Backlog pre-dismissed")
    }

    /// #778 covers migrated shells as well: their first full-catalog backfill
    /// must not persist duplicate GUIDs from one malformed feed response.
    func testActorBackfillDeduplicatesGUIDWithinSingleResponse() async throws {
        let container = cleanContainer()
        let seedContext = ModelContext(container)
        seedContext.insert(Podcast(feedURL: "https://x/feed.xml", title: "Shell"))
        try seedContext.save()

        let first = parsedEpisode("duplicate", d1, audioURL: "https://x/old.mp3")
        let newer = parsedEpisode("duplicate", d2, audioURL: "https://x/newer.mp3")
        let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: "https://x/feed.xml", feed: FakeFeed(parsedFeed([first, newer])),
            autoQueueEnabled: false
        )

        let stored = try episodes(container)
        XCTAssertTrue(outcome?.wasBackfill == true)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.guid, "duplicate")
        XCTAssertEqual(stored.first?.audioURL, "https://x/newer.mp3")
    }

    /// A compact CloudKit subscription carries a feed high-water mark but no
    /// episode relationships. Its first local refresh must create a bounded,
    /// useful catalog without treating pre-mark history as newly published.
    func testActorSeedsSyncedShellWithTenRecentEpisodes() async throws {
        let container = cleanContainer()
        let mark = Date(timeIntervalSince1970: 1_700_020_000)
        do {
            let seedContext = ModelContext(container)
            seedContext.insert(Podcast(
                feedURL: "https://x/feed.xml", title: "Cloud shell",
                lastSeenPubDate: mark
            ))
            try seedContext.save()
        }
        let items = (1...25).map { index in
            parsedEpisode(
                "episode-\(index)",
                Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 1_000))
            )
        }

        let outcome = try await FeedRefreshActor(modelContainer: container).refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed(items)),
            autoQueueEnabled: false
        )

        let stored = try episodes(container)
        XCTAssertEqual(stored.count, 10, "A synced shell seeds a bounded recent catalog")
        XCTAssertEqual(
            Set(stored.map(\.guid)),
            Set((16...25).map { "episode-\($0)" })
        )
        XCTAssertEqual(outcome?.added, 5, "Only episodes newer than the transferred mark are new")
        XCTAssertEqual(
            Set(stored.filter { !$0.inboxDismissed }.map(\.guid)),
            Set((21...25).map { "episode-\($0)" })
        )
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Podcast>()).first?.lastSeenPubDate,
            Date(timeIntervalSince1970: 1_700_025_000)
        )
    }

    // MARK: subscribe (off the caller's context)

    /// Subscribing inserts the podcast + every episode on the actor's OWN
    /// background context (read back via a fresh independent context), with the
    /// backlog dismissed when the seed count is 0 and the high-water mark seeded to
    /// the newest non-future pub date (#296).
    func testActorSubscribeInsertsPodcastAndBacklogOffTheCallerContext() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))

        // seed 0 = dismiss the whole backlog (the legacy behavior this asserts).
        let result = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 0)

        XCTAssertFalse(result.alreadySubscribed)
        XCTAssertEqual(result.episodeIDs.count, 2)

        // Read back through an independent context: the actor persisted to the store.
        let freshCtx = ModelContext(container)
        let podcasts = try freshCtx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        let podcast = try XCTUnwrap(podcasts.first)
        XCTAssertEqual(podcast.title, "Show")
        XCTAssertEqual(podcast.author, "Host")
        XCTAssertEqual(podcast.episodes?.count, 2)
        XCTAssertTrue((podcast.episodes ?? []).allSatisfy { $0.inboxDismissed }, "Seed 0 dismisses the whole backlog")
        XCTAssertEqual(podcast.lastSeenPubDate, d2, "Mark seeded to newest pub date")
        XCTAssertNotNil(podcast.refreshedAt)
    }

    /// #778 also covers the fresh-subscription path that produced the historical
    /// Glenn Beck duplicates: one response GUID persists exactly one row.
    func testActorSubscribeDeduplicatesGUIDWithinSingleResponse() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let first = parsedEpisode("duplicate", d1, audioURL: "https://x/z.mp3")
        let newer = parsedEpisode("duplicate", d2, audioURL: "https://x/newer.mp3")

        let result = try await actor.subscribe(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([first, newer])),
            inboxSeedCount: 0
        )

        let stored = try episodes(container)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.guid, "duplicate")
        XCTAssertEqual(stored.first?.audioURL, "https://x/newer.mp3")
        XCTAssertEqual(result.episodeIDs.count, 1)
    }

    /// Subscribing with a seed count of N keeps the newest N non-future episodes in
    /// the inbox (`status == .newEpisode && !inboxDismissed`) and dismisses the
    /// older backlog — the core fix for the empty-inbox-on-subscribe parity gap.
    func testActorSubscribeSeedsNewestNIntoInbox() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        // Five episodes a<b<c<d<e by pub date; seed 2 keeps d and e.
        let d4 = d3.addingTimeInterval(100_000)
        let d5 = d4.addingTimeInterval(100_000)
        let fetcher = FakeFeed(parsedFeed([
            parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3),
            parsedEpisode("d", d4), parsedEpisode("e", d5),
        ]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 2)

        let stored = try episodes(container)
        let seeded = stored.filter { !$0.inboxDismissed }
        XCTAssertEqual(Set(seeded.map(\.guid)), ["d", "e"], "Newest 2 seeded into inbox")
        XCTAssertTrue(seeded.allSatisfy { $0.status == .newEpisode }, "Seeded episodes are newEpisode")
        let dismissed = stored.filter { $0.inboxDismissed }
        XCTAssertEqual(Set(dismissed.map(\.guid)), ["a", "b", "c"], "Older backlog dismissed")
    }

    /// A seed count of -1 ("All") seeds the entire non-future backlog into the inbox.
    func testActorSubscribeSeedAllSeedsWholeBacklog() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: -1)

        let stored = try episodes(container)
        XCTAssertTrue(stored.allSatisfy { !$0.inboxDismissed && $0.status == .newEpisode }, "Whole backlog seeded")
    }

    /// Future-dated episodes are never seeded into the inbox even when the seed
    /// count would otherwise include them (#296). With seed 3 and a feed of one
    /// real + one future episode, only the real one surfaces.
    func testActorSubscribeNeverSeedsFutureDatedEpisode() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("future", future)]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)

        let stored = try episodes(container)
        let seeded = stored.filter { !$0.inboxDismissed }
        XCTAssertEqual(Set(seeded.map(\.guid)), ["a"], "Only the non-future episode is seeded")
        let futureEp = try XCTUnwrap(stored.first { $0.guid == "future" })
        XCTAssertTrue(futureEp.inboxDismissed, "Future-dated episode stays dismissed")
    }

    /// Subscribing to an already-subscribed feed URL is idempotent: no fetch, no
    /// new rows, `alreadySubscribed == true`, and the existing podcast ID returned.
    func testActorSubscribeIsIdempotentByFeedURL() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))

        let first = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)
        let second = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)

        XCTAssertFalse(first.alreadySubscribed)
        XCTAssertTrue(second.alreadySubscribed)
        XCTAssertEqual(first.podcastID, second.podcastID)
        XCTAssertTrue(second.episodeIDs.isEmpty, "Idempotent return inserts nothing")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try episodes(container).count, 1, "No duplicate episode rows")
    }

    /// A future-dated episode must not advance the high-water mark past real
    /// non-future episodes on subscribe (#296).
    func testActorSubscribeFutureDatedEpisodeDoesNotAdvanceMark() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("future", future)]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)

        let podcast = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.lastSeenPubDate, d1, "Mark is newest NON-future date, not the future one")
    }

    // MARK: republished same-guid episodes (#397)

    /// A republished episode (same guid, newer pubDate) that is unplayed and not
    /// queued is re-surfaced: status flips back to `.newEpisode`, `inboxDismissed`
    /// clears, and the stored `pubDate` advances to the new value.
    func testActorRefreshResurfacesRepublishedUnplayedEpisode() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.status = .newEpisode
            a.inboxDismissed = true // previously read/dismissed
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d3)])) // republished, newer pubDate
        let outcome = try await actor.refreshOne(
            feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false
        )

        let stored = try episodes(container)
        let a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d3, "pubDate advances to the republished value")
        XCTAssertEqual(a.status, .newEpisode)
        XCTAssertFalse(a.inboxDismissed, "Re-surfaced into the inbox")
        XCTAssertEqual(outcome?.added, 0, "Republish is not counted as a new episode")
        XCTAssertNil(outcome?.newestNewEpisodeGUID, "Republish never triggers the notification path")
    }

    /// A played episode is never re-surfaced by a republish, even with a newer
    /// pubDate — its pubDate and status are left untouched.
    func testActorRefreshDoesNotResurfacePlayedEpisode() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.status = .played
            a.inboxDismissed = true
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d3)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        let stored = try episodes(container)
        let a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d1, "Played episode's pubDate is untouched")
        XCTAssertEqual(a.status, .played, "Played status is untouched")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")
    }

    /// A queued episode is never re-surfaced by a republish, even with a newer
    /// pubDate and unplayed status.
    func testActorRefreshDoesNotResurfaceQueuedEpisode() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.status = .inQueue
            a.inboxDismissed = true
            let queueItem = QueueItem(episode: a, position: 0)
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            seedCtx.insert(queueItem)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d3)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        let stored = try episodes(container)
        let a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d1, "Queued episode's pubDate is untouched")
        XCTAssertNotNil(a.queueItem, "Still queued")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")
    }

    /// A same-guid item whose pubDate is NOT newer than the stored value (or is
    /// future-dated) leaves the existing episode untouched.
    func testActorRefreshIgnoresNonNewerOrFutureDatedRepublish() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d2)
            a.podcast = podcast
            a.status = .newEpisode
            a.inboxDismissed = true
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        // Same guid with an OLDER pubDate (d1 < d2) — not newer, so no change.
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)
        var stored = try episodes(container)
        var a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d2, "Older pubDate does not overwrite the stored value")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")

        // Same guid with a FUTURE pubDate — never re-surfaced (#296 guard).
        let futureFetcher = FakeFeed(parsedFeed([parsedEpisode("a", future)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: futureFetcher, autoQueueEnabled: false)
        stored = try episodes(container)
        a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d2, "Future-dated republish does not overwrite the stored value")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")
    }

    /// `refreshAll` walks every subscription and reports progress, persisting to
    /// the store readable from a fresh context.
    func testActorRefreshAllProcessesEveryFeedAndPersists() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            for i in 0..<3 {
                seedCtx.insert(Podcast(feedURL: "https://x/feed\(i).xml", title: "Show \(i)", lastSeenPubDate: d1))
            }
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))
        let recorder = ProgressBox()

        let results = await actor.refreshAll(
            feed: fetcher,
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { completed, total in
                recorder.calls += 1
                recorder.lastCompleted = completed
                recorder.lastTotal = total
            }
        )

        XCTAssertEqual(results.count, 3, "One result per subscription")
        XCTAssertEqual(recorder.calls, 3)
        XCTAssertEqual(recorder.lastCompleted, 3)
        XCTAssertEqual(recorder.lastTotal, 3)
        // Each of the three feeds gained episode "b"; read via a fresh context.
        XCTAssertEqual(try episodes(container).filter { $0.guid == "b" }.count, 3)
    }

    /// A failed first-content checkpoint must be discarded before later feeds
    /// are applied. SwiftData otherwise leaves the failed graph dirty and every
    /// later save retries it.
    func testActorRefreshAllRollsBackFailedBatchAndLaterBatchPersists() async throws {
        let container = cleanContainer()
        do {
            let seedContext = ModelContext(container)
            for index in 0..<15 {
                let podcast = Podcast(
                    feedURL: "https://x/rollback-\(index).xml",
                    title: "Show \(index)",
                    lastSeenPubDate: d1
                )
                let oldEpisode = Episode(
                    guid: "old", title: "Old", audioURL: "https://x/old.mp3", pubDate: d1
                )
                oldEpisode.podcast = podcast
                seedContext.insert(podcast)
                seedContext.insert(oldEpisode)
            }
            try seedContext.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        await actor.forceNextSaveFailureForTesting()

        let report = await actor.refreshAllReport(
            feed: FakeFeed(parsedFeed([parsedEpisode("new", d2)])),
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { _, _ in }
        )

        let durableNewEpisodes = try episodes(container).filter { $0.guid == "new" }
        let hasPendingChanges = await actor.hasPendingChangesForTesting()
        XCTAssertEqual(durableNewEpisodes.count, 14, "Only later successful checkpoints persist")
        XCTAssertFalse(hasPendingChanges)
        XCTAssertEqual(report.results.count, 14, "Unsaved feeds must not be reported as successful")
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.reason, "Could not save refresh changes.")
        XCTAssertEqual(report.intendedInsertions, 15)
        XCTAssertEqual(report.durableInsertions, 14)
    }

    /// Whole-library refresh opens its three-request window immediately and never
    /// exceeds it.
    func testActorRefreshAllBoundsNetworkConcurrencyAtThree() async throws {
        let container = cleanContainer()
        do {
            let seedContext = ModelContext(container)
            for index in 0..<7 {
                seedContext.insert(Podcast(
                    feedURL: "https://x/feed\(index).xml",
                    title: "Show \(index)",
                    lastSeenPubDate: d1
                ))
            }
            try seedContext.save()
        }
        let fetcher = RefreshConcurrencyFeed(parsedFeed([parsedEpisode("a", d1)]))

        let results = await FeedRefreshActor(modelContainer: container).refreshAll(
            feed: fetcher,
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { _, _ in }
        )

        let maximumActiveFetches = await fetcher.maximumActiveFetches()
        XCTAssertEqual(results.count, 7)
        XCTAssertEqual(maximumActiveFetches, 3)
    }

    func testActorRefreshFailureReportsPodcastTitleAndReason() async throws {
        final class FailingFeed: FeedFetching, @unchecked Sendable {
            func fetch(_ urlString: String) async throws -> ParsedFeed {
                throw URLError(.timedOut)
            }
        }
        let container = cleanContainer()
        let context = ModelContext(container)
        context.insert(Podcast(
            feedURL: "https://example.com/failing.xml",
            title: "The Failing Show",
            lastSeenPubDate: d1
        ))
        try context.save()

        let report = await FeedRefreshActor(modelContainer: container).refreshAllReport(
            feed: FailingFeed(),
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { _, _ in }
        )

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.failures, [FeedRefreshFailure(
            feedURL: "https://example.com/failing.xml",
            podcastTitle: "The Failing Show",
            reason: "Could not download or read this feed."
        )])
    }

    func testRollingWindowStartsNextFetchWithoutWaitingForSlowSiblings() async throws {
        let container = cleanContainer()
        do {
            let context = ModelContext(container)
            for index in 0..<6 {
                context.insert(Podcast(
                    feedURL: "https://x/rolling-\(index).xml",
                    title: "Rolling \(index)",
                    lastSeenPubDate: d1
                ))
            }
            try context.save()
        }
        let fetcher = RollingWindowProbeFeed(parsedFeed([parsedEpisode("existing", d1)]))
        let refresh = Task { @concurrent in
            await FeedRefreshActor(modelContainer: container).refreshAll(
                feed: fetcher,
                autoQueueEnabled: false,
                isCancelled: { false },
                onProgress: { _, _ in }
            )
        }

        var startedFifth = false
        for _ in 0..<100 {
            if await fetcher.fetchCount() >= 5 {
                startedFifth = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await fetcher.releaseBlockedFetches()
        let results = await refresh.value

        XCTAssertTrue(
            startedFifth,
            "A completed slot should start feed five while feeds two and three remain slow"
        )
        XCTAssertEqual(results.count, 6)
    }

    func testNotModifiedMarksRefreshedWithoutEpisodeMutation() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/not-modified.xml"
        do {
            let context = ModelContext(container)
            let podcast = Podcast(
                feedURL: feedURL,
                title: "Unchanged",
                lastSeenPubDate: d1
            )
            let episode = Episode(
                guid: "existing",
                title: "Existing",
                audioURL: "https://x/existing.mp3",
                pubDate: d1
            )
            episode.podcast = podcast
            context.insert(podcast)
            context.insert(episode)
            try FeedRefreshValidatorStore.set(
                FeedHTTPValidators(etag: "\"old\"", lastModified: nil, representationURL: nil),
                feedURL: feedURL,
                in: context
            )
            try context.save()
        }
        let replacement = FeedHTTPValidators(
            etag: "\"confirmed\"",
            lastModified: "today",
            representationURL: feedURL
        )

        let report = await FeedRefreshActor(modelContainer: container).refreshAllReport(
            feed: NotModifiedFeed(validators: replacement),
            autoQueueEnabled: false,
            trigger: .backgroundTask,
            isCancelled: { false },
            onProgress: { _, _ in }
        )
        let context = ModelContext(container)
        let localState = try context.fetch(FetchDescriptor<LocalPodcastState>())

        XCTAssertEqual(report.results.count, 1)
        XCTAssertTrue(report.results[0].wasNotModified)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertNotNil(localState.first?.refreshedAt)
        XCTAssertEqual(
            FeedRefreshValidatorStore.validators(feedURL: feedURL, in: context),
            replacement
        )
    }

    func testActorRefreshAllSurfacesFirstDurableBatchBeforeCompletion() async throws {
        let container = cleanContainer()
        let urls = (0..<12).map { "https://x/feed\($0).xml" }
        do {
            let seedContext = ModelContext(container)
            for (index, url) in urls.enumerated() {
                seedContext.insert(Podcast(
                    feedURL: url,
                    title: "Show \(index)",
                    lastSeenPubDate: d1
                ))
            }
            try seedContext.save()
        }
        let feeds = Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            (url, parsedFeed([parsedEpisode("new-\(index)", d2)]))
        })
        var completed = 0
        var inboxChangeProgress: [Int] = []

        let report = await FeedRefreshActor(modelContainer: container).refreshAllReport(
            feed: OutOfOrderDistinctFeed(feeds: feeds),
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { current, _ in completed = current },
            onInboxChange: { inboxChangeProgress.append(completed) }
        )

        XCTAssertEqual(report.durableInsertions, urls.count)
        XCTAssertEqual(inboxChangeProgress.count, 2)
        XCTAssertLessThan(inboxChangeProgress[0], urls.count)
        XCTAssertEqual(inboxChangeProgress[1], urls.count)
        XCTAssertEqual(try episodes(container).count, urls.count)
    }

    /// Each concurrent response is applied to the podcast identified by the
    /// URL captured in that request, even when later requests finish first.
    func testActorRefreshAllCorrelatesOutOfOrderResultsByRequestedFeedURL() async throws {
        let container = cleanContainer()
        let urls = (0..<4).map { "https://x/feed\($0).xml" }
        do {
            let seedContext = ModelContext(container)
            for (index, url) in urls.enumerated() {
                let podcast = Podcast(feedURL: url, title: "Show \(index)", lastSeenPubDate: d1)
                let existing = parsedEpisode("old-\(index)", d1)
                let episode = Episode(
                    guid: existing.guid,
                    title: existing.title,
                    audioURL: existing.audioURL,
                    pubDate: existing.pubDate
                )
                episode.podcast = podcast
                seedContext.insert(podcast)
                seedContext.insert(episode)
            }
            try seedContext.save()
        }
        let feeds = Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            (url, parsedFeed([parsedEpisode("new-\(index)", d2)]))
        })

        _ = await FeedRefreshActor(modelContainer: container).refreshAll(
            feed: OutOfOrderDistinctFeed(feeds: feeds),
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { _, _ in }
        )

        let stored = try episodes(container)
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(
                stored.filter { $0.podcast?.feedURL == url }.map(\.guid).sorted(),
                ["new-\(index)", "old-\(index)"]
            )
        }
    }

    // MARK: subscribeAll (bulk OPML path)

    /// Bulk subscribe inserts every feed's podcast + backlog on the actor's own
    /// background context, returns one result per feed in input order, and reports
    /// progress with increasing completed counts up to total.
    func testActorSubscribeAllInsertsEveryFeedAndReportsProgress() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))
        let urls = (0..<12).map { "https://x/feed\($0).xml" } // > saveBatchSize (10) to exercise batching
        let recorder = ProgressBox()

        let results = await actor.subscribeAll(
            feedURLs: urls,
            feed: fetcher,
            inboxSeedCount: 3,
            onProgress: { completed, total, _ in
                recorder.calls += 1
                recorder.lastCompleted = completed
                recorder.lastTotal = total
            }
        )

        XCTAssertEqual(results.count, 12)
        XCTAssertTrue(results.allSatisfy { !$0.alreadySubscribed })
        XCTAssertEqual(recorder.calls, 12)
        XCTAssertEqual(recorder.lastCompleted, 12)
        XCTAssertEqual(recorder.lastTotal, 12)
        // Read back through a fresh context: all 12 podcasts persisted (batched saves).
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 12)
        XCTAssertEqual(try episodes(container).count, 24)
    }

    /// OPML bulk import persists only the newest ten rows immediately. Automatic
    /// refresh must not rebuild the older history and recreate the large inverse-
    /// relationship stall measured on the build-178 device.
    func testActorSubscribeAllAndRefreshKeepHistoricalBacklogBounded() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let catalog = (0..<25).map { index in
            parsedEpisode("episode-\(index)", d1.addingTimeInterval(Double(index)))
        }
        let fetcher = FakeFeed(parsedFeed(catalog))

        _ = await actor.subscribeAll(
            feedURLs: ["https://x/large.xml"], feed: fetcher, inboxSeedCount: 3
        )

        var stored = try episodes(container)
        XCTAssertEqual(stored.count, 10, "OPML import stores only the newest ten episodes")
        XCTAssertEqual(Set(stored.map(\.guid)), Set((15..<25).map { "episode-\($0)" }))

        _ = try await actor.refreshOne(
            feedURL: "https://x/large.xml", feed: fetcher, autoQueueEnabled: false
        )

        stored = try episodes(container)
        XCTAssertEqual(stored.count, 10, "Automatic refresh does not rebuild historical gaps")
        XCTAssertEqual(Set(stored.map(\.guid)), Set((15..<25).map { "episode-\($0)" }))
    }

    /// A device that has been offline can encounter more than ten genuinely-new
    /// publications in one response. Persist the newest ten only, but advance the
    /// durable high-water mark to the newest publication so the same backlog is
    /// not reconsidered on every subsequent automatic refresh.
    func testNoFilterGoldenStoresNewestTenOfTwentyFiveAndAdvancesMark() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/established-large.xml"
        let seedContext = ModelContext(container)
        let podcast = Podcast(feedURL: feedURL, title: "Established", lastSeenPubDate: d1)
        let existing = Episode(
            guid: "existing",
            title: "Existing",
            audioURL: "https://x/existing.mp3",
            pubDate: d1
        )
        existing.podcast = podcast
        seedContext.insert(podcast)
        seedContext.insert(existing)
        try seedContext.save()

        let catalog = (1...25).map { index in
            parsedEpisode("new-\(index)", d1.addingTimeInterval(Double(index)))
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let optionalOutcome = try await actor.refreshOne(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(catalog)),
            autoQueueEnabled: false
        )
        let outcome = try XCTUnwrap(optionalOutcome)

        let stored = try episodes(container)
        XCTAssertEqual(outcome.added, 10)
        XCTAssertEqual(outcome.filteredCount, 0)
        XCTAssertEqual(outcome.keptOverflowCount, 15)
        XCTAssertFalse(outcome.rejectedAllNewCandidates)
        XCTAssertEqual(stored.count, 11)
        XCTAssertEqual(
            Set(stored.map(\.guid)),
            Set(["existing"] + (16...25).map { "new-\($0)" })
        )
        let refreshedPodcast = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Podcast>()).first
        )
        XCTAssertEqual(refreshedPodcast.lastSeenPubDate, d1.addingTimeInterval(25))
        XCTAssertTrue(stored.filter { $0.guid.hasPrefix("new-") }.allSatisfy { !$0.inboxDismissed })
    }

    func testLoadOlderEpisodesPagesTenThenTenThenEndAndDismissesHistory() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/history.xml"
        let seed = ModelContext(container)
        let podcast = Podcast(
            feedURL: feedURL,
            title: "History",
            lastSeenPubDate: d1.addingTimeInterval(25)
        )
        for index in 16...25 {
            let episode = Episode(
                guid: "episode-\(index)",
                title: "Episode \(index)",
                audioURL: "https://x/\(index).mp3",
                pubDate: d1.addingTimeInterval(Double(index))
            )
            episode.podcast = podcast
            seed.insert(episode)
        }
        seed.insert(podcast)
        try seed.save()

        let catalog = (1...25).map { index in
            parsedEpisode("episode-\(index)", d1.addingTimeInterval(Double(index)))
        }
        let actor = FeedRefreshActor(modelContainer: container)

        let firstOptional = try await actor.loadOlderEpisodes(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(catalog)),
            pageSize: 10
        )
        let first = try XCTUnwrap(firstOptional)
        XCTAssertEqual(first, OlderEpisodePageOutcome(inserted: 10, hasMore: true))

        let secondOptional = try await actor.loadOlderEpisodes(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(catalog)),
            pageSize: 10
        )
        let second = try XCTUnwrap(secondOptional)
        XCTAssertEqual(second, OlderEpisodePageOutcome(inserted: 5, hasMore: false))

        let endOptional = try await actor.loadOlderEpisodes(
            feedURL: feedURL,
            feed: FakeFeed(parsedFeed(catalog)),
            pageSize: 10
        )
        let end = try XCTUnwrap(endOptional)
        XCTAssertEqual(end, OlderEpisodePageOutcome(inserted: 0, hasMore: false))
        let stored = try episodes(container)
        XCTAssertEqual(stored.count, 25)
        XCTAssertTrue(stored.filter { (1...15).contains(Int($0.guid.dropFirst(8)) ?? 0) }
            .allSatisfy(\.inboxDismissed))
    }

    func testLoadOlderEpisodesDeduplicatesGUIDAndHandlesMissingDates() async throws {
        let container = cleanContainer()
        let feedURL = "https://x/undated-history.xml"
        let seed = ModelContext(container)
        let podcast = Podcast(feedURL: feedURL, title: "Undated")
        let newest = Episode(
            guid: "newest",
            title: "Newest",
            audioURL: "https://x/newest.mp3",
            pubDate: d1
        )
        newest.podcast = podcast
        seed.insert(podcast)
        seed.insert(newest)
        try seed.save()

        var duplicate = undatedEpisode("old-a")
        duplicate.title = "Duplicate payload"
        let catalog = [
            parsedEpisode("newest", d1),
            undatedEpisode("old-a"),
            duplicate,
            undatedEpisode("old-b"),
        ]
        let outcomeOptional = try await FeedRefreshActor(modelContainer: container)
            .loadOlderEpisodes(
                feedURL: feedURL,
                feed: FakeFeed(parsedFeed(catalog)),
                pageSize: 10
            )
        let outcome = try XCTUnwrap(outcomeOptional)

        XCTAssertEqual(outcome, OlderEpisodePageOutcome(inserted: 2, hasMore: false))
        XCTAssertEqual(Set(try episodes(container).map(\.guid)), ["newest", "old-a", "old-b"])
    }

    func testLoadOlderEpisodesFailureCanRetryWithoutDuplicates() async throws {
        final class FailOnceFeed: FeedFetching, @unchecked Sendable {
            private let calls = OSAllocatedUnfairLock(initialState: 0)
            let parsed: ParsedFeed
            init(_ parsed: ParsedFeed) { self.parsed = parsed }
            func fetch(_ urlString: String) async throws -> ParsedFeed {
                let call = calls.withLock { value in
                    value += 1
                    return value
                }
                if call == 1 { throw URLError(.timedOut) }
                return parsed
            }
        }
        let container = cleanContainer()
        let feedURL = "https://x/retry-history.xml"
        let seed = ModelContext(container)
        seed.insert(Podcast(feedURL: feedURL, title: "Retry"))
        try seed.save()
        let feed = FailOnceFeed(parsedFeed([undatedEpisode("old")]))
        let actor = FeedRefreshActor(modelContainer: container)

        do {
            _ = try await actor.loadOlderEpisodes(feedURL: feedURL, feed: feed)
            XCTFail("Expected the first request to fail")
        } catch {
            XCTAssertEqual(try episodes(container).count, 0)
        }
        let retryOptional = try await actor.loadOlderEpisodes(
            feedURL: feedURL,
            feed: feed
        )
        let retry = try XCTUnwrap(retryOptional)
        XCTAssertEqual(retry, OlderEpisodePageOutcome(inserted: 1, hasMore: false))
        XCTAssertEqual(try episodes(container).map(\.guid), ["old"])
    }

    /// A feed that throws is logged and skipped — the rest of the batch still
    /// subscribes and the result array omits the failed feed.
    func testActorSubscribeAllSkipsFailingFeedAndContinues() async throws {
        final class FlakyFeed: FeedFetching, @unchecked Sendable {
            let good: ParsedFeed
            init(_ good: ParsedFeed) { self.good = good }
            func fetch(_ urlString: String) async throws -> ParsedFeed {
                if urlString.contains("bad") { throw URLError(.badServerResponse) }
                return good
            }
        }
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FlakyFeed(parsedFeed([parsedEpisode("a", d1)]))

        let results = await actor.subscribeAll(
            feedURLs: ["https://x/good1.xml", "https://x/bad.xml", "https://x/good2.xml"],
            feed: fetcher,
            inboxSeedCount: 3
        )

        XCTAssertEqual(results.count, 2, "Only the two good feeds resolved")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 2)
    }

    /// Idempotency: a URL already subscribed returns `alreadySubscribed` and never
    /// double-inserts.
    func testActorSubscribeAllIsIdempotentByFeedURL() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))

        _ = await actor.subscribeAll(feedURLs: ["https://x/feed.xml"], feed: fetcher, inboxSeedCount: 3)
        let second = await actor.subscribeAll(
            feedURLs: ["https://x/feed.xml", "https://x/feed2.xml"], feed: fetcher, inboxSeedCount: 3
        )

        let already = second.filter { $0.alreadySubscribed }
        XCTAssertEqual(already.count, 1, "The re-imported URL is already subscribed")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 2)
        XCTAssertEqual(try episodes(container).count, 2, "No duplicate episode rows")
    }

    /// Canonical variants resolve through the bulk identity map without another
    /// network request or a duplicate podcast row.
    func testActorSubscribeAllBulkIdentityMatchesCanonicalVariants() async throws {
        final class CountingFeed: FeedFetching, @unchecked Sendable {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let parsed: ParsedFeed
            init(_ parsed: ParsedFeed) { self.parsed = parsed }
            func fetch(_ urlString: String) async throws -> ParsedFeed {
                calls.withLock { $0 += 1 }
                return parsed
            }
        }
        let container = cleanContainer()
        let seed = ModelContext(container)
        seed.insert(Podcast(feedURL: "https://example.com/feed.xml", title: "Existing"))
        try seed.save()
        let fetcher = CountingFeed(parsedFeed([parsedEpisode("a", d1)]))
        let actor = FeedRefreshActor(modelContainer: container)

        let results = await actor.subscribeAll(
            feedURLs: [" HTTPS://EXAMPLE.COM:443/feed.xml#fragment "],
            feed: fetcher,
            inboxSeedCount: 3
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].alreadySubscribed)
        XCTAssertEqual(fetcher.calls.withLock { $0 }, 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Podcast>()), 1)
    }

    /// Cancellation preserves completed save batches; retrying the same input is
    /// idempotent and completes the remaining feeds without duplicate rows.
    func testActorSubscribeAllCancellationThenRetryIsIdempotent() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))
        let urls = (0..<24).map { "https://cancel\($0).example/feed" }
        let state = OSAllocatedUnfairLock(initialState: (progress: 0, cancelled: false))

        let partial = await actor.subscribeAll(
            feedURLs: urls,
            feed: fetcher,
            inboxSeedCount: 3,
            isCancelled: { state.withLock { $0.cancelled } },
            onProgress: { _, _, _ in
                state.withLock {
                    $0.progress += 1
                    if $0.progress == 11 { $0.cancelled = true }
                }
            }
        )

        XCTAssertGreaterThanOrEqual(partial.count, 10, "The first completed batch remains durable")
        XCTAssertLessThan(partial.count, urls.count)

        let retried = await actor.subscribeAll(feedURLs: urls, feed: fetcher, inboxSeedCount: 3)
        XCTAssertEqual(retried.count, urls.count)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Podcast>()), urls.count)
        XCTAssertEqual(try episodes(container).count, urls.count, "Retry creates no duplicate episodes")
    }

    /// A cancelled rolling refresh opens with the three least recently checked
    /// feeds, so its next run resumes fairly without a serial warm-up request.
    func testActorRefreshAllResumesWithLeastRecentlyRefreshedFeed() async throws {
        let container = cleanContainer()
        let neverURL = "https://x/never.xml"
        let oldestURL = "https://x/oldest.xml"
        let middleURL = "https://x/middle.xml"
        let newestURL = "https://x/newest.xml"
        do {
            let context = ModelContext(container)
            for url in [newestURL, neverURL, oldestURL, middleURL] {
                context.insert(Podcast(feedURL: url, title: url, lastSeenPubDate: d1))
            }
            context.insert(LocalPodcastState(feedURL: oldestURL, refreshedAt: d2))
            context.insert(LocalPodcastState(feedURL: middleURL, refreshedAt: d3))
            context.insert(LocalPodcastState(feedURL: newestURL, refreshedAt: d3.addingTimeInterval(60)))
            try context.save()
        }
        let fetcher = RecordingFeed(parsedFeed([parsedEpisode("a", d1)]))
        let actor = FeedRefreshActor(modelContainer: container)

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let report = await actor.refreshAllReport(
            feed: fetcher,
            autoQueueEnabled: false,
            isCancelled: { cancelled.withLock { $0 } },
            onProgress: { _, _ in cancelled.withLock { $0 = true } }
        )
        let fetchedURLs = await fetcher.allURLs()

        XCTAssertEqual(report.attempted, 1, "Cancellation stops processing after the first completed fetch")
        XCTAssertEqual(Set(fetchedURLs), Set([neverURL, oldestURL, middleURL]))
        XCTAssertFalse(fetchedURLs.contains(newestURL))
    }

    func testActorRefreshAllCancelledImmediatelyDoesNothing() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            seedCtx.insert(Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1))
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("b", d2)]))
        let calls = OSAllocatedUnfairLock(initialState: 0)

        let results = await actor.refreshAll(
            feed: fetcher,
            autoQueueEnabled: false,
            isCancelled: { true },
            onProgress: { _, _ in calls.withLock { $0 += 1 } }
        )

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }
}

/// Sendable feed double for the actor tests.
private final class FakeFeed: FeedFetching, @unchecked Sendable {
    let feed: ParsedFeed
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed { feed }
}

private actor RecordingFeed: FeedFetching {
    let feed: ParsedFeed
    private var urls: [String] = []

    init(_ feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        urls.append(urlString)
        return feed
    }

    func lastURL() -> String? { urls.last }
    func allURLs() -> [String] { urls }
}

/// Holds the first three requests until all are active. Later requests finish
/// immediately; the high-water mark proves the scheduler opens its window at
/// launch and never exceeds the bound.
private actor RefreshConcurrencyFeed: FeedFetching {
    private let feed: ParsedFeed
    private var callCount = 0
    private var active = 0
    private var maximumActive = 0
    private var rendezvous: [CheckedContinuation<Void, Never>] = []

    init(_ feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        callCount += 1
        active += 1
        maximumActive = max(maximumActive, active)

        if callCount <= 3 {
            await withCheckedContinuation { continuation in
                rendezvous.append(continuation)
                if rendezvous.count == 3 {
                    let waiting = rendezvous
                    rendezvous.removeAll()
                    waiting.forEach { $0.resume() }
                }
            }
        }

        active -= 1
        return feed
    }

    func maximumActiveFetches() -> Int { maximumActive }
}

private actor RollingWindowProbeFeed: FeedFetching {
    private let feed: ParsedFeed
    private var calls = 0
    private var blocked: [CheckedContinuation<Void, Never>] = []

    init(_ feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        calls += 1
        let call = calls
        if call == 2 || call == 3 {
            await withCheckedContinuation { continuation in
                blocked.append(continuation)
            }
        }
        return feed
    }

    func fetchCount() -> Int { calls }

    func releaseBlockedFetches() {
        let continuations = blocked
        blocked.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct NotModifiedFeed: FeedFetching {
    let validators: FeedHTTPValidators

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        XCTFail("A conditional refresh should use refresh(_:)")
        return ParsedFeed(
            title: "Unexpected", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
    }

    func refresh(_ request: FeedRefreshRequest) async throws -> FeedRefreshFetchResult {
        .notModified(validators: validators)
    }
}

private actor OutOfOrderDistinctFeed: FeedFetching {
    let feeds: [String: ParsedFeed]

    init(feeds: [String: ParsedFeed]) {
        self.feeds = feeds
    }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        let index = feeds.keys.sorted().firstIndex(of: urlString) ?? 0
        if index > 0 {
            try await Task.sleep(for: .milliseconds((4 - index) * 10))
        }
        return feeds[urlString] ?? ParsedFeed(
            title: "Missing",
            artworkURL: nil,
            description: nil,
            author: nil,
            websiteURL: nil,
            language: nil,
            category: nil,
            episodes: []
        )
    }
}

/// Captures progress callback values across the actor boundary.
private final class ProgressBox: @unchecked Sendable {
    var calls = 0
    var lastCompleted = 0
    var lastTotal = 0
}
