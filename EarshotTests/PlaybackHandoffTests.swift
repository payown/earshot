import CloudKit
import SwiftData
import XCTest
@testable import Earshot

actor FakePlaybackHandoffClient: PlaybackHandoffClient {
    nonisolated let isEnabled = true
    var fetched: PlaybackHandoffSnapshot?
    var fetchDelayNanoseconds: UInt64 = 0
    private(set) var fetchedIdentities: [PlaybackHandoffIdentity] = []
    private(set) var published: [PlaybackHandoffSnapshot] = []

    init(fetched: PlaybackHandoffSnapshot? = nil) {
        self.fetched = fetched
    }

    func setFetchDelay(_ nanoseconds: UInt64) {
        fetchDelayNanoseconds = nanoseconds
    }

    func fetchLatest(
        for identity: PlaybackHandoffIdentity
    ) async throws -> PlaybackHandoffSnapshot? {
        fetchedIdentities.append(identity)
        if fetchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        guard fetched?.identity == identity else { return nil }
        return fetched
    }

    func publish(_ snapshot: PlaybackHandoffSnapshot) async throws {
        published.append(snapshot)
    }
}

@MainActor
final class PlaybackHandoffTests: XCTestCase {
    private func makeEpisode(
        _ context: ModelContext,
        position: Int = 0,
        followed: Bool = true
    ) -> Episode {
        let podcast = Podcast(
            feedURL: "HTTPS://Example.com/feed/",
            title: "Show",
            subscriptionStateRaw: followed
                ? nil : PodcastSubscriptionState.catalogOnly.rawValue
        )
        context.insert(podcast)
        let episode = Episode(
            guid: "episode-1",
            title: "Episode",
            audioURL: "https://example.com/episode.mp3"
        )
        episode.podcast = podcast
        episode.positionSeconds = position
        context.insert(episode)
        try? context.save()
        return episode
    }

    private func identity() throws -> PlaybackHandoffIdentity {
        try XCTUnwrap(
            PlaybackHandoffIdentity(
                feedURL: "https://example.com/feed/",
                guid: "episode-1"
            )
        )
    }

    func testRecordIdentityIsCanonicalAndDeterministic() throws {
        let first = try XCTUnwrap(
            PlaybackHandoffIdentity(
                feedURL: "HTTPS://Example.com/feed/",
                guid: "episode-1"
            )
        )
        let second = try identity()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.recordName, second.recordName)
        XCTAssertEqual(first.recordName.count, 75)
        XCTAssertTrue(first.recordName.hasPrefix("handoff-v1-"))
    }

    func testCloudRecordRoundTripPreservesRewindAndRate() throws {
        let snapshot = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 80,
            playbackRate: 1.5,
            eventID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            eventDate: Date(timeIntervalSince1970: 1_800_000_000),
            sourceDeviceID: "phone"
        )
        let record = CKRecord(
            recordType: CloudKitPlaybackHandoffClient.Schema.recordType,
            recordID: CKRecord.ID(recordName: snapshot.identity.recordName)
        )

        CloudKitPlaybackHandoffClient.apply(snapshot, to: record)

        XCTAssertEqual(CloudKitPlaybackHandoffClient.snapshot(from: record), snapshot)
        XCTAssertEqual(
            (record[CloudKitPlaybackHandoffClient.Schema.positionSeconds] as? NSNumber)?.intValue,
            80,
            "A rewind must remain 80 rather than being merged with a prior larger position"
        )
    }

    func testDelayedOlderBoundaryCannotOverwriteNewerBoundary() throws {
        let old = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 300,
            playbackRate: 2,
            eventID: UUID(),
            eventDate: Date(timeIntervalSince1970: 100),
            sourceDeviceID: "mac"
        )
        let newerRewind = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 80,
            playbackRate: 1.5,
            eventID: UUID(),
            eventDate: Date(timeIntervalSince1970: 200),
            sourceDeviceID: "phone"
        )

        XCTAssertTrue(PlaybackHandoffOrdering.shouldAccept(incoming: newerRewind, over: old))
        XCTAssertFalse(PlaybackHandoffOrdering.shouldAccept(incoming: old, over: newerRewind))
        XCTAssertFalse(
            PlaybackHandoffOrdering.shouldAccept(incoming: newerRewind, over: newerRewind),
            "Retrying the same event must be idempotent"
        )
    }

    func testResumeAppliesExplicitFetchPositionAndRateBeforePlaying() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 180,
            playbackRate: 1.5,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20)
        player.load(episode)

        player.resume()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(Int(player.currentPositionSeconds), 180)
        XCTAssertEqual(player.effectiveRate, 1.5)
        XCTAssertEqual(episode.positionSeconds, 180)
        XCTAssertNil(
            episode.podcast?.speedOverride,
            "A handoff rate is session state and must not rewrite the podcast preference"
        )
    }

    func testResumeFallsBackToLocalStateAtDeadline() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 999,
            playbackRate: 2,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        await client.setFetchDelay(10_000_000_000)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 42)
        player.load(episode)

        let start = ContinuousClock.now
        player.resume()
        try await Task.sleep(nanoseconds: 1_700_000_000)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(Int(player.currentPositionSeconds), 42)
        XCTAssertEqual(player.effectiveRate, 1)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testSeekPublishesOneExactBoundaryWithoutWaitingForCloudKit() async throws {
        let context = TestStore.freshContext()
        let client = FakePlaybackHandoffClient()
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context)
        player.load(episode)

        player.seek(to: 73)
        try await Task.sleep(nanoseconds: 100_000_000)

        let published = await client.published
        XCTAssertEqual(published.last?.identity, try identity())
        XCTAssertEqual(published.last?.positionSeconds, 73)
        XCTAssertEqual(published.last?.playbackRate, 1)
    }

    func testCatalogTransitionBeforeScheduledPublishPreventsUpload() async throws {
        let context = TestStore.freshContext()
        let client = FakePlaybackHandoffClient()
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context)
        player.load(episode)

        // `seek` forms the value snapshot and schedules its MainActor publish
        // task. This test remains on MainActor long enough to supersede Follow
        // before that task can begin, deterministically exercising the narrow
        // scheduling window rather than relying on a transport delay.
        player.seek(to: 73)
        episode.podcast?.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        try context.save()
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        let published = await client.published
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(Int(player.currentPositionSeconds), 73)
    }

    func testCatalogPlaybackNeverFetchesOrPublishesDirectHandoff() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 180,
            playbackRate: 1.5,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20, followed: false)

        player.playWithHandoff(episode)
        player.seek(to: 73)
        player.pause()
        player.setGlobalSpeed(1.25, announce: false)
        player.persistForBackground()
        try await Task.sleep(nanoseconds: 100_000_000)

        let fetched = await client.fetchedIdentities
        let published = await client.published
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(Int(player.currentPositionSeconds), 73)
    }

    func testCatalogLoadedResumeNeverFetchesDirectHandoff() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 180,
            playbackRate: 1.5,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20, followed: false)
        player.load(episode)

        player.resume()
        try await Task.sleep(nanoseconds: 100_000_000)

        let fetched = await client.fetchedIdentities
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(Int(player.currentPositionSeconds), 20)
    }

    func testCatalogPromotionEnablesOrdinaryDirectHandoff() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 180,
            playbackRate: 1.5,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20, followed: false)

        player.playWithHandoff(episode)
        try await Task.sleep(nanoseconds: 100_000_000)
        let catalogFetches = await client.fetchedIdentities
        XCTAssertTrue(catalogFetches.isEmpty)

        episode.podcast?.subscriptionStateRaw = nil
        try context.save()
        player.playWithHandoff(episode)
        try await Task.sleep(nanoseconds: 100_000_000)

        let promotedFetches = await client.fetchedIdentities
        XCTAssertEqual(promotedFetches, [try identity()])
        XCTAssertEqual(Int(player.currentPositionSeconds), 180)
        XCTAssertEqual(player.effectiveRate, 1.5)
    }

    func testCatalogTransitionDuringStartFetchDoesNotApplyRemoteHandoff() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 180,
            playbackRate: 1.5,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        await client.setFetchDelay(250_000_000)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20)

        player.playWithHandoff(episode)
        episode.podcast?.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        try context.save()
        try await Task.sleep(nanoseconds: 400_000_000)

        let fetched = await client.fetchedIdentities
        XCTAssertEqual(fetched, [try identity()])
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(Int(player.currentPositionSeconds), 20)
        XCTAssertEqual(player.effectiveRate, 1)
    }

    func testCatalogTransitionDuringResumeFetchDoesNotApplyRemoteHandoff() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 180,
            playbackRate: 1.5,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        await client.setFetchDelay(250_000_000)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20)
        player.load(episode)

        player.resume()
        episode.podcast?.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        try context.save()
        try await Task.sleep(nanoseconds: 400_000_000)

        let fetched = await client.fetchedIdentities
        XCTAssertEqual(fetched, [try identity()])
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(Int(player.currentPositionSeconds), 20)
        XCTAssertEqual(player.effectiveRate, 1)
    }

    func testSeekCancelsPendingResumeHandoffSoLateFetchCannotBounceBack() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 25,
            playbackRate: 1,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        await client.setFetchDelay(500_000_000)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 25)
        episode.durationSeconds = 300
        player.load(episode)

        player.resume()
        player.skipForward()
        XCTAssertEqual(Int(player.currentPositionSeconds), 55)

        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(
            Int(player.currentPositionSeconds),
            55,
            "A delayed handoff fetched before the skip must not restore the old position"
        )
    }

    func testRepeatedForwardSkipsAccumulateFromPendingTarget() {
        let context = TestStore.freshContext()
        let player = PlayerService(playbackHandoff: DisabledPlaybackHandoffClient())
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 20)
        episode.durationSeconds = 300
        player.load(episode)

        player.skipForward()
        player.skipForward()
        player.skipForward()

        XCTAssertEqual(
            Int(player.currentPositionSeconds),
            110,
            "Three rapid 30-second skips must accumulate to 90 seconds"
        )
    }

    func testPauseCancelsLateFetchWithoutSeekingOrRestarting() async throws {
        let context = TestStore.freshContext()
        let remote = PlaybackHandoffSnapshot(
            identity: try identity(),
            positionSeconds: 500,
            playbackRate: 2,
            sourceDeviceID: "phone"
        )
        let client = FakePlaybackHandoffClient(fetched: remote)
        await client.setFetchDelay(500_000_000)
        let player = PlayerService(playbackHandoff: client)
        player.configure(context: context)
        defer { player.stopAndUnload() }
        let episode = makeEpisode(context, position: 25)
        player.load(episode)

        player.resume()
        player.pause()
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(Int(player.currentPositionSeconds), 25)
        XCTAssertEqual(player.effectiveRate, 1)
    }

    func testPendingOutboxKeepsNewerRewindAndSurvivesRecreation() throws {
        let suite = "PlaybackHandoffTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = try identity()
        let newerRewind = PlaybackHandoffSnapshot(
            identity: identity,
            positionSeconds: 80,
            playbackRate: 1.5,
            eventID: UUID(),
            eventDate: Date(timeIntervalSince1970: 200),
            sourceDeviceID: "phone"
        )
        let delayedOld = PlaybackHandoffSnapshot(
            identity: identity,
            positionSeconds: 300,
            playbackRate: 2,
            eventID: UUID(),
            eventDate: Date(timeIntervalSince1970: 100),
            sourceDeviceID: "mac"
        )
        var store = PlaybackHandoffPendingStore(defaults: defaults)

        store.save(newerRewind)
        store.save(delayedOld)

        let restored = PlaybackHandoffPendingStore(defaults: defaults)
        XCTAssertEqual(restored.snapshot(for: identity), newerRewind)
    }
}
