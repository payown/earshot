import Foundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ListeningPlacesSubscriptionExchangeTests: XCTestCase {
    private let feed = "https://example.com/public.xml"
    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_000_000)

    private func emptyFile() throws -> Data {
        try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "phone123", appVersion: "earshot/1.3.1",
            writtenAt: newer, records: []
        )
    }

    private func rows(_ data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["records"] as? [[String: Any]])
    }

    func testOptInExportKeepsEpisodeBudgetFoldersOrderAndPrivateShowsOut() throws {
        let context = TestStore.freshContext()
        let publicShow = Podcast(feedURL: feed, title: "Public", speedOverride: 1.4,
                                 createdAt: older)
        let privateShow = Podcast(feedURL: "https://example.com/private?token=synthetic",
                                  title: "Private", createdAt: older)
        let first = PodcastFolder(name: "First", sortOrder: 3, createdAt: older)
        let second = PodcastFolder(name: "Second", sortOrder: 4, createdAt: older)
        context.insert(publicShow)
        context.insert(privateShow)
        context.insert(first)
        context.insert(second)
        context.insert(FolderMembership(folder: second, podcast: publicShow, sortOrder: 2))
        context.insert(FolderMembership(folder: first, podcast: publicShow, sortOrder: 1))
        try context.save()
        var originalRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: emptyFile()) as? [String: Any]
        )
        let episodeRows: [[String: Any]] = (0..<ListeningPlacesFormat.maximumRecordCount)
            .map { ["id": "episode:\($0)", "kind": "episode", "position": $0] }
        originalRoot["records"] = episodeRows
        let original = try JSONSerialization.data(withJSONObject: originalRoot)
        XCTAssertEqual(try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: original, context: context, policy: .init()
        ), original)

        let carried: [[String: Any]] = [
            ["id": "folder:unknown1", "kind": "folder", "name": "Peer-only",
             "updated_at": "2023-11-14T22:13:20Z", "sortOrder": 9],
            ["id": try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed)),
             "kind": "subscription", "folders": ["folder:unknown1"],
             "app_private": ["quill-cast": ["is_favorite": true]]],
        ]
        let exported = try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: original, context: context,
            policy: .init(shareSubscriptions: true), carriedPeerRows: carried,
            now: newer
        )
        let output = try rows(exported)
        XCTAssertEqual(output.filter { $0["kind"] as? String == "episode" }.count,
                       ListeningPlacesFormat.maximumRecordCount,
                       "Subscription rows must not evict bounded episode places")
        if let path = ProcessInfo.processInfo.environment["EARSHOT_LP_EXPORT_PATH"] {
            try exported.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let sub = try XCTUnwrap(output.first { $0["kind"] as? String == "subscription" })
        XCTAssertEqual(sub["feed_url"] as? String, feed)
        XCTAssertEqual(sub["title"] as? String, "Public")
        XCTAssertEqual((sub["prefs"] as? [String: Any])?["speed"] as? Double, 1.4)
        let folders = try XCTUnwrap(sub["folders"] as? [String])
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(folders.last, "folder:unknown1")
        XCTAssertEqual((sub["app_private"] as? [String: Any])?["quill-cast"]
            as? [String: Bool], ["is_favorite": true])
        XCTAssertEqual(output.filter { $0["kind"] as? String == "folder" }.count, 3)
        let reopenedRows = try rows(ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: original, context: ModelContext(context.container),
            policy: .init(shareSubscriptions: true), carriedPeerRows: carried,
            now: newer
        ))
        let reopenedSub = try XCTUnwrap(reopenedRows.first {
            $0["kind"] as? String == "subscription"
        })
        XCTAssertEqual(reopenedSub["folders"] as? [String], folders,
                       "Folder IDs and membership order must survive a context reopen")
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("token=synthetic"))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("Private"))
    }

    func testDeviceOnlyWithdrawalKeepsPeerFollowAndLocalPlace() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let podcast = Podcast(feedURL: feed, title: "Public", createdAt: older)
        let episode = Episode(guid: "withdraw", title: "Kept",
                              audioURL: "https://example.com/withdraw.mp3",
                              positionSeconds: 73)
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let loader = await ListeningPlacesSnapshotLoader.makeBackground(modelContainer: container)
        let before = try await loader.prepare(
            pendingZeroSnapshots: [], includeLabels: false, previousRecords: [],
            previousSignatures: [:], previousUpdatedAtByID: [:],
            deviceID: "phone123", appVersion: "earshot/1.3.1", now: older
        )
        let original = try XCTUnwrap(before.data)
        let peer: Data
        if let path = ProcessInfo.processInfo.environment["QUILL_PEER_FIXTURE_PATH"] {
            peer = try Data(contentsOf: URL(fileURLWithPath: path))
            print("Listening Places subscription test loaded pinned QUILL peer export")
        } else {
            peer = try file(records: [[
                "id": try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed)),
                "kind": "subscription", "feed_url": feed, "title": "Public",
                "private": false, "subscribed_at": "2023-11-14T22:13:20Z",
                "updated_at": "2023-11-14T22:13:20Z", "folders": [],
            ]])
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "places-subs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let peerFile = directory.appending(path: "peer.json")
        let ownFile = directory.appending(path: "phone123.json")
        try peer.write(to: peerFile)
        let ownBefore = try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: original, context: context,
            policy: .init(shareSubscriptions: true), now: older
        )
        XCTAssertEqual(try rows(ownBefore).filter {
            $0["kind"] as? String == "subscription"
        }.count, 1)
        try ownBefore.write(to: ownFile)
        try ListeningPlacesFeedPrivacy.stageDeviceOnly(feedURL: feed, in: context)
        try context.save()
        let scrubbed = try await loader.prepare(
            pendingZeroSnapshots: [], includeLabels: false,
            previousRecords: before.records, previousSignatures: before.signatures,
            previousUpdatedAtByID: before.updatedAtByID,
            deviceID: "phone123", appVersion: "earshot/1.3.1", now: newer
        )
        let ownedAfter = try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: try XCTUnwrap(scrubbed.data), context: context,
            policy: .init(shareSubscriptions: true),
            carriedPeerRows: try rows(peer), now: newer
        )
        try ownedAfter.write(to: ownFile)
        XCTAssertTrue(try rows(ownedAfter).isEmpty, "No privacy tombstone or place may remain")
        XCTAssertEqual(episode.positionSeconds, 73)
        let noInboundChange = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            peer, context: context,
            policy: .init(shareSubscriptions: true, acceptFollows: true,
                          acceptUnfollows: true),
            expectedPeerID: ProcessInfo.processInfo.environment["QUILL_PEER_FIXTURE_PATH"] == nil
                ? "peer1234" : "desktop99", ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(noInboundChange.follows + noInboundChange.unfollows, 0)
        XCTAssertTrue(podcast.isFollowed)
        XCTAssertEqual(try Data(contentsOf: peerFile), peer)
    }

    func testPeerFollowAndUnfollowRetainLocalGraphAndDeviceOnlyWins() throws {
        let context = TestStore.freshContext()
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let follow: [String: Any] = [
            "id": id, "kind": "subscription", "feed_url": feed,
            "title": "Public", "private": false,
            "subscribed_at": "2023-11-14T22:13:20Z",
            "updated_at": "2023-11-14T22:13:20Z", "folders": [],
        ]
        let firstFile: Data
        if let path = ProcessInfo.processInfo.environment["QUILL_PEER_FIXTURE_PATH"] {
            firstFile = try Data(contentsOf: URL(fileURLWithPath: path))
            print("Listening Places follow test loaded pinned QUILL peer export")
        } else {
            firstFile = try file(records: [follow])
        }
        let peerID = ProcessInfo.processInfo.environment["QUILL_PEER_FIXTURE_PATH"] == nil
            ? "peer1234" : "desktop99"
        var policy = ListeningPlacesSubscriptionExchange.Policy(
            shareSubscriptions: true, acceptFollows: true, acceptUnfollows: true
        )
        XCTAssertThrowsError(try ListeningPlacesSubscriptionExchange.applyPeerFile(
            firstFile, context: context, policy: policy,
            expectedPeerID: "different-device", ownDeviceID: "phone123", now: newer
        ))
        try ListeningPlacesFeedPrivacy.stageDeviceOnly(feedURL: feed, in: context)
        try context.save()
        let blocked = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            firstFile, context: context, policy: policy,
            expectedPeerID: peerID, ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(blocked.follows, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
        try ListeningPlacesFeedPrivacy.clearForExplicitSharing(feedURL: feed, in: context)
        try context.save()
        let applied = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            firstFile, context: context, policy: policy,
            expectedPeerID: peerID, ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(applied.follows, 1)
        let podcast = try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertTrue(podcast.isFollowed)
        let carried = try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: emptyFile(), context: context,
            policy: .init(shareSubscriptions: true),
            carriedPeerRows: try rows(firstFile), now: newer
        )
        let carriedSub = try XCTUnwrap(try rows(carried).first {
            $0["kind"] as? String == "subscription"
        })
        XCTAssertEqual(carriedSub["folders"] as? [String],
                       (try rows(firstFile)).first {
                           $0["kind"] as? String == "subscription"
                       }?["folders"] as? [String])
        XCTAssertEqual(carriedSub["updated_at"] as? String,
                       (try rows(firstFile)).first {
                           $0["kind"] as? String == "subscription"
                       }?["updated_at"] as? String,
                       "File composition must not stamp an imported follow as a new event")
        let episode = Episode(guid: "kept", title: "Kept",
                              audioURL: "https://example.com/media.mp3", positionSeconds: 45)
        episode.podcast = podcast
        context.insert(episode)
        context.insert(QueueItem(episode: episode, position: 0))
        context.insert(ListeningSession(episode: episode, podcast: podcast,
                                        durationSeconds: 40, date: older))
        try context.save()

        let tombstone: [String: Any] = [
            "id": id, "deleted": true, "updated_at": "2027-01-15T08:00:00Z",
        ]
        let removal = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            file(records: [tombstone]), context: context, policy: policy,
            expectedPeerID: "peer1234", ownDeviceID: "phone123",
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        XCTAssertEqual(removal.unfollows, 1)
        XCTAssertTrue(podcast.isCatalogOnly)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 1)
        XCTAssertTrue(try ListeningPlacesSubscriptionRetention.isRetained(
            feedURL: feed, in: context
        ))
        policy.shareSubscriptions = false
        XCTAssertEqual(try ListeningPlacesSubscriptionExchange.applyPeerFile(
            firstFile, context: context, policy: policy,
            expectedPeerID: peerID, ownDeviceID: "phone123", now: newer
        ).follows, 0)
    }

    func testMalformedSiblingDoesNotDiscardFractionalTimestampFollow() throws {
        let context = TestStore.freshContext()
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let data = try JSONSerialization.data(withJSONObject: [
            "format": ListeningPlacesFormat.identifier,
            "device": "peer1234", "app": "quill-cast/1.0.0",
            "written_at": "2026-11-27T09:00:00.125Z",
            "records": [
                "malformed sibling",
                ["id": id, "kind": "subscription", "feed_url": feed,
                 "title": "Public", "private": false,
                 "subscribed_at": "2023-11-14T22:13:20.125Z",
                 "updated_at": "2023-11-14T22:13:20.250Z"],
            ],
        ])
        let result = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            data, context: context,
            policy: .init(shareSubscriptions: true, acceptFollows: true),
            expectedPeerID: "peer1234", ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(result.follows, 1)
        XCTAssertEqual(result.deferred, 1)
    }

    func testPeerAliasCannotCreateDuplicateLocalSubscription() throws {
        let context = TestStore.freshContext()
        let original = Podcast(feedURL: feed, title: "Already followed", createdAt: older)
        context.insert(original)
        try context.save()
        let renamed = "https://example.com/renamed.xml"
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(renamed))
        let peer = try file(records: [[
            "id": id, "kind": "subscription", "feed_url": renamed,
            "alt_urls": [feed], "title": "Same show", "private": false,
            "subscribed_at": "2023-11-14T22:13:20Z",
            "updated_at": "2023-11-14T22:13:20Z", "folders": [],
        ]])
        let result = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            peer, context: context,
            policy: .init(shareSubscriptions: true, acceptFollows: true),
            expectedPeerID: "peer1234", ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(result.follows, 0)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(original.title, "Already followed")
    }

    func testOlderPeerUnfollowCannotUndoNewerLocalFollow() throws {
        let context = TestStore.freshContext()
        let original = Podcast(feedURL: feed, title: "Locally followed", createdAt: newer)
        context.insert(original)
        try context.save()
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let peer = try file(records: [[
            "id": id, "deleted": true, "updated_at": "2023-11-14T22:13:20Z",
        ]])
        let result = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            peer, context: context,
            policy: .init(shareSubscriptions: true, acceptUnfollows: true),
            expectedPeerID: "peer1234", ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(result.unfollows, 0)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertTrue(original.isFollowed)
    }

    func testNewerPeerUnfollowCannotUndoIndependentlyFollowedLocalShow() throws {
        let context = TestStore.freshContext()
        let original = Podcast(feedURL: feed, title: "My follow", createdAt: older)
        context.insert(original)
        try context.save()
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let peer = try file(records: [[
            "id": id, "deleted": true, "updated_at": "2027-01-15T08:00:00Z",
        ]])
        let result = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            peer, context: context,
            policy: .init(shareSubscriptions: true, acceptUnfollows: true),
            expectedPeerID: "peer1234", ownDeviceID: "phone123",
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        XCTAssertEqual(result.unfollows, 0)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertTrue(original.isFollowed)
        XCTAssertFalse(try ListeningPlacesSubscriptionRetention.isRetained(
            feedURL: feed, in: context
        ))
    }

    private func file(records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": ListeningPlacesFormat.identifier,
            "device": "peer1234", "app": "quill-cast/1.0.0",
            "written_at": "2027-01-15T08:00:00Z", "records": records,
        ])
    }
}
