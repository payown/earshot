import Foundation
import SwiftData
import Observation

/// Main-actor state is limited to presentation and the currently playing item.
/// Database, network, parsing, ordering and historical imports have actor owners.
@MainActor @Observable
final class FolderRunController {
    private(set) var snapshot: FolderRunSnapshot? {
        didSet { if oldValue?.id != snapshot?.id { refreshFolderName() } }
    }
    private(set) var folderName = "Folder"
    private(set) var message: String?
    private(set) var isBusy = false
    private(set) var isConnected = false
    private(set) var driving = false
    private(set) var hasPlaybackFailure = false
    @ObservationIgnored private var store: FolderRunStore?
    @ObservationIgnored private var catalog: FolderRunCatalog?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private weak var player: PlayerService?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var currentItem: FolderRunItem?
    @ObservationIgnored private var isAdvancing = false
    @ObservationIgnored private var transportPaused = false
    @ObservationIgnored private var pendingPlayback = false

    nonisolated static let directoryName = "FolderRuns"

    @concurrent private static func openStore() async throws -> FolderRunStore {
#if DEBUG
        if ScreenshotHarness.isActive { return try await FolderRunStore.open() }
#endif
        var directory = URL.applicationSupportDirectory.appending(path: directoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        return try await FolderRunStore.open(at: directory.appending(path: "manifest.store"))
    }

    func connect(context: ModelContext, player: PlayerService, testStore: FolderRunStore? = nil) async {
        guard !isConnected else { return }
        self.context = context
        self.player = player
        catalog = FolderRunCatalog(container: context.container)
        perform { [self] in
            do {
                let opened: FolderRunStore
                if let testStore { opened = testStore } else { opened = try await Self.openStore() }
                try Task.checkCancellation()
                store = opened
                let prior = try await opened.currentSnapshot()
                snapshot = try await opened.recover()
                try Task.checkCancellation()
                isConnected = true
                if let snapshot, [.paused, .ready].contains(snapshot.state) {
                    let first = try await opened.window(id: snapshot.id, limit: 1).first
                    if prior?.state == .playing || first?.identity == identity(player.nowPlayingEpisode) {
                        try await selectNext(autoplay: false)
                    }
                }
            } catch is CancellationError {
                store = nil
            } catch {
                message = "Folder run could not be opened. Your Queue is unchanged. \(error.localizedDescription)"
            }
        }
        await operation?.value
    }

    func refreshFolderName() {
        folderName = folder()?.name ?? snapshot?.folderName ?? "Folder"
    }

    private func folder() -> PodcastFolder? {
        guard let data = snapshot?.folderIdentity,
              let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data), let context else { return nil }
        var query = FetchDescriptor<PodcastFolder>(predicate: #Predicate { $0.persistentModelID == id })
        query.fetchLimit = 1
        return (try? context.fetch(query))?.first
    }

    func start(folder: PodcastFolder, replacing: UUID?, feed: any FeedFetching = FeedService(), startsPlayback: Bool = true) {
#if DEBUG
        let feed: any FeedFetching = ScreenshotHarness.isFolderRunTest ? FolderRunUITestFeed() : feed
#endif
        let id = folder.persistentModelID
        let name = folder.name
        perform {
            guard let store = self.store, let catalog = self.catalog else { throw FolderRunError.missingRun }
            let wasDriving = self.driving
            self.driving = false
            self.pendingPlayback = false
            self.transportPaused = false
            self.hasPlaybackFailure = false
            if wasDriving { self.player?.pause() }
            self.currentItem = nil
            let feeds = try await catalog.feeds(in: id)
            try Task.checkCancellation()
            self.snapshot = try await store.begin(folderIdentity: JSONEncoder().encode(id), folderName: name,
                                                  totalPodcasts: feeds.count, replacing: replacing)
            guard let runID = self.snapshot?.id else { throw FolderRunError.missingRun }
            Announcer.announce("Preparing \(name). Checking \(feeds.count) podcasts for available older episodes.")
            do {
                try await catalog.prepare(feeds: feeds, runID: runID, store: store, feed: feed) { snapshot in
                    await self.receiveProgress(snapshot)
                }
                try Task.checkCancellation()
                while try await store.pruneObsoletePage() > 0 { try Task.checkCancellation() }
                self.snapshot = try await store.seal(id: runID)
                try Task.checkCancellation()
                Announcer.announce("\(name) is ready. \(self.snapshot?.discovered ?? 0) unheard episodes, oldest first.")
                // Confirm the actual count before interrupting current playback.
                // The status screen supplies Resume folder run for this ready run.
                if startsPlayback, (self.snapshot?.discovered ?? 0) <= 50 {
                    try await self.selectNext(autoplay: true)
                }
            } catch {
                if let latest = try? await store.currentSnapshot(), latest.id == runID, latest.state == .preparing {
                    let cancelled = try? await store.cancel(id: runID)
                    if !Task.isCancelled { self.snapshot = cancelled }
                }
                throw error
            }
        }
    }

    private func receiveProgress(_ value: FolderRunSnapshot) {
        guard !Task.isCancelled, snapshot?.id == value.id else { return }
        snapshot = value
    }

    func resume() {
        transportPaused = false
        hasPlaybackFailure = false
        pendingPlayback = true
        perform {
            try await self.selectNext(autoplay: true)
        }
    }

    func pauseForTransport() {
        guard driving || pendingPlayback else { return }
        driving = false
        pendingPlayback = false
        transportPaused = true
        perform {
            guard let id = self.snapshot?.id, let store = self.store else { return }
            let latest = try await store.currentSnapshot()
            if latest?.state.isTerminal == false { self.snapshot = try await store.pause(id: id) }
        }
    }

    func resumeTransportIfNeeded() -> Bool {
        guard transportPaused else { return false }
        resume()
        return true
    }

    func cancel() {
        let wasDriving = driving
        driving = false
        pendingPlayback = false
        transportPaused = false
        hasPlaybackFailure = false
        currentItem = nil
        if wasDriving { player?.pause() }
        perform {
            guard let id = self.snapshot?.id, let store = self.store else { return }
            self.snapshot = try await store.cancel(id: id)
            Announcer.announce("\(self.folderName) folder run cancelled. \(self.snapshot?.discovered ?? 0) episodes were found. Your normal Queue is unchanged.")
            if wasDriving { self.player?.resumeOrdinaryQueueAfterFolderRun() }
        }
    }

    /// Invoked before a deliberate source switch. Pause, interruption, route
    /// changes and same-item resumes do not destroy or reorder the run.
    func playbackWillStart(_ episode: Episode) {
        if transportPaused, identity(episode) == currentItem?.identity, !episode.isPlayed {
            transportPaused = false
            driving = true
            perform {
                guard let store = self.store, let id = self.snapshot?.id else { return }
                self.snapshot = try await store.resume(id: id)
            }
            return
        }
        if identity(episode) != currentItem?.identity { transportPaused = false; hasPlaybackFailure = false }
        guard driving || pendingPlayback, identity(episode) != currentItem?.identity else { return }
        driving = false
        pendingPlayback = false
        currentItem = nil
        perform {
            guard let id = self.snapshot?.id, let store = self.store else { return }
            self.snapshot = try await store.pause(id: id)
        }
    }

    /// A failed stream is not proof of a permanently missing episode. Keep the
    /// cursor and played state; only an explicit skip records it as unavailable.
    func playbackFailed(_ episode: Episode, unavailable: Bool = false) {
        guard driving, identity(episode) == currentItem?.identity else { return }
        player?.pause()
        hasPlaybackFailure = true
        if unavailable {
            Announcer.announce("Skipping unavailable folder episode. It has not been marked played.")
            skipFailedEpisode()
            return
        }
        message = "This folder episode could not play. Resume to retry, or skip it in Folder run status. It has not been marked played."
        Announcer.announce(message ?? "Folder episode could not play")
    }

    func skipFailedEpisode() {
        guard hasPlaybackFailure, let item = currentItem else { return }
        hasPlaybackFailure = false
        transportPaused = false
        perform {
            guard let store = self.store else { throw FolderRunError.missingRun }
            self.snapshot = try await store.advance(item, disposition: .unavailable)
            try Task.checkCancellation()
            try await self.selectNext(autoplay: true)
        }
    }

    func completeCurrent(_ episode: Episode, continuePlayback: Bool) -> Bool {
        guard driving, identity(episode) == currentItem?.identity, let item = currentItem else { return false }
        guard !isAdvancing else { return true }
        guard player?.finishFolderEpisode(episode) == true else {
            message = "Could not save episode completion. Folder playback stopped."
            player?.pause()
            return true
        }
        isAdvancing = true
        perform {
            guard let store = self.store else { throw FolderRunError.missingRun }
            self.snapshot = try await store.advance(item, disposition: .completed)
            try Task.checkCancellation()
            self.isAdvancing = false
            if continuePlayback {
                try await self.selectNext(autoplay: true)
            } else {
                self.driving = false
                self.currentItem = nil
                if let snapshot = self.snapshot, !snapshot.state.isTerminal {
                    self.snapshot = try await store.pause(id: snapshot.id)
                }
                self.player?.clearFolderRunPresentation()
            }
        }
        return true
    }

    private func selectNext(autoplay: Bool) async throws {
        pendingPlayback = autoplay
        guard let store, let catalog, let context, let id = snapshot?.id else { throw FolderRunError.missingRun }
        snapshot = try await store.currentSnapshot()
        if snapshot?.state.isTerminal == false {
            if autoplay { snapshot = try await store.resume(id: id) }
            else { snapshot = try await store.pause(id: id) }
        }
        try Task.checkCancellation()
        var skipped = 0
        while let snapshot, snapshot.remaining > 0, !snapshot.state.isTerminal {
            try Task.checkCancellation()
            let window = try await store.window(id: id)
            guard let item = window.first else { throw FolderRunError.invalidState }
            let episodeID = try await catalog.resolve(item.identity)
            try Task.checkCancellation()
            var episode: Episode?
            if let episodeID {
                var query = FetchDescriptor<Episode>(predicate: #Predicate { $0.persistentModelID == episodeID })
                query.fetchLimit = 1
                episode = try context.fetch(query).first
            }
            if let episode, !episode.isPlayed,
               PlaybackLogic.resolvePlaybackURL(downloadPath: episode.localAudioURL?.path, audioURL: episode.audioURL) != nil {
                currentItem = item
                hasPlaybackFailure = false
                driving = true
                pendingPlayback = false
                if skipped > 0 { Announcer.announce("Skipped \(skipped) episodes already played or unavailable.") }
                player?.playFolderRunEpisode(episode, origin: folder().map { .folder($0.persistentModelID) }, autoplay: autoplay)
                return
            }
            self.snapshot = try await store.advance(item, disposition: episode?.isPlayed == true ? .alreadyPlayed : .unavailable)
            skipped += 1
        }
        driving = false
        pendingPlayback = false
        transportPaused = false
        currentItem = nil
        if let snapshot, snapshot.state != .cancelled {
            Announcer.announce("\(folderName) finished. \(snapshot.completed) completed, \(snapshot.skipped) already played, \(snapshot.unavailableEpisodes) unavailable episodes. \(snapshot.unavailablePodcasts) feeds could not be fully checked.")
            if autoplay { player?.resumeOrdinaryQueueAfterFolderRun() }
            else { player?.clearFolderRunPresentation() }
        }
    }

    private func identity(_ episode: Episode?) -> FolderRunIdentity? {
        guard let episode, let feedURL = episode.podcast?.feedURL else { return nil }
        return FolderRunIdentity(feedURL: feedURL, guid: episode.guid)
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        let prior = operation
        prior?.cancel()
        let token = UUID()
        generation = token
        isBusy = true
        message = nil
        operation = Task { [weak self] in
            await prior?.value
            guard let self, !Task.isCancelled else { return }
            defer { if self.generation == token { self.isBusy = false; self.isAdvancing = false } }
            do { try await body() }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                let wasDriving = self.driving
                self.driving = false
                self.pendingPlayback = false
                if wasDriving { self.player?.pause() }
                self.message = "Folder run stopped: \(error.localizedDescription). Your normal Queue is unchanged."
                Announcer.announce(self.message ?? "Folder run stopped")
            }
        }
    }

    /// Reset waits for network, actor saves, and cursor work before file removal.
    func release() async {
        generation = UUID()
        operation?.cancel()
        await operation?.value
        operation = nil
        store = nil
        catalog = nil
        context = nil
        player = nil
        snapshot = nil
        currentItem = nil
        driving = false
        transportPaused = false
        hasPlaybackFailure = false
        pendingPlayback = false
        isBusy = false
        isConnected = false
    }

#if DEBUG
    func waitForOperationForTesting() async { await operation?.value }
#endif
}
