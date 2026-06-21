import Foundation
import SwiftData

/// Background importer for the one-time Flutter→SwiftUI subscription migration.
///
/// `@ModelActor` gives this its own `ModelContext` on a background executor, so
/// the inserts happen off the main actor. It creates lightweight Podcast
/// "shells" — feed URL + display metadata read from the old database, with **no
/// episodes**. That is what makes the restore near-instant and keeps VoiceOver
/// responsive: importing every episode of 50+ feeds is what starved the main
/// actor. Episodes are filled afterward by a normal background refresh, which on
/// a freshly-migrated shell backfills the catalog pre-dismissed and seeds the
/// inbox high-water mark (see `SubscriptionRepository.refresh`).
@ModelActor
actor SubscriptionImporter {
    /// Creates a Podcast shell per subscription (deduped, skipping any already
    /// present), reporting `(completed, total)` on the main actor after each.
    /// No network, no episodes. Returns the count of shells created.
    func importShells(
        _ subscriptions: [FlutterSubscription],
        onProgress: @MainActor @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async -> Int {
        let total = subscriptions.count
        var imported = 0
        var handled = Set<String>()

        for (index, sub) in subscriptions.enumerated() {
            let url = sub.rssURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, !handled.contains(url), !alreadySubscribed(url) {
                handled.insert(url)
                insertShell(sub, feedURL: url)
                imported += 1
            }
            await onProgress(index + 1, total)
        }
        if modelContext.hasChanges {
            try? modelContext.save()
        }
        AppLog.data.info("Migration: created \(imported, privacy: .public) of \(total, privacy: .public) show shell(s)")
        return imported
    }

    private func alreadySubscribed(_ url: String) -> Bool {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == url })
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor))?.first) != nil
    }

    /// A Podcast shell: metadata only, no episodes. `lastSeenPubDate` and
    /// `refreshedAt` are left nil so the first refresh backfills the catalog
    /// (pre-dismissed) and seeds the inbox high-water mark.
    private func insertShell(_ sub: FlutterSubscription, feedURL: String) {
        let podcast = Podcast(
            feedURL: feedURL,
            title: sub.title ?? "Untitled podcast",
            author: sub.author,
            artworkURL: sub.artworkURL
        )
        modelContext.insert(podcast)
    }
}
