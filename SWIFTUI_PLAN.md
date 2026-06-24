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
| BUG — tab switching blocked during playback | #362 | [x] | Per-second synchronous main-actor SwiftData `context.save()` from the 1s time observer starved the run loop, freezing TabView selection while audio played (severe VoiceOver nav regression). Fixed by throttling the per-tick position write to a 5s cadence via pure `PlaybackLogic.shouldPersistTick`; eager saves on pause/seek/episode-switch/30s-flush keep durability. All gates passed (security, testing, swift6, changelog; a11y N/A — no view changed). 210 tests green (was 204). Branch `fix/issue-362-tab-switching-playback`. Awaiting device verification. |

**Non-blocking follow-up (from #362 security gate, NOT done — file if it surfaces):**
`PlayerService.persistPositionThrottled` (and the prior per-second save) lacks an
`isPlayed` guard, so a tick after the 95% played threshold could rewrite a stale
non-zero `positionSeconds` over the just-zeroed value. Pre-existing, cosmetic
(episode is already played; end-of-item resets to 0 anyway), out of scope for #362.

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

- **Issue #418 (Settings — Send Feedback recipient):** Changed the feedback recipient from `beta@payown.media` to `michael@payown.media`. **Implemented by:** planning agent (one-word/string-constant change, no domain logic). **Reviewed by:** earshot-security (PASS), earshot-accessibility (PASS — VoiceOver hint now reads "Opens an email to michael at payown dot media"), earshot-testing (PASS — 438/438, Release build clean), earshot-changelog (entry under Fixed; also corrected the unshipped #392 Added line). Touches `FeedbackComposer.recipient`, the `SendFeedbackView` doc comment + `accessibilityHint`, and 4 literals in `FeedbackComposerTests`. The mailto fallback, in-line fallback message, and Announcer all interpolate `FeedbackComposer.recipient`, so no literal edits there. Acceptance: `grep -r "beta@payown.media" EarshotSwift/` returns nothing. **Test count: 438** (baseline of record was 404; never decreased). Branch `fix/issue-418-feedback-recipient` into `swift`. Not merged / not closed — Michael verifies on device first.

- **Issue #421 (Notifications — per-podcast new-episode notifications never fired; BLOCKED build 114):** Four compounding bugs fixed. **PRIMARY — no permission prompt (root cause confirmed with Michael's device report):** `PodcastSettingsView`'s "Notify on new episodes" toggle bound `$podcast.notificationEnabled` (a SwiftData `@Model` property) and requested authorization from `.onChange(of:)` + a bare `Task {}`. `.onChange` does not reliably fire on a persistent-model write (old == new by the time SwiftUI diffs) and the unowned `Task {}` had no lifetime owner, so `requestAuthorization()` was never invoked, the iOS prompt never appeared, status stayed `.notDetermined`, and every `deliver()` silently failed (that toggle is the ONLY `requestAuthorization` call site). Local notifications need no Info.plist usage string or entitlement — none added/required. **Fix:** explicit `Binding` (writes the model + bumps a `@State` token) + `.task(id:)` that owns and awaits `requestAuthorization()`; pure `NotificationPermissionTrigger` makes the ON/OFF decision unit-testable. Plus (2) foreground delivery from pull-to-refresh (`SubscriptionsView`) and launch/restore (`RootView`) capturing `refreshAll()`'s `[NewEpisodeNotification]`; (3) `NotificationDelegate` foreground options `[.list, .badge]` (quiet — no banner/sound interruption, screen-reader-correct); (4) delivery decoupled from the 15-min network throttle, `deliver()` coalesces per podcast so a throttle-skipped wake loses nothing and no show double-fires. **Implemented by:** earshot-audio. **Gates:** earshot-security PASS, earshot-accessibility PASS (toggle keeps native switch role/state), earshot-testing PASS (442 tests, baseline 438, Release clean), earshot-changelog (Fixed/Changed/Accessibility). +4 tests. **PR #423** into `swift`. **Not merged / not closed — Michael verifies on device first.**

- **Issue #422 (Inbox — item count in title, VoiceOver-readable; BLOCKED build 114):** Inbox nav title now shows "Inbox (N)" when non-empty, just "Inbox" when empty (never "(0)"), live from the `@Query`. **Accessibility approach (load-bearing decision):** `.accessibilityLabel` chained after `.navigationTitle` binds to the content view, not the nav-bar title element, so VoiceOver spoke "Inbox, open paren, 12" (first earshot-accessibility pass FAILED). On iOS 17 the large-title a11y bridge is unreliable about carrying a custom label even on the title `Text`, so the count is rendered in a `.principal` ToolbarItem `Text` carrying `.accessibilityLabel` ("Inbox, 12 episodes" / "Inbox, 1 episode" / "Inbox") + `.accessibilityAddTraits(.isHeader)`, with plain `.navigationTitle("Inbox")` + `.inline` for bar/back-button identity. Tradeoff accepted: inline title (no large-title spring) in exchange for a guaranteed spoken count. Pure title/label logic in testable `InboxLogic` helpers. **Implemented by:** earshot-ui. **Gates:** earshot-security PASS, earshot-accessibility FAIL→rework→PASS, earshot-testing PASS (442 tests, Release clean), earshot-changelog (Added/Accessibility). +4 tests. **PR #424** into `swift`. **Not merged / not closed — Michael verifies on device first.**

- **Issue #426 extension (Migration — queue order restore + partial-success self-heal):** Builds on #427's played/inbox/position restore. (1) **Queue order:** `FlutterMigrationService.readQueue()` joins the drift `queue_items → episodes` ordered by Flutter `position`; new `QueueImporter` re-adds via the existing `QueueRepository.add` path (idempotent, sets `.inQueue`, dense positions). The queue data was always in `earshot.db` but was never read. (2) **Partial-success retry:** new `flutter_episode_state_restored` flag set only after the overlay+queue succeed; `EpisodeStateImporter`/`QueueImporter` now `throw` on hard failure so the marker defers and a later launch retries. `MigrationGate.shouldSelfHeal` broadened to fire when state is missing (not just when the library is empty); RootView branches the remedy by podcast count — full re-import when 0 podcasts, a cheap **local** state-only re-overlay (no network, no announcement, no VoiceOver interruption) when shows already exist, which also auto-recovers prior-build users without a forced feed refresh. (3) New shared `MigrationEpisodeMatcher` (guid→audioURL) is the single matching path for both importers, replacing the inline logic in `EpisodeStateImporter`. **Implemented by:** planning agent (well-scoped data-layer extension; no domain logic beyond the audit's design). **Gates:** earshot-security PASS (leak-free SQLite, no force-unwraps, no retain cycle), earshot-swift6 PASS (all new types `@MainActor`/`Sendable`, no isolation violations), earshot-accessibility PASS (silent re-heal confirmed correct), earshot-testing PASS (**495 tests**, was 442 baseline; Release clean). earshot-changelog: Added/Fixed/Accessibility. **PR #428** into `swift`. **Not merged / not closed — Michael verifies on device first** (install a migrated build, then this over the top; confirm queue order + inbox/played history return). **Test baseline of record: 495.**

- **Issue #429 (Settings → Data — "Import older data"):** On-demand re-import of the Flutter `earshot.db` from a Settings → Data action, with a status row + import sheet. `FlutterMigrationService.runManualImport()` reopens the migration gate (`resetForSelfHeal`), imports deduped show shells, refreshes feeds, then overlays played/inbox/position state and queue order — idempotent (re-run adds no duplicate podcasts or queue entries) and a missing/empty DB is a no-op success (clean install, not a failure). New `MigrationStatus` persistence on `AppSettingsStore` (status + last-attempt date, both fall back safely on unset/garbage). New `DataImportViewModel` owns the `isRunning` flag and mirrors the persisted outcome; pure `ImportStatusText` maps status (+date) to the row value, sheet result, and VoiceOver announcement strings. **Implemented by:** earshot-data + earshot-ui (sequential on one branch, per the parallel-agent branch-hygiene lesson). **Gates:** earshot-security PASS (idempotent re-import, no half-written dead end, no retain cycle), earshot-accessibility PASS (row label/value split, header trait, escape action, outcome announced + conveyed by text not color), earshot-swift6 FAIL→fix→PASS (`runManualImport(onProgress:)` needed `@MainActor @Sendable` on the closure param to avoid a non-Sendable capture under strict concurrency — one-line signature fix; no caller passes a non-nil closure), earshot-testing PASS (**518 tests**, was 495 baseline; 0 failures; Release build clean). +21 net new tests across `ManualImportTests` (happy path / idempotent re-run / missing-DB no-op / status helpers), `ImportStatusTextTests` (status→string mapping), `DataImportViewModelTests` (view-model state), `AppSettingsStoreTests` (+5 migration-status round-trip/default). **`.failed` overlay path** covered by decomposition: the catch block only calls `recordImportFailed()` + returns false, and both the helper and the view-model's `.failed`→result-text mapping are independently tested (forcing a real overlay throw would require corrupting the ModelContext — rejected as brittle). Branch `feat/issue-429-import-older-data` into `swift`. **Not merged / not closed — Michael verifies on device first.** **Test baseline of record: 518.**

- **Decision (parallel-agent branch hygiene, 2026-06-22):** #421 and #422 were implemented by two domain agents dispatched in parallel sharing one working tree. The earshot-ui (#422) commit captured the earshot-audio (#421) uncommitted files, bundling both issues into one commit on one branch. Resolved by rebuilding each branch off `swift` from the combined tip and `git checkout <tip> -- <files>` selecting only each issue's own files (verified no cross-leakage; each branch builds + tests green independently at 442). **Lesson:** do not run two implementing domain agents in parallel in the same worktree — give each its own worktree, or run sequentially, so commits stay one-issue-per-branch.

## Audio Decisions

- **Decision (#362 — tab switching blocked during playback):** The periodic time
  observer fires every second and previously called `persistCurrentPosition()` →
  synchronous main-actor SwiftData `context.save()` on **every** tick, plus a
  `currentPositionSeconds` observation write that invalidates the whole TabView
  subtree (NowPlayingBar + all tabbed NavigationStacks read PlayerService). The
  per-second synchronous save starved the main run loop enough that TabView
  selection/hit-testing was delayed or dropped while playing, recovering the
  moment the tick loop stopped (pause) — a severe VoiceOver navigation
  regression. **Fix:** throttle the per-tick position write to a coarse cadence
  (`PlaybackLogic.positionPersistInterval = 5s`) via a new pure, unit-tested
  `PlaybackLogic.shouldPersistTick(currentSecond:lastPersistedSecond:interval:)`.
  The observed `currentPositionSeconds` and the lock-screen elapsed time still
  update every tick (cheap; required for AC #6); only the SwiftData write is
  coarsened. Durability is preserved because pause, seek, episode switch, and the
  30s listening-session flush all still persist eagerly (and reset the throttle).
  Worst-case loss on an abrupt process kill is ~5s of position. Backward jumps
  (seek/skip-back) persist immediately. **No selection binding** was being
  clobbered — RootView's TabView has none (confirmed). **Issue:** #362.
  **Files:** `PlaybackLogic.swift` (+`shouldPersistTick`/`positionPersistInterval`),
  `PlayerService.swift` (`persistPositionThrottled` + `lastPersistedSecond`
  tracker; eager paths reset it), `PlaybackLogicTests.swift` (+6 cadence tests).
  210 tests green, Debug strict-concurrency clean.

- **Decision (#412 — device overheats / sustained high CPU during playback):**
  The 1 Hz periodic time observer's `handleTick` called `updateNowPlayingElapsed()`
  on **every** tick, which read and rewrote the entire
  `MPNowPlayingInfoCenter.default().nowPlayingInfo` dictionary. That dictionary is
  marshaled cross-process to `mediaserverd` (including the `MPMediaItemArtwork`), so
  a full get+set every second indefinitely is a real, sustained energy cost — the
  overheating source. It is also unnecessary: once `elapsedPlaybackTime`,
  `playbackRate`, and `playbackDuration` are set, the system **extrapolates** the
  running elapsed time from the rate, so a per-second rewrite only re-states what the
  system already computes. **Ruled out as causes (verified):** the always-mounted
  `NowPlayingBar`/`RootView` do **not** read `currentPositionSeconds` in their
  bodies, so `@Observable` does not re-render them at 1 Hz (only the open
  `NowPlayingScreen` scrubber observes position, which is expected and transient);
  `evaluateChapterAutoSkip()` early-returns immediately when no chapters are marked
  skipped (the common case); `recordListeningTick()` is cheap arithmetic;
  `handleRouteChange` only `pause()`s and never re-invokes `configureSession()`
  (no `setCategory`/`setActive` churn); exactly one `AVPlayerItem` buffers at a time
  (preload is built only on queue-change / play, never per tick). **Fix:** throttle
  the per-tick now-playing elapsed rewrite to a coarse cadence
  (`PlaybackLogic.nowPlayingElapsedSyncInterval = 5s`) via a new pure, unit-tested
  `PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond:lastSyncedSecond:interval:)`,
  cutting the cross-process IPC rate ~5×. Correctness preserved: every discontinuity
  (play / pause / seek / resume) already calls `updateNowPlayingInfo()` with the
  exact elapsed time and rate, and now resets the throttle tracker
  (`lastNowPlayingSyncSecond = nil`) so the next tick re-anchors; rate (speed)
  changes now also push an immediate `updateNowPlayingElapsed()` so the lock screen
  reflects the new speed at once instead of waiting up to a sync interval. Backward
  jumps re-sync immediately. Lock-screen elapsed time, mark-played threshold,
  listening-session stats, chapter auto-skip, and the sleep timer are untouched.
  **Issue:** #412. **Files:** `PlaybackLogic.swift`
  (+`shouldSyncNowPlayingElapsed`/`nowPlayingElapsedSyncInterval`),
  `PlayerService.swift` (`updateNowPlayingElapsedThrottled` + `lastNowPlayingSyncSecond`
  tracker; `updateNowPlayingInfo` and `applyRate` reset it), `PlaybackLogicTests.swift`
  (+7 cadence tests). 362 tests green, Release build clean. **Concurrency:** not
  touched — no async/actor/Sendable changes, all work stays on the existing
  `@MainActor` tick path.

- **Decision (#368 -- in-player speed control):** Speed control added to
  `NowPlayingScreen` as a compact speed badge (shows current rate with a `*`
  suffix when a podcast override is active). Tapping opens `SpeedPickerSheet`,
  a new sheet with: (a) a scope toggle "This podcast" vs "All podcasts", (b) a
  quick-tap grid of 8 shortcuts (0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0),
  (c) a Stepper for precise 0.1x adjustment across the full 0.5x-5.0x range,
  and (d) a destructive "Reset to global speed" row when a podcast override is
  active. Per-podcast writes go to `Podcast.speedOverride`; global writes go to
  `AppSettingsStore` (same key `global_speed` used by SettingsScreen). Both
  paths call `PlayerService.applyRate()` immediately so the rate takes effect
  without pause/resume. VoiceOver: badge has `accessibilityLabel("Playback
  speed")` and a spoken `accessibilityValue` (e.g. "1.5 times"); speed changes
  are announced via `Announcer.announce`; the stepper has an explicit
  `accessibilityValue` and hint; shortcuts carry `.isSelected` when active.
  Speed range updated in SettingsScreen to full 0.5x-5.0x via `stride`. Pure
  helpers (`clampedSpeed`, `spokenRate`, `speedShortcuts`, `minSpeed`,
  `maxSpeed`, `speedStep`) added to `PlaybackLogic` and covered by 23 new unit
  tests in `SpeedTests.swift`. **Files:** `PlaybackLogic.swift`,
  `PlayerService.swift`, `NowPlayingScreen.swift`, `SpeedPickerSheet.swift`
  (new), `SettingsScreen.swift`, `SpeedTests.swift` (new). 235 tests green.

- **Decision (#370 -- AirPlay session options + in-player route picker):**
  The `.playback` category was configured without options, so AirPlay was not
  enabled by default. Added `options: [.allowAirPlay, .allowBluetooth]` to
  both `configureSession()` (called on every episode load and resume) and
  `applyAudioEnhancement()` (called on voice-enhance toggle mid-playback).
  Keeping the same options in both call sites prevents a voice-enhance toggle
  from inadvertently stripping AirPlay capability. Added `RoutePickerView`
  (`AVRoutePickerView` wrapped as `UIViewRepresentable`, tint from
  `Color.accentColor`) in `Core/UI/` and `airPlayRow` in `NowPlayingScreen`
  below the speed badge. Accessibility label "AirPlay" / hint "Choose audio
  output device" set on both the UIKit view and the SwiftUI wrapper layer.
  **Files:** `RoutePickerView.swift` (new), `PlayerService.swift`,
  `NowPlayingScreen.swift`, `project.pbxproj`. 248 tests green.

## UI Decisions

- **Import older data lives in an always-visible Settings → Data row (#429).** The
  manual re-import is surfaced as an "Import older data" row in the existing Data
  section of `SettingsScreen` — never gated on `IS_BETA_BUILD` or any migration
  window, so a returning tester can re-run it any time. The row shows the current
  outcome on its trailing side via a pure helper `ImportStatusText.rowValue` ("Not
  imported" / "Imported on {medium date}" / "Import failed"); the status is exposed
  as `.accessibilityValue(...)` with a fixed `.accessibilityLabel("Import older
  data")` so VoiceOver reads label + value as one stop and the status never bakes
  into the label. Status is read from `FlutterMigrationService(context:)` on
  `.onAppear` and refreshed on the sheet's `onDismiss` (the persisted
  `migration_status`/`migration_last_attempt_date` AppSettings don't drive `@Query`,
  so an explicit refresh keeps the row current). Tapping opens a dedicated
  `DataImportSheet` (separate from onboarding's migration sheet — no "Remind me
  later", reachable any time). The sheet wraps a `NavigationStack` with a Done
  confirmation button plus `.accessibilityAction(.escape)` so it's dismissible
  without a drag; its title `Text` carries `.isHeader`. A `@MainActor @Observable`
  `DataImportViewModel` (held via `@State`, created lazily on appear because it
  needs the environment `modelContext`) owns the `isRunning` flag, mirrors the
  persisted status, and posts `Announcer.announce("Import complete" / "Import
  failed", assertive: true)` when a run finishes. The result line pairs a
  decorative (`accessibilityHidden`) success/failure icon with text that states the
  outcome — color is never the only signal. Status→string logic is kept in the pure
  `ImportStatusText` enum so it's unit-testable without a view. **Issue:** #429.
  **Files:** `SettingsScreen.swift`, `Migration/Presentation/ImportStatusText.swift`,
  `DataImportViewModel.swift`, `DataImportSheet.swift`. 518 tests green (was 505).
- **Mini player inset attaches to tab content, not the TabView (#366).** The
  `NowPlayingBar` was attached with `.safeAreaInset(edge: .bottom)` on the
  `TabView` itself, which inserted the bar into the TabView's bottom safe area and
  drew it *over* the system tab bar — the tab bar was fully covered and not
  tappable during playback. **Fix:** a small private `MiniPlayerInset`
  `ViewModifier` (in `RootView.swift`) that applies
  `.safeAreaInset(edge: .bottom) { NowPlayingBar() }`, applied to each of the five
  tabs' `NavigationStack`s instead of to the TabView. With the inset on the tab
  content, the bar floats *above* the system tab bar; the tab bar stays visible
  and interactive, and the system handles positioning above the tab bar and home
  indicator across devices and Dynamic Type — no fragile manual height math
  (ZStack overlay was rejected for that reason). `NowPlayingBar` still renders
  nothing when `player.currentTitle == nil`, so no inset is added until playback
  begins. The magic-tap action and the audio re-apply `.onChange`/`.task` hooks
  on the TabView are untouched. **Issue:** #366. **Files:** `RootView.swift`.
  209 tests green (branch baseline 209; no regression).
- **Play-state announcement moved to the TabView root (#366 a11y gate).** Because
  the mini player is now inset into all five tabs, it renders five times. The
  per-bar `.onChange(of: player.isPlaying) { Announcer.announce(...) }` would have
  fired up to five times per toggle (VoiceOver "Playing, Playing, ..."). The
  announcer was removed from `NowPlayingBar` and a single one added at the
  `RootView` TabView root, so the transition is announced exactly once. Play/pause
  state is still carried on the transport button's `accessibilityValue`. **Files:**
  `RootView.swift`, `NowPlayingBar.swift`. Caught by the earshot-accessibility gate.
- **Doc correction:** the #362 note records "210 tests green," but the actual count
  on the `swift` branch is **209** (verified via `git stash` on this branch). New
  baseline of record: **209**.

## Networking Decisions

- **#381 Background feed refresh + 15-min skip window.** Registered a
  `BGAppRefreshTask` with stable identifier `media.payown.earshot.feedrefresh`
  (declared in `Info.plist > BGTaskSchedulerPermittedIdentifiers`; `fetch` added
  to `UIBackgroundModes`). The launch handler is attached declaratively via the
  SwiftUI `.backgroundTask(.appRefresh(_:))` scene modifier on `EarshotApp`
  (skipped under `isRunningTests`). The handler **re-schedules the next request
  first**, then runs a throttled refresh.
- **Throttle policy is pure + unit-tested.** `FeedRefreshPolicy.shouldRefresh(
  lastRefresh:now:force:window:)` (window default 15 min, mirrors Flutter) lives
  in the Subscriptions domain layer alongside `PlaybackLogic`/`StatsLogic`.
  Persisted via new `AppSetting` key `last_feed_refresh` (epoch seconds) with
  typed `AppSettingsStore.date/setDate` accessors. Background + cold-launch paths
  consult the window; manual pull-to-refresh passes `force: true` and stamps the
  timestamp so the next background wake inside 15 min is skipped. The migration
  restore in `RootView` also stamps it after its full refresh.
- **Threading.** `BackgroundFeedRefresher.runRefresh` is `@MainActor`. Both
  `SubscriptionRepository` and `AppSettingsStore` are `@MainActor`-bound (they
  touch `mainContext`), and `refreshAll` already saves per-podcast and
  logs+continues past per-feed failures. The 15-min window keeps each wake to one
  batched pass, so this does not re-introduce the cold-launch write storm the
  `@ModelActor` migration importer was built to avoid. All background DB work is
  guarded (no unrecoverable dead end, per `database-migrations.md`); the handler
  respects `Task.isCancelled` for task expiration. **Flag for earshot-swift6:**
  new async/MainActor-isolated code (`BackgroundFeedRefresher`, the
  `.backgroundTask` closure hopping to `MainActor.run`).
- **Inbox reach confirmed.** Background `refreshAll` → `refresh` writes new
  episodes as default `status == .newEpisode` with `inboxDismissed == false`,
  exactly what `InboxRepository`'s `status == .newEpisode && !inboxDismissed`
  query surfaces. Auto-queue + auto-download-N (#380) fire inside the same
  `refresh` path, so they trigger through the background path unchanged.
- **#385 Disk-backed artwork cache.** New `Core/Networking/ArtworkCache.swift`:
  a `Sendable final class` wrapping a dedicated `URLSession` whose
  `URLCache(memoryCapacity:16MB, diskCapacity:200MB, directory:)` is rooted at
  `Caches/artwork/` (system may evict under storage pressure — acceptable for
  re-fetchable artwork). Exposes async `data(for:)`/`image(for:)` primitives
  using `.returnCacheDataElseLoad`, so a previously fetched image is served from
  disk after a cold launch instead of re-downloading (the bug; `AsyncImage` and
  `URLCache.shared` were effectively per-session). Returns `nil` on any failure
  (no throws) since artwork is decorative — callers fall back to a placeholder.
  Falls back to a memory-only cache if the Caches dir can't be resolved (no
  force-unwraps, no crash).
- **Single shared cache for UI + lock screen (#378 reuse).** `ArtworkCache.shared`
  is used by both `PodcastArtwork` (replaced `AsyncImage` with a `@State` loader
  keyed by `urlString` via `.task(id:)`, cancellation-checked; stays decorative
  + `accessibilityHidden(true)` with the same placeholder/frame/border/API) and
  `PlayerService.updateNowPlayingArtwork`, which dropped its `URLCache.shared` +
  `URLSession.shared` path. So artwork loaded for a screen is a disk hit on the
  lock screen and vice versa.
- **Reset path.** `SettingsReset` now calls `ArtworkCache.shared.clear()` plus
  removes the `Caches/artwork/` directory, so "Reset local data" drops artwork.
- **Flag for earshot-swift6:** `ArtworkCache` is `Sendable` (immutable `let`
  refs to the thread-safe `URLCache`/`URLSession`); `UIImage`/`Data` cross actor
  boundaries to callers. The `PodcastArtwork` loader hops to the main actor by
  virtue of `.task`/`@State` after the `await`. No new data races; no actors
  added.
- **#386 Networking robustness: one shared session + retry/backoff.** New
  `Core/Networking/EarshotURLSession.swift` is an `enum` namespace holding the
  single configured `URLSession` (`.shared`) and a `makeConfiguration()`
  factory: explicit `timeoutIntervalForRequest = 15s`,
  `timeoutIntervalForResource = 60s`, and `requestCachePolicy =
  .reloadIgnoringLocalCacheData` (feeds/search change often). `HTTPClient` and
  `ITunesSearchService` default inits now take `EarshotURLSession.shared`
  instead of `URLSession.shared`, so the whole feed/search layer shares one
  configuration. Both inits stay injectable for tests. **`ArtworkCache` keeps
  its own session** on purpose (disk `URLCache` + `.returnCacheDataElseLoad`,
  #385) — left as-is, not folded into the shared session.
- **Pure `RetryPolicy` (Core/Networking/RetryPolicy.swift), unit-tested.** A
  `Sendable` value type: `maxAttempts` (3) + `backoff` schedule (`[1, 2]` →
  1s then 2s). `isTransient(_:)` classifies retryable failures: HTTP **5xx**
  and connectivity `URLError`s (`.timedOut`, `.networkConnectionLost`,
  `.cannotConnectToHost`, `.notConnectedToInternet`, `.dnsLookupFailed`).
  **Non-transient and never retried:** HTTP **4xx**, `HTTPError.badURL`,
  decoding/parse errors, `URLError.cancelled`. `.standard` is the shipping
  policy; `.immediate` (same attempts, 0s delays) is for tests.
- **`HTTPClient` retry loop.** `data(from:)` wraps `performFetch` in an
  attempt loop. The raw error/status is classified **before** it is wrapped
  into `HTTPError.transport`, so the policy sees the real 5xx / `URLError`.
  Backoff is awaited via an **injectable** `sleep` closure
  (`@Sendable (TimeInterval) async throws -> Void`, default `Task.sleep`,
  honors cancellation; tests inject a no-op). On exhaustion the original
  `HTTPError` (`.server(status:)` or `.transport`) surfaces unchanged —
  existing user-facing messages preserved, no swallowed errors, no
  force-unwraps.
- **Tests + `MockURLProtocol`.** New `EarshotTests/MockURLProtocol.swift`
  (a `URLProtocol` subclass with a FIFO queue of scripted outcomes — status
  +body or a `URLError`, lock-guarded) and `makeSession()` that layers it onto
  `EarshotURLSession.makeConfiguration()`. `RetryPolicyTests` (pure
  classification + backoff schedule) and `HTTPClientRetryTests` cover: 5xx→200
  and timeout/connection-lost→200 succeed after retry; 4xx fails fast (no
  retry); persistent 5xx/timeout exhaust and surface the right `HTTPError`;
  badURL never hits the network. Retry tests use `.immediate` + no-op sleep so
  the suite doesn't wait. **Test count 385 → 404.**
- **Flag for earshot-swift6:** new async + `Sendable` surface —
  `RetryPolicy: Sendable`, the `@Sendable` injected `sleep` closure on
  `HTTPClient`, and the lock-guarded mutable static queue in `MockURLProtocol`
  (test-only). No actors added; no SwiftUI view changed (no accessibility gate).

## Phase 3 Work Queue (post-parity audit, 2026-06-21)

Test baseline: **349 tests** (verified 2026-06-21, after #392 — 10 FeedbackComposerTests covering system-info block/anonymization and mailto encoding; PR #409, commit b319307). Prior steps: 339 after #372; 327 after #371; 315 after #373; 284 after #370 AirPlay salvage; 274 after #399.

> Follow-up for #391 (changelog reconcile): older untagged Flutter-era [Unreleased] entries duplicate the new #371-tagged "Export audio file" / "Stop after this episode" / "Mark as played" entries and reference TalkBack/auto-advance details that don't match the SwiftUI build. Dedupe before cutting the release block.

### P0 — Must fix first
| Issue | Title | Agent | Status |
|-------|-------|-------|--------|
| #368 | In-player speed control + per-podcast override | earshot-audio + earshot-ui | [x] Closed 2026-06-21. SpeedPickerSheet, per-podcast override, 0.5x-5.0x full range. 235 tests. Commit 5322185. |
| #369 | Skip Silence: wire or remove dead toggle | earshot-audio | [x] Closed 2026-06-21. Toggle removed; AppSettingsStore key retained for data compat. All gates passed. Commit 5322185. |

### P1 — High user impact
| Issue | Title | Agent | Status |
|-------|-------|-------|--------|
| #399 | Per-podcast settings page | earshot-ui | [x] Closed 2026-06-21. All gates PASS (security, swift6, accessibility, testing — 274 tests, Release clean). Merged via PR #403. Commit ab398cb. |
| #370 | AirPlay route picker in player | earshot-audio | [x] Closed earlier. Merged via PR #402 (commit 3ea5998). Follow-up: AirPlayTests salvaged into separate PR (see Salvage note below). |
| #380 | Auto-download N on subscribe + auto-queue on refresh | earshot-data | [x] Closed 2026-06-21. All gates PASS. |
| #378 | Lock screen artwork (MPMediaItemArtwork) | earshot-audio | [x] Closed 2026-06-21. Commit 5505b85. |
| #401 | Verify export audio shares local file (follow-up #363) | earshot-audio | [ ] |

### P2 — Polish and parity
| Issue | Title | Agent | Status |
|-------|-------|-------|--------|
| #379 | Sleep timer: Extend +5 on bar; countdown clears on episode switch | earshot-audio + earshot-ui | [x] Closed 2026-06-21. All gates PASS (security, swift6, accessibility, testing — 252 tests, Release clean). Merged via PR #404. Commit 41c7b32. Non-blocking follow-up: +5/speed badge touch-target <44pt (pre-existing, cleanup pass). |
| #373 | Chapter skip next/prev from player controls + hold-to-scan | earshot-audio | [x] Closed 2026-06-21. Hold-to-FF 4× (gesture + rotor gated on Direct Touch) + chapter auto-skip (in-memory skip set, loop guard). All gates PASS — 315 tests. Merged via PR #406. Commit 4744946. |
| #371 | Player episode actions: Mark as played, Export audio, Stop after this episode | earshot-ui | [x] Closed 2026-06-21. Overflow Menu + rotor actions; export shares LOCAL file (addresses #401 concern for player path); stop-after intercepts handlePlaybackEnded. All gates PASS — 327 tests. Merged via PR #407. Commit fd47c3b. Row-level export parity = separate follow-up. |
| #372 | Bookmarks list in player: jump, delete, share | earshot-ui | [x] Closed 2026-06-21. Surfaced existing BookmarksListView from player (menu + rotor); added per-bookmark share (pure BookmarkShareLogic). All gates PASS — 339 tests. Merged via PR #408. Commit 193635a. |
| #392 | Send Feedback (PRD 12) | earshot-ui | [x] Closed 2026-06-21. Settings > Help > Send Feedback; MFMailComposeViewController + mailto fallback; opt-in anonymized system info. All gates PASS — 349 tests. Merged via PR #409. Commit b319307. About screen = #258 (separate, next). |
| #400 | Expand speed range 0.5×–5.0× | earshot-ui | [x] | Absorbed into #368. SettingsScreen Picker now uses stride(0.5...5.0 by 0.1). |

### P3 — Larger standalone features
| Issue | Title | Agent | Status |
|-------|-------|-------|--------|
| #381 | Background feed refresh (BGTaskScheduler) | earshot-networking | [ ] |
| #72 | Push notifications per podcast | earshot-data | [ ] |
| #385 | Artwork disk cache | earshot-networking | [ ] |
| #386 | Networking robustness: retry/backoff/timeouts | earshot-networking | [ ] |

### Excluded
- #395 — DO NOT TOUCH. Protected per session instructions.

### Deferred — needs Michael's decision
- #259 Appearance (manual theme override / accent color picker / layout density) — DEFERRED 2026-06-21. Two reasons: (1) the issue is Flutter-framed (references lib/, Riverpod, MaterialApp) and not yet re-scoped for SwiftUI; (2) a manual theme/accent/density override brushes CLAUDE.md non-negotiable rule #3 ("follow system settings; never override the user's theme/contrast; Earshot reads from the system, never imposes"). A user-chosen Light/Dark/System override is arguably fine and is an accessibility win for some users, but accent-color/density overrides go further. This is a product-principle call for Michael before building. Not a technical blocker.
- #258 About screen is Flutter-framed too but ports cleanly and is explicitly wanted (PRD 17); re-scoped to a new SwiftUI issue and implemented.

## Blockers

None. (F14 audio-enhancement DSP intentionally deferred — see Decision F14.)

## Security Review — subscribe() off-main-actor (branch fix/refresh-off-main-actor)

earshot-security gate: PASS. Extension moves `SubscriptionRepository.subscribe()`
onto the background `FeedRefreshActor` (`@ModelActor`), mirroring the refresh fix.
Force-unwraps: none (no `!` in either production file beyond none-found). force-try:
none. fatalError/trap: none — the deliberate avoidance of `ModelContext.model(for:)`
(which traps on a missing ID) is confirmed; both ID re-fetches use predicate
`FetchDescriptor` and the missing-podcast path THROWS `SubscriptionError.podcastNotFoundAfterSubscribe`
instead of crashing. try?: 9 uses, all on `ModelContext.fetch` for idempotency
lookups / re-faults where nil is a valid "not present" result, not a swallowed
error — acceptable per checklist item 2. Silent error swallowing: subscribe
failures propagate (`async throws`); all 3 callers handle them — OPMLImportService
logs per-feed + continues, AddFeedView surfaces to UI + Announcer, SearchView
announces failure. saveIfNeeded() logs on catch. Cross-context safety: only
`PersistentIdentifier` value types cross the actor boundary (SubscribeResult);
no `@Model` is returned from or force-unwrapped after the actor. Auto-download
loop re-fetches Episodes by ID on the MAIN context via `compactMap` (stale/missing
IDs are dropped, never crashed), so the downloader never sees a background-context
or stale Episode. Idempotency preserved: re-subscribe returns the existing podcast
ID with no fetch/insert/save (alreadySubscribed=true); test confirms 1 podcast /
1 episode after double-subscribe. Behavior preservation verified: backlog
pre-dismiss (`inboxDismissed = true`), #296 future-date clamp on `lastSeenPubDate`
(seeded to newest NON-future pub date), `refreshedAt` stamp, and auto-download of
N most recent — all still hold and are covered by tests. Retain cycles: none (no
Task/sink/Timer/addObserver closures in changed files). @MainActor: repository
stays `@MainActor`; heavy work isolated to the `@ModelActor`. Secrets/entitlements:
none touched. Release build (iPhone 17): BUILD SUCCEEDED. Tests: 33 pass (8
FeedRefreshActorTests + 25 SubscriptionRepositoryTests). Feature suggestions: none
this review.

## Security Review — Issue #429

earshot-security gate: PASS. Settings → Data "Import older data" manual re-import
with status tracking. Force-unwraps: none in production (all `!` are boolean
negations; force-unwraps only in test fixtures where nil fails the test). try?:
no new ones (the `try?` in changed files are pre-existing OPML/AppSettings reads
out of #429 scope). fatalError: none. Retain cycles: none — `DataImportViewModel`
is `@MainActor @Observable` held via `@State` in a struct view; the `Task` captures
the view model, not self, and SwiftUI owns its lifetime. @MainActor: all status
read/write paths (`FlutterMigrationService`, `AppSettingsStore`, view model,
`runManualImport`) are main-actor isolated, so status writes can't race the launch
import Task; `importShells` correctly stays on its own `@ModelActor`. Release build
SUCCEEDED; the row is intentionally ungated (always-visible recovery affordance),
`IS_BETA_BUILD` absent from project.yml. AppLog: the one new catch logs + records
`.failed`. Data-safety deep review: `runManualImport` is idempotent (dedup by
feedURL in `importShells`, `queueItem == nil` skip in `QueueImporter`, state
overwrite in `EpisodeStateImporter`) and a phase-2 failure leaves
`migrationComplete=true`/`episodeStateRestored=false`, which `MigrationGate.shouldSelfHeal`
recovers on the next launch — no half-written dead end. Missing/empty DB → no-op
success so a clean install isn't shown a false failure. Faithfully replays the
shipping launch sequence, so no new cross-context race. Feature suggestions: none
this review.

## Security Review — Issue #366

earshot-security gate: PASS. NowPlayingBar overlapping tab bar fix. Only Swift
change is RootView.swift (added private `MiniPlayerInset` ViewModifier, moved the
`.safeAreaInset(edge: .bottom)` off the TabView onto each tab's NavigationStack).
No force-unwraps (the lone `!` is the boolean `!settings.onboardingComplete`), no
`try?`, no `fatalError`, no new closures capturing self (the modifier is a value-
type struct, no Task/observer/timer/sink), no new async or off-main SwiftData
access, no entitlement or secret changes. `#if IS_BETA_BUILD` migration guards
untouched and still fenced. Structural UI change with no new logic.

## Security Review — Issue #378

earshot-security gate: PASS (with advisory). Lock screen artwork via MPMediaItemArtwork.
No force-unwraps (the two `!` in PlayerService.swift are boolean negations, not optional
force-unwraps). No `try?` — network path uses full `do/catch` with `AppLog.player.error`.
No `fatalError`. No secrets. No entitlement changes. No IS_BETA_BUILD impact.
Both new methods (`updateNowPlayingArtwork`, `setArtwork`) are @MainActor-isolated
(inherited from the class annotation); URLSession suspension is correct async pattern.
Both error paths logged. Advisory only: `Task { await updateNowPlayingArtwork(from:) }`
(line 728) captures `self` strongly without `[weak self]` — inconsistent with lines
543/611/658/665 in the same file. Not a practical problem (PlayerService lives for the
app lifetime), but recommend adding `[weak self]` for consistency. Also: `setArtwork`
could be `private` rather than `internal`. Neither finding blocks the gate.

## Security Review — Issue #369

earshot-security gate: PASS. Removal-only change: dead `Toggle("Skip silence")`
removed from SettingsScreen, `skipSilenceEnabled` property and its configure-load
line removed from SettingsStore. `SettingsKey.skipSilenceEnabled` and
`SettingsDefault.skipSilenceEnabled` retained in AppSettingsStore with explicit
deprecation comments explaining data compatibility. No new code paths, no new
closures, no new async work. Pre-existing `try?` calls in AppSettingsStore
(context.fetch) and SettingsScreen (String(contentsOf:)) are unchanged and
pre-date this issue. No force-unwraps, fatalErrors, retain cycles, secrets,
entitlement changes, or IS_BETA_BUILD guard regressions introduced.
Data compatibility is sound: the key is retained so a future reader gets the
stored Bool string; it is simply never written again. No new error types needed
(no new code paths).

## Security Review — Issue #380

earshot-security gate: PASS. Auto-download on subscribe + auto-queue on refresh.
No force-unwraps (all four `!` characters are boolean operators). No `try?` introduced
by this PR; two pre-existing `try?` fetch calls in `refreshAll` and `podcast(forFeedURL:)`
are unchanged and both acceptable (degrade-to-default and sentinel-nil patterns). No
`fatalError`. No retain cycles (no Task/NotificationCenter/Combine closures; all async
work is direct await on the @MainActor class). @MainActor annotation at class level
covers all new methods including `subscribe` and `refresh`. `QueueRepository.add` is
also @MainActor. `EpisodeDownloading` protocol is non-throwing by design; error contract
delegated to DownloadManager. All new code paths logged via AppLog.subscriptions.
No secrets. No entitlement changes. No IS_BETA_BUILD impact. Advisory only:
`AppSettingsStore(context:)` constructed inline in `subscribe()` — consider injecting
`autoDownloadCount` for cleaner unit testing. Does not block the gate.

## Security Review — Issue #418

earshot-security gate: PASS. Send Feedback recipient corrected from beta@payown.media to
michael@payown.media (the project owner contact from CLAUDE.md). Pure string-constant change,
3 files: FeedbackComposer.swift (`recipient` constant), SendFeedbackView.swift (doc comment +
accessibilityHint "michael at payown dot media"), FeedbackComposerTests.swift (4 literal
assertions; the 5th test follows `FeedbackComposer.recipient`). No logic change — the mailto
builder, percent-encoding, fallback message, and Announcer all interpolate `recipient` and were
untouched. No force-unwraps, no `fatalError`, no secrets (the address is a public contact, not a
credential). The 3 `try?` grep hits are pre-existing `XCTUnwrap` wrappers in test code, not in
this diff. No new closures/retain cycles; SendFeedbackView already @MainActor. AppLog error paths
intact. No entitlements/project.yml/migration impact (IS_BETA_BUILD Release check N/A). git diff
vs swift confirms exactly 3 files; no stray beta@payown.media remains. Feature suggestions: none.

## Security Review — Issue #410

earshot-security gate: PASS. Settings → About screen (PRD 17). New files: AppInfo.swift,
AboutView.swift, AppInfoTests.swift; SendFeedbackView refactored to use AppInfo; SettingsScreen
gained an About NavigationLink. No force-unwraps (AppInfo uses `as? String ?? "unknown"`;
AboutView guards the repo URL with `if let`). No `try?` introduced (the lone grep hit at
SettingsScreen.swift:180 is pre-existing OPML code, not in this branch's diff). No `fatalError`.
No retain cycles (AppInfo/AboutView have no Task/sink/observer/Timer; SendFeedbackView's openURL
closure captures only @State value types). @MainActor on AboutView; AppInfo is a pure stateless
enum. No new catch blocks. PII/privacy: reads only CFBundleShortVersionString + CFBundleVersion;
external Link is a system-handled SwiftUI Link to the public repo with a VoiceOver "leaves the app"
hint. No secrets (only public repo URL + already-public beta@payown.media). No entitlement or
project.yml changes. Release build SUCCEEDED on iPhone 17 sim after xcodegen regenerate; no
migration/IS_BETA_BUILD impact. project.pbxproj registration verified for all three files across
app + test targets.

## Security Review — Issue #412

earshot-security gate: PASS. Playback overheating fix: now-playing elapsed write throttled
from 1 Hz to once per 5s. Changed: PlayerService.swift (added `@ObservationIgnored
lastNowPlayingSyncSecond`, `updateNowPlayingElapsedThrottled`; applyRate/updateNowPlayingInfo
re-anchor), PlaybackLogic.swift (pure `nowPlayingElapsedSyncInterval` + `shouldSyncNowPlayingElapsed`),
PlaybackLogicTests.swift (8 cadence tests, all pass). No force-unwraps, no `try?`, no `fatalError`,
no secrets in the diff. Time observer closure uses `[weak self]` + `guard let self` on @MainActor;
class is @MainActor @Observable so the throttle anchor is main-actor-only. No stall risk: lock-screen
elapsed keeps moving via system rate extrapolation; every discontinuity (play/pause/seek/resume/rate)
pushes exact elapsed+rate and resets the anchor to nil; backward jumps force an immediate resync.
mark-played write is unconditional in handleTick, unaffected by the throttle. No entitlement/migration
changes; Release build SUCCEEDED on iPhone 17 sim. No feature suggestions this review.

## Security Review — Issue #381

earshot-security gate: PASS (with one defect found + fixed). Background feed refresh via
BGAppRefreshTask. New files: FeedRefreshPolicy.swift (pure throttle, 15-min window, force bypass)
and BackgroundFeedRefresher.swift (caseless enum: owns task id, schedules next request, runs
@MainActor throttled refresh wrapped do/catch). Checklist clean: no force-unwraps, no `try?`,
no fatalError, no secrets, no retain cycles (caseless enums + value-type App/scene closures),
@MainActor on all DB work. Task identifier `media.payown.earshot.feedrefresh` matches byte-for-byte
across the const, `.appRefresh` registration, BGAppRefreshTaskRequest, and Info.plist
BGTaskSchedulerPermittedIdentifiers; UIBackgroundModes `fetch` present. DB-migration safety rule
satisfied — refreshAll logs+continues per feed, AppSettingsStore.save is do/catch+AppLog; no
unguarded DB call can dead-end the task. DEFECT: refreshAll ignored cancellation, so BGTask
expiration with many feeds kept spinning fetches instead of stopping. FIX: added
`isCancelled` param (default `{ Task.isCancelled }`) to refreshAll with a per-iteration guard,
forwarded from runRefresh; existing trailing-closure callers unaffected. Re-verified BUILD
SUCCEEDED + 33 related tests pass (policy 8, settings 6, repo 15, importer 4). No feature
suggestions this review.

## Security Review — Issue #385

earshot-security gate: PASS (no defects, no code changes needed). Disk-backed artwork cache.
New: ArtworkCache.swift — `final class ArtworkCache: Sendable`, `static let shared`, dedicated
URLSession over a disk-backed URLCache (16MB mem / 200MB disk) rooted at Caches/artwork; async
`data(for:)`/`image(for:)` return nil (never throw) on miss/failure; `clear()` and
`cacheDirectoryURL()`. Wired into PodcastArtwork (replaces AsyncImage with a cancellation-guarded
@State loader) and PlayerService.updateNowPlayingArtwork (lock-screen path now reuses the same
cache, #378). SettingsReset factory reset now clears the URLCache + removes Caches/artwork.
Checklist clean: no force-unwraps (only XCTUnwrap in tests), no fatalError, no secrets, no
entitlement/migration changes. The three `try?` calls are all benign filesystem ops (createDirectory
best-effort with logged memory-only fallback; removeItem on possibly-absent dirs). Retain cycles:
PlayerService callsite uses `[weak self]`; PodcastArtwork is a struct view (no self capture) and
re-checks `!Task.isCancelled` + URL identity after await before committing @State. @MainActor:
PlayerService is class-level @MainActor so the post-await write is safe; ArtworkCache is Sendable
with only immutable URLCache/URLSession refs. AppLog.networking.error covers every failure branch
(HTTP non-2xx, fetch, decode, memory-only fallback) — no empty catches. Defensive filesystem
confirmed: memory-only URLCache fallback when Caches dir unresolvable, no crash. SettingsReset scope
confirmed: removes exactly Caches/artwork, nothing broader; new SettingsStoreTests proves it. Build
SUCCEEDED on iPhone 17 sim. No feature suggestions this review.

## Swift 6 Review — Issue #385

earshot-swift6 gate: PASS. Disk-backed artwork cache (ArtworkCache.swift,
PodcastArtwork.swift, PlayerService.updateNowPlayingArtwork, SettingsReset).
Concurrency mode verified: SWIFT_STRICT_CONCURRENCY=complete (project baseline is
Swift 5.0 / minimal). Default build SUCCEEDED and strict-complete build SUCCEEDED
on iPhone 17 sim; test target build-for-testing SUCCEEDED under strict-complete.

Findings:
- Sendable: `final class ArtworkCache: Sendable` is sound — only immutable `let`
  refs to a thread-safe URLCache + URLSession, no mutable shared state; `static let
  shared` is safe. PASS.
- UIImage across the isolation boundary: `image(for:)` is nonisolated async and
  constructs the UIImage internally, returning a freshly-built value with no other
  references. Under region-based isolation the return value is in a disconnected
  region, so handing it to the MainActor caller (PodcastArtwork @State set;
  PlayerService.setArtwork MainActor write) is race-free. Strict-complete produced
  ZERO warnings on either call site. No need to fall back to returning Data?. PASS.
- PodcastArtwork load: `.task(id:)` cancels on URL change; load() re-checks
  `!Task.isCancelled` && `self.urlString == urlString` after await before mutating
  @State on the main actor (struct view, no self capture). Race-free. PASS.
- SettingsReset.deleteArtworkCache: called from @MainActor static func; clear() and
  cacheDirectoryURL() are nonisolated on a Sendable type — valid from any actor. PASS.

Pre-existing (NOT this issue): PlayerService.swift:981 and :988 emit "sending 'note'
risks causing data races" under strict-complete (the AVAudioSession interruption /
route-change Notification observer pattern). Those lines are unchanged by #385 and
predate it; out of scope for this gate. Project-wide strict-complete surfaces 118
concurrency warnings total (e.g. the known DownloadManager one), none in #385's files.

New agents created: none. Overall: PASS.

## Security Review — Issue #386

earshot-security gate: PASS (no defects, no code changes needed). Networking robustness:
retry/backoff + shared configured URLSession + explicit timeouts. New: EarshotURLSession.swift
(immutable `static let shared` over a thread-safe URLSession; 15s request / 60s resource;
`.reloadIgnoringLocalCacheData`), RetryPolicy.swift (pure `Sendable` value type; maxAttempts 3,
backoff [1,2]s; transient = HTTP 5xx + connectivity URLErrors). Modified: HTTPClient.swift gains
a bounded retry loop with an injectable `@Sendable` sleep (default Task.sleep, honors
cancellation); ITunesSearchService default session switched to EarshotURLSession.shared. New
tests: MockURLProtocol.swift, RetryPolicyTests.swift, HTTPClientRetryTests.swift.

Findings:
- Force-unwraps: only in test-only code (MockURLProtocol fallback URL/HTTPURLResponse,
  test fixture URLs) — acceptable XCTest exception. None in production.
- Retry surfaces the real final error: on exhaustion/non-transient, `throw mapped(error, url:)`
  passes HTTPError through unchanged and wraps raw transport as .transport. Verified by
  exhaustion tests (.server(status:500) and .transport surface, not masked).
- Unbounded loop / DoS / battery: `while true` bounded by `attempt < maxAttempts` (cap 3).
  Cannot loop forever.
- Cancellation: `try await sleep(backoff)` sits OUTSIDE the do/catch, so CancellationError
  exits immediately without consuming a retry; URLError(.cancelled) classified non-transient.
- Thread-safety: shared session is an immutable static let over a thread-safe URLSession;
  MockURLProtocol's mutable static queue is NSLock-guarded on every access and is test-only.
- .reloadIgnoringLocalCacheData: deliberate; applies only to feed/search session. ArtworkCache
  (#385) uses a separate session with its own disk URLCache + .returnCacheDataElseLoad — intact.
- Typed errors (HTTPError enum); AppLog.networking on all log paths; no try?/fatalError;
  no @Published/UI state; no entitlement or project.yml changes; no secrets.

Build: simulator BUILD SUCCEEDED on iPhone 17. Feature suggestions: none. Overall: PASS.

## Swift 6 Review — Issue #386

earshot-swift6 gate: PASS (no code changes needed). Networking robustness:
RetryPolicy.swift, EarshotURLSession.swift, HTTPClient.swift, ITunesSearchService.swift
(session swap), MockURLProtocol.swift (test-only). Concurrency mode verified:
SWIFT_STRICT_CONCURRENCY=complete (project baseline is Swift 5.0 / minimal).
Default build SUCCEEDED and strict-complete build SUCCEEDED on iPhone 17 sim;
test target build-for-testing SUCCEEDED (default) and under strict-complete.

Findings:
- Sendable conformance: `struct RetryPolicy: Sendable` is sound — all stored
  props are `let` over `Int` / `[TimeInterval]`; statics are `let`. Explicit
  conformance correct. PASS.
- HTTPClient struct Sendability: stored props are `session: URLSession`
  (thread-safe, Sendable), `retryPolicy: RetryPolicy` (Sendable), and
  `sleep: @Sendable (TimeInterval) async throws -> Void`. The closure is
  correctly `@escaping @Sendable`; the default body captures nothing external
  (only its `seconds` param + `Task.sleep`). Struct is implicitly Sendable and
  crosses awaits race-free. NOTE: signature is `TimeInterval`, not the
  `Duration/TimeInterval` named in the issue brief — fine either way, no
  concurrency impact. PASS.
- static let shared URLSession: immutable `let`, thread-safe URLSession, Swift's
  thread-safe lazy static init. Concurrency-safe from any actor. PASS.
- Retry loop / Task.sleep cancellation: `attempt` is local stack state, no shared
  mutable state across awaits. `Task.sleep` CancellationError is not an HTTPError
  or URLError, so `isTransient` returns false and it propagates out instead of
  looping; URLError(.cancelled) likewise non-transient. No data race. PASS.
  (Behavioral note, out of gate scope: a cancelled sleep is wrapped by `mapped()`
  into HTTPError.transport rather than rethrown as CancellationError — covered by
  the security gate, not a concurrency defect.)
- nonisolated functions: none introduced; all methods are plain struct methods.
  N/A.
- Structured concurrency: no Task.detached anywhere in the issue's code. PASS.
- Global state: `EarshotURLSession.shared`, `requestTimeout`, `resourceTimeout`,
  `RetryPolicy.standard/.immediate/.transientURLErrorCodes`, `AppLog.networking`
  are all `let` (Sendable). No mutable app-target global state. PASS.
- Swift 6 build clean: ZERO strict-complete warnings/errors in any of the four
  app-target files (RetryPolicy, EarshotURLSession, HTTPClient, ITunesSearchService).

Test-only (does NOT block gate): MockURLProtocol.swift:25 `static var outcomes`
warns under strict-complete ("nonisolated global shared mutable state"). It is
fully NSLock-guarded on every access (setOutcomes/reset/nextOutcome), so it is
NOT a real data race — the compiler just can't see through the manual lock.
Test target is not on Swift 6. If/when the test target flips to Swift 6, minimal
fix is `nonisolated(unsafe) static var outcomes` (justified: lock-protected).

Pre-existing (NOT this issue): project-wide strict-complete surfaces the same
catalogue of warnings as #385 (SwiftData KeyPath-not-Sendable macro noise,
DownloadManager non-Sendable `Episode` param, SubscriptionRepository `@Model`
sends, PlayerService.swift:981/988 `sending 'note'`, EarshotSchema
`versionIdentifier` static state). None are in #386's files; all out of scope.

New agents created: none. Overall: PASS.

## Security Review — Issue #72

earshot-security gate: PASS. Per-podcast new-episode LOCAL notifications.
Reviewed: Core/Notifications/{NewEpisodeNotification, NewEpisodeNotificationDecision,
NotificationCenterProtocol, NotificationService, NotificationRouter,
NotificationDelegate}.swift (new), Logger+Earshot.swift, SubscriptionRepository.swift,
BackgroundFeedRefresher.swift, PodcastSettingsView.swift, EarshotApp.swift, RootView.swift.

- Force-unwraps: none. fatalError: none. Secrets: none (scan hits were userInfo key constants).
- try?: one new (RootView route() podcast fetch) — acceptable, fetch-fail and not-found
  both log + return identically. The two SubscriptionRepository try? are pre-existing.
- Retain cycles: none. Delegate Task captures `router` not self; app retains the delegate
  because UNUserNotificationCenter.delegate is weak (correct, commented).
- @MainActor / thread safety: NotificationRouter is @MainActor @Observable; delegate hops to
  main actor before mutating. BackgroundFeedRefresher.runRefresh and refreshAll are both
  @MainActor, so the new deliver() call is race-free. NotificationService is a Sendable struct
  over the thread-safe UNUserNotificationCenter via an injectable protocol.
- Delivery never throws out of the background task — auth/delivery failures caught+logged via
  new AppLog.notifications. Stale notifications resolve podcast by feedURL / episode by guid
  with guards; missing refs log + no-op, never crash.
- Entitlements: N/A (local notifications need none; no aps-environment added). IS_BETA_BUILD:
  N/A (no migration code). Release build SUCCEEDED. Tests: 27/27 + 22/22 (incl. 4 new) pass.
- Feature suggestions: none this review. New agents created: none.

## Notifications Decisions

- **#72 Per-podcast new-episode local notifications (PRD 5.10).** LOCAL
  notifications only via `UserNotifications` — no APNs/FCM/remote push, no new
  Info.plist key, no entitlement. New `Earshot/Core/Notifications/` module:
  `NotificationService` (auth + category + delivery), `NotificationDelegate`
  (`UNUserNotificationCenterDelegate`), `NotificationRouter` (`@MainActor`
  `@Observable` routing state), plus pure value/logic types
  `NewEpisodeNotification`, `NewEpisodeNotificationDecision`, and the
  `NotificationScheduling` protocol with a `SystemNotificationCenter` adapter.
- **Testability via protocol seam.** All `UNUserNotificationCenter` access goes
  through `NotificationScheduling` so authorization/delivery is unit-tested
  against an actor-backed mock — no real notification center in the test host.
  Pure helpers (`bodyText`, `shouldNotify`, `NotificationDelegate.intent`) are
  static and tested directly.
- **Fire point.** `SubscriptionRepository.refresh(_:)` now returns a
  `RefreshOutcome` (`added`, `wasBackfill`, `newestNewEpisode`); `refreshAll`
  collects one `NewEpisodeNotification` per notification-enabled podcast that got
  genuinely-new episodes (decision excludes both backfill paths: first-subscribe
  pre-dismiss and migrated-shell catalog seed). `BackgroundFeedRefresher.runRefresh`
  delivers them after stamping the throttle timestamp. Delivery never throws —
  failures are logged via `AppLog.notifications` and swallowed so the BGTask
  always completes.
- **Natural-key references.** `userInfo` carries `podcastFeedURL` (unique) and
  `episodeGUID`, not `PersistentIdentifier`, mirroring `lastPlayingEpisodeID`
  (which stores `episode.guid`) so references resolve reliably across launches.
- **Deep link + actions.** Two foreground actions ("Add to queue", "Play now")
  on a stable category id. The delegate maps the response to a `NotificationIntent`
  and publishes it on `NotificationRouter`; `RootView` observes it, resolves the
  podcast/episode by natural key, performs the action (enqueue via
  `QueueRepository` / play via `PlayerService`), switches to the Library tab
  (new `TabView` selection binding + `RootTab` enum), and pushes the show's
  detail via a bound Library `NavigationStack` path. Missing podcast/episode is
  logged and skipped — never crashes on a stale notification.
- **Permission prompt.** Requested only when the user first toggles
  "Notify on new episodes" ON in `PodcastSettingsView` (`.onChange`), and only if
  status is `.notDetermined` (idempotent). Title/body are plain text (no emoji,
  per the issue's VoiceOver requirement); body is correctly pluralized.
- **Concurrency.** `NotificationService`/value types are `Sendable`;
  `NotificationRouter` is `@MainActor`; the delegate hops to the main actor to
  publish. Debug + Release builds clean under `minimal` strict concurrency.

## Data Decisions

### Issue #425 — Freeze V2, add V3 + drift detection (launch-crash hardening)
- **Frozen-schema architecture.** `EarshotSchemaV2` is now a verbatim frozen
  snapshot (nested `@Model` types) of the 10-entity graph as it shipped at #337
  (`f0ae8d5`), including `Podcast.notificationEnabled` as the original
  non-optional `Bool`. `EarshotSchemaV3` (`Schema.Version(3,0,0)`) is the only
  versioned schema that references the LIVE top-level model types. No
  `VersionedSchema` references live types except V3.
- **The latent crash.** Previously `EarshotSchemaV2.models` pointed at live
  types, so the 2.0.0 schema silently changed shape on any field add — SwiftData
  would later abort a store open into a non-optional destination attribute
  (NSCocoaErrorDomain 134110), an uncatchable launch crash. Freezing V2 makes
  that class impossible; the drift test makes the next occurrence a CI failure.
- **notificationEnabled -> Bool?.** The live `Podcast.notificationEnabled` is now
  optional (`nil` = off). Default in the initializer is `nil` so a fresh insert
  and a row migrated from V2 read identically. Every reader coalesces `nil` to
  `false`: `SubscriptionRepository` (`?? false` into the notify decision),
  `PodcastActionsBuilder` (read + explicit-assign toggle, no `.toggle()`),
  `PodcastSettingsView` (an explicit `Binding<Bool>` bridges the optional to the
  `Toggle`), and `NewEpisodeNotificationDecision` keeps its plain `Bool` param.
- **Migration plan.** `EarshotMigrationPlan` chains `[V1, V2, V3]` with two
  stages: V1->V2 stays the manual export/reimport in `StoreMigration` (the plan's
  V1->V2 custom stage is an inert marker — a V1 store is intercepted before the
  plan runs), and V2->V3 is `.lightweight` (optionalizing a field is natively
  supported, so it migrates instead of aborting). The production container
  (`ModelContainerFactory.makeShared` via `StoreMigration.openOrMigrate`) now
  opens as V3 with the plan; reset-on-failure and in-memory tiers are preserved.
- **Drift detection** (`SchemaDriftTests`). Compares the live graph against the
  frozen V2 snapshot and asserts the only difference is the documented intentional
  delta (`Podcast.notificationEnabled`: `Bool` -> `Bool?`). Any other added /
  removed / retyped attribute fails CI, forcing a new frozen Vn + migration stage.
  Verified to fail when a probe field is added to a live model.
- **Upgrade fixture** (`StoreMigrationV2toV3Tests`). Seeds a real on-disk store at
  the frozen V2 schema (2 podcasts, episodes incl. NULL optionals + a played one,
  queue item, bookmark, folder + membership, `notificationEnabled` true/false) and
  asserts V2->V3 via the production path completes without aborting and preserves
  every relationship and the nil-as-false semantics. The original V1->V2
  `StoreMigrationTests` still passes.
- **#423 coordination.** PR #423's `PodcastSettingsView` notifications toggle binds
  `isOn: $podcast.notificationEnabled` directly. Against the now-optional field a
  `Binding<Bool?>` cannot bind to `Toggle(isOn:)`, so when #423 rebases it must use
  the same bridge this PR added (a `Binding<Bool>` get `{ podcast.notificationEnabled
  ?? false }` set `{ podcast.notificationEnabled = $0 }`) and observe that binding's
  `wrappedValue` in `.onChange`. If #423 also reads `notificationEnabled` anywhere as
  a plain `Bool`, coalesce with `?? false`.

## Security Review — Issue #425

earshot-security gate: **PASS**. Reviewed the schema-freeze + V2->V3 migration
hardening across EarshotSchema.swift, StoreMigration.swift, ModelContainerFactory.swift,
Podcast.swift, and the three reader sites (SubscriptionRepository, PodcastSettingsView,
PodcastActionsBuilder) plus the new tests.

- Force-unwraps / try! / fatalError: none introduced. The pre-existing `try!`
  (test-host placeholder) and in-memory last-resort `fatalError` in
  ModelContainerFactory are unchanged and expected.
- try?: the deliberate `try?` in `openOrMigrate` is correct — a failed V3/V2 open
  is an expected recoverable signal routing to the manual V1 reimport, not a
  swallowed error; a genuine failure still throws into makeShared's
  reset-on-failure catch.
- Data safety: V2->V3 is a native `.lightweight` Bool->Bool? stage that migrates
  (never aborts) and preserves all data; reset-on-failure can only fire on a
  genuinely unreadable store, never on a normal upgrade or fresh install. Verified
  by StoreMigrationV2toV3Tests and the SchemaDriftTests CI guard.
- All notificationEnabled readers coalesce nil->false; no entitlements/secrets
  touched. Release build SUCCEEDED. 26/26 targeted tests pass.

## Security Review — Issue #383

earshot-security gate: **PASS**. Track 2 — share-sheet / "Open in Earshot" OPML
import, branch `feat/opml-share-sheet`. Reviewed Info.plist, RootView.swift,
SettingsScreen.swift, the new OPMLFileImporter.swift, and OPMLFileImporterTests.swift.

- Security-scoped resource: balanced and correct — `startAccessingSecurityScopedResource()`
  paired with `defer { if scoped { stop... } }`, releasing only when start returned
  true. No leak, no unbalanced release.
- UTI / Info.plist scope: minimal-claim. `LSItemContentTypes` lists only
  `org.opml.opml` (NOT `public.xml`), so the app does not claim all XML.
  `public.xml`/`public.text` are conformance-only (`UTTypeConformsTo`).
  `CFBundleTypeRole = Viewer`, `LSHandlerRank = Alternate`. No entitlement change.
- Untrusted input: `String(contentsOf:encoding:.utf8)` throws (does not crash) on
  non-UTF8/huge/missing files; `try?`->nil is logged via `AppLog.data.error` AND
  announced via `Announcer`. Verified at runtime in the test log.
- No force-unwraps / try! / fatalError introduced. No retain cycle (RootView is a
  value-type View; inner Task calls a static func). Release build SUCCEEDED.
  4/4 OPMLFileImporterTests pass.
- Non-blocking notes: `handleIncomingFile` also accepts `.xml` though only `.opml`
  is registered (harmless); Settings picker `.failure` still silently returns
  (pre-existing, unchanged). No fixes applied, no commit made.

## Issue #425 (Data — Freeze V2 schema, add V3 + drift detection; build-114 launch-crash class)

**Status:** Implemented, all gates PASS, NOT merged / NOT closed. Branch
`fix/issue-425-freeze-schema-v3-migration` off `swift`. Awaiting Michael's on-device
UPGRADE verification (a clean install proves nothing per database-migrations.md).

**Validation verdict (planning agent):** Accepted the proposed architecture, with a
correction to the diagnosis recorded for the record. Git history proof: no
`Data/Models/*.swift` file has changed since the V2 graph was created (#337, f0ae8d5),
and `notificationEnabled` was present in V2 from that first commit — so the literal
"a field added to V2 without a bump, store-on-disk lacks it, same-version shape
mismatch aborts" story is NOT yet true on shipped builds. BUT the underlying defect is
real and the fix is the correct, owner-aligned ("most stable, future-proof") move:
`EarshotSchemaV2.models` referenced LIVE types, so the 2.0.0 schema would silently
change shape the moment any model gains a field with no bump — a latent guaranteed
launch-crash. Reproduced the abort MECHANISM by running StoreMigrationTests: opening a
V1 store against the live V2 schema throws NSCocoaErrorDomain 134110
(`entity=Episode, attribute=createdAt ... missing attribute values on mandatory
destination attribute`), surviving today only because `openOrMigrate` wraps the first
open in `try?` and falls back to manual reimport. The fix makes the whole class
impossible and adds a CI drift test so it can never silently return.

**Implemented by:** earshot-data.

**Changes:** EarshotSchema.swift (froze V2 into nested @Model snapshots of all 10
entities; added EarshotSchemaV3 holding the live types — now the ONLY versioned schema
referencing live models; added `EarshotMigrationPlan` with V1->V2 [manual reimport
intercept] and V2->V3 [.lightweight] stages); Podcast.swift (`notificationEnabled`
Bool -> Bool?, default nil); StoreMigration.swift + ModelContainerFactory.swift (open
as V3 via the plan; reset-on-failure + in-memory tiers preserved); nil-as-false readers
at SubscriptionRepository:239, PodcastSettingsView (Binding<Bool> bridge + .onChange),
PodcastActionsBuilder:23/28/30; NEW SchemaDriftTests.swift (fails CI if live graph
diverges from frozen V2 by anything but the documented notificationEnabled delta); NEW
StoreMigrationV2toV3Tests.swift (real frozen-V2 on-disk store w/ podcasts incl. NULL
optionals, episodes, queue, played, bookmark, folder, membership -> migrates to V3 via
production path preserving all data, never aborting; + clean reopen-as-V3).

**Gates:** earshot-security PASS; earshot-swift6 PASS (no new concurrency surface);
earshot-accessibility PASS (Binding<Bool> bridge keeps native switch role/state; nil
reads as "off", not dimmed); earshot-testing PASS (**442** executed, 0 failures =
438 branch baseline + 4 new; Release build clean); earshot-changelog (Fixed +
Changed entries in repo-root CHANGELOG.md).

**Test count: 442** on this branch (438 branch baseline + 4). NOTE: SWIFTUI_PLAN's
442 figure for #421/#422 is post their unmerged PRs #423/#424; this branch reaches the
same 442 independently off the 438 `swift` tip. Set branch baseline to 442 once merged.

**Non-blocking follow-ups (do NOT block close):**
- earshot-testing flagged the drift test covers attribute names/optionality/valueType
  but not @Relationship topology (delete rules/inverse) or `.unique` markers. A change
  to those that keeps attribute shape would slip past. Worth a future enhancement issue
  to make it a full schema-hash guard.
- earshot-swift6 flagged the project is at `SWIFT_STRICT_CONCURRENCY: minimal`, not
  strict — true Swift 6 gating needs that raised in a separate migration issue.
- SWIFTUI_PLAN.md is at ~810 lines (target <400). Archive completed sections to
  docs/phases/swiftui/ in a separate housekeeping pass (not in this fix branch).

**Coordination — #423/#424 (open into `swift`, unmerged):** This migration fix lands
FIRST; #423/#424 rebase onto the optional field afterward. #423 will break at
`PodcastSettingsView` `Toggle("Notify on new episodes", isOn: $podcast.notificationEnabled)`
because `$podcast.notificationEnabled` is now `Binding<Bool?>` (won't compile against
`Toggle(isOn:)`), and `.onChange(of: podcast.notificationEnabled)` now observes an
optional. #423 must adopt the `Binding<Bool>` bridge this PR already lands
(get `{ podcast.notificationEnabled ?? false }`, set `{ podcast.notificationEnabled = $0 }`)
and observe `binding.wrappedValue`, plus coalesce any other `notificationEnabled` reads
it adds with `?? false`. #424 (Inbox count) does not touch `notificationEnabled` and
needs no field change, only a normal rebase onto the new `swift` tip after this merges.

**Device verification for Michael (UPGRADE path — required before merge/close):**
1. Install the PRIOR shipped build over a fresh device (or keep your current build).
2. In that build, create real data: subscribe to 2-3 feeds, queue a couple episodes,
   mark one played, add a bookmark, toggle "Notify on new episodes" ON for one show.
3. Build/install THIS branch's build OVER the existing app (do NOT delete first — a
   clean install proves nothing).
4. Confirm on launch: app reaches the normal screen (no crash, no reset), and your
   subscriptions, inbox/queue, played state, bookmark, and the notification toggle ON
   state all survived. The "Notify on new episodes" toggle should read ON for the show
   you enabled and OFF elsewhere.
5. If anything is missing or it crashes, stay on this branch and report back.

## Swift 6 Review — Track 2 (share-sheet OPML import)

earshot-swift6 gate: PASS. Branch `feat/opml-share-sheet` (uncommitted working
tree), reviewed via `git diff swift`. Files: NEW
`Earshot/Features/Subscriptions/Data/OPMLFileImporter.swift`,
`Earshot/App/RootView.swift`, `Earshot/Features/Settings/Presentation/SettingsScreen.swift`,
`Earshot/App/Info.plist` (+ NEW `EarshotTests/OPMLFileImporterTests.swift`).

Concurrency mode: SWIFT_STRICT_CONCURRENCY=complete build SUCCEEDED on iPhone 17 sim.
Full SWIFT_VERSION=6 + strict-complete build FAILS on the PRE-EXISTING baseline only
(NotificationDelegate.swift:59 "sending 'self' risks causing data races" — untouched by
this track; compiler halts there). Zero errors and zero non-macro warnings in any of
this track's changed files in either mode.

Findings:
- Actor isolation: `@MainActor enum OPMLFileImporter` is correct. `importFile(at:context:)`
  awaits `@MainActor OPMLImportService.importOPML` and `@MainActor Announcer.announce`
  with no actor hop — all on MainActor. PASS.
- ModelContext (NOT Sendable) boundary: helper, both call sites (RootView,
  SettingsScreen — SwiftUI Views, implicitly @MainActor), and the `Task { }` blocks are
  all MainActor. `context` from `@Environment(\.modelContext)` never crosses a nonisolated
  boundary; no illegal capture across an await. PASS.
- Sendable closures: `onOpenURL { url in handleIncomingFile(url) }` and the inner
  `Task { await OPMLFileImporter.importFile(...) }` capture only a `URL` (Sendable) and
  `self`/`context` (MainActor). No non-Sendable capture across an actor boundary. PASS.
- defer + await: `startAccessingSecurityScopedResource()` / `defer stop...` correctly
  brackets the awaited `importOPML`; scope released after import completes, all on
  MainActor. Race-free. PASS.
- Structured concurrency: uses `Task { }` (inherits MainActor), no `Task.detached`. PASS.
- Global state: none introduced. PASS.

Pre-existing baseline (NOT this track), reported separately as requested:
- NotificationDelegate.swift:59 — `sending 'self'` data-race (first hard Swift 6 error).
- DownloadManager.swift:41 — non-Sendable `Episode` param into MainActor impl.
- EarshotSchema.swift:24/343, EarshotSchemaV1.swift:17 — `versionIdentifier` global
  mutable state.
- RSSParser.swift:84/90 — static `ISO8601DateFormatter` not concurrency-safe.
- SubscriptionRepository.swift:32 — static `backfill` non-Sendable RefreshOutcome.
- SwiftData `#Predicate`/`@Query` `KeyPath` not-Sendable macro warnings across
  FoldersScreen, FolderRepository, InboxRepository, and RootView:306 (the pre-existing
  `route(_:)` notification predicate — NOT this track's `handleIncomingFile`).

New agents created: none. Overall: PASS.
