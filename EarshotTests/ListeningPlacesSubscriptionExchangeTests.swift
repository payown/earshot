import Foundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ListeningPlacesSubscriptionExchangeTests: XCTestCase {
    private let feed = "https://example.com/public.xml"
    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlaybackReceiveConsentIsDeviceLocalAndDefaultsOffForUpgrades() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        XCTAssertFalse(ListeningPlacesPlaybackReceiveConsent.isEnabled(in: context))
        try LocalAppSettingIdentity.setValue(
            "unknown", for: "listening_places_receive_playback_v1", in: context
        )
        try context.save()
        XCTAssertFalse(ListeningPlacesPlaybackReceiveConsent.isEnabled(in: ModelContext(container)))
        try ListeningPlacesPlaybackReceiveConsent.setEnabled(true, in: context)
        XCTAssertTrue(ListeningPlacesPlaybackReceiveConsent.isEnabled(in: ModelContext(container)))
        try ListeningPlacesPlaybackReceiveConsent.setEnabled(false, in: context)
        XCTAssertFalse(ListeningPlacesPlaybackReceiveConsent.isEnabled(in: ModelContext(container)))
    }

    func testPublicProvenanceRequiresExactAnonymousDirectoryResolution() throws {
        typealias Evidence = ListeningPlacesPublicFeedApproval.Evidence
        func evidence(
            origin: Evidence.Origin = .appleITunesDirectory,
            directoryResponseURL: String? = "https://itunes.apple.com/search?media=podcast",
            directoryFeedURL: String? = "https://example.com/public.xml",
            requestedFeedURL: String = "https://example.com/public.xml",
            resolvedFeedURL: String? = "https://example.com/public.xml",
            redirectCount: Int? = 0,
            access: Evidence.Access = .provenAnonymous,
            hasStoredCredentials: Bool? = false,
            deviceOnly: Bool = false
        ) -> Evidence {
            Evidence(origin: origin, directoryResponseURL: directoryResponseURL,
                directoryFeedURL: directoryFeedURL, requestedFeedURL: requestedFeedURL,
                resolvedFeedURL: resolvedFeedURL, redirectCount: redirectCount,
                access: access, hasStoredCredentials: hasStoredCredentials,
                deviceOnly: deviceOnly)
        }

        XCTAssertEqual(ListeningPlacesPublicFeedApproval.eligibleFeedURL(evidence()), feed)
        let rejected = [
            evidence(origin: .userEntered), evidence(origin: .opml),
            evidence(origin: .genericFetch), evidence(origin: .unknown),
            evidence(directoryResponseURL: "https://other.example/search"),
            evidence(directoryResponseURL: nil),
            evidence(directoryFeedURL: nil),
            evidence(directoryFeedURL: "https://example.com/alias.xml"),
            evidence(requestedFeedURL: "https://example.com/public.xml/"),
            evidence(resolvedFeedURL: "https://example.com/redirected.xml", redirectCount: 1),
            evidence(resolvedFeedURL: nil), evidence(redirectCount: nil),
            evidence(access: .usedCredentialsOrCookies), evidence(access: .unknown),
            evidence(hasStoredCredentials: true), evidence(hasStoredCredentials: nil),
            evidence(deviceOnly: true),
            evidence(directoryFeedURL: "https://example.com/private.xml?token=synthetic",
                requestedFeedURL: "https://example.com/private.xml?token=synthetic",
                resolvedFeedURL: "https://example.com/private.xml?token=synthetic"),
        ]
        for item in rejected {
            XCTAssertNil(ListeningPlacesPublicFeedApproval.eligibleFeedURL(item))
        }

        let context = TestStore.freshContext()
        try LocalAppSettingIdentity.setValue("approved",
            for: ListeningPlacesPublicFeedApproval.key(feed), in: context)
        try LocalAppSettingIdentity.setValue("approved",
            for: "listening_places_public_feed_approval_v1:synthetic", in: context)
        try context.save()
        XCTAssertTrue(try ListeningPlacesPublicFeedApproval.approvedKeys(in: context).isEmpty,
            "Legacy and ambiguous markers must not become positive public proof")
        try ListeningPlacesPublicFeedApproval.stageVerifiedDirectoryEvidence(evidence(), in: context)
        try context.save()
        XCTAssertEqual(try ListeningPlacesPublicFeedApproval.approvedKeys(in: context),
            [ListeningPlacesPublicFeedApproval.key(feed)])
        XCTAssertNotEqual(ListeningPlacesPublicFeedApproval.key(feed),
            ListeningPlacesPublicFeedApproval.key(feed + "/"),
            "An approved feed cannot grant a URL alias")
    }

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
        XCTAssertEqual(try rows(ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: original, context: context,
            policy: .init(shareSubscriptions: true)
        )).count, episodeRows.count, "Sharing without per-feed approval must fail closed")
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(
            for: feed, in: context
        )
        try context.save()

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
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
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
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try context.save()
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
        let stillDeferred = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            firstFile, context: context, policy: policy,
            expectedPeerID: peerID, ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(stillDeferred.follows, 0,
            "Clearing device-only cannot revive the previous public proof")
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(
            for: feed, in: context)
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
        let afterUnfollow = try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: emptyFile(), context: context,
            policy: .init(shareSubscriptions: true), now: newer
        )
        XCTAssertTrue(try rows(afterUnfollow).isEmpty,
                      "A remote unfollow must not publish a new tombstone")
        policy.shareSubscriptions = false
        XCTAssertEqual(try ListeningPlacesSubscriptionExchange.applyPeerFile(
            firstFile, context: context, policy: policy,
            expectedPeerID: peerID, ownDeviceID: "phone123", now: newer
        ).follows, 0)
    }

    func testMalformedSiblingDoesNotDiscardFractionalTimestampFollow() throws {
        let context = TestStore.freshContext()
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try context.save()
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
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: renamed, in: context)
        try context.save()
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
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
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
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
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

    func testPrivatePeerSubscriptionAndTokenFeedCannotBeFollowed() throws {
        let context = TestStore.freshContext()
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try context.save()
        let publicID = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let peer = try file(records: [
            ["id": "sub:private", "kind": "subscription", "feed_url": feed,
             "title": "Private", "private": true,
             "subscribed_at": "2023-11-14T22:13:20Z",
             "updated_at": "2023-11-14T22:13:20Z"],
            ["id": "sub:token", "kind": "subscription",
             "feed_url": "https://example.com/feed?token=synthetic",
             "title": "Token feed", "private": false,
             "subscribed_at": "2023-11-14T22:13:20Z",
             "updated_at": "2023-11-14T22:13:20Z"],
            ["id": publicID, "kind": "subscription", "feed_url": feed,
             "title": "Unclassified", "subscribed_at": "2023-11-14T22:13:20Z",
             "updated_at": "2023-11-14T22:13:20Z"],
        ])
        let result = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            peer, context: context,
            policy: .init(shareSubscriptions: true, acceptFollows: true),
            expectedPeerID: "peer1234", ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(result.follows, 0)
        XCTAssertEqual(result.privateRows, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 0)
    }

    func testPublicPeerFollowWithoutLocalApprovalIsDeferred() throws {
        let context = TestStore.freshContext()
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let peer = try file(records: [[
            "id": id, "kind": "subscription", "feed_url": feed,
            "title": "Public", "private": false,
            "subscribed_at": "2023-11-14T22:13:20Z",
            "updated_at": "2023-11-14T22:13:20Z",
        ]])
        let deferred = try ListeningPlacesSubscriptionExchange.applyPeerFile(
            peer, context: context,
            policy: .init(shareSubscriptions: true, acceptFollows: true),
            expectedPeerID: "peer1234", ownDeviceID: "phone123", now: newer
        )
        XCTAssertEqual(deferred.follows, 0)
        XCTAssertEqual(deferred.deferred, 1)
        XCTAssertEqual(deferred.privateRows, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 0)
    }


    func testDisposableCoordinatorReadsPeerAndCASWritesOnlyOwnedFile() async throws {
        guard ProcessInfo.processInfo.environment["EARSHOT_LP_DISPOSABLE_SYNC"] == "1",
              let pinnedPeerPath = ProcessInfo.processInfo.environment["QUILL_PEER_FIXTURE_PATH"]
        else { throw XCTSkip("Requires explicit disposable runner gate and pinned QUILL fixture") }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "places-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try root.bookmarkData(options: .minimalBookmark,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        let transport = ListeningPlacesFileTransport()
        try await transport.prepareFolder(bookmarkData: bookmark)
        let own = try emptyFile()
        try await transport.writeDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123", data: own
        )
        let peer = try Data(contentsOf: URL(fileURLWithPath: pinnedPeerPath))
        let peerID = "desktop99"
        let peerPath = root.appending(path: "Listening Places/devices/\(peerID).json")
        try peer.write(to: peerPath)
        let context = TestStore.freshContext()
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try context.save()
        try ListeningPlacesSubscriptionTestCoordinator.stagePolicy(.init(), in: context)
        try context.save()
        let off = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "phone123", context: context,
            transport: transport, now: newer
        )
        XCTAssertEqual(off.applied.follows, 0)
        XCTAssertFalse(off.wroteOwnedFile)
        let unchangedOwn = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123"
        )
        XCTAssertEqual(unchangedOwn, own)

        try ListeningPlacesSubscriptionTestCoordinator.stagePolicy(
            .init(shareSubscriptions: true, acceptFollows: true, acceptUnfollows: true),
            in: context
        )
        try context.save()
        let followed = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "phone123", context: context,
            transport: transport, now: newer
        )
        XCTAssertEqual(followed.peerFilesRead, 1)
        XCTAssertEqual(followed.applied.follows, 1)
        XCTAssertTrue(followed.wroteOwnedFile)
        let podcast = try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.feedURL, feed)
        XCTAssertEqual(podcast.speedOverride, 1.4)
        let maybeOwnedFollow = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123"
        )
        let ownedFollow = try XCTUnwrap(maybeOwnedFollow)
        let sub = try XCTUnwrap(try rows(ownedFollow).first {
            $0["kind"] as? String == "subscription"
        })
        XCTAssertEqual((sub["folders"] as? [String])?.count, 3)
        XCTAssertEqual(try Data(contentsOf: peerPath), peer)

        try ListeningPlacesFeedPrivacy.stageDeviceOnly(feedURL: feed, in: context)
        try context.save()
        let withdrawn = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "phone123", context: context,
            transport: transport, now: newer
        )
        XCTAssertEqual(withdrawn.applied.follows + withdrawn.applied.unfollows, 0)
        let maybeWithdrawnBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123"
        )
        let withdrawnBytes = try XCTUnwrap(maybeWithdrawnBytes)
        XCTAssertTrue(try rows(withdrawnBytes).isEmpty)
        XCTAssertTrue(podcast.isFollowed)
        XCTAssertEqual(try Data(contentsOf: peerPath), peer)

        try ListeningPlacesFeedPrivacy.clearForExplicitSharing(feedURL: feed, in: context)
        try context.save()
        let reentered = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "phone123", context: context,
            transport: transport, now: newer
        )
        XCTAssertEqual(reentered.applied.follows, 0)
        let maybeReenteredBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123"
        )
        let reenteredBytes = try XCTUnwrap(maybeReenteredBytes)
        XCTAssertTrue(try rows(reenteredBytes).filter {
            $0["kind"] as? String == "subscription"
        }.isEmpty, "Clearing device-only cannot revive the previous public proof")

        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(
            for: feed, in: context)
        try context.save()
        _ = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "phone123", context: context,
            transport: transport, now: newer
        )
        let maybeReapprovedBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123")
        let reapprovedBytes = try XCTUnwrap(maybeReapprovedBytes)
        XCTAssertEqual(try rows(reapprovedBytes).filter {
            $0["kind"] as? String == "subscription"
        }.count, 1)
        XCTAssertEqual(try Data(contentsOf: peerPath), peer)

        let episode = Episode(guid: "retained", title: "Retained",
                              audioURL: "https://example.com/retained.mp3",
                              positionSeconds: 30)
        episode.podcast = podcast
        context.insert(episode)
        context.insert(QueueItem(episode: episode, position: 0))
        context.insert(ListeningSession(episode: episode, podcast: podcast,
                                        durationSeconds: 10, date: older))
        try context.save()
        let id = try XCTUnwrap(ListeningPlacesSubscriptionIdentity.shareableID(feed))
        let tombstone = try JSONSerialization.data(withJSONObject: [
            "format": ListeningPlacesFormat.identifier,
            "device": peerID, "app": "quill-cast/1.0.0",
            "written_at": "2026-11-27T12:00:00Z",
            "records": [["id": id, "deleted": true,
                         "updated_at": "2026-11-27T12:00:00Z"]],
        ])
        try tombstone.write(to: peerPath, options: .atomic)
        let unfollowed = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "phone123", context: context,
            transport: transport, now: newer
        )
        XCTAssertEqual(unfollowed.applied.unfollows, 1)
        XCTAssertTrue(podcast.isCatalogOnly)
        let maybeOwnedAfter = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123"
        )
        let ownedAfter = try XCTUnwrap(maybeOwnedAfter)
        XCTAssertTrue(try rows(ownedAfter).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 1)
        XCTAssertEqual(try Data(contentsOf: peerPath), tombstone)
    }

    func testDisposableCoordinatorImportsPeerPlaceWithoutEchoAcrossTwoPassesAndReopen() async throws {
        guard ProcessInfo.processInfo.environment["EARSHOT_LP_DISPOSABLE_SYNC"] == "1",
              let pinnedPath = ProcessInfo.processInfo.environment["QUILL_PEER_FIXTURE_PATH"]
        else { throw XCTSkip("Requires explicit disposable runner gate and pinned QUILL fixture") }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "places-episode-receiver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try root.bookmarkData(options: .minimalBookmark,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        let transport = ListeningPlacesFileTransport()
        try await transport.prepareFolder(bookmarkData: bookmark)
        try await transport.writeDeviceFile(
            bookmarkData: bookmark, deviceID: "aabb1234", data: try ListeningPlacesFormat.encodedDeviceFile(
                deviceID: "aabb1234", appVersion: "earshot/1.3.1",
                writtenAt: newer, records: []
            )
        )
        let peerPath = root.appending(path: "Listening Places/devices/desktop99.json")
        let pinned = try Data(contentsOf: URL(fileURLWithPath: pinnedPath))
        var peerRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: pinned) as? [String: Any])
        let timestamp = try XCTUnwrap(peerRoot["written_at"] as? String)
        let peerTime = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
        let id = ListeningPlacesFormat.episodeID(
            guid: "receiver-episode", enclosureURL: "https://example.com/receiver.mp3"
        )
        var records = try XCTUnwrap(peerRoot["records"] as? [[String: Any]])
        records.append(["id": id, "kind": "episode", "position_ms": 409_421,
                        "played": false, "updated_at": timestamp])
        records.append(["id": "episode:0000000000000000", "kind": "episode",
                        "position_ms": 20_000, "played": false, "updated_at": timestamp])
        peerRoot["records"] = records
        let peer = try JSONSerialization.data(withJSONObject: peerRoot, options: [.sortedKeys])
        try peer.write(to: peerPath, options: .atomic)

        let store = root.appending(path: "store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        func openStore() throws -> ModelContainer {
            try ModelContainer(for: Schema(versionedSchema: EarshotSchemaV14.self),
                configurations:
                    ModelConfiguration("FutureMirrored",
                        schema: Schema(EarshotSchemaV14.mirroredModels),
                        url: store.appending(path: "mirrored.store"), cloudKitDatabase: .none),
                    ModelConfiguration("DeviceLocal",
                        schema: Schema(EarshotSchemaV14.localModels),
                        url: store.appending(path: "local.store"), cloudKitDatabase: .none))
        }
        let container = try openStore()
        let context = ModelContext(container)
        let podcast = Podcast(feedURL: feed, title: "Disposable public")
        let episode = Episode(guid: "receiver-episode", title: "Receiver",
                              audioURL: "https://example.com/receiver.mp3",
                              positionSeconds: 60)
        let other = Episode(guid: "untouched", title: "Untouched",
                            audioURL: "https://example.com/untouched.mp3",
                            positionSeconds: 31)
        episode.podcast = podcast
        other.podcast = podcast
        episode.inboxDismissed = true
        context.insert(podcast)
        context.insert(episode)
        context.insert(other)
        context.insert(QueueItem(episode: episode, position: 0))
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "aabb1234",
            now: peerTime.addingTimeInterval(-120)
        )
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        // Episode import is independently gated; no subscription sharing is
        // needed for a preexisting approved public local catalog episode.
        try ListeningPlacesSubscriptionTestCoordinator.stagePolicy(.init(), in: context)
        try ListeningPlacesSubscriptionTestCoordinator.stageEpisodeImportForTesting(in: context)
        try context.save()
        var loaded: PersistentIdentifier? = episode.persistentModelID
        let first = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "aabb1234", context: context,
            transport: transport, now: peerTime.addingTimeInterval(60),
            loadedEpisodeID: { loaded }
        )
        XCTAssertEqual(first.episodes.applied, 0)
        XCTAssertEqual(first.episodes.deferredLoaded, 1)
        XCTAssertEqual(episode.positionSeconds, 60)
        loaded = nil
        let second = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "aabb1234", context: context,
            transport: transport, now: peerTime.addingTimeInterval(60),
            loadedEpisodeID: { loaded }
        )
        XCTAssertEqual(second.episodes.applied, 1)
        XCTAssertEqual(episode.positionSeconds, 409)
        XCTAssertEqual(other.positionSeconds, 31)
        let ownedBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "aabb1234"
        )
        let owned = try XCTUnwrap(ownedBytes)
        XCTAssertTrue(try rows(owned).filter {
            ($0["id"] as? String)?.hasPrefix("episode:") == true
        }.isEmpty, "peer place must not echo into Earshot's owned file")
        XCTAssertEqual(try Data(contentsOf: peerPath), peer)

        let reopened = ModelContext(try openStore())
        let saved = try XCTUnwrap(reopened.fetch(FetchDescriptor<Episode>()).first {
            $0.guid == "receiver-episode"
        })
        XCTAssertEqual(saved.positionSeconds, 409)
        XCTAssertTrue(saved.inboxDismissed)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<QueueItem>()), 1)
        guard case .event(let clock) = try ListeningPlacesEventJournal.read(
            for: saved, in: reopened
        ) else { return XCTFail("peer event clock was not durable") }
        XCTAssertEqual(clock.updatedAt, peerTime)
        XCTAssertEqual(clock.sourceDeviceID, "desktop99")
        XCTAssertEqual(clock.positionMilliseconds, 409_421,
                       "peer millisecond precision must retain its original event identity")
        let directLoader = await ListeningPlacesSnapshotLoader.makeBackground(
            modelContainer: reopened.container
        )
        let directSnapshot = try await directLoader.prepare(
            pendingZeroSnapshots: [], includeLabels: false,
            previousRecords: [], previousSignatures: [:], previousUpdatedAtByID: [:],
            deviceID: "aabb1234", appVersion: "earshot/1.3.1",
            now: peerTime.addingTimeInterval(60)
        )
        XCTAssertFalse(directSnapshot.records.contains { $0.id == id },
                       "background exporter must skip the imported episode")
        XCTAssertEqual(directSnapshot.records.count, 1,
                       "unrelated legacy one-way export must remain available")
        let settings = AppSettingsStore(context: reopened)
        settings.setRawValue("aabb1234", for: SettingsKey.listeningPlacesDeviceID)
        try reopened.save()
        let normalExporter = ListeningPlacesService()
        normalExporter.configure(context: reopened)
        await normalExporter.chooseFolder(root)
        await normalExporter.writeNow()
        let normalBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "aabb1234"
        )
        let normalOwned = try XCTUnwrap(normalBytes)
        XCTAssertFalse(try rows(normalOwned).contains {
            $0["id"] as? String == id
        }, "normal export must not echo a peer-origin place as a local event")
        XCTAssertTrue(try rows(normalOwned).contains {
            $0["id"] as? String == ListeningPlacesFormat.episodeID(
                guid: other.guid, enclosureURL: other.audioURL
            )
        }, "legacy one-way export must remain available")
        normalExporter.releasePersistence()
        let repeated = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "aabb1234", context: reopened,
            transport: transport, now: peerTime.addingTimeInterval(60),
            loadedEpisodeID: { nil }
        )
        XCTAssertEqual(repeated.episodes.applied, 0)
        XCTAssertEqual(saved.positionSeconds, 409)

        XCTAssertFalse(try ListeningPlacesEventJournal.stageLocalMutation(
            of: saved, in: reopened, deviceID: "aabb1234",
            now: peerTime.addingTimeInterval(70)
        ), "a same-second checkpoint must not restamp the imported place")
        XCTAssertEqual(try ListeningPlacesEventJournal.read(for: saved, in: reopened),
                       .event(clock))
        saved.positionSeconds = 300
        let localSeekTime = peerTime.addingTimeInterval(90)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: saved, in: reopened, deviceID: "aabb1234", now: localSeekTime
        )
        try reopened.save()
        let afterSeekExporter = ListeningPlacesService()
        afterSeekExporter.configure(context: reopened)
        await afterSeekExporter.chooseFolder(root)
        await afterSeekExporter.writeNow()
        let afterSeekBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "aabb1234"
        )
        let afterSeek = try XCTUnwrap(afterSeekBytes)
        let seekRow = try XCTUnwrap(rows(afterSeek).first { $0["id"] as? String == id })
        XCTAssertEqual(seekRow["position_ms"] as? Int, 300_000)
        XCTAssertEqual(seekRow["updated_at"] as? String,
                       ISO8601DateFormatter().string(from: localSeekTime))
        afterSeekExporter.releasePersistence()
        guard case .event(let committedSeek) = try ListeningPlacesEventJournal.read(
            for: saved, in: reopened
        ) else { return XCTFail("local seek clock must remain readable") }
        XCTAssertEqual(committedSeek.updatedAt, localSeekTime)
        XCTAssertEqual(committedSeek.sourceDeviceID, "aabb1234")
        #if EARSHOT_LP_PLAYBACK_TRIAL
        // Choosing a folder revokes inbound consent even when a disposable
        // test selects the same URL again; explicitly opt in for the next pass.
        try ListeningPlacesSubscriptionTestCoordinator.setTrialImportEnabled(true, in: reopened)
        #endif

        func replacePeerPlace(position: Int, played: Bool, secondsLater: TimeInterval) throws {
            let eventTime = peerTime.addingTimeInterval(secondsLater)
            let timeText = ISO8601DateFormatter().string(from: eventTime)
            var updated = peerRoot
            updated["written_at"] = timeText
            var updatedRows = records.filter { $0["id"] as? String != id }
            updatedRows.append(["id": id, "kind": "episode",
                                "position_ms": position, "played": played,
                                "updated_at": timeText])
            updated["records"] = updatedRows
            try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
                .write(to: peerPath, options: .atomic)
        }
        try replacePeerPlace(position: 90_000, played: true, secondsLater: 120)
        let forwardBytes = try Data(contentsOf: peerPath)
        let forwardParsed = try ListeningPlacesInboundParser.parse(
            data: forwardBytes, now: peerTime.addingTimeInterval(180)
        )
        XCTAssertEqual(forwardParsed.entries.first { $0.record.id == id }?
            .record.positionMilliseconds, 90_000)
        let forwardRemote = forwardParsed.entries.filter { $0.record.id == id }.map {
            ListeningPlacesRemoteEvent(deviceID: forwardParsed.deviceID, entry: $0)
        }
        XCTAssertEqual(ListeningPlacesMergePlanner.decide(
            id: id, local: .event(committedSeek), remote: forwardRemote, isLoaded: false
        ), .apply(ListeningPlacesStateEvent(
            id: id, positionMilliseconds: 90_000, played: true,
            updatedAt: peerTime.addingTimeInterval(120),
            sourceDeviceID: "desktop99", isReset: false
        )))
        let forward = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "aabb1234", context: reopened,
            transport: transport, now: peerTime.addingTimeInterval(180),
            loadedEpisodeID: { nil }
        )
        XCTAssertEqual(forward.episodes.applied, 1)
        XCTAssertEqual(saved.positionSeconds, 90)
        XCTAssertTrue(saved.isPlayed)
        XCTAssertEqual(saved.playedAt, peerTime.addingTimeInterval(120))
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<QueueItem>()), 1)
        try replacePeerPlace(position: 0, played: false, secondsLater: 240)
        let reset = try await ListeningPlacesSubscriptionTestCoordinator.sync(
            bookmarkData: bookmark, ownDeviceID: "aabb1234", context: reopened,
            transport: transport, now: peerTime.addingTimeInterval(300),
            loadedEpisodeID: { nil }
        )
        XCTAssertEqual(reset.episodes.applied, 1)
        XCTAssertEqual(saved.positionSeconds, 0)
        XCTAssertFalse(saved.isPlayed)
        XCTAssertNil(saved.playedAt)
        let afterResetBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "aabb1234"
        )
        let afterReset = try XCTUnwrap(afterResetBytes)
        let retainedLocalRow = try XCTUnwrap(rows(afterReset).first {
            $0["id"] as? String == id
        })
        XCTAssertEqual(retainedLocalRow["position_ms"] as? Int, 300_000)
        XCTAssertEqual(retainedLocalRow["updated_at"] as? String,
                       ISO8601DateFormatter().string(from: localSeekTime),
                       "an older owned local event may remain, but a peer reset must not echo")
        // A subsequent real local seek/Played event may supersede the peer
        // reset, but the normal exporter must use that event's clock, not the
        // later time at which the provider file happens to be rewritten.
        let localTime = peerTime.addingTimeInterval(360)
        saved.positionSeconds = 45
        saved.isPlayed = true
        saved.playedAt = localTime
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: saved, in: reopened, deviceID: "aabb1234", now: localTime
        )
        try reopened.save()
        let localExporter = ListeningPlacesService()
        localExporter.configure(context: reopened)
        await localExporter.chooseFolder(root)
        await localExporter.writeNow()
        let afterLocalBytes = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "aabb1234"
        )
        let afterLocal = try XCTUnwrap(afterLocalBytes)
        let localRow = try XCTUnwrap(rows(afterLocal).first { $0["id"] as? String == id })
        XCTAssertEqual(localRow["position_ms"] as? Int, 45_000)
        XCTAssertEqual(localRow["played"] as? Bool, true)
        XCTAssertEqual(localRow["updated_at"] as? String,
                       ISO8601DateFormatter().string(from: localTime))
        XCTAssertTrue(try rows(afterLocal).contains {
            $0["id"] as? String == ListeningPlacesFormat.episodeID(
                guid: other.guid, enclosureURL: other.audioURL
            )
        })
        localExporter.releasePersistence()
    }

    func testEpisodeReceiverDefersAmbiguousIDsConflictingRowsAndStaleFiles() throws {
        let context = TestStore.freshContext()
        try ListeningPlacesPlaybackReceiveConsent.stageEnabled(true, in: context)
        let firstShow = Podcast(feedURL: feed, title: "First")
        let secondFeed = "https://example.com/second.xml"
        let secondShow = Podcast(feedURL: secondFeed, title: "Second")
        let first = Episode(guid: "same-id", title: "First episode",
                            audioURL: "https://example.com/first.mp3", positionSeconds: 10)
        let second = Episode(guid: "same-id", title: "Second episode",
                             audioURL: "https://example.com/second.mp3", positionSeconds: 20)
        first.podcast = firstShow
        second.podcast = secondShow
        for model in [firstShow, secondShow] { context.insert(model) }
        for model in [first, second] { context.insert(model) }
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: secondFeed, in: context)
        let localTime = Date(timeIntervalSince1970: 1_000)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: first, in: context, deviceID: "phone123", now: localTime
        )
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: second, in: context, deviceID: "phone123", now: localTime
        )
        try context.save()
        let id = ListeningPlacesFormat.episodeID(
            guid: first.guid, enclosureURL: first.audioURL
        )
        let peerTime = Date(timeIntervalSince1970: 1_200)
        let valid = placeRecord(id: id, position: 30_000, at: peerTime)
        let file = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "desktop99", appVersion: "quill/test", writtenAt: peerTime,
            records: [valid]
        )
        let ambiguous = try ListeningPlacesEpisodeTestReceiver.apply(
            [("desktop99", file)], in: context, ownDeviceID: "phone123",
            now: peerTime.addingTimeInterval(1), loadedEpisodeID: { nil }
        )
        XCTAssertEqual(ambiguous.applied, 0)
        XCTAssertEqual(first.positionSeconds, 10)
        XCTAssertEqual(second.positionSeconds, 20)

        context.delete(second)
        try context.save()
        let conflict = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "desktop99", appVersion: "quill/test", writtenAt: peerTime,
            records: [valid, placeRecord(id: id, position: 40_000, at: peerTime)]
        )
        let tied = try ListeningPlacesEpisodeTestReceiver.apply(
            [("desktop99", conflict)], in: context, ownDeviceID: "phone123",
            now: peerTime.addingTimeInterval(1), loadedEpisodeID: { nil }
        )
        XCTAssertEqual(tied.applied, 0)
        XCTAssertEqual(first.positionSeconds, 10)
        let stale = try ListeningPlacesEpisodeTestReceiver.apply(
            [("desktop99", file)], in: context, ownDeviceID: "phone123",
            now: peerTime.addingTimeInterval(181 * 24 * 60 * 60),
            loadedEpisodeID: { nil }
        )
        XCTAssertEqual(stale.applied, 0)
        XCTAssertEqual(first.positionSeconds, 10)
    }

    func testEpisodeReceiverDefersPrivateUnknownLegacyAndMissingRows() throws {
        let context = TestStore.freshContext()
        try ListeningPlacesPlaybackReceiveConsent.stageEnabled(true, in: context)
        let privateFeed = "https://example.com/private.xml?token=synthetic"
        let privateShow = Podcast(feedURL: privateFeed, title: "Private")
        let privateEpisode = Episode(guid: "private", title: "Private episode",
                                     audioURL: "https://example.com/private.mp3",
                                     positionSeconds: 10)
        privateEpisode.podcast = privateShow
        let publicShow = Podcast(feedURL: feed, title: "Public")
        let legacy = Episode(guid: "legacy", title: "Old state",
                             audioURL: "https://example.com/legacy.mp3",
                             positionSeconds: 20)
        legacy.podcast = publicShow
        context.insert(privateShow)
        context.insert(privateEpisode)
        context.insert(publicShow)
        context.insert(legacy)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: privateEpisode, in: context, deviceID: "phone123",
            now: Date(timeIntervalSince1970: 1_000)
        )
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try context.save()
        let peerTime = Date(timeIntervalSince1970: 1_200)
        let file = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "desktop99", appVersion: "quill/test", writtenAt: peerTime,
            records: [
                placeRecord(id: ListeningPlacesFormat.episodeID(
                    guid: privateEpisode.guid, enclosureURL: privateEpisode.audioURL
                ), position: 30_000, at: peerTime),
                placeRecord(id: ListeningPlacesFormat.episodeID(
                    guid: legacy.guid, enclosureURL: legacy.audioURL
                ), position: 40_000, at: peerTime),
                placeRecord(id: "episode:0000000000000000", position: 50_000, at: peerTime),
            ]
        )
        let result = try ListeningPlacesEpisodeTestReceiver.apply(
            [("desktop99", file)], in: context, ownDeviceID: "phone123",
            now: peerTime.addingTimeInterval(1), loadedEpisodeID: { nil }
        )
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.deferred, 3)
        XCTAssertEqual(privateEpisode.positionSeconds, 10)
        XCTAssertEqual(legacy.positionSeconds, 20)
    }

    func testEpisodeReceiverRollsBackIfEpisodeLoadsBeforeSaveBoundary() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let podcast = Podcast(feedURL: feed, title: "Disposable")
        let episode = Episode(guid: "loaded-late", title: "Loaded late",
                              audioURL: "https://example.com/loaded-late.mp3",
                              positionSeconds: 10)
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(for: feed, in: context)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone123",
            now: Date(timeIntervalSince1970: 1_000)
        )
        try context.save()
        let id = ListeningPlacesFormat.episodeID(
            guid: episode.guid, enclosureURL: episode.audioURL
        )
        let peerTime = Date(timeIntervalSince1970: 1_200)
        let file = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "desktop99", appVersion: "quill/test", writtenAt: peerTime,
            records: [placeRecord(id: id, position: 20_000, at: peerTime)]
        )
        let off = try ListeningPlacesEpisodeTestReceiver.apply(
            [("desktop99", file)], in: context, ownDeviceID: "phone123",
            now: peerTime.addingTimeInterval(1), loadedEpisodeID: { nil }
        )
        XCTAssertEqual(off.applied, 0)
        XCTAssertEqual(episode.positionSeconds, 10)
        try ListeningPlacesPlaybackReceiveConsent.setEnabled(true, in: context)
        var checks = 0
        XCTAssertThrowsError(try ListeningPlacesEpisodeTestReceiver.apply(
            [("desktop99", file)], in: context, ownDeviceID: "phone123",
            now: peerTime.addingTimeInterval(1), loadedEpisodeID: {
                checks += 1
                return checks >= 3 ? episode.persistentModelID : nil
            }
        )) { error in
            guard case ListeningPlacesEpisodeTestReceiver.ReceiverError.revalidationFailed = error
            else { return XCTFail("expected loaded-row save-boundary rejection") }
        }
        let fresh = ModelContext(container)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(saved.positionSeconds, 10)
        guard case .event(let event) = try ListeningPlacesEventJournal.read(
            for: saved, in: fresh
        ) else { return XCTFail("local event should survive rollback") }
        XCTAssertEqual(event.updatedAt, Date(timeIntervalSince1970: 1_000))
    }

    private func placeRecord(id: String, position: Int, at time: Date) -> ListeningPlaceRecord {
        ListeningPlaceRecord(id: id, kind: "episode", positionMilliseconds: position,
                             durationMilliseconds: nil, played: false, updatedAt: time,
                             label: nil, feed: nil, deleted: nil)
    }

    func testDisposablePlaybackConsentSerializesProviderDelayAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "places-playback-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try root.bookmarkData(options: .minimalBookmark,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        let transport = ListeningPlacesFileTransport()
        try await transport.prepareFolder(bookmarkData: bookmark)
        let empty = try emptyFile()
        try await transport.writeDeviceFile(bookmarkData: bookmark,
            deviceID: "phone123", data: empty)
        let peerPath = root.appending(path: "Listening Places/devices/desktop99.json")
        let peer = try file(records: [])
        try peer.write(to: peerPath)
        let proposed = try JSONSerialization.data(withJSONObject: [
            "format": ListeningPlacesFormat.identifier,
            "device": "phone123", "app": "earshot/debug",
            "written_at": "2027-01-15T08:00:00Z",
            "records": [["id": "episode:synthetic", "kind": "episode",
                         "position_ms": 12_000, "played": false,
                         "updated_at": "2027-01-15T08:00:00Z"]],
        ])

        // Revocation reaches the actor while an earlier provider write waits.
        let first = try await transport.setDisposablePlaybackScopeAndScrub(
            bookmarkData: bookmark, deviceID: "phone123", episodes: true, now: newer)
        _ = try await transport.setDisposablePlaybackScopeAndScrub(
            bookmarkData: bookmark, deviceID: "phone123", episodes: false, now: newer)
        do {
            try await transport.replaceDisposablePlaybackFileWithConsent(
                bookmarkData: bookmark, deviceID: "phone123",
                expected: empty, with: proposed, token: first.token, now: newer)
            XCTFail("A stale writer must not disclose an episode after revocation")
        } catch ListeningPlacesFileTransport.ConsentError.staleScope {}
        let afterEarlyRevoke = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123")
        XCTAssertEqual(afterEarlyRevoke, empty)

        // The write reaches the actor first; the later revocation must scrub
        // the owned file before acknowledging Off, leaving the peer untouched.
        let second = try await transport.setDisposablePlaybackScopeAndScrub(
            bookmarkData: bookmark, deviceID: "phone123", episodes: true, now: newer)
        do {
            try await transport.replaceDisposablePlaybackFileWithConsent(
                bookmarkData: bookmark, deviceID: "phone123",
                expected: empty, with: peer, token: second.token, now: newer)
            XCTFail("A peer-root payload must not be written as this device")
        } catch ListeningPlacesFileTransport.ConsentError.foreignOwnedFile {}
        try await transport.replaceDisposablePlaybackFileWithConsent(
            bookmarkData: bookmark, deviceID: "phone123",
            expected: empty, with: proposed, token: second.token, now: newer)
        let afterWrite = try await transport.readDeviceFile(
            bookmarkData: bookmark, deviceID: "phone123")
        XCTAssertEqual(try rows(try XCTUnwrap(afterWrite)).count, 1)
        let revoked = try await transport.setDisposablePlaybackScopeAndScrub(
            bookmarkData: bookmark, deviceID: "phone123", episodes: false, now: newer)
        XCTAssertTrue(revoked.scrubbed)
        XCTAssertTrue(try rows(try XCTUnwrap(revoked.ownedFile)).isEmpty)
        XCTAssertEqual(try Data(contentsOf: peerPath), peer)
    }

    private func file(records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": ListeningPlacesFormat.identifier,
            "device": "peer1234", "app": "quill-cast/1.0.0",
            "written_at": "2027-01-15T08:00:00Z", "records": records,
        ])
    }
}
