import Foundation
import SwiftData

/// Imports an OPML document: subscribes to each feed and recreates folder groups
/// (nested outlines) as ``PodcastFolder``s with memberships. Already-subscribed
/// feeds are reused (subscribe is idempotent). Returns the number of feeds
/// successfully imported.
@MainActor
final class OPMLImportService {
    private let context: ModelContext
    private let subscriptions: SubscriptionRepository

    init(context: ModelContext) {
        self.context = context
        self.subscriptions = SubscriptionRepository(context: context)
    }

    /// Test seam: inject a pre-built ``SubscriptionRepository`` (e.g. one with an
    /// `onMerge` spy) so tests can assert the bulk path reconciles the main context
    /// ONCE per import. The `context` is still used for folder/membership writes.
    init(context: ModelContext, subscriptions: SubscriptionRepository) {
        self.context = context
        self.subscriptions = subscriptions
    }

    /// Imports an OPML document. Subscribes to ALL feeds in one bulk pass on the
    /// background actor (reconciling the main context ONCE, not per feed), then
    /// creates folders + memberships on the main context for the resolved podcasts,
    /// and finally runs auto-download once at the end. Returns the number of feeds
    /// successfully imported.
    ///
    /// The per-feed `subscribe()` loop this replaced merged the entire Podcast +
    /// Episode tables on the main context once per feed; with the Library tab
    /// visible, the `@Query`-driven list and its VoiceOver tree rebuilt on every one
    /// of those merges, starving VoiceOver during a large import (#440). The bulk
    /// path does the heavy work off the main actor and merges once.
    ///
    /// `onResolveTotal` fires once on the main actor with the de-duplicated feed
    /// count BEFORE any network work, so the progress screen (and its on-appear
    /// "Importing N podcasts" announcement) sees the real total instead of a 0
    /// placeholder. It's the single source of truth for the count the user hears —
    /// driven off the same `orderedURLs` the import actually processes, so it can't
    /// drift from a raw, un-deduped parse.
    ///
    /// `onProgress` fires on the main actor after each feed with `(completed, total,
    /// currentTitle)`. It is intentionally lightweight (two ints + an optional
    /// String) so it can't reintroduce a per-feed main-thread stall. Existing call
    /// sites pass `nil` (no behavior change) until the progress UI wires it up.
    @discardableResult
    func importOPML(
        _ opml: String,
        onResolveTotal: (@MainActor @Sendable (_ total: Int) -> Void)? = nil,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int, _ currentTitle: String?) -> Void)? = nil
    ) async -> Int {
        let groups = OPMLDocument.groups(from: opml)

        // Flatten to an ordered list of feed URLs and a trimmed-URL -> folder-name
        // map. A URL keeps its FIRST folder if it somehow appears twice (mirrors the
        // old loop, which created the membership on first encounter).
        var orderedURLs: [String] = []
        var folderForURL: [String: String] = [:]
        for group in groups {
            for feedURL in group.feedURLs {
                let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !orderedURLs.contains(trimmed) { orderedURLs.append(trimmed) }
                if let folderName = group.folder, folderForURL[trimmed] == nil {
                    folderForURL[trimmed] = folderName
                }
            }
        }
        guard !orderedURLs.isEmpty else { return 0 }

        // Report the resolved (de-duped) total up front so the progress screen
        // presents with the correct count and its on-appear announcement speaks the
        // real number, not the 0 placeholder `start()` was seeded with.
        await onResolveTotal?(orderedURLs.count)

        // One bulk subscribe pass: fetch/parse/insert/save off the main actor,
        // reconcile the main context ONCE afterward.
        let outcomes = await subscriptions.subscribeAll(feedURLs: orderedURLs, onProgress: onProgress)

        // Create folders + memberships on the main context from the resolved
        // main-context podcasts. findOrCreateFolder/addMembership are unchanged.
        for outcome in outcomes {
            guard let folderName = folderForURL[outcome.feedURL] else { continue }
            let folder = findOrCreateFolder(named: folderName)
            addMembership(outcome.podcast, to: folder)
        }
        save()

        // Auto-download once at the end (no-op unless a downloader was injected,
        // which preserves the OPML path's existing behavior).
        await subscriptions.autoDownloadRecent(episodeIDsPerPodcast: outcomes.map(\.episodeIDs))

        return outcomes.count
    }

    private func findOrCreateFolder(named name: String) -> PodcastFolder {
        let existing = (try? context.fetch(FetchDescriptor<PodcastFolder>()))?
            .first { $0.name == name }
        if let existing { return existing }
        let folder = PodcastFolder(name: name)
        context.insert(folder)
        return folder
    }

    private func addMembership(_ podcast: Podcast, to folder: PodcastFolder) {
        let already = (try? context.fetch(FetchDescriptor<FolderMembership>()))?
            .contains { $0.folder == folder && $0.podcast == podcast } ?? false
        guard !already else { return }
        context.insert(FolderMembership(folder: folder, podcast: podcast))
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.subscriptions.error("OPML import save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
