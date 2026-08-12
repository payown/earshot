import Foundation
import SwiftData

extension Notification.Name {
    static let earshotBookmarksDidChange = Notification.Name("earshotBookmarksDidChange")
}

/// SwiftData-backed bookmark store: add a saved position (with an optional note)
/// to an episode, list an episode's bookmarks in position order, and delete one.
/// Mirrors the Flutter `BookmarkRepositoryImpl`.
@MainActor
final class BookmarkRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// An episode's bookmarks, earliest position first.
    func bookmarks(for episode: Episode) -> [Bookmark] {
        (episode.bookmarks ?? []).sorted { $0.positionSeconds < $1.positionSeconds }
    }

    /// Adds a bookmark at `positionSeconds` (clamped to >= 0). The note is
    /// trimmed; an empty note is allowed (the UI shows a default label).
    @discardableResult
    func add(to episode: Episode, positionSeconds: Int, note: String = "") -> Bookmark {
        let bookmark = Bookmark(
            episode: episode,
            positionSeconds: max(0, positionSeconds),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(bookmark)
        save()
        AppLog.player.info("Bookmark added at \(bookmark.positionSeconds)s on \(episode.title, privacy: .public)")
        return bookmark
    }

    func delete(_ bookmark: Bookmark) {
        context.delete(bookmark)
        save()
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            NotificationCenter.default.post(name: .earshotBookmarksDidChange, object: nil)
        } catch {
            AppLog.data.error("Bookmark save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
