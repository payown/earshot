import Foundation
import Network
import Observation
import SwiftData

struct DownloadBatchReport: Equatable, Sendable {
    let eligible: Int
    let started: Int
    let skipped: Int
    let deferred: Int
    let failed: Int
    let wasCancelled: Bool

    var announcement: String {
        var parts = [
            "Eligible \(eligible)",
            "started \(started)",
            "skipped \(skipped)",
            "deferred \(deferred)",
            "failed \(failed)",
        ]
        if wasCancelled { parts.append("cancelled") }
        return "Download batch complete. " + parts.joined(separator: ", ") + "."
    }
}

/// A hard safety boundary for an explicit Inbox/Queue "Download All" request.
/// Yielding enrollment work keeps VoiceOver responsive, but does not prevent a
/// single confirmation from creating hundreds of background URLSession tasks.
/// This policy does both: callers get exact counts, and the manager independently
/// enforces the first 50 eligible episodes even if a presentation path regresses.
struct ManualDownloadBatchPlan: Equatable, Sendable {
    static let maximumEpisodeCount = 50

    let selectedIndices: [Int]
    let eligibleCount: Int
    let skippedCount: Int
    let deferredCount: Int

    static func make(statuses: [DownloadStatus]) -> Self {
        let eligibleIndices = statuses.indices.filter {
            statuses[$0] == .none || statuses[$0] == .failed
        }
        let selected = Array(eligibleIndices.prefix(maximumEpisodeCount))
        return Self(
            selectedIndices: selected,
            eligibleCount: eligibleIndices.count,
            skippedCount: statuses.count - eligibleIndices.count,
            deferredCount: eligibleIndices.count - selected.count
        )
    }
}

struct DownloadStorageSummary: Equatable, Sendable {
    static let empty = Self(downloadedCount: 0, activeCount: 0, allocatedBytes: 0)

    let downloadedCount: Int
    let activeCount: Int
    let allocatedBytes: Int64
}

/// Downloads episode audio to the app's Documents/Downloads folder, gated on
/// Wi-Fi when the user has "Wi-Fi only" enabled. Writes `downloadPath` /
/// `downloadStatus` so the player prefers the local file. The pure gating
/// decision lives in ``DownloadGate``.
///
/// Downloads run on a process-wide **background** `URLSession` (#544), so a
/// transfer continues while the app is suspended and completes on relaunch
/// instead of dying and stranding the episode at `.downloading`. Because iOS
/// allows only one background session per identifier per process, the session
/// and its delegate are shared statics used by every `DownloadManager` instance
/// (the app's and the transient one ``BackgroundFeedRefresher`` creates for
/// auto-download). Terminal events are resolved against the app's shared
/// container by the composite ``DownloadTaskKey`` (`"feedURL|guid"`, #576 —
/// guids alone repeat across podcasts), decoupled from whichever instance
/// started the download.
@MainActor
@Observable
final class DownloadManager {
    /// Keep each main-actor enrollment slice small enough that a very large
    /// filtered Inbox or Queue cannot monopolize VoiceOver or SwiftUI updates.
    private static let batchEnrollmentSize = 20
    /// True when the current path is Wi-Fi (or wired). Drives the gate.
    private(set) var isOnWifi = true

    /// False until `NWPathMonitor` delivers its first path report. Used so the
    /// first report also kicks `.pending` downloads at launch (#576) —
    /// `isOnWifi` optimistically defaults to true, so a launch already on Wi-Fi
    /// would otherwise never see a "became Wi-Fi" transition.
    @ObservationIgnored private var hasReceivedNetworkPath = false

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Observer for `.earshotQueueDidChange`, so queued episodes auto-download.
    @ObservationIgnored private var queueChangeObserver: NSObjectProtocol?

    // MARK: Shared background session (one per identifier per process)

    /// Background session identifier; also matched by the app delegate's
    /// `handleEventsForBackgroundURLSession`.
    static let sessionIdentifier = "media.payown.earshot.swift.downloads"

    @ObservationIgnored private static let delegate = DownloadSessionDelegate()

    /// The one background session for the process. Lazily created; recreating it
    /// on a background relaunch reconnects the delegate to outstanding tasks.
    @ObservationIgnored static let session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // The app enforces its own Wi-Fi-only gate before starting a task, so the
        // session itself may use cellular.
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Set by the app delegate when iOS relaunches the app to deliver background
    /// URL-session events; invoked once all events have been delivered.
    @ObservationIgnored static var backgroundCompletionHandler: (() -> Void)?

    /// The container terminal events resolve completed episodes against.
    @ObservationIgnored private static var container: ModelContainer?
    /// Notification-center seam for proving that a persisted terminal event
    /// reaches local notification scheduling without involving iOS in tests.
    @ObservationIgnored private static var notificationCenter: any NotificationScheduling =
        SystemNotificationCenter()

    /// Wires the shared session's delegate to the app's container and forces the
    /// session into existence so it can reconnect to any tasks that finished
    /// while the app was suspended. Call once at launch (not under tests).
    static func activate(container: ModelContainer) {
        self.container = container
        delegate.installTerminalHandler { event in
            Task { @MainActor in handle(event) }
        }
        installEventsFinishedHandler()
        _ = session
    }

    /// Connects the delegate while the durable marker still suppresses terminal
    /// events, drains old tasks, repeats the filesystem sweep, then reconciles
    /// SwiftData before the ready UI is published.
    static func prepareForReadyContainer(_ container: ModelContainer) async {
        guard RecoveryDownloadRemoval.isPending else {
            activate(container: container)
            return
        }
        self.container = container
        delegate.installRecoverySuppressionHandler()
        installEventsFinishedHandler()
        _ = session
        guard await cancelAllTasksAndWaitForRecovery() else {
            AppLog.networking.error(
                "Downloaded-audio recovery is waiting for background tasks to stop"
            )
            return
        }
        if let directory = try? DownloadPaths.downloadsDirectory() {
            _ = await Task.detached(priority: .utility) {
                RecoveryDownloadRemoval.removeContents(of: directory)
            }.value
        }
        await Task.yield()
        do {
            try RecoveryDownloadRemoval.reconcileStoreIfNeeded(container: container)
            activate(container: container)
        } catch {
            AppLog.networking.error(
                "Downloaded-audio recovery reconciliation will retry next launch: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func recoveryDownloadUsage() async -> Int64 {
        guard let directory = try? DownloadPaths.downloadsDirectory() else { return 0 }
        return await Task.detached(priority: .utility) {
            RecoveryDownloadRemoval.allocatedBytes(in: directory)
        }.value
    }

    static func removeDownloadedAudioForRecovery() async throws -> RecoveryDownloadRemovalResult {
        try await Task.detached(priority: .utility) {
            try RecoveryDownloadRemoval.begin()
        }.value
        await cancelAllTasks()
        let directory = try DownloadPaths.downloadsDirectory()
        let sweep = await Task.detached(priority: .utility) {
            RecoveryDownloadRemoval.removeContents(of: directory)
        }.value
        try RecoveryDownloadRemoval.failIfInjected(at: .afterFileDeletion)
        let available = try await Task.detached(priority: .utility) {
            try MigrationBackupManager.availableBytes(at: directory)
        }.value
        return RecoveryDownloadRemovalResult(
            freedBytes: sweep.freedBytes,
            availableBytes: available,
            remainingDownloadBytes: sweep.remainingBytes,
            failedItemCount: sweep.failedItemCount
        )
    }

    /// Reconnects a system-launched background session without requiring the
    /// store to be ready. Terminal events are journaled by the delegate and
    /// replayed when ``activate(container:)`` installs the final container.
    static func reconnectBackgroundSession(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        installEventsFinishedHandler()
        _ = session
    }

    private static func installEventsFinishedHandler() {
        delegate.installEventsFinishedHandler {
            Task { @MainActor in
                let handler = backgroundCompletionHandler
                backgroundCompletionHandler = nil
                handler?()
            }
        }
    }

    func configure(context: ModelContext) {
        self.context = context
        self.settings = AppSettingsStore(context: context)
        monitor.pathUpdateHandler = { [weak self] path in
            let onWifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self else { return }
                // Episodes parked at `.pending` by the Wi-Fi gate previously had
                // no reader and never started (#576). Kick them on the Wi-Fi
                // transition, and once on the FIRST path report so launch
                // reconciliation covers pending rows left over from a prior run
                // (start now or keep waiting, per current connectivity).
                let becameWifi = onWifi && !self.isOnWifi
                let firstPath = !self.hasReceivedNetworkPath
                self.hasReceivedNetworkPath = true
                self.isOnWifi = onWifi
                if becameWifi || firstPath {
                    await self.startPendingDownloads()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "media.payown.earshot.swift.network"))

        // Auto-download queued episodes (#downloads): every manual/opt-in enqueue
        // funnels through QueueRepository.save, which posts this. The scan is
        // bounded by the queue and idempotent, so it's safe to react to every
        // queue mutation (adds, reorders, removals). Refresh-time auto-queue posts
        // on a background context and is covered separately by SubscriptionRepository.
        if queueChangeObserver == nil {
            queueChangeObserver = NotificationCenter.default.addObserver(
                forName: .earshotQueueDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.downloadQueuedIfEnabled() }
            }
        }
    }

    /// Releases the old SwiftData graph before Settings reset unlinks its files.
    func releasePersistence() async {
        _ = await Self.cancelAllTasksAndWaitForRecovery()
        context = nil
        settings = nil
    }

    /// Whether a download may start right now under the Wi-Fi gate.
    var downloadsAllowed: Bool {
        let wifiOnly = settings?.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads)
            ?? SettingsDefault.wifiOnlyDownloads
        return DownloadGate.allowed(wifiOnly: wifiOnly, isOnWifi: isOnWifi)
    }

    /// Starts downloading `episode`'s audio on the background session. No-op when
    /// already downloaded; sets `downloadStatus = .pending` and returns when
    /// blocked by the Wi-Fi gate. Completion is handled by the session delegate's
    /// durable terminal-event journal, so this returns as soon as the task is
    /// enqueued — the transfer survives app suspension and store preparation.
    func download(_ episode: Episode) async {
        await download(episode, announceWaiting: true)
    }

    private func download(_ episode: Episode, announceWaiting: Bool) async {
        guard let context else { return }
        guard episode.downloadStatus != .downloaded else { return }
        guard downloadsAllowed else {
            ActiveDownload.setDownloadStatus(.pending, on: episode, in: context)
            save()
            if announceWaiting {
                Announcer.announce("Waiting for Wi-Fi to download \(episode.title)")
            }
            AppLog.networking.info("Download gated (no Wi-Fi): \(episode.title, privacy: .public)")
            return
        }
        guard let rawURL = URL(string: episode.audioURL) else {
            ActiveDownload.setDownloadStatus(.failed, on: episode, in: context)
            save()
            return
        }
        // A download is a non-media URLSession fetch (unlike AVFoundation
        // streaming), so upgrade http→https under the media-only ATS policy
        // (#387). HTTP-only hosts can still stream; only the download is affected.
        let url = SecureURL.upgradedForNonMedia(rawURL)

        // The ActiveDownload row and the .downloading write land in the SAME save
        // (#701): a row that lagged behind would leave this episode invisible to
        // reconcileStuckDownloads() and spinning forever — #544 returning.
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        save()

        let task = Self.session.downloadTask(with: url)
        // taskDescription (unlike taskIdentifier) survives an app relaunch, so a
        // completion delivered after the app was killed still resolves the
        // episode. The composite "feedURL|guid" key (#576) disambiguates guids
        // that repeat across podcasts.
        task.taskDescription = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
        task.resume()
        AppLog.networking.info("Download started (background): \(episode.title, privacy: .public)")
    }

    /// Enrolls an explicit user-selected batch through the same guarded path as
    /// a single download. Downloaded, pending, and downloading episodes are
    /// skipped before task creation, failed downloads remain retryable, and the
    /// main actor yields every bounded slice. The caller owns the one final
    /// accessibility announcement so Wi-Fi gating never chatters once per row.
    func downloadAll(_ episodes: [Episode]) async -> DownloadBatchReport {
        let plan = ManualDownloadBatchPlan.make(statuses: episodes.map(\.downloadStatus))
        let eligibleEpisodes = plan.selectedIndices.map { episodes[$0] }
        var started = 0
        var failed = 0
        var wasCancelled = false

        for (index, episode) in eligibleEpisodes.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            await download(episode, announceWaiting: false)
            switch episode.downloadStatus {
            case .pending, .downloading, .downloaded:
                started += 1
            case .failed, .none:
                failed += 1
            }

            if (index + 1).isMultiple(of: Self.batchEnrollmentSize) {
                await Task.yield()
            }
        }

        return DownloadBatchReport(
            eligible: plan.eligibleCount,
            started: started,
            skipped: plan.skippedCount,
            deferred: plan.deferredCount,
            failed: failed,
            wasCancelled: wasCancelled
        )
    }

    /// Downloads `episode` and suspends until the transfer reaches a TERMINAL
    /// state — unlike ``download(_:)``, which returns as soon as the task is
    /// enqueued (#544). Returns true when the episode ends up downloaded.
    ///
    /// Returns false without waiting when the download is gated on Wi-Fi
    /// (`.pending`) or failed to start (no terminal event will ever arrive for
    /// those), and after `timeout` seconds without a terminal event — the
    /// background task itself is left running and can still finish normally
    /// later. Safe to call concurrently for the same episode: each caller parks
    /// its own continuation and every continuation is resumed exactly once,
    /// either by the terminal event or by its own timeout (removal from
    /// ``downloadWaiters`` before resuming is the single ownership point, and
    /// all access is main-actor-serialized).
    func downloadAndWait(_ episode: Episode, timeout: TimeInterval = 120) async -> Bool {
        if episode.downloadStatus == .downloaded { return true }
        await download(episode)
        switch episode.downloadStatus {
        case .downloaded:
            return true
        case .downloading:
            break
        case .none, .pending, .failed:
            return false
        }
        let key = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
        // No suspension between download(_:) returning and the waiter being
        // parked (this closure runs synchronously on the main actor), so the
        // terminal event can't slip past unobserved.
        return await withCheckedContinuation { continuation in
            let id = Self.addWaiter(continuation, for: key)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // No-op when the terminal event already resolved this waiter.
                Self.timeOutWaiter(id: id, for: key)
            }
        }
    }

    /// Starts every episode parked at `.pending` (Wi-Fi-gated, #576) through the
    /// normal ``download(_:)`` path. Called when the network becomes Wi-Fi and
    /// once on the first path report after launch. `download(_:)` re-checks the
    /// gate itself, so if connectivity no longer qualifies the episodes simply
    /// stay `.pending`.
    ///
    /// Bounded by the tiny ``ActiveDownload`` table (#701) instead of the old
    /// whole-`Episode`-table fetch. Internal, not private, so tests can drive it.
    func startPendingDownloads() async {
        guard let context, downloadsAllowed else { return }
        let episodes = await activeEpisodes(state: .pending, in: context)
        guard !episodes.isEmpty else { return }
        AppLog.networking.info("Starting \(episodes.count) Wi-Fi-gated download(s)")
        for episode in episodes {
            await download(episode)
        }
    }

    /// Downloads every queued episode that isn't already downloaded or in flight,
    /// when "Auto-download queued episodes" is on (default). Bounded by the (small)
    /// queue: it fetches the ``QueueItem`` table, never the Episode table. Honors
    /// the Wi-Fi gate automatically because it routes through ``download(_:)`` — a
    /// gated episode parks at `.pending` and starts later, exactly like a manual
    /// download.
    ///
    /// Fired for manual/opt-in adds via the ``Notification/Name/earshotQueueDidChange``
    /// observer wired in ``configure(context:)``, and for refresh-time auto-queue
    /// from ``SubscriptionRepository``'s refresh completion. Idempotent: an episode
    /// already `.downloaded` / `.downloading` / `.pending` is skipped, so repeated
    /// queue changes (including reorders) never re-enqueue work. A `.failed`
    /// episode is left for a manual retry rather than re-hammered on every change.
    func downloadQueuedIfEnabled() async {
        guard let context else { return }
        guard settings?.bool(SettingsKey.autoDownloadQueued, default: SettingsDefault.autoDownloadQueued) == true
        else { return }
        let items = (try? context.fetch(FetchDescriptor<QueueItem>())) ?? []
        for item in items {
            guard let episode = item.episode, episode.downloadStatus == .none else { continue }
            await download(episode)
        }
    }

    /// Resets episodes stuck at `.downloading` with no live background task (the
    /// app was killed mid-transfer) so they don't hang forever (#544). Episodes
    /// whose task is still in flight are left untouched — the delegate will finish
    /// them. Call once at launch after ``configure(context:)``.
    ///
    /// The candidate rows now come from the bounded ``ActiveDownload`` table
    /// rather than a whole-`Episode`-table fetch on the main actor (#701); the
    /// orphan comparison itself is unchanged.
    func reconcileStuckDownloads() async {
        guard let context else { return }
        let markedDownloading = await activeEpisodes(state: .downloading, in: context)
        guard !markedDownloading.isEmpty else { return }

        let liveKeys = await Self.liveTaskKeys()
        let identities = markedDownloading.map { episode in
            (composite: DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid),
             bare: episode.guid)
        }
        let orphaned = DownloadReconciliation.orphanedIndices(
            markedDownloading: identities,
            liveTaskKeys: liveKeys
        )
        guard !orphaned.isEmpty else { return }
        for index in orphaned {
            // Also drops the ActiveDownload row: .failed is terminal, so the work
            // is over and reconciliation must not see it again.
            ActiveDownload.setDownloadStatus(.failed, on: markedDownloading[index], in: context)
        }
        save()
        AppLog.networking.info("Reconciled \(orphaned.count) stuck download(s) to failed")
    }

    /// The episodes whose download is currently in `state`, resolved on the
    /// caller's (main) context.
    ///
    /// The fetch itself runs on a throwaway background `ModelContext` so the
    /// launch path never does store I/O on the main actor (#701), and only
    /// Sendable `PersistentIdentifier`s cross back — SwiftData models are not
    /// Sendable across contexts. Pending changes are saved first so the
    /// background context sees a complete store.
    ///
    /// Any row whose episode has vanished is garbage-collected here: ``episode``
    /// has no inverse, so SwiftData does not nullify it for us.
    private func activeEpisodes(
        state: ActiveDownloadState, in context: ModelContext
    ) async -> [Episode] {
        save()
        let keys = await Self.activeDownloadKeys(state: state, in: context.container)
        let matches = (try? LocalStateStore.episodes(matching: keys, in: context)) ?? [:]
        return keys.compactMap { matches[$0] }
    }

    /// Persistent IDs of the ``ActiveDownload`` rows in `state`, fetched off the
    /// main actor on a throwaway context (#701). A plain-`String` predicate on
    /// `stateRaw` is the whole reason this table exists: `Episode.downloadStatus`
    /// is a Codable enum SwiftData refuses in a `#Predicate`.
    private static func activeDownloadKeys(
        state: ActiveDownloadState, in container: ModelContainer
    ) async -> [EpisodeLocalKey] {
        let raw = state.rawValue
        return await Task.detached(priority: .utility) {
            let scan = ModelContext(container)
            let descriptor = FetchDescriptor<LocalEpisodeState>(
                predicate: #Predicate { $0.downloadStatusRaw == raw }
            )
            return ((try? scan.fetch(descriptor)) ?? []).map {
                EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID)
            }
        }.value
    }

    /// Removes a downloaded file and resets the episode's download state. The
    /// file is deleted via the RESOLVED URL (`Episode.localAudioURL`), so a
    /// legacy absolute `downloadPath` from before an app update still deletes
    /// the real file instead of a dead path (#575).
    func removeDownload(_ episode: Episode) {
        guard let context else { return }
        if let url = episode.localAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        episode.downloadPath = nil
        // Drops any ActiveDownload row too: removing a download mid-transfer must
        // not leave reconciliation chasing it (#701).
        ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
        save()
    }

    /// Counts completed and active downloads and measures the allocated bytes in
    /// the Downloads directory. Directory traversal stays off the main actor;
    /// only the compact scalar summary returns to SwiftUI.
    func storageSummary() async -> DownloadStorageSummary {
        guard let context else { return .empty }
        save()

        let completedDescriptor = FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { $0.downloadPath != nil }
        )
        let downloadedCount = (try? context.fetchCount(completedDescriptor)) ?? 0
        let pending = await activeEpisodes(state: .pending, in: context)
        let downloading = await activeEpisodes(state: .downloading, in: context)
        let activeCount = Set((pending + downloading).map(\.persistentModelID)).count
        let allocatedBytes = await Task.detached(priority: .utility) {
            guard let directory = try? DownloadPaths.downloadsDirectory() else { return Int64(0) }
            return RecoveryDownloadRemoval.allocatedBytes(in: directory)
        }.value

        return DownloadStorageSummary(
            downloadedCount: downloadedCount,
            activeCount: activeCount,
            allocatedBytes: allocatedBytes
        )
    }

    /// Stops pending and in-flight transfers without touching completed audio.
    /// Cancellation happens before state reset so a late delegate callback sees
    /// a non-downloading episode and cannot overwrite the reset with `.failed`.
    @discardableResult
    func cancelActiveDownloads() async -> Int {
        guard let context else { return 0 }
        let pending = await activeEpisodes(state: .pending, in: context)
        let downloading = await activeEpisodes(state: .downloading, in: context)
        var seen = Set<PersistentIdentifier>()
        let affected = (pending + downloading).filter {
            seen.insert($0.persistentModelID).inserted
        }
        guard !affected.isEmpty else { return 0 }

        await Self.cancelAllTasks()
        for episode in affected {
            ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
        }
        save()
        AppLog.networking.info("Cancelled \(affected.count) active download(s)")
        return affected.count
    }

    /// Removes every downloaded file and resets all download state in one pass —
    /// the bulk equivalent of ``removeDownload(_:)``. Returns the number of
    /// episodes cleared (files removed plus in-flight transfers cancelled).
    ///
    /// Order matters: cancel any live background transfers FIRST so a completion
    /// can't land a fresh file on disk after the sweep. Cancellation delivers an
    /// `onFailed` terminal event, but every affected episode is reset to `.none`
    /// here regardless, and the `ActiveDownload` row is dropped in the same save,
    /// so a late `.failed` write has nothing to clobber (it early-returns on the
    /// `.downloading` guard in ``fail(taskKey:)``).
    ///
    /// The candidate set is the two bounded, queryable sources (#701): episodes
    /// with a file on disk (`downloadPath != nil`) and in-flight rows
    /// (`ActiveDownload`, `.pending` / `.downloading`). A stray `.failed` episode
    /// has no file and no row, so there is nothing to remove for it.
    @discardableResult
    func clearAllDownloads() async -> Int {
        guard let context else { return 0 }

        var affected: [Episode] = await episodesWithDownloadPath(in: context)
        var seen = Set(affected.map(\.persistentModelID))
        var hasInFlight = false
        for state in [ActiveDownloadState.pending, .downloading] {
            for episode in await activeEpisodes(state: state, in: context) {
                hasInFlight = true
                if seen.insert(episode.persistentModelID).inserted {
                    affected.append(episode)
                }
            }
        }
        guard !affected.isEmpty else { return 0 }

        // Cancel live transfers BEFORE resetting state so a completion delivered
        // mid-clear can't write `downloadPath`/`.downloaded` back onto a row we
        // just cleared. Only reach for the shared background session when a
        // transfer is actually in flight — the common "delete downloaded files"
        // path never forces the session into existence.
        if hasInFlight {
            await Self.cancelAllTasks()
        }

        for episode in affected {
            if let url = episode.localAudioURL {
                try? FileManager.default.removeItem(at: url)
            }
            episode.downloadPath = nil
            ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
        }
        save()
        AppLog.networking.info("Cleared \(affected.count) download(s)")
        return affected.count
    }

    /// Cancels every task on the shared background session. Used by
    /// ``clearAllDownloads()`` so no in-flight transfer completes after a clear.
    static func cancelAllTasks() async {
        for task in await allTasks() { task.cancel() }
    }

    /// A recovery marker may be removed only after cancellation callbacks have
    /// crossed the delegate queue. If the session does not quiesce promptly, the
    /// marker stays durable and the whole idempotent reconciliation retries on
    /// the next launch.
    static func cancelAllTasksAndWaitForRecovery() async -> Bool {
        await cancelAllTasks()
        for _ in 0..<250 {
            if await allTasks().isEmpty {
                await withCheckedContinuation { continuation in
                    session.delegateQueue.addOperation { continuation.resume() }
                }
                if await allTasks().isEmpty { return true }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    /// Heals `downloadPath` values written by pre-#575 builds, which stored
    /// ABSOLUTE container paths. iOS relocates the app container on every app
    /// update, so every such path goes stale: playback silently fell back to
    /// streaming and Remove deleted a dead path while the real file survived.
    ///
    /// For each episode that HAS a `downloadPath`: rewrite a legacy absolute
    /// value to just the file name; if the resolved file no longer exists on
    /// disk, reset the episode to not-downloaded so the UI offers a re-download
    /// instead of listing an unplayable file. Idempotent (healed rows are
    /// skipped next launch) and cheap (writes only rows that need it). Never
    /// throws outward — unverifiable rows are left alone. Call once at launch
    /// after ``configure(context:)``, alongside ``reconcileStuckDownloads()``.
    ///
    /// **Scope (#701).** The candidate set is now the bounded
    /// `downloadPath != nil` predicate rather than a fetch of the ENTIRE Episode
    /// table filtered in memory for `.downloaded` — on a 241,979-row library that
    /// fetch was a launch watchdog kill, and `downloadStatus` cannot be queried
    /// (a Codable enum SwiftData rejects in a `#Predicate`). Both purposes of
    /// this function are fully preserved: legacy ABSOLUTE paths (the #575 reason
    /// it exists) and file-gone resets both operate on rows with a non-nil path.
    ///
    /// The one deliberate, approved narrowing: a row marked `.downloaded` with NO
    /// path at all is no longer reset. That defensive branch cannot survive a
    /// bounded query — catching it would mean querying the enum, which is
    /// impossible — and it only ever fired on rows that were already internally
    /// inconsistent. An empty-string path is still caught (`"" != nil`).
    func reconcileDownloadPaths() async {
        guard let context else { return }
        let episodes = await episodesWithDownloadPath(in: context)
        guard !episodes.isEmpty else { return }

        var rewritten = 0
        var reset = 0
        for episode in episodes {
            guard let name = DownloadPaths.storedFileName(episode.downloadPath) else {
                // A non-nil but unusable path (empty string): inconsistent row;
                // make it re-downloadable.
                episode.downloadPath = nil
                ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
                reset += 1
                continue
            }
            guard let resolved = DownloadPaths.resolveLocalURL(storedValue: name) else {
                // Downloads directory unavailable right now — don't clear state
                // we can't verify; try again next launch.
                continue
            }
            if FileManager.default.fileExists(atPath: resolved.path) {
                if episode.downloadPath != name {
                    LocalStateStore.setDownloadPath(name, on: episode, in: context)
                    rewritten += 1
                }
            } else {
                episode.downloadPath = nil
                ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
                reset += 1
            }
        }
        guard rewritten > 0 || reset > 0 else { return }
        save()
        AppLog.networking.info("Reconciled download paths: \(rewritten) legacy path(s) rewritten, \(reset) missing file(s) reset")
    }

    /// Episodes with a non-nil `downloadPath`, resolved on the caller's (main)
    /// context. Bounded by what the user actually downloaded (#701), and fetched
    /// on a throwaway background context so the launch path does no store I/O on
    /// the main actor. Only Sendable identifiers cross back.
    private func episodesWithDownloadPath(in context: ModelContext) async -> [Episode] {
        save()
        let container = context.container
        let keys = await Task.detached(priority: .utility) {
            let scan = ModelContext(container)
            let descriptor = FetchDescriptor<LocalEpisodeState>(
                predicate: #Predicate { $0.downloadPath != nil }
            )
            return ((try? scan.fetch(descriptor)) ?? []).map {
                EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID)
            }
        }.value
        let matches = (try? LocalStateStore.episodes(matching: keys, in: context)) ?? [:]
        return keys.compactMap { matches[$0] }
    }

    // MARK: Terminal events (delegate → main actor → SwiftData)

    static func handle(_ event: PendingDownloadTerminalEvent) {
        defer { delegate.acknowledge(event) }
        if RecoveryDownloadRemoval.isPending {
            if case .finished(let fileName) = event.outcome,
               let url = DownloadPaths.resolveLocalURL(storedValue: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        switch event.outcome {
        case .finished(let fileName):
            complete(taskKey: event.taskKey, fileName: fileName)
        case .failed:
            fail(taskKey: event.taskKey)
        }
    }

    private static func complete(taskKey: String, fileName: String) {
        // Wake downloadAndWait callers first, unconditionally, so a failed
        // episode lookup can't leave a continuation parked until its timeout.
        // Resumption only SCHEDULES the waiter — it runs after this function
        // returns, so it observes the persisted state below.
        resolveWaiters(for: taskKey, success: true)
        guard let context = container?.mainContext,
              let episode = DownloadTaskKey.episode(matching: taskKey, in: context) else {
            // A local or remotely delivered unfollow can delete the episode
            // while its background URLSession task is still finishing. The
            // delegate has already moved the temporary file into Downloads by
            // this point. With no surviving natural-key owner, retaining it
            // would leak device storage forever; never attempt to write through
            // the deleted SwiftData model.
            if let url = DownloadPaths.resolveLocalURL(storedValue: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        // Store only the file NAME: iOS relocates the app container on every
        // app update, so an absolute path goes stale (#575). Reads resolve the
        // name against the current container via `Episode.localAudioURL`.
        episode.downloadPath = fileName
        // Terminal: this also drops the ActiveDownload row, in the same save
        // (#701).
        ActiveDownload.setDownloadStatus(.downloaded, on: episode, in: context)
        save(context, action: "complete")
        Announcer.announce("Downloaded \(episode.title)")
        let shouldNotify = AppSettingsStore(context: context).bool(
            SettingsKey.downloadCompletionNotifications,
            default: SettingsDefault.downloadCompletionNotifications
        )
        if shouldNotify,
           let feedURL = episode.podcast?.feedURL {
            let title = episode.title
            let guid = episode.guid
            let center = notificationCenter
            Task {
                await NotificationService(center: center).deliverDownloadCompleted(
                    episodeTitle: title,
                    podcastFeedURL: feedURL,
                    episodeGUID: guid
                )
            }
        }
        AppLog.networking.info("Download finished: \(episode.title, privacy: .public)")
    }

    #if DEBUG
    static func setContainerForTesting(_ container: ModelContainer?) {
        self.container = container
    }

    static func setNotificationCenterForTesting(_ center: (any NotificationScheduling)?) {
        notificationCenter = center ?? SystemNotificationCenter()
    }
    #endif

    private static func fail(taskKey: String) {
        resolveWaiters(for: taskKey, success: false)
        guard let context = container?.mainContext,
              let episode = DownloadTaskKey.episode(matching: taskKey, in: context) else { return }
        // Don't clobber a state that already moved on (e.g. the user removed it).
        guard episode.downloadStatus == .downloading else { return }
        ActiveDownload.setDownloadStatus(.failed, on: episode, in: context)
        save(context, action: "fail")
        AppLog.networking.error("Download failed: \(episode.title, privacy: .public)")
    }

    /// The task keys (composite `"feedURL|guid"`, or bare guids from tasks
    /// enqueued by a pre-#576 build) of tasks the background session still has
    /// in flight.
    private static func liveTaskKeys() async -> Set<String> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { $0.taskDescription }))
            }
        }
    }

    // MARK: downloadAndWait continuations (#576)

    /// Continuations parked by ``downloadAndWait(_:timeout:)``, keyed by the
    /// composite task key. Each entry is resumed EXACTLY once: removal from
    /// this dictionary before resuming is the single ownership point, and every
    /// access is main-actor-isolated, so the terminal event and the timeout
    /// task can't double-resume. Every waiter is paired with a timeout task, so
    /// none can leak if a terminal event never arrives.
    @ObservationIgnored private static var downloadWaiters:
        [String: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)]] = [:]

    private static func addWaiter(
        _ continuation: CheckedContinuation<Bool, Never>, for key: String
    ) -> UUID {
        let id = UUID()
        downloadWaiters[key, default: []].append((id: id, continuation: continuation))
        return id
    }

    /// Resumes and removes every waiter parked for `key`. Called on the
    /// terminal complete/fail event. No-op when nothing is waiting.
    private static func resolveWaiters(for key: String, success: Bool) {
        guard let parked = downloadWaiters.removeValue(forKey: key) else { return }
        for waiter in parked {
            waiter.continuation.resume(returning: success)
        }
    }

    /// Resumes exactly the ONE waiter identified by `id` with false. Called by
    /// that waiter's timeout task; no-op when the terminal event already
    /// resolved it. Other callers waiting on the same key keep waiting.
    private static func timeOutWaiter(id: UUID, for key: String) {
        guard var parked = downloadWaiters[key],
              let index = parked.firstIndex(where: { $0.id == id }) else { return }
        let waiter = parked.remove(at: index)
        downloadWaiters[key] = parked.isEmpty ? nil : parked
        AppLog.networking.error("downloadAndWait timed out for task key")
        waiter.continuation.resume(returning: false)
    }

    // MARK: Internals

    /// The one save path for download state (#576): logs failures instead of
    /// discarding them. Static so the delegate-driven terminal events (which
    /// run without an instance) share it with instance methods via ``save()``.
    private static func save(_ context: ModelContext, action: String) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.networking.error("Download \(action, privacy: .public) save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let context else { return }
        Self.save(context, action: "state")
    }
}

/// Download-side reactions to episode lifecycle changes that any layer can call
/// without a ``DownloadManager`` (which is `@MainActor` and owns the live
/// background session). Lives here, alongside the download logic it mirrors,
/// rather than in its own file, because the Xcode project uses manual file
/// references.
@MainActor
enum DownloadCleanup {
    /// Whether automatic download cleanup is on. Read once and reused when
    /// clearing many episodes in a loop (e.g. Mark all as played or Clear queue)
    /// so a bulk action doesn't refetch the setting per episode. The stored key
    /// retains its original name for compatibility.
    static func deleteAfterPlayedEnabled(_ context: ModelContext) -> Bool {
        AppSettingsStore(context: context)
            .bool(SettingsKey.deleteDownloadAfterPlayed, default: SettingsDefault.deleteDownloadAfterPlayed)
    }

    /// Deletes `episode`'s downloaded file and resets its download state — the
    /// same file+state contract as ``DownloadManager/removeDownload(_:)`` (delete
    /// via the resolved ``Episode/localAudioURL``, reset through
    /// ``ActiveDownload/setDownloadStatus(_:on:in:)``). No-op unless the episode
    /// is actually `.downloaded`, so an in-flight transfer is never touched. The
    /// caller saves the context (every mark-played path already saves right after).
    static func removeDownloadFileAndState(_ episode: Episode, in context: ModelContext) {
        guard episode.downloadStatus == .downloaded else { return }
        if let url = episode.localAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        episode.downloadPath = nil
        ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
    }

    /// Convenience for single-episode completion and deliberate queue-removal
    /// paths: removes the download only when the setting is on. Bulk callers should gate once with
    /// ``deleteAfterPlayedEnabled(_:)`` and call ``removeDownloadFileAndState(_:in:)``.
    static func removeDownloadAfterPlayedIfEnabled(_ episode: Episode, in context: ModelContext) {
        guard deleteAfterPlayedEnabled(context) else { return }
        removeDownloadFileAndState(episode, in: context)
    }
}
