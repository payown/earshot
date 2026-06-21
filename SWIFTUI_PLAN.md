# Earshot SwiftUI Conversion Plan

Living task log for the SwiftUI rebuild on the `swift` branch. Maintained by the
Planning Agent. The Flutter app (`lib/`, `ios/`, `tool/`) and TestFlight are
read-only references — never modified, never deployed from this branch.

## Status Legend
- [ ] Pending
- [~] In progress
- [x] Verified and closed
- [!] Blocked

## Feature Build Order

| # | Feature | PRD Section | GH Issue | Status | Notes |
|---|---------|-------------|----------|--------|-------|
| 1 | F1 Foundation — feature-first restructure, test target, shared scheme, os.Logger | CLAUDE.md conventions | #336 | [x] | Done. Layout under `EarshotSwift/Earshot/`, test target + shared scheme, AppLog. 5 tests green. |
| 2 | F2 Data — full SwiftData model graph + VersionedSchema + migration plan | PRD 5 / data | #337 | [x] | Done. 10 @Model types, EarshotSchemaV1 + migration plan, container factory w/ in-memory fallback, AppSettingsStore. 15 tests green. |
| 3 | F3 Core — networking, feed parser, theme tokens, a11y helpers | PRD 4, 7, 8 | #338 | [x] | Done. HTTPClient, extended RSSParser (iTunes + podcast namespaces), Spacing/AppColor, Announcer/Motion. 24 tests green. |
| 4 | Subscriptions — library, add feed, episode list w/ artwork + refresh | PRD 5.1 | #339 | [x] | Done. SubscriptionRepository (subscribe/refresh/refreshAll + high-water mark), artwork, pull-to-refresh, podcast-detail header. mobile-accessibility reviewed: 3 errors + warnings fixed. 28 tests green. |
| 5 | Playback — engine, Now Playing, lock screen + remote commands | PRD 5.5 | #340 | [x] | Done. PlayerService (AVPlayer, skip, remote commands, MPNowPlayingInfo), NowPlayingBar mini-transport. mobile-accessibility: 2 errors + 2 warnings fixed (commit 5db83b6). Build + 43 tests green. Full-player screen deferred — see decisions. |
| 6 | Queue — reorder/remove/move, groups, gapless | PRD 5.3 | #341 | [x] | Done. QueueLogic (20 tests), QueueRepository (13 tests), QueueScreen UI + VoiceOver, gapless preload + auto-advance (PlaybackLogic.nextUpID, 4 tests). 80 tests green. Within-group reorder + auto-queue refresh enrollment noted as follow-ups. |
| 7 | Quick Actions — VoiceOver rotor + configurator (3 sets) | PRD 5.4 | #342 | [x] | Done. 3 sets (Episode/Podcast/Queue) persisted in QuickActionConfig; 3-section configurator; rotors wired into episode/podcast/queue rows. mobile-accessibility: unsubscribe confirm + position-aware configurator labels. 93 tests green. Deferred actions documented. |
| 8 | Downloads + Inbox + queue expiration | PRD 5.2, 5.3 | #343 | [x] | Done. InboxLogic+Repository (caps, one-directional dismiss), ExpirationService (7-day RecentlyExpired + restore), DownloadManager (Wi-Fi gated). Inbox + Downloads tabs. Download added to episode rotor. mobile-accessibility: clear-inbox confirm + focus, days-left announce. 117 tests green. Auto-download-N-on-subscribe deferred. |
| 9 | Settings — all screens + documented prefs | PRD 7, 9 | #344 | [x] | Done. SettingsStore (bindable) + SettingsScreen (playback/general/inbox/downloads/history/privacy/accessibility/data), OPML export, factory reset. Settings tab replaces Actions (Quick Actions nested). mobile-accessibility: spoken picker labels, hints, post-reset announce. 122 tests green. |
| 10 | Search + OPML import/export | PRD 5.7, 5.1 | #345 | [x] | Done. SearchView (grouped local + iTunes directory), SearchLogic, OPML import with nested folder->PodcastFolder mapping, OPML export (F9). mobile-accessibility: header traits, nil-safe labels, announcements. 128 tests green. Per-screen context-aware scoping deferred. |
| 11 | Folders — grouping + per-folder queue age limit | PRD 5.2 | #346 | [x] | Done. FolderRepository (create/rename/delete, reorder folders + members, add/remove/setMemberships, unfiled), FolderLogic (age-limit filter), FoldersScreen + FolderDetailScreen + FolderPodcastPickerView, reached from Podcasts toolbar. Per-folder queue age limit filters latest-unplayed-per-podcast on "Add folder to queue". Resolves the F2 follow-up: memberships are cleaned up before podcast delete (no cascade from Podcast side). mobile-accessibility: picker `.isToggle` state announce, EditButton for member reorder, author in row label. 142 tests green. |
| 12 | Bookmarks — saved timestamps | PRD 5.5 | #347 | [x] | Done. BookmarkRepository (add/list-by-position/delete) + BookmarkLogic (clock + spoken time). Create from the Now Playing bar's new bookmark button; per-episode BookmarksListView (jump-to-position + delete) opened via a new `.viewBookmarks` episode Quick Action (wired into all 4 episode surfaces). Search bookmark rows now actually seek to the saved spot. PlayerService gains `nowPlayingEpisode` + `play(_:at:)`. mobile-accessibility: @State-backed list refresh after rotor delete, spoken "no episode playing" on empty, ViewThatFits reflow so 4 transport buttons keep 44pt at AX type. 8 bookmark tests; 150 total green. |
| 13 | Stats — listening stats, retention, CSV export | PRD 5.9 | #348 | [x] | Done. PlayerService now records ListeningSession rows (accumulates plausible position steps, drops seeks via StatsLogic.isListeningStep, flushes every 30s + on pause/stop/switch). StatsRepository aggregates total/time-saved-by-speed/per-podcast/episodes-completed/opt-in streak per period; applyRetention (on launch) + deleteAllHistory + CSV export. StatsScreen reached from Settings > History. Streaks opt-in (off by default, new setting). mobile-accessibility: announce stats change on period switch, deferred post-delete announce, disabled-export hint, empty-state leads. Time-saved-by-silence-trim deferred (model carries no trimmed-seconds). 12 stats tests; 162 total green. |
| 14 | Chapters + sleep timer + audio enhancements | PRD 5.5, 5.6 | #349 | [~] | Chapters + sleep timer DONE + tested; audio-enhancement DSP DEFERRED (see decision). ChapterParser (PC2.0 JSON + description timestamps, pure/tested) + ChapterService (adds AVAsset embedded/ID3 chapters). SleepTimer presets/extend/cancel/end-of-episode with pure SleepTimerLogic + SleepTimerController (tested); wired into PlayerService (fade-pause on expire, stop-not-advance on end-of-episode). PlayerControlsSheet (sleep timer + chapter jump) opened by tapping the Now Playing bar. mobile-accessibility: coarse spoken countdown (no per-second spam), .isSelected current chapter (no empty value node), explicit button trait. 19 chapter/sleep tests; 181 total green. |
| 15 | Onboarding — 7 screens, contextual tips, app icon | PRD 6 | #350 | [x] | Done. OnboardingView (7 pages: Welcome/Content flow/Privacy/Quick Actions/Queue expiration/Add first podcast/All set), shown via fullScreenCover on first launch, Skip + Back/Next, "Start Listening" gated on >=1 podcast, sets onboarding_complete. Contextual tips: TipCategory + persisted TipsStore (once-per-category) + dismissable .contextualTip banner on Inbox/Queue/Downloads with polite announcement. App icon: new Assets.xcassets/AppIcon (1024, single-size) wired via ASSETCATALOG_COMPILER_APPICON_NAME. mobile-accessibility: hide non-current pages, move focus to new page heading, position folded into heading label, delayed tip announce. 8 onboarding/tips tests; 189 total green. |
| 16 | Polish — performance + full VoiceOver / Dynamic Type audit | PRD 7, 8 | #351 | [x] | Done. Full mobile-accessibility sweep across Inbox/Queue/Downloads/Settings/Episode screens (the rest reviewed at build time): focusable empty states, header trait on the right node, hidden duplicate buttons in combined rows, removed footer-duplicating hints, pluralized values. Reduce Motion: onboarding + tip animations gated via Motion.preferred. Perf: fixed O(n²) fetch in FolderRepository.unfiledPodcasts. Final report at docs/swiftui-accessibility-audit.md. 189 tests green. |

Deferred (folded into the nearest feature or appended as issues once prerequisites
land): Transcripts (5.6), Local audio import (5.8), Notifications (5.10), Sharing /
Universal Links (5.11).

## Phase 2

Phase 2 = immediate fixes, the Flutter→SwiftUI migration, and audio DSP (#352).

| Item | GH Issue | Status | Notes |
|------|----------|--------|-------|
| Fix A — app icon on device | — | [x] | No-op. Icon config verified correct (1024² source, Contents.json, `ASSETCATALOG_COMPILER_APPICON_NAME`). Confirmed working on device by Michael; no code change. |
| Fix B — tab order + Library rename | #353 | [x] | Reordered to Inbox/Queue/Library/Downloads/Settings; `books.vertical` icon; renamed Podcasts→Library in tab label, `SubscriptionsView` title, refresh announcement, and reset category label. Search results "Podcasts" header left as-is (result category, not tab). 189 tests green. Commit c363675. Awaiting device verification. |
| Fix C — artwork not loading on device | — | [x] | Skipped. Artwork confirmed working on device by Michael. (Investigation noted a latent gap: RSSParser reads `itunes:image` only, not the standard `<image><url>` channel-art fallback — file an issue if any feed surfaces it later.) |
| Migration — Flutter→SwiftUI subscription import | #354 | [~] | SwiftUI signing-independent layer DONE: `MigrationGate` (gate + 3-reminder cap), `FlutterMigrationService` (reads `SELECT rss_url FROM podcasts` from `earshot_export.db` via `import SQLite3`, no-ops if absent), beta-gated `MigrationPromptView` wired into RootView, dedicated **Beta** build config (`IS_BETA_BUILD` in Debug+Beta, not Release). 10 new tests (real temp SQLite DB + mocked feed). Release build confirmed to exclude the sheet. mobile-accessibility reviewed (iOS-001 announcement lifecycle + 5 more fixed). **Deferred:** App Group entitlement (`Earshot.entitlements`) — needs the group registered to team 72PH974742 and matched on the Flutter app; can't be verified in CI. Until it lands, the container URL is nil and migration no-ops. See Flutter-side tasks below. |
| Audio DSP | #352 | [~] | DONE pending device verify. `AudioEnhancementLogic` (pure mode/channel mapping, tested both ways). `configureSession` now conditional on `voiceEnhanceEnabled` (was hardcoded `.spokenAudio`); `applyAudioEnhancement()` sets mode + `setPreferredOutputNumberOfChannels` (1 mono / 2 stereo); all `AVAudioSession` calls in do/catch + `AppLog.player` (no silent `try?`). Public `effectiveRate` + `reapplyRate()`. RootView `.onChange` re-applies global speed + voice-enhance mid-playback (observation-based, not NotificationCenter). Per-podcast `speedOverride` has no setter UI yet (deferred F7) — `reapplyRate()` ready for it. Mono is audible only on device. |

### Migration — Flutter-side tasks (document-only; NOT done, no Flutter files touched)

These must ship in a Flutter release before migration can be tested end-to-end.
The SwiftUI side is built and waiting.

1. **Add the App Group to the Flutter app.** Add `group.media.payown.earshot` to the
   Flutter iOS entitlements (`ios/Runner/Runner.entitlements`) under
   `com.apple.security.application-groups`. Register the group in the Apple
   Developer portal for team 72PH974742. Re-sign and re-distribute.
2. **Add the matching App Group to the SwiftUI app** (the deferred entitlement):
   create `EarshotSwift/Earshot/App/Earshot.entitlements` with the same group and
   reference it from `project.yml` (`entitlements:` on the Earshot target), then
   `xcodegen generate`.
3. **Flutter writes the export DB on launch.** On launch, the Flutter app copies
   (or hard-links) `<sandbox>/Documents/earshot.db` to
   `group.media.payown.earshot/earshot_export.db` in the shared container. The
   SwiftUI reader expects the drift `podcasts` table with the `rss_url` column
   (drift v16 schema — confirmed against `lib/data/db/tables/podcasts.dart` +
   generated SQL).
4. Until 1–3 ship, OPML import (Settings) is the manual fallback, surfaced in the
   prompt's "Export my subscriptions as OPML" instructions.

## Swift 6 Migration

Step 1 = surface and clear all `complete` strict-concurrency warnings in Debug,
**without** raising `SWIFT_VERSION` to 6 yet. Step 2 (later) flips
`SWIFT_VERSION: 6` and fixes the remaining errors. One GH issue per subsystem;
`earshot-swift6` gate on each.

- **Flip (commit feb429a):** `SWIFT_STRICT_CONCURRENCY: complete` set in the
  Debug config only (project-level `settings.configs.Debug`). Base, Beta, and
  Release stay `minimal`. `SWIFT_VERSION` stays 5.0. Baseline: 86 unique
  warnings, 0 errors, build succeeds.

| Subsystem | GH Issue | Status | Notes |
|-----------|----------|--------|-------|
| Persistence — non-Sendable KeyPaths + schema versionIdentifier | #357 | [x] | Done (commit 6ecbd80). `versionIdentifier` made computed (values unchanged); `sendableKeyPath` helper (layout-preserving marker-protocol cast, stored-property-only per doc precondition) at SortDescriptor/@Query sites. All 5 gates passed. 204 tests. **4 warnings remain by design:** Apple `#Predicate`-macro-internal `KeyPath<Model,String>` Sendable (AppSettingsStore ×2, PlaybackStartup, SubscriptionRepository) — unfixable at source until a newer SDK; revisit at the Step 2 flip. |
| Player — `sending 'note'` data races in PlayerService NC observers (+ trivial ChapterParser unused var) | #358 | [x] | Done. NC observers extract Sendable `UInt?` values on `.main` before the `@MainActor` Task; handlers re-typed to take raw values. Behavior preserved. Gates passed. |
| Subscriptions — `sending 'self.feed'` data races in SubscriptionRepository | #359 | [x] | Done. `FeedFetching: Sendable`; `FeedService: @unchecked Sendable` (value type, all stored state Sendable down to URLSession). Test fallout fixed (FakeFeedFetcher `@unchecked Sendable`). Gates passed. |
| Migration — main-actor static props from nonisolated context in FlutterMigrationService | #360 | [x] | Done. `appGroupID`/`exportDBName` → `nonisolated static let`. No entitlement/behavior change. Gates passed. |
| Test target — strict-concurrency warnings in StoreMigrationTests + FolderRepositoryTests | #361 | [x] | Done. `nonisolated(unsafe)` on serially-accessed test scaffolding; `sendableKeyPath(\Episode.guid)` in test FetchDescriptor; dropped unused binding. Surfaced once `xcodebuild test` compiled the test target under `complete`. Gates passed. |

**Step 1 status: COMPLETE.** Debug strict-concurrency clean (204 tests pass, 0
errors) except the 4 Apple `#Predicate`-macro-internal `KeyPath<Model,String>`
warnings, which are unfixable at source. Per plan, STOP and report before
considering the Step 2 `SWIFT_VERSION: 6` flip (that flip turns the 4 macro
warnings into errors and needs a separate decision / newer-SDK check).

Non-blocking follow-up (from testing gate): extract pure
`PlaybackLogic.interruptionAction(...)`/`routeChangeAction(...)` so the
PlayerService interruption/route mapping becomes unit-testable (currently the
private AVFoundation handlers can't be covered without restructuring).

## Decisions Log

- **Decision:** Feature-first layout `Earshot/Features/<feature>/{Data,Domain,Presentation}`, migrating the flat `EarshotSwift/Sources/` slice. **Reason:** documented CLAUDE.md standard; cheap while small. **Issue:** #336.
- **Decision:** Clean, versioned, migratable SwiftData store; no Flutter(drift/SQLite)→SwiftUI import for now. **Reason:** the `.swift` bundle id installs alongside Flutter in a separate sandbox and can't see `earshot.db`; cross-engine import is a future task. **Issue:** #337.
- **Decision:** Full model graph defined up front behind a VersionedSchema before feature UI. **Reason:** SwiftData "define all models before UI" rule; keeps later migrations lightweight. **Issue:** #337.
- **Note:** Live Flutter drift schema is version 16 (not 12). The SwiftData model graph mirrors v16.
- **Note:** The 42 existing open GitHub issues are the Flutter production backlog. They are left untouched (not relabeled/closed) per the "never close without confirmation" rule. SwiftUI work is tracked under new `[SwiftUI]` issues #336–#351.
- **Decision:** The feature-first source tree lives at `EarshotSwift/Earshot/` (co-located with `Earshot.xcodeproj`), not at the repo root as CLAUDE.md's diagram shows. **Reason:** keeps XcodeGen source paths relative and simple; avoids cross-directory project references. The `Earshot/Features/...` convention itself is honored. **Issue:** #336.
- **Note:** No `iPhone 16` simulator is installed on this machine; verification uses `iPhone 17`. Build/test destination: `platform=iOS Simulator,name=iPhone 17`.
- **Decision (F2):** SwiftData unit tests share ONE in-memory `ModelContainer` per process (`TestStore`, wiped between tests) instead of creating a container per test. **Reason:** rapidly creating many in-memory containers for the same schema in one test process crashes with an `EXC_BREAKPOINT` in `context.insert` (toolchain/SwiftData issue, reproduced and bisected). The real app uses a single container, so it is unaffected. The test host also uses a throwaway placeholder container during XCTest. **Issue:** #337.
- **Decision (F2):** The model graph keeps cascade collections only on `Podcast.episodes`, `Episode.bookmarks`, `Episode.queueItem`, `Episode.recentlyExpired`, and `PodcastFolder.memberships`. `ListeningSession` and `FolderMembership` reference their parents via plain to-one relationships, so deleting a Podcast does NOT auto-cascade its listening sessions or folder memberships. **Reason:** keeps the relationship graph simple. **Follow-up:** Stats (#348) and Folders (#346) must clean up orphaned `ListeningSession`/`FolderMembership` rows on podcast/episode delete.
- **Decision (F5):** Play/pause control uses a stable VoiceOver name ("Play or pause") with the live state carried by `accessibilityValue` ("Playing"/"Paused") plus an `Announcer` announcement on transition — rather than flipping the label and the value together. **Reason:** a stable name keeps the control predictable for screen-reader and Voice Control users; flipping both double-states the condition. Per independent mobile-accessibility review of #340. **Issue:** #340.
- **Decision (F5):** F5 delivers the playback engine + lock-screen/remote commands + a compact `NowPlayingBar` mini-transport only. A full-screen Now Playing view (scrubber, expand-from-bar affordance, speed, chapters, sleep timer) is NOT built and the bar has no tap-to-expand. **Reason:** those controls belong to later feature rows (scrubbing/speed + Chapters/sleep timer #349). **Follow-up:** when the full player lands, give `NowPlayingBar`'s title/artist element `.isButton` + an open-full-player action so VoiceOver users get the same affordance as sighted users (mobile-accessibility iOS-003).

- **Decision (F6):** Grouped-by-podcast view reorders at the group level only (header "Play group" = bring group to front); per-row move-to-top/up/down/bottom are offered in flat mode only, where position is unambiguous. **Reason:** flat moves operate on the global queue while the grouped list re-sorts, so mixing them per-row is confusing and was a VoiceOver blocker. **Follow-up:** within-group reorder (QueueLogic.moveUp/DownWithinGroup are written + tested but not yet wired to repo/UI) can land later if needed. **Issue:** #341.
- **Decision (F6):** `markPlayedAndRemove` does not reset `positionSeconds` (mirrors Flutter — position-zeroing is owned by the playback/position tracker, not queue removal); `cancelFromQueue` and `clear` revert episodes to `newEpisode` so they return to the inbox. **Issue:** #341.
- **Note (F6):** Auto-queue *enrollment* (new episodes from auto-queue podcasts skipping the inbox straight into the queue) is a refresh-time concern. The queue repository provides the enqueue primitive; wiring it into SubscriptionRepository.refresh / inbox is a thin follow-up tracked with F8 inbox work, not done in F6.
- **Note (F6):** `QueueRepository.orderedItems()` deletes orphan (nil-episode) queue items on read so the displayed list and the reorder domain are always the same set — defends against the aged-data scenario the DB-migration rules warn about.

- **Decision (F7):** Each Quick Action set lists only actions whose backing feature exists today. Deferred: episode download/bookmark/delete (F8/F12), podcast per-setting editors changeDownloadCount/changeQueueAgeLimit/editSpeed (F9). They join their set when those features land — no rotor action is ever a dead no-op. **Issue:** #342.
- **Decision (F7):** Podcast rows are navigation rows: tap opens detail, so `openDetail` is excluded from the podcast rotor (adding it would double-navigate). The configured order drives the rotor; the row tap is always open-detail. **Issue:** #342.
- **Note (F7):** Queue-row "Remove from queue" is exposed both in `accessibilityActions` (config-ordered rotor) and `.swipeActions` (sighted). iOS may surface the swipe action into the rotor too, so it could double-list — verify on device and de-dupe if confirmed. **Issue:** #342.

- **Note (F8):** Auto-download of the most-recent N episodes on subscribe / new-episode (PRD 5.2, `autoDownloadCount`) is a refresh-time enhancement not wired in F8. DownloadManager provides the primitive (and the Download rotor action); enrolling new episodes automatically is a thin follow-up on SubscriptionRepository.refresh.
- **Decision (F8):** Inbox count cap uses the per-podcast `inboxMaxEpisodes` only (no global default key in the SwiftUI settings yet), matching PRD "default off." Caps dismiss overflow one-directionally (never un-dismiss). **Issue:** #343.

- **Decision (F9):** The standalone "Actions" tab is replaced by a "Settings" tab; Quick Actions config is a NavigationLink inside Settings. **Reason:** keeps 5 top-level tabs (Inbox/Podcasts/Queue/Downloads/Settings) and matches the PRD nav where Settings contains all configuration. **Issue:** #344.

- **Decision (F10):** Search is a single dedicated grouped screen (Podcasts/Episodes/Bookmarks + iTunes directory under "Search Everywhere"), reached from the Podcasts toolbar. PRD 5.7's per-screen context-aware scoping (search-in-queue searches queue, etc.) is deferred as a `.searchable` follow-up on each list; the grouped global screen meets "grouped results with accessible structure." **Issue:** #345.
- **Note (F10):** OPML import maps nested outline groups to `PodcastFolder` + `FolderMembership` directly (the models exist); the full Folders UI/management is F11. Export lives in Settings (F9); import added there too.
- **Decision (F11):** The per-folder `queueAgeLimitDays` filters which episodes are added when a folder is queued ("Add folder to queue" → newest unplayed per member podcast, skipping any older than the limit), matching the Flutter behavior. It does NOT drive the per-podcast `QueueExpirationService` (that stays keyed on `Podcast.queueAgeLimitDays`). A `days` of 0 or empty clears the limit. **Issue:** #346.
- **Decision (F11):** Resolves the F2 orphan follow-up by cleaning up `FolderMembership` rows *before* deleting a podcast (`removeFromAllFolders` in the unsubscribe/delete paths), not lazily afterward. SwiftData does not nullify the plain to-one `FolderMembership.podcast` on delete — a leftover row keeps a dangling reference that traps when accessed — so proactive cleanup is the only safe option short of changing the model graph. **Issue:** #346.
- **Decision (F12):** Bookmarks are surfaced two ways: created from the Now Playing bar (current position) and listed per-episode via a new `.viewBookmarks` episode Quick Action. The action is added to `EpisodeAction` (appended for existing users by `QuickActionRepository.resolve`) and threaded through all four episode surfaces (episode list, inbox, downloads, search) as `onBookmarks`, so it's never a dead no-op (F7 rule). Jump-to-bookmark uses a new `PlayerService.play(_:at:)`; the pre-existing Search bookmark row that played without seeking was fixed to use it. **Issue:** #347.
- **Decision (F13):** `ListeningSession` rows were not written by anything before F13; the player now records them. Recording accumulates per-tick content-position advances and writes one session per ~30s of real listening (and flushes on pause/stop/episode switch), with forward skips and seek-backs filtered out by `StatsLogic.isListeningStep` (step must be 0 < x <= 10s). This is more honest than the Flutter tracker, which records raw position deltas. Time saved is speed-only (`duration * (1 - 1/speed)`); time-saved-by-silence-trim is deferred because `ListeningSession` carries no trimmed-seconds field (adding it is a schema change). Streaks are opt-in via a new `stats_streaks_enabled` setting (off by default) and only computed when enabled. Retention reuses the existing `history_retention_days` setting, applied on launch. **Issue:** #348.

- **Decision (F14):** Chapters (PC2.0 JSON + embedded AVAsset/ID3 + description-timestamp fallback) and the sleep timer (all presets, extend +5, end-of-episode) are implemented, wired, and unit-tested. **Audio-enhancement DSP (skip silence / voice boost / mono) is deferred.** Native AVPlayer has no API for these; they require an `MTAudioProcessingTap` (audio-render-thread C interop) that cannot be device-verified in the build/test environment, and a faulty tap crashes the render thread — exactly the kind of un-recoverable failure the DB-migration rule warns against shipping unverified. The Flutter app's own iOS build doesn't apply these either (they're Android-only there — see its `player_screen.dart` comments), so this is not a parity regression. The existing Settings toggles (`skip_silence_enabled`, `voice_enhance_enabled`) persist and are ready to wire when the tap lands on-device. **Follow-up:** implement `MTAudioProcessingTap`-based mono + gain (and evaluate skip-silence) in a focused, device-verified PR. **Issue:** #349.

- **Decision (Naming):** "Library" is the **established, intentional** name for the subscriptions / podcast list (the tab, `SubscriptionsView` title, related announcements). Users are already used to it — do not rename it. The PRD's use of "Library" for local audio import (PRD 5.8) is a naming conflict, resolved here in favor of the existing user vocabulary: the subscriptions list keeps "Library," and local audio import — **if** it ships — will be called **"Local Audio,"** not "Library." Documentation-only; no code change.

## Swift 6 Review — Issues #358, #359, #360, #361

- **Mode:** `SWIFT_STRICT_CONCURRENCY: complete` (Debug), `SWIFT_VERSION: 5.0`. Full `xcodebuild test` independently confirmed TEST SUCCEEDED, 204 tests, 0 errors, only the 4 known `#Predicate`/`@Query` `KeyPath<Model,String>` Sendable warnings remain (issue #357, unfixable at source).
- **Result: PASS.** All eight concurrency-checklist items pass; no `@unchecked`/`nonisolated(unsafe)` hides a real race.
- **#358 PlayerService:** NC observer closures run on `.main`, extract `UInt?` raw values from `Notification.userInfo` before the `@MainActor` Task; no `Notification` (non-Sendable) crosses the boundary. Handlers re-typed to `(typeValue:optionsValue:)` / `(reasonValue:)`. Only callers are the two closures. Guards and behavior preserved. ChapterParser: dead `i` from `enumerated()` removed, no impact.
- **#359 SubscriptionRepository:** `FeedFetching: Sendable` is correct — `fetch` is `nonisolated async`, so the `@MainActor` repo sends the conformer off-actor. `extension FeedService: @unchecked Sendable` is sound: `FeedService` is a struct whose only stored prop is `HTTPClient` (struct wrapping a Sendable `URLSession`). Plain `Sendable` would also have worked, but `@unchecked` in the declaring extension is required since the conformance can't live in FeedService.swift; harmless and documented. Single conformance, no duplicate-conformance risk under Swift 6.
- **#360 FlutterMigrationService:** `appGroupID`/`exportDBName` → `nonisolated static let` correct and required so the existing `nonisolated static var sharedDatabaseURL` can read them off the `@MainActor` class. Plain `String` constants, Sendable.
- **#361 Tests:** `FakeFeedFetcher: @unchecked Sendable` — justified; mutable `feed` only reassigned and read serially inside `@MainActor` tests, `fetch` returns synchronously, no concurrent access. `StoreMigrationTests` `dir`/`storeURL` → `nonisolated(unsafe) var` — justified; XCTest setUp→test→tearDown is serial with happens-before, and the override points are `nonisolated` so MainActor isolation can't apply. `sendableKeyPath(\Episode.guid)` — `unsafeBitCast` to `KeyPath & Sendable` is a layout-preserving no-op; precondition (stored-property key path) holds for both `Episode.guid` and `PodcastFolder.sortOrder`. FolderRepositoryTests: dropped unused `loose` binding (side-effecting `makePodcast` call retained), added behavior-neutral sort assertion.
- **Swift 6 forward-compat:** All constructs are already Swift-6-valid (they're the Swift-6-style fixes). Nothing here becomes an error when `SWIFT_VERSION` flips to 6. The 4 remaining #357 warnings are the only items that would become errors — tracked separately, not in scope of these issues.
- **New agents created:** none.

## Blockers

None. (F14 audio-enhancement DSP intentionally deferred — see Decision F14.)
