# Personal Audio: Product Requirements and Technical Plan

**Status:** V1 closeout; implementation is in TestFlight and this document records the approved scope and review status.  
**Date:** 2026-09-27  
**Terminology:** “Personal Audio” is the working feature name. User actions should say “Add to Earshot.”

## Executive Summary

Personal Audio lets listeners add individual audio files through the standard Files picker and play them through Earshot’s existing player. V1 copies each selection into durable app-managed storage, extracts available metadata and embedded chapters, and stores state in a separate `PersonalAudioItem`. Library presents one **Personal Audio** destination before subscribed podcasts; that screen lists all imported items and owns **Add to Earshot**. Playback, resume, played state, completion, chapters, lock-screen controls, and safe deletion use the existing player. Mixed Queue integration, folders, Share Sheet, direct open, URL import, and Earshot CloudKit synchronization are deferred.

Do not model imported files as fake podcast subscriptions. `Episode` is not an independent media row: its lifecycle, uniqueness, queue projections, playback restoration, folder behavior, and many screens expect a parent `Podcast`. A separate `PersonalAudioItem` entity is the safer domain model. Reuse player behavior through a narrow playback-content adapter/value interface, and expand the queue identity/repository deliberately. This is more work than inserting synthetic Podcast/Episode rows, but avoids corrupt subscription semantics, RSS refresh paths, and CloudKit feed-key assumptions.

Personal Audio uses the existing folder system, with multiple memberships per item. Items remain visible in Personal Audio even when filed, and folder deletion removes membership only. Folder details, counts, pickers, Queue operations, and ordering need explicit updates. A technical complication is that podcast/folder records and device-local state currently live in separate SwiftData stores; implementation must resolve folder membership without creating unsupported cross-store relationships or syncing Personal Audio through CloudKit.

The project already has mature document-import and persistence patterns, but the manifest currently declares only OPML as an openable document. `PlayerService` hands resolved URLs to `AVPlayerItem`; it has no explicit importer allowlist or validation stage. `ChapterService` already reads embedded MP3 ID3 chapters and MP4/M4A chapter atoms from local files. Format acceptance must therefore be based on type identification plus actual AVFoundation asset inspection/playability, not on an assumed exhaustive supported-format list.

## Current Architecture Findings

### Library and subscriptions

- `Earshot/Features/Subscriptions/Presentation/SubscriptionsView.swift` is the main Library screen (navigation title “Library”). It currently presents subscribed podcasts, with manual load and derived ordering/filtering to avoid expensive SwiftData relationship faults in large libraries. The code specifically avoids faulting each podcast’s `episodes` relationship because real libraries can contain hundreds of thousands of episode rows; any new unified Library query must preserve this VoiceOver responsiveness constraint.
- The Library toolbar links to Search, `FoldersScreen`, refresh, options, and podcast discovery. Empty state says “No podcasts yet” and offers discovery. A Personal Audio section needs to coexist with this lifecycle and empty state rather than replacing it.
- `Podcast` represents a subscribed or catalog-only podcast and holds feed metadata and many feed-specific settings. `subscriptionStateRaw` and `PodcastSubscriptionState` separate catalog-only from followed state. Feed URL is its persistent identity; never invent a feed URL for user files.
- `Episode` stores RSS episode metadata, enclosure `audioURL`, status, position, timestamps, feed identifiers, chapter/transcript URLs, and relationships to queue, bookmarks, listening sessions, downloads, and folder memberships. Podcast deletion cascades to its episodes.
- Podcast folders use `PodcastFolder` plus `FolderMembership`; individual podcast episodes can separately be filed through `EpisodeFolderMembership`. Folder hierarchy already supports parent/child nesting. `FolderRepository` owns membership cleanup and folder-detail snapshots. Episode membership cleanup is manual because its relationship intentionally has no inverse to avoid migrations faulting a very large Episode table.
- `FolderDetailSnapshot`, `FoldersScreen`, `FolderDetailScreen`, `FolderPickerView`, and `FolderRepository` are podcast/episode-aware. Presentation counts and folder-run/queue behaviors must be extended if Personal Audio is included.

### Queue and playback

- `QueueItem` currently points only to an optional `Episode`; `QueueRepository.queue()` returns `[Episode]`, and queue uniqueness and cloud synchronization use the podcast feed URL plus episode GUID. The CloudKit queue journal/projection logic stages mutations only for followed-podcast episodes. Since the main Queue is mirrored and Personal Audio must remain local, a Personal Audio queue entry cannot simply be a relationship from that queue row to a `DeviceLocal` item. A local queue overlay or another cross-store ordering bridge must support mixed RSS/Personal Audio ordering, restoration, and reorder operations without sending Personal Audio identity to CloudKit.
- `PlayerService` (`Earshot/Features/Player/Data/PlayerService.swift`) owns a single `AVPlayer`, creates `AVPlayerItem(url:)` in one helper, applies audio time-pitch configuration, manages Now Playing/remote commands, chapters, interruptions, queue advancement, playback persistence, and extensive recovery logic. Public entry points such as `play(_:)`, `load(_:)`, queue navigation, and callbacks accept `Episode` directly.
- `PlaybackLogic.resolvePlaybackURL` prefers an existing downloaded local path, else converts `Episode.audioURL` to a URL. It accepts any URL scheme syntactically; transport/security handling is elsewhere. Passing `file://` can work at AVPlayer level, but current parsing and network diagnostics include RSS-specific assumptions.
- Startup restoration uses `SettingsKey.lastPlayingEpisodeID` and `DownloadTaskKey` (feed URL + GUID). Session progress and played state are persisted to Episode (`positionSeconds`, `status`, `playedAt`); completion resets position and marks played. `ListeningSession` records Episode and Podcast relationships. All these need general identities or an explicit Personal Audio path.
- `NowPlayingScreen`, `NowPlayingBar`, `EpisodeRow`, queue rows, App Intents, and accessibility announcements currently read episode/podcast data. The existing spoken semantics must be retained for subscribed episodes; new Personal Audio context should be additive and explicitly identify user-added content where that helps orientation.

### Downloads, storage, and file import

- Podcast downloads live under `Documents/Downloads` (`DownloadPaths`). New stored values are bare filenames because iOS can relocate the app container. That directory is explicitly excluded from system backup because podcast media is re-downloadable; Personal Audio files must not inherit this policy.
- Download transfer state is separated from durable mirrored metadata (`ActiveDownload`, local state / runtime projection). This shows the project deliberately separates device-specific file/transfer data from synchronized state.
- `OPMLFileImporter` demonstrates the existing import pattern: start security-scoped access, read/copy while scope is active, stage app-owned bytes, report spoken outcomes through `Announcer`, then continue work in a coordinator. Entry points include SwiftUI `.fileImporter` and `onOpenURL` in `RootView`/`EarshotApp`.
- `Earshot/App/Info.plist` declares an OPML document type, sets `LSSupportsOpeningDocumentsInPlace`, and declares OPML as imported. It does not currently advertise audio-file opening. `ShareSheet` is a `UIActivityViewController` wrapper for outbound sharing; no inbound share extension is present.
- There is no general-purpose external-file bookmark registry or Personal Audio import today. `AppRuntime.enqueueIncomingFile` queues an incoming URL, while `RootView` interprets it as an OPML import; the route must dispatch by supported content type before audio open-in-app support is added.

### Persistence and cloud behavior

- SwiftData models are declared in versioned `EarshotSchema` snapshots and split mirrored/local stores. `ModelContainerFactory` and `StoreMigration` use a carefully staged, forward-only migration process with recovery backups. The current schema is V12; new persistent model fields/entities require an additive schema/version update and review of both mirrored and local schema declarations.
- The current container has a CloudKit-mirrored store for library/folder models, a separate `DeviceLocal` SwiftData store, and an optional compact private projection (`CloudProjection`) for podcast/episode identity, progress, played state, queue, and folder state. Personal Audio media and state must stay out of both Earshot CloudKit paths. Because a local SwiftData model cannot simply hold a relationship to `PodcastFolder` in the other store, folder membership is a high-risk design point requiring a stable cross-store folder key or another tested bridge.
- `AppSetting` stores several scalar preferences and restoration markers; it is not appropriate as the canonical home for a collection of imported items or opaque file metadata.

### Accessibility conventions

- `Announcer` is used for success/failure and workflow status. Existing screens use custom accessibility labels, values, hints, rotors, and focus state. `SubscriptionsView` explicitly manages tab-entry/heading focus and avoids VoiceOver stalls from giant relationship faults. Folder and queue screens communicate grouping and actions through spoken content rather than icon-only cues.
- The Personal Audio section must be a real semantic section and its items must be spoken as Personal Audio. Color/icon differences alone are insufficient. Import status and errors must be announced without relying only on transient visual banners.

## User Problem

Listeners have audio files outside podcast feeds—recordings, lectures, language lessons, audiobooks, and downloaded programs—but Earshot’s accessible controls and listening state are currently available only for podcast episodes. They need a reliable way to bring a file into the same playback experience without fabricating a subscription or depending on an external file remaining in place.

## Feature Goals

1. Add one supported local audio file to Earshot with a short, VoiceOver-operable workflow.
2. Play it with the normal player, lock-screen controls, resume position, and played/unplayed state.
3. Find Personal Audio near the top of Library and distinguish it in speech and structure from followed podcasts.
4. Integrate with playback, restoration, chapter navigation, and Now Playing while keeping Personal Audio separate from Podcast and Episode identity. Queue and folders are deferred.
5. Preserve the imported file inside Earshot so moves/deletions in Files do not break playback.
6. Give clear progress, success, and recoverable error feedback.

## Non-Goals for V1

- RSS feed creation, podcast subscription, URL downloads, web scraping, or external streaming links.
- Share Sheet, direct “Open in Earshot,” URL import, Earshot CloudKit sync, or batch import.
- Chapter editing, metadata editor, custom artwork, transcripts, or automatic content recognition.
- Import of video, archives, protected/DRM audio, or arbitrary documents.
- Rewriting the existing podcast player and all feed-only behavior as a generic media framework.

## Terminology and Naming

- **Personal Audio:** Library category and model-level content type.
- **Add to Earshot:** Primary import action and success language.
- **Personal Audio item:** One app-owned imported audio file.
- **Subscribed podcast:** Followed feed and its RSS episodes.
- Avoid “side-load,” “file-backed episode,” and “subscription” for imported content. In VoiceOver, include “Personal Audio” in the title or group context where the section context may not be retained.

## User Stories

- As a listener, I can choose an audio file from Files and add it to Earshot.
- As a VoiceOver user, I can understand what files are eligible, hear import progress and the result, and recover from errors.
- As a listener, I can play, pause, seek, change speed, resume after force quit, and mark an item played/unplayed.
- As a listener, I can queue an item, remove it from Queue, and organize it in an existing folder.
- As a listener, I can delete the imported copy without affecting the original in Files.
- As a listener, I can distinguish my files from followed podcasts even when navigating by headings or spoken row labels.

## Proposed User Experience

### Library structure

Recommended initial presentation:

1. **Personal Audio** section at the top, showing the five most recently added items (configurable during implementation if layout or VoiceOver review indicates a better count), then **View All Personal Audio**.
2. The existing subscribed-podcast Library presentation, ordering, filters, and discovery controls unchanged below it.

Keep the current Library as one navigation destination and preserve the existing Folders toolbar navigation; Folders does not become a new top-level content category. Show the five most recently added items inline, newest first, in deterministic order, without querying/faulting all episodes. Podcast sorting and Hide caught-up behavior apply only to podcasts. If there are no Personal Audio items, show a concise empty state and a **Add to Earshot** action. The existing podcast empty state remains available independently.

### Folder behavior

Use the existing `PodcastFolder` hierarchy, folder navigation, and picker. Personal Audio items start unfiled and remain in the main Personal Audio list regardless of memberships. A folder picker lets the user add/remove an item from multiple folders. Folder details show separate podcast, episode, and Personal Audio groupings with meaningful headings and counts. Membership is organizational, not ownership. Deleting a folder removes its Personal Audio membership, matching the current principle that deleting folders does not delete content.

Do not auto-create a “Personal Audio” folder: the category itself is the default collection. V1 supports multiple memberships, matching the many-to-many organizational model already used for podcasts and episodes, subject to resolving the separate-store persistence boundary.

## Import Workflows

### Version 1: in-app Files picker

1. From Library’s Personal Audio section or list, activate **Add to Earshot**.
2. Present the standard iOS file importer filtered to candidate audio UTTypes; allow one file initially.
3. While the selected URL is security-scoped, coordinate/read it and copy it into `Application Support/PersonalAudio` (or another explicitly app-managed durable directory). Do not retain an external URL as the only media reference.
4. Validate the copied file can be opened as an audio asset and has a playable audio track. Reject encrypted/protected or unsupported assets with an actionable, spoken message.
5. Extract metadata, create the SwiftData record only once the copy and validation succeed, and save transactionally. If database insertion fails, remove the just-copied file; if copying fails, create no visible item.
6. Announce “Added [title] to Personal Audio” and put focus on the newly added row or a stable import result heading. On failure announce the reason and keep the user on a predictable screen.

The app already uses `.fileImporter` and a staged-copy pattern for OPML. Reuse that workflow shape, but give audio its own importer service, staging/cleanup, and progress semantics rather than expanding the OPML parser/coordinator into a catch-all.

### Future import entry points

V1 excludes Share Sheet and direct “Open in Earshot.” Later, both should route into the same importer service. Direct document opening requires audio type registration in Info.plist and audio-aware dispatch through `RootView`; the current app registers OPML only. Share Sheet requires deciding between system-provided app sharing and a true extension, handling `NSItemProvider` representations and temporary URLs, and potentially adding an extension target/app group. These are additional front ends, not separate import pipelines.

### URL ingestion (future)

Treat URLs as future scope. Require explicit user confirmation and HTTPS by default, use Earshot’s existing secure URL handling, cap size/time, validate redirects and actual media type, and never accept arbitrary local/network schemes. Remote URLs introduce server authentication, expiring links, redirection/ATS, content-length uncertainty, and rights/privacy concerns that Files import does not.

## Data Model Recommendation

### Recommended: separate `PersonalAudioItem` entity

Persist at minimum:

- stable UUID/string identity (not filename, source URL, or mutable path)
- title, optional artist/album/description, optional duration and artwork reference/embedded artwork cache metadata
- relative managed filename (never an absolute container path)
- byte size, detected UTType/container/codec diagnostics as appropriate
- import date, status, playback position, played state/date
- optional import fingerprint (e.g. content hash) for duplicate prompts
- a content hash for exact duplicate detection (calculate off the main actor)
- multiple local folder membership keys and per-folder order

Keep raw media bytes outside SwiftData. Use a new `PersonalAudioFolderMembership` concept with explicit cleanup and per-folder ordering. Do not add an inverse on the very large `Episode` model. Keep Personal Audio records, file paths, memberships, and queue identity out of Earshot CloudKit. Since `PodcastFolder` is in the mirrored SwiftData store and Personal Audio belongs in `DeviceLocal`, do not assume a SwiftData relationship can cross stores. Prototype an immutable folder UUID/key usable by a local membership row, including how existing folders receive that key and how rename/delete changes are observed; alternatively document another design that demonstrably keeps Personal Audio local. This decision is a prerequisite for folder support, not a reason to duplicate the folder hierarchy.

### Why not reuse Episode directly?

**Direct reuse** looks cheap because the player, queue row, played/progress fields, bookmarks, and folders already target Episode. But a bare Episode is structurally invalid for many existing assumptions: its feed URL/GUID composite key, parent Podcast, subscription filtering, podcast speed overrides, episode GUID collisions, auto-queue rules, feed refresh, metadata provenance, ListeningSession attribution, and CloudKit reconciliation. A synthetic Podcast would pollute subscribed-podcast queries and create fake feed identity. Marking the synthetic podcast “catalog-only” still introduces special cases across rendering, caps, queue projection, and deletion. It also risks accidentally treating a personal file as renewable or deletable feed cache.

**Separate type with shared protocol/value abstraction (recommended):** clean ownership and lifecycle; RSS code stays RSS-specific. Cost: queue item identity, playback state, Now Playing metadata, screen rows, and shared player APIs must accept the new type. Avoid SwiftData protocol polymorphism; use an enum/value wrapper (for example `PlaybackContent` with `.episode(Episode)` / `.personalAudio(PersonalAudioItem)`) at service/UI boundaries and separate stores behind it. Build this in narrow slices, preserving Episode-only code paths until each is explicitly generalized.

**Two parallel player stacks:** smallest model coupling, but duplicates resume, remote controls, speed, interruptions, queue, and accessibility behavior. Not recommended because the product’s core promise is “same player.”

## File Storage Recommendation

- Copy user media into an app-managed `Application Support/PersonalAudio` directory with stable generated filenames. Store only the filename/relative key in the device-local SwiftData store; resolve it against the current container on each use, following the path-relocation convention in `DownloadPaths`.
- Mark the Personal Audio directory as included in normal iOS device backup by leaving `isExcludedFromBackup` false. Do not place it in `Documents/Downloads`, `Caches`, `tmp`, or any directory carrying the podcast-download exclusion. The original file is read-only from Earshot’s perspective and is never moved, edited, or deleted.
- **Restoration expectation:** when a user restores the app from a Finder/iTunes or iCloud device backup that contains the app’s Application Support data, the Personal Audio media directory and its device-local metadata should restore together; launch reconciliation then verifies each relative filename and byte record. If media restores without metadata or metadata without media, report unavailable items and clean only confirmed orphans according to a recovery policy. App Store reinstall without restoring a device backup does not restore local files. Earshot CloudKit sync does not restore Personal Audio records or bytes to another device, and merely signing into the same Apple Account is not sufficient. Verify the actual backup/restore behavior on supported iOS versions before promising it in user-facing copy.
- Do not reference external security-scoped URLs for ordinary playback. A saved bookmark is technically possible, but access can expire, the provider can move/remove the file, iCloud files can be evicted, and migrations/device changes complicate access. Copying matches the reliability requirement and ensures offline playback.
- Do not copy imported media to iCloud Drive or CloudKit in V1. Device backups may restore it, but cross-device library state is not guaranteed by that. Future sync should first sync metadata/identity/progress and present an explicit media transfer/re-download policy; CloudKit is not a suitable default transport for large audio binaries without product and quota design.
- Check available storage and source size when available, but do not declare an arbitrary maximum file size. Copy with bounded chunks off the main actor, report useful progress for long copies without noisy frequent VoiceOver announcements, support cancellation, verify copied bytes and hash, atomically move into final storage, and remove/reconcile staging files on launch. Ensure delete cleans media and model rows without deleting the user’s original.
- File disappearance/corruption should mark the record unavailable and offer “Remove from Earshot” or re-import; do not silently reset progress.

## Playback Integration

V1 must use existing `PlayerService` and controls. Introduce stable `PlaybackContentID`, `PlaybackContent` and metadata/source resolution interfaces at service boundaries. `PersonalAudioItem` playback resolves directly to its local file URL; RSS episode resolution retains download-preferred/stream fallback behavior. Keep exactly one `AVPlayer` engine and reuse remote commands, audio session, pitch algorithm, skip controls, sleep timer, Now Playing, and accessibility affordances.

Generalize the following explicitly:

- `PlayerService.play/load`, current-content identity, callback persistence, queue advancement/deletion, startup restoration, playback failure messages, completion threshold/state updates, Mark Played/Mark Unplayed, and remote Now Playing metadata. Reuse the current completion policy so users do not learn a content-type-specific definition.
- last-playing restoration storage so it can encode a namespaced stable ID (legacy feed/GUID identifiers still resolve unchanged).
- queue storage/repository/UI, Add/Remove, uniqueness, reordering where currently supported, restoration, and deletion safety. `QueueItem` needs a tagged content reference or equivalent stable namespaced identity; do not key a personal item by display filename or pretend it has feed URL/GUID. Existing RSS journal/projection logic must ignore Personal Audio explicitly.
- Played/progress persistence on `PersonalAudioItem`. Reuse the exact Episode completion threshold and played-state behavior after confirming the applicable helper path. Manual Mark Played and Mark Unplayed must work consistently.
- V1 excludes podcast-attributed listening statistics, Listening Places, donation attribution, and RSS/feed-specific CloudKit projection. If a general listening-history facility can represent non-podcast content without false attribution, document it as a separate future design decision.
- Folder runs and group playback need not support Personal Audio in V1; individual playback and full Queue support are required. State this limit clearly.

## Metadata Handling

Read common embedded title, artist, album, duration, and artwork via AVFoundation asset metadata. `ID3TagFetcher` and `ID3ChapterParser` already handle bounded ID3v2 tag reads for chapters, while current episode metadata otherwise comes from RSS. Do not promise that every container exposes equivalent tags. Use filename (without extension) as title when embedded title is missing or blank; show artist and album only when present; show “Unknown artist” only if a row layout requires a value, otherwise omit it; use Earshot’s normal placeholder artwork. Preserve the original filename as a secondary detail for support and a future rename/reset action. A later edit-title action should modify display metadata only, never the managed file name.

Duration should be loaded asynchronously and stored as optional; avoid blocking the main actor on large assets. Artwork should be bounded and cached separately (or transformed to a small app-owned thumbnail); don’t serialize full image bytes into the database. **Embedded chapters belong in V1:** `ChapterService` already reads local MP3 ID3v2 CHAP/CTOC tags through `ID3TagFetcher`/`ID3ChapterParser`, and MP4/M4A chapter metadata through `AVURLAsset.loadChapterMetadataGroups`. The small safe change is to pass a Personal Audio file URL/path into the existing local-file branch and key stale-result protection by stable namespaced content ID instead of GUID. There is no need to edit or persist chapters. Other formats remain best-effort pending device tests.

## Accessibility Requirements

- Standard system document picker and controls wherever possible.
- VoiceOver label includes item title and the context “Personal Audio”; value includes duration/progress and played state where appropriate. Avoid relying on section color/icon.
- **Add to Earshot** control has a specific label and hint; disabled/busy state is conveyed accessibly.
- Import status announces the start and meaningful milestones for long copies, then one final outcome; do not emit per-chunk announcements. Focus moves predictably to an import result/new item and returns sensibly on cancellation.
- Duplicate warning is a standard accessible confirmation: “This audio appears to already be in Personal Audio,” with **Add Anyway** and **Cancel**. Keep focus on the prompt and return it predictably after either action.
- Errors identify the problem and next action: unsupported type, cannot read, cannot play, storage unavailable, duplicate, or save failure.
- The Personal Audio section has a meaningful empty state and a direct Add action.
- Preserve all existing RSS episode VoiceOver labels, values, traits, rotor actions, and focus behavior byte-for-byte unless separately approved. Avoid whole-library SwiftData queries or synchronous duration/metadata reads that delay VoiceOver.

## Error Handling and Edge Cases

| Case | V1 behavior |
|---|---|
| Unsupported format / non-audio document | Filter in picker where possible; validate actual asset; explain supported audio expectation and leave no partial item. |
| Corrupt, truncated, encrypted, or no audio track | Reject after validation; keep original untouched; remove staged copy. |
| Extremely large file | Show byte size/progress when available; check free space; copy in bounded streaming chunks off the main actor; allow cancel; explain storage failure. No arbitrary file-size maximum. |
| Duplicate import | Calculate exact-content hash where practical; filename alone is never a duplicate. For exact match show “This audio appears to already be in Personal Audio” with **Add Anyway** and **Cancel**. Never silently reject or silently deduplicate. |
| Missing metadata/artwork | Filename-derived title, optional detail omission, standard placeholder artwork. |
| Import interrupted/failed | No visible partial row; clean or reconcile staging file on next launch; announce retry path. |
| Insufficient storage | Abort before finalization; preserve original; clean temporary copy; give device-storage guidance. |
| Deletion | Confirmation names the Personal Audio item; remove queue membership, folder membership, related local metadata, then media file with recoverable ordering. Failure to remove bytes should leave a cleanup marker for retry. Never delete original source. |
| Delete item currently queued | Remove it from Queue and advance/skip safely; announce removal. |
| Delete item currently playing | Confirm; stop/unload before deleting the file, clear last-playing restoration if it matches, then delete; do not leave AVPlayer holding a disappearing path. |
| Folder memberships | Add/remove multiple memberships; keep item visible in Personal Audio; deterministic focus after each change. Folder deletion removes memberships only. |
| Restore/change device | Normal device backup may restore app-container Application Support and device-local database data together; verify in practice and reconcile inconsistencies. Without a restoring device backup, another device receives no Personal Audio through Earshot CloudKit. Do not imply CloudKit sync occurred. |
| External file moved/deleted | No playback impact because Earshot owns a copy. |

## Version 1 Scope

- Single-file import from in-app Files picker.
- Common audio UTTypes exposed by iOS; validate with AVFoundation asset inspection and playable audio track. Confirm exact supported matrix through device tests before publishing it.
- Copy to durable app-managed folder; include in device backup; maintain stable relative filename.
- Extract title/artist/album/duration/artwork with filename/placeholder fallbacks.
- Library preview of the five most recently added items plus **View All Personal Audio**, with the preview count adjustable during implementation if accessibility/performance review requires.
- Separate `PersonalAudioItem`; extract available metadata/artwork and import embedded MP3/M4A chapters through the existing chapter infrastructure.
- Existing folder system with multiple memberships; remain visible in Personal Audio regardless of memberships; no folder-run playback requirement.
- Full normal Queue operations, stable namespaced identity, restoration, reordering where supported, and safe currently-playing/next-item deletion.
- Persist position/resume and played/unplayed/Mark Played/Mark Unplayed, using current Episode completion policy.
- Delete with safe behavior for queued/currently playing content.
- Exact content duplicate confirmation with **Add Anyway** and **Cancel**; matching filenames alone do not count.
- Keep Personal Audio models/files out of Earshot CloudKit and podcast statistics, Listening Places, and donation attribution.
- Check storage, show useful large-copy progress, allow cancel, copy off the main actor, and define no arbitrary size cap.
- Accessibility-focused status, errors, focus, and VoiceOver testing.
- Media stored in Application Support without backup exclusion; verify device backup/restore. Clearly state that Earshot CloudKit does not sync the feature.

## Future Enhancements

- Inbound share extension or app URL open for audio files (both route through the same importer service).
- Multiple selection/batch import after single-file progress, cancellation, and storage behavior are proven.
- Add from HTTPS URL, with secure transport, redirect and resource limits.
- Optional iCloud metadata/media synchronization with explicit quota, conflicts, device restoration, and eviction behavior.
- Rename display title, edit artist/album, custom artwork, richer sort/filter.
- Queue grouping, folder runs, a general listening-history design, widgets/App Intents and search for Personal Audio.
- Audio file export/share and backup-management settings.

## Planned Code Changes Beyond Phase 1

The following product surfaces and integrations remain for later phases:

- Extend the local V13 schema only for later folder-membership or tagged-queue records; `PersonalAudioItem`, the local/mirrored schema split, and the V12-to-V13 migration are implemented in Phase 1.
- Phase 2 implemented the Files picker, one-file import UI, progress/error/duplicate states, the accessible Library navigation row, the dedicated item list, local playback/restoration/chapters, played state, and deletion cleanup. Representative media format compatibility and VoiceOver behavior still need physical-device confirmation.
- Verify app-container backup and restored-store/media mismatch behavior on a physical device. The Phase 1 importer already provides bounded copies, exact hashing, backup inclusion attributes, staging cleanup, and orphan reconciliation; Phase 2 invokes reconciliation when the Personal Audio screen opens.
- Folder snapshots, pickers, repositories, memberships, and folder-specific counts remain deferred with Personal Audio folder membership.
- `QueueItem`/`QueueRepository`/`QueueScreen` generalization and mixed ordering remain deferred. Any later cloud queue journal/projection must exclude local-only Personal Audio.
- Phase 2 extends `PlayerService`, startup restoration, chapter display/navigation, `NowPlayingScreen`, and `NowPlayingBar` without changing Episode restoration encoding or podcast behavior.
- `Earshot/App/Info.plist` only when direct open/share is in scope. Files-picker V1 does not need document open registration. No entitlements change is expected for copying selected files; validate this against the chosen API and target settings during implementation.

## Migration Considerations

1. Additive schema migration only; do not alter/remove large Episode columns or relationships as part of Personal Audio.
2. V13 adds `PersonalAudioItem` to `DeviceLocal`; the mirrored model list remains unchanged. Prototype how future local Personal Audio folder-membership rows refer to mirrored `PodcastFolder` records without cross-store SwiftData relationships.
3. No backfill of existing episodes is needed. Legacy `lastPlayingEpisodeID` values must continue restoring through their current resolver while new namespaced Personal Audio IDs are added.
4. If Queue’s relationship shape changes, preserve existing queued Episode rows and ordering through an explicit migration/backfill or additive parallel reference strategy. The existing cloud queue journal remains episode/feed keyed and must never stage Personal Audio.
5. File-store versioning/reconciliation is independent from SwiftData schema. The current schema migration recovery snapshots cover the two database store files, not a future media directory. Keep media in the app container with normal backup inclusion; do not accidentally copy large media into migration working snapshots. Reconciliation must cope with database/media backup restore mismatches without silently deleting item records.
6. Test upgrades from the actual shipped schema routes using established fixtures and recovery strategy, plus real device backup/restore and second-device-without-restore cases.

## Testing Strategy

- Unit: supported-type policy, AVAsset metadata/chapter fallback, title normalization, exact hash duplicate policy, stable identity encoding, file naming, backup attribute, byte-copy/integrity, progress/cancel/error cleanup, cross-store folder key mapping, multiple memberships, queue identity/order, deletion resolution, completion/played/progress state, last-playing migration compatibility.
- Integration: import into temporary app storage + SwiftData; ensure failure cannot leave a visible item/orphaned final file; import exact duplicate; launch restoration; queue and folder membership; delete while queued/current.
- Migration: schema fixture upgrades and preservation of existing Episode/Queue rows, downloaded filenames, settings and current restoration keys.
- UI/accessibility: VoiceOver traversal/order and spoken “Personal Audio” distinction; Files picker cancel/success/errors; focus after import/delete/move; Dynamic Type; status announcements; large-library responsiveness against the existing high-volume fixtures.
- Device: representative MP3, AAC/M4A, WAV/AIFF and other proposed types selected from Files/iCloud Drive; embedded MP3 and M4A chapters; realistic large copies; offline playback; background/lock-screen controls; low-storage simulation; Finder/iTunes and iCloud device backup restore; second device with same Apple Account but no device restore. File type acceptance is confirmed only by asset and chapter tests on supported OS versions.
- Avoid changing existing episode announcements and accessibility tests. StoreKit suites and local Xcode caveats are unrelated to this feature.

## Remaining Technical Questions

1. What stable folder key can a `DeviceLocal` membership use to refer to a `PodcastFolder` stored in the mirrored store, and how will folder rename/delete notifications be reconciled? No direct cross-store SwiftData relationship should be assumed.
2. Can the added V13 entity be introduced into the local store while the mirrored schema version advances compatibly through the current multi-store migration routes? Verify using real V12 fixtures and both CloudKit-enabled/disabled configurations.
3. Does the existing generic player completion path apply to all Episode playback starts, including manual Mark Played/Unplayed, without triggering podcast-only queue/history side effects? Identify the narrowest safe shared seam.
4. How should mixed Queue order be represented locally so Personal Audio can interleave with RSS queue entries, restore after relaunch, and support current reorder operations while the RSS queue remains CloudKit mirrored? Define how concurrent RSS Queue changes and deletions reconcile without changing RSS CloudKit semantics.
5. Can the added V13 entities be introduced into the local store while mirrored schema changes (for folder stable keys, if needed) advance compatibly through current multi-store migration routes? Verify with real V12 fixtures and CloudKit-enabled/disabled configurations.
6. Does the existing Episode completion and manual Mark Played/Unplayed path apply without triggering podcast-only queue/history side effects? Identify the narrowest safe shared seam.
7. Which audio UTTypes/codecs pass playable-track validation on the minimum supported iOS version and current OS? Confirm with a physical-device compatibility matrix.
8. Can file coordination plus a cancellable bounded copy reliably report progress for local, iCloud Drive, and third-party File Provider selections without main-thread work?
9. Does ordinary iOS device backup include the chosen Application Support directory and local SwiftData store as expected, and what precise mismatch behavior occurs when only one restores?
10. Can local `ChapterService` support be invoked with a namespaced Personal Audio content ID with a small signature change, particularly its stale-result guard, or does hidden Episode ownership remain elsewhere in chapter/UI wiring?

## Recommended Implementation Sequence

1. Prototype the local-store/mirrored-folder identity bridge and a local mixed-queue ordering overlay; confirm the additive schema route. Write migration, folder, and queue tests before feature UI.
2. Prototype AVFoundation validation, metadata, embedded MP3/M4A chapters, cancellable copy progress, and exact hash detection on local files; establish the tested type matrix and storage behavior.
3. Implement app-owned storage and import transaction/reconciliation, including device-backup attributes and mismatch recovery.
4. Add `PersonalAudioItem`, stable namespaced identity, multiple folder memberships, and a five-item Library preview plus View All; verify very large podcast libraries stay responsive.
5. Generalize the player/queue boundary narrowly using a tagged content adapter; preserve RSS behavior, restoration, played threshold, all supported queue operations, chapters, and accessibility semantics.
6. Add robust deletion for current, next, and queued items.
7. Run migration, VoiceOver, large-copy/low-storage, and physical-device playback/chapter/backup tests.
8. After V1 is stable, consider direct open, Share Sheet, URLs, and sync as future importer front ends/capabilities.

## Implementation Readiness

### Phase 1 implementation boundary and repository findings (2026-09-27)

Phase 1 adds only the device-local data and import foundation. `PersonalAudioItem`
is in the local V13 schema; the mirrored V13 model list is byte-for-byte the V12
list. Storage uses generated relative filenames under Application Support,
explicitly enables ordinary device backup, copies in bounded chunks with a
streamed SHA-256, and reconciles interrupted staging/orphaned managed files only
after SwiftData opens. The importer validates a playable audio track, extracts
common metadata, bounded artwork and existing embedded chapters, and reports
exact-hash duplicates for Add Anyway/Cancel handling. No Library, Queue, or
player surface is changed in this phase.

The folder constraint is now confirmed in repository code: `PodcastFolder` and
its membership records are mirrored, while Personal Audio must remain local.
SwiftData cannot safely model a relationship across those two stores. Phase 1
therefore adds no Personal Audio folder field or membership workaround. For a
later phase, prototype an immutable UUID scalar on mirrored `PodcastFolder` and
a relationless local membership record containing that UUID; resolve folder
names and deletion/rename lifecycle through an explicit repository across the
two contexts. First prove the additive CloudKit schema and upgrade behavior in
both CloudKit-enabled and disabled configurations. Do not ship membership until
those lifecycle tests pass. Queue and player integration remain outside Phase 1.

### Final product decisions

- Feature name is **Personal Audio**; all user-facing import actions say **Add to Earshot**.
- V1 imports one item at a time from the Files/document picker, copies it to Earshot-managed storage, extracts metadata and embedded MP3/M4A chapters, and plays it through the normal player.
- The model is a separate `PersonalAudioItem`, with a shared playback-content abstraction at service/UI boundaries; no synthetic Podcast/Episode records.
- Library presents one **Personal Audio** navigation row above subscribed podcasts. Activating it opens the dedicated list; the list owns **Add to Earshot** and its accessible empty state. Personal Audio is not modeled as a Podcast.
- Personal Audio remains outside folders and mixed Queue in Phase 2. Local storage, namespaced current-item identity/restoration, resume, Mark Played/Unplayed, chapter navigation, Now Playing metadata, and safe deletion are implemented through the existing single player.
- Queue integration and Personal Audio folder membership are deferred until their cross-store and mixed-ordering designs have been proven in a later phase.
- Exact-content duplicates prompt with **Add Anyway** / **Cancel**. Filenames alone are not duplicate evidence.
- No arbitrary maximum size. Check storage, copy off the main actor with useful progress and cancellation, and test large files.
- Personal Audio remains out of Earshot CloudKit, RSS projections, podcast analytics, Listening Places, and donation attribution. It is expected to be included in ordinary device backup through app-container storage, subject to device verification; Earshot CloudKit does not provide cross-device Personal Audio sync.
- Share Sheet, direct open, URL import, and chapter editing are future scope.

### Prototype or repository investigation still required

- Resolve how a local-store Personal Audio folder membership can refer to mirrored-store folders without cross-store relationships. A stable folder UUID/key bridge is the leading option but needs a migration and lifecycle prototype.
- Resolve mixed Queue ordering and restoration across the mirrored RSS queue and device-local Personal Audio queue without leaking personal identities into CloudKit.
- Prove V12-to-next-schema migration for both store configurations and CloudKit enabled/disabled setups.
- Validate file types, AVAsset metadata, MP3/M4A chapter loading, very large file progress/cancellation, and iOS device-backup restoration on physical devices.
- Confirm the current completion/Mark Played paths can be reused without invoking podcast-only attribution and RSS queue projection behavior.

### High-risk areas that need tests first

- Two-store SwiftData migration and folder identity/membership mapping.
- Mixed local/CloudKit Queue ordering, restoration, and reordering while preserving every existing queued Episode and cloud reconciliation semantics.
- Playback startup restoration and deletion while the item is current, next, or queued; no stale player URL or last-playing ID.
- File/database transaction recovery when import, save, app termination, deletion, or device restore leaves only one side present.
- No regression to current podcast VoiceOver speech, focus behavior, large-library launch/navigation responsiveness, completion threshold, or RSS CloudKit projection.

### Phase 2 implementation status (2026-09-27)

The Library now has a single Personal Audio destination row before the existing
podcast snapshot. The destination lists all local items and contains the Files
picker, import status, duplicate confirmation, playback actions, and confirmed
deletion. The five-item inline preview and **View All Personal Audio** design
were replaced by the later approved navigation adjustment.

Personal Audio loads through the existing `PlayerService` and AVPlayer. A tagged
`PlaybackContentIdentity` uses the unchanged Episode restoration values and the
`personal-audio:` namespace for local items. Durable anchors update the local
model; five-second crash recovery uses the existing live-position key without
CloudKit projection or podcast listening-session attribution. Local chapter data
uses the existing chapter controls and skip behavior. Deletion clears matching
current/restoration state, removes the managed copy, and leaves the Files source
untouched; startup reconciliation removes orphaned managed files.

Automated Phase 2 tests cover namespaced restore and live position recovery,
paused load/resume/seek, played/unplayed state, current-item deletion and source
preservation, item-count presentation, and regression suites for podcast restore,
position persistence, Library snapshots, Now Playing artwork, and player audio
sessions. The Personal Audio row exposes Play now, Mark as played/unplayed, and
Delete through the shared VoiceOver Actions rotor; the touch Actions menu remains
available, and podcast actions are unchanged. Existing MP3 chapter parser and
chapter navigation suites remain part of the required regression run. A real Zoom `.m4a`, representative `.mp3`, lock
screen controls, VoiceOver traversal, and device backup remain physical-device
checks; no suitable Zoom recording is present in the repository.

#### Physical-device checklist

1. Import a real Zoom-generated `.m4a` from Files and confirm it plays without conversion.
2. Import and play an `.mp3` file.
3. Seek forward and backward, change speed, and pause/resume.
4. Background Earshot and operate play, pause, and skip from the lock screen.
5. Return to Earshot and confirm the saved position; force quit, relaunch, and confirm paused restoration at the same position.
6. Mark each item Played and Unplayed and confirm progress resets appropriately.
7. Use a file with chapters to navigate chapters; confirm a file without chapters still plays normally.
8. Delete the Earshot copy and verify the original source still exists in Files.
9. With VoiceOver, verify Library → Personal Audio → item hierarchy, picker return, progress/errors/duplicate confirmation, and focus after import, cancellation, and deletion.

Phase 2 intentionally does not implement mixed Queue integration, Personal Audio
folder membership, CloudKit sync, direct-open/share extensions, URL/batch import,
metadata editing, artwork editing, or podcast analytics/donation attribution.

## References

Repository findings are based on the paths cited above. Apple’s document picker provides security-scoped URLs and requires access coordination for external files; copying on import is the recommended reliability fit here: [UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpicker) and [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories). Apple lists AVFoundation-recognized media types such as MP3, WAV, and AIFF, but the app should validate a selected asset and playable audio track rather than treating a container list as a guarantee that every encoded file is playable: [AVFileType](https://developer.apple.com/documentation/avfoundation/avfiletype) and [Media types and utilities](https://developer.apple.com/documentation/avfoundation/media-types-and-utilities).
