import Foundation
import SwiftData

extension AppRuntime {
    /// Shared by the screen and background audio intents. The existing runtime
    /// gate keeps restoration, reconciliation and player binding single-owner.
    func preparePlaybackServices(
        container: ModelContainer,
        deferNoncriticalMaintenance: Bool = false
    ) async -> Bool {
        let context = container.mainContext
        return await activateRootServices(for: container) {
            self.bindRootServicesIfNeeded(to: container) {
                #if DEBUG
                if ScreenshotHarness.isSeeding { ScreenshotFixtures.seed(into: context) }
                if JournalRestartProbe.isSeeding { JournalRestartProbe.seed(in: context) }
                if RealDownloadRestartProbe.isSeeding { RealDownloadRestartProbe.seed(in: context) }
                #endif
                self.player.configure(context: context)
                self.quickActions.configure(context: context)
                self.downloads.configure(context: context)
                self.feedRefreshStatus.configure(context: context)
            }
            try Task.checkCancellation()
            // These repairs keep restoration pointed at the current local file
            // path and were measured at about 2 ms on the large-download fixture.
            #if DEBUG
            if !JournalRestartProbe.isSeeding {
                await self.downloads.reconcileStuckDownloads()
            }
            #else
            await self.downloads.reconcileStuckDownloads()
            #endif
            try Task.checkCancellation()
            await self.downloads.reconcileDownloadPaths()
            #if DEBUG
            if JournalRestartProbe.isVerifying { JournalRestartProbe.report(in: context, phase: "relaunch") }
            if RealDownloadRestartProbe.isSeeding {
                await RealDownloadRestartProbe.start(using: self.downloads, context: context)
            }
            if RealDownloadRestartProbe.isVerifying {
                RealDownloadRestartProbe.report(in: context, phase: "relaunch")
            }
            #endif
            try Task.checkCancellation()
            self.settings.configure(context: context)
            self.listeningPlaces.configure(context: context)
            self.tips.configure(context: context)
            let capSettings = AppSettingsStore(context: context)
            let count = (try? PodcastQuery.followedCount(in: context)) ?? 0
            capSettings.introducePodcastCapGatingIfNeeded(currentPodcastCount: count)
            PlaybackStartup.restoreLastEpisode(into: self.player, context: context)
            if !deferNoncriticalMaintenance {
                await self.performNoncriticalRootMaintenance(container: container)
            }
        }
    }

    /// RootView calls this after it has published the first interactive frame.
    /// Keep launch-time repair and restoration on the critical path, while
    /// expiration, cloud projection, retention, and folder-run wiring proceed
    /// after VoiceOver can already reach the main interface.
    func finishDeferredRootStartup(container: ModelContainer) async {
        await performNoncriticalRootMaintenance(container: container)
    }

    func cancelAndWaitForDeferredRootStartup() async {
        guard let task = noncriticalRootMaintenanceTask else { return }
        task.cancel()
        await task.value
        noncriticalRootMaintenanceTask = nil
    }

    private func performNoncriticalRootMaintenance(container: ModelContainer) async {
        guard !isResettingLocalData else { return }
        if let noncriticalRootMaintenanceTask {
            await noncriticalRootMaintenanceTask.value
            return
        }
        let task = Task { @MainActor in
            await self.runNoncriticalRootMaintenance(container: container)
        }
        noncriticalRootMaintenanceTask = task
        await task.value
    }

    private func runNoncriticalRootMaintenance(container: ModelContainer) async {
        guard !Task.isCancelled, !isResettingLocalData else { return }
        #if DEBUG
        if !ScreenshotHarness.isActive {
            _ = await ExpirationMaintenance.run(modelContainer: container)
        }
        #else
        _ = await ExpirationMaintenance.run(modelContainer: container)
        #endif
        do {
            try await activateCloudProjectionIfNeeded(container: container)
        } catch {
            AppLog.data.error(
                "Cloud projection activation failed after root became interactive: \(error.localizedDescription, privacy: .public)"
            )
        }
        guard !Task.isCancelled, !isResettingLocalData else { return }
        let statsReport = await StatsMaintenance.applyRetention(
            modelContainer: container,
            days: settings.historyRetentionDays
        )
        if statsReport.removed > 0 {
            NotificationCenter.default.post(
                name: .earshotListeningHistoryDidChange,
                object: nil
            )
        }
        guard !Task.isCancelled, !isResettingLocalData else { return }
        await player.folderRuns.connect(context: container.mainContext, player: player)
    }
}

#if DEBUG
private enum RealDownloadRestartProbe {
    static var isSeeding: Bool { CommandLine.arguments.contains("-journalRestartRealSeed") }
    static var isVerifying: Bool { CommandLine.arguments.contains("-journalRestartRealVerify") }
    private static let feed = "https://journal-restart-real.invalid/feed"
    private static let guid = "real-background-transfer"
    private static var source: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-journalRestartRealURL"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor static func seed(in context: ModelContext) {
        guard let source else { report(in: context, phase: "missing-url"); return }
        let podcast = Podcast(feedURL: feed, title: "Real background transfer probe")
        let episode = Episode(guid: guid, title: "Real background transfer", audioURL: source)
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        do { try context.save() } catch { report(in: context, phase: "seed-save-failed") }
    }

    @MainActor static func start(using manager: DownloadManager, context: ModelContext) async {
        guard let episode = try? context.fetch(FetchDescriptor<Episode>()).first(where: {
            $0.guid == guid && $0.podcast?.feedURL == feed
        }) else { report(in: context, phase: "missing-episode"); return }
        await manager.download(episode)
        report(in: context, phase: "enrolled")
        for _ in 0..<150 {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: DownloadPaths.downloadsDirectory(), includingPropertiesForKeys: nil
            ), !files.isEmpty {
                report(in: context, phase: "callback")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        report(in: context, phase: "callback-timeout")
    }

    @MainActor static func report(in context: ModelContext, phase: String) {
        let row = try? context.fetch(FetchDescriptor<LocalEpisodeState>()).first(where: {
            $0.podcastFeedURL == feed && $0.episodeGUID == guid
        })
        let files = (try? FileManager.default.contentsOfDirectory(
            at: DownloadPaths.downloadsDirectory(), includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)) ?? []
        let data: [String: Any] = [
            "phase": phase, "status": row?.downloadStatusRaw ?? "missing",
            "path": row?.downloadPath ?? "", "attempt": row?.downloadAttemptID ?? "",
            "files": files
        ]
        let url = URL.documentsDirectory.appending(path: "real-download-restart-probe.json")
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]) {
            try? encoded.write(to: url, options: .atomic)
        }
    }
}

/// DEBUG-only process-boundary fixture for scripts/tests/journal-restart.sh.
/// It writes only inside the script's disposable simulator container.
private enum JournalRestartProbe {
    static var isSeeding: Bool { CommandLine.arguments.contains("-journalRestartProbeSeed") }
    static var isVerifying: Bool { CommandLine.arguments.contains("-journalRestartProbeVerify") }
    private static let feed = "https://journal-restart.invalid/feed"
    private static let source = URL(string: "https://journal-restart.invalid/audio.mp3")!
    private static let cases: [(guid: String, storedAttempt: String, callbackAttempt: String)] = [
        ("current", "11111111-1111-4111-8111-111111111111", "11111111-1111-4111-8111-111111111111"),
        ("superseded", "33333333-3333-4333-8333-333333333333", "22222222-2222-4222-8222-222222222222")
    ]

    @MainActor static func seed(in context: ModelContext) {
        do {
            let podcast = Podcast(feedURL: feed, title: "Journal restart probe")
            context.insert(podcast)
            for entry in cases {
                let episode = Episode(guid: entry.guid, title: entry.guid, audioURL: source.absoluteString)
                episode.podcast = podcast
                context.insert(episode)
                context.insert(LocalEpisodeState(
                    podcastFeedURL: feed, episodeGUID: entry.guid,
                    downloadStatus: .downloading, downloadAttemptID: entry.storedAttempt
                ))
            }
            try context.save()
            let journal = DownloadEventJournal(
                url: URL.applicationSupportDirectory.appending(path: "pending-download-events.json"),
                write: { _, _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
            )
            let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [])
            for entry in cases {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try Data("probe audio \(entry.guid)".utf8).write(to: temp)
                let task = URLSession.shared.downloadTask(with: source)
                task.taskDescription = DownloadTransferKey.key(
                    identityKey: DownloadTaskKey.key(feedURL: feed, guid: entry.guid),
                    sourceURL: source, attemptID: entry.callbackAttempt
                )
                delegate.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: temp)
                task.cancel()
            }
            report(in: context, phase: "before-termination")
        } catch {
            write(["error": String(describing: error)])
        }
    }

    @MainActor static func report(in context: ModelContext, phase: String) {
        do {
            let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>())
                .filter { $0.podcastFeedURL == feed }
                .map { ["guid": $0.episodeGUID, "status": $0.downloadStatusRaw,
                        "path": $0.downloadPath ?? "", "attempt": $0.downloadAttemptID ?? ""] }
            let files = try FileManager.default.contentsOfDirectory(
                at: DownloadPaths.downloadsDirectory(), includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted()
            let episodes = try context.fetch(FetchDescriptor<Episode>())
                .filter { $0.podcast?.feedURL == feed }
                .map { episode -> [String: String] in
                    let source = URL(string: episode.audioURL).map(SecureURL.preferredMediaHTTPS)
                    let key = source.map {
                        DownloadTransferKey.key(
                            identityKey: DownloadTaskKey.key(feedURL: feed, guid: episode.guid),
                            sourceURL: $0, attemptID: episode.downloadAttemptID
                        )
                    }
                    return ["guid": episode.guid, "attempt": episode.downloadAttemptID ?? "",
                            "status": episode.downloadStatus.rawValue,
                            "source": episode.audioURL,
                            "taskKey": key ?? "",
                            "prefix": key.map(DownloadPaths.recoveryPrefix) ?? ""]
                }
            write(["phase": phase, "feed": feed, "rows": rows, "files": files, "episodes": episodes])
        } catch {
            write(["phase": phase, "error": String(describing: error)])
        }
    }

    private static func write(_ value: [String: Any]) {
        let url = URL.documentsDirectory.appending(path: "journal-restart-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
