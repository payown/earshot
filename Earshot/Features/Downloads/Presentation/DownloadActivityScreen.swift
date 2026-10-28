import Observation
import SwiftData
import SwiftUI

/// Only device-local download metadata is observed. Episode titles are resolved
/// for the displayed page, never by loading the subscriber's entire library.
struct DownloadActivityRecord: Identifiable, Equatable, Sendable {
    let id: EpisodeLocalKey
    let status: DownloadStatus

    static func records(from rows: [LocalEpisodeState]) -> [Self] {
        var seen: Set<EpisodeLocalKey> = []
        return rows.compactMap { row in
            let key = EpisodeLocalKey(feedURL: row.podcastFeedURL, guid: row.episodeGUID)
            guard row.downloadStatus != .none, seen.insert(key).inserted else { return nil }
            // Match Downloads: a completed status without a destination cannot
            // count as offline audio. Launch reconciliation repairs stale files.
            guard row.downloadStatus != .downloaded || !(row.downloadPath?.isEmpty ?? true) else { return nil }
            return Self(id: key, status: row.downloadStatus)
        }
    }
}

struct DownloadActivitySummary: Equatable, Sendable {
    var downloading = 0
    var waiting = 0
    var failed = 0
    var completed = 0

    init(records: [DownloadActivityRecord]) {
        for record in records {
            switch record.status {
            case .downloading: downloading += 1
            case .pending: waiting += 1
            case .failed: failed += 1
            case .downloaded: completed += 1
            case .none: break
            }
        }
    }

    var text: String {
        "Downloading \(downloading), waiting for Wi-Fi \(waiting), failed \(failed), downloaded \(completed)."
    }
}

/// All SwiftData models stay in this fresh worker context. The screen receives
/// only values, so opening or refreshing Activity never fetches its library on
/// the main actor. A cancelled or superseded request cannot publish a result.
struct DownloadActivityEntry: Identifiable, Equatable, Sendable {
    let id: EpisodeLocalKey
    let title: String
    let podcast: String
    let status: DownloadStatus
}

struct DownloadActivitySnapshot: Equatable, Sendable {
    let summary: DownloadActivitySummary
    let entries: [DownloadActivityEntry]
    let failedKeys: [EpisodeLocalKey]
    let visibleCount: Int
    let executedStoreWorkOnMainThread: Bool
}

enum DownloadActivitySnapshotLoader {
    @concurrent
    static func load(
        container: ModelContainer, showCompleted: Bool, limit: Int,
        podcastNames: [String: String]
    ) async throws -> DownloadActivitySnapshot {
        try loadSynchronously(container: container, showCompleted: showCompleted,
                              limit: limit, podcastNames: podcastNames)
    }

    private static func loadSynchronously(
        container: ModelContainer, showCompleted: Bool, limit: Int,
        podcastNames: [String: String]
    ) throws -> DownloadActivitySnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let onMain = Thread.isMainThread
        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { $0.downloadStatusRaw != "none" },
            sortBy: [SortDescriptor(\LocalEpisodeState.podcastFeedURL),
                     SortDescriptor(\LocalEpisodeState.episodeGUID)]
        ))
        var seen: Set<EpisodeLocalKey> = []
        var records: [DownloadActivityRecord] = []
        for row in rows {
            try Task.checkCancellation()
            let key = EpisodeLocalKey(feedURL: row.podcastFeedURL, guid: row.episodeGUID)
            let status = row.downloadStatus
            guard status != .none, seen.insert(key).inserted else { continue }
            guard status != .downloaded || !(row.downloadPath?.isEmpty ?? true) else { continue }
            records.append(DownloadActivityRecord(id: key, status: status))
        }
        let summary = DownloadActivitySummary(records: records)
        let failed = Array(records.lazy.filter { $0.status == .failed }
            .prefix(ManualDownloadBatchPlan.maximumEpisodeCount).map(\.id))
        let visible = records.filter { showCompleted || $0.status != .downloaded }
        let page = Array(visible.prefix(limit))
        try Task.checkCancellation()
        let matches = try LocalStateStore.episodes(matching: page.map(\.id), in: context)
        let entries = page.compactMap { record -> DownloadActivityEntry? in
            guard let episode = matches[record.id] else { return nil }
            let podcast = episode.podcast
            let name: String
            if let podcast {
                name = podcast.isFollowed ? (podcastNames[record.id.feedURL] ?? podcast.title) : podcast.title
            } else {
                name = "Podcast"
            }
            return DownloadActivityEntry(id: record.id, title: episode.title,
                                         podcast: name, status: record.status)
        }
        try Task.checkCancellation()
        return DownloadActivitySnapshot(summary: summary, entries: entries, failedKeys: failed,
                                        visibleCount: visible.count,
                                        executedStoreWorkOnMainThread: onMain || Thread.isMainThread)
    }

    /// Ignore unrelated saves, especially frequent playback-position writes.
    static func downloadsChanged(_ notification: Notification) -> Bool {
        AppIconBadgeCount.downloadsChanged(notification)
    }
}

@MainActor
@Observable
final class DownloadActivityLoadController {
    typealias Load = @Sendable (ModelContainer, Bool, Int, [String: String]) async throws -> DownloadActivitySnapshot
    private(set) var snapshot: DownloadActivitySnapshot?
    private(set) var loadError: String?
    private struct Request {
        let container: ModelContainer
        let showCompleted: Bool
        let limit: Int
        let names: [String: String]
    }
    @ObservationIgnored private let load: Load
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var latestRequest: Request?
    @ObservationIgnored private var dirty = false

    init(load: @escaping Load = { container, completed, limit, names in
        try await DownloadActivitySnapshotLoader.load(container: container, showCompleted: completed,
                                                      limit: limit, podcastNames: names)
    }) {
        self.load = load
    }

    func schedule(container: ModelContainer, showCompleted: Bool, limit: Int,
                  names: [String: String], immediate: Bool = false) {
        latestRequest = Request(container: container, showCompleted: showCompleted,
                                limit: limit, names: names)
        if !immediate, task != nil {
            // Complete the current read even during a continuous stream of
            // saves, then read once more with the latest request.
            dirty = true
            return
        }
        generation += 1
        let requested = generation
        task?.cancel()
        dirty = false
        task = Task { @MainActor in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            while generation == requested, let request = latestRequest {
                dirty = false
                do {
                    let result = try await load(request.container, request.showCompleted,
                                                request.limit, request.names)
                    try Task.checkCancellation()
                    guard generation == requested else { return }
                    snapshot = result
                    loadError = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == requested else { return }
                    // Stale retry buttons must not remain actionable after a
                    // failed read. Keep the existing error wording.
                    snapshot = nil
                    loadError = "Could not load download details. Reopen Download activity to try again."
                }
                guard generation == requested else { return }
                if !dirty {
                    task = nil
                    return
                }
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        latestRequest = nil
        dirty = false
    }

    func waitUntilIdle() async { await task?.value }
    func currentTaskForTesting() -> Task<Void, Never>? { task }
}

struct DownloadActivityScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCompleted = false
    @State private var limit = 50
    @State private var loader = DownloadActivityLoadController()
    @State private var retryRequest: [EpisodeLocalKey]?
    @State private var isRetrying = false

    var body: some View {
        let snapshot = loader.snapshot
        List {
            Section("Status across all podcasts") {
                Text("This screen tracks episode audio downloads. To retry a failed check for new episodes, open Settings, Feed Refresh.")
                if let snapshot {
                    Text(snapshot.summary.text)
                        .accessibilityIdentifier("downloadActivitySummary")
                }
                Toggle("Include completed downloads", isOn: $showCompleted)
                Button("Retry failed downloads") {
                    retryRequest = snapshot?.failedKeys
                }
                .disabled(snapshot == nil || snapshot?.summary.failed == 0 || isRetrying)
            }
            Section {
                if let loadError = loader.loadError {
                    Text(loadError)
                } else if let snapshot, snapshot.visibleCount == 0 {
                    Text(showCompleted ? "No download requests." : "No waiting, downloading, or failed episodes.")
                }
                ForEach(snapshot?.entries ?? []) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title).font(.headline)
                        Text(entry.podcast).font(.subheadline)
                        Text(EpisodeRowLabel.spokenDownloadState(entry.status))
                        Button("Retry download") { retry([entry.id]) }
                            .disabled(entry.status != .failed || isRetrying)
                            .accessibilityLabel("Retry download for \(entry.title)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("downloadActivityEpisode")
                }
                if let snapshot, snapshot.visibleCount > limit {
                    Button("Show more download requests") { limit += 50 }
                }
            } header: {
                Text("Download requests")
            } footer: {
                Text("Status updates here without interrupting speech. Downloading means a transfer has been requested from iOS; it may still be connecting. Failed episodes remain available to retry. Completed files are also in Downloads.")
            }
            Section {
                NavigationLink("Inbox, Queue, and Downloads guide") { ListeningWorkflowGuide() }
            }
        }
        .navigationTitle("Download activity")
        .onAppear { scheduleLoad(immediate: true) }
        .onDisappear { loader.cancel() }
        .onChange(of: showCompleted) { _, _ in scheduleLoad(immediate: true) }
        .onChange(of: limit) { _, _ in scheduleLoad(immediate: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scheduleLoad() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)) { notification in
            if DownloadActivitySnapshotLoader.downloadsChanged(notification) { scheduleLoad() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .earshotSubscriptionsDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .earshotCloudProjectionDidApply))
            .merge(with: NotificationCenter.default.publisher(for: .earshotInboxDidChange))
            .merge(with: NotificationCenter.default.publisher(for: .earshotPodcastNamesDidChange))
            .receive(on: DispatchQueue.main)) { _ in scheduleLoad() }
        .confirmationDialog("Retry failed downloads?", isPresented: Binding(
            get: { retryRequest != nil },
            set: { if !$0 { retryRequest = nil } }
        ), titleVisibility: .visible) {
            if let keys = retryRequest {
                Button("Retry \(keys.count) downloads") { retryRequest = nil; retry(keys) }
            }
            Button("Cancel", role: .cancel) { retryRequest = nil }
        } message: {
            Text("Retries up to 50 failed episodes across all podcasts. Wi-Fi-only still applies. Any additional failures remain available for another batch.")
        }
    }

    private func scheduleLoad(immediate: Bool = false) {
        loader.schedule(container: context.container, showCompleted: showCompleted, limit: limit,
                        names: PodcastDisplayNames.shared.names, immediate: immediate)
    }

    private func retry(_ keys: [EpisodeLocalKey]) {
        guard !isRetrying else { return }
        isRetrying = true
        Task { @MainActor in
            defer { isRetrying = false }
            do {
                let matches = try LocalStateStore.episodes(matching: keys, in: context)
                let episodes = keys.compactMap { matches[$0] }.filter { $0.downloadStatus == .failed }
                let report = await downloads.downloadAll(episodes)
                Announcer.announce(report.announcement)
            } catch {
                Announcer.announce("Could not retry downloads. Please try again.")
            }
        }
    }
}
