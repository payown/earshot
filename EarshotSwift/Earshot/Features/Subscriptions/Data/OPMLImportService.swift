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

    @discardableResult
    func importOPML(_ opml: String) async -> Int {
        var imported = 0
        for group in OPMLDocument.groups(from: opml) {
            let folder = group.folder.map { findOrCreateFolder(named: $0) }
            for feedURL in group.feedURLs {
                do {
                    let podcast = try await subscriptions.subscribe(feedURL: feedURL)
                    imported += 1
                    if let folder { addMembership(podcast, to: folder) }
                } catch {
                    AppLog.subscriptions.error("OPML import: failed \(feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        save()
        return imported
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
