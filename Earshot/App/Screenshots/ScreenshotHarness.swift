#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// The six App Store screens the capture harness can boot directly into (#643).
enum ScreenshotScreen: String {
    case inbox
    case queue
    case library
    case episodeList
    case nowPlaying
    case settings
    case downloads
    case feedRefresh
    case listeningPlacesPlayback
}

/// DEBUG-only App Store screenshot harness (#643). Never compiled into a Release
/// build. Driven entirely by launch arguments passed by
/// `scripts/screenshots/capture.sh`:
///
///   -uiTestScreenshotSeed        replace the store with an in-memory one seeded
///                                from `ScreenshotFixtures` (Michael's real feeds)
///   -screenshotScreen <name>     boot straight into one `ScreenshotScreen`
///
/// See `ScreenshotFixtures` for exactly which seeded data is real vs synthesized.
enum ScreenshotHarness {
    static let feedRetryFetcher = FeedRetryScreenshotFeed()

    static var isFolderRunTest: Bool { isSeeding && CommandLine.arguments.contains("-folderRunTest") }

    static var isListeningPlacesPlaybackDemo: Bool {
        isSeeding && requestedScreen == .listeningPlacesPlayback
            && ProcessInfo.processInfo.environment["EARSHOT_LP_DISPOSABLE_SYNC"] == "1"
    }

    static var isSeeding: Bool {
        CommandLine.arguments.contains("-uiTestScreenshotSeed")
    }

    static var requestedScreen: ScreenshotScreen? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-screenshotScreen"), i + 1 < args.count else { return nil }
        return ScreenshotScreen(rawValue: args[i + 1])
    }

    /// True whenever any screenshot launch argument is present. The app skips its
    /// network launch work (feed refresh, entitlement resync) in this mode so the
    /// seeded store stays exactly as fixtured.
    static var isActive: Bool { isSeeding || requestedScreen != nil }

    /// Applies the requested screen from `RootView`'s launch task: selects the
    /// tab, pushes the featured show's episode list, or loads the featured
    /// episode and raises the full player. A no-op when no screen is requested.
    @MainActor
    static func apply(
        in context: ModelContext,
        player: PlayerService,
        selectTab: (RootTab) -> Void,
        pushLibrary: ([Podcast]) -> Void
    ) {
        guard let screen = requestedScreen else { return }
        switch screen {
        case .inbox:
            selectTab(.inbox)
        case .queue:
            selectTab(.queue)
        case .library:
            if CommandLine.arguments.contains("-personalAudioRowTest") {
                context.insert(PersonalAudioItem(
                    title: "Field recording", originalFilename: "field.caf",
                    mediaFilename: "missing-test-media.caf", typeIdentifier: "public.audio",
                    byteSize: 1, contentHash: "personal-audio-row-test"
                ))
                try? context.save()
            }
            if isFolderRunTest {
                let folder = FolderRepository(context: context).createFolder(name: "Backlog test")
                let podcast = Podcast(feedURL: "https://folder.test/feed", title: "Folder test show")
                context.insert(podcast)
                FolderRepository(context: context).add(podcast, to: folder)
                try? context.save()
            }
            selectTab(.library)
        case .downloads:
            if CommandLine.arguments.contains("-downloadActivityTest") {
                seedDownloadActivity(in: context)
            } else if CommandLine.arguments.contains("-largeDownloadActivityTest") {
                seedLargeDownloadActivity(in: context)
            }
            selectTab(.downloads)
        case .feedRefresh:
            let podcast = Podcast(feedURL: "https://feed-retry.test/rss", title: "Feed retry test")
            context.insert(podcast)
            let episode = Episode(guid: "existing", title: "Already downloaded", audioURL: "https://feed-retry.test/audio.mp3")
            episode.podcast = podcast
            context.insert(episode)
            try? context.save()
            FeedRefreshStatusMonitor.shared.finish(SubscriptionRefreshReport(
                notifications: [], attempted: 1, total: 1, succeeded: 0,
                failed: 1, cancelled: false, intendedInsertions: 0, durableInsertions: 0,
                failures: [FeedRefreshFailure(feedURL: podcast.feedURL, podcastTitle: podcast.title,
                                             reason: "Could not download or read this feed.")]
            ))
            selectTab(.settings)
        case .listeningPlacesPlayback:
            guard isListeningPlacesPlaybackDemo else { return }
            selectTab(.settings)
        case .settings:
            // RootView renders DownloadsSettingsView as the Settings-tab root in
            // screenshot mode, so selecting the tab is all that's needed.
            if CommandLine.arguments.contains("-largeDownloadActivityTest") {
                seedLargeDownloadActivity(in: context)
            }
            selectTab(.settings)
        case .episodeList:
            selectTab(.library)
            if let podcast = featuredPodcast(in: context) {
                pushLibrary([podcast])
            }
        case .nowPlaying:
            guard let episode = nowPlayingEpisode(in: context) else { return }
            if CommandLine.arguments.contains("-playerLayoutTransition") { episode.episodeDescription = "Layout test notes without chapters." }
            player.load(episode)
            player.pendingFullPlayerPresentation = true
            if CommandLine.arguments.contains("-playerLayoutTransition") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(12))
                    player.currentTitle = String(repeating: "A long episode title for layout testing. ", count: 6)
                    player.currentArtist = String(repeating: "A long podcast name. ", count: 4)
                    episode.episodeDescription = nil
                    episode.artworkURL = nil
                    episode.podcast?.artworkURL = nil
                    player.setChapters([Chapter(index: 0, startTime: 0, title: "A chapter arriving after the Player opens")])
                    let folder = PodcastFolder(name: "A folder context arriving after loading")
                    context.insert(folder)
                    player.showLayoutTestFailure(folderID: folder.persistentModelID)
                    player.sleepTimer.set(.fiveMinutes)
                }
            }
        }
    }

    @MainActor
    private static func seedDownloadActivity(in context: ModelContext) {
        let podcast = Podcast(feedURL: "https://activity.test/ui", title: "Download activity test")
        context.insert(podcast)
        let failed = Episode(guid: "activity-failed", title: "Failed test episode", audioURL: "")
        let delayed = Episode(guid: "activity-delayed", title: "Delayed test episode", audioURL: "")
        for episode in [failed, delayed] {
            episode.podcast = podcast
            context.insert(episode)
        }
        ActiveDownload.setDownloadStatus(.failed, on: failed, in: context)
        ActiveDownload.setDownloadStatus(.downloading, on: delayed, in: context)
        try? context.save()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            ActiveDownload.setDownloadStatus(.failed, on: delayed, in: context)
            try? context.save()
        }
    }

    /// Populate local state directly, avoiding one fetch per episode while
    /// creating a large, deterministic library for the activity UI test.
    @MainActor
    private static func seedLargeDownloadActivity(in context: ModelContext) {
        let feed = "https://large-activity.test/feed"
        let podcast = Podcast(feedURL: feed, title: "Large activity test")
        context.insert(podcast)
        let completedPath = "large-activity-test.mp3"
        if let directory = try? DownloadPaths.downloadsDirectory() {
            let url = directory.appendingPathComponent(completedPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        }
        let groups: [(String, String, DownloadStatus)] = [
            ("a-completed", "Completed", .downloaded),
            ("b-failed", "Failed", .failed),
            ("c-waiting", "Waiting", .pending),
            ("d-downloading", "Downloading", .downloading)
        ]
        for (prefix, title, status) in groups {
            for index in 0..<500 {
                let number = String(format: "%04d", index)
                let guid = "\(prefix)-\(number)"
                let path = status == .downloaded ? completedPath : nil
                let episode = Episode(guid: guid, title: "Large \(title) episode \(number)",
                                      audioURL: "", downloadStatus: status, downloadPath: path)
                episode.podcast = podcast
                context.insert(episode)
                context.insert(LocalEpisodeState(podcastFeedURL: feed, episodeGUID: guid,
                                                 downloadStatus: status, downloadPath: path))
            }
        }
        do {
            try context.save()
        } catch {
            preconditionFailure("Could not seed large download activity fixture: \(error)")
        }
    }

    @MainActor
    private static func featuredPodcast(in context: ModelContext) -> Podcast? {
        let feedURL = ScreenshotFixtures.featuredPodcastFeedURL
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @MainActor
    private static func nowPlayingEpisode(in context: ModelContext) -> Episode? {
        let guid = ScreenshotFixtures.nowPlayingEpisodeGUID
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

struct FolderRunUITestFeed: FeedFetching {
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        try await Task.sleep(for: .seconds(1))
        return ParsedFeed(title: "Folder test show", episodes: (0..<60).map {
            ParsedEpisode(guid: "history-\($0)", title: "History \($0)", audioURL: "https://folder.test/audio.mp3",
                          pubDate: Date(timeIntervalSince1970: Double(1_000_000 + $0)))
        })
    }
}

/// Keeps the actual manual refresh task active while a UI test navigates and
/// invokes podcast actions. No network request or persistent store is involved.
actor HeldRefreshUITestFeed: FeedFetching {
    private var attempts = 0

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        attempts += 1
        if attempts == 1 { try await Task.sleep(for: .seconds(35)) }
        return ParsedFeed(title: "Held refresh", episodes: [])
    }
}
/// The first retry fails and the next returns the already-known episode.
/// Exercises the real retry controller, repository and persistence without a network.
actor FeedRetryScreenshotFeed: FeedFetching {
    private var attempts = 0

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        attempts += 1
        try await Task.sleep(for: .milliseconds(200))
        if attempts == 1 { throw HTTPError.server(status: 503) }
        return ParsedFeed(title: "Feed retry test", episodes: [
            ParsedEpisode(guid: "existing", title: "Already downloaded", audioURL: "https://feed-retry.test/audio.mp3",
                          description: nil, pubDate: nil, durationSeconds: nil)
        ])
    }
}

/// Native Settings rehearsal using only an in-memory library and a fresh
/// temporary folder. The launch gate is absent from Release builds. It never
/// reads the user's bookmark, account, library, or a network feed.
struct ListeningPlacesPlaybackDemoControls: View {
    @MainActor private static var directory: URL?
    private static let feed = "https://example.invalid/playback-demo.xml"
    private static let blockedFeeds: [(feed: String, guid: String)] = [
        ("https://example.invalid/private.xml?token=synthetic", "synthetic-private"),
        ("https://example.invalid/redirect.xml", "synthetic-redirect"),
        ("https://example.invalid/unknown.xml", "synthetic-unknown"),
        ("https://example.invalid/device-only.xml", "synthetic-device-only"),
    ]

    @Environment(\.modelContext) private var context
    @Environment(ListeningPlacesService.self) private var service
    @Environment(PlayerService.self) private var player
    @State private var isSyncing = false
    @State private var ownedFileBeforeConflict: Data?
    @State private var status = "Preparing disposable playback fixtures."

    var body: some View {
        Section("Disposable Playback test") {
            Text("This Debug test uses synthetic episodes and a temporary folder. It does not use your library, iCloud, or a network feed.")
            Button("Sync synthetic peer place") { Task { await syncNow() } }
                .disabled(isSyncing || !service.enabled || service.isSharingStopPendingForTesting)
            Button("Simulate disposable cleanup conflict") {
                Task { await makeCleanupConflict() }
            }
            .disabled(isSyncing || ownedFileBeforeConflict != nil)
            if ownedFileBeforeConflict != nil {
                Button("Repair disposable owned file") {
                    Task { await repairOwnedFile() }
                }
            }
            Text(status)
                .accessibilityLabel("Disposable Playback status: \(status)")
                .accessibilityIdentifier("listeningPlacesPlaybackDemoStatus")
        }
        .task { await prepareFixture() }
    }

    private func prepareFixture() async {
        guard ScreenshotHarness.isListeningPlacesPlaybackDemo else { return }
        do {
            service.configure(context: context)
            let show: Podcast
            let loaded: Episode
            let idle: Episode
            if let existing = try context.fetch(FetchDescriptor<Podcast>()).first(where: {
                $0.feedURL == Self.feed
            }), let episodes = existing.episodes,
               let first = episodes.first(where: { $0.guid == "synthetic-loaded" }),
               let second = episodes.first(where: { $0.guid == "synthetic-idle" }) {
                show = existing
                loaded = first
                idle = second
            } else {
                show = Podcast(feedURL: Self.feed, title: "Synthetic playback demo")
                loaded = Episode(guid: "synthetic-loaded", title: "Loaded rewind",
                    audioURL: "https://example.invalid/loaded.mp3", positionSeconds: 12)
                idle = Episode(guid: "synthetic-idle", title: "Idle progress",
                    audioURL: "https://example.invalid/idle.mp3", positionSeconds: 20)
                context.insert(show)
                for episode in [loaded, idle] {
                    episode.podcast = show
                    context.insert(episode)
                }
                let deviceID = AppSettingsStore(context: context).rawValue(
                    SettingsKey.listeningPlacesDeviceID) ?? "phone123"
                let earlier = Date().addingTimeInterval(-3_600)
                try ListeningPlacesEventJournal.stageLocalMutation(
                    of: loaded, in: context, deviceID: deviceID, now: earlier)
                try ListeningPlacesEventJournal.stageLocalMutation(
                    of: idle, in: context, deviceID: deviceID, now: earlier)
                try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(
                    for: show.feedURL, in: context)
                for fixture in Self.blockedFeeds {
                    let blockedShow = Podcast(feedURL: fixture.feed, title: "Blocked synthetic feed")
                    let blockedEpisode = Episode(guid: fixture.guid, title: "Blocked synthetic place",
                        audioURL: "https://example.invalid/\(fixture.guid).mp3", positionSeconds: 10)
                    blockedEpisode.podcast = blockedShow
                    context.insert(blockedShow)
                    context.insert(blockedEpisode)
                }
                let privateFeed = Self.blockedFeeds[0].feed
                let redirectedFeed = Self.blockedFeeds[1].feed
                let directoryURL = "https://itunes.apple.com/search?media=podcast"
                guard ListeningPlacesPublicFeedApproval.eligibleFeedURL(.init(
                    origin: .appleITunesDirectory, directoryResponseURL: directoryURL,
                    directoryFeedURL: privateFeed, requestedFeedURL: privateFeed,
                    resolvedFeedURL: privateFeed, redirectCount: 0,
                    access: .provenAnonymous, hasStoredCredentials: false,
                    deviceOnly: false
                )) == nil,
                ListeningPlacesPublicFeedApproval.eligibleFeedURL(.init(
                    origin: .appleITunesDirectory, directoryResponseURL: directoryURL,
                    directoryFeedURL: redirectedFeed, requestedFeedURL: redirectedFeed,
                    resolvedFeedURL: "https://example.invalid/resolved.xml",
                    redirectCount: 1, access: .provenAnonymous,
                    hasStoredCredentials: false, deviceOnly: false
                )) == nil else {
                    throw ListeningPlacesSubscriptionExchange.ExchangeError.invalidFile
                }
                // A formerly accepted marker cannot silently approve an
                // unknown feed after the positive-provenance version change.
                try LocalAppSettingIdentity.setValue("approved",
                    for: ListeningPlacesPublicFeedApproval.key(Self.blockedFeeds[2].feed),
                    in: context)
                try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(
                    for: Self.blockedFeeds[3].feed, in: context)
                try ListeningPlacesFeedPrivacy.stageDeviceOnly(
                    feedURL: Self.blockedFeeds[3].feed, in: context)
                try ListeningPlacesSubscriptionTestCoordinator.stagePolicy(.init(), in: context)
                try ListeningPlacesSubscriptionTestCoordinator.stageEpisodeImportForTesting(in: context)
                try context.save()
            }
            player.load(loaded) // Loaded but never played or fetched.
            if Self.directory == nil {
                let root = FileManager.default.temporaryDirectory
                    .appending(path: "places-playback-demo-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                Self.directory = root
            }
            guard let directory = Self.directory else { return }
            if service.folderName == nil { await service.chooseFolder(directory) }
            if service.enabled {
                let deviceID = AppSettingsStore(context: context).rawValue(
                    SettingsKey.listeningPlacesDeviceID) ?? "phone123"
                let bookmark = try directory.bookmarkData(options: .minimalBookmark,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                guard let own = try await service.disposableTransportForTesting.readDeviceFile(
                    bookmarkData: bookmark, deviceID: deviceID),
                      let root = try JSONSerialization.jsonObject(with: own) as? [String: Any],
                      let records = root["records"] as? [[String: Any]] else {
                    throw ListeningPlacesSubscriptionExchange.ExchangeError.invalidFile
                }
                let ids = Set(records.compactMap { $0["id"] as? String })
                let publicIDs = [loaded, idle].map {
                    ListeningPlacesFormat.episodeID(guid: $0.guid, enclosureURL: $0.audioURL)
                }
                let blockedIDs = Self.blockedFeeds.map {
                    ListeningPlacesFormat.episodeID(guid: $0.guid,
                        enclosureURL: "https://example.invalid/\($0.guid).mp3")
                }
                guard publicIDs.allSatisfy(ids.contains),
                      blockedIDs.allSatisfy({ !ids.contains($0) }) else {
                    throw ListeningPlacesSubscriptionExchange.ExchangeError.invalidFile
                }
            }
            status = service.enabled
                ? "Ready. Loaded rewind stays at 12 seconds; idle progress starts at 20 seconds. Public places 2. Blocked sensitive or unverified places 4."
                : "Sharing is off. Turn on Share listening places to try the synthetic sync."
        } catch {
            context.rollback()
            status = "Could not prepare disposable fixtures. Reopen this Debug screen to retry."
        }
    }

    private func syncNow() async {
        guard !isSyncing, service.enabled, !service.isSharingStopPendingForTesting,
              let directory = Self.directory else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let episodes = try context.fetch(FetchDescriptor<Episode>())
            guard let loaded = episodes.first(where: { $0.guid == "synthetic-loaded" }),
                  let idle = episodes.first(where: { $0.guid == "synthetic-idle" }),
                  let deviceID = AppSettingsStore(context: context).rawValue(
                    SettingsKey.listeningPlacesDeviceID) else {
                status = "Synthetic episodes are unavailable. Reopen this Debug screen to retry."
                return
            }
            let now = Date()
            let peerRecords = [
                ListeningPlaceRecord(id: ListeningPlacesFormat.episodeID(
                    guid: loaded.guid, enclosureURL: loaded.audioURL), kind: "episode",
                    positionMilliseconds: 5_000, durationMilliseconds: nil,
                    played: false, updatedAt: now, label: nil, feed: nil, deleted: nil),
                ListeningPlaceRecord(id: ListeningPlacesFormat.episodeID(
                    guid: idle.guid, enclosureURL: idle.audioURL), kind: "episode",
                    positionMilliseconds: 25_000, durationMilliseconds: nil,
                    played: false, updatedAt: now, label: nil, feed: nil, deleted: nil),
            ]
            let peer = try ListeningPlacesFormat.encodedDeviceFile(
                deviceID: "desktopfixture", appVersion: "quill-cast/synthetic-fixture",
                writtenAt: now, records: peerRecords)
            let peerPath = directory.appending(path: "Listening Places/devices/desktopfixture.json")
            try peer.write(to: peerPath, options: .atomic)
            let bookmark = try directory.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            let before = try await service.disposableTransportForTesting.readDeviceFile(
                bookmarkData: bookmark, deviceID: deviceID)
            let result = try await ListeningPlacesSubscriptionTestCoordinator.sync(
                bookmarkData: bookmark, ownDeviceID: deviceID, context: context,
                transport: service.disposableTransportForTesting, now: now,
                loadedEpisodeID: { player.nowPlayingEpisode?.persistentModelID },
                isPlaybackEnabled: {
                    service.enabled && !service.isSharingStopPendingForTesting
                })
            let after = try await service.disposableTransportForTesting.readDeviceFile(
                bookmarkData: bookmark, deviceID: deviceID)
            let applied = result.episodes.applied
            let deferredLoaded = result.episodes.deferredLoaded
            let deferredOther = result.episodes.deferred
            let ownFileUnchanged = before == after ? "yes" : "no"
            status = "Applied \(applied). Deferred while loaded \(deferredLoaded). "
                + "Other deferred \(deferredOther). Idle progress is "
                + "\(idle.positionSeconds) seconds. Own file unchanged: \(ownFileUnchanged)."
        } catch {
            status = "Disposable sync failed. Confirm sharing is on, then retry Sync synthetic peer place."
        }
    }

    /// Mutates only the fresh temporary fixture's owned file. A foreign app
    /// marker makes the actual native stop path fail closed until repaired.
    private func makeCleanupConflict() async {
        guard let directory = Self.directory, ownedFileBeforeConflict == nil else { return }
        do {
            let deviceID = AppSettingsStore(context: context).rawValue(
                SettingsKey.listeningPlacesDeviceID) ?? "phone123"
            let bookmark = try directory.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            guard let original = try await service.disposableTransportForTesting.readDeviceFile(
                bookmarkData: bookmark, deviceID: deviceID),
                  var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                status = "No disposable owned file is ready. Sync the synthetic place first."
                return
            }
            root["app"] = "other-app/synthetic-conflict"
            let conflict = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try await service.disposableTransportForTesting.writeDeviceFile(
                bookmarkData: bookmark, deviceID: deviceID, data: conflict)
            ownedFileBeforeConflict = original
            status = "Disposable conflict staged. Turn off Share listening places to check the cleanup error."
        } catch {
            status = "Could not stage the disposable conflict. Retry in this Debug screen."
        }
    }

    private func repairOwnedFile() async {
        guard let directory = Self.directory, let original = ownedFileBeforeConflict else { return }
        do {
            let deviceID = AppSettingsStore(context: context).rawValue(
                SettingsKey.listeningPlacesDeviceID) ?? "phone123"
            let bookmark = try directory.bookmarkData(options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            try await service.disposableTransportForTesting.writeDeviceFile(
                bookmarkData: bookmark, deviceID: deviceID, data: original)
            ownedFileBeforeConflict = nil
            status = "Disposable file repaired. Turn off Share listening places again to retry cleanup."
        } catch {
            status = "Could not repair the disposable file. Retry repair before turning sharing off."
        }
    }
}
#endif
