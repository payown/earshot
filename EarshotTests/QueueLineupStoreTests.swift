import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class QueueLineupStoreTests: XCTestCase {
    private func makePodcast(_ context: ModelContext, name: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://example.com/\(name).xml", title: name)
        context.insert(podcast)
        return podcast
    }

    private func makeEpisode(
        _ context: ModelContext, guid: String, podcast: Podcast
    ) -> Episode {
        let episode = Episode(
            guid: guid,
            title: guid,
            audioURL: "https://example.com/\(guid).mp3"
        )
        episode.podcast = podcast
        context.insert(episode)
        return episode
    }

    func testSavedLineupIsMirroredAndRoundTripsStableIdentities() {
        let context = TestStore.freshContext()
        let podcast = makePodcast(context, name: "show")
        let first = makeEpisode(context, guid: "first", podcast: podcast)
        let second = makeEpisode(context, guid: "second", podcast: podcast)
        let store = QueueLineupStore(context: context)

        let report = store.save([first, second])

        XCTAssertEqual(report, QueueLineupSaveReport(savedCount: 2, omittedCount: 0))
        XCTAssertEqual(store.savedCount, 2)
        XCTAssertTrue(store.hasSavedLineup)
        XCTAssertTrue(AppSettingScope.isMirrored(SettingsKey.morningLineup))
    }

    func testApplyMovesSavedEpisodesToFrontAndPreservesOtherQueueOrder() {
        let context = TestStore.freshContext()
        let podcast = makePodcast(context, name: "show")
        let first = makeEpisode(context, guid: "first", podcast: podcast)
        let second = makeEpisode(context, guid: "second", podcast: podcast)
        let otherA = makeEpisode(context, guid: "other-a", podcast: podcast)
        let otherB = makeEpisode(context, guid: "other-b", podcast: podcast)
        let queue = QueueRepository(context: context)
        queue.add([otherA, second, otherB])
        let store = QueueLineupStore(context: context)
        store.save([first, second])

        let report = store.apply(to: queue)

        XCTAssertEqual(report, QueueLineupApplyReport(appliedCount: 2, skippedCount: 0))
        XCTAssertEqual(queue.queue().map(\.guid), ["first", "second", "other-a", "other-b"])
    }

    func testApplySkipsPlayedAndUnavailableEpisodesWithExactCount() {
        let context = TestStore.freshContext()
        let podcast = makePodcast(context, name: "show")
        let available = makeEpisode(context, guid: "available", podcast: podcast)
        let played = makeEpisode(context, guid: "played", podcast: podcast)
        played.isPlayed = true
        let identities = [
            QueueLineupIdentity(feedURL: podcast.feedURL, episodeGUID: available.guid),
            QueueLineupIdentity(feedURL: podcast.feedURL, episodeGUID: played.guid),
            QueueLineupIdentity(feedURL: podcast.feedURL, episodeGUID: "missing"),
        ]
        let data = try! JSONEncoder().encode(identities)
        AppSettingsStore(context: context).setRawValue(
            String(decoding: data, as: UTF8.self),
            for: SettingsKey.morningLineup
        )

        let queue = QueueRepository(context: context)
        let report = QueueLineupStore(context: context).apply(to: queue)

        XCTAssertEqual(report, QueueLineupApplyReport(appliedCount: 1, skippedCount: 2))
        XCTAssertEqual(queue.queue().map(\.guid), ["available"])
    }

    func testSaveCapsLargeQueueAndReportsOmittedCount() {
        let context = TestStore.freshContext()
        let podcast = makePodcast(context, name: "show")
        let episodes = (0..<105).map {
            makeEpisode(context, guid: "episode-\($0)", podcast: podcast)
        }

        let report = QueueLineupStore(context: context).save(episodes)

        XCTAssertEqual(report, QueueLineupSaveReport(savedCount: 100, omittedCount: 5))
        XCTAssertEqual(QueueLineupStore(context: context).savedCount, 100)
    }

    func testCorruptValueBehavesAsNoSavedLineupAndClearRemovesLineup() {
        let context = TestStore.freshContext()
        let settings = AppSettingsStore(context: context)
        settings.setRawValue("not json", for: SettingsKey.morningLineup)
        let store = QueueLineupStore(context: context)

        XCTAssertFalse(store.hasSavedLineup)
        store.clear()
        XCTAssertEqual(settings.rawValue(SettingsKey.morningLineup), "")
        XCTAssertFalse(store.hasSavedLineup)
    }
}
