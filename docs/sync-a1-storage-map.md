# Sync A1 storage map

**Status:** Approved by Michael (2026-08-03), amended for retained-column V9

**Issue:** [#769](https://github.com/payown/earshot/issues/769)

**Parent plan:** [folders-sync-phase-a.md](folders-sync-phase-a.md), Task 1

This record freezes the storage boundary before Earshot changes a live model or
enables CloudKit. It inventories the complete V6 graph and every known
`AppSetting` key, then defines which values belong in the future mirrored store
and which must remain on one device.

No live `@Model`, migration, entitlement, capability, signing, or UI change is
part of A1. The test-only prototype in `SchemaDriftTests.swift` proves the
proposed graph can be constructed as one `ModelContainer` with separate
mirrored and local configurations under Xcode 26.6 / Swift 6.3.3. Both
configurations explicitly use `cloudKitDatabase: .none` in Phase A.

## Decision summary

1. Keep the user library graph in the future mirrored configuration.
2. Move `Podcast.refreshedAt` into a local row keyed by canonical `feedURL`.
3. Move `Episode.downloadStatus` and `Episode.downloadPath` into one local row
   keyed by canonical podcast `feedURL` plus episode `guid`. `LocalEpisodeState`
   is the sole runtime source of truth. Retain the two old Episode attributes as
   permanent, unused schema tombstones; do not plan to drop them later unless a
   deferred lightweight migration has first been proven with supported public
   APIs.
4. Retire `ActiveDownload`. Its queryable raw state becomes
   `LocalEpisodeState.downloadStatusRaw`, eliminating both the redundant table
   and its forbidden cross-store relationship to `Episode`.
5. Keep `AppSetting` for settings that should mirror and introduce
   `LocalAppSetting` for device lifecycle, migration, and verified-entitlement
   caches. Unknown keys default to local until deliberately classified.
6. Local models contain scalar natural keys only. They have no SwiftData
   relationships to mirrored models.
7. Every mirrored relationship becomes optional and has an inverse. Existing
   application-level cleanup remains authoritative because CloudKit does not
   process relationship changes atomically.

Apple documents that CloudKit-backed SwiftData cannot enforce unique
constraints, requires optional relationships, and needs an inverse whenever it
cannot infer one. It also documents `ModelConfiguration` as the way to manage
specific groups of models and `.none` as the explicit way to disable mirroring:

- [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [ModelConfiguration](https://developer.apple.com/documentation/swiftdata/modelconfiguration)

## V6 attribute inventory and disposition

Every stored V6 attribute appears below. “Mirrored” means future user-library
state in the private CloudKit-backed configuration. “Local” means a separate
device-only configuration that will continue using `.none` after sync is
enabled for the mirrored configuration.

| V6 model | Stored field | V6 shape | Decision | Proposed representation and reason |
|---|---|---|---|---|
| `Podcast` | `feedURL` | required `String`, unique | Mirrored | Required natural key with a schema-visible default; remove `.unique` and enforce canonical fetch-or-create plus repair. |
| `Podcast` | `title` | required `String` | Mirrored | Feed metadata required to present a subscription; add schema-visible default. |
| `Podcast` | `author` | optional `String` | Mirrored | Feed metadata. |
| `Podcast` | `podcastDescription` | optional `String` | Mirrored | Feed metadata. |
| `Podcast` | `artworkURL` | optional `String` | Mirrored | The URL may mirror; cached image bytes remain outside SwiftData and local. |
| `Podcast` | `websiteURL` | optional `String` | Mirrored | Feed metadata. |
| `Podcast` | `language` | optional `String` | Mirrored | Feed metadata. |
| `Podcast` | `category` | optional `String` | Mirrored | Feed metadata. |
| `Podcast` | `autoQueue` | required `Bool` | Mirrored | User content-flow preference; add schema-visible default. |
| `Podcast` | `notificationEnabled` | optional `Bool` | Mirrored | Per-podcast user preference. |
| `Podcast` | `speedOverride` | optional `Double` | Mirrored | Per-podcast playback preference. |
| `Podcast` | `trimSilenceOverride` | optional `Bool` | Mirrored | Per-podcast playback preference. |
| `Podcast` | `introSkipSeconds` | optional `Int` | Mirrored | Per-podcast playback preference. |
| `Podcast` | `queueAgeLimitDays` | optional `Int` | Mirrored | Per-podcast queue policy. |
| `Podcast` | `inboxMaxEpisodes` | optional `Int` | Mirrored | Per-podcast inbox policy. |
| `Podcast` | `inboxAgeLimitHours` | optional `Int` | Mirrored | Per-podcast inbox policy. |
| `Podcast` | `inboxExcluded` | required `Bool` | Mirrored | User inbox membership state; add schema-visible default. |
| `Podcast` | `inboxIncluded` | required `Bool` | Mirrored | User inbox membership state; add schema-visible default. |
| `Podcast` | `createdAt` | required `Date` | Mirrored | Stable subscription metadata; add schema-visible default while initializers still supply `.now`. |
| `Podcast` | `refreshedAt` | optional `Date` | **Local** | Network-throttling bookkeeping differs by device. Move to `LocalPodcastState.refreshedAt`, keyed by canonical `feedURL`. |
| `Podcast` | `lastSeenPubDate` | optional `Date` | Mirrored | Inbox high-water mark is user-visible state and must prevent backlog floods on every device. |
| `Episode` | `guid` | required `String` | Mirrored | Episode natural key component; default plus app-level identity using podcast feed URL and GUID. |
| `Episode` | `title` | required `String` | Mirrored | Feed metadata; add schema-visible default. |
| `Episode` | `episodeDescription` | optional `String` | Mirrored | Feed metadata. |
| `Episode` | `audioURL` | required `String` | Mirrored | Feed metadata and stream location; add schema-visible default. |
| `Episode` | `durationSeconds` | optional `Int` | Mirrored | Feed metadata. |
| `Episode` | `pubDate` | optional `Date` | Mirrored | Feed metadata and ordering. |
| `Episode` | `artworkURL` | optional `String` | Mirrored | The URL may mirror; cached image bytes stay local. |
| `Episode` | `episodeNumber` | optional `Int` | Mirrored | Feed metadata. |
| `Episode` | `seasonNumber` | optional `Int` | Mirrored | Feed metadata. |
| `Episode` | `chapterURL` | optional `String` | Mirrored | Feed metadata; downloaded chapter data is a cache and stays local. |
| `Episode` | `transcriptURL` | optional `String` | Mirrored | Feed metadata; downloaded transcript data is a cache and stays local. |
| `Episode` | `status` | required `EpisodeStatus` | Mirrored | Played/unplayed state; retain the semantic type and add a schema-visible default. |
| `Episode` | `downloadStatus` | required `DownloadStatus` | **Local runtime; permanent tombstone column** | Runtime state comes only from queryable `LocalEpisodeState.downloadStatusRaw`. Retain the old column unused so Phase A never deliberately drops it. |
| `Episode` | `downloadPath` | optional `String` | **Local runtime; permanent tombstone column** | Runtime state comes only from `LocalEpisodeState.downloadPath`. Retain the old column unused; its legacy values are not authoritative. |
| `Episode` | `positionSeconds` | required `Int` | Mirrored | Playback progress; add schema-visible default. |
| `Episode` | `playedAt` | optional `Date` | Mirrored | User playback state and history semantics. |
| `Episode` | `inboxDismissed` | required `Bool` | Mirrored | User inbox state; add schema-visible default. |
| `Episode` | `createdAt` | required `Date` | Mirrored | Stable episode metadata; add schema-visible default while initializers still supply `.now`. |
| `QueueItem` | `position` | required `Int` | Mirrored | User queue order; add schema-visible default and retain deterministic recompaction. |
| `QueueItem` | `addedAt` | required `Date` | Mirrored | Queue metadata; add schema-visible default. |
| `ListeningSession` | `durationSeconds` | required `Int` | Mirrored | Listening history/statistics, per decision SY2; add schema-visible default. |
| `ListeningSession` | `speed` | required `Double` | Mirrored | Listening history detail; add schema-visible default. |
| `ListeningSession` | `date` | required `Date` | Mirrored | Listening history timestamp; add schema-visible default. |
| `Bookmark` | `positionSeconds` | required `Int` | Mirrored | User bookmark state; add schema-visible default. |
| `Bookmark` | `note` | required `String` | Mirrored | User bookmark content; add schema-visible default. |
| `Bookmark` | `createdAt` | required `Date` | Mirrored | User bookmark metadata; add schema-visible default. |
| `PodcastFolder` | `name` | required `String` | Mirrored | User folder content; add schema-visible default. |
| `PodcastFolder` | `sortOrder` | required `Int` | Mirrored | User folder ordering; add schema-visible default. |
| `PodcastFolder` | `queueAgeLimitDays` | optional `Int` | Mirrored | User folder queue policy. |
| `PodcastFolder` | `createdAt` | required `Date` | Mirrored | Stable folder metadata; add schema-visible default. |
| `FolderMembership` | `sortOrder` | required `Int` | Mirrored | User membership ordering; add schema-visible default. |
| `RecentlyExpired` | `expiredAt` | required `Date` | Mirrored | Recoverable queue state should behave consistently across devices; add schema-visible default. |
| `QuickActionConfig` | `contentType` | required `QuickActionContentType` | Mirrored | User-configured action set; add schema-visible default. |
| `QuickActionConfig` | `actionKey` | required `String` | Mirrored | User-configured action identity; add schema-visible default. |
| `QuickActionConfig` | `sortOrder` | required `Int` | Mirrored | User-configured action ordering; add schema-visible default. |
| `AppSetting` | `key` | required `String`, unique | Split by key | Keep mirrored rows in `AppSetting`, move local rows to `LocalAppSetting`, remove `.unique`, and use deterministic fetch-or-create/repair in both stores. |
| `AppSetting` | `value` | required `String` | Split by key | Follows the key classification below; add schema-visible default. |
| `ActiveDownload` | `stateRaw` | required `String` | **Local, then retire** | Fold into `LocalEpisodeState.downloadStatusRaw`; active states remain queryable without a relationship or redundant invariant table. |
| `EpisodeFolderMembership` | `sortOrder` | required `Int` | Mirrored | User episode-filing order; add schema-visible default. |

## V6 relationship inventory and disposition

All current relationships are optional except the four to-many arrays shown as
required. An unannotated relationship uses SwiftData's default `.nullify` rule.
The proposed mirrored graph makes every relationship optional and supplies an
inverse. No local model has a relationship.

| V6 owner.field | V6 cardinality | Delete rule | V6 inverse | A1 decision |
|---|---|---|---|---|
| `Podcast.episodes` | required to-many | cascade | `Episode.podcast` | Mirrored; become optional to-many and retain explicit inverse. |
| `Episode.podcast` | optional to-one | nullify | `Podcast.episodes` | Mirrored. |
| `Episode.queueItem` | optional to-one | cascade | `QueueItem.episode` | Mirrored. |
| `Episode.bookmarks` | required to-many | cascade | `Bookmark.episode` | Mirrored; become optional to-many. |
| `Episode.recentlyExpired` | optional to-one | cascade | `RecentlyExpired.episode` | Mirrored. |
| `QueueItem.episode` | optional to-one | nullify | `Episode.queueItem` | Mirrored. |
| `ListeningSession.episode` | optional to-one | nullify | none | Mirrored; add optional `Episode.listeningSessions` inverse. |
| `ListeningSession.podcast` | optional to-one | nullify | none | Mirrored; add optional `Podcast.listeningSessions` inverse. |
| `Bookmark.episode` | optional to-one | nullify | `Episode.bookmarks` | Mirrored. |
| `PodcastFolder.memberships` | required to-many | cascade | `FolderMembership.folder` | Mirrored; become optional to-many. |
| `PodcastFolder.parent` | optional to-one | nullify | `PodcastFolder.children` | Mirrored. |
| `PodcastFolder.children` | required to-many | nullify | `PodcastFolder.parent` | Mirrored; become optional to-many. |
| `FolderMembership.folder` | optional to-one | nullify | `PodcastFolder.memberships` | Mirrored. |
| `FolderMembership.podcast` | optional to-one | nullify | none | Mirrored; add optional `Podcast.folderMemberships` inverse. |
| `RecentlyExpired.episode` | optional to-one | nullify | `Episode.recentlyExpired` | Mirrored. |
| `ActiveDownload.episode` | optional to-one | nullify | none | Remove; local episode state is scalar-keyed. |
| `EpisodeFolderMembership.folder` | optional to-one | nullify | none | Mirrored; add optional `PodcastFolder.episodeMemberships` inverse. |
| `EpisodeFolderMembership.episode` | optional to-one | nullify | none | Mirrored; add optional `Episode.folderMemberships` inverse. |

CloudKit does not make cascade cleanup atomic. The app must keep the existing
explicit cleanup before podcast, episode, folder, queue, bookmark, or history
deletion even where the model retains `.cascade` as a local convenience.

## AppSetting key classification

There are 46 declared scalar/prefix keys in V6. Dynamic keys inherit the scope
of their prefix. The router must use an exhaustive allow-list; an unknown key
is local by default so a future build cannot accidentally mirror a device path,
persistent identifier, migration marker, or unverified entitlement cache.

| Key or prefix | Scope | Reason |
|---|---|---|
| `auto_download_count` | Mirrored | User download preference; decision SY2. |
| `history_retention_days` | Mirrored | User history policy; history itself mirrors. |
| `download_retention_days` | Mirrored | User download preference, not downloaded bytes. |
| `onboarding_complete` | **Local** | Per-install lifecycle; a new device must run its own setup and sync disclosure. |
| `crash_reporting_enabled` | **Local** | Unused compatibility residue; no telemetry ships. |
| `analytics_enabled` | **Local** | Unused compatibility residue; no telemetry ships. |
| `skip_silence_enabled` | **Local** | Unused compatibility residue for an unimplemented feature. |
| `voice_enhance_enabled` | Mirrored | User playback preference. |
| `global_speed` | Mirrored | User playback preference. |
| `skip_forward_seconds` | Mirrored | User playback preference. |
| `skip_back_seconds` | Mirrored | User playback preference. |
| `direct_touch_enabled` | **Local** | Unused compatibility residue. |
| `chapter_nav_buttons_visible` | Mirrored | Persisted user presentation preference, not transient UI state. |
| `inbox_opt_in_only` | Mirrored | User inbox policy. |
| `wifi_only_downloads` | Mirrored | User download preference; decision SY2. |
| `delete_download_after_played` | Mirrored | User download preference; decision SY2. |
| `auto_download_queued` | Mirrored | User download preference; decision SY2. |
| `downloads_played_filter` | Mirrored | Persisted user list preference. |
| `group_queue_episodes` | Mirrored | Persisted user queue preference. |
| `show_episode_numbers` | Mirrored | Persisted user presentation preference. |
| `open_player_on_play` | Mirrored | Persisted user playback preference. |
| `continue_after_episode` | Mirrored | User playback policy. |
| `continue_after_group_ends` | Mirrored | User playback policy. |
| `default_launch_screen` | Mirrored | Persisted user preference; not transient navigation state. |
| `library_sort_order` | Mirrored | Persisted user list preference. |
| `episode_sort_order` | Mirrored | Persisted user list preference. |
| `last_playing_episode_id` | **Local** | Current device playback lifecycle; replace the store-specific ID payload with the episode natural key during implementation. |
| `stats_streaks_enabled` | Mirrored | User stats preference. |
| `inbox_default_count` | Mirrored | User inbox policy. |
| `flutter_migration_complete` | **Local** | Retired per-install migration marker. |
| `flutter_migration_attempts` | **Local** | Retired per-install migration marker. |
| `flutter_episode_state_restored` | **Local** | Retired per-install migration marker. |
| `last_feed_refresh` | **Local** | Per-device network throttle; another device's refresh must not suppress this one. |
| `migration_status` | **Local** | Retired per-install migration diagnostic. |
| `migration_last_attempt_date` | **Local** | Retired per-install migration diagnostic. |
| `theme_override` | Mirrored | Persisted user appearance preference. |
| `accent_color` | Mirrored | Persisted user appearance preference. |
| `layout_density` | Mirrored | Persisted user appearance preference. |
| `podcast_filter_<feedURL>` | Mirrored | Per-podcast user list preference, keyed by canonical feed URL. |
| `podcast_inbox_cap_<feedURL>` | Mirrored | Per-podcast user inbox policy, keyed by canonical feed URL. |
| `earshot_plus_entitled` | **Local** | StoreKit-derived cache; each device must verify current entitlements. |
| `earshot_plus_entitlement_product` | **Local** | StoreKit-derived cache; never trust a mirrored assertion. |
| `earshot_plus_active_subscription` | **Local** | StoreKit-derived cache; never trust a mirrored assertion. |
| `earshot_plus_entitlement_last_synced` | **Local** | Per-device verification timestamp. |
| `podcast_cap_gating_introduced` | Mirrored | Account/library policy must be consistent across devices. |
| `grandfathered_podcast_count` | Mirrored | Account/library allowance must be consistent across devices. |

Result: 30 mirrored keys/prefixes and 16 local keys/prefixes.

## Proposed configuration membership

The final CloudKit-ready graph contains 14 model types across two
configurations:

| Configuration | Models | Phase A database option |
|---|---|---|
| Future mirrored | `Podcast`, `Episode`, `QueueItem`, `ListeningSession`, `Bookmark`, `PodcastFolder`, `FolderMembership`, `RecentlyExpired`, `QuickActionConfig`, `AppSetting`, `EpisodeFolderMembership` | `.none` |
| Device local | `LocalPodcastState`, `LocalEpisodeState`, `LocalAppSetting` | `.none` |

`ActiveDownload` is retired after its active rows are converted to
`LocalEpisodeState`. In Sync Phase B only, the first configuration may change to
`.private("iCloud.media.payown.earshot")`; the local configuration must remain
`.none` permanently.

### Natural keys

- `LocalPodcastState`: canonical `feedURL`.
- `LocalEpisodeState`: canonical podcast `feedURL` plus episode `guid`.
- `LocalAppSetting`: exact key string.

None uses `.unique`. Task 2 supplies fetch-or-create, deterministic duplicate
repair, and indexes where measurements justify them. Episode GUID is never
treated as globally unique.

### Download-state invariant

`LocalEpisodeState.downloadStatusRaw` is a plain queryable string with the same
known states as `DownloadStatus`. This replaces both V6 download fields and the
`ActiveDownload` join:

- pending/downloading rows are fetched directly by raw state;
- downloaded rows carry a local filename in `downloadPath`;
- terminal none/failed state may retain a row only when other local episode
  state needs it, otherwise the row can be removed;
- audio bytes remain in `Documents/Downloads` and outside SwiftData;
- no container-relative path or active-transfer state exists in the mirrored
  schema.

## Query and performance consequences

The configuration prototype constructs, but optional inverses change safe query
style:

- Optional to-many relationships require `?? []` at call sites that genuinely
  operate on a small already-loaded collection.
- Never traverse `Podcast.episodes` or a new inverse collection from a hot list
  merely to filter or count. Keep store predicates on scalar fields and
  persistent IDs, following the Inbox/Downloads performance fixes.
- New `Episode.listeningSessions` and `Episode.folderMemberships` inverses exist
  for CloudKit integrity, not as list-loading APIs. Repositories continue to
  query the join/session type and must remain bounded.
- `PodcastFolder.memberships`, `PodcastFolder.children`, and folder inverse
  collections are small in normal use, but their readers still coalesce nil and
  avoid repeated work during VoiceOver traversal.
- Resolving local state for a visible episode uses the composite natural key.
  Batch screens fetch local candidates once and build an in-memory lookup;
  never issue one local-store query per row.
- The 242,000-plus Episode table must not be materialized on the main actor for
  backfill, dedup, download lookup, or optional-inverse repair.

## Migration consequences and recommended sequence

Moving persisted values between model types cannot safely be expressed as one
blind lightweight migration: a `willMigrate` callback cannot insert the new
destination type, while a `didMigrate` callback can no longer read a removed
source field. A whole-store export/reimport would touch 242,000-plus Episode
rows and is rejected.

Use an explicit, recoverable preflight followed by the final container open in
the same Phase A implementation release. A single automatic `ModelContainer`
migration is not sufficient: the test-only disk probe demonstrated that a
`didMigrate` callback cannot route copied rows into a second configuration (the
destination store remained empty).

1. **Read a bounded V6 preflight without changing V6:** open the frozen V6 graph
   and snapshot only the local candidates:
   - fetch episodes with `downloadPath != nil` using a store predicate;
   - fetch the naturally tiny `ActiveDownload` table for pending/downloading;
   - copy `Podcast.refreshedAt` from the small Podcast table;
   - classify the small AppSetting table into mirrored/local rows.
   Retain the additive V7 schema solely to resume stores that already reached
   that preflight in an earlier draft build.
2. **Close and populate the separate local store:** write idempotent V9 local
   rows into the device-local store, save, and verify
   expected row counts and values. Record completion only after the destination
   is durable.
3. **Open the retained-column V9 split container:** only after validation,
   finalize `FutureMirrored` and open it with `DeviceLocal`. Remove
   `Podcast.refreshedAt` and `ActiveDownload`, but preserve Episode's two legacy
   download columns as unused tombstones. Remove unique constraints; add
   schema-visible defaults and optional inverses. Keep both configurations
   explicitly local.
4. **Advance the installed draft V8 store without replaying V7:** recognize its
   durable split marker, migrate both V8 files forward to V9, and run the
   versioned identity repair once. Save repair results first, then save the
   completion marker separately. Targeted per-podcast repair remains in feed
   refresh.

Back up the existing store before preflight. A failure during V6→V7 retries the
bridge migration. A crash or validation failure while copying local data
rebuilds the destination from the source bridge rows. Never advance the
original store to V8 until the local copy validates, because V8 deliberately
removes the only source for those values.

Failed download state without a path is transient and may normalize to `none`;
pending/downloading comes from `ActiveDownload`; downloaded state comes from a
valid path and is reconciled against the file system at launch. Migration tests
must still seed every V6 enum case and assert this normalization explicitly.

The baked Phase A target is V9. V8 remains a frozen snapshot only for the one
device that installed the draft column-dropping build; V7 remains a frozen
restart point. Neither is a future steady-state schema.

Real-store timing remains a release gate. Retaining the columns prevents a
deliberate drop/re-add, but it does not guarantee that SwiftData avoids a table
copy for the other CloudKit relationship changes. The opt-in aged-store test,
not the freshly constructed scale fixture, decides whether launch-path work is
safe.

## Automated construction proof

`SyncStorageTopologyTests` uses test-only models and verifies under the required
toolchain that:

- the complete 14-model schema constructs in one container with separate
  `FutureMirrored` and `DeviceLocal` configurations;
- one mirrored and one local row save and fetch through that container;
- no future-mirrored attribute is unique;
- every required future-mirrored attribute has a schema-visible default;
- every future-mirrored relationship is optional, has an inverse, and does not
  use `.deny`;
- the local schema has no relationships;
- an untouched V6 disk store can populate and validate a separately configured
  V9 local store before finalization, and an already-split V8 pair can advance
  to V9 without replaying the V7 bridge.

The proof intentionally uses `.none` for both configurations. Constructing a
live `.private` container would require the entitlements and capability changes
that A1 and all of Sync Phase A explicitly prohibit.

## Approval gate

Approval of this record authorizes Tasks 2 and 3 to implement:

- the 11 mirrored / 3 local model boundary above;
- natural-key local episode and podcast state;
- the 30 mirrored / 16 local setting classification;
- retirement of `ActiveDownload` after bridge backfill;
- a restartable bounded preflight followed by retained-column V9 in the same
  Phase A release, with frozen V7/V8 resume routes.

It does **not** authorize CloudKit, entitlements, capabilities, schema
initialization/promotion, sync UX, or two-device behavior.
