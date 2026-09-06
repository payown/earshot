import SwiftData
import SwiftUI

/// Only device-local download metadata is observed. Episode titles are resolved
/// for the displayed page, never by loading the subscriber's entire library.
struct DownloadActivityRecord: Identifiable, Equatable {
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

struct DownloadActivitySummary: Equatable {
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

struct DownloadActivityScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Query(
        filter: #Predicate<LocalEpisodeState> { $0.downloadStatusRaw != "none" },
        sort: [SortDescriptor(\LocalEpisodeState.podcastFeedURL), SortDescriptor(\LocalEpisodeState.episodeGUID)]
    ) private var rows: [LocalEpisodeState]
    @State private var showCompleted = false
    @State private var limit = 50
    @State private var entries: [Entry] = []
    @State private var loadError: String?
    @State private var retryRequest: [EpisodeLocalKey]?
    @State private var isRetrying = false

    private struct Entry: Identifiable {
        let id: EpisodeLocalKey
        let title: String
        let podcast: String
        let status: DownloadStatus
    }

    private struct Page: Equatable {
        let records: [DownloadActivityRecord]
    }

    var body: some View {
        let records = DownloadActivityRecord.records(from: rows)
        let summary = DownloadActivitySummary(records: records)
        let visible = records.filter { showCompleted || $0.status != .downloaded }
        let page = Page(records: Array(visible.prefix(limit)))
        List {
            Section("Status across all podcasts") {
                Text(summary.text)
                    .accessibilityIdentifier("downloadActivitySummary")
                Button("Read download status") { Announcer.announce(summary.text) }
                Toggle("Include completed downloads", isOn: $showCompleted)
                Button("Retry failed downloads") {
                    retryRequest = Array(records.filter { $0.status == .failed }
                        .prefix(ManualDownloadBatchPlan.maximumEpisodeCount).map(\.id))
                }
                .disabled(summary.failed == 0 || isRetrying)
            }
            Section {
                if let loadError {
                    Text(loadError)
                } else if visible.isEmpty {
                    Text(showCompleted ? "No download requests." : "No waiting, downloading, or failed episodes.")
                }
                ForEach(entries) { entry in
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
                if visible.count > limit {
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
        .task(id: page) { load(page) }
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

    private func load(_ page: Page) {
        do {
            let matches = try LocalStateStore.episodes(matching: page.records.map(\.id), in: context)
            entries = page.records.compactMap { record in
                guard let episode = matches[record.id] else { return nil }
                return Entry(id: record.id, title: episode.title,
                             podcast: episode.podcast?.displayName ?? "Podcast", status: record.status)
            }
            loadError = nil
        } catch {
            entries = []
            loadError = "Could not load download details. Reopen Download activity to try again."
        }
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
