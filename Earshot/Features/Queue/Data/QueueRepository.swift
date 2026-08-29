import Foundation
import SwiftData

extension Notification.Name {
    /// Posted after any queue mutation persists, so the player can invalidate /
    /// refresh its gapless preload without the queue and player features being
    /// directly coupled.
    static let earshotQueueDidChange = Notification.Name("earshotQueueDidChange")
}

/// A section of the grouped Queue view: a run of episodes sharing a group key,
/// whether that key is a podcast ("Group by podcast", #444) or a top-level
/// folder ("Group by folder", #762). Generalized from the original
/// podcast-only shape so the group header + rotor render identically for both
/// modes — only the ``title`` (and the actions' backing key) differ.
struct QueueGroup: Identifiable {
    /// What a group represents, and its stable identity for `ForEach` and
    /// `@AccessibilityFocusState`. A podcast group carries the podcast's id, a
    /// folder group its top-level folder's id, and the catch-all group for
    /// podcasts in no folder a single shared ``unfiled`` case.
    enum Kind: Hashable {
        case podcast(PersistentIdentifier)
        case folder(PersistentIdentifier)
        case unfiled
    }

    let kind: Kind
    /// The spoken + visible group name: the podcast title, the folder name, or
    /// "Unfiled".
    let title: String
    let episodes: [Episode]
    /// The backing podcast for a ``Kind/podcast`` group, used by the podcast
    /// group actions (Play group, Move group, Sort, Shuffle). Nil for folder and
    /// Unfiled groups, which drive the identical actions through their group key.
    let podcast: Podcast?

    var id: Kind { kind }

    /// Only a real folder group creates Playing-from-folder context. Podcast and
    /// Unfiled groups are ordinary Queue sources and therefore clear any prior
    /// origin when their Play Group action starts an episode.
    var playbackOrigin: PlaybackOrigin? {
        switch kind {
        case let .folder(folderID): return .folder(folderID)
        case .podcast, .unfiled: return nil
        }
    }

    /// The folder-grouping key for `episode` given a subtree-aware map of each
    /// podcast to the top-level folder whose subtree contains it. A podcast in no
    /// folder — or an episode with no podcast — buckets into ``Kind/unfiled``.
    static func folderKind(
        for episode: Episode?,
        rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Kind {
        guard let pid = episode?.podcast?.persistentModelID,
              let rootID = rootByPodcast[pid] else { return .unfiled }
        return .folder(rootID)
    }
}

/// The result of grouping the queue by folder: the display groups plus the
/// subtree-aware podcast→folder map that produced them (#762). The map is
/// carried so the Queue's folder group actions and folder drag-reorder can
/// re-derive an episode's group key WITHOUT rebuilding it — the bucketing pays
/// its folder-structure cost once, not once per action.
struct QueueFolderGrouping {
    let groups: [QueueGroup]
    let rootByPodcast: [PersistentIdentifier: PersistentIdentifier]

    func key(for episode: Episode?) -> QueueGroup.Kind {
        QueueGroup.folderKind(for: episode, rootByPodcast: rootByPodcast)
    }
}

/// SwiftData-backed play queue. One ``QueueItem`` per episode (idempotent
/// enqueue). Ordering is kept dense — positions are recompacted to `0..<N` after
/// every mutation, mirroring the Flutter drift queue — so callers and
/// ``QueueLogic`` never reason about the raw position integers.
@MainActor
final class QueueRepository {
    /// Freshness window used when a podcast has no explicit queue age limit.
    static let autoQueueOptInDefaultAgeLimitDays = 7

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Reads

    /// The queue in play order.
    func queue() -> [Episode] {
        orderedItems().compactMap(\.episode)
    }

    /// The number of episodes the queue shows: raw rows backing a real episode.
    /// Orphan rows (`episode == nil`, only possible from corrupt/aged data) are
    /// excluded so this equals what ``orderedItems()``/``queue()`` render and what
    /// `QueueScreen` displays. Pure and static so the RootView tab-count badge can
    /// be unit-tested without a tab bar (mirrors `InboxRepository.inbox(from:)`).
    static func displayedCount(from items: [QueueItem]) -> Int {
        items.reduce(0) { $0 + ($1.episode == nil ? 0 : 1) }
    }

    /// The queue grouped by podcast, groups in first-appearance order, episodes
    /// in queue order within each group. Episodes with no podcast are omitted
    /// from groups (they still appear in ``queue()``).
    func groupedQueue() -> [QueueGroup] {
        let episodes = queue()
        let byID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.persistentModelID, $0) })
        let items: [(id: PersistentIdentifier, key: PersistentIdentifier)] = episodes.compactMap {
            guard let podcast = $0.podcast else { return nil }
            return ($0.persistentModelID, podcast.persistentModelID)
        }
        return QueueLogic.group(items).compactMap { group in
            let eps = group.ids.compactMap { byID[$0] }
            guard let podcast = eps.first?.podcast else { return nil }
            return QueueGroup(
                kind: .podcast(podcast.persistentModelID),
                title: podcast.title,
                episodes: eps,
                podcast: podcast
            )
        }
    }

    /// The queue grouped by top-level folder, subtree-aware (#762). Groups appear
    /// in first-appearance order; episodes keep queue order within a group even
    /// when the flat queue interleaves folders. A podcast filed anywhere in a
    /// folder's subtree buckets under that top-level folder; a podcast in no
    /// folder — or an episode with no podcast — buckets into a single "Unfiled"
    /// group (always present when any such episode is queued).
    ///
    /// Bucketing is done ONCE: the podcast→folder map is built up front from the
    /// folder structure — cost scales with folders + memberships, not with queue
    /// length — then each episode is an O(1) lookup, never an O(queue × folders)
    /// walk (performance.md). The returned ``QueueFolderGrouping`` carries that
    /// map so folder group actions reuse it.
    func groupedQueueByFolder() -> QueueFolderGrouping {
        let episodes = queue()
        let byID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.persistentModelID, $0) })
        let folderRepo = FolderRepository(context: context)
        let rootByPodcast = folderRepo.rootFolderByPodcast()
        let namesByFolder = Dictionary(
            uniqueKeysWithValues: folderRepo.folders().map { ($0.persistentModelID, $0.name) }
        )

        let items: [(id: PersistentIdentifier, key: QueueGroup.Kind)] = episodes.map {
            ($0.persistentModelID, QueueGroup.folderKind(for: $0, rootByPodcast: rootByPodcast))
        }
        let groups = QueueLogic.group(items).map { group -> QueueGroup in
            let eps = group.ids.compactMap { byID[$0] }
            switch group.key {
            case let .folder(folderID):
                return QueueGroup(
                    kind: .folder(folderID),
                    title: namesByFolder[folderID] ?? "Folder",
                    episodes: eps,
                    podcast: nil
                )
            case .unfiled:
                return QueueGroup(kind: .unfiled, title: "Unfiled", episodes: eps, podcast: nil)
            case .podcast:
                // Never produced by `folderKind`; present only for exhaustiveness.
                return QueueGroup(kind: group.key, title: eps.first?.podcast?.title ?? "", episodes: eps, podcast: eps.first?.podcast)
            }
        }
        return QueueFolderGrouping(groups: groups, rootByPodcast: rootByPodcast)
    }

    // MARK: Adding (status -> inQueue)

    /// Applies an auto-queue setting change. A false -> true transition may add
    /// exactly the podcast's newest existing episode so an active show takes
    /// effect immediately; every other transition only updates the setting.
    ///
    /// The latest episode must be dated, non-future, inside the podcast's queue
    /// age limit (or the seven-day default), and still genuinely untriaged. A
    /// played, dismissed, previously expired/skipped, or already-queued latest
    /// episode blocks enrollment rather than falling back into deeper backlog.
    @discardableResult
    func setAutoQueue(_ enabled: Bool, for podcast: Podcast, now: Date = .now) -> Bool {
        let wasEnabled = podcast.autoQueue
        podcast.autoQueue = enabled
        guard enabled, !wasEnabled else { return false }

        let podcastID = podcast.persistentModelID
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.persistentModelID == podcastID },
            sortBy: [
                SortDescriptor(\.pubDate, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse),
            ]
        )
        descriptor.fetchLimit = 1

        guard let episode = (try? context.fetch(descriptor))?.first,
              let pubDate = episode.pubDate,
              pubDate <= now
        else { return false }

        let ageLimitDays = max(
            0,
            podcast.queueAgeLimitDays ?? Self.autoQueueOptInDefaultAgeLimitDays
        )
        let cutoff = now.addingTimeInterval(-Double(ageLimitDays) * 86_400)
        guard pubDate >= cutoff,
              episode.status == .newEpisode,
              !episode.inboxDismissed,
              episode.recentlyExpired == nil,
              episode.queueItem == nil
        else { return false }

        // Match refresh-time auto-queue: once enrolled, the episode must not
        // resurface in Inbox if it later leaves the queue.
        episode.inboxDismissed = true
        add(episode)
        return true
    }

    /// Appends `episode` to the end. Idempotent: an already-queued episode is
    /// left untouched.
    func add(_ episode: Episode) {
        guard episode.queueItem == nil else { return }
        var items = orderedItems()
        items.append(enqueue(episode))
        compact(items)
    }

    /// Appends `episodes` to the end in the given order, in a single fetch +
    /// compact rather than one per episode (backs Inbox multi-select bulk add,
    /// #595). Idempotent per-episode: any already queued is left untouched,
    /// same as adding one at a time.
    func add(_ episodes: [Episode]) {
        var items = orderedItems()
        for episode in episodes where episode.queueItem == nil {
            items.append(enqueue(episode))
        }
        compact(items)
    }

    /// Enqueues any missing episodes, then moves the supplied ordered subset to
    /// the front while every other queued episode keeps its relative order.
    /// Used by the reusable morning lineup; duplicates in `episodes` are ignored.
    func bringToFront(_ episodes: [Episode]) {
        var items = orderedItems()
        var itemByEpisodeID: [PersistentIdentifier: QueueItem] = [:]
        for item in items {
            if let episodeID = item.episode?.persistentModelID {
                itemByEpisodeID[episodeID] = item
            }
        }

        var frontItemIDs: [PersistentIdentifier] = []
        var seen = Set<PersistentIdentifier>()
        for episode in episodes where seen.insert(episode.persistentModelID).inserted {
            let item: QueueItem
            if let existing = itemByEpisodeID[episode.persistentModelID] {
                item = existing
            } else {
                item = enqueue(episode)
                items.append(item)
                itemByEpisodeID[episode.persistentModelID] = item
            }
            frontItemIDs.append(item.persistentModelID)
        }

        let order = QueueLogic.bringToFront(items.map(\.persistentModelID), frontItemIDs)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        compact(order.compactMap { byID[$0] })
    }

    /// Inserts `episode` so it plays immediately after `current`. If `current`
    /// is in the queue, inserts right after it; otherwise inserts at the front,
    /// so auto-advance still picks it next. Moves an already-queued episode.
    /// Backs "Play Next".
    func playNext(_ episode: Episode, after current: Episode?) {
        var items = orderedItems()
        let item: QueueItem
        if let existing = episode.queueItem {
            item = existing
            items.removeAll { $0.persistentModelID == existing.persistentModelID }
        } else {
            item = enqueue(episode)
        }
        let insertIndex: Int
        if let currentID = current?.queueItem?.persistentModelID,
           let idx = items.firstIndex(where: { $0.persistentModelID == currentID }) {
            insertIndex = idx + 1
        } else {
            insertIndex = 0
        }
        items.insert(item, at: min(insertIndex, items.count))
        compact(items)
    }

    // MARK: Removing

    /// User-initiated removal: reverts the episode to `newEpisode` but dismisses
    /// it from the inbox durably (#614), matching the pattern already used by
    /// ``InboxRepository/clearInbox()`` and the per-podcast age/count auto-dismiss
    /// -- removing from the queue is a deliberate choice not to listen to it right
    /// now, not a request to see it resurface as "new" again. Deliberately does
    /// NOT mark the episode played: `isPlayed`/`playedAt` (and therefore the
    /// "Episodes completed" listening stat) stay untouched, since the user may
    /// not have listened to any of it. Use ``markPlayedAndRemove(_:)`` instead
    /// when the episode genuinely finished playing.
    @discardableResult
    func cancelFromQueue(_ episode: Episode) -> Bool {
        remove(episode) {
            $0.status = .newEpisode
            $0.inboxDismissed = true
            // Reuse the existing opt-in download cleanup rule. A deliberate
            // queue removal means the listener is done with this episode just
            // as surely as marking it played, but it still must not count as a
            // completed listen.
            DownloadCleanup.removeDownloadAfterPlayedIfEnabled($0, in: self.context)
        }
    }

    /// Completion-driven removal: marks the episode played atomically.
    /// Intentionally does NOT reset `positionSeconds` — position-zeroing is owned
    /// elsewhere, so a spurious completion can't destroy a saved place.
    @discardableResult
    func markPlayedAndRemove(_ episode: Episode) -> Bool {
        // Also dismiss from the inbox: an episode played to completion should
        // leave the inbox durably, matching the mark-played Quick Action and
        // swipe (#546). `inboxDismissed` stays set even if later marked unplayed.
        let queuedEpisode = orderedItems().compactMap(\.episode).first {
            $0.persistentModelID == episode.persistentModelID
        }
        let episodeToMark = queuedEpisode ?? episode
        let mutate: (Episode) -> Void = {
            $0.isPlayed = true
            $0.inboxDismissed = true
            // Auto-delete the download once played, when the user opted in. In
            // the same save as the played flip so the file and state clear atomically.
            DownloadCleanup.removeDownloadAfterPlayedIfEnabled($0, in: self.context)
        }
        let saved: Bool
        if queuedEpisode != nil {
            saved = remove(episodeToMark, mutate)
        } else {
            // Restored playback and jump-to-bookmark intentionally do not queue
            // the episode. Marking played is still a valid episode mutation; only
            // queue removal is conditional.
            mutate(episodeToMark)
            saved = save(notifyQueueChange: false)
        }
        guard saved else { return false }
        postEpisodeUserStateChanges([episodeToMark], playedChangedExplicitly: true)
        return true
    }

    /// Empties the queue, reverting every episode to `newEpisode` while keeping
    /// it dismissed from the inbox, matching ``cancelFromQueue(_:)``.
    ///
    /// Reverts through `isPlayed = false` rather than a raw `status = .newEpisode`
    /// so `playedAt` is cleared alongside `status`, preserving the invariant that
    /// a `.newEpisode` episode is unplayed. This matters now that the inbox badge
    /// and list fetch unplayed episodes only (`InboxQuery.normalUnplayed`): a
    /// played-then-queued episode resurfaced here with a stale `playedAt` would be
    /// silently dropped from the inbox count. For an already-unplayed episode this
    /// is equivalent to the old assignment.
    func clear() {
        let items = orderedItems()
        let episodes = items.compactMap(\.episode)
        let shouldDeleteDownloads = DownloadCleanup.deleteAfterPlayedEnabled(context)
        for item in items {
            if let episode = item.episode {
                episode.isPlayed = false
                episode.inboxDismissed = true
                if shouldDeleteDownloads {
                    DownloadCleanup.removeDownloadFileAndState(episode, in: context)
                }
            }
            context.delete(item)
        }
        save()
        postEpisodeUserStateChanges(episodes, playedChangedExplicitly: true)
    }

    // MARK: Moves

    /// Each move returns whether the order actually changed, so callers only
    /// announce / restore VoiceOver focus when something moved (an edge no-op
    /// must not announce "Moved … up").
    @discardableResult
    func moveToTop(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveToTop($0, $1) } }
    @discardableResult
    func moveToBottom(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveToBottom($0, $1) } }
    @discardableResult
    func moveUp(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveUp($0, $1) } }
    @discardableResult
    func moveDown(_ episode: Episode) -> Bool { reorder(episode) { QueueLogic.moveDown($0, $1) } }

    /// Drag-reorder `episode` to `toIndex`.
    @discardableResult
    func move(_ episode: Episode, toIndex: Int) -> Bool {
        reorder(episode) { QueueLogic.move($0, $1, toIndex: toIndex) }
    }

    /// Swaps `episode` with the previous episode in the same podcast group,
    /// leaving every other group untouched. Backs grouped-mode "Move up". No-op
    /// (returns false) when it's already first in its group.
    @discardableResult
    func moveUpWithinGroup(_ episode: Episode) -> Bool {
        reorderWithinGroup(episode, keyedBy: podcastKey) { QueueLogic.moveUpWithinGroup($0, id: $1) }
    }

    /// Swaps `episode` with the next episode in the same podcast group, leaving
    /// every other group untouched. Backs grouped-mode "Move down". No-op
    /// (returns false) when it's already last in its group.
    @discardableResult
    func moveDownWithinGroup(_ episode: Episode) -> Bool {
        reorderWithinGroup(episode, keyedBy: podcastKey) { QueueLogic.moveDownWithinGroup($0, id: $1) }
    }

    /// Folder-grouped analogue of ``moveUpWithinGroup(_:)`` (#762): swaps
    /// `episode` with the previous episode in the SAME folder group (which may be
    /// a different podcast), leaving every other folder group untouched. `rootByPodcast`
    /// is the subtree-aware map from ``QueueFolderGrouping``. No-op when already
    /// first in its folder group.
    @discardableResult
    func moveUpWithinFolderGroup(
        _ episode: Episode, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Bool {
        reorderWithinGroup(episode, keyedBy: folderKey(rootByPodcast)) { QueueLogic.moveUpWithinGroup($0, id: $1) }
    }

    /// Folder-grouped analogue of ``moveDownWithinGroup(_:)`` (#762). See
    /// ``moveUpWithinFolderGroup(_:rootByPodcast:)``. No-op when already last in
    /// its folder group.
    @discardableResult
    func moveDownWithinFolderGroup(
        _ episode: Episode, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Bool {
        reorderWithinGroup(episode, keyedBy: folderKey(rootByPodcast)) { QueueLogic.moveDownWithinGroup($0, id: $1) }
    }

    // MARK: Group actions (#445)

    /// Brings a podcast's queued episodes to the front in their current order
    /// ("Play group"), so auto-advance stays within the group. Returns the
    /// episode now at the front of the group for the caller to start playing.
    @discardableResult
    func playGroup(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(matching: memberOf(podcast), order: identityOrder)
    }

    /// Reorders the group's episodes newest-first by publish date, then brings
    /// the group to the front. Other groups keep their relative order. Returns
    /// the (now front) newest episode for the caller to start playing.
    @discardableResult
    func playNewestFirst(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(matching: memberOf(podcast), order: dateOrder(newestFirst: true))
    }

    /// Reorders the group's episodes oldest-first by publish date, then brings
    /// the group to the front. Other groups keep their relative order. Returns
    /// the (now front) oldest episode for the caller to start playing.
    @discardableResult
    func playOldestFirst(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(matching: memberOf(podcast), order: dateOrder(newestFirst: false))
    }

    /// Shuffles the group's episodes, then brings the group to the front. Other
    /// groups keep their relative order. Returns the (now front) episode for the
    /// caller to start playing.
    @discardableResult
    func shuffleGroup(_ podcast: Podcast) -> Episode? {
        reorderGroupToFront(matching: memberOf(podcast), order: shuffleOrder)
    }

    // MARK: Folder group actions (#762)

    /// Folder-grouped analogue of ``playGroup(_:)``: brings the queued episodes
    /// whose podcasts fall in the folder group identified by `key` to the front
    /// in queue order. `rootByPodcast` is the subtree-aware map from
    /// ``QueueFolderGrouping``. Returns the front episode, or nil for an empty
    /// group. The identical group-header rotor drives this — "Play Group" simply
    /// plays whichever folder the header names.
    @discardableResult
    func playGroup(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Episode? {
        reorderGroupToFront(matching: memberOf(key, rootByPodcast: rootByPodcast), order: identityOrder)
    }

    /// Folder-grouped analogue of ``playNewestFirst(_:)`` (#762).
    @discardableResult
    func playNewestFirst(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Episode? {
        reorderGroupToFront(matching: memberOf(key, rootByPodcast: rootByPodcast), order: dateOrder(newestFirst: true))
    }

    /// Folder-grouped analogue of ``playOldestFirst(_:)`` (#762).
    @discardableResult
    func playOldestFirst(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Episode? {
        reorderGroupToFront(matching: memberOf(key, rootByPodcast: rootByPodcast), order: dateOrder(newestFirst: false))
    }

    /// Folder-grouped analogue of ``shuffleGroup(_:)`` (#762).
    @discardableResult
    func shuffleGroup(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Episode? {
        reorderGroupToFront(matching: memberOf(key, rootByPodcast: rootByPodcast), order: shuffleOrder)
    }

    // MARK: Group-action ordering + membership helpers

    /// Group episodes brought to the front in their current queue order.
    private func identityOrder(_ groupItems: [QueueItem]) -> [PersistentIdentifier] {
        groupItems.map(\.persistentModelID)
    }

    /// Group episodes ordered by publish date (see ``QueueLogic/sortedByDate``).
    private func dateOrder(newestFirst: Bool) -> ([QueueItem]) -> [PersistentIdentifier] {
        { groupItems in
            QueueLogic.sortedByDate(
                groupItems.map { (id: $0.persistentModelID, date: $0.episode?.pubDate) },
                newestFirst: newestFirst
            )
        }
    }

    /// Group episodes shuffled through the system RNG.
    private func shuffleOrder(_ groupItems: [QueueItem]) -> [PersistentIdentifier] {
        var rng = SystemRandomNumberGenerator()
        return QueueLogic.shuffled(groupItems.map(\.persistentModelID), using: &rng)
    }

    /// Membership predicate for a podcast group.
    private func memberOf(_ podcast: Podcast) -> (QueueItem) -> Bool {
        { $0.episode?.podcast?.persistentModelID == podcast.persistentModelID }
    }

    /// Membership predicate for a folder group `key`, keyed the same way the
    /// folder-grouped display buckets episodes.
    private func memberOf(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> (QueueItem) -> Bool {
        { QueueGroup.folderKind(for: $0.episode, rootByPodcast: rootByPodcast) == key }
    }

    /// The grouping key for a queue item under "Group by podcast": the podcast id,
    /// falling back to the item's own id for an episode with no podcast (so it
    /// forms a singleton group and never swaps with anything).
    private func podcastKey(_ item: QueueItem) -> PersistentIdentifier {
        item.episode?.podcast?.persistentModelID ?? item.persistentModelID
    }

    /// The grouping key for a queue item under "Group by folder", keyed the same
    /// way the folder-grouped display buckets episodes.
    private func folderKey(
        _ rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> (QueueItem) -> QueueGroup.Kind {
        { QueueGroup.folderKind(for: $0.episode, rootByPodcast: rootByPodcast) }
    }

    /// Moves a podcast's whole group up one slot (swapping with the group
    /// before it) and de-interleaves the queue so each group is contiguous,
    /// matching the grouped view. Returns whether the order changed. No-op
    /// (returns false) if the group is already first or the podcast has nothing
    /// queued.
    @discardableResult
    func moveGroupUp(_ podcast: Podcast) -> Bool {
        reorderGroup(keyedBy: podcastKey, target: podcast.persistentModelID) { QueueLogic.moveGroupUp($0, key: $1) }
    }

    /// Moves a podcast's whole group down one slot (swapping with the group
    /// after it). See ``moveGroupUp(_:)``. Returns whether the order changed.
    /// No-op (returns false) if the group is already last or the podcast has
    /// nothing queued.
    @discardableResult
    func moveGroupDown(_ podcast: Podcast) -> Bool {
        reorderGroup(keyedBy: podcastKey, target: podcast.persistentModelID) { QueueLogic.moveGroupDown($0, key: $1) }
    }

    /// Folder-grouped analogue of ``moveGroupUp(_:)`` (#762): moves the whole
    /// folder group identified by `key` up one slot, de-interleaving the queue so
    /// each folder group is contiguous (matching the grouped view). No-op if the
    /// group is already first or empty.
    @discardableResult
    func moveGroupUp(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Bool {
        reorderGroup(keyedBy: folderKey(rootByPodcast), target: key) { QueueLogic.moveGroupUp($0, key: $1) }
    }

    /// Folder-grouped analogue of ``moveGroupDown(_:)`` (#762). No-op if the
    /// group is already last or empty.
    @discardableResult
    func moveGroupDown(
        _ key: QueueGroup.Kind, rootByPodcast: [PersistentIdentifier: PersistentIdentifier]
    ) -> Bool {
        reorderGroup(keyedBy: folderKey(rootByPodcast), target: key) { QueueLogic.moveGroupDown($0, key: $1) }
    }

    /// Shared group-action core: collects the podcast's queued items, lets
    /// `order` decide their new relative order, brings that ordered subset to the
    /// front (every other item keeps its relative position via
    /// ``QueueLogic/bringToFront(_:_:)``), persists only when the order actually
    /// changes, and returns the episode now at the front of the group. An empty
    /// group (the podcast has nothing queued) returns `nil` and makes no change.
    @discardableResult
    private func reorderGroupToFront(
        matching belongs: (QueueItem) -> Bool,
        order: (_ groupItems: [QueueItem]) -> [PersistentIdentifier]
    ) -> Episode? {
        let items = orderedItems()
        let groupItems = items.filter(belongs)
        guard !groupItems.isEmpty else { return nil }

        let orderedSubset = order(groupItems)
        let currentIDs = items.map(\.persistentModelID)
        let newOrder = QueueLogic.bringToFront(currentIDs, orderedSubset)
        if newOrder != currentIDs {
            applyOrder(newOrder, items: items)
        }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        return orderedSubset.first.flatMap { byID[$0]?.episode }
    }

    // MARK: Binge (#488)

    /// Establishes an in-podcast play run from the Library: seeds the queue with
    /// `episodes` (the podcast detail view's active-filter set — Unheard or All),
    /// orders them oldest-first by publish date, enqueues any not already queued,
    /// and brings that group to the FRONT of the queue as a contiguous block so
    /// auto-advance walks the podcast oldest→newest. Returns the oldest episode for
    /// the caller to start playing.
    ///
    /// Unlike ``playOldestFirst(_:)`` (which only reorders what is *already*
    /// queued), this seeds from the passed-in list, which is the whole point of a
    /// Library binge: the podcast usually isn't in the queue yet. It is
    /// non-destructive — every other queue item keeps its relative order via
    /// ``QueueLogic/bringToFront(_:_:)`` — and never clears the queue. With
    /// "continue after group ends" off, advance stops cleanly at the podcast's last
    /// episode (#446); this method does not touch that boundary logic.
    ///
    /// Empty input (or none of the episodes belong to `podcast`) returns `nil` and
    /// makes no change.
    @discardableResult
    func bingeOldestFirst(_ podcast: Podcast, episodes: [Episode]) -> Episode? {
        // Defensive: only this podcast's episodes form the run.
        let scoped = episodes.filter {
            $0.podcast?.persistentModelID == podcast.persistentModelID
        }
        guard !scoped.isEmpty else { return nil }

        // Oldest-first by publish date (stable; undated episodes trail).
        let orderedIDs = QueueLogic.sortedByDate(
            scoped.map { (id: $0.persistentModelID, date: $0.pubDate) },
            newestFirst: false
        )
        let byEpisodeID = Dictionary(uniqueKeysWithValues: scoped.map { ($0.persistentModelID, $0) })
        let orderedEpisodes = orderedIDs.compactMap { byEpisodeID[$0] }

        // Seed the queue: append any binge episode not already queued, tracking
        // its queue item directly (the inverse relationship may not be readable
        // again within the same mutation).
        var items = orderedItems()
        var itemByEpisodeID: [PersistentIdentifier: QueueItem] = [:]
        for item in items {
            if let epID = item.episode?.persistentModelID { itemByEpisodeID[epID] = item }
        }
        for episode in orderedEpisodes where itemByEpisodeID[episode.persistentModelID] == nil {
            let item = enqueue(episode)
            items.append(item)
            itemByEpisodeID[episode.persistentModelID] = item
        }

        // Bring the run to the front, oldest-first, preserving every other item's
        // relative order. Then persist dense positions.
        let frontSubset = orderedEpisodes.compactMap { itemByEpisodeID[$0.persistentModelID]?.persistentModelID }
        let newOrder = QueueLogic.bringToFront(items.map(\.persistentModelID), frontSubset)
        let byItemID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        compact(newOrder.compactMap { byItemID[$0] })

        return orderedEpisodes.first
    }

    // MARK: Internals

    /// Queue items in position order, with orphans (no episode — only possible
    /// via corrupt/aged data, since the relationship cascades) deleted so the
    /// set the UI shows and the set we reorder over are always identical.
    private func orderedItems() -> [QueueItem] {
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        let all = (try? context.fetch(descriptor)) ?? []
        let orphans = all.filter { $0.episode == nil }
        if !orphans.isEmpty {
            orphans.forEach(context.delete)
            AppLog.player.error("Removed \(orphans.count) orphan queue item(s)")
        }
        return all.filter { $0.episode != nil }
    }

    private func enqueue(_ episode: Episode) -> QueueItem {
        let item = QueueItem(episode: episode, position: 0)
        context.insert(item)
        episode.status = .inQueue
        return item
    }

    @discardableResult
    private func remove(_ episode: Episode, _ mutate: (Episode) -> Void) -> Bool {
        var items = orderedItems()
        guard let item = items.first(where: {
            $0.episode?.persistentModelID == episode.persistentModelID
        }), let canonicalEpisode = item.episode else { return false }
        items.removeAll { $0.persistentModelID == item.persistentModelID }
        context.delete(item)
        mutate(canonicalEpisode)
        return compact(items)
    }

    /// Applies a ``QueueLogic`` ordering op (keyed on queue-item ids) and
    /// persists. Returns whether the order actually changed.
    @discardableResult
    private func reorder(_ episode: Episode, _ op: ([PersistentIdentifier], PersistentIdentifier) -> [PersistentIdentifier]) -> Bool {
        let items = orderedItems()
        guard let id = episode.queueItem?.persistentModelID else { return false }
        return applyOrder(op(items.map(\.persistentModelID), id), items: items)
    }

    /// Applies a within-group ``QueueLogic`` op, keyed by `keyer` (podcast id for
    /// "Group by podcast"; folder group key for "Group by folder"). An item whose
    /// key is unique forms a singleton group and never swaps. Returns whether the
    /// order actually changed. Generic over the key type so both grouping modes
    /// reuse the exact same reorder path (#762).
    @discardableResult
    private func reorderWithinGroup<Key: Hashable>(
        _ episode: Episode,
        keyedBy keyer: (QueueItem) -> Key,
        _ op: ([(id: PersistentIdentifier, key: Key)], PersistentIdentifier) -> [PersistentIdentifier]
    ) -> Bool {
        let items = orderedItems()
        guard let id = episode.queueItem?.persistentModelID else { return false }
        let keyed = items.map { (id: $0.persistentModelID, key: keyer($0)) }
        return applyOrder(op(keyed, id), items: items)
    }

    /// Applies a whole-group ``QueueLogic`` op, keyed by `keyer` and targeting
    /// the group `target`. Generic over the key type so podcast and folder
    /// grouping share one reorder path (#762). Returns whether the order changed.
    @discardableResult
    private func reorderGroup<Key: Hashable>(
        keyedBy keyer: (QueueItem) -> Key,
        target: Key,
        _ op: ([(id: PersistentIdentifier, key: Key)], Key) -> [PersistentIdentifier]
    ) -> Bool {
        let items = orderedItems()
        let keyed = items.map { (id: $0.persistentModelID, key: keyer($0)) }
        return applyOrder(op(keyed, target), items: items)
    }

    /// Persists `orderedIDs` (a permutation of `items`) by recompacting positions,
    /// but only when it differs from the current order — a no-op order makes no
    /// write and posts no change notification. Returns whether anything changed.
    @discardableResult
    private func applyOrder(_ orderedIDs: [PersistentIdentifier], items: [QueueItem]) -> Bool {
        guard orderedIDs != items.map(\.persistentModelID) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentModelID, $0) })
        compact(orderedIDs.compactMap { byID[$0] })
        return true
    }

    /// Assigns dense positions `0..<N` over `ordered` and saves.
    @discardableResult
    private func compact(_ ordered: [QueueItem]) -> Bool {
        for (index, item) in ordered.enumerated() where item.position != index {
            item.position = index
        }
        return save()
    }

    @discardableResult
    private func save(notifyQueueChange: Bool = true) -> Bool {
        do {
            try context.save()
            if notifyQueueChange {
                NotificationCenter.default.post(name: .earshotQueueDidChange, object: nil)
            }
            return true
        } catch {
            AppLog.player.error("Queue save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
