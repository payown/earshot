import Foundation
import SwiftData

/// Which of the two IN-FLIGHT download states an ``ActiveDownload`` row records.
///
/// Deliberately NOT stored on the model. SwiftData refuses a `Codable` enum in a
/// `#Predicate` ("Unsupported Predicate: Captured/constant values of type
/// 'DownloadStatus' are not supported"), and reaching for `.rawValue` on a stored
/// enum is an uncatchable `fatalError` ("Failed to validate
/// \Episode.downloadStatus.rawValue"). ``ActiveDownload/stateRaw`` stores the raw
/// String — the only form a predicate can actually use — and this type is purely
/// a computed accessor over it (#701).
enum ActiveDownloadState: String, CaseIterable {
    case pending
    case downloading

    /// The active state matching `status`, or nil when `status` is terminal
    /// (`.none` / `.downloaded` / `.failed`) and therefore has no row at all.
    ///
    /// The switch is exhaustive on purpose: a new ``DownloadStatus`` case must
    /// force a deliberate decision here rather than silently defaulting to
    /// "not active" and re-opening the #544 stuck-download hole.
    init?(_ status: DownloadStatus) {
        switch status {
        case .pending: self = .pending
        case .downloading: self = .downloading
        case .none, .downloaded, .failed: return nil
        }
    }
}

/// The authoritative record of download work that is IN FLIGHT — an episode
/// parked on the Wi-Fi gate (`.pending`) or actually transferring
/// (`.downloading`). New entity in schema V5 (#701).
///
/// **Why this exists.** ``DownloadManager`` used to find those episodes by
/// fetching the ENTIRE `Episode` table on the main actor and filtering in
/// memory, at three points on the launch path. `Episode.downloadStatus` cannot
/// be queried at all: it is a `Codable` enum, which SwiftData rejects in a
/// `#Predicate`, and reshaping it into a raw `String` is not
/// lightweight-inferrable (134110 "missing attribute values on mandatory
/// destination attribute") — a `.custom` stage cannot rescue that, because
/// custom only brackets the inferred migration. On a real 241,979-row library
/// the whole-table walk is a scene-create watchdog kill (0x8BADF00D; 38.4s of
/// user CPU in `swift_arrayDestroy` -> `Episode.__deallocating_deinit`). This
/// table carries the same information in a form that IS queryable, and it is
/// naturally tiny — bounded by user action, measured at ZERO rows on the
/// affected device at launch.
///
/// **Why the V4→V5 migration is safe.** Adding a brand-new entity is
/// lightweight-inferrable and leaves `Episode`'s shape completely untouched, so
/// the 242k episode rows are never rewritten and carry no migration risk. An
/// EMPTY table is the semantically correct state immediately after the upgrade —
/// no download is in flight across an app update — so there is no backfill.
///
/// **The invariant that makes it trustworthy.** A row exists if and only if its
/// episode is at `.pending` or `.downloading`. Every write of
/// `Episode.downloadStatus` goes through ``setDownloadStatus(_:on:in:)``, which
/// updates the episode and this table in the same `ModelContext` save. If the
/// two could diverge, an episode stuck at `.downloading` with no row would be
/// invisible to reconciliation and spin forever — issue #544 returning.
///
/// **The `episode` reference is deliberately ONE-WAY.** An
/// `@Relationship(inverse:)` collection on `Episode` would change `Episode`'s
/// shape and put the 242k rows straight back into the migration's path. The cost
/// is that SwiftData maintains no referential integrity for a relationship with
/// no inverse, so rows must be dropped explicitly BEFORE their episode is
/// deleted — see ``removeRows(forEpisodesOf:in:)``, which unsubscribe calls
/// ahead of its cascade delete.
@Model
final class ActiveDownload {
    /// The episode whose download is in flight. One-way (no inverse on
    /// `Episode`) — see the note on the type.
    var episode: Episode?

    /// ``ActiveDownloadState`` as its raw String. Stored as a plain `String`,
    /// never as the enum, because only a plain String is usable in a
    /// `#Predicate` — which is the entire point of this table (#701). Read it
    /// through ``state``; write it through ``setDownloadStatus(_:on:in:)``.
    var stateRaw: String

    /// Type-safe read of ``stateRaw``. nil only for a value this build does not
    /// know (i.e. a store written by a newer build).
    var state: ActiveDownloadState? { ActiveDownloadState(rawValue: stateRaw) }

    init(episode: Episode? = nil, state: ActiveDownloadState) {
        self.episode = episode
        self.stateRaw = state.rawValue
    }
}

extension ActiveDownload {

    /// The ONE way to write `Episode.downloadStatus` (#701). Sets the status and
    /// brings the episode's ``ActiveDownload`` row into step in the same
    /// `ModelContext`, so the two land in a single save and cannot diverge.
    ///
    /// Writing `episode.downloadStatus` directly anywhere else breaks the
    /// invariant this table depends on. Callers still own the save — this only
    /// stages both changes on `context`.
    static func setDownloadStatus(
        _ status: DownloadStatus, on episode: Episode, in context: ModelContext
    ) {
        episode.downloadStatus = status
        sync(episode, in: context)
    }

    /// Reconciles `episode`'s row(s) with its CURRENT `downloadStatus`:
    /// insert/update while the status is active, delete once it is terminal.
    /// Idempotent, and self-healing against duplicate rows.
    private static func sync(_ episode: Episode, in context: ModelContext) {
        let existing = rows(for: episode, in: context)
        guard let state = ActiveDownloadState(episode.downloadStatus) else {
            // Terminal status (.none / .downloaded / .failed): the work is over,
            // so the row must go — leaving one would make reconciliation chase
            // an episode that is no longer downloading.
            for row in existing { context.delete(row) }
            return
        }
        guard let row = existing.first else {
            context.insert(ActiveDownload(episode: episode, state: state))
            return
        }
        row.stateRaw = state.rawValue
        // Duplicates cannot arise through this API, but dropping them is free
        // and a duplicate would double-report the episode to reconciliation.
        for extra in existing.dropFirst() { context.delete(extra) }
    }

    /// Every row pointing at `episode`.
    ///
    /// Keyed on the episode's persistent identity rather than its guid, because
    /// guids are not unique across podcasts (#576). The predicate compares a
    /// `PersistentIdentifier` through a to-one relationship, mirroring the
    /// established pattern in `SubscriptionRepository.mergeBackgroundWrites`.
    static func rows(for episode: Episode, in context: ModelContext) -> [ActiveDownload] {
        let id = episode.persistentModelID
        let descriptor = FetchDescriptor<ActiveDownload>(
            predicate: #Predicate { $0.episode?.persistentModelID == id }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Drops every row belonging to an episode of `podcast`. Unsubscribe must
    /// call this BEFORE `context.delete(podcast)`: the cascade deletes the
    /// podcast's episodes, and because ``episode`` has no inverse SwiftData will
    /// not nullify the references pointing at them, leaving rows that dangle at
    /// deleted rows.
    ///
    /// Fetches the whole table on purpose. Unlike `Episode` — the 242k-row table
    /// this whole design exists to stop scanning — `ActiveDownload` is bounded by
    /// in-flight user action (tens of rows at the very most), so a full fetch is
    /// cheap and keeps the traversal in Swift rather than in a two-level
    /// optional-chained predicate.
    static func removeRows(forEpisodesOf podcast: Podcast, in context: ModelContext) {
        let id = podcast.persistentModelID
        let all = (try? context.fetch(FetchDescriptor<ActiveDownload>())) ?? []
        for row in all where row.episode?.podcast?.persistentModelID == id {
            context.delete(row)
        }
    }
}
