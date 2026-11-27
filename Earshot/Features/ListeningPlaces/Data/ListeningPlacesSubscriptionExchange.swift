import CryptoKit
import Foundation
import SwiftData

/// An explicit, opt-in transaction boundary for disposable two-app conformance.
/// Nothing in the shipped app invokes this coordinator. In particular, the
/// Listening Places reader still does not apply peer episode places.
@MainActor
enum ListeningPlacesSubscriptionExchange {
    struct Policy: Codable, Equatable {
        var shareSubscriptions = false
        var acceptFollows = false
        var acceptUnfollows = false
    }

    struct ApplyResult: Equatable {
        var follows = 0
        var unfollows = 0
        var deferred = 0
        var privateRows = 0
    }

    enum ExchangeError: Error {
        case invalidFile
        case fileTooLarge
    }

    private static let maximumBytes = 2 * 1_024 * 1_024
    private static let maximumAuxiliaryRows = 2_000
    private static let importedClockPrefix = "listening_places_subscription_import_clock_v1:"
    private static let dateReader = ISO8601DateFormatter()
    private static let fractionalDateReader: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ text: String) -> Date? {
        fractionalDateReader.date(from: text) ?? dateReader.date(from: text)
    }

    /// Compose subscriptions beside the existing bounded episode rows. The
    /// caller supplies only this device's file and must write it using the
    /// existing owned-file CAS; this method never opens or edits peer files.
    static func exportOwnedFile(
        episodeFile: Data, context: ModelContext, policy: Policy,
        carriedPeerRows: [[String: Any]] = [], now: Date = .now
    ) throws -> Data {
        guard episodeFile.count <= maximumBytes,
              var root = (try? JSONSerialization.jsonObject(with: episodeFile)) as? [String: Any],
              root["format"] as? String == ListeningPlacesFormat.identifier,
              let originalRows = root["records"] as? [[String: Any]] else {
            throw ExchangeError.invalidFile
        }
        guard policy.shareSubscriptions else { return episodeFile }
        let episodeRows = originalRows.filter {
            ($0["id"] as? String)?.hasPrefix("episode:") == true
        }
        let localOnly = try ListeningPlacesFeedPrivacy.deviceOnlyKeys(in: context)
        let approved = try ListeningPlacesPublicFeedApproval.approvedKeys(in: context)
        let podcasts = try context.fetch(PodcastQuery.followedDescriptor())
        var rows = episodeRows
        var sharedIDs = Set<String>()
        var localFolders: [String: [String: Any]] = [:]
        for podcast in podcasts {
            let feed = podcast.feedURL
            guard ListeningPlacesFeedPrivacy.mayShare(
                feedURL: feed, deviceOnlyKeys: localOnly
            ), approved.contains(ListeningPlacesPublicFeedApproval.key(feed)),
                  let canonical = ListeningPlacesSubscriptionIdentity.canonicalURL(feed),
                  let id = ListeningPlacesSubscriptionIdentity.shareableID(feed)
            else { continue }
            guard sharedIDs.insert(id).inserted else { continue }
            let time = dateReader.string(from: podcast.createdAt)
            // An imported follow may carry an older update clock than the
            // peer's first-follow time. Re-export its original event time;
            // composing a file is never a new subscription mutation.
            let importedClock = LocalAppSettingIdentity.value(
                for: importedClockPrefix + id, in: context
            )
            let eventTime: String
            if let importedClock, date(importedClock) != nil {
                eventTime = importedClock
            } else {
                eventTime = time
            }
            var row: [String: Any] = [
                "id": id, "kind": "subscription", "feed_url": canonical,
                "alt_urls": [canonical], "title": podcast.title,
                "private": false, "subscribed_at": time, "updated_at": eventTime,
                "folders": [String](),
            ]
            let memberships = (podcast.folderMemberships ?? []).sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return String(describing: $0.persistentModelID)
                    < String(describing: $1.persistentModelID)
            }
            var folderIDs: [String] = []
            for membership in memberships {
                guard let folder = membership.folder else { continue }
                let folderKey = folderID(folder)
                guard !folderIDs.contains(folderKey) else { continue }
                folderIDs.append(folderKey)
                localFolders[folderKey] = folderRow(folder)
                if let parent = folder.parent {
                    localFolders[folderID(parent)] = folderRow(parent)
                }
            }
            row["folders"] = folderIDs
            if let speed = podcast.speedOverride, speed.isFinite,
               (0.5...4).contains(speed) {
                row["prefs"] = ["speed": speed]
            }
            // Retain unfamiliar peer metadata and extra folder memberships
            // without allowing it to override Earshot's privacy or identity.
            if let prior = carriedPeerRows.first(where: { $0["id"] as? String == id }),
               prior["deleted"] as? Bool != true {
                for (key, value) in prior where ![
                    "id", "kind", "feed_url", "alt_urls", "title", "private",
                    "subscribed_at", "updated_at", "deleted", "prefs", "folders",
                ].contains(key) {
                    row[key] = value
                }
                if let folders = prior["folders"] as? [String] {
                    for folder in folders.prefix(64) where !folderIDs.contains(folder) {
                        folderIDs.append(folder)
                    }
                    row["folders"] = folderIDs
                }
            }
            rows.append(row)
        }
        let carriedFolders = carriedPeerRows.filter {
            guard let id = $0["id"] as? String, id.hasPrefix("folder:") else { return false }
            return ($0["kind"] as? String) == "folder"
                && ($0["deleted"] as? Bool) != true
        }
        let referenced = Set(rows.compactMap { row -> [String]? in
            guard (row["kind"] as? String) == "subscription" else { return nil }
            return row["folders"] as? [String]
        }.flatMap { $0 })
        rows.append(contentsOf: localFolders.values)
        rows.append(contentsOf: carriedFolders.filter {
            let id = $0["id"] as? String ?? ""
            return referenced.contains(id) && localFolders[id] == nil
        }.prefix(maximumAuxiliaryRows))
        guard rows.count - episodeRows.count <= maximumAuxiliaryRows else {
            throw ExchangeError.fileTooLarge
        }
        root["records"] = rows
        root["written_at"] = dateReader.string(from: now)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw ExchangeError.fileTooLarge }
        return data
    }

    private static func folderID(_ folder: PodcastFolder) -> String {
        let source = String(describing: folder.persistentModelID)
        let prefix = SHA256.hash(data: Data(source.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        return "folder:\(prefix)"
    }

    private static func folderRow(_ folder: PodcastFolder) -> [String: Any] {
        var row: [String: Any] = [
            "id": folderID(folder), "kind": "folder", "name": folder.name,
            "updated_at": dateReader.string(from: folder.createdAt),
            "sortOrder": folder.sortOrder,
        ]
        if let parent = folder.parent { row["parent"] = folderID(parent) }
        return row
    }

    /// Applies only validated follow/unfollow facts. Folder/prefs application
    /// and episode import remain deferred; callers can carry those raw rows
    /// back through `exportOwnedFile` without changing the local library.
    static func applyPeerFile(
        _ data: Data, context: ModelContext, policy: Policy,
        expectedPeerID: String, ownDeviceID: String,
        now: Date = .now
    ) throws -> ApplyResult {
        guard data.count <= maximumBytes else { throw ExchangeError.fileTooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["format"] as? String == ListeningPlacesFormat.identifier,
              let device = root["device"] as? String,
              device == expectedPeerID, device != ownDeviceID,
              let app = root["app"] as? String, !app.isEmpty,
              let writtenAt = root["written_at"] as? String,
              date(writtenAt) != nil,
              let rawRows = root["records"] as? [Any] else {
            throw ExchangeError.invalidFile
        }
        guard policy.shareSubscriptions else { return ApplyResult() }
        let rows = rawRows.compactMap { $0 as? [String: Any] }
        let localOnly = try ListeningPlacesFeedPrivacy.deviceOnlyKeys(in: context)
        let approved = try ListeningPlacesPublicFeedApproval.approvedKeys(in: context)
        var result = ApplyResult()
        result.deferred = rawRows.count - rows.count
            + max(0, rows.count - ListeningPlacesFormat.maximumRecordCount - maximumAuxiliaryRows)
        var appliedIDs = Set<String>()
        let existing = try context.fetch(FetchDescriptor<Podcast>())
        var podcastsByID: [String: Podcast] = [:]
        var localCanonicalURLs = Set<String>()
        for podcast in existing {
            if let id = ListeningPlacesSubscriptionIdentity.shareableID(podcast.feedURL) {
                podcastsByID[id] = podcast
            }
            if let canonical = ListeningPlacesSubscriptionIdentity.canonicalURL(podcast.feedURL) {
                localCanonicalURLs.insert(canonical)
            }
        }
        let candidates = rows.prefix(ListeningPlacesFormat.maximumRecordCount + maximumAuxiliaryRows)
            .filter { ($0["id"] as? String)?.hasPrefix("sub:") == true }
            .sorted { left, right in
                let l = (left["updated_at"] as? String).flatMap(date) ?? .distantPast
                let r = (right["updated_at"] as? String).flatMap(date) ?? .distantPast
                if l != r { return l > r }
                let lDeleted = left["deleted"] as? Bool == true
                let rDeleted = right["deleted"] as? Bool == true
                if lDeleted != rDeleted { return lDeleted }
                return (left["id"] as? String ?? "") < (right["id"] as? String ?? "")
            }
        for row in candidates {
            guard let id = row["id"] as? String, id.hasPrefix("sub:") else { continue }
            guard !appliedIDs.contains(id) else { result.deferred += 1; continue }
            appliedIDs.insert(id)
            guard let timeString = row["updated_at"] as? String,
                  let eventTime = date(timeString),
                  eventTime <= now.addingTimeInterval(24 * 60 * 60)
            else { result.deferred += 1; continue }
            let deleted = row["deleted"] as? Bool == true
            if !deleted && (row["private"] as? Bool != false) {
                result.privateRows += 1
                continue
            }
            if deleted {
                // A local show has no durable follow-event clock yet. Even a
                // newer peer tombstone cannot safely override local intent.
                // Limit this harness path to follows this peer introduced.
                let importedClock = LocalAppSettingIdentity.value(
                    for: importedClockPrefix + id, in: context
                ).flatMap(date)
                guard policy.acceptUnfollows,
                      let podcast = podcastsByID[id], podcast.isFollowed,
                      let importedClock, importedClock < eventTime,
                      approved.contains(ListeningPlacesPublicFeedApproval.key(podcast.feedURL)),
                      ListeningPlacesFeedPrivacy.mayShare(
                        feedURL: podcast.feedURL, deviceOnlyKeys: localOnly
                      ),
                      podcast.createdAt <= eventTime else {
                    result.deferred += 1; continue
                }
                if try ListeningPlacesSubscriptionRetention.stageRemoteUnfollow(
                    podcast, in: context
                ) { result.unfollows += 1 }
            } else {
                guard let feed = row["feed_url"] as? String,
                      feed.utf8.count <= 4_096,
                      let expectedID = ListeningPlacesSubscriptionIdentity.shareableID(feed),
                      expectedID == id,
                      ListeningPlacesFeedPrivacy.mayShare(
                        feedURL: feed, deviceOnlyKeys: localOnly
                      ) else { result.privateRows += 1; continue }
                guard approved.contains(ListeningPlacesPublicFeedApproval.key(feed))
                else { result.deferred += 1; continue }
                let canonical = FeedURLIdentity.canonical(feed)
                guard policy.acceptFollows,
                      let firstFollow = row["subscribed_at"] as? String,
                      let subscribedAt = date(firstFollow),
                      subscribedAt <= now.addingTimeInterval(24 * 60 * 60),
                      let title = row["title"] as? String, !title.isEmpty
                else { result.deferred += 1; continue }
                let aliases = ((row["alt_urls"] as? [String]) ?? [])
                    .compactMap(ListeningPlacesSubscriptionIdentity.canonicalURL)
                let matchesKnownAlias = aliases.contains { localCanonicalURLs.contains($0) }
                if podcastsByID[id] == nil && !matchesKnownAlias {
                    let inserted = Podcast(
                        feedURL: canonical, title: String(title.prefix(256)),
                        createdAt: subscribedAt
                    )
                    if let speed = (row["prefs"] as? [String: Any])?["speed"] as? Double,
                       speed.isFinite, (0.5...4).contains(speed) {
                        inserted.speedOverride = speed
                    }
                    context.insert(inserted)
                    try LocalAppSettingIdentity.setValue(
                        timeString, for: importedClockPrefix + id, in: context
                    )
                    podcastsByID[id] = inserted
                    if let canonicalURL = ListeningPlacesSubscriptionIdentity.canonicalURL(feed) {
                        localCanonicalURLs.insert(canonicalURL)
                    }
                    result.follows += 1
                } else {
                    // Existing local ownership and explicit decisions win until
                    // a durable per-feed event clock can compare both sides.
                    result.deferred += 1
                }
            }
        }
        if context.hasChanges {
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
        return result
    }
}

/// Until a product UI can obtain and revoke per-feed disclosure consent, a
/// missing/ambiguous local approval keeps subscription URLs out of the plain
/// shared file and prevents automatic follows of peer-provided addresses.
/// This is device-local and carries only a hash, never a feed URL or password.
enum ListeningPlacesPublicFeedApproval {
    private static let prefix = "listening_places_public_feed_approval_v1:"

    static func key(_ feedURL: String) -> String {
        let canonical = ListeningPlacesSubscriptionIdentity.canonicalURL(feedURL) ?? feedURL
        let hash = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return prefix + hash
    }

    static func approvedKeys(in context: ModelContext) throws -> Set<String> {
        let prefix = Self.prefix
        let rows = try context.fetch(FetchDescriptor<LocalAppSetting>(predicate: #Predicate {
            $0.key.starts(with: prefix)
        }))
        let grouped = Dictionary(grouping: rows, by: \.key)
        return Set(grouped.compactMap { key, values in
            values.count == 1 && values[0].value == "approved" ? key : nil
        })
    }

    #if DEBUG
    static func stageDisposableApproval(for feedURL: String, in context: ModelContext) throws {
        guard ListeningPlacesSubscriptionIdentity.shareableID(feedURL) != nil else {
            throw ListeningPlacesSubscriptionExchange.ExchangeError.invalidFile
        }
        try LocalAppSettingIdentity.setValue("approved", for: key(feedURL), in: context)
    }
    #endif
}

#if DEBUG
/// Exercises the real coordinated file transport in disposable XCTest stores.
/// There is no app/Settings caller. Release builds omit this coordinator, and
/// the extra runner gate stays off even in ordinary Debug app launches.
@MainActor
enum ListeningPlacesSubscriptionTestCoordinator {
    private static let policyKey = "listening_places_disposable_subscription_policy_v1"
    private static let episodeImportKey = "listening_places_disposable_episode_import_v1"
    private static let runnerGate = "EARSHOT_LP_DISPOSABLE_SYNC"

    struct Result {
        var applied = ListeningPlacesSubscriptionExchange.ApplyResult()
        var episodes = ListeningPlacesEpisodeTestReceiver.Result()
        var wroteOwnedFile = false
        var peerFilesRead = 0
    }

    enum CoordinatorError: Error {
        case foreignOwnedFile
        case policyChanged
        case missingLoadedEpisodeProvider
        case dirtyContext
    }

    static func stagePolicy(
        _ policy: ListeningPlacesSubscriptionExchange.Policy, in context: ModelContext
    ) throws {
        let data = try JSONEncoder().encode(policy)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ListeningPlacesSubscriptionExchange.ExchangeError.invalidFile
        }
        try LocalAppSettingIdentity.setValue(raw, for: policyKey, in: context)
    }

    static func stageEpisodeImportForTesting(in context: ModelContext) throws {
        try LocalAppSettingIdentity.setValue("enabled", for: episodeImportKey, in: context)
    }

    private static func policy(in context: ModelContext)
        -> ListeningPlacesSubscriptionExchange.Policy? {
        guard ProcessInfo.processInfo.environment[runnerGate] == "1",
              let raw = LocalAppSettingIdentity.value(for: policyKey, in: context)
        else { return nil }
        return try? JSONDecoder().decode(
            ListeningPlacesSubscriptionExchange.Policy.self, from: Data(raw.utf8)
        )
    }

    static func sync(
        bookmarkData: Data, ownDeviceID: String, context: ModelContext,
        transport: ListeningPlacesFileTransport = ListeningPlacesFileTransport(),
        now: Date = .now,
        loadedEpisodeID: (@MainActor () -> PersistentIdentifier?)? = nil,
        isPlaybackEnabled: (@MainActor () -> Bool)? = nil
    ) async throws -> Result {
        let episodeImportEnabled = LocalAppSettingIdentity.value(
            for: episodeImportKey, in: context
        ) == "enabled"
        guard let initialPolicy = policy(in: context),
              initialPolicy.shareSubscriptions || episodeImportEnabled,
              isPlaybackEnabled?() != false
        else { return Result() }
        guard !context.hasChanges else { throw CoordinatorError.dirtyContext }
        // The disposable Playback-only route serializes its scope and owned
        // file with the same actor. Subscription/folder experiments retain
        // their separate disabled path and are not enabled by this slice.
        let playbackOnly = episodeImportEnabled && !initialPolicy.shareSubscriptions
        let scope: ListeningPlacesFileTransport.ScopeResult?
        let observed: Data
        if playbackOnly {
            let current = try await transport.setDisposablePlaybackScopeAndScrub(
                bookmarkData: bookmarkData, deviceID: ownDeviceID, episodes: true, now: now
            )
            guard let file = current.ownedFile else { return Result() }
            scope = current
            observed = file
        } else {
            scope = nil
            guard let file = try await transport.readDeviceFile(
                bookmarkData: bookmarkData, deviceID: ownDeviceID
            ) else { return Result() }
            observed = file
        }
        guard let root = (try? JSONSerialization.jsonObject(with: observed)) as? [String: Any],
              root["format"] as? String == ListeningPlacesFormat.identifier,
              root["device"] as? String == ownDeviceID,
              (root["app"] as? String)?.hasPrefix("earshot/") == true
        else { throw CoordinatorError.foreignOwnedFile }

        let peers = try await transport.readOtherDeviceFiles(
            bookmarkData: bookmarkData, excludingDeviceID: ownDeviceID
        )
        guard isPlaybackEnabled?() != false else { throw CoordinatorError.policyChanged }
        var result = Result()
        var carried: [[String: Any]] = []
        var episodePeerFiles: [(deviceID: String, data: Data)] = []
        for peer in peers.files {
            try Task.checkCancellation()
            guard policy(in: context) == initialPolicy else { throw CoordinatorError.policyChanged }
            let peerID = String(peer.fileName.dropLast(5))
            guard let parsed = (try? JSONSerialization.jsonObject(with: peer.data)) as? [String: Any],
                  parsed["device"] as? String == peerID,
                  let rawRows = parsed["records"] as? [Any]
            else { continue }
            let rows = rawRows.compactMap { $0 as? [String: Any] }
            let applied: ListeningPlacesSubscriptionExchange.ApplyResult
            do {
                applied = try ListeningPlacesSubscriptionExchange.applyPeerFile(
                    peer.data, context: context, policy: initialPolicy,
                    expectedPeerID: peerID, ownDeviceID: ownDeviceID, now: now
                )
            } catch {
                context.rollback()
                continue
            }
            result.applied.follows += applied.follows
            result.applied.unfollows += applied.unfollows
            result.applied.deferred += applied.deferred
            result.applied.privateRows += applied.privateRows
            result.peerFilesRead += 1
            carried.append(contentsOf: rows.prefix(2_000))
            episodePeerFiles.append((peerID, peer.data))
        }
        guard policy(in: context) == initialPolicy,
              (LocalAppSettingIdentity.value(for: episodeImportKey, in: context)
                == "enabled") == episodeImportEnabled,
              isPlaybackEnabled?() != false
        else { throw CoordinatorError.policyChanged }
        if episodeImportEnabled {
            guard let loadedEpisodeID else { throw CoordinatorError.missingLoadedEpisodeProvider }
            result.episodes = try ListeningPlacesEpisodeTestReceiver.apply(
                episodePeerFiles, in: context, ownDeviceID: ownDeviceID,
                now: now, loadedEpisodeID: loadedEpisodeID
            )
        }
        let composed = try ListeningPlacesSubscriptionExchange.exportOwnedFile(
            episodeFile: observed, context: context,
            policy: initialPolicy, carriedPeerRows: carried, now: now
        )
        if composed != observed {
            guard policy(in: context) == initialPolicy,
                  (LocalAppSettingIdentity.value(for: episodeImportKey, in: context)
                    == "enabled") == episodeImportEnabled,
                  isPlaybackEnabled?() != false else {
                throw CoordinatorError.policyChanged
            }
            if let scope {
                try await transport.replaceDisposablePlaybackFileWithConsent(
                    bookmarkData: bookmarkData, deviceID: ownDeviceID,
                    expected: observed, with: composed, token: scope.token, now: now
                )
            } else {
                try await transport.replaceDeviceFile(
                    bookmarkData: bookmarkData, deviceID: ownDeviceID,
                    expected: observed, with: composed
                )
            }
            result.wroteOwnedFile = true
        }
        return result
    }
}

/// Test-only receiver using real SwiftData Episode and journal rows. It has no
/// normal application caller. The eventual product path must additionally
/// reconcile the owned-file exporter so an imported event cannot be restamped.
@MainActor
enum ListeningPlacesEpisodeTestReceiver {
    struct Result {
        var applied = 0
        var deferredLoaded = 0
        var deferred = 0
    }

    enum ReceiverError: Error { case dirtyContext, revalidationFailed }

    static func apply(
        _ files: [(deviceID: String, data: Data)], in context: ModelContext,
        ownDeviceID: String, now: Date,
        loadedEpisodeID: @MainActor () -> PersistentIdentifier?
    ) throws -> Result {
        guard !context.hasChanges else { throw ReceiverError.dirtyContext }
        var remoteByID: [String: [ListeningPlacesRemoteEvent]] = [:]
        for file in files {
            guard file.deviceID != ownDeviceID,
                  let parsed = try? ListeningPlacesInboundParser.parse(data: file.data, now: now),
                  parsed.deviceID == file.deviceID, !parsed.isStale else { continue }
            for entry in parsed.entries {
                remoteByID[entry.record.id, default: []].append(
                    ListeningPlacesRemoteEvent(deviceID: file.deviceID, entry: entry)
                )
            }
        }
        guard !remoteByID.isEmpty else { return Result() }
        let deviceOnly = try ListeningPlacesFeedPrivacy.deviceOnlyKeys(in: context)
        let approved = try ListeningPlacesPublicFeedApproval.approvedKeys(in: context)
        var matches: [String: [Episode]] = [:]
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Episode>()
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = 256
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }
            for episode in batch {
                let id = ListeningPlacesFormat.episodeID(
                    guid: episode.guid, enclosureURL: episode.audioURL
                )
                if remoteByID[id] != nil { matches[id, default: []].append(episode) }
            }
            if batch.count < 256 { break }
            offset += batch.count
        }
        var result = Result()
        var staged: [(episode: Episode, event: ListeningPlacesStateEvent,
                      feed: String)] = []
        do {
            for id in remoteByID.keys.sorted() {
                guard let rows = matches[id], rows.count == 1, let episode = rows.first,
                      let feed = episode.podcast?.feedURL,
                      ListeningPlacesFeedPrivacy.mayShare(
                        feedURL: feed, deviceOnlyKeys: deviceOnly
                      ),
                      approved.contains(ListeningPlacesPublicFeedApproval.key(feed)),
                      episode.status != .expired
                else { result.deferred += 1; continue }
                let local = try ListeningPlacesEventJournal.read(for: episode, in: context)
                let loaded = loadedEpisodeID() == episode.persistentModelID
                let decision = ListeningPlacesMergePlanner.decide(
                    id: id, local: local, remote: remoteByID[id] ?? [], isLoaded: loaded
                )
                switch decision {
                case .keepLocal: result.deferred += 1
                case .deferLoaded: result.deferredLoaded += 1
                case .apply(let event):
                    guard event.positionMilliseconds >= 0,
                          event.positionMilliseconds % 1_000 == 0,
                          loadedEpisodeID() != episode.persistentModelID,
                          ListeningPlacesFormat.episodeID(
                            guid: episode.guid, enclosureURL: episode.audioURL
                          ) == event.id else {
                        result.deferred += 1; continue
                    }
                    episode.positionSeconds = event.positionMilliseconds / 1_000
                    if event.played {
                        episode.status = .played
                        episode.playedAt = event.updatedAt
                    } else {
                        if episode.status == .played { episode.status = .newEpisode }
                        episode.playedAt = nil
                    }
                    try ListeningPlacesEventJournal.stagePeerEvent(
                        event, for: episode, in: context
                    )
                    staged.append((episode, event, feed))
                    result.applied += 1
                }
            }
            if context.hasChanges {
                guard staged.allSatisfy({ item in
                    loadedEpisodeID() != item.episode.persistentModelID
                        && item.episode.podcast?.feedURL == item.feed
                        && ListeningPlacesFormat.episodeID(
                            guid: item.episode.guid, enclosureURL: item.episode.audioURL
                        ) == item.event.id
                        && ListeningPlacesFeedPrivacy.mayShare(
                            feedURL: item.feed, deviceOnlyKeys: deviceOnly
                        ) && approved.contains(ListeningPlacesPublicFeedApproval.key(item.feed))
                }) else {
                    throw ReceiverError.revalidationFailed
                }
                // No suspension occurs between the final loaded check and save.
                // This is a disposable harness, not a player-facing application.
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
        return result
    }
}
#endif
