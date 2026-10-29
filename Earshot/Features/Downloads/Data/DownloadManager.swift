import Foundation
import Network
import Observation
import SwiftData
import UIKit

struct DownloadBatchReport: Equatable, Sendable {
    let eligible: Int
    var downloading: Int = 0
    var waitingForWifi: Int = 0
    var completed: Int = 0
    let skipped: Int
    let deferred: Int
    let failed: Int
    let wasCancelled: Bool

    var accepted: Int { downloading + waitingForWifi + completed }

    var announcement: String {
        var parts = [
            "Eligible \(eligible)",
            "accepted \(accepted)",
            "downloading \(downloading)",
            "waiting for Wi-Fi \(waitingForWifi)",
            "already finished \(completed)",
            "skipped \(skipped)",
            "deferred \(deferred)",
            "could not start \(failed)",
        ]
        if wasCancelled {
            parts.append("cancelled before requesting \(max(0, eligible - deferred - accepted - failed))")
        }
        return "Download requests prepared. " + parts.joined(separator: ", ")
            + ". Open Download activity in Downloads to check progress or retry failures."
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

/// Keeps transient store errors from stranding journaled events until relaunch.
/// The journal remains the source of truth after retries are exhausted.
@MainActor
final class DownloadEventRetrier {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var requestedAgain: Set<UUID> = []
    private let delays: [Duration]
    private let sleep: @MainActor (Duration) async throws -> Void

    init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.delays = delays
        self.sleep = sleep
    }

    func submit(_ event: PendingDownloadTerminalEvent,
                handle: @escaping @MainActor (PendingDownloadTerminalEvent) -> Bool) {
        guard tasks[event.id] == nil else {
            requestedAgain.insert(event.id)
            return
        }
        if handle(event) { return }
        tasks[event.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    self.tasks[event.id] = nil
                    if self.requestedAgain.remove(event.id) != nil {
                        self.submit(event, handle: handle)
                    }
                }
            }
            for delay in self.delays {
                do { try await self.sleep(delay) } catch { return }
                guard !Task.isCancelled else { return }
                if handle(event) { return }
            }
        }
    }

    func cancelAll() {
        let running = Array(tasks.values)
        tasks.removeAll()
        requestedAgain.removeAll()
        for task in running { task.cancel() }
    }
}

struct DownloadStorageCounts: Equatable, Sendable {
    let downloadedCount: Int
    let activeCount: Int
}

/// Only scalar data crosses back from the background store scan. Paths also
/// identify when an already scheduled directory-size scan needs a fresh pass.
struct DownloadStorageSnapshot: Equatable, Sendable {
    let counts: DownloadStorageCounts
    let paths: Set<String>
    let executedStoreWorkOnMainThread: Bool

    @concurrent
    static func load(container: ModelContainer) async throws -> Self {
        try loadSynchronously(container: container)
    }

    private static func loadSynchronously(container: ModelContainer) throws -> Self {
        let scan = ModelContext(container)
        let onMain = Thread.isMainThread
        let completed = FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { $0.downloadPath != nil }
        )
        let pending = DownloadStatus.pending.rawValue
        let downloading = DownloadStatus.downloading.rawValue
        let active = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate {
            $0.downloadStatusRaw == pending || $0.downloadStatusRaw == downloading
        })
        let completedRows = try scan.fetch(completed)
        let keys = Array(Set(try scan.fetch(active).map {
            EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID)
        }))
        let matches = try LocalStateStore.episodes(matching: keys, in: scan)
        return Self(
            counts: .init(downloadedCount: completedRows.count,
                          activeCount: Set(matches.values.map(\.persistentModelID)).count),
            paths: Set(completedRows.compactMap(\.downloadPath)),
            executedStoreWorkOnMainThread: onMain || Thread.isMainThread
        )
    }
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
    @ObservationIgnored private weak var deferredReconciliationContext: ModelContext?
    @ObservationIgnored private var deferredReconciliationKeys: (@MainActor () async -> Set<String>?)?
    @ObservationIgnored private let journalWaiterID = UUID()
    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Observer for `.earshotQueueDidChange`, so queued episodes auto-download.
    @ObservationIgnored private var queueChangeObserver: NSObjectProtocol?
    @ObservationIgnored private let startTransfer: (URL, String) -> Void

    init(startTransfer: @escaping (URL, String) -> Void = { url, key in
        let task = DownloadManager.session.downloadTask(with: url)
        task.taskDescription = key
        task.resume()
    }) {
        self.startTransfer = startTransfer
    }

    #if DEBUG
    func configureForTesting(context: ModelContext, isOnWifi: Bool) {
        if self.context !== context {
            deferredReconciliationContext = nil
            deferredReconciliationKeys = nil
        }
        self.context = context
        self.settings = AppSettingsStore(context: context)
        self.isOnWifi = isOnWifi
    }
    #endif

    // MARK: Shared background session (one per identifier per process)

    /// Background session identifier; also matched by the app delegate's
    /// `handleEventsForBackgroundURLSession`.
    static let sessionIdentifier = "media.payown.earshot.swift.downloads"

    @ObservationIgnored private static let delegate = DownloadSessionDelegate()
    @ObservationIgnored private static let terminalRetrier = DownloadEventRetrier()
    @ObservationIgnored private static var replayObservers: [NSObjectProtocol] = []
    /// Store effects already committed in this process but not yet removed
    /// from the journal. Retry only the acknowledgement, since a newer
    /// download may have started after the first application.
    @ObservationIgnored private static var pendingAcknowledgements: Set<UUID> = []

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
        terminalRetrier.cancelAll()
        self.container = container
        delegate.installTerminalHandler(replayHandler: { event, generation in
            await MainActor.run { processDelegateEvent(event, generation: generation) }
        }) { event, generation in
            Task { @MainActor in
                processDelegateEvent(event, generation: generation)
            }
        }
        installReplayObserversIfNeeded()
        installEventsFinishedHandler()
        _ = session
    }

    private static func processDelegateEvent(_ event: PendingDownloadTerminalEvent, generation: UInt64) {
        guard delegate.isCurrentNormalHandler(generation) else { return }
        submitJournalEvent(event, delegate: delegate, retrier: terminalRetrier) { handle($0) }
    }

    static func submitJournalEvent(
        _ event: PendingDownloadTerminalEvent,
        delegate: DownloadSessionDelegate,
        retrier: DownloadEventRetrier,
        handle: @escaping @MainActor (PendingDownloadTerminalEvent) -> Bool
    ) {
        retrier.submit(event) { event in
            guard let pending = delegate.containsPendingEvent(event) else { return false }
            guard pending else { return true }
            return handle(event)
        }
    }

    private static func installReplayObserversIfNeeded() {
        guard replayObservers.isEmpty else { return }
        for name in [UIApplication.didBecomeActiveNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in delegate.retryPendingEvents() }
            }
            replayObservers.append(observer)
        }
    }

    /// Connects the delegate while the durable marker still suppresses terminal
    /// events, drains old tasks, repeats the filesystem sweep, then reconciles
    /// SwiftData before the ready UI is published.
    static func prepareForReadyContainer(_ container: ModelContainer) async {
        guard RecoveryDownloadRemoval.isPending else {
            activate(container: container)
            return
        }
        terminalRetrier.cancelAll()
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
        terminalRetrier.cancelAll()
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
        if self.context !== context {
            deferredReconciliationContext = nil
            deferredReconciliationKeys = nil
        }
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
        deferredReconciliationContext = nil
        deferredReconciliationKeys = nil
        Self.terminalRetrier.cancelAll()
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
        guard episode.downloadStatus != .downloaded,
              episode.downloadStatus != .downloading else { return }
        guard downloadsAllowed else {
            ActiveDownload.setDownloadStatus(.pending, on: episode, in: context)
            save()
            if announceWaiting {
                Announcer.announce("Waiting for Wi-Fi to download \(episode.title)")
            }
            AppLog.networking.info("Download gated: Wi-Fi unavailable")
            return
        }
        guard let rawURL = URL(string: episode.audioURL),
              ["http", "https"].contains(rawURL.scheme?.lowercased() ?? ""),
              rawURL.host != nil else {
            ActiveDownload.setDownloadStatus(.failed, on: episode, in: context)
            save()
            return
        }
        // A download is a non-media URLSession fetch (unlike AVFoundation
        // streaming), so require HTTPS under the media-only ATS policy (#387).
        // BBC's published HTTP selector has a working HTTPS variant (#709).
        let url = SecureURL.preferredMediaHTTPS(rawURL)

        // The ActiveDownload row and the .downloading write land in the SAME save
        // (#701): a row that lagged behind would leave this episode invisible to
        // reconcileStuckDownloads() and spinning forever — #544 returning.
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        save()

        // taskDescription (unlike taskIdentifier) survives an app relaunch, so a
        // completion delivered after the app was killed still resolves the
        // episode. The composite "feedURL|guid" key (#576) disambiguates guids
        // that repeat across podcasts.
        let identityKey = DownloadTaskKey.key(
            feedURL: episode.podcast?.feedURL,
            guid: episode.guid
        )
        let transferKey = DownloadTransferKey.key(
            identityKey: identityKey,
            sourceURL: url
        )
        startTransfer(url, transferKey)
        AppLog.networking.info("Download started in the background")
    }

    /// Enrolls an explicit user-selected batch through the same guarded path as
    /// a single download. Downloaded, pending, and downloading episodes are
    /// skipped before task creation, failed downloads remain retryable, and the
    /// main actor yields every bounded slice. The caller owns the one final
    /// accessibility announcement so Wi-Fi gating never chatters once per row.
    func downloadAll(_ episodes: [Episode]) async -> DownloadBatchReport {
        let plan = ManualDownloadBatchPlan.make(statuses: episodes.map(\.downloadStatus))
        let eligibleEpisodes = plan.selectedIndices.map { episodes[$0] }
        var downloading = 0
        var waitingForWifi = 0
        var completed = 0
        var failed = 0
        var wasCancelled = false

        for (index, episode) in eligibleEpisodes.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            await download(episode, announceWaiting: false)
            switch episode.downloadStatus {
            case .pending: waitingForWifi += 1
            case .downloading: downloading += 1
            case .downloaded: completed += 1
            case .failed, .none:
                failed += 1
            }

            if (index + 1).isMultiple(of: Self.batchEnrollmentSize) {
                await Task.yield()
            }
        }

        return DownloadBatchReport(
            eligible: plan.eligibleCount,
            downloading: downloading,
            waitingForWifi: waitingForWifi,
            completed: completed,
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
    func reconcileStuckDownloads(
        journalDelegate: DownloadSessionDelegate = DownloadManager.delegate,
        requiredGeneration: UInt64? = nil,
        liveKeys: @escaping @MainActor () async -> Set<String>? = { await DownloadManager.liveTaskKeys() }
    ) async {
        guard let context else { return }
        let markedDownloading = await activeEpisodes(state: .downloading, in: context)
        guard !markedDownloading.isEmpty else { return }

        let keys = await liveKeys()
        guard !Task.isCancelled, self.context === context,
              !RecoveryDownloadRemoval.isPending else { return }
        if let requiredGeneration {
            guard Self.container === context.container else { return }
            guard journalDelegate.isCurrentNormalHandler(requiredGeneration) else {
                deferReconciliation(context: context, journalDelegate: journalDelegate, liveKeys: liveKeys)
                return
            }
        }
        guard let liveKeys = keys else {
            deferReconciliation(context: context, journalDelegate: journalDelegate, liveKeys: liveKeys)
            return
        }
        deferredReconciliationContext = nil
        deferredReconciliationKeys = nil
        let identities = markedDownloading.map { episode in
            (composite: DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid),
             bare: episode.guid)
        }
        let orphaned = DownloadReconciliation.orphanedIndices(
            markedDownloading: identities,
            liveTaskKeys: liveKeys
        )
        guard !orphaned.isEmpty else { return }
        var failed = 0
        for index in orphaned {
            guard !markedDownloading[index].isDeleted,
                  markedDownloading[index].downloadStatus == .downloading else { continue }
            // Also drops the ActiveDownload row: .failed is terminal, so the work
            // is over and reconciliation must not see it again.
            ActiveDownload.setDownloadStatus(.failed, on: markedDownloading[index], in: context)
            failed += 1
        }
        save()
        AppLog.networking.info("Reconciled \(failed) stuck download(s) to failed")
    }

    private func deferReconciliation(
        context: ModelContext, journalDelegate: DownloadSessionDelegate,
        liveKeys: @escaping @MainActor () async -> Set<String>?
    ) {
        deferredReconciliationContext = context
        deferredReconciliationKeys = liveKeys
        journalDelegate.whenJournalReadable(id: journalWaiterID) { [weak self, weak journalDelegate] generation in
            Task { @MainActor [weak self, weak journalDelegate] in
                guard let self, let journalDelegate else { return }
                await self.resumeDeferredReconciliation(journalDelegate: journalDelegate, generation: generation)
            }
        }
    }

    func resumeDeferredReconciliation(journalDelegate: DownloadSessionDelegate, generation: UInt64) async {
        guard let context = deferredReconciliationContext,
              self.context === context, Self.container === context.container,
              !RecoveryDownloadRemoval.isPending,
              let retryKeys = deferredReconciliationKeys else { return }
        guard journalDelegate.isCurrentNormalHandler(generation) else {
            deferReconciliation(context: context, journalDelegate: journalDelegate, liveKeys: retryKeys)
            return
        }
        await reconcileStuckDownloads(
            journalDelegate: journalDelegate,
            requiredGeneration: generation,
            liveKeys: retryKeys
        )
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
        if episode.downloadStatus == .downloading {
            Self.cancelDownload(identityKey: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL, guid: episode.guid
            ))
        }
        try? DownloadPaths.removeIfUnshared(storedValue: episode.downloadPath, for: episode, in: context)
        episode.downloadPath = nil
        // Drops any ActiveDownload row too: removing a download mid-transfer must
        // not leave reconciliation chasing it (#701).
        ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
        save()
    }

    /// Finishes a feed-driven media correction after the background refresh
    /// save is visible on the main context. Cancellation is identity-scoped: a
    /// repaired show never disturbs unrelated background downloads. A second
    /// file/state reset closes the narrow window where a legacy task (which has
    /// no source fingerprint) completed between the actor save and this call.
    func replaceCorrectedMedia(_ repairs: [CorrectedEpisodeMedia]) async {
        guard let context, !repairs.isEmpty else { return }
        let episodes = repairs.compactMap { repair -> (Episode, CorrectedEpisodeMedia)? in
            let episodeID = repair.episodeID
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.persistentModelID == episodeID }
            )
            descriptor.fetchLimit = 1
            guard let episode = (try? context.fetch(descriptor))?.first else { return nil }
            return (episode, repair)
        }
        guard !episodes.isEmpty else { return }

        let identityKeys = Set(episodes.map {
            DownloadTaskKey.key(feedURL: $0.0.podcast?.feedURL, guid: $0.0.guid)
        })
        await Self.cancelTasks(matchingIdentityKeys: identityKeys)
        for (episode, repair) in episodes {
            Self.resolveWaiters(for: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL, guid: episode.guid
            ), success: false)
            try? DownloadPaths.removeIfUnshared(storedValue: repair.staleDownloadPath, for: episode, in: context)
            try? DownloadPaths.removeIfUnshared(storedValue: episode.downloadPath, for: episode, in: context)
            episode.downloadPath = nil
            ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
        }
        save()
        for (episode, repair) in episodes where repair.restoreDownloadIntent {
            await download(episode, announceWaiting: false)
        }
        AppLog.networking.notice(
            "Replaced corrected media for \(episodes.count) episode(s)"
        )
    }

    /// Counts completed and active downloads and measures the allocated bytes in
    /// the Downloads directory. Directory traversal stays off the main actor;
    /// only the compact scalar summary returns to SwiftUI.
    func storageSummary() async -> DownloadStorageSummary {
        guard context != nil else { return .empty }
        let counts = await storageCounts()
        let allocatedBytes = await storageAllocatedBytes()
        return DownloadStorageSummary(
            downloadedCount: counts.downloadedCount,
            activeCount: counts.activeCount,
            allocatedBytes: allocatedBytes
        )
    }

    /// Read directory usage separately so Settings does not recount the same
    /// library when it requests a size scan as well as an activity refresh.
    func storageAllocatedBytes() async -> Int64 {
        guard context != nil else { return 0 }
        return await Task.detached(priority: .utility) {
            guard let directory = try? DownloadPaths.downloadsDirectory() else { return Int64(0) }
            return RecoveryDownloadRemoval.allocatedBytes(in: directory)
        }.value
    }

    func storageSnapshot() async -> DownloadStorageSnapshot? {
        guard let context else { return nil }
        save()
        do {
            return try await DownloadStorageSnapshot.load(container: context.container)
        } catch {
            AppLog.networking.error("Download storage snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Refresh counts without materializing episodes on the main actor.
    func storageCounts() async -> DownloadStorageCounts {
        await storageSnapshot()?.counts ?? .init(downloadedCount: 0, activeCount: 0)
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
            Self.resolveWaiters(for: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL, guid: episode.guid
            ), success: false)
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

        let removedOwners = Set(affected.compactMap { LocalStateStore.key(for: $0) })
        let retainedFiles = try? DownloadPaths.referencedFileNames(excluding: removedOwners, in: context)
        for episode in affected {
            Self.resolveWaiters(for: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL, guid: episode.guid
            ), success: false)
            if let retainedFiles, let name = DownloadPaths.storedFileName(episode.downloadPath),
               !retainedFiles.contains(name) {
                try? DownloadPaths.removeFile(named: name)
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

    /// Request cancellation without delaying synchronous episode actions. Resetting
    /// download state in the caller makes late terminal events discard their file.
    static func cancelDownload(identityKey: String, using downloadSession: URLSession? = nil) {
        resolveWaiters(for: identityKey, success: false)
        (downloadSession ?? session).getAllTasks { tasks in
            for task in tasks {
                guard let raw = task.taskDescription,
                      DownloadTransferKey.identityKey(from: raw) == identityKey else { continue }
                task.cancel()
            }
        }
    }

    private static func cancelTasks(matchingIdentityKeys keys: Set<String>) async {
        guard !keys.isEmpty else { return }
        for task in await allTasks() {
            guard let raw = task.taskDescription,
                  keys.contains(DownloadTransferKey.identityKey(from: raw)) else { continue }
            task.cancel()
        }
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
    func reconcileDownloadPaths(
        verifyBatch: ([DownloadPathReconciliation.Correction]) -> DownloadPathReconciliation.BatchVerification = {
            DownloadPathReconciliation.verifyBatch($0)
        },
        scan: @MainActor (ModelContainer) async throws -> [DownloadPathReconciliation.Correction] = {
            try await DownloadPathReconciliation.scan(container: $0)
        }
    ) async {
        guard let context else { return }
        save()
        do {
            let corrections = try await scan(context.container)
            var rewritten = 0
            var reset = 0
            // Only repair candidates need mirrored Episode models. Bound each
            // main-actor batch and yield so navigation can proceed between them.
            for start in stride(from: 0, to: corrections.count, by: 50) {
                guard !Task.isCancelled, self.context === context,
                      !RecoveryDownloadRemoval.isPending else { return }
                let batch = corrections[start..<min(start + 50, corrections.count)]
                let episodes = try LocalStateStore.episodes(matching: batch.map(\.key), in: context)
                let verified = verifyBatch(Array(batch))
                for correction in batch {
                    guard let episode = episodes[correction.key],
                          episode.downloadPath == correction.originalPath,
                          episode.downloadStatus.rawValue == correction.originalStatus else { continue }
                    if correction.checkedURL != nil, !verified.directoryValid { continue }
                    if let name = correction.replacementName {
                        LocalStateStore.setDownloadPath(name, on: episode, in: context)
                        rewritten += 1
                    } else {
                        // A transfer may have finished while the worker scanned.
                        // Recheck only missing-file candidates before clearing.
                        if let url = correction.checkedURL, !verified.missing.contains(url) { continue }
                        episode.downloadPath = nil
                        ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
                        reset += 1
                    }
                }
                save()
                await Task.yield()
            }
            if rewritten > 0 || reset > 0 {
                AppLog.networking.info("Reconciled download paths: \(rewritten) legacy path(s) rewritten, \(reset) missing file(s) reset")
            }
        } catch is CancellationError {
            // A later activation can retry without changing unverified rows.
        } catch {
            AppLog.networking.error("Download path reconciliation failed: \(error.localizedDescription)")
        }
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

    @discardableResult
    static func handle(
        _ event: PendingDownloadTerminalEvent,
        resolve: (String, ModelContext) throws -> Episode? = {
            try DownloadTaskKey.findEpisode(matching: $0, in: $1)
        },
        fetchLocalRows: (EpisodeLocalKey, ModelContext) throws -> [LocalEpisodeState] = LocalStateStore.episodeRowsThrowing,
        persist: (ModelContext) throws -> Void = { try $0.save() },
        acknowledge: (PendingDownloadTerminalEvent) -> Bool = { delegate.acknowledge($0) },
        isRecoveryPending: () -> Bool = { RecoveryDownloadRemoval.isPending }
    ) -> Bool {
        func acknowledgeAppliedEvent() -> Bool {
            guard acknowledge(event) else {
                pendingAcknowledgements.insert(event.id)
                return false
            }
            pendingAcknowledgements.remove(event.id)
            return true
        }
        if pendingAcknowledgements.contains(event.id) {
            return acknowledgeAppliedEvent()
        }
        if isRecoveryPending() {
            if case .finished(let fileName) = event.outcome,
               let url = DownloadPaths.resolveLocalURL(storedValue: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
            return acknowledgeAppliedEvent()
        }
        guard let context = container?.mainContext else { return false }
        do {
            let episode = try resolve(event.taskKey, context)
            switch event.outcome {
            case .finished(let fileName):
                try complete(taskKey: event.taskKey, fileName: fileName,
                             episode: episode, context: context, fetchLocalRows: fetchLocalRows, persist: persist)
            case .failed:
                try fail(taskKey: event.taskKey, episode: episode, context: context,
                         fetchLocalRows: fetchLocalRows, persist: persist)
            }
            return acknowledgeAppliedEvent()
        } catch {
            AppLog.networking.error("Download event will be retried: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func complete(
        taskKey: String, fileName: String, episode: Episode?, context: ModelContext,
        fetchLocalRows: (EpisodeLocalKey, ModelContext) throws -> [LocalEpisodeState],
        persist: (ModelContext) throws -> Void
    ) throws {
        let identityKey = DownloadTransferKey.identityKey(from: taskKey)
        guard let episode else {
            // A local or remotely delivered unfollow can delete the episode
            // while its background URLSession task is still finishing. The
            // delegate has already moved the temporary file into Downloads by
            // this point. With no surviving natural-key owner, retaining it
            // would leak device storage forever; never attempt to write through
            // the deleted SwiftData model.
            try removeFinishedFile(fileName, context: context)
            resolveWaiters(for: identityKey, success: false)
            return
        }
        // Replaying after a save succeeded but before acknowledgement must not
        // delete the file that the episode now owns.
        if episode.downloadStatus == .downloaded && episode.downloadPath == fileName {
            if context.hasChanges { try persist(context) }
            resolveWaiters(for: identityKey, success: true)
            return
        }
        // A feed correction or explicit removal can supersede a background
        // transfer while URLSession is delivering its terminal callback. Only
        // the still-current source, in the still-downloading state, may win.
        // This closes the late-success race that previously resurrected a stale
        // file after its replacement had already been selected.
        let currentSource = URL(string: episode.audioURL).map(SecureURL.preferredMediaHTTPS)
        let transferSource = DownloadTransferKey.parse(taskKey).flatMap {
            URL(string: $0.sourceURL)
        }
        guard episode.downloadStatus == .downloading,
              transferSource == nil || transferSource == currentSource else {
            try removeFinishedFile(fileName, context: context)
            AppLog.networking.notice("Ignored a superseded download completion")
            return
        }
        // Store only the file NAME: iOS relocates the app container on every
        // app update, so an absolute path goes stale (#575). Reads resolve the
        // name against the current container via `Episode.localAudioURL`.
        // Terminal: this also drops the ActiveDownload row, in the same save
        // (#701).
        try LocalStateStore.setTerminalDownloadState(.downloaded, path: fileName, on: episode,
                                                     in: context, fetchRows: fetchLocalRows)
        try persist(context)
        resolveWaiters(for: identityKey, success: true)
        // Status is durable and readable in Download activity. Per-episode
        // speech here can queue dozens of announcements after a bulk request;
        // users can read one live summary there, or opt into notifications below.
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

    private static func removeFinishedFile(_ fileName: String, context: ModelContext) throws {
        try DownloadPaths.removeIfUnshared(storedValue: fileName, excluding: [], in: context)
    }

    #if DEBUG
    static func setContainerForTesting(_ container: ModelContainer?) {
        self.container = container
    }

    static func setNotificationCenterForTesting(_ center: (any NotificationScheduling)?) {
        notificationCenter = center ?? SystemNotificationCenter()
    }
    #endif

    private static func fail(
        taskKey: String, episode: Episode?, context: ModelContext,
        fetchLocalRows: (EpisodeLocalKey, ModelContext) throws -> [LocalEpisodeState],
        persist: (ModelContext) throws -> Void
    ) throws {
        guard let episode else {
            resolveWaiters(for: DownloadTransferKey.identityKey(from: taskKey), success: false)
            return
        }
        if let source = DownloadTransferKey.parse(taskKey).flatMap({ URL(string: $0.sourceURL) }),
           source != URL(string: episode.audioURL).map(SecureURL.preferredMediaHTTPS) {
            return
        }
        if episode.downloadStatus == .failed {
            if context.hasChanges { try persist(context) }
            resolveWaiters(for: DownloadTransferKey.identityKey(from: taskKey), success: false)
            return
        }
        // Don't clobber a state that already moved on (e.g. the user removed it).
        guard episode.downloadStatus == .downloading else { return }
        try LocalStateStore.setTerminalDownloadState(.failed, path: episode.downloadPath, on: episode,
                                                     in: context, fetchRows: fetchLocalRows)
        try persist(context)
        resolveWaiters(for: DownloadTransferKey.identityKey(from: taskKey), success: false)
        AppLog.networking.error("Download failed: \(episode.title, privacy: .public)")
    }

    /// The task keys (composite `"feedURL|guid"`, or bare guids from tasks
    /// enqueued by a pre-#576 build) of tasks the background session still has
    /// in flight.
    private static func liveTaskKeys() async -> Set<String>? {
        await liveTaskKeys(
            taskDescriptions: { await allTasks().compactMap(\.taskDescription) },
            pendingKeys: { delegate.pendingTaskKeys() }
        )
    }

    static func liveTaskKeys(
        taskDescriptions: () async -> [String], pendingKeys: () -> [String]?
    ) async -> Set<String>? {
        let descriptions = await taskDescriptions()
        // Read after URLSession enumeration: a task may have finished and been
        // journaled while getAllTasks was suspended.
        guard let pending = pendingKeys() else { return nil }
        var keys = Set<String>()
        for value in descriptions + pending {
            keys.insert(value)
            keys.insert(DownloadTransferKey.identityKey(from: value))
        }
        return keys
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
    struct BulkOwnership {
        /// Nil means the ownership fetch failed; keep files to avoid deleting
        /// audio that might still belong to another episode.
        let retainedFiles: Set<String>?
    }

    static func bulkOwnership(for episodes: [Episode], in context: ModelContext) -> BulkOwnership {
        let owners = Set(episodes.compactMap { LocalStateStore.key(for: $0) })
        return BulkOwnership(retainedFiles: try? DownloadPaths.referencedFileNames(excluding: owners, in: context))
    }

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
    /// ``ActiveDownload/setDownloadStatus(_:on:in:)``). Pending requests are removed
    /// and active transfers are cancelled. The caller saves the context immediately
    /// so late completion events cannot restore a removed download.
    static func removeDownloadFileAndState(
        _ episode: Episode, in context: ModelContext, ownership: BulkOwnership? = nil
    ) {
        guard episode.downloadStatus != .none || episode.downloadPath != nil else { return }
        if episode.downloadStatus == .downloading {
            DownloadManager.cancelDownload(identityKey: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL, guid: episode.guid
            ))
        }
        if let ownership {
            if let retainedFiles = ownership.retainedFiles,
               let name = DownloadPaths.storedFileName(episode.downloadPath),
               !retainedFiles.contains(name) {
                try? DownloadPaths.removeFile(named: name)
            }
        } else {
            try? DownloadPaths.removeIfUnshared(storedValue: episode.downloadPath, for: episode, in: context)
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
