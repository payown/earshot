# Earshot SwiftUI Conversion Plan

Living task log for the SwiftUI rebuild. Maintained by the Planning Agent.

## September 5, 2026: iPhone feedback follow-up (#951)

Michael verified names, Queue navigation/wrapping and timers, Library/Settings,
Clear Queue cancellation, and improved hints. He requests one More options
entry and more accurate/larger Player touch targets before merge. Consolidated
episode commands and playback settings in a native List sheet, removed the
duplicate chapter entry, and retained direct chapter/transport and rotor access.
Play/Pause now has an 80pt label target, skips 64pt, and secondary buttons at
least 44pt. Native geometry/presentation checks and source review pending.
No TestFlight upload, issue closure, release or main merge; reinstall locally.

## September 5, 2026: delivery changed to direct iPhone installation

Michael requested Wi-Fi installation on his iPhone before TestFlight. No
TestFlight upload has occurred or is authorized for this step. Keep the build
number at 255; version 1.2.2 identifies the integration. Use a signed Release
build and devicectl over the paired local-network connection. Final Release
build and signature checks passed; 1.2.2 (255) was installed and launched on
Michael’s iPhone over Wi-Fi on September 5. The proposed
Chapter 82 remains a draft outside the canonical story until distribution.
The full simulator native suite passed 2,264 tests, with 29 skips and zero
failures. Final playback/media follow-up passed 73 tests; the final name identity
assertion also passed. Four of five selected UI flows passed initially; the
Queue-clear flow exposed an unreachable Cancel in confirmationDialog. Replaced
it with a native alert and reran that flow successfully. The required source
accessibility gate passed again for the final alert. Physical VoiceOver is
still pending. No main merge,
issue closure, or release before Michael verifies on his iPhone.

Draft PRs assigned to payown: #952 (names), #953 (hints), #954 (Queue
navigation), #955 (wrapping), and #956 (navigation cleanup). Each targets main;
none is merged. The integrated device checklist is in
`docs/feedback-device-test-2026-09-05.md`.

## September 5, 2026: Mac validation of Queue navigation (#949)

Xcode 26.6 / Swift 6.3.3: 163 PlaybackLogicTests and AdvancedPlaybackTests
passed on the iOS 26.5 simulator. Required source accessibility review found
missing spoken feedback for unusable audio. Fixed navigation to announce the
failure; explicit mark-and-next now validates the next source before changing
played state. Added regression coverage preserving the current episode, saved
position and Queue for both failure paths. Device VoiceOver remains pending.
Integration is on codex/feedback-integration; no merge to main or release.

## September 5, 2026: post-1.2.1 user feedback

Michael reports App Store approval of 1.2.1 and authorized implementation.
Issues: #947 custom podcast names; #948 player hints; #949 Previous/Next in
Queue; #950 optional wrap to earlier remaining Queue items; #951 UI navigation
cleanup. The code at 44002eb stops at the last queued item even if earlier
items remain. Wrapping does not mean resurrecting completed/removed episodes.

#949 first implementation is on feature/949-queue-navigation in a linked
worktree. Skipped episodes remain in their original Queue positions and retain
unplayed status and saved position. Explicit navigation follows displayed
Queue grouping and bypasses automatic stop preferences; manual episode starts
retain the existing sleep-timer/stop-after-current cancellation behavior.
First/last boundaries do not wrap. Existing Mark as played remains available
for unqueued episodes and its established auto-advance policy.

Validation: source/accessibility review and git diff --check only in this
workspace. Xcode and Swift are unavailable, so added XCTest coverage has not
run. Required next gate: Xcode tests, physical-device VoiceOver, then a
pre-merge test build. Do not merge or close issues until Michael verifies.
No signing, schema, purchase, reset, or release-number changes in this batch.
## September 5, 2026: Mac compilation of player hints (#948)

Xcode 26.6 / Swift 6.3.3 simulator Debug build succeeded. Required
Earshot accessibility source gate passed: existing labels, actions, and
Play/Pause semantics remain intact. Native integrated tests and physical
VoiceOver verification with hints on/off remain pending. No release or merge.

## September 5, 2026: player action discovery (#948)

Michael authorized work on post-1.2.1 feedback. Added concise discovery hints
on Skip back, Skip forward, and artwork; all existing labels/actions and
Play/Pause behavior remain intact. Play/Pause has no hidden action to explain.
Hints are guidance only; actions still work when VoiceOver hints are disabled.
Coordinate with #949 navigation additions; avoid duplicating system-provided
"Actions available" wording. Source-reviewed only: this workspace has no
Xcode/Swift or iPhone. Run native tests and verify hints on/off and action order
on device before merging. No issue closure or distribution performed here.
## September 5, 2026: optional Queue wrapping (#950)

Implemented on codex/950-queue-wrap. Default-off Wrap Queue to remaining
episodes uses the displayed grouped order, then excludes completed items.
Only natural completion and preload use wrapping; explicit Previous/Next and
mark-and-next remain nonwrapping. Continue-after-episode and group stops,
Stop after this episode, and sleep timers take precedence. Countdown timers
survive automatic advancement; expiration invalidates pending media resolution
and cannot be cancelled by an automatic start. Manual-start timer policy stays
unchanged. This is normal Queue policy only; #944 folder runs remain deferred.

The preference uses the existing mirrored scalar-setting contract. No schema,
signing, reset, purchase, or folder-run changes. Source accessibility gate
passed after correcting order-before-filtering and timer-expiry races. Native
focused tests: 172 passed on Xcode 26.6 / iOS 26.5 before final additional
unusable-target/completion-save guards; rerun and integrated suite pending.
Device VoiceOver and integrated pre-merge TestFlight remain pending. No merge.
## September 5, 2026: personal podcast display names (#947)

Implemented on codex/947-podcast-names. Podcast Settings opens a draft name
editor with Save, Cancel, and Restore original name. Blank names are rejected;
save failures keep the editor open. Publisher title remains refresh-owned and
unchanged. Followed-podcast presentation uses an observed in-memory name map,
loaded only at settings initialization/import or explicit rename, so row reads
never fetch settings or episodes. Library sorts by effective name; local and
podcast-detail searches accept both personal and publisher names. Player and
Queue group speech use effective names. Directory/catalog-only titles stay
publisher-owned. Shared files/text (OPML, audio/transcript exports, CSV, and
Listening Places labels) retain publisher names for portability.

Persistence decision: canonical-feed-keyed AppSetting, mirrored through the
existing private CloudSettingProjection contract, no new schema/entity/field.
Normal newest-modified contribution wins; ties use existing source-device ID
then value ordering. Restore writes an explicit empty value, not row deletion,
so stale contributions cannot revive an older override. Followed-feed scoping
applies to publication, activation, and imports. No new CloudKit schema rollout.

Initial native gates passed 61 tests (one pre-existing intentional search
capability skip), including schema drift, editor logic, and search. Source
accessibility review found and fixed podcast-detail search invalidation and
refresh-failure row names. Added disk-reopen, two-device projection/restore,
local-name search, 10k-episode cached lookup, and editor UI coverage; final
rerun/integrated tests pending. Physical VoiceOver and TestFlight remain
pending. No main merge, issue closure, purchase/reset/signing or #944 changes.
## September 5, 2026: navigation cleanup (#951)

Implemented on codex/951-navigation-cleanup. Library toolbar goes from six
controls to five: Search, Folders, Refresh, Library options, Discover. Sort and
Select move under Library options; current sort is still spoken and Done stays
direct while selecting. Frequent refresh and existing per-row rotor actions
remain direct. Queue options has Organization, Downloads, Saved lineup, and
separate Clear queue groups. Clearing requires confirmation for the entire
Queue, explains download retention, and announces success only after saving;
focus returns to the Queue heading. Player options now consistently names its
opener and sheet and hints at sleep timer, volume boost, and chapters.
Settings destinations are grouped into Listening, Personalization, Library and
sync, and Help and privacy. Purchase UI is unchanged.

Task audit: Inbox and podcast details retain their current search, filters,
row actions, and settings entry points; no extra hierarchy was added there.
Source accessibility review passed. Simulator build-for-testing succeeded;
Queue-clear UI regression and full integrated tests pending. Physical checks:
Explore by Touch, swipe order, menu dismissal focus, largest Dynamic Type,
and hints enabled/disabled. No merge, issue closure, or release.

> **2026-07-30 — restructure.** SwiftUI is now the primary codebase and the app
> lives at the **repo root** (it was under `EarshotSwift/` while this plan was
> written, so older entries below reference that path — read them as historical).
> The retired Flutter app moved to `archive/flutter/` (restore point: tag
> `flutter-final`). `main` is the SwiftUI trunk. See root `CLAUDE.md`.

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
| Migration — Flutter→SwiftUI subscription import | #354 | [x] | REMOVED (#580). The migration was abandoned 2026-06-25; OPML is the only re-import path. `FlutterMigrationService`, `MigrationGate`, the importers, the Data Import UI, the RootView launch wiring (including the per-launch SQLite diagnostics), and the Settings → Data "Import older data" surface were all deleted. The `flutter_migration_*` / `migration_*` setting keys are retained as unread constants for data compatibility only. |
| Audio DSP | #352 | [~] | DONE pending device verify. `AudioEnhancementLogic` (pure mode/channel mapping, tested both ways). `configureSession` now conditional on `voiceEnhanceEnabled` (was hardcoded `.spokenAudio`); `applyAudioEnhancement()` sets mode + `setPreferredOutputNumberOfChannels` (1 mono / 2 stereo); all `AVAudioSession` calls in do/catch + `AppLog.player` (no silent `try?`). Public `effectiveRate` + `reapplyRate()`. RootView `.onChange` re-applies global speed + voice-enhance mid-playback (observation-based, not NotificationCenter). Per-podcast `speedOverride` has no setter UI yet (deferred F7) — `reapplyRate()` ready for it. Mono is audible only on device. |
| BUG — tab switching blocked during playback | #362 | [x] | Per-second synchronous main-actor SwiftData `context.save()` from the 1s time observer starved the run loop, freezing TabView selection while audio played (severe VoiceOver nav regression). Fixed by throttling the per-tick position write to a 5s cadence via pure `PlaybackLogic.shouldPersistTick`; eager saves on pause/seek/episode-switch/30s-flush keep durability. All gates passed (security, testing, swift6, changelog; a11y N/A — no view changed). 210 tests green (was 204). Branch `fix/issue-362-tab-switching-playback`. Awaiting device verification. |
| BUG — auto-download of newest episodes doesn't work | #639 | [x] | Two compounding bugs, both fixed. (1) `SubscriptionRepository.refresh(_:)`/`refreshAll(...)` never triggered auto-download for newly-discovered episodes on already-subscribed podcasts — only subscribe-time and OPML-import had it wired (an unfinished F8 follow-up, never completed). `RefreshOutcome` now carries `newEpisodeIDs: [PersistentIdentifier]` (resolved only AFTER `context.save()`, mirroring `subscribeAll`'s pending-ID pattern in `FeedRefreshActor`, since a pre-save read would silently reintroduce the bug); backfill passes correctly report zero new-episode IDs. `refresh`/`refreshAll` now call the existing `autoDownloadRecent(episodeIDsPerPodcast:)`. (2) The app's one real, shared `DownloadManager` was never threaded into ANY UI call site that constructs `SubscriptionRepository`/`OPMLImportService` (`AddFeedView`, `SubscriptionsView`, `SearchView`, `PodcastPreviewView`, `EpisodeListView`, OPML import) — all relied on the `downloader: nil` default, so even the working subscribe-time auto-download never fired from real usage. Now wired via `@Environment(DownloadManager.self)` at every call site. **Implemented by:** earshot-data. **Gates:** earshot-security PASS, earshot-swift6 PASS (one pre-existing unrelated strict-concurrency warning noted, not introduced here), earshot-accessibility PASS (no VoiceOver/announcement/focus surface change — download start stays silent, matching the pre-existing subscribe-time behavior), earshot-testing PASS (+9 tests total: 6 from earshot-data, 3 from the gate covering the `autoDownloadCount == 0` off-switch and partial-refreshAll cases). **1141 → 1144 tests**, Release build clean. **PR #654** squash-merged into `swift` (`09e7767`). Reported by TestFlight tester Greg Wocher on 1.0.0 (150). Not yet deployed to TestFlight (requires separate approval). |
| BUG — no way to add a podcast to inbox with "Opt-in podcasts only" enabled | #668 | [x] | Root cause: pre-existing SwiftUI-rebuild parity gap, **not** a #659 regression (#659 was unrelated Mark-All-as-Played work). `Podcast.inboxIncluded` has existed since F2 (#337) and was already read/enforced by `InboxRepository.isExcluded(_:optInOnly:)`/`InboxLogic.isExcluded`, but no SwiftUI surface ever wrote it — the Flutter original's dual-mode `PodcastAction.toggleInboxExcluded` custom action (`all_podcasts_screen.dart`) was never ported. Fix (scoped to the opt-in path only, per the issue): new `PodcastAction.toggleInboxInclude` Quick Action (rotor, label "Add to Inbox"/"Remove from Inbox", toggles `inboxIncluded`, non-assertive `Announcer.announce` matching the `.toggleAutoQueue`/`.toggleNotifications` convention), filtered out of the rotor entirely when opt-in mode is off; a leading-edge sighted swipe action on Library rows gated on `!voiceOverEnabled && settings.inboxOptInOnly` (mirrors the existing Unfollow swipe/rotor split, #597); an "Include in Inbox" `Toggle` in `PodcastSettingsView`'s Inbox section, shown only when opt-in mode is on (native switch announcement, no custom `Announcer` needed). **Deliberately out of scope:** the symmetric "Exclude from Inbox" toggle for normal (non-opt-in) mode — `Podcast.inboxExcluded` also exists and is enforced but has no UI either; a separate, unreported gap, to be filed as a follow-up issue. **Implemented by:** earshot-ui. **Gates:** earshot-security PASS (no fix needed; logged review, commit `88c3eb3` — no force-unwraps, silent `try?`, retain cycles, or `@MainActor` violations; writes route through the existing `saveQuickAction` do/catch helper), earshot-swift6 PASS (no fix needed, no commits — no `@Model`/`ModelContext` crosses an actor boundary, no `Task.detached`, new arm matches `.toggleAutoQueue`'s isolation exactly, zero new warnings under an informational `SWIFT_STRICT_CONCURRENCY=complete` pass), earshot-accessibility PASS (no fix needed, no commits — rotor/swipe labels unambiguous and state-derived, correct opt-in-mode filtering verified against dedicated tests, icon+text swipe label not color-only, non-assertive announcement convention confirmed correct), earshot-testing PASS (gate added `PodcastSettingsViewTests` Toggle-binding coverage, a gap found during review — commit `462cbac`). **1254 → 1266 tests** on the isolated worktree before the final `swift`-rebase pulled in #663-#667's own test growth (1314 after rebase, all pre-existing); the only failures throughout were the already-known StoreKit sandbox (`SKTestSession`) `ProductCatalogServiceTests`/`PaywallViewModelTests` failures, confirmed unrelated (untouched by this diff). Release build clean. CHANGELOG updated (Fixed + Accessibility). CI green. **PR #670**, merging into `swift`. Reported by beta tester Bel, same class as #639. |
| FEATURE — no way to exclude a podcast from inbox in normal (non-opt-in) mode | #671 | [x] | Mirror-image companion to #668, deliberately left out of that issue's scope. `Podcast.inboxExcluded` existed since F2 and was already enforced by `InboxRepository`/`InboxLogic` (same pattern as `inboxIncluded`), but had no UI. Fix mirrors #668 inverted: new `PodcastAction.toggleInboxExclude` Quick Action (rotor, label "Exclude from Inbox"/"Include in Inbox", toggles `inboxExcluded`, same non-assertive `Announcer.announce` convention), filtered into the rotor only when opt-in mode is **off**; a leading-edge sighted swipe action on Library rows gated on `!voiceOverEnabled && !settings.inboxOptInOnly`; an "Exclude from Inbox" `Toggle` in `PodcastSettingsView`'s Inbox section shown only when opt-in mode is off (native switch announcement). `rotorActions(for:)` restructured from a boolean one-liner into a guard+if cascade to hold both #668's and #671's filters (verified logically equivalent to the prior #668-only expression by truth table, no regression). **Design call:** kept the two toggle directions as parallel, separately-named code rather than a shared `direction:`-parameterized helper — each side reads clearly enough on its own; only the rotor filter itself was consolidated. **Implemented by:** earshot-ui. **Gates:** earshot-security PASS (no fix needed, logged review — no force-unwraps, silent `try?`, retain cycles, or `@MainActor` violations; also independently re-verified the rotor-filter restructuring didn't regress #668), earshot-swift6 PASS (no fix needed — new arm matches `.toggleInboxInclude`'s isolation exactly, zero new warnings under an informational strict-concurrency pass), earshot-accessibility PASS (no fix needed — state-derived unambiguous labels, non-assertive announcement with no double-announce against the native Toggle, no color-only signaling), earshot-testing PASS (found and closed one real coverage gap — combined `inboxExcluded && inboxIncluded` override routed through `InboxRepository` in normal mode specifically — added `testNormalModeExplicitlyIncludedOverridesExcludedFlag`). **1314 → 1327 tests** (13 net new: 12 from implementation + 1 from the testing gate). Only failures throughout were the already-known StoreKit sandbox (`PaywallViewModelTests`/`ProductCatalogServiceTests`) failures, confirmed unrelated. Release build clean. Rebased onto `swift` tip (past #672's dart-format-hook fix) before merge — clean, no conflicts. CHANGELOG updated (Fixed + Accessibility). **PR #675** (squash), merge commit `45010ce`. **Note:** GitHub Actions CI did not run on this PR — account-level billing/spending-limit failure (`recent account payments have failed or your spending limit needs to be increased`), unrelated to this code; all gates verified via local `xcodebuild` runs instead (full suite + Release build). This will block CI on every future PR until Michael resolves it in GitHub billing settings. |

**Follow-up from #362 security gate — FIXED by #653:** `PlayerService.persistPositionThrottled`
(and the prior per-second save) lacked an `isPlayed` guard, so a tick after the
95% played threshold could rewrite a stale non-zero `positionSeconds` over the
just-zeroed value. Flagged as pre-existing/cosmetic/out-of-scope during #362 but
never filed until the App Store 1.0 launch-readiness audit surfaced it as #653.
Fixed: `PlaybackLogic.shouldPersistTick` gained an `isPlayed` parameter (returns
`false` unconditionally when true), wired at the `persistPositionThrottled` call
site via `episode.isPlayed`; `persistCurrentPosition()` (the eager pause/seek/
episode-switch anchor) got the same inline guard since `pause()` can land in the
identical race window. 4 new `PlaybackLogicTests` + 2 new `AdvancedPlaybackTests`.

### Migration — Flutter-side tasks (OBSOLETE — feature removed, #580)

The Flutter→SwiftUI migration was abandoned 2026-06-25 and its remaining dead
code (launch wiring, migration service, importers, Settings surface) was deleted
under #580. None of the App Group / export-DB tasks that used to live here will
ship; OPML export/import is the supported way to carry a library over.

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

- **Issue #652 (Release — verify/add CI upgrade-path test for schema V4 migration; App Store 1.0 Launch milestone; VERIFICATION-ONLY, no code changes):** Audited whether every SwiftData schema bump (current schema is **V4**, no V5 in progress) has the per-step migration test required by `.claude/rules/database-migrations.md` rule 6, in the wake of the #529 wipe incident. Coverage was already complete: `StoreMigrationTests.swift` (V1→V2 manual export/reimport — rich fixture: 3 podcasts, mixed played/unplayed, NULL description/pubDate, empty-episode podcast; also covers the #529 backup-before-delete regression + reopen-idempotency), `StoreMigrationV2toV3Tests.swift` (V2→V3 lightweight, `notificationEnabled`→optional — 2 podcasts, NULL optionals, queue item, bookmark, folder+membership), `StoreMigrationV3toV4Tests.swift` (V3→V4 lightweight, adds `introSkipSeconds` — podcast with a realistic `speedOverride`, asserts the new attribute reads nil on migrated rows and is writable afterward). All three run the actual production `StoreMigration.openOrMigrate`, build a REAL on-disk store at the prior schema (not `onCreate`), and assert data survival. `SchemaDriftTests.swift` is a complementary (not rule-required) guard against the #425 crash class — fails CI if the live model graph drifts from its last frozen snapshot without a version bump. **Own read of `ModelContainerFactory.swift` confirmed the #529 fix is real:** `load(at:)` never auto-wipes on any open failure — a newer-than-app store is left completely untouched, a genuinely corrupt store only offers a user-consented `resetCorruptStore` which backs up (`backupStoreFiles`) before deleting (`removeStoreFiles`). **Gates:** earshot-security PASS (two minor pre-existing non-blocking findings, not introduced here and not filed as separate issues per the existing "file if it surfaces" precedent: (1) `ModelContainerFactory.inMemoryContainer()` has a `fatalError` on the empty in-memory fallback failing to build — never touches user data; (2) a narrow double-failure window where `write(snapshots, into:)` throwing right after a failed `backupStoreFiles` could lose both copies — already logged, disk-full-twice class of failure), earshot-swift6 PASS (all migration/test code consistently `@MainActor`, no `@Model`/`ModelContext` crosses an actor boundary, `autoreleasepool` blocks are synchronous/non-escaping; verified clean under `SWIFT_STRICT_CONCURRENCY=complete` for these six files specifically — one unrelated pre-existing compiler-internal crash surfaced at `QueueScreen.swift:100` under that override, tied to the in-progress #390 Swift 6 migration, not a regression from this issue), earshot-accessibility N/A (no UI touched). **Test suite:** 1,142 executed, 1 skipped, 0 unexpected failures (one `AdvancedPlaybackTests` flake reproduced full-suite but confirmed passing in isolation — pre-existing isolation flake, unrelated to migrations). No CHANGELOG entry (nothing user-facing changed, per this issue's explicit "skip if verification-only" allowance). **Separate structural gap found and filed as #656** (not fixed here, out of scope): `.github/workflows/` only runs Flutter CI — there is no GitHub Actions workflow that builds/runs the Swift/SwiftData test suite at all, so the migration tests' "required gate" status is enforced manually today, not automatically on every PR. Closed #652 directly with no branch/PR needed for the verification itself; this `SWIFTUI_PLAN.md` update is the only diff, done in an isolated worktree per the parallel-agent-branch-hygiene lesson above (the shared main working tree was mid-use by another concurrent agent on `feat/issue-631-storekit-config` when this write was attempted).

- **Issue #656 (Release — no GitHub Actions workflow runs the Swift/SwiftData test suite; App Store 1.0 Launch milestone):** Closes the structural gap #652 identified: `.github/workflows/` previously only ran Flutter CI, so the `EarshotTests` suite (1,142+ tests, including the migration "required gate" tests) only ran when a human or agent remembered to invoke `xcodebuild test` locally. New `.github/workflows/swift-ci.yml` builds `EarshotSwift/Earshot.xcodeproj` and runs the full `EarshotTests` suite via `xcodebuild test` on every push/PR into `swift`, no path filters (so it always runs and is safe to mark Required in branch protection — a path-filtered required check that never fires on a given PR leaves that PR stuck pending). **Xcode/simulator pin:** the `macos-15` runner's default Xcode is 16.4, which predates the iPhone 17 simulator device used by every local `xcodebuild test` invocation in this codebase; `maxim-lobanov/setup-xcode@v1` with `xcode-version: latest-stable` selects the newest stable Xcode on the image (confirmed via `actions/runner-images`' documented macOS 15 readme to include 26.x with iPhone 17 in its iOS 26.x simulator runtimes) instead of hardcoding a patch version that would go stale on routine image updates. **No xcodegen in CI:** `Earshot.xcodeproj` is committed to the repo (per `EarshotSwift/README.md` — local devs regenerate it from `project.yml` only when `project.yml` changes, then commit the result), so CI builds the committed project directly. `CODE_SIGNING_ALLOWED=NO`/`CODE_SIGNING_REQUIRED=NO` avoid needing a signing identity the runner doesn't have. **Verified locally first:** ran the exact `xcodebuild test` command against simulator UDID `38284C7C-E08A-40E5-AACA-C654C8A48E2A` (a `StoreMigrationTests` subset) before writing the workflow YAML; validated the YAML with `actionlint` (clean). **Verified in a real Actions run:** pushed the branch and confirmed the workflow triggers on PR #662 and completes successfully (see PR for the run link) before merging — proving the pipeline itself works is the real test for a CI-infrastructure change. **Gates:** earshot-security PASS (no secrets referenced, `pull_request` not `pull_request_target`, third-party actions pinned by tag; two non-blocking hardening suggestions — explicit `permissions: contents: read`, SHA-pin `maxim-lobanov/setup-xcode` — left as follow-up, not blocking). earshot-accessibility/earshot-swift6 N/A (no UI, no Swift code changed). CHANGELOG: one "Behind the scenes" Added bullet (closes #656), matching the existing convention for non-visible engineering work (e.g. #631's StoreKit catalog entry). Also documents the new gate in `.claude/rules/git-workflow.md` under a new "Swift CI (branch: swift)" section, including the still-manual follow-up: branch protection on `swift` must be turned on in repo settings to actually require the "Build and test (EarshotTests)" check (not doable from a code PR). **PR #662** into `swift`. Implemented and merged directly (CI-infrastructure-only, no device verification applicable — the real verification is the Actions run itself, confirmed green before merge).

## Audio Decisions

- **Decision (#549 — garbled/pitch-shifted audio burst before export):** No
  `AVPlayerItem` ever had an explicit `audioTimePitchAlgorithm`, so the framework
  default (`.lowQualityZeroLatency`-class variable-rate processing, supported
  range 0.5×–2.0×) served an engine that plays 0.5×–5.0× plus a 4× fast-forward
  scan; on render-pipeline reconfiguration it can flush a buffered chunk at the
  wrong rate/pitch — the tester-reported burst in the stop → menu → export
  sequence. **Fix:** `PlayerService.makePlayerItem(url:)` is now the sole
  construction point for every player item (shared `play()` path, `load()`
  restore, gapless preload) and sets `audioTimePitchAlgorithm = .spectral`.
  **Algorithm choice:** `.spectral` over the issue's proposed `.timeDomain` —
  both support 1/32×–32×, but time-domain overlap-add gets choppy on speech
  above ~2–3×, under this app's 5× ceiling; spectral is pitch-preserving across
  the whole range and its single-stream CPU cost is negligible. Any future
  `AVPlayerItem` creation must go through the helper. **Sequencing fix (same
  issue):** the shared `play()` path called `replaceCurrentItem(with:)` while
  the outgoing episode could still be playing (`rate != 0`), letting the new
  item audibly render from 0:00 at the inherited rate before the resume seek
  landed; `player.pause()` now precedes the swap (no-op for gapless advance —
  the finished item already left the player paused). Export path audit came back
  clean: export never plays audio, DownloadManager never touches the
  player/session, no `setActive(false)` exists, and stall recovery is gated on
  `intendsToPlay`. **File:** `PlayerService.swift` only. Ears-only device
  verification pending.

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

- **Decision (#522 — streaming stalls + overheating, no stall recovery):**
  `PlayerService` had no buffer/stall resilience — no `playbackStalledNotification`
  observer, no `isPlaybackBufferEmpty`/`isPlaybackLikelyToKeepUp` KVO, no
  `timeControlStatus` watch, and `automaticallyWaitsToMinimizeStalling` was never
  set. When a streamed item's buffer emptied, AVPlayer paused and nothing
  re-issued `play()`, so the user had to manually resume (the "stopped 3 times,
  magic-tap" report); the heat was the radio thrashing through repeated
  rebuffering. **Fix:** explicitly set `automaticallyWaitsToMinimizeStalling =
  true`; observe the player's `timeControlStatus` (logging `reasonForWaitingToPlay`
  while `.waitingToPlayAtSpecifiedRate`), the per-item buffer KVO, and the stall
  notification; and re-issue `play()` exactly once the buffer recovers AND the
  user still intends playback. The decision is a pure, unit-tested
  `StallRecoveryLogic.shouldResume(intendedToPlay:isLikelyToKeepUp:timeControlStatus:)`
  that returns true only when intent holds, the player has settled into `.paused`
  (the `.waiting` case is left to AVPlayer's own auto-resume), and the buffer is
  `likelyToKeepUp`. A new `intendsToPlay` flag (set on play/resume, cleared on
  pause and every end-of-playback stop) keeps a deliberate pause from being
  overridden and stops a finished/ended item from being auto-replayed. The
  `.paused` gate means one recovery flips the player to `.playing`, so repeat
  observer callbacks no-op — no busy-loop, no repeated hammering. **Buffer policy:**
  `preferredForwardBufferDuration` left at default (0 = automatic) on each item —
  a fixed large value raises startup latency/memory and a fixed small value
  invites more rebuffering, so AVPlayer's adaptive buffering plus the auto-resume
  is the lower-risk pairing rather than a guessed pin. Per-item KVO tokens are
  invalidated before each `replaceCurrentItem` so there are no dangling
  observers; all observer closures hop to the main actor via `Task { @MainActor }`
  with `[weak self]`. **Secondary:** `ID3TagFetcher.prefix(of:upTo:)` accumulated
  the ranged prefix one byte at a time into `Data` (per-byte `Data.append` was the
  hot spot for a multi-hundred-KB tag); now buffers into a contiguous `[UInt8]`
  and converts to `Data` once, still streaming with the 2 MB cap (not a single-shot
  `data(for:)`) so a server that ignores `Range` and returns `200` still stops at
  the cap. **Issue:** #522. **Files:** `StallRecoveryLogic.swift` (new pure type),
  `PlayerService.swift` (observers + `intendsToPlay` + recovery glue),
  `ID3TagFetcher.swift` (chunked buffer), `StallRecoveryLogicTests.swift` (+6 tests).
  Debug build green on iPhone 17 simulator.

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

- **Decision (#508 — observe current chapter + previous/next navigation):** The
  chapter ENGINE (resolution + `activeChapterIndex(at:)` + auto-skip) already
  existed but `currentChapters` is `@ObservationIgnored private`, so the UI could
  not surface the active chapter. **Added an observable surface alongside** the
  private list: `currentChapterTitle: String?`, `currentChapterIndex: Int?`, and
  `chapterCount: Int` on `PlayerService`. The index/title are recomputed by a new
  private `updateCurrentChapter()` called from `handleTick`. **Per-tick thrash is
  avoided** by an early-return when `activeChapterIndex(at:)` equals the cached
  `currentChapterIndex` — `@Observable` state is only written when the active
  chapter actually changes, not every 1 Hz tick. The surface is reset on episode
  switch (`resetChapterObservables()`, paired with `currentChapters = []`) and
  refreshed when a chapter list is installed (both `setChapters` and the async
  `loadChaptersForCurrentEpisode` completion clear the cached index first so the
  refresh isn't suppressed by the same-index guard). The auto-skip engine
  (`evaluateChapterAutoSkip` / `toggleChapterSkipped` / `lastAutoSkipFromChapterIndex`)
  was left untouched. **Manual prev/next:** `previousChapter()` / `nextChapter()`
  navigate by index regardless of the deselected/skip set (a manual override),
  driven by a new pure, unit-tested `ChapterNavLogic` (returns a target index
  from `currentIndex + count + positionWithinChapter`). `nextChapter` seeks to
  the next chapter start, no-op past the last; `previousChapter` restarts the
  current chapter when > `ChapterNavLogic.previousRestartThreshold` (3s) in,
  otherwise steps to the prior chapter, clamped at the first. Both seek via the
  existing `seek(to:)` and announce "Chapter: <title>" via `Announcer` — MANUAL
  changes announce; automatic chapter changes during playback update the label
  **silently** (too chatty otherwise). **UI:** `NowPlayingScreen` shows a chapter
  line below the title (plain labeled element, label "Chapter" / value = title;
  `// #509:` seam to make it the chapter-list button later) and a prev/next
  control row below the transport (44pt targets via the shared `transportButton`),
  both shown only when `chapterCount > 0`; prev/next are also artwork rotor
  actions. **Files:** `ChapterNavLogic.swift` (new), `PlayerService.swift`,
  `NowPlayingScreen.swift`, `ChapterNavLogicTests.swift` (new, +13 tests). 781
  tests (768 baseline + 13); the lone failure
  (`SettingsStoreTests.testFactoryResetRemovesArtworkCacheDirectory`) is a
  pre-existing full-suite isolation flake unrelated to chapters — passes in
  isolation. **Issue:** #508 (#509 stacks: chapter list + deselect-to-skip UI).

- **Decision (#517 — stream-only from Search directory preview):** Episode rows in
  a directory result's `PodcastPreviewView` are now playable, streaming directly
  through the existing player engine WITHOUT subscribing, downloading, or writing
  anything to the store (confirmed by Michael: stream-only, no library/Stats/queue
  side effects, schema frozen per #425). **Approach:** `PlayerService.playPreview(...)`
  builds a detached `Episode` (created via `init`, NEVER inserted into a
  `ModelContext`) and plays it through the shared private `play(_:preparedItem:transient:)`
  path with a new `transient` flag. A real-but-detached `@Model` lets the whole
  engine (rate, audio session, scrubber, Now Playing bar, lock screen, chapters via
  `loadChaptersForCurrentEpisode`, resume/pause/seek which need `currentEpisode != nil`)
  work unchanged. `currentEpisodeIsTransient` gates every persistence sink:
  `flushListeningSession` (the real pollution vector — `context.insert(session)`
  would pull the detached Episode in), `persistCurrentPosition`,
  `persistPositionThrottled`, `markCurrentEpisodePlayed`, and
  `persistLastPlayingEpisode`. The flag is set exactly where `currentEpisode` is
  assigned, so it always reflects the loaded episode; every real entry point
  (`play(_:)`, `play(_:at:)`, `load(_:)`, auto-advance) passes/sets `transient =
  false`, restoring full persistence after a preview. **Completion path is clean
  WITHOUT extra gating:** `handlePlaybackEnded` → `markPlayedAndRemove` →
  `remove` guards on `episode.queueItem` (nil for a detached episode) so it
  no-ops; `nextAdvanceID` for an id not in the queue returns nil → playback stops
  with `currentEpisode = nil`; the `finished.positionSeconds = 0` write mutates a
  detached object so `context.hasChanges` stays false and `saveContext` no-ops.
  The preview row is a `Button` (a single VoiceOver element — one stop per row
  preserved) that announces "Streaming <title>"; rows with no enclosure URL render
  as static, non-playable rows. `PreviewEpisode` carries `audioURL` +
  `episodeDescription`/`artworkURL`/`chapterURL` through from the parsed feed; it
  is a plain Search-feature value type, NOT a `@Model`, so this does not touch the
  frozen schema. **Swift 6 note for the gate:** `playPreview` and the new flag are
  `@MainActor`-isolated on `PlayerService` like all surrounding state; the detached
  `Episode` is a main-actor `@Model` and never crosses an actor/Sendable boundary
  (only Sendable strings cross into `ChapterService` via the existing
  `loadChaptersForCurrentEpisode` path). **Files:** `PlayerService.swift`,
  `PodcastPreviewModel.swift`, `PodcastPreviewView.swift`,
  `AdvancedPlaybackTests.swift` (+4), `PodcastPreviewModelTests.swift` (+1).
  **Issue:** #517. **Testing gate (earshot-testing):** 837 tests, 0 failures
  (swift-tip baseline 832 → +4 implementer +1 gate); Release build clean. The
  gate added `test_playPreview_playbackEnds_stopsCleanlyWithoutInserting` to cover
  the natural-end-of-track invariant directly (posts
  `AVPlayerItem.didPlayToEndTimeNotification`, polls until `nowPlayingEpisode ==
  nil`, asserts Episode/ListeningSession/QueueItem counts unchanged). The
  implementer's suite already covered no-store-writes on play, empty-audioURL
  no-op, and persistence-restored-after-preview. **Test baseline of record: 837.**

## UI Decisions

- **Episode multi-select + batch folder actions (#758, Folders Phase 2).**
  Reuses the #757 scaffold unchanged (`MultiSelectState`, `MultiSelectBar`,
  `SelectableRow`, the noun-agnostic `MultiSelectActionLabel` with
  `itemSingular: "episode"`, and `FolderPickerView`'s `onComplete` hook). Wired
  into `InboxScreen` and `EpisodeListView`. To render the checkbox rows through
  the SAME `SelectableRow` component as podcasts (one selection component, one
  `.isSelected`-not-`.isToggle` semantics), `EpisodeRow`'s visual body was
  extracted into a reusable `EpisodeRowContent`; the new `EpisodeSelectableRow`
  feeds that content to `SelectableRow` with an `EpisodeRowLabel`-built spoken
  name identical to the normal row's. This REPLACED Inbox's bespoke #595
  selection (which used `EpisodeRow.SelectionState` + `.isToggle` and a single
  toolbar "Add to Queue"); that path is gone. Bottom bar actions: Add to folder
  (primary) + Move to folder on both screens, plus the natural, low-risk episode
  batches — Add to queue on both, and Mark as played on Inbox (triage screen,
  reusing `InboxRepository.markPlayed`). Deliberately scoped OUT: batch Download
  (kept bars short; less central than folders/queue), and batch Mark-as-played on
  `EpisodeListView` (it already has a whole-podcast "Mark all as played"). Focus
  re-anchor diverges from #757's first-row anchor because Inbox's queue/played
  batches REMOVE rows: `exitSelection` anchors to the empty state when the batch
  emptied the inbox, else the stable Select/Done toolbar button (checked against
  a fresh `InboxRepository().inboxEpisodes()`); `EpisodeListView` anchors to the
  Select button (folder-file/queue-add never empty a full episode list); folder
  batches still stagger the focus move to +0.9s past the picker's +0.5s result
  announcement. Queue/played announcements carry the episode noun ("Added 3
  episodes to queue") to match the folder path's phrasing (pure
  `EpisodeBatchLabel`). Single-item rotor "Add/Move to folder" from #756 is
  preserved on the normal rows — multi-select is additive. earshot-accessibility
  gate: PASS, no required fixes.
- **FolderDetailScreen Episodes section — surface episode membership (#759, Folders Phase 2).**
  Below Subfolders and Podcasts, a real `.isHeader` "Episodes" section lists the
  hand-picked episodes a folder holds via `EpisodeFolderMembership`
  (`FolderRepository.episodes(in:)`). Rows reuse the shared `EpisodeRow`
  (`includesPodcastName: true` — a folder mixes shows) with actions from the
  shared `buildEpisodeActions(...)` plus a destructive "Remove from folder"
  appended LAST (so it never displaces `actions.first`, the row's default
  double-tap / primary rotor action) — surfaced through `EpisodeRow`'s existing
  `.quickActionsRotor`. Remove calls `FolderRepository.removeEpisodes([episode],
  from:)` (drops only the join row; the episode is untouched), announces via the
  pure `FolderDetailLabel.removeEpisodeAnnouncement`, and re-anchors
  `@AccessibilityFocusState` to the neighbor captured BEFORE removal (or the empty
  state when it was the last episode) — never the removed row. Because
  `episodes(in:)` reads a detached `FetchDescriptor` (EpisodeFolderMembership has
  no inverse on PodcastFolder, by design), it is NOT observed like `members` /
  `subfolders`; a `@State` reload token, read inside the `episodes` computed
  property, forces the one re-render after an in-screen remove. A real spoken
  empty state (`FolderDetailLabel.episodesEmptyTitle` / `episodesEmptyDescription`,
  `.combine`d) shows when the folder holds no episodes; the whole-screen
  ContentUnavailableView is reserved for a completely empty folder (no subfolders,
  podcasts, or episodes). Coexistence with #757 podcast multi-select: the Episodes
  section is hidden entirely while podcast-selection mode is active (matching how
  the Podcasts section swaps to checkbox rows), so nothing competes with a podcast
  selection. Episode multi-select is out of scope (#758 owns it); "Unfollow this
  podcast" and the mark-played focus runner are intentionally omitted from the
  folder episode row (a folder row is about the episode and its membership, and
  marking played here doesn't remove the row). New pure strings live in
  `FolderDetailLabel` so the header/empty-state/announcement wording is
  unit-testable.
- **Reusable multi-select scaffold + podcast batch folder actions (#757, Folders Phase 2).**
  New generic scaffold under `Earshot/Core/UI/`, built so #758 (episode
  multi-select) drops it in unchanged: `MultiSelectState` (an `@Observable`,
  UI-free holder over `Set<PersistentIdentifier>` — enter/exit/toggle/count/
  clear, no announcing or focus so it's fully unit-testable); `MultiSelectBar`
  (a persistent bottom bar whose primary button label carries the LIVE count and
  is the count's accessibility source of truth, plus caller-supplied secondary
  actions — `MultiSelectAction` has a STABLE `id` distinct from its count-
  carrying title so the `ForEach` doesn't rebuild buttons on every tap; a polite
  600ms-debounced "N selected" via `.task(id:)`); and `SelectableRow` (leading
  filled/hollow checkmark glyph + `.isSelected` trait + accent color — never the
  word "selected" in the label and never color alone; full-row 44pt tap target).
  Count-carrying labels live in the pure `MultiSelectActionLabel` enum (noun-
  agnostic: "Add 3 podcasts to folder" / "Add 3 episodes to folder"). Wired into
  `SubscriptionsView` (Library — Add/Move) and `FolderDetailScreen`'s Podcasts
  section only (Add/Move/Remove; Remove calls `FolderRepository.removePodcasts`
  directly, the others reuse the shared `FolderPickerView` batch). A "Select"
  toolbar entry enters selection mode (announces "Selection mode on", moves
  `@AccessibilityFocusState` to the first row); "Done" exits (announces off).
  Batch Add/Move reuse `FolderPickerView`, extended with an additive optional
  `onComplete` hook (fires only on a real pick, not Cancel) so the screen auto-
  exits selection mode and re-anchors focus AFTER the mutation (never a removed
  row); the focus re-anchor is staggered to +0.9s so its row-name utterance
  doesn't collide with the picker's +0.5s result announcement. The single-item
  rotor "Add/Move to folder" from #756 is preserved — multi-select is additive.
- **Podcast settings Folders section + "Add to folder" picker (#754, Folders Phase 1).**
  `PodcastSettingsView` gains a `foldersSection` between Inbox and Notifications:
  it lists the folders this podcast is in (via `FolderRepository.folders(containing:)`),
  each rendered by its full `FolderLogic.pathString` breadcrumb, or a single
  "Not in any folder" row when empty, followed by an "Add to folder…" button.
  The section reads a `@Query` over `PodcastFolder` (Podcast has no inverse to
  `FolderMembership` — the F2 decision — so it can't observe membership on its
  own; the query plus body re-eval on sheet dismiss keep it current). The button
  presents `PodcastFolderPickerView` (new, `Features/Folders/Presentation/`), the
  inverse of `FolderPodcastPickerView`: it lists all folders **nested** (a
  depth-first walk from `parent == nil` roots through `children`, cycle-guarded)
  with each row labelled by its breadcrumb path so depth rides the label, not
  indentation. Toggling a row writes membership immediately (no Save button,
  mirroring the sibling) and a "New folder…" row creates a top-level folder
  (`createSubfolder(under: nil)`) and files the podcast into it on the spot.
  **A11y adjudication (earshot-accessibility gate):** #754 asked for both
  `.isToggle` (matching the sibling) AND an explicit "Added to News › Daily"
  announcement — those collide, because `.isToggle` auto-speaks a generic state
  word that talks over the informative announcement. Resolution: drop `.isToggle`,
  keep `.isSelected` (still exposes membership to the rotor) plus the path
  announcement, which names *which* folder changed — more useful here than the
  flat sibling since folders nest and a podcast can be in several. The `create()`
  announcement is deferred 0.5 s so it clears the alert-dismissal focus utterance.
  Phase 2 will replace the minimal picker with a fully shared `FolderPickerView`.
- **Shared "Add/Move to folder" Quick Actions + one reusable `FolderPickerView` (#756, Folders Phase 2, Issue A).**
  Added `addToFolder`/`moveToFolder` cases to `EpisodeAction` and `PodcastAction`
  (labels "Add to folder"/"Move to folder"), placed before the destructive
  `.unfollow`/appended after `.share` respectively, and appended to the default
  arrays so `QuickActionRepository.resolve()` hands them to existing users too
  (reorderable/hideable in `QuickActionsSettingsView`). `buildEpisodeActions` and
  `buildPodcastActions` gained optional `onAddToFolder`/`onMoveToFolder`
  callbacks and a branch per case; both actions are **omitted** when a surface
  passes no runner (same optional-callback contract as `onExport`/`onUnfollow`) —
  `PodcastActionsBuilder` switched `.map` → `.compactMap` to support that.
  **One reusable picker:** new `Features/Folders/Presentation/FolderPickerView.swift`
  with `init(episodes: [Episode] = [], podcasts: [Podcast] = [], mode: FolderPickMode)`
  where `enum FolderPickMode { case add, move }`. Unlike `PodcastFolderPickerView`
  (a multi-membership *toggle* editor that stays open), this is a single-tap
  *destination* selector: it shows the nested tree (shared `FolderLogic.orderedHierarchy`,
  extracted from `PodcastFolderPickerView` so there is one cycle-guarded walk; the
  old static now forwards to it), each row labelled by full `FolderLogic.pathString`
  breadcrumb (depth via label, not indentation, no `.isToggle`), plus a "New folder…"
  alert affordance (`createSubfolder(under: nil)`, flat for now) and a descriptive
  empty state. On pick it calls the matching `FolderRepository` batch method
  (`add/moveEpisodes`, `add/movePodcasts` — dispatch extracted to the testable
  static `FolderPickerView.apply`), dismisses, and announces
  "Moved 3 episodes to News › Daily" / "Added 1 podcast to News" via `Announcer`,
  **deferred 0.5 s** so it lands after the sheet-dismiss focus utterance while iOS
  re-anchors VoiceOver focus to the presenting row. A `Cancel` toolbar button makes
  it dismissible without a drag gesture. Call sites present it through a one-line
  `.folderPicker($request)` view modifier (backed by an Identifiable
  `FolderPickRequest`), mirroring `.episodeAudioExport`. **Wired:** Inbox,
  podcast `EpisodeListView`, Downloads (episode rows), and Library
  `SubscriptionsView` (podcast rows). **Gated out:** Search results — those are
  detached preview episodes for shows not yet subscribed, and folder membership is
  a store write on a persisted episode (zero-store-write contract, #517), so the
  folder actions are omitted there (no runner passed), same as `.unfollow`/`.exportAudio`.
  **Not migrated:** `PodcastSettingsView`/`PodcastFolderPickerView` stay on the
  Phase-1 toggle picker — that screen edits *multiple* memberships with add+remove
  and live checkmarks, which the single-destination `FolderPickerView` doesn't
  express; converting it would regress multi-folder editing. Flagged for a Phase 2
  cleanup pass if a unified multi/single picker is designed. No multi-select or
  `.contextMenu` yet (#757/#758, Phase 3).
- **Folder drill-down: breadcrumb lives in-content, not the nav title (#753).**
  `FolderDetailScreen` gains a Subfolders section above its podcasts; each row is
  a `NavigationLink(value:)` resolving against the `PodcastFolder` destination
  `FoldersScreen` declares at the stack root (no duplicate destination), so a
  child pushes another `FolderDetailScreen`. The breadcrumb is rendered as a
  **wrapping Section header** (full `FolderLogic.pathString`, `.isHeader`,
  comma-joined spoken label so VoiceOver doesn't voice the visual `›`) rather
  than the inline `navigationTitle` — inline titles are single-line and would
  clip a deep path at large Dynamic Type with no way for VoiceOver to recover the
  tail; the wrapping header reflows and is Headings-rotor navigable. "Go up one
  level" (only when `parent != nil`) is a visible button + a rotor action on the
  breadcrumb + a menu item, and just `dismiss()`es since the back stack mirrors
  the hierarchy; its announcement is deferred 0.5s past the pop's screen-change
  utterance. Subfolder reorder is the shared `QuickActionMoveLogic` rotor set
  (non-drag) plus `.onMove` drag, persisted via `reorderFolders`. Reactivity fix:
  `subfolders` is derived by sorting the **tracked `folder.children` relationship**
  (not a detached `FetchDescriptor`), mirroring how `members` reads through
  `folder.memberships`, so Observation re-renders on a `sortOrder` mutation —
  otherwise the row would announce "Moved…" while the list stayed put. Spoken
  strings (subfolder row = "name, N subfolders, M podcasts, folder"; breadcrumb;
  move announcement) are a pure `FolderDetailLabel` helper, unit-tested.

- **Per-screen search is one shared filter, presentation-only (#457 Part A).**
  Inbox, Queue, and Downloads each get an in-place `.searchable` field backed by
  `EpisodeSearchFilter` (`Core/UI/`), a pure enum: case- and diacritic-insensitive
  `localizedStandardContains` over episode title → podcast title → the episode's
  cached brief summary (via `EpisodeSummaryCache`, so description matching costs
  an NSCache lookup and never regresses large-list scrolling; tradeoff is the
  ~140-char summary cap). No repository/query changes — screens filter the
  arrays they already loaded. Shared `NoSearchMatchesView` (one combined VO
  element) replaces the list when nothing matches. Result counts announce on
  SUBMIT only, never per keystroke, never while the field is empty. Inbox title
  count stays TOTAL while filtering; Inbox #579 neighbor-focus computes against
  the FILTERED list. Queue: flat rows keep their true "position X of Y"; drag
  reorder + EditButton suspend while a search is active (move indices against a
  partial list would be wrong — rotor moves still work); grouped mode filters
  within groups and hides emptied groups, header counts = visible rows.
  Downloads searches both sections (Recently Expired matches on the same
  fields). Part B ("Search Everywhere") intentionally not started.

- **Episode-list sort control is a pure enum (#459), episode lists only.** A
  single `EpisodeSortOrder` (Alphabetical / Latest first / Latest last, in
  `Features/Subscriptions/Domain/`) with `sorted(_ episodes:)` orders a podcast's
  episode list. Alphabetical reuses `LibrarySort.titlesInOrder` (article-aware);
  the date cases sort by `Episode.pubDate`, undated items always last, ties →
  alphabetical for stable VoiceOver focus. **Persistence is GLOBAL** (a
  `SettingsStore.episodeSortOrder` prop + `episode_sort_order` key, default
  `latestFirst`), mirroring `librarySortOrder`, chosen over per-podcast because a
  sort preference is a reading habit not a per-show attribute; the #489
  per-podcast *filter* is unaffected and still coexists. **Default `latestFirst`
  preserves the old hardcoded `pubDate` desc.** The control is a toolbar
  `Menu`+`Picker` (identical idiom to the Library sort), labeled "Sort episodes",
  `.accessibilityValue(currentSort.title)` on the button so VoiceOver speaks the
  active order without opening the menu; the binding guards `newValue != current`
  before announcing, and the stored value loads via `SettingsStore.configure`
  (not the view) so opening a screen never speaks a sort announcement.
  **Folder-contents sort was deliberately deferred** (not shipped in #459):
  applying a sort there collides with the existing folder-contents drag-reorder
  (the same manual-order-vs-sort conflict as #458). Left for Michael's decision
  rather than silently removing the reorder; `FolderDetailScreen` is unchanged.

- **Chapter list is ONE shared component, ONE VoiceOver stop per row (#509).**
  `ChapterListView` is a standalone modal sheet reached from BOTH the Now Playing
  current-chapter line (the #508 seam, now a button) and the controls sheet's
  Chapters section, so there is one chapter UI rather than two divergent ones.
  Adopts Michael's "included by default, deselect to skip" framing over the old
  "Skip" verb: every chapter shows a checkmark (included); deselecting marks it
  skipped via the existing in-memory engine (`PlayerService.toggleChapterSkipped`,
  #373) — no skip engine was rebuilt. Each row is a single accessibility element
  (`.accessibilityElement(children: .ignore)`): the **primary** action (VoiceOver
  double-tap / sighted tap) seeks + resumes from that chapter; the include/skip
  toggle is a **rotor** action (`.accessibilityAction(named:)`) whose label
  reflects state ("Skip this chapter" / "Include this chapter"). The visible
  sighted checkmark/slash toggle is a real `Button` but `.accessibilityHidden(true)`
  so it adds NO second stop — a 20-chapter list stays ~20 flicks. State is never
  color-only: a leading now-playing marker, a "Now playing"/"Skipped" status word,
  and strikethrough on skipped titles carry it visibly, and the combined a11y
  label folds "now playing"/"skipped" into words. The engine map isn't observed,
  so the view mirrors skip state locally for immediate re-render (same idiom the
  controls sheet used). The (included/skipped/now-playing) -> label/indicator
  mapping is extracted to the pure, unit-tested `ChapterRowState`. The controls
  sheet's old inline chapters Section is replaced by a single button that opens
  the same `ChapterListView`. Skip memory stays per-session (resets on restart).

- **Transcript viewer is a sheet mirroring ShowNotesView, ONE VoiceOver stop per
  segment (#451).** `TranscriptView` (Features/Transcripts/Presentation) is a
  `NavigationStack`-wrapped sheet with an inline "Transcript" title and a Done
  button, presented from Now Playing right below the Show notes row (same layout,
  chevron, and 44pt+ row height, so the two entry points read as a pair). It's
  purely presentational: a `@MainActor @Observable` `TranscriptViewModel` holds the
  async state as a sealed `LoadState` enum (`.loading` / `.loaded([TranscriptSegment])`
  / `.failed(TranscriptError)`) — the exact PodcastPreviewModel idiom — and calls
  the existing `TranscriptService` (no parsing/fetch logic in the view). Loaded
  segments render one `Text` per segment in a `ScrollView`+`LazyVStack`
  (`id: \.offset`), mirroring ShowNotesView's per-paragraph #547 model so each
  segment is one VoiceOver element. Each segment is
  `.accessibilityElement(children: .ignore)` with an authored label of
  "Speaker: text" when the segment carries a speaker (the speaker also shows as a
  distinct `.caption`/secondary label above the line), so VoiceOver names who is
  speaking before reading the line; visible text stays `.textSelection(.enabled)`.
  Error state is icon + headline + specific `errorDescription` (never color-only)
  with a Retry button that re-runs `model.load`; `.empty` gets a gentle
  "No transcript available for this episode." headline (with a neutral icon) instead
  of an error tone, and a nil/blank URL folds straight to `.empty` without a network
  attempt. The Now Playing entry point is gated on `hasTranscript`
  (`transcriptURL` non-nil/non-empty) so it never offers a dead action. MVP only —
  no tap-to-seek/synced highlighting (segments are timing-free) and no
  search-within-transcript (deferred).

- **Inbox-row "Unfollow this podcast" is a single trailing swipe action, not a
  second explicit rotor source (#500).** Inbox episode rows let a user unfollow the
  owning show (`episode.podcast`) straight from the inbox, via the centralized
  `SubscriptionRepository.unsubscribe(_:)` (the same path Library and search use —
  no inline delete). It's surfaced as one `.swipeActions(edge: .trailing,
  allowsFullSwipe: false)` button with a `Label` (icon + text, never color alone).
  A single swipe action covers BOTH populations: it's the visible affordance
  sighted users expect, and SwiftUI automatically surfaces a swipe action to the
  VoiceOver Actions rotor, so it lands in the same rotor as the row's episode Quick
  Actions for VoiceOver users. We deliberately did **not** also append an
  "Unfollow" item to `EpisodeRow`'s explicit `actions` array: a second source would
  produce a duplicate rotor entry, and it would risk the existing episode Quick
  Actions ordering. `allowsFullSwipe` is off so an over-swipe can't fast-path a
  podcast-level delete — every path lands on a destructive `confirmationDialog`
  whose wording/structure mirror Library's unfollow dialog ("Unfollow <title>?",
  message spelling out the whole show leaves the library). Success announces
  "Unfollowed <title>" only when the repo reports the delete saved; if the unfollow
  empties the inbox, focus moves to the empty state (mirrors `clearInbox`).
- **Tab screens read heading-first via inline title + `.principal` heading (#490).**
  A large `.navigationTitle` renders the title in the scrollable content area while
  toolbar items live in the bar chrome, which VoiceOver sweeps first — so a screen
  with toolbar items announced those items before its own title. The fix (proven on
  Inbox in #422) is `.navigationBarTitleDisplayMode(.inline)` plus a
  `ToolbarItem(placement: .principal)` `Text(...).font(.headline)` carrying
  `.accessibilityAddTraits(.isHeader)`; the plain `navigationTitle` stays for
  back-button identity. Applied to **Queue** and **Library** (both had the
  large-title-with-toolbar-items bug). **Inbox** already used this pattern.
  **Downloads** and **Settings** have no toolbar items, so their large titles
  already read heading-first and were intentionally left unchanged — meaning two
  tabs keep the large-title spring while three are inline. Note: when a screen has
  leading toolbar items (Queue's conditional EditButton, Library's search/folders),
  bar order is leading → principal → trailing, so those leading items are read
  before the heading. That is conventional iOS (a leading action before a centered
  title) and the primary bug (trailing options before the heading) is resolved.
  `accessibilitySortPriority` cannot fix this — it only reorders siblings within one
  container, and the large title (content) and toolbar items (bar) are different
  containers.

- **Now Playing bar is one named accessibility container (#490).** The
  `.safeAreaInset(edge: .bottom) { NowPlayingBar() }` in `RootView.TabChrome` wraps
  the bar with `.accessibilityElement(children: .contain)` and
  `.accessibilityLabel("Now Playing")`, so reaching it reads as a "Now Playing"
  group with each transport control still individually navigable. `.contain` (not
  `.combine`) preserves per-button focus. This does not change VoiceOver's standard
  first→last wrap (reaching the bar by back-flicking from the first element is
  expected). `NowPlayingBar` renders nothing while idle, so the inset adds no height
  and the #366 layout (bar never covers the system tab bar) is unchanged.

- **Queue tab announces its episode count via a native badge (#491).** Same
  mechanism as the Inbox tab (#422): a live `@Query` over `QueueItem` in `RootView`
  reduced through the new pure `QueueRepository.displayedCount(from:)` (drops orphan
  rows so the count equals what `QueueScreen` shows), surfaced as a native
  `UITabBarItem.badgeValue` via a second `TabBarBadgeApplier(tabIndex: 1, …)` and
  re-asserted on tab switch. UIKit folds the badge into the tab's VoiceOver
  announcement ("Queue, N items") with no extra VoiceOver stop, and the existing
  recursive hider suppresses the duplicate standalone badge element while the red
  bubble stays visible. Decided (vs. spoken-count-only): a visible red badge matching
  Inbox, phrasing "Queue, N items" — true Inbox parity, no override path needed.

- **Library search and "add a new podcast" are split (UX round 1, item 2).** The
  Library tab toolbar now carries two distinct affordances: a magnifying-glass that
  opens `SearchView(scope: .library)` (labelled "Search your library"), and a `plus`
  that opens the new `AddPodcastView` sheet (labelled "Add podcast"). `SearchView`
  gained a `SearchScope` parameter (`.library` / `.everywhere`, defaulting to
  `.everywhere` so old call sites are unchanged). In `.library` scope the entire
  iTunes directory path is gated off — `scheduleDirectorySearch` is never invoked
  from `onChange`, the "From the directory" section isn't rendered, and the empty
  state reads "No results in your library" pointing the user at Add podcast — so no
  network request or debounce task can fire. `AddPodcastView` is a `NavigationStack`
  sheet (Done button + `.accessibilityAction(.escape)`, never drag-only) offering
  the three add paths via the new shared `AddPodcastOptions` group: "Search podcasts"
  pushes `SearchView(scope: .everywhere)`, "Add by RSS URL" presents `AddFeedView`,
  "Import OPML file" runs `OPMLFileImporter.importFile` with the shared
  `OPMLImportProgress` (no duplicated announcement — the importer owns it).
  `AddPodcastOptions` is reused by `OnboardingView` so the onboarding and Library add
  flows can't drift. Onboarding's in-flow search now passes `.everywhere` explicitly.

- **Grouped-queue header is a single heading element with four rotor actions (#445).**
  `QueueScreen.groupHeader(_:)` is now one `Text(podcast.title)` node carrying an
  explicit `.accessibilityLabel("[Podcast], N episodes")` (pluralized — "1 episode"
  vs "N episodes"), the `.isHeader` trait, and `.accessibilityActions { }` exposing
  exactly four actions in order — Play Group, Sort Newest First, Sort Oldest First,
  Shuffle Group — so they sit in the VoiceOver Actions rotor rather than as a second
  focusable button. The old standalone "Play group" `Button` was removed. Only
  **Play Group** starts audio: `repo.playGroup` → if non-nil `PlayerService.play()`
  → announce "Playing [title]" (empty group is a no-op). The three **sort/shuffle**
  actions reorder the group in place only and do not start playback — they call
  `repo.playNewestFirst` / `repo.playOldestFirst` / `repo.shuffleGroup` (the
  `@discardableResult Episode?` is ignored) and announce "Sorted newest first" /
  "Sorted oldest first" / "Shuffled" (device-feedback change: starting audio on a
  sort surprised testers). All four repo methods (added in #448) are silent — the
  view owns the announcements. Group-level move actions stay out of grouped mode by
  design — position is ambiguous there, so grouped mode offers these four and flat
  mode keeps the move rotor.

- **Library "+" now lands directly in podcast search (UX round 1, follow-up).**
  Device feedback: following a show is the primary action, and the intermediate
  three-option menu was an extra step. The Library toolbar `plus` ("Add podcast")
  still presents `AddPodcastView`, but `AddPodcastView` was repurposed from a
  three-button hub into a search-first screen — it wraps `SearchView(scope:
  .addPodcast, title: "Add podcast", autoFocusSearch: true)` in its own
  `NavigationStack`, so the directory search field is the first thing the user
  reaches. `SearchView` gained `title` (nav-title override) and `autoFocusSearch`
  parameters; the latter focuses the `.searchable` field itself (never a container)
  via a `SearchFieldFocus` modifier gated on `if #available(iOS 18.0, *)` because
  `.searchFocused` is iOS 18+. On iOS 17 the field is simply tapped — no container
  focus is ever forced. The two secondary add paths (Add by RSS URL, Import OPML
  file) moved into a single labelled "More add options" `Menu`
  (`ellipsis.circle`, `accessibilityLabel "More add options"`) in the search
  screen's leading toolbar; each item is a `Label` action with a leading icon. RSS
  presents `AddFeedView`; OPML runs `OPMLFileImporter.importFile` with the shared
  `OPMLImportProgress` (no duplicated announcement). Done + `.accessibilityAction(
  .escape)` keep a non-drag dismiss. The injected toolbar composes onto the
  `SearchView` instance via `.toolbar` (no generic `SearchView` over
  `ToolbarContent` — that hit "static stored properties not supported in generic
  types" for the debounce constant, so the simpler composition was used). The
  `.addPodcast` scope is unchanged, so it still hides episodes/bookmarks, keeps the
  "Follow" rotor action and Following value, and searches the directory. **Onboarding
  is unchanged**: the "Add your first podcast" page still uses the visible
  three-option `AddPodcastOptions` group for first-run guidance.

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

- **Bulk OPML import shows a determinate progress screen over the active tab.**
  A `@MainActor @Observable OPMLImportProgress` (`start` / `advance` / `finish`,
  `isImporting` / `completed` / `total` / `currentTitle`) is provided once from
  `EarshotApp` via `.environment(...)` — the same single-shared-instance pattern as
  `MigrationImportState` / `SettingsStore`. Every OPML entry point reads it from the
  environment and passes it to `OPMLFileImporter.importFile(at:context:progress:)`
  (new optional `progress:` param, default `nil`, so tests/non-UI callers are
  unaffected). The importer flips `start(total:)` only after a parseable OPML is
  read (an unreadable/empty file never flashes the screen), drives `advance(...)`
  from `importOPML`'s main-actor `onProgress` callback, and clears via `finish()` in
  a `defer`. `RootView` presents `ImportProgressView` as a `.sheet` bound to a
  read-only `Binding(get: isImporting, set: { })`, `.interactiveDismissDisabled` and
  `.presentationDetents([.medium])` — it covers whichever tab is active and
  auto-dismisses when `finish()` flips the flag (no cancel/manual dismiss for v1).
  **VoiceOver:** one assertive "Importing N podcasts" announcement on appearance;
  per-feed progress is *exposed not spoken* — the count + current title live in a
  single `.accessibilityElement(children: .ignore)` with `.accessibilityValue` and
  `.updatesFrequently`, so a user can swipe to re-check "3 of 10" on demand without
  per-tick chatter (the existing "Imported N podcasts" announcement in
  `OPMLFileImporter` closes the loop). Heading is one `.isHeader` element; no
  container autofocus; bar animation honors `accessibilityReduceMotion`. Bulk path
  only — single-podcast add (AddFeedView) is untouched.
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

- **Queue grouping reads the persisted setting, not local state (#444).**
  `QueueScreen` previously branched grouped-vs-flat on a throwaway
  `@State groupByPodcast`, so the choice reset on navigation/relaunch and the App
  Settings toggle was dead with respect to the queue. The local state was removed;
  the screen now reads `@Environment(SettingsStore.self).groupQueueEpisodes`
  (persisted key `group_queue_episodes`) for the display branch, the EditButton
  gating, and the in-queue Menu toggle. The toggle binds through a computed
  `Binding<Bool>` whose setter writes `settings.groupQueueEpisodes` and then posts
  `Announcer.announce("Queue grouped by podcast"|"Queue ungrouped")` (Flutter
  parity, announced after the flip so the spoken state is correct). The in-queue and
  Settings toggles now share one source of truth. View-layer only — no model/schema
  change; the existing `QueueLogic.group` transform is reused as-is.

- **Directory search rows: Activate navigates, a single Follow/Unfollow toggle is a
  rotor action (#499).** The old `directoryRow` collapsed an HStack whose only
  control was a Follow button with `children: .combine`, which made the row's default
  Activate fire `subscribe`, and ALSO added a duplicate "Follow" rotor action calling
  the same thing — so Activate and Follow were identical and nothing navigated. The
  row is now one accessibility element built with `children: .ignore` (so the inner
  navigate Button and Follow Button don't each make a VoiceOver stop), marked
  `.isButton`, with a `.default` `accessibilityAction` that navigates and a SINGLE
  named `accessibilityAction` whose label is `FollowToggle.actionLabel(subscribed:)`
  ("Follow"/"Unfollow"). Sighted users still get two real tap targets (row body
  navigates, trailing button toggles). Primary Activate routes through programmatic
  `navigationDestination(item:)`: an un-subscribed hit opens the new read-first
  `PodcastPreviewView`, an already-followed one routes to the existing
  `EpisodeListView` (so subscribed results behave exactly as the local Podcasts
  section). `PodcastSearchResult` gained `Hashable` to drive that item navigation.
  The toggle's label/announcement text lives in the pure `FollowToggle` enum (unit-
  tested); the announcements are "Now following X" / "Unfollowed X" via `Announcer`.

- **`PodcastPreviewView` previews an UN-subscribed directory result (#499).** It is
  NOT `EpisodeListView` (which needs a subscribed `Podcast` `@Model` and reads
  `podcast.episodes` from the store). The preview takes a `PodcastSearchResult` and
  uses `PodcastPreviewModel` (`@MainActor @Observable`) to fetch the feed once via
  the existing `FeedFetching` abstraction — the same path the subscribe flow uses, so
  no new network risk — exposing `.loading / .loaded(description, episodes) / .failed`
  with explicit loading and error+retry states. It shows artwork, a heading title,
  author, the feed description ("About" section), a few recent episodes (read-only
  value-type `PreviewEpisode`s, newest-first, no store writes), and a prominent
  borderedProminent Follow/Unfollow button (icon+label, 44pt, Dynamic Type) sharing
  the same toggle + announcements. The model's `recentEpisodes(from:limit:)` and
  `cleanedDescription(_:)` are pure and unit-tested. Recent-episodes-in-preview WAS
  included (the `FeedFetching` path made it low-risk), not deferred.

- **`SubscriptionRepository.unsubscribe(_:)` centralizes unsubscribe (#499/#500).**
  The inline logic in `SubscriptionsView.unsubscribe` (removeFromAllFolders → delete
  → save) moved to the repository as `@discardableResult func unsubscribe(_:) -> Bool`
  (true when the save succeeded), with AppLog + error handling. It does NOT post the
  VoiceOver announcement — that stays in the presentation layer, which announces
  "Unfollowed X" only on a `true` result. `SubscriptionsView`, the search row, and
  the preview now share this one path; #500's unfollow-from-search half is delivered.

- **Directory search "result N of M" position context + native scroll bar (#501).**
  Robin (VoiceOver) found stepping through long directory result lists one swipe at a
  time slow with no sense of size or place. Decision (Michael): rely on the SYSTEM
  VoiceOver vertical scroll bar (touch the far-right edge → "vertical scroll bar,
  adjustable", swipe up/down ≈10%) rather than building a custom scrollbar or an A–Z
  index (an alphabetical index was explicitly rejected — it would destroy iTunes
  relevance ordering). The results already render in a `List` with default scroll
  indicators and nothing suppresses them (no `.scrollIndicators(.hidden)` exists in
  the codebase), so the affordance is present without code change — confirmed by code
  inspection; the actual gesture is device-VoiceOver-only and noted for Michael to
  verify. On top of that, each directory row's `accessibilityValue` now carries
  "result N of M" position-in-set context via the pure `SearchResultPosition` helper
  (`Features/Search/Domain/`). It composes cleanly with #499's subscribed state: a
  subscribed row reads "Following, result 4 of 50", an un-subscribed one
  "result 4 of 50" — the value is now always non-empty (no dead-air pause) and the
  title stays in the label. The `ForEach` enumerates the already-materialized
  `[PodcastSearchResult]` (max ~50, not a `@Query`) so index/count follow displayed
  relevance order. The settled-result count announcement (from #499) was moved to the
  same helper (`countAnnouncement`) for testability, keeping its deduped/polite
  once-per-query behavior. The removed `SubscribedValue` modifier is superseded by the
  always-present value. Position/count formatting is unit-tested
  (`SearchResultPositionTests`).

- **Mark All as Played wired into `EpisodeListView` (#640).** Two entry points
  drive one shared `@State` confirmation gate so they can never diverge: a
  `topBarTrailing` toolbar button (`checklist.checked`, disabled — not
  hidden — when `unplayedCount == 0`, mirroring InboxScreen's "Add to Queue"
  disabled-not-hidden pattern) and a screen-level
  `.accessibilityAction(named: "Mark all as played")` on the `List`, the first
  non-per-row rotor action in the codebase (every prior one hangs off an
  episode row). Since a rotor action can't visually gray itself out, it's
  conditionally attached at all via a small `@ViewBuilder` View extension
  (`markAllPlayedAccessibilityAction(enabled:action:)`) rather than left as a
  silent no-op. `unplayedCount` is derived from the view's existing
  `sortedEpisodes` (unfiltered, sorted) rather than the filtered/visible set,
  since `EpisodeRepository.markAllPlayed` acts on the whole podcast regardless
  of which filter (Unheard/All) is showing. Confirmation is a destructive
  `confirmationDialog` matching the Clear-inbox/Unfollow precedent exactly
  (plain-text buttons, no icons — the system dialog doesn't render them).
  Completion is announced assertively via a new pure `MarkAllPlayedAnnouncement`
  helper (comma-grouped counts, correct singular/plural), unit-tested in
  `MarkAllPlayedAnnouncementTests` mirroring `EpisodeListFilter.announcement(count:)`'s
  pattern of keeping VoiceOver wording pure and file-scoped rather than inline
  in the view.

- **Normal-mode "Exclude from Inbox" UI (#671), the companion #668 deliberately
  left out of scope.** `Podcast.inboxExcluded` and its `InboxRepository`/
  `InboxLogic.isExcluded(inboxExcluded:inboxIncluded:)` enforcement already
  existed and were untouched — this was UI-only, mirroring #668's shape
  exactly but inverted: a new `PodcastAction.toggleInboxExclude` Quick Action
  (label "Exclude from Inbox"/"Include in Inbox" reflecting `inboxExcluded`,
  non-assertive `Announcer.announce`), filtered out of the rotor when opt-in
  mode is ON (the inverse of `.toggleInboxInclude`'s filter); a leading-edge
  sighted swipe action on Library rows in the `else` branch of the same
  `if settings.inboxOptInOnly` swipe-actions block #668 added, gated on
  `!voiceOverEnabled && !settings.inboxOptInOnly`; an "Exclude from Inbox"
  `Toggle` in `PodcastSettingsView`'s Inbox section, shown only when opt-in
  mode is OFF. **Judgment call: kept the two toggle cases and swipe branches
  as parallel, separately-named code** (not a shared `direction:`-parameterized
  helper) — each is ~6 lines, the inverted gating conditions read clearly
  side by side, and a generalized helper would need an enum/bool parameter
  whose meaning ("which mode, which field") isn't obviously simpler to read
  than just seeing both cases. The one place genuinely shared is the rotor
  filter in `SubscriptionsView.rotorActions(for:)`, restructured from two
  chained `&&`/`||` clauses into a small `guard`+`if` cascade so adding the
  second mode's condition didn't turn into an unreadable one-liner. Test
  coverage mirrors #668's three-file shape: `QuickActionBuildersTests` (default
  set membership, label-reflects-state both directions, run flips+persists,
  rotor-filter predicate both directions), `DownloadsInboxLogicTests` (added
  three new `InboxRepository` end-to-end normal-mode tests — the existing
  #668 coverage only exercised `InboxLogic.isExcluded` directly plus opt-in-mode
  `InboxRepository` end-to-end, leaving normal-mode end-to-end as a real gap),
  `PodcastSettingsViewTests` (default/set/toggle/persist for `inboxExcluded`,
  mirroring the `inboxIncluded` block). **Implemented by:** earshot-ui.

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
- **#451 Transcript fetch + parse (data layer).** New `Features/Transcripts/`
  (`Domain/TranscriptFormat.swift`, `TranscriptSegment.swift`,
  `TranscriptParser.swift`; `Data/TranscriptService.swift`). Format is resolved
  at fetch time, not from the feed: `RSSParser` only stored the transcript `url`
  (not the MIME `type`), so `TranscriptFormat.detect(url:contentType:)` keys off
  the URL path extension first, then the response `Content-Type` (charset param
  stripped), defaulting to `.plainText`. Reused `HTTPClient` for retry/timeouts:
  added an additive `dataWithResponse(from:)` that returns the body **plus** the
  `HTTPURLResponse` (the data-only path discarded headers, so there was no way to
  read `Content-Type`); `data(from:)` now routes through the same shared retry
  loop and is behaviourally unchanged. `TranscriptParser` is pure/synchronous/
  Foundation-only (SwiftData-free) and never throws — malformed input yields a
  best-effort (possibly empty) array. WebVTT and SRT share one cue-block
  extractor (keyed on `-->` lines, so the `WEBVTT` header and numeric indices are
  ignored); tag/entity decoding reuses `EpisodeSummary.plainText`; HTML reuses
  `EpisodeSummary.paragraphs`. Speaker extraction: WebVTT `<v Name>` voice spans,
  else a leading `Name:` label **requiring a space after the colon** so
  `https://…` can't masquerade as a speaker. JSON (`{segments:[{speaker,body}]}`)
  is parsed defensively with `JSONSerialization` (missing/bad keys skipped, `text`
  accepted as a `body` fallback) and consecutive same-speaker entries are coalesced
  into ≤320-char paragraphs so word-level transcripts don't become thousands of
  VoiceOver stops. `TranscriptService.load(from:)` returns
  `Result<[TranscriptSegment], TranscriptError>` (cases: `invalidURL`, `network`,
  `empty`, `decodingFailed`, `tooLarge`); UTF-8 decode with Latin-1 fallback;
  5 MB post-fetch size cap. **Flag for earshot-swift6:** all new types are value
  types with `Sendable` stored properties (`TranscriptSegment: Sendable`); no
  actors, no SwiftUI view (viewer is a separate earshot-ui pass; no a11y gate here).
  **Flag for earshot-testing:** `MockURLProtocol.Outcome.response` sets
  `headerFields: nil`, so Content-Type-path detection tests need it extended to
  carry headers; extension-based detection is testable as-is.
- **#576 Download pipeline hardening.** (1) `DownloadSessionDelegate.
  didFinishDownloadingTo` now rejects non-2xx statuses and `text/html` bodies
  before moving the file (an error page was previously saved as audio and marked
  `.downloaded`), and the silent move-failure catch logs via `AppLog.networking`.
  (2) Episodes are identified everywhere a string identity is persisted by the
  composite `DownloadTaskKey` `"feedURL|guid"` (guids repeat across podcasts):
  the background task's `taskDescription` and `SettingsKey.lastPlayingEpisodeID`.
  `DownloadTaskKey` (in `DownloadPaths.swift`) is the single parse/resolve
  helper; legacy bare-guid values (old in-flight tasks, old stored setting)
  still resolve by guid alone. NOT a schema change — both stores were already
  strings. (3) `DownloadManager.downloadAndWait(_:timeout:)` (default 120 s)
  parks per-caller continuations keyed by task key, resolved exactly once by the
  terminal complete/fail event or a paired per-waiter timeout task (removal
  from the dictionary before resume is the ownership point; all main-actor).
  `PlayerService.exportCurrentEpisodeAudio` uses it, fixing the #544 regression
  where export always failed for non-downloaded episodes. (4) `.pending`
  (Wi-Fi-gated) downloads now start on the `NWPathMonitor` Wi-Fi transition and
  on the first path report after launch; `EpisodeRowLabel` reads `.pending` as
  "Waiting for Wi-Fi" (spoken + badge) instead of the false "Downloading".
  (5) Terminal-path `try? context.save()` replaced by a static logging save
  helper shared with the instance `save()`. **Flag for earshot-testing:**
  `DownloadReconciliationTests` must move to the new
  `orphanedIndices(markedDownloading:liveTaskKeys:)` API (compile-breaking) and
  `EpisodeRowLabelTests` `.pending` expectations change to "Waiting for Wi-Fi";
  `DownloadTaskKey.key/parse/episode(matching:)` are pure/fetch-only and unit-
  testable. **Known follow-up:** notification routing in `RootView.swift`
  (~line 322) still resolves `episodeGUID` guid-only despite carrying the feed
  URL — UI-owned, out of #576's scope.
- **#384 RSS parser robustness (partial results + fallback art + iTunes
  fields).** (1) **Partial results on malformed XML:** `RSSParser.parse` no
  longer discards everything when `XMLParser.parse()` fails mid-document. If
  any episodes or a feed title were accumulated before the abort point, it
  returns the partial `ParsedFeed` (title falls back to "Untitled podcast"
  when the channel head never parsed) and logs the parser error, line/column,
  and salvaged episode count via `AppLog.networking`. `nil` is still returned
  only when nothing was salvageable (no episodes AND no title) — so
  `FeedService`'s `FeedError.parse` behavior is unchanged for truly broken
  input. No half-items are possible: `finishItem()` only runs on an item's
  closing tag. (2) **Channel `<image><url>` artwork fallback:** tracked with an
  `inChannelImage` flag; used only when `itunes:image`/Atom logo/icon are
  absent (`feedImage ?? channelImageURL`). The flag also stops `<image>`'s
  `<title>`/`<link>` children from shadowing the channel's title/link.
  (3) **`itunes:explicit` / `itunes:episodeType`: PARSE-LEVEL ONLY, NO SCHEMA
  CHANGE.** Persisting them on `Podcast`/`Episode` would require new SwiftData
  attributes (schema bump); per the schema-window rule they live only on
  `ParsedFeed.explicit: Bool?` (yes/true → true; no/false/clean → false; else
  nil) and `ParsedEpisode.episodeType: String?` (normalized "full"/"trailer"/
  "bonus", else nil), both defaulted so existing memberwise-init call sites
  compile. Plumbing to the models is deferred to the next schema window.
  (4) **`parseDuration` overflow (readiness-audit P2-11):** the naive
  `reduce(0) { $0 * 60 + $1 }` trapped on hostile values like
  "999999999999999999:00:00"; now uses `multipliedReportingOverflow`/
  `addingReportingOverflow`, rejects >3 segments and negatives, returns nil
  instead of crashing.

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
| #401 | Verify export audio shares local file (follow-up #363) | earshot-audio | [x] Closed. Confirmed export shares the local downloaded/cached file, not the feed URL; player-path concern addressed in #371 (PR #407), row-level export parity verified separately. Shipped. |

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
| #381 | Background feed refresh (BGTaskScheduler) | earshot-networking | [x] Closed. BGTaskScheduler registration + 15-min refresh-skip window; background-found episodes flow through the same auto-queue/auto-download path as manual refresh (#380). All gates PASS (security + swift6 reviews on file). Shipped, see CHANGELOG. |
| #72 | Push notifications per podcast | earshot-data | [x] Closed. Per-podcast "Notify on new episodes" toggle; local (on-device only) notification with show name + new-episode count and Add to queue / Play now actions; VoiceOver-clean text, tap-to-focus. All gates PASS (security + swift6 reviews on file). Shipped, see CHANGELOG. |
| #385 | Artwork disk cache | earshot-networking | [x] Closed. New `Core/Networking/ArtworkCache.swift` — disk-backed artwork cache shared by lock-screen/Control Center art; no longer re-downloads every cold launch. All gates PASS (security + swift6 reviews on file). Shipped, see CHANGELOG. |
| #386 | Networking robustness: retry/backoff/timeouts | earshot-networking | [x] Closed. One shared `URLSessionConfiguration` with consistent timeouts + retry/backoff (1s then 2s) on transient errors (5xx, dropped connection, timeout); permanent errors (404, bad address) fail fast. Kept separate from the #385 artwork session by design. All gates PASS (security + swift6 reviews on file). Shipped, see CHANGELOG. |

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

## Security Review — Issue #440

earshot-security gate: PASS. Bulk OPML import (off-main one-pass subscribe + ONE
main-context merge) plus the `OPMLImportProgress`/`ImportProgressView` progress
sheet. Force-unwraps: none in production. fatalError/`model(for:)`: none — the
post-save re-resolution of `persistentModelID`s in `SubscriptionRepository`
(`podcast(forPersistentID:)` / `episode(forPersistentID:)`) uses a predicate
`FetchDescriptor` returning nil on a missing ID, explicitly NOT `model(for:)`,
so a vanished row can't trap. try?: all are `context.fetch` reads with `?? []`
or `?.first`/guard-let fallbacks (valid nil-as-empty reads) plus a `Task.sleep`;
no silent error swallowing. Per-feed import failures are caught and logged via
`AppLog.subscriptions` and skipped — one bad feed never aborts the batch
(`subscribeAll` catch at FeedRefreshActor:209). Retain cycles: none — the
`onProgress` closure captures the value-type `OPMLImportProgress?`, not self
(`OPMLFileImporter` is an enum, no self), and is consumed synchronously during
the await, not stored; the `.sheet` get/set binding closes over the shared
`@Observable` env object (reference, no view capture). @MainActor: `onProgress`
is `@MainActor @Sendable`, `OPMLImportProgress` is `@MainActor`, the actor
marshals each tick via `await onProgress?(...)`; only `Sendable`
`PersistentIdentifier`s cross the actor boundary — `@Model` `Podcast`/`Episode`
stay on their owning context. Stuck-sheet check: `OPMLFileImporter` arms
`defer { progress?.finish() }` BEFORE the import and `start()` runs only after a
parseable, non-empty OPML, so any throw/early return clears `isImporting` — the
sheet can't hang. Behavior preserved and test-verified: idempotent re-import (no
duplicate podcasts/folders/memberships), #296 newest-non-future high-water mark,
backlog pre-dismiss, auto-download run once at the end, and the core fix asserted
via `onMerge == 1` per import. Secrets/entitlements/project.yml/IS_BETA_BUILD:
untouched, N/A. Release build (iPhone 17): BUILD SUCCEEDED, 0 errors. AppLog: all
four catch blocks log; no empty catches. Feature suggestions: none this review.

## Swift 6 Review — Issue #440

earshot-swift6 gate: PASS. Branch `feat/opml-import-progress`.

Concurrency mode used for review: SWIFT_VERSION=6 SWIFT_STRICT_CONCURRENCY=complete
(overrides; project baseline remains SWIFT_VERSION=5.0 / minimal). Project baseline
build (Swift 5): BUILD SUCCEEDED with only the one pre-existing DownloadManager
warning. Under Swift 6 + complete, every changed file in this branch type-checked
cleanly; the only errors were in five pre-existing baseline files untouched by this
branch (see baseline note below).

Checklist:
[x] Sendable conformance: PASS — `SubscribeResult` (PersistentIdentifier +
    [PersistentIdentifier] + Bool) is correctly `Sendable`; `PersistentIdentifier`
    is Sendable in SwiftData and the compiler raised no Sendable diagnostic on it.
    `BulkSubscribeOutcome` holds a main-context `Podcast` and is built only on the
    @MainActor repo after the merge — it never crosses the actor boundary. The
    `@MainActor @Sendable onProgress` closure is the only closure passed into the
    actor and is correctly Sendable.
[x] Actor isolation: PASS — `FeedRefreshActor` is `@ModelActor`; `subscribeAll`
    returns only `[SubscribeResult]`. NO `@Model` crosses the boundary in
    `subscribeAll`: the live `SubscribeOutcome` (Podcast/Episode) stays inside the
    actor and only its IDs are projected. The pre-save `persistentModelID` fix is
    SOUND: a non-alreadySubscribed slot is reserved with a temporary ID, recorded in
    `pendingIndexByResult`, and ALWAYS overwritten by `flushPending()` after
    `saveIfNeeded()` — every reserved slot is resolved post-save before the function
    returns, and a temporary ID is never observable by a caller. A throwing
    `subscribeOne` reserves no slot. `SubscriptionRepository`/`OPMLImportService`/
    `OPMLFileImporter` are all `@MainActor`; the actor hop is `await actor.subscribeAll`
    then `mergeBackgroundWrites()` on main.
[x] @Model/SwiftData actor boundary: PASS — episode `persistentModelID`s are
    projected only AFTER the actor's save; main-context re-fetch via
    `podcast(forPersistentID:)` / `episode(forPersistentID:)` (predicate fetch, nil
    on miss). No `@Model` on a hop.
[x] AVAudioSession main actor: N/A — branch touches no audio session code.
[x] Combine publishers: N/A — `OPMLImportProgress` is `@Observable` (Observation),
    not ObservableObject; mutated only via main-actor `start/advance/finish`.
[x] nonisolated functions: PASS — none added; none needed.
[x] Structured concurrency: PASS — no `Task.detached`. The `.sheet` Bindings and the
    onOpenURL/Settings `Task { ... }` inherit the main actor. The actor loop awaits
    per-feed `onProgress` sequentially (bounded, in-order).
[x] Global state: PASS — no new global/static mutable state in changed files.
[x] OPMLImportProgress isolation: PASS — `@MainActor @Observable final class`,
    mutated only on the main actor; the RootView `.sheet` get/set binding reads
    `isImporting` on main and the `set` is a no-op; `.environment` wiring is clean.
[x] autoDownloadRecent: PASS — runs on @MainActor, re-fetches main-context
    `Episode`s by ID, awaits the @MainActor downloader; no `@Model` crosses a hop.
[x] Swift 6 build clean (changed files): PASS — zero strict-concurrency
    diagnostics in any file modified or added by this branch.

Pre-existing Swift 6 baseline issues — NOT this branch (each in declaration code
untouched by the diff; surfaced one at a time as the Swift 6 build advanced PAST
all of this branch's Subscriptions files into other features):
  - DownloadManager.swift:41 — `download(_:Episode)` non-Sendable param into a
    @MainActor impl of a non-isolated protocol requirement (`EpisodeDownloading`).
    Already a warning at baseline. Correct fix is `@MainActor protocol
    EpisodeDownloading` (DownloadManager and its sole consumer are already @MainActor)
    — verified it clears the error. Deferred to the Swift 6 migration, not this PR.
  - NotificationDelegate.swift:59 — `Task { @MainActor in router.handle(...) }`
    captures non-Sendable `self` from a non-isolated delegate.
  - EarshotSchema.swift:24/343, EarshotSchemaV1.swift:17 — `static var
    versionIdentifier = Schema.Version(...)` nonisolated mutable global (VersionedSchema).
  - RSSParser.swift:84/90 (+ rfc822Formatters) — static non-Sendable
    DateFormatter/ISO8601DateFormatter.
  - PlayerService.swift:1044/1051 — non-Sendable `Notification` sent into
    `Task { @MainActor in }`.
These five are the known baseline set; recommend tackling them in the dedicated
Swift 6 migration (Layer 2/3) issue, not here.

New agents created: none.
Overall: PASS — no concurrency issue introduced by this branch; nothing committed.

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

### Issue #762 — Queue grouping by folder
- **A value migration, not a schema migration.** The existing
  `group_queue_episodes` setting keeps its key but now stores `none`, `podcast`,
  or `folder`. `AppSettingsStore.queueGrouping()` maps the shipped string
  booleans (`true`/`false`) to `podcast`/`none`, so existing choices survive
  without touching the SwiftData schema.
- **One subtree map per grouping pass.** `FolderRepository.rootFolderByPodcast()`
  resolves every filed podcast to one deterministic top-level folder. Queue
  display, row moves, group moves, playback ordering, and group-boundary
  auto-advance all reuse that map instead of walking folder relationships per
  episode or per action.
- **Accessibility semantics stay parallel to podcast grouping.** The native
  three-way `Picker` is named "Group queue"; switching modes is announced once.
  Each folder header remains one heading element named "[Folder], N episodes"
  and exposes the existing Play Group, Move Group Up/Down, Sort, and Shuffle
  rotor actions in the same order. Header focus is keyed by `QueueGroup.Kind`,
  including a stable `unfiled` key, so reordering never strands VoiceOver.

### Issue #763 — Folder-scoped Inbox and listening
- **No schema change.** A folder scope is its de-duplicated subtree of podcasts.
  SwiftData/Core Data cannot execute a captured-array `contains` across
  `Episode.podcast` (the optional relationship generates an unsupported SQL
  subquery), so `InboxQuery.folderUnplayedPredicate(podcastID:)` uses the
  supported scalar relationship equality once per subtree podcast. The
  repository merges those store-bounded results newest-first; it never fetches
  the global library or faults every podcast's inverse episode collection.
- **Scoped snapshots are event-driven.** The global `@Query` candidates live in
  a conditional child and are torn down while a folder filter is active. The
  folder snapshot reloads only when its podcast scope changes, Inbox membership
  changes, queue membership changes, or the opt-in setting changes—not on the
  five-second playback-position save that caused #736.
- **Play/queue all shares one eligibility list.** The folder repository walks
  subtree subscriptions once, de-duplicates episodes, applies `.newEpisode`,
  dismissal, queue, and folder-age rules, then sorts newest-first. Queue All is
  a single batch write; Play All batches the same order and starts its first
  episode. Nested folders participate and multiply-filed podcasts never duplicate.
- **Accessibility stays explicit and mutation-safe.** The Inbox's native
  44-point menu picker is always reachable, including from an empty scope, and
  names nested choices by full breadcrumb. Folder Detail exposes one real "New
  episodes" heading with a spoken empty state and a native listening-actions
  menu. Played/queued rows move VoiceOver focus to a surviving neighbor or the
  scoped empty state, and result announcements carry the episode count.

### Issue #764 — Folders phase 3, OPML round-trip (nested export + subscribe-to-folder)
- **Nested export is additive; the flat `export(_:)` stays.** `OPMLDocument` gains
  value-type `OPMLFeed` / `OPMLFolderNode` and a new
  `export(folders:unfiled:)` that emits the folder hierarchy as nested `<outline>`
  groups (a folder's own feeds, then its subfolders, recursively) with unfiled
  podcasts as a flat top-level list. The old flat `export(_:)` is kept verbatim
  because `SettingsStoreTests` and `OPMLFileImporterTests` still call it; both
  share one `document(body:)` envelope so heads/framing are byte-identical.
  `OPMLDocument` stays Foundation-only (no SwiftData) so the emitter is pure and
  unit-testable.
- **The builder lives on `FolderRepository`.** `opmlExportString()` walks
  `childFolders(of:)` from the roots and maps each folder's direct
  `podcasts(in:)` onto nodes, appending `unfiledPodcasts()` at top level. It
  carries a `Set<PersistentIdentifier>` visited guard so a corrupt parent/child
  cycle can never spin the recursion (mirrors `FolderLogic.flattenSubtree`).
  Settings → Data "Export podcasts (OPML)" now calls this instead of the flat map;
  the `@Query podcasts` there still only gates the button's enabled state.
- **Round-trip contract = each feed re-imports under the folder it is filed
  DIRECTLY in.** The import path (`OPMLDocument.groups(from:)`) assigns a feed to
  its nearest enclosing named outline, so a podcast in subfolder Tech (nested under
  News) round-trips to folder "Tech", not "News". Export→import is therefore stable
  per-folder; the visual News▸Tech nesting is flattened to leaf-folder groups on
  re-import, which is the pre-existing import behavior — lossless for feed URL +
  title. Empty folders emit a valid empty `<outline>` group that simply drops out
  on re-import (groups() only surfaces folders that hold feeds).
- **A podcast in several folders is exported once per folder.** OPML has no
  cross-links; re-import de-dupes by first folder (existing `importOPML` behavior),
  so no duplicate subscription results.
- **Subscribe-to-folder is gated on `folderCount > 0` (decision F8).** After a
  successful follow from the Add/Search flow (`SearchView.subscribe` and
  `PodcastPreviewView.toggleFollow`), the app presents the existing shared
  `FolderPickerView` in `.add` mode with the just-followed podcast — but only when
  the user already has ≥1 folder. The decision is the pure, tested
  `FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount:)`. The picker
  reuses its own Cancel (= "not now") and its deferred `Announcer` outcome, so no
  new announcement or dismissal path was added.

### Issue #761 — Quick Action context menus
- **One resolved action array feeds both surfaces.** `EpisodeRow` passes its
  existing `buildEpisodeActions` result to both the VoiceOver Actions rotor and
  the new long-press context menu. Library podcast rows resolve
  `buildPodcastActions` once and share that exact array the same way; folder
  podcast rows do likewise with their fixed "Remove from folder" action. This
  prevents labels, availability, order, and destructive roles from drifting.
- **The rotor remains the guaranteed accessibility path.** Context menus are a
  convenience only and do not replace `.accessibilityActions`. Selection-mode
  rows deliberately omit them so long press never conflicts with selection.
  Attaching the modifier outside the existing `Button` / `NavigationLink`
  preserves normal tap activation. Unlike the iOS rotor, context menus render
  in declaration order, so they must not use the rotor's reversal compensation.

### Issue #751 — Folders phase 1, SwiftData schema V6
- **Purely additive, lightweight-inferrable migration (V5→V6).** The whole point
  of phase 1 is the safest possible schema bump: no attribute is reshaped and
  nothing non-optional is added, so SwiftData's lightweight inference handles it
  and no `.custom` stage is needed. Two additions: (a) a new
  `EpisodeFolderMembership` entity (episode↔folder join, the analogue of
  `FolderMembership`), and (b) optional self-referential `parent`
  (`PodcastFolder?`, `.nullify`) + inverse `children` (`[PodcastFolder]`) on
  `PodcastFolder` for nesting. Every existing folder migrates as top-level
  (`parent == nil`); the new join table starts empty.
- **V5 was frozen into a nested snapshot before the live models changed.** V5
  previously pointed at the live top-level `@Model` types; per the drift-crash
  discipline (#425), it was copied verbatim into nested `EarshotSchemaV5.*`
  classes (matching how V4 is frozen) so V5 keeps hashing to exactly what
  shipped. V6 is now the only versioned schema referencing the live types.
- **No inverse on `Episode` for the new join (the #701 discipline).**
  `EpisodeFolderMembership.episode` is deliberately one-way. An
  `@Relationship(inverse:)` collection on `Episode` would change `Episode`'s
  shape and put a real library's ~242k episode rows back into the migration's
  path. Cleanup of orphaned join rows on episode/podcast delete is a later phase
  (`// TODO(folders P2): cleanup on episode delete`), following the same manual
  discipline `FolderMembership`/`ActiveDownload` already use.
- **Migration is a required CI gate.** `StoreMigrationV5toV6Tests` seeds a real
  on-disk store at frozen V5 (folders, memberships, a podcast with NULL
  optionals, episodes, a queue item), opens it through the production
  `StoreMigration.openOrMigrate` path, and asserts nothing throws, folders and
  memberships survive, `parent` is nil, and both nesting and the new join table
  work post-migration. `SchemaDriftTests` now guards V6 against the live types
  and asserts the live graph differs from frozen V5 only by the intentional
  additions.

### Issue #635 — Earshot Plus: enforce 10-podcast free tier cap
- **Pure decision logic, no StoreKit/ModelContext.** `PodcastCapPolicy`
  (Features/Monetization/Domain) takes primitives + `[Podcast]` arrays only —
  no `ModelContext`, no StoreKit — matching how `InboxRepository.inbox(from:)`
  / `QueueRepository.displayedCount(from:)` already take model arrays directly
  in this codebase. Trivially unit-testable with in-memory `@Model` fixtures.
- **`effectiveFreeLimit = max(freeTierLimit, grandfatheredCount)` is the whole
  grandfathering mechanism.** Michael's confirmed rules combine two things: (a)
  a lapsed user's over-cap podcasts go read-only but are never deleted, and (b)
  current TestFlight testers already over 10 podcasts keep everything they
  have, with the cap only applying to *adding* going forward. Naively combining
  these has an edge case the issue text doesn't spell out: a grandfathered
  tester's pre-existing podcasts must never themselves become read-only, even
  if they later buy Plus, add more, and then lapse. `effectiveFreeLimit`
  solves this: `PodcastCapPolicy.ranked()` orders podcasts oldest-`createdAt`
  first, so a grandfathered user's original podcasts are always the
  lowest-ranked (and thus always under the raised limit); they just get no
  MORE free slots than they already had. A grandfathered-15 user who buys
  Plus, adds 10 more (25 total), then lapses, has those 10 NEW podcasts (not
  the original 15) go read-only. This is my synthesis of an edge case Michael
  didn't spell out explicitly — flag for correction if he disagrees.
- **Grandfathering is a one-time snapshot, taken once ever.** Two new
  `AppSettingsStore` keys: `podcastCapGatingIntroduced` (Bool) and
  `grandfatheredPodcastCount` (Int). `introducePodcastCapGatingIfNeeded(
  currentPodcastCount:)` is idempotent — the first call snapshots the current
  podcast count and flips the introduced flag; every later call is a no-op,
  so the grandfathered allowance can never silently grow. Called from
  `RootView`'s launch `.task`, right after `settings.configure`, before
  `showOnboarding` is set — so it always runs ahead of any possible subscribe
  action, including an onboarding OPML import.
- **No persisted "this podcast is read-only" flag anywhere.**
  `PodcastCapPolicy.readOnlyPodcastIDs` is computed live off the CURRENT
  `EntitlementStore.isEntitled` + the current podcast list every time it's
  read (Library row rendering, auto-download). Resubscribing to Plus (or
  dropping back under the cap) restores full access immediately with no
  stale state to clear — pinned down by a dedicated
  `PodcastCapPolicyTests` case rather than left as an assumption.
  `SubscriptionRepository`'s `isEntitled: Bool?` is `nil` by default (cap not
  enforced), preserving every pre-existing call site and test.
  `SubscriptionRepository(context:)` construction sites that only ever call
  `unsubscribe` were deliberately NOT given `isEntitled:` — unsubscribing
  doesn't touch the cap or downloads.
- **Cap check happens before the network fetch.** `subscribe(feedURL:)` throws
  `SubscriptionError.podcastCapReached(currentCount:limit:)` (now
  `LocalizedError`) right after the existing-podcast early return but before
  `FeedRefreshActor` is invoked, so a blocked add never wastes a fetch. The
  bulk `subscribeAll(feedURLs:)` path (OPML) trims `feedURLs` to
  `PodcastCapPolicy.allowedNewSubscriptions(...)` BEFORE handing anything to
  the background actor, for the same reason, and returns a
  `BulkSubscribeResult` (outcomes + `skippedForCap`) instead of a bare array.
  `OPMLImportService.importOPML` now returns `OPMLImportOutcome` (importedCount
  + skippedForCapCount) instead of a bare `Int` — every existing test call
  site was updated to read `.importedCount`.
- **Auto-download skips read-only podcasts' episodes.**
  `SubscriptionRepository.autoDownloadRecent` computes
  `PodcastCapPolicy.readOnlyPodcastIDs` once per call (only when
  `isEntitled == false`) and filters them out of the download candidates —
  this is the "no new episodes download for podcasts beyond the first 10"
  requirement, wired into the exact #639 auto-download path.
- **The Announcer is the only accessible surface for OPML import outcome** —
  this app has no persistent OPML-import status screen. When the cap trims an
  import, `OPMLFileImporter.importFile`'s spoken outcome is extended (not
  replaced) to report how many feeds were skipped and why, with an upgrade
  mention, rather than inventing a new screen just for this issue.
- **Library read-only indicator is icon + text, not color alone**
  (accessibility rules) — a `Label("Read-only", systemImage: "lock.fill")`
  sits alongside the episode-count caption, `accessibilityHidden` because the
  state is folded into the row's combined `accessibilityLabel` instead
  (mirrors the sheet-heading / error-row pattern already used elsewhere in
  this codebase, avoiding a duplicate VoiceOver node).
- **Search/preview subscribe-failure announcements now surface the specific
  error** (`(error as? LocalizedError)?.errorDescription`) instead of a
  generic "Couldn't follow {title}" — needed so the cap message
  ("You've reached the 10-podcast limit...") actually reaches VoiceOver from
  `SearchView`/`PodcastPreviewView`, matching the pattern `AddFeedView`
  already used before this issue.
- **#632 (paywall) is NOT built here.** `SubscriptionError.podcastCapReached`
  is the gate/result a future paywall presentation hooks into; this issue only
  defines that contract, not the UI that reacts to it.

### Issue #634 — On-device StoreKit 2 receipt validation (Earshot Plus entitlement)
- **No new SwiftData model, no schema bump.** Entitlement state is two
  `AppSetting` key/value rows (`earshot_plus_entitled`,
  `earshot_plus_entitlement_last_synced`), following the exact pattern
  `TipsStore` already uses for "small piece of app state that should survive
  relaunch." A dedicated `@Model` would have forced an `EarshotSchemaV5` bump
  and a migration test purely to persist one bool + one date — not justified.
- **Three-layer split, StoreKit isolated to one file.** `EntitlementFact`
  (Domain) is a plain Sendable struct with no StoreKit import.
  `EntitlementEngine` (Domain) is a pure, synchronous
  `[EntitlementFact] -> Bool` decision function. `RawTransactionResult` +
  `EntitlementFactMapper` (Domain) do the verify/reject mapping
  (`VerificationResult`-shaped but StoreKit-free) so that logic is unit
  testable with plain fixtures. `StoreKitEntitlementSource` (Data) is the
  *only* type that imports `StoreKit` and touches
  `Transaction.currentEntitlements` / `Transaction.updates` directly — it
  reduces each real `VerificationResult<Transaction>` to a
  `RawTransactionResult` and hands it to the pure mapper. `EntitlementStore`
  (Data) wires persistence + an `EntitlementTransactionSource` together and
  owns the listener lifecycle. This was worth the extra file because the
  issue explicitly required the verify/reject and grant/deny logic to be
  testable without a real or `SKTestSession`-simulated StoreKit environment
  — `EntitlementFactMapperTests` and `EntitlementEngineTests` need zero
  StoreKit setup as a result.
- **`Transaction.updates` recomputes from scratch, not incrementally.**
  `EntitlementTransactionSource.updateSignals()` carries no payload — a
  signal just means "call `currentFacts()` again." Simpler and more robust
  than trying to apply one transaction update as a delta against unknown
  prior state, and it's the same code path Restore Purchases (#633) needs
  anyway (`EntitlementStore.resync()`).
- **`transaction.finish()` scoped to the three Plus products only.** The
  `Transaction.updates` listener finishes verified transactions for
  `EarshotPlusProduct.earshotPlusProducts` (entitlement granted = content
  delivered), but deliberately leaves tip jar consumable transactions
  unfinished — finishing a consumable is part of granting its content, which
  is #636's job, not entitlement tracking's.
  Unverified/unrecognized-product transactions are also left unfinished.
- **Ambiguous-state resolutions (all denied, per Michael's explicit rule):**
  unverified `VerificationResult` (unwrapped, logged via `AppLog.monetization`,
  no fact produced); a verified transaction whose `productID` doesn't match
  any `EarshotPlusProduct` case (unrecognized/retired ID — logged, no fact);
  a fact whose `revocationDate` is set, regardless of any other field; a
  subscription fact whose `expirationDate` is at or before `now` (defensive —
  `Transaction.currentEntitlements` is documented to already exclude expired
  subscriptions, but the engine doesn't trust that alone). None of these has
  a "grant" branch anywhere in `EntitlementEngine` or `EntitlementFactMapper`.
- **Listener lifecycle.** `EntitlementStore.startObservingTransactionUpdates()`
  is called once from `EarshotApp`'s launch `.task` (same place
  `BackgroundFeedRefresher`/`NotificationService` are wired), guarded by the
  existing `isRunningTests` check. It's a `Task { [weak self] in ... }`
  stored on the store and is idempotent (a second call is a no-op) so the
  call site doesn't need to track whether it already started — matches the
  existing `Task { [weak self] in ... }` pattern already used in
  `PlayerService`.
- **Public API for #633/#635 to build on:** `EntitlementStore.isEntitled`
  (sync, reflects last-persisted state, no StoreKit round trip),
  `EntitlementStore.configure(context:)` (load persisted state, call once at
  launch before reading `isEntitled`), `EntitlementStore.resync() async ->
  Bool` (forces a fresh StoreKit read + persist; #633's Restore Purchases
  should call this after `AppStore.sync()`), and
  `EntitlementStore.lastSyncedAt` (diagnostics).
- **No user data deleted on revocation.** `EntitlementStore` only ever writes
  its own two `AppSetting` rows; a regression test
  (`testResyncDoesNotDeleteAnyUserDataOnRevocation`) asserts a `Podcast`
  survives a revoke-then-resync round trip. Cap enforcement / lapse behavior
  is #635's scope, not this issue's.

### Issue #632 — Earshot Plus: paywall / upgrade screen
- **StoreKit-free `PaywallLogic` mirrors the `EntitlementFact` pattern from
  #634.** `PaywallProductDisplay`/`PaywallSubscriptionPeriod` (Domain) are
  plain structs a live StoreKit `Product` gets mapped into by
  `PaywallViewModel` (Presentation) — the only place besides
  `purchase(_:entitlements:)`'s direct `product.purchase()` call that imports
  `StoreKit`. Every other decision (badge math, accessibility labels,
  disclosure copy, announcement text/assertiveness) is a pure function over
  those structs, so it's fully covered by headless `PaywallLogicTests` (20
  tests, 0 StoreKit I/O) rather than inheriting the `SKInternalErrorDomain
  Code=3` local-daemon limitation documented for #631's
  `ProductCatalogServiceTests`. A separate `PaywallViewModelTests` (3 tests)
  exercises `loadProducts()` against a real `SKTestSession` the same way
  `ProductCatalogServiceTests` does, and — as expected — hits the identical
  known environment limitation in this sandbox; not a #632 regression, see
  that file's doc comment.
- **"Best value" badge is computed from real StoreKit prices, never
  hardcoded, and can only ever be honest.** `PaywallLogic.bestValueBadge`
  divides yearly's price by its `approximateMonths` (30-day months, 365-day
  years — an approximation used only for this comparison, never for
  billing), compares against monthly's price, and returns `nil` if yearly
  doesn't actually save money or either input is missing/non-positive. The
  percentage is floored, never rounded, so the claim can't overstate the
  saving by even a fraction of a point. At the shipped `Configuration.storekit`
  prices ($2.99/mo, $20/yr) this computes to "Best value — about 44% off
  monthly" — a real, reproducible number, not a copy-writer's guess.
- **Equal weight is structural, not just stylistic.** All three product
  cards share one `productCard(_:badge:)` view builder — same font sizes,
  same `.borderedProminent` button style, same card chrome — so Monthly
  can't accidentally end up smaller/muted/buried by a future edit touching
  only one card. The badge is the ONLY per-product visual difference, and
  it's a `Label` (icon + text), not a background-color or size change.
- **Disclosure text is a separate, always-visible element positioned before
  the purchase button — never a hint, never a `DisclosureGroup`.** This was
  the most load-bearing layout decision: App Store Review Guideline 3.1.2
  requires price/terms be visible before purchase is reachable, and an
  `accessibilityHint` technically satisfies "reachable" for VoiceOver (hints
  speak right after the label) but does NOT satisfy "visible" for sighted
  users scanning the card. A standalone `Text` row above the button solves
  both at once, and happens to also give VoiceOver users the disclosure
  BEFORE the button in swipe order for free, with no
  `accessibilitySortPriority` needed.
- **Purchase state machine lives in `PaywallViewModel`, not the view.**
  `.success(.verified)` finishes the transaction directly (WWDC "Meet
  StoreKit 2" pattern) and calls `entitlements.resync()` before returning,
  rather than relying solely on the long-running `Transaction.updates`
  listener (`EntitlementStore.startObservingTransactionUpdates()`, already
  running since launch) — that listener WILL also observe this exact
  transaction and is a safe no-op the second time, but finishing here is
  what makes `isEntitled` flip before the async call returns instead of
  racing listener timing. `.unverified` is never finished, mirroring
  `StoreKitEntitlementSource`'s existing conservative handling.
  `.userCancelled` deliberately does NOT set the `outcome` property at all —
  see the next bullet.
- **Judgment call: cancellation has no persistent UI state, only a brief,
  non-alarming announcement.** `PaywallPurchaseOutcome` (the enum driving the
  inline banner) intentionally has only 3 cases — `success`/`pending`/
  `failed` — with no `cancelled` case. A user-cancelled purchase returns to
  the exact same interactive paywall state as before tapping, with only
  `PaywallLogic.cancelledAnnouncement` ("Purchase cancelled.", NOT assertive)
  spoken. This was the most literal reading of the hard constraint
  "dismissing must be exactly as easy and neutral as any other iOS sheet
  dismissal" extended to cancelling a purchase specifically — a persistent
  "Cancelled" banner would have made cancelling feel like a worse outcome
  than just closing the sheet.
- **Judgment call: success does NOT auto-dismiss.** The sheet shows an inline
  success banner ("You're an Earshot Plus member. Thank you.") and purchase
  buttons disable themselves, but the user closes it with the same explicit
  Close button used at every other point. Considered auto-dismissing after
  the "Earshot Plus unlocked." announcement, but rejected it: a timed
  disappearance right after (or during) a VoiceOver announcement risks
  cutting off speech or disorienting the user, and nothing else in this
  paywall is time-based — an auto-dismiss would be the one moment the sheet
  does something on its own schedule instead of the user's, which cuts
  against the whole "no dark patterns" brief even though a success
  auto-dismiss isn't itself manipulative.
- **Judgment call: in-progress announcement is polite, not assertive.**
  `PaywallLogic.inProgressAnnouncement` ("Purchasing Earshot Plus Monthly.")
  is queued behind current speech, not interrupting — it's reassurance that
  the tap registered, not an urgent state change. It supplements (does not
  replace) the button's own accessibility-label swap to a busy phrase,
  matching `RestorePurchasesRow`'s established busy-state pattern
  (`.disabled` alone gives no spoken busy indication). All THREE settled
  outcomes (success/pending/failed) are assertive, matching
  `RestorePurchasesRow`'s outcome-announcement convention exactly.
- **Judgment call: fixed product order (Monthly, Yearly, Lifetime), never
  reordered by which one has a badge.** Shortest-to-longest commitment is a
  neutral, predictable ordering; re-sorting by "best value" would have made
  the ordering itself a subtle prominence signal, undermining the "equal
  weight" requirement even with identical styling.
- **Judgment call: Settings' new "Upgrade to Earshot Plus" row hides itself
  once `entitlements.isEntitled` is true.** Nothing in the issue specified
  already-entitled Settings copy, and `PaywallView` has no "you already have
  this" state; showing "Upgrade" to a paying member reads as confusing at
  best, so the row is conditionally hidden rather than building unrequested
  UI for a state PaywallView doesn't otherwise handle. "Restore Purchases"
  stays visible unconditionally either way (reinstall/new-device recovery
  path, independent of cached entitlement state).
- **OPML-cap wiring is additive, not a signature-breaking change.**
  `OPMLFileImporter.importFile` gained one new optional parameter,
  `onCapSkipped: (@MainActor @Sendable () -> Void)? = nil`, fired only when
  `outcome.skippedForCapCount > 0`, in ADDITION to the existing Announcer
  call (never instead of it). Every pre-existing call site (`RootView`,
  `AddPodcastView`, `OnboardingView`, and every existing
  `OPMLFileImporterTests`/`OnboardingOPMLImportTests`/`OPMLImportProgressTests`
  case) is untouched — only `DataSettingsView` (explicitly named in scope)
  passes the closure, setting its own `showPaywall` state.
- **Subscribe-cap wiring reuses the existing announcement, doesn't replace
  it.** `SearchView.subscribe(_:)` and `PodcastPreviewView.toggleFollow()`
  both already announce `SubscriptionError.podcastCapReached`'s message
  (#635); this issue adds `if case SubscriptionError.podcastCapReached =
  error { showPaywall = true }` right after, in both catch blocks.
  `AddPodcastView` needed no changes of its own — it embeds `SearchView` in
  `.addPodcast` scope directly, so `SearchView`'s own paywall sheet already
  covers it.
- **No launch interstitial, no timer.** `PaywallView` is presented from
  exactly three `.sheet(isPresented:)` call sites (`SearchView`,
  `PodcastPreviewView`, `SettingsScreen`) plus one `.sheet(item:)`-adjacent
  `DataSettingsView` cap-skip path — never from `RootView`/`EarshotApp`.
  Verified `RootView.swift`/`EarshotApp.swift` were not touched by this
  issue at all (`EntitlementStore` was already in `.environment()` from
  #634).
- **CHANGELOG entries marked "(pending design/copy review, not yet merged)"**
  per this issue's explicit instruction — the visible copy (title, subtitle,
  button/disclosure text) is a first pass, not confirmed final wording.

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

## Security Review — UX Round 1 (branch feat/ux-round-1)

earshot-security review complete. Three commits: fdf0982 (onboarding Next gate),
2669a0c (library search/add split), 9a1d125 (Subscribe→Follow rename). No GitHub
issue number assigned to this round; tracked here.

Checklist:
- [x] Force-unwraps: PASS — none found. `UTType(filenameExtension:) ?? .xml`
  fallback used in both file importers, not a force-unwrap.
- [x] Silent try?: PASS — one `try? await Task.sleep` (SearchView:286). Acceptable:
  Task.sleep only throws CancellationError and cancellation is handled by the very
  next line (`if Task.isCancelled { return }`); nil == cancelled == expected.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — all `Task {}` blocks are inside SwiftUI View structs
  (value types; no self reference cycle). `directoryTask` is stored and explicitly
  cancelled in `.onDisappear` and at the head of each `scheduleDirectorySearch`.
  AddPodcastView/OnboardingView `fileImporter` + sheet closures capture only URL
  (Sendable) and MainActor context. No `.sink`/Timer/addObserver introduced.
- [x] @MainActor: PASS — directoryState/lastAnnouncedSummary mutations run inside
  View-isolated (MainActor) Task bodies; `announceDirectory` explicitly @MainActor.
  Only suspension points are `itunes.search` and `SubscriptionRepository.subscribe`,
  then resume on main. No background SwiftData @Model access added.
- [x] IS_BETA_BUILD Release build: PASS — migration files untouched this round;
  no IS_BETA_BUILD in changed code or in project.yml Release config. Release build
  succeeded (xcodebuild Release, iPhone 17 sim: ** BUILD SUCCEEDED **).
- [x] Entitlements: N/A — no Earshot.entitlements / Info.plist / project.yml entitlement
  changes in the round. OPMLFileImporter (the security-scoped helper) is unchanged and
  still brackets startAccessingSecurityScopedResource() with a balanced defer-stop;
  AddPodcastView reuses it with no new unscoped read.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new error types; existing typed errors/AppLog paths reused.
- [x] AppLog coverage: PASS — both new `handleImport` failure branches log
  `AppLog.data.error`; SearchView.subscribe catch logs `AppLog.networking.error`. No
  empty catch blocks.

Scope-specific verifications (the point of the round):
- `.library` SearchScope fires NO network/directory work: `onChange(of: query)` calls
  `scheduleDirectorySearch` only when `scope == .everywhere`; the "From the directory"
  section is gated `if scope == .everywhere`. No iTunes call, no debounce Task, no
  dangling task in `.library`. Pinned by SearchScopeTests. PASS.
- OPML import reuses the existing security-scoped helper with no new unscoped read in
  either AddPodcastView or OnboardingView. PASS.
- Rename touched user-facing strings + VoiceOver labels only. All remaining
  Subscribe/Subscription occurrences are non-user-facing and correctly left intact:
  AppLog.subscriptions category, log message strings, `earshot-subscriptions.opml`
  temp filename, `is_subscribed` DB-column query in FlutterMigrationService, and code
  identifiers (`subscribe`/`unsubscribe`/`.unsubscribe`/`isSubscribed`/`SubscribedValue`).
  No identifier/log/DB change. PASS.
- pbxproj diff adds only the 3 new source files; no build-setting or config changes.

Tests: SearchScopeTests (4) + AddPodcastOptionsTests (1) + OnboardingTipsTests green;
Release build clean.

Feature suggestions identified: none this round.

New agents created: none. Overall: PASS.

## Security Review — Issue #501

earshot-security review complete. Branch `feat/issue-501-search-nav-aid`. Scope =
diff vs the #499 branch: `SearchResultPosition.swift` (new pure helper),
`SearchView.swift` (row value + count announcement now route through the helper;
`ForEach` enumerates the materialized `[PodcastSearchResult]`), `OnboardingView.swift`
(comment-only — two stale `SubscribedValue` doc references updated), and
`SearchResultPositionTests.swift` (+13 tests).

Checklist:
- [x] Force-unwraps: PASS — none in any changed file. Helper is pure `min`/`max`
  arithmetic; SearchView changes add no `!`.
- [x] Silent try?: PASS — no new `try?`. The pre-existing `try? await Task.sleep`
  is unchanged and canonical (throws only on cancellation, checked next line).
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new closures. The directory `Task` lives in a value-type
  SwiftUI View (no self cycle) and is cancelled in `.onDisappear`. Unchanged here.
- [x] @MainActor: PASS — `announceDirectory` is `@MainActor`; the changed call passes a
  pure String. No new off-main UI-state mutation; no SwiftData @Model background access.
- [x] IS_BETA_BUILD Release build: PASS (build) / N/A (guard) — no migration files;
  no IS_BETA_BUILD in changed code or project.yml Release. xcodegen regen = no pbxproj
  drift. Release build, iPhone 17 sim: ** BUILD SUCCEEDED **.
- [x] Entitlements: N/A — no entitlement/project.yml entitlement changes.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new error types introduced.
- [x] AppLog coverage: PASS — no new catch blocks; existing subscribe() catch logs
  AppLog.networking.

Index/total mapping (user-facing a11y focus): `phrase(index:total:)` clamps into
`1...max(total,1)` — traced negative index (→1), overflow (99→50), and total<=0 (→1).
Pure arithmetic, no array indexing, so an out-of-range index cannot crash; worst case
is a clamped but well-formed phrase. Off-by-one correct (zero-based +1 → one-based;
last row == total). `rowValue` composes position after #499's "Following" state and is
never empty in either state. `countAnnouncement` handles singular/plural explicitly,
replacing the iOS inflect markup with testable logic. All 13 tests trace correctly.

Feature suggestions identified: none this review.

No fixes required; no commits made to the branch. Overall: PASS.

## Security Review — Issue #515

earshot-security review complete. Branch `feat/515-chapter-nav-buttons-flanking-name`.
Scope = diff vs `swift` tip: `NowPlayingScreen.swift` (chapter row restructured so
Previous/Next chapter buttons flank the chapter-name button, gated on the new
`showChapterNavButtons` computed flag), `ChapterNavLogic.swift` (+pure
`shouldShowNavButtons(chapterCount:settingEnabled:)`), `AppSettingsStore.swift`
(+`SettingsKey`/`SettingsDefault.chapterNavButtonsVisible`, default true),
`SettingsStore.swift` (+observed Bool with persist `didSet`, loaded in
`configure`), `SettingsScreen.swift` (+Toggle with explanatory footer), and tests
(`ChapterNavLogicTests.swift` +4, `AppSettingsStoreTests.swift` +3).

Checklist:
- [x] Force-unwraps: PASS — none introduced. Flagged `try?` (AppSettingsStore:149/157)
  and `Task {` / `try? await Task.sleep` (NowPlayingScreen) are pre-existing lines
  outside this diff.
- [x] Silent try?: PASS — none added by #515.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new closures/Tasks. The two `transportButton`
  actions take MainActor method references (`player.previousChapter`/`nextChapter`)
  invoked synchronously from a SwiftUI Button; views are value types, no self capture.
- [x] @MainActor: PASS — `SettingsStore` is `@MainActor @Observable`; the new
  `chapterNavButtonsVisible` is a plain Bool read on the main actor. PlayerService
  chapter access stays on MainActor. No data race.
- [ ] IS_BETA_BUILD Release build: N/A — no migration files; schema frozen per #425.
- [ ] Entitlements: N/A — no entitlement/project.yml changes.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — pure value logic + key/value setting; no new error types.
- [x] AppLog coverage: PASS — no new catch blocks.

The new AppSetting follows the existing safe pattern exactly (Key + Default
constants, `didSet` persist, `configure` load). Tests cover default, round-trip,
persist-across-relaunch, and the 4-case pure gating logic. Testing gate already
green (832 tests, Debug+Release clean).

Feature suggestions identified: none this review.

No fixes required; no commits made to the branch. Overall: PASS.

## Security Review — Issue #517

Stream-only playback from the Search podcast preview via a transient, detached
(never-inserted) `Episode`. Files reviewed in full: `PlayerService.swift`,
`PodcastPreviewModel.swift`, `PodcastPreviewView.swift`, plus the two test files.

- [x] Force-unwraps: PASS — none. Added-line `!` are all boolean negation; URL
  handling goes through optional `PlaybackLogic.resolvePlaybackURL` + guard.
- [x] Silent try?: PASS — none in production; two `try?` live in the test
  `storeCounts` helper with a `-1` sentinel (acceptable XCTest exception).
- [x] fatalError: PASS — none.
- [x] Retain cycles: PASS — `playPreview` is straight-line, no new closures; the
  pre-existing chapter/artwork Tasks and observers use `[weak self]`, unmodified.
- [x] @MainActor: PASS — `PlayerService` is `@MainActor`; the detached `@Model`
  is only touched on the main actor and NEVER crosses a Sendable boundary — only
  Strings reach `ChapterService`, only `URL?` reaches the artwork fetch.
- [ ] IS_BETA_BUILD Release build: N/A — no migration files; schema frozen (#425).
- [ ] Entitlements: N/A — no entitlement/project.yml changes.
- [x] No secrets: PASS — none.
- [x] Error types: PASS — empty/malformed URL is a logged no-op, not an error.
- [x] AppLog coverage: PASS — no-audio-URL guard logs; no new catch blocks.

CRITICAL invariant (preview = NO store writes) verified in code: all five sinks
(`persistCurrentPosition`, `persistPositionThrottled`, `flushListeningSession`
[the `context.insert(session)` vector], `markCurrentEpisodePlayed`,
`persistLastPlayingEpisode`) early-return on `currentEpisodeIsTransient`. The
flag is set (line 335) AFTER the outgoing-episode persist/flush (lines 302-303),
so neither direction leaks. The completion path is structurally safe too:
`markPlayedAndRemove(detached)` no-ops because `queueItem == nil`, mutating a
non-inserted model leaves `context.hasChanges` false, and `saveContext` guards on
that. Speed-override writes guard on the (nil) `podcast`. The detached `Episode`
is built via `init` only and never inserted anywhere — #425 freeze intent intact.
Behavioral note: a preview that ends with a non-empty queue auto-advances into
the queue (persistence restored via `transient: false`); no preview-side write.

Feature suggestions identified: none this review.

No code fixes required. Overall: PASS.

## Security Review — Issue #518

earshot-security review complete. Issue #518 (strip HTML / decode numeric
entities in podcast descriptions). Branch `fix/518-strip-html-descriptions`.

Checklist:
- [x] Force-unwraps: PASS — none introduced.
- [x] Silent try?: PASS — one `try? NSRegularExpression(pattern:)` on a
  hardcoded constant pattern with a safe `guard ... else { return text }`
  fallback. Accepted idiom (provably-valid compile-time pattern, graceful
  degradation), not runtime error suppression.
- [x] fatalError: PASS — none.
- [x] Retain cycles: PASS — pure static funcs, no closures capturing self.
- [x] @MainActor: N/A — synchronous, side-effect-free static string work; no
  UI state, no actor isolation, no threading concern.
- [ ] IS_BETA_BUILD Release build: N/A — no migration files.
- [ ] Entitlements: N/A — none changed.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new error types; failures degrade to verbatim text.
- [x] AppLog coverage: PASS — no new catch blocks.

Hostile-feed safety (focus of this change):
- Regex `&#[xX]?[0-9A-Fa-f]+;` is single-quantifier, anchored by literal `&#`
  and `;`, no nested quantifiers/alternation — no catastrophic backtracking.
- `UInt32(body, radix:)` returns nil on overflow (giant entity bodies) → token
  kept verbatim, O(n), no hang.
- `Unicode.Scalar(code)` is failable: surrogate (0xD800–0xDFFF) and
  out-of-range (>0x10FFFF) values return nil → kept verbatim, no crash.
- UTF-16 (NSString) match ranges fall on ASCII `&#...;` boundaries, so the
  verbatim runs between matches can't split a surrogate pair.
- Tests cover surrogate, out-of-range, non-hex shape, empty body, hex a–f
  letters, uppercase X — all hostile paths asserted.

Feature suggestions identified: none this review.

No fixes required; no commits made to the branch. Overall: PASS.

## Security Review — Issue #639

earshot-security review complete. Issue #639 (auto-download of newest
episodes does not work). Branch `fix/issue-639-auto-download`, commit
`7701597`.

Checklist:
- [x] Force-unwraps: PASS — none introduced.
- [x] Silent try?: PASS — no new `try?` introduced; existing `modelContext.fetch`
  `try?` usages in `FeedRefreshActor` are pre-existing, unrelated to this change.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new `Task {}`/`sink`/`Timer`/`NotificationCenter`
  closures; only `@Environment(DownloadManager.self)` property injection and
  parameter threading through existing (unmodified) closure bodies.
- [x] @MainActor: PASS — `RefreshOutcome`/`ApplyOutcome`/`SubscribeOutcome`
  stay `Sendable` value types crossing the `FeedRefreshActor` boundary; no
  `@Model` object crosses. Verified the persistentModelID-post-save
  restructuring is correct: `ApplyOutcome.newEpisodes` holds live `@Model`
  episodes inside the actor, and `.result()` (which reads `persistentModelID`)
  is called only after `saveIfNeeded()`/`flushPending()` in every path
  (`refreshOne` and `refreshAll`'s batched `flushPending`).
- [ ] IS_BETA_BUILD Release build: N/A — no migration files changed.
- [ ] Entitlements: N/A — none changed.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new error types needed; existing `AppLog`
  logging preserved on all touched catch paths.
- [x] AppLog coverage: PASS — no empty catch blocks introduced.

Targeted checks from the review brief:
- Backfill exclusion: verified — the migrated-shell backfill branch returns
  `ApplyOutcome(refreshOutcome: .backfill, newEpisodes: [])`, so
  `newEpisodeIDs` is always empty on backfill, matching the `wasBackfill`
  notification gate. Confirmed by `testBackfillRefreshOutcomeNewEpisodeIDsIsEmpty`
  / `testBackfillRefreshDoesNotAutoDownload`.
- No double-download / republish path: verified — `newEpisodes` is populated
  only from the `!existingGUIDs.contains(item.guid)` loop (genuinely new
  guids). `resurfaceRepublished()` operates on already-existing episodes and
  never touches `newEpisodes`, so a republished-guid resurface never triggers
  auto-download. Auto-queued episodes are intentionally also eligible for
  auto-download (documented as orthogonal, confirmed by
  `testRefreshAutoDownloadsNewEpisodeEvenWhenAutoQueued`) — a product
  decision, not a bug; each podcast's downloads are capped independently at
  `autoDownloadCount`.
- `BackgroundFeedRefresher.swift` (BGTaskScheduler / cold-launch / foreground-
  resume path) correctly needed no change — it already constructs its own
  `SubscriptionRepository(downloader:)`, so it automatically benefits from
  `refreshAll()` now calling `autoDownloadRecent`.

Build/test verification: `xcodebuild test -scheme Earshot -destination
'platform=iOS Simulator,name=iPhone 17' -only-testing:EarshotTests/SubscriptionRepositoryTests`
— BUILD SUCCEEDED / TEST SUCCEEDED, 36/36 passed, 0 failures. All 6 new #639
tests confirmed passing.

Feature suggestions identified: none this review (scope intentionally kept
narrow per the review brief; no new feature issues filed).

No fixes required; no commits made to the branch. Overall: PASS.

## Swift 6 Review — Issue #639

earshot-swift6 review complete. Issue #639 (auto-download of newest episodes
does not work). Branch `fix/issue-639-auto-download`, commit `7701597`.

Concurrency mode: project.yml has `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (Swift 6 migration not yet flipped on for
this target). Reviewed both under the project's real settings and under a
forced `SWIFT_STRICT_CONCURRENCY=complete` override to surface anything the
eventual migration would catch.

Checklist:
- [x] Sendable conformance: PASS — `ApplyOutcome` (new private struct in
  `FeedRefreshActor.swift`) is deliberately NOT `Sendable` and never appears
  in a method signature exposed outside the actor; `refreshAll`/`refreshOne`
  always resolve it to the `Sendable` `RefreshOutcome`/`RefreshProgress`
  before returning, mirroring the pre-existing `SubscribeOutcome` pattern in
  the same file. `RefreshOutcome`'s new `newEpisodeIDs: [PersistentIdentifier]`
  field is `Sendable` (`PersistentIdentifier` is a Sendable value type); no
  non-Sendable field was introduced.
- [x] Actor isolation: PASS — `saveIfNeeded()` runs entirely on the
  `FeedRefreshActor`'s own isolated context; `ApplyOutcome.result()` (which
  reads `persistentModelID`) is called only after a save in every path
  (`refreshOne` saves then calls `.result()`; `refreshAll`'s `flushPending()`
  saves then resolves every pending row). No `@Model` object crosses the
  actor boundary.
- [x] @Model/SwiftData actor boundary: PASS — same as above; `ApplyOutcome`
  holds live `Episode` `@Model` objects but they never leave
  `FeedRefreshActor`.
- N/A AVAudioSession main actor: no audio session code in this diff.
- N/A Combine publishers: none in this diff.
- [x] nonisolated functions: N/A — no new `nonisolated` needed; the new code
  is all actor-isolated (background actor) or `@MainActor`
  (`SubscriptionRepository`), correctly.
- [x] Structured concurrency: PASS — the new `pendingIndexByApply`/
  `flushPending()` local function in `refreshAll` is a plain nested function
  (not an escaping closure), inherits the enclosing actor's isolation, and
  never escapes the call frame. `onProgress` (`@MainActor @Sendable`) is
  still correctly `await`-called at the same relative point in the loop as
  before the restructuring. No `Task.detached` anywhere in the diff.
- [x] Global state: PASS — none introduced.
- [~] Swift 6 build clean: PASS for this diff, with one pre-existing,
  out-of-scope finding — see below.

Targeted checks from the review brief:
1. `ApplyOutcome` never crosses the actor boundary — confirmed by reading
   every call site; it's a `private struct`, only ever consumed inside
   `refreshAll`/`refreshOne`/`apply(...)`, all of which live on
   `FeedRefreshActor`.
2. `RefreshOutcome.newEpisodeIDs: [PersistentIdentifier]` — confirmed
   `Sendable` holds; `PersistentIdentifier` is the same Sendable value type
   already used by `SubscribeResult.episodeIDs`/`podcastID`.
3. `pendingIndexByApply`/`flushPending()` — no capture/isolation issues;
   `onProgress` await placement unchanged relative to the pre-restructuring
   code.
4. `autoDownloadRecent(episodeIDsPerPodcast:)` calling
   `downloader.download(episode)` — **pre-existing, not introduced by this
   diff**: under a forced `SWIFT_STRICT_CONCURRENCY=complete` build, the
   `await downloader.download(episode)` call inside `autoDownloadRecent`
   (and the identical call inside `subscribe()`) emits "sending 'episode'
   risks causing data races" / "sending value of non-Sendable type 'any
   EpisodeDownloading' risks causing data races" — confirmed present
   identically on the `swift` base branch before this diff (same two
   call-site locations, unmodified by this diff). Root cause: the
   `EpisodeDownloading` protocol requirement isn't `@MainActor`-isolated
   even though the only conformer (`DownloadManager`) is, so the compiler
   can't statically prove the call stays on the main actor. This diff adds
   two *new call sites to* `autoDownloadRecent` (from `refresh()` and
   `refreshAll()`) but does not add a new textual `download(...)` call, so
   it does not add a new instance of this diagnostic — confirmed by diffing
   full warning output between a clean worktree build of `swift` and a clean
   worktree build of this branch at the same forced strict-concurrency
   setting: warning count and locations are unchanged. Under the project's
   *actual* committed settings (`SWIFT_STRICT_CONCURRENCY: minimal`), this
   surfaces as a single warning at the conformance site
   (`DownloadManager.swift:122`, a file this diff does not touch), also
   unchanged from baseline. Not fixed here per "no scope creep" — flagging as
   a candidate for Layer 2 of the eventual Swift 6 migration (likely fix:
   mark `EpisodeDownloading` `@MainActor`).
5. New `@Environment(DownloadManager.self)` wiring in
   `PodcastPreviewView`/`SearchView`/`DataSettingsView`/`AddFeedView`/
   `AddPodcastView`/`EpisodeListView`/`SubscriptionsView`/`RootView`/
   `OnboardingView` — all trivial reads of the existing
   `@MainActor @Observable final class DownloadManager`, matching the
   established pattern already used elsewhere in the app (registered via
   `.environment(downloads)` in `EarshotApp.swift`, not touched by this
   diff). No isolation warnings.

Build/test verification:
- `xcodebuild build` with the project's real settings (`SWIFT_VERSION 5.0`,
  `SWIFT_STRICT_CONCURRENCY minimal`) — BUILD SUCCEEDED, one pre-existing
  warning (`DownloadManager.swift:122`, unrelated file, present on `swift`
  baseline too).
- `xcodebuild build` forced to `SWIFT_STRICT_CONCURRENCY=complete` in three
  configurations (in-place clean derived data, and two independent clean
  worktree builds — one of `swift`, one of this branch at the same commit) —
  confirmed the pre-existing `QueueScreen.swift:100` compiler crash
  ("failed to produce diagnostic for expression") and the widespread
  `KeyPath`-not-`Sendable` macro-expansion warnings are present identically
  on both `swift` and this branch (unrelated files, not touched by this
  diff — matches the known "Swift build noise" baseline). No new
  concurrency diagnostics attributable to this diff in either configuration.
- `xcodebuild test` (full suite, real settings) — **TEST SUCCEEDED**,
  1141/1141 passed, 0 failed. All 7 auto-download-specific tests in
  `SubscriptionRepositoryTests` pass:
  `testBackfillRefreshDoesNotAutoDownload`,
  `testRefreshAllAutoDownloadsNewEpisodesAcrossPodcasts`,
  `testRefreshAutoDownloadsNewEpisodeEvenWhenAutoQueued`,
  `testRefreshAutoDownloadsNewEpisodes`,
  `testSubscribeAutoDownloadsNMostRecentEpisodes`,
  `testSubscribeAutoDownloadsOnlyNMostRecentWhenFeedHasMore`,
  `testSubscribeWithAutoDownloadCountZeroDoesNotDownload`.

New agents created: none.

No fixes required; no commits made to the branch. Overall: PASS.

## Testing Review — Issue #639

earshot-testing complete. Issue #639 (auto-download of newest episodes does
not work). Branch `fix/issue-639-auto-download`.

New tests written: 3, added to `SubscriptionRepositoryTests.swift` on top of
earshot-data's 6:
- `testRefreshWithAutoDownloadCountZeroDoesNotDownload` — the refresh-path
  off-switch. `refresh(_:)` must still discover a genuinely new episode
  (`newEpisodeIDs.count == 1`) but must not download it when
  `autoDownloadCount == 0`, mirroring the existing subscribe-path coverage
  (`testSubscribeWithAutoDownloadCountZeroDoesNotDownload`), which had no
  equivalent on the refresh side.
- `testRefreshAllWithAutoDownloadCountZeroDoesNotDownload` — same off-switch
  on the whole-library `refreshAll()` path.
- `testRefreshAllOnlyDownloadsForPodcastsWithGenuinelyNewEpisodes` — a true
  partial case across two podcasts refreshed in the same `refreshAll()` pass:
  one podcast's feed is unchanged, the other gains a genuinely new episode.
  Asserts the download fires only for the changed podcast's new episode, not
  for the unchanged podcast's existing episode and not a second time. The
  existing `testRefreshAllAutoDownloadsNewEpisodesAcrossPodcasts` covered two
  podcasts *both* gaining the same new episode (via the shared `FakeFeedFetcher`,
  which returns one feed for every URL) but never the case where only some
  podcasts change — the actual real-world shape of a library refresh. Added a
  new `PerURLFeedFetcher` test double (lock-protected dictionary keyed by feed
  URL) to make this constructible, since `FakeFeedFetcher` can't diverge per
  podcast.

Coverage assessment: earshot-data's 6 tests covered the happy path (refresh
and refreshAll trigger download), the auto-queue/auto-download orthogonality,
and the backfill exclusion (both the download behavior and the
`RefreshOutcome.newEpisodeIDs` field it depends on). The gap was the
`autoDownloadCount == 0` off-switch and true multi-podcast partial refresh —
both now closed. `BackgroundFeedRefresher` (BGTaskScheduler/cold-launch path)
needed no new test per earshot-security's review: it constructs its own
`SubscriptionRepository(downloader:)` and calls `refreshAll()` unchanged, so
it's exercised transitively by the `SubscriptionRepository`-level tests above;
no BGTaskScheduler-specific behavior was touched by this fix.

Test count reconciliation: earshot-data/earshot-security reported a
pre-fix baseline of 1134; earshot-swift6 independently ran the full suite on
this branch (post-fix, pre-my-3-tests) and got **1141/1141 passed**. A clean
full-suite run performed here, after adding the 3 tests above, gives
**Executed 1144 tests, with 1 test skipped and 0 failures** — exactly
1141 + 3, confirming swift6's 1141 is the correct count and reconciling this
gate's baseline against it (the 1134 figure predates commits already on
`swift` that this branch branched from and was undercounted by 7; not a
regression, not investigated further since two independent full-suite runs
now agree exactly). The 1 skip is the pre-existing env-gated
`ScaleDiagnosticTests.test_libraryScaleProfile` (`RUN_SCALE_DIAG=1` required),
unrelated to this branch.

Previous test count (authoritative, full-suite): 1141
New test count (confirmed passing, full-suite): 1144
Count increased: yes

Release build (IS_BETA_BUILD absent): PASS — `xcodebuild -configuration
Release -destination 'generic/platform=iOS' build` → BUILD SUCCEEDED. N/A
per earshot-security (no migration files touched) but run anyway since this
branch changed constructor signatures across several views; confirms no
Release-only compile break.

PRD acceptance criteria covered: #639's fix has two parts, both now covered —
(1) `refresh()`/`refreshAll()` trigger auto-download for genuinely-new
episodes on an already-subscribed podcast (earshot-data's
`testRefreshAutoDownloadsNewEpisodes`,
`testRefreshAllAutoDownloadsNewEpisodesAcrossPodcasts`, plus this gate's
partial-refresh and off-switch tests); (2) the shared `DownloadManager` is
wired into every real call site that constructs `SubscriptionRepository`/
`OPMLImportService` (verified by reading the diff — `AddFeedView`,
`SubscriptionsView`, `SearchView`, `PodcastPreviewView`, `EpisodeListView`,
`DataSettingsView`, `OnboardingView`, `RootView`, `OPMLImportService`,
`OPMLFileImporter` — no test needed beyond the constructor-injection unit
tests already in place, since this is wiring, not logic).

Regressions found: none — full suite is 1144/1144 (1 unrelated pre-existing
env-gated skip), matching or exceeding every prior gate's count on this
branch.

Overall: PASS.

Commit: 3 new tests + this SWIFTUI_PLAN.md update committed to
`fix/issue-639-auto-download`. Branch not merged / not closed — Michael
verifies on device first, per workflow.

## Swift 6 Review — Issue #631

earshot-swift6 review complete. Issue #631 (Earshot Plus: StoreKit 2 product
configuration). Worktree `earshot-worktrees/issue-631`, branch
`feat/issue-631-storekit-config`, commit `6b5ee91`. Required because the new
code uses `async`/`await` (StoreKit 2's `Product.products(for:)`).

Concurrency mode: project.yml has `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (Swift 6 not yet flipped on for this
target — tracked by #390). Reviewed under the project's real settings and
under a forced `SWIFT_STRICT_CONCURRENCY=complete` override to surface
anything the eventual migration would catch.

Checklist:
- [x] Sendable conformance: PASS — `EarshotPlusProduct` (`String,
  CaseIterable, Sendable`), its nested `Kind` enum (`Sendable, Equatable`),
  and `ProductCatalogService.CatalogError` (`Error, Sendable, Equatable`,
  wraps `Set<EarshotPlusProduct>`) are all correctly Sendable.
  `ProductCatalogService` is a stateless `Sendable` struct with no stored
  properties.
- [x] Actor isolation: PASS — `ProductCatalogService.fetch(_:)` and its
  `fetchAll()`/`fetchEarshotPlusProducts()`/`fetchTipProducts()` callers are
  free functions, capture no mutable state, and correctly carry no
  `@MainActor` isolation (pure StoreKit fetch, touches no UI/observable
  state). No isolation is missing anywhere in the diff.
- N/A @Model/SwiftData actor boundary: no SwiftData types in this diff.
- N/A AVAudioSession main actor: no AVAudioSession usage in this diff.
- N/A Combine publishers: none in this diff.
- [x] nonisolated functions: N/A — nothing here is actor-isolated to begin
  with, so there's no unnecessary-hop pattern to fix or add.
- [x] Structured concurrency: PASS — plain `async`/`await` on
  `Product.products(for:)`; no `Task.detached`, no unstructured task
  spawning.
- [x] Global state: PASS — the one new global, `AppLog.monetization`
  (`Logger+Earshot.swift`), is a `static let os.Logger` (Sendable,
  immutable), consistent with every other category in that file.
- [x] Swift 6 build clean (for the new files): PASS — zero errors/warnings
  in `EarshotPlusProduct.swift`, `ProductCatalogService.swift`,
  `EarshotPlusProductTests.swift`, `ProductCatalogServiceTests.swift` under
  both normal Debug settings and `SWIFT_STRICT_CONCURRENCY=complete`.

Build detail:
- Normal build (`xcodebuild build`, default settings, iPhone 17 sim):
  **BUILD SUCCEEDED**, only pre-existing warnings in files this issue never
  touched (`OPMLImportService.swift`, `ChapterParser.swift`,
  `DownloadManager.swift`).
- `SWIFT_STRICT_CONCURRENCY=complete` override: surfaced pre-existing debt
  (KeyPath-Sendable warnings in `QueueRepository.swift` /
  `QuickActionRepository.swift` / `AppSettingsStore` macro expansion, a
  main-actor mutation warning in `AppearanceSettings.swift`, and an unrelated
  compiler crash — "failed to produce diagnostic for expression" — in
  `QueueScreen.swift:100`). Confirmed via `git show --stat HEAD` that none of
  those files are touched by this commit; this is pre-existing migration
  debt (#390), not new debt from #631. Nothing in the diff's own files
  produced any warning under this override.
- Ran the two new test files directly: `EarshotPlusProductTests` (pure
  logic, no StoreKit I/O) — all 9 pass. `ProductCatalogServiceTests`
  (StoreKitTest `SKTestSession`) — compiles and runs with no actor-isolation
  or Sendable violations, but 7/9 fail at runtime with
  `CatalogError.productsNotFound` (StoreKit isn't resolving products from
  the loaded `SKTestSession` in this `xcodebuild test` invocation). This is a
  **functional test issue, not a concurrency issue** — no data races, no
  isolation violations, no crashes; async/await plumbing and error
  propagation both behave exactly as designed. Flagged on the issue for
  earshot-testing to resolve; out of scope for this gate.

New agents created: none.

Overall: PASS.

No fix commit needed — the diff introduced no concurrency debt. Review
posted as a GitHub comment on #631; issue not closed (planning agent closes
after all gates pass).

## Testing Review — Issue #631

earshot-testing gate. Issue #631 (Earshot Plus: StoreKit 2 product
configuration). Worktree `earshot-worktrees/issue-631`, on top of commit
`013c1c6` (domain `6b5ee91` + swift6 docs `013c1c6`).

**New tests written (+2, review follow-up to #631), both in
`ProductCatalogServiceTests.swift`:**
- `testFetchWithDuplicateIDsInInputDeduplicatesAndReturnsUniqueResults` —
  duplicate IDs in the request list must not produce duplicate/conflicting
  dictionary entries.
- `testFetchThrowsProductsNotFoundWhenStoreKitConfigIsMissingAProduct` —
  exercises the `CatalogError.productsNotFound` branch, which none of the
  domain agent's original 9 `ProductCatalogServiceTests` reached (the
  shipped `Configuration.storekit` always resolves all six catalog IDs).
  Added a second fixture, `Earshot/Testing/ConfigurationMissingProduct.storekit`
  (identical to `Configuration.storekit` minus `tip.large`), loaded via a
  dedicated `SKTestSession` inside the test method, and asserts the thrown
  error's payload is exactly `{.tipLarge}`.

**Full suite: 1164 tests total (1144 baseline + 18 from the domain agent's
`EarshotPlusProductTests`/`ProductCatalogServiceTests` + 2 from this gate).
1156 passing, 8 failing, 1 skipped** (the skip is the pre-existing
`RUN_SCALE_DIAG`-gated `ScaleDiagnosticTests`, unrelated to #631). All 1144
baseline tests still pass — **no regressions**.

**The 8 failures are 100% reproducible, not intermittent, and are an
environment limitation, not a code defect:** every `ProductCatalogServiceTests`
case that touches live StoreKit resolution (all except the empty-list
short-circuit) fails with `CatalogError.productsNotFound` for *every*
requested ID, including the two new tests added by this gate. The swift6
gate above already saw the same signature (7/9 failing) and flagged it as
"out of scope, functional not concurrency." This gate tried the prescribed
remediation and went further:
- Erased and rebooted the iPhone 17 / iOS 26.0 simulator, reran — same
  failure, but now silent (zero console diagnostic, `Product.products(for:)`
  just returns empty).
- Switched to a second, previously-untouched iPhone 17 / iOS 26.5 simulator,
  erased fresh, reran — same failure, this time with the underlying error
  surfaced in the console: `[SKTestSession] Error saving configuration
  file: Error Domain=SKInternalErrorDomain Code=3`, plus matching "Error
  clearing overrides" / "Error setting value... for media.payown.earshot" /
  "Error deleting all transactions" — i.e. the local StoreKit test daemon
  cannot persist the test session's configuration in this environment at
  all, for either `.storekit` file.
- Reran with the harness sandbox disabled entirely — identical
  `SKInternalErrorDomain Code=3` errors.
- Added a 3-second `Task.sleep` before the fetch to rule out a
  daemon-not-ready race — identical failure.

Four independent attempts (2 simulator runtimes × erased/fresh, ±sandbox,
±settle delay) all reproduce the identical `SKInternalErrorDomain Code=3`
signature. This is a headless-CI/sandboxed-execution limitation of
`StoreKitTest.framework` in this specific environment, not a defect in
`ProductCatalogService`, `EarshotPlusProduct`, or either `.storekit` config.
The async/await plumbing, error propagation, and catalog logic are otherwise
proven correct: the 11 pure-logic `EarshotPlusProductTests` (no StoreKit I/O)
pass every run, and the failing StoreKit-session tests fail for the *same*
reason regardless of which assertion they contain — consistent with the
fetch layer working exactly as designed and simply never receiving a
response from the local test daemon.

Note for the planning agent: the GitHub issue for #631 currently has exactly
one gate comment (swift6's), reporting 7/9 `ProductCatalogServiceTests`
failing and explicitly punting resolution to this gate. No earshot-security
comment is on the issue. This gate could not resolve the StoreKit-session
failures despite exhausting the documented remediation; real verification of
`ProductCatalogService` against live/test StoreKit will need either Xcode's
GUI-driven test runner (not headless `xcodebuild test`) or a physical
device/TestFlight build with the App Store Connect products configured
(issue #631's own task list — "Create the products and subscription group in
App Store Connect" — is still unchecked).

Release build (`xcodebuild -configuration Release build`, iPhone 17 sim):
**BUILD SUCCEEDED**, 7 pre-existing warnings, none in this issue's files
(`EarshotPlusProduct.swift`, `ProductCatalogService.swift`), matching
swift6's finding.

Regressions found: none. Baseline 1144 tests all still pass.

**Overall: FAIL** — not on baseline count (1144 → 1156 passing, count
increased) and not on Release build (clean), but on the required "count new
tests as reliably passing" bar: 2 new tests plus 6 of the domain agent's
original 9 `ProductCatalogServiceTests` cannot be confirmed passing in this
execution environment. Flagging to the planning agent for a decision:
accept as a known, well-documented environmental gap (StoreKit local testing
needs Xcode GUI or device, not headless CI) and merge on the strength of the
11/11 pure-logic tests + Release build, or hold for a device/Xcode-GUI
verification pass before closing #631.

Files changed by this gate: `EarshotSwift/EarshotTests/ProductCatalogServiceTests.swift`
(+2 tests), `EarshotSwift/Earshot/Testing/ConfigurationMissingProduct.storekit`
(new fixture), `EarshotSwift/Earshot.xcodeproj/project.pbxproj` (xcodegen
regen — adds the new fixture's file reference only, 2-line diff), this
SWIFTUI_PLAN.md entry. No production code changed.

## Security Review — Issue #640

earshot-security review complete. Issue #640 (Select All / Mark All as
Played in episode list). Branch `feat/issue-640-mark-all-played`, HEAD
`7410304` at review time.

Checklist:
- [x] Force-unwraps: PASS — none found. Every `!` in the diff is `!=` or
  boolean negation (`!$0.isPlayed`, `!unplayed.isEmpty`, `!episodes.isEmpty`,
  etc.).
- [x] Silent try?: PASS — none found.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no `Task {}`, `NotificationCenter.addObserver`,
  `Combine.sink`, or `Timer` closures introduced. The `DispatchQueue.main
  .asyncAfter` closure in `EpisodeListView.onMarkPlayed` only touches
  `@State`/`@AccessibilityFocusState` on a `View` struct, no reference-type
  `self` capture.
- [x] @MainActor: PASS — `EpisodeRepository` is `@MainActor final class`.
  `markAllPlayed(in:)` mutates every unplayed episode in memory in one loop
  and calls `context.save()` exactly once, verified by the `onSave` test hook
  against a 1200-episode fixture (`saveCount == 1`). No cross-actor SwiftData
  access, no isolation violations. At 1000+ episodes this is a bounded
  synchronous property-set loop plus one SQLite write; not a main-thread
  blocking concern worth moving off-actor, and doing so would just
  reintroduce cross-actor `@Model` risk.
- [ ] IS_BETA_BUILD Release build: N/A — no migration files changed.
- [ ] Entitlements: N/A — none changed.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new `Error` type needed; the only new `catch`
  (`EpisodeRepository.save()`) wraps SwiftData's built-in `context.save()`
  throw, matching existing repository conventions (e.g. `SubscriptionRepository`).
- [x] AppLog coverage: PASS — `EpisodeRepository.save()`'s catch logs via
  `AppLog.data.error(...)`; no empty catch blocks introduced.

Also verified: all four `project.pbxproj` sections (PBXBuildFile,
PBXFileReference, group children, PBXSourcesBuildPhase) correctly wired for
the three new files. Ran `EpisodeRepositoryTests` +
`MarkAllPlayedAnnouncementTests` on iPhone 17 simulator — 9/9 pass, including
the 1200-unplayed/300-already-played batching assertion and the
inbox-dismissal parity test against the existing single-episode path.

Feature suggestions identified: none this review.

Overall: PASS. No fixes needed, no commit required from this gate.

## Swift 6 Review — Issue #640

earshot-swift6 review complete. Issue #640 (Select All / Mark All as Played
in episode list). Branch `feat/issue-640-mark-all-played`, HEAD `2787421` at
review time.

Concurrency mode: project.yml has `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (Swift 6 migration not yet flipped on for
this target). Reviewed under the project's real committed settings and under
a forced `SWIFT_STRICT_CONCURRENCY=complete` override to surface anything the
eventual migration would catch.

Checklist:
- [x] Sendable conformance: PASS — `EpisodeRepository` is a plain
  `@MainActor final class` (not `Sendable`, correctly so — its stored
  `ModelContext` and `onSave` closure aren't `Sendable` either, but every
  access is actor-isolated so that's fine). Never instantiated or referenced
  from off the main actor.
- [x] Actor isolation: PASS — `markAllPlayed(in:)` mutates every unplayed
  `Episode` `@Model` in memory in a single synchronous loop, then calls
  `context.save()` exactly once, all on the main actor. `EpisodeListView`'s
  new toolbar button, rotor action (`markAllPlayedAccessibilityAction`), and
  `confirmationDialog` closures are all synchronous SwiftUI view-body code —
  no `Task`, no `await`, nothing crosses an isolation boundary.
- [x] @Model/SwiftData actor boundary: PASS — `Podcast`/`Episode` `@Model`
  objects are read and mutated only within `EpisodeRepository`'s
  `@MainActor`-isolated method; none is passed to a background actor,
  `Task.detached`, or any non-main-actor context.
- [x] `onSave` closure isolation: verified. It's declared
  `private let onSave: (() -> Void)?` with no `@Sendable`, deliberately
  mirroring `SubscriptionRepository.onMerge` (same signature, same
  `@MainActor` host class). Since `EpisodeRepository` itself is
  `@MainActor`-isolated and `onSave` is invoked only from `save()` inside
  that same isolation domain — never handed to a background actor or a
  `@Sendable`-requiring API — the closure never needs to cross an isolation
  boundary, so no `@Sendable` annotation is required. This is unlike
  `SubscriptionRepository`'s separate `onProgress` parameter (`@MainActor
  @Sendable`), which exists specifically because *that* closure is invoked
  from a background actor's loop; `onSave` has no equivalent because
  `markAllPlayed` never leaves the main actor. Confirmed by the passing
  strict-concurrency build below (no diagnostic on this parameter).
- N/A AVAudioSession main actor: no audio session code in this diff.
- N/A Combine publishers: none in this diff.
- [x] nonisolated functions: N/A — no pure/computation-only function in this
  diff would benefit from `nonisolated`; `MarkAllPlayedAnnouncement.text
  (count:)` is already a `static func` on a plain non-actor `enum`, not a
  method needing isolation opt-out.
- [x] Structured concurrency: PASS — no `Task`, `Task.detached`, or task
  groups introduced by this diff. `markAllPlayed()` runs synchronously; the
  1200-episode batching test (`EpisodeRepositoryTests`) confirms this is a
  bounded in-memory loop plus one SQLite write, not something that needs
  structured concurrency.
- [x] Global state: PASS — none introduced.
- [x] Swift 6 build clean: PASS. Confirmed no new instance of the project's
  documented pre-existing baseline issues (`QueueScreen.swift:100` compiler
  crash under forced strict-complete, `KeyPath`-not-`Sendable` warnings in
  `QueueRepository.swift`/`QuickActionRepository.swift`, and the
  `DownloadManager.swift:122` non-Sendable-`Episode` warning under the
  project's real minimal setting) — all four appear identically whether or
  not this diff's files are compiled, and none references
  `EpisodeRepository.swift`, `EpisodeListView.swift`, or either new test
  file.

Build/test verification:
- `xcodebuild build` with the project's real settings (`SWIFT_VERSION 5.0`,
  `SWIFT_STRICT_CONCURRENCY minimal`) — BUILD SUCCEEDED, only the
  pre-existing `DownloadManager.swift:122` warning (unrelated file, present
  on `swift` baseline too).
- `xcodebuild build` forced to `SWIFT_STRICT_CONCURRENCY=complete` — BUILD
  FAILED only on the pre-existing `QueueScreen.swift:100` compiler crash and
  the `KeyPath`-not-`Sendable` warnings in `QueueRepository.swift` /
  `QuickActionRepository.swift` (all three previously documented as baseline
  in the #639 Swift 6 review). Zero errors or warnings in
  `EpisodeRepository.swift` or `EpisodeListView.swift` — confirmed by
  grepping the full build log for both filenames: only their `SwiftCompile`
  invocation lines appear, no `error:`/`warning:` lines.
- `xcodebuild test -only-testing:EarshotTests/EpisodeRepositoryTests
  -only-testing:EarshotTests/MarkAllPlayedAnnouncementTests` on iPhone 17
  simulator — TEST SUCCEEDED, 9/9 passed.

New agents created: none.

Overall: PASS. No fixes needed, no commit required beyond this
SWIFTUI_PLAN.md log entry.

---

### earshot-testing gate: Issue #640 (Select All / Mark All as Played in episode list)

Reviewed existing coverage against the issue's 4 acceptance criteria:

1. **Confirmation step before bulk-marking** — `EpisodeListView`'s
   `confirmationDialog` wiring matches the existing Unfollow/Clear-inbox
   precedent exactly (destructive-role button + plain-text Cancel, no icons);
   grepping `EarshotTests/` for `confirmationDialog` returns zero matches
   anywhere in the app, so there is no existing UI-interaction test
   infrastructure for this pattern to match — not inventing one here either,
   per the gate's own guidance. What WAS a real gap: the confirmation
   title/message pluralization and comma-grouping
   (`markAllPlayedConfirmationTitle`/`Message`) were private computed
   properties on the view with zero coverage, unlike the already-extracted,
   already-tested `MarkAllPlayedAnnouncement.text(count:)`. Fixed by
   extracting them into a new pure `MarkAllPlayedConfirmationCopy` enum
   (mirroring the exact pattern the domain agent already established for the
   announcement) and adding 6 tests
   (`MarkAllPlayedConfirmationCopyTests` in
   `MarkAllPlayedAnnouncementTests.swift`): singular/plural and
   comma-grouping for both `title(unplayedCount:)` and
   `message(unplayedCount:podcastTitle:)`. `requestMarkAllPlayed()` itself
   (opens the dialog) and the `.disabled(unplayedCount == 0)` toolbar state
   remain untested view-level wiring, same bar as every other toolbar action
   in this file (e.g. `showingPodcastSettings`).
2. **Batched write** — confirmed real, not vacuous. Read
   `EpisodeRepositoryTests.testMarkAllPlayedBatchesSaveExactlyOnceForLargeList`:
   fixture is 1200 unplayed + 300 already-played episodes, asserts
   `saveCount == 1` via the `onSave` hook (fired only after a real
   `context.save()`, mirroring `SubscriptionRepository.onMerge`), asserts the
   return value equals exactly the unplayed count, and asserts already-played
   episodes' `playedAt` is untouched (guards against overwriting to `.now`).
   Two no-op tests confirm `saveCount == 0` when nothing changes (empty
   podcast, fully-played podcast) so a no-op never dirties the context. A
   fourth test confirms inbox-dismissal parity with the single-episode
   `InboxRepository.markPlayed` path.
3. **VoiceOver announcement wording** — confirmed real.
   `MarkAllPlayedAnnouncementTests` covers singular (1), plural (2), the
   unreachable-in-production zero case, and comma-grouping at both 1,204 and
   1,000,000.
4. **Performant on 1000+ episodes** — same batching test as #2; 1200-episode
   fixture is the direct evidence.

Added 6 tests (`MarkAllPlayedConfirmationCopyTests`) plus the
`MarkAllPlayedConfirmationCopy` enum extraction in
`EpisodeListView.swift` to close the title/message coverage gap identified
above. The 9 tests the domain agents already wrote (4
`EpisodeRepositoryTests` + 5 `MarkAllPlayedAnnouncementTests`) needed no
changes.

Full suite run clean from this worktree (`xcodebuild test -scheme Earshot
-destination 'platform=iOS Simulator,name=iPhone 17'`):

```
Executed 1159 tests, with 1 test skipped and 0 failures (0 unexpected)
Test Suite 'All tests' passed
```

The 1 skip is the pre-existing env-gated `ScaleDiagnosticTests` (`RUN_SCALE_DIAG=1`
required), unrelated to this branch. All three new/changed test suites
(`EpisodeRepositoryTests` 4/4, `MarkAllPlayedAnnouncementTests` 5/5,
`MarkAllPlayedConfirmationCopyTests` 6/6) passed individually in the same run.

Previous test count (authoritative, full-suite; `swift`-branch tip before
this branch started, per the #654 earshot-testing gate above): 1144
New test count (confirmed passing, full-suite): 1159
Reconciliation: 1144 + 9 (domain agents' original tests) + 6 (this gate's
`MarkAllPlayedConfirmationCopyTests`) = 1159. Exact match, no discrepancy.
Count increased: yes

Release build: `xcodebuild build -configuration Release -destination
'generic/platform=iOS Simulator'` → **BUILD SUCCEEDED**, no errors or
warnings in any changed file. N/A per earshot-security/earshot-swift6 (no
migration files touched by this issue) but run anyway as standard practice —
confirms no Release-only compile break from the `EpisodeRepository`/
`EpisodeListView` changes or the `MarkAllPlayedConfirmationCopy` extraction.

PRD acceptance criteria covered: all 4 (confirmation step, VoiceOver
rotor/toolbar entry point, batched write, completion announcement) — see
coverage assessment above.

Regressions found: none — full suite is 1159/1159 (1 unrelated pre-existing
env-gated skip), exceeding the prior gate's count by exactly the expected
delta.

Overall: PASS. Committed the `MarkAllPlayedConfirmationCopy` extraction and
its 6 tests to this branch (`feat/issue-640-mark-all-played`).

## Security Review — Issue #634

earshot-security review complete. Issue #634 (Earshot Plus: on-device
StoreKit 2 receipt validation). Branch `feat/issue-634-receipt-validation`,
commit `3fa62af` on top of `swift` tip `b01974f`, reviewed in worktree
`earshot-wt-634`.

Checklist:
- [x] Force-unwraps: PASS — none found in any changed file. Every `!` match
  is boolean negation (`!isRunningTests`, `!store.isEntitled`), not a
  force-unwrap.
- [x] Silent try?: PASS — none in the 5 new production Monetization files.
  The 2 `try?` in `AppSettingsStore.swift` are pre-existing (this diff only
  appended 9 lines of new `SettingsKey` constants), out of scope. The 2
  `try?` in `EntitlementStoreTests.swift` match the existing
  `ScaleDiagnosticTests.swift` test-only pattern against a fresh in-memory
  context.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — `EntitlementStore.startObservingTransactionUpdates()`
  uses `Task { [weak self] in ... guard let self else { return } ... }`, and
  captures a local `source` (not `self`) for the `AsyncStream`.
- [x] @MainActor: PASS — `EntitlementStore` is `@MainActor @Observable`;
  `isEntitled`/`settings` mutation is fully main-actor-serialized, including
  across the `resync()` await gap. `startObservingTransactionUpdates()`
  double-call safety verified by `testCallingStartObservingTwiceDoesNotCrashOrDoubleStart`.
- [ ] IS_BETA_BUILD Release build: N/A — no migration/schema files changed
  (entitlement state is 2 plain `AppSetting` rows, no `@Model`/schema bump).
- [ ] Entitlements: N/A — `Earshot.entitlements`/App Group settings untouched;
  `project.pbxproj` diff is the expected xcodegen wiring for 8 new files.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — deny states are `nil` returns + `AppLog.monetization`
  logging (the module's explicit "ambiguous -> deny, never throw" design), no
  typed `Error` needed.
- [x] AppLog coverage: PASS — both deny branches in
  `EntitlementFactMapper.fact(from:)` log via `AppLog.monetization.error`
  before returning nil.

Core receipt-validation correctness, verified directly against source:
1. Verified-only gate: `EntitlementFactMapper.fact(from:)` has no branch
   producing a fact from `.unverified` — confirmed by
   `EntitlementFactMapperTests`.
2. No product-ID bypass: the only ID→product path is
   `EarshotPlusProduct(rawValue:)`; unrecognized IDs deny and log.
   `EntitlementEngine.grantsEntitlement` re-checks
   `earshotPlusProducts.contains(fact.product)` as a second gate, so tip-jar
   facts are denied even if one reached the engine.
3. Revocation/expiration: both checked independently
   (`revocationDate == nil` AND `expirationDate` not `<= now`); boundary case
   (expiration exactly now) denies, not grants
   (`testExpirationExactlyNowDoesNotGrantEntitlement`).
4. `transaction.finish()` scoped correctly: only called after the mapper
   produces a fact AND it's one of the 3 Plus products (non-tip, verified,
   recognized). Unfinished tip/unverified/unrecognized transactions can't
   cause duplicate-entitlement or resource exhaustion because
   `EntitlementEngine` denies non-qualifying facts on every redelivery and
   `resync()` is an idempotent full recomputation each call.
5. No test-only backdoors: no `#if DEBUG` entitlement grants, no
   hardcoded-ID special-casing in `StoreKitEntitlementSource`;
   `FakeEntitlementTransactionSource` lives only in the test target, behind
   the `EntitlementTransactionSource` protocol, never reachable from
   `EarshotApp.swift` (which constructs the real `StoreKitEntitlementSource`).

No server-side/third-party receipt validation anywhere: confirmed —
`StoreKitEntitlementSource` is the only file importing `StoreKit`, calling
only local on-device `Transaction.currentEntitlements`/`Transaction.updates`.
No network calls, no backend endpoint, no third-party SDK in the diff.

Test suite: ran the full pinned-simulator suite
(`platform=iOS Simulator,id=C7CE2A99-3D54-42BB-8D59-97F7F5A00362`) as a
confirmation pass. Result: 1211 executed, 1 skipped, 0 failures — matches the
domain agent's stated baseline exactly. No fixes were needed, so no
additional commit was made on this branch.

Feature suggestions identified: none this review.

Overall: PASS.

## Swift 6 Review — Issue #634 (earshot-swift6)

earshot-swift6 review complete. Issue #634 (Earshot Plus: on-device StoreKit 2
receipt validation). Worktree `earshot-wt-634`, branch
`feat/issue-634-receipt-validation`, commit `c88ceae`. Required because the
diff introduces an async `Transaction.updates` listener task and
actor-isolated entitlement state.

Concurrency mode: project.yml has `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (Swift 6 not yet flipped on for this
target — tracked by #390). Reviewed under the project's real committed
settings and under a forced `SWIFT_STRICT_CONCURRENCY=complete` override to
surface anything the eventual migration would catch.

Checklist:
- [x] Sendable conformance: PASS. `EntitlementFact` (`Sendable, Equatable`,
  all-value-type stored properties: `EarshotPlusProduct` (itself `String,
  CaseIterable, Sendable`), two `Date?`), `RawTransactionResult` (`Sendable,
  Equatable` enum, associated values all value types), `EntitlementEngine`
  and `EntitlementFactMapper` (stateless case-less enums, trivially
  Sendable) are all correctly usable off the main actor / in plain unit
  tests with no StoreKit involved. `EntitlementTransactionSource` is
  declared `Sendable`; `StoreKitEntitlementSource` (a `struct` with zero
  stored properties) satisfies it for real, not via `@unchecked`.
- [x] Actor isolation: PASS. `EntitlementStore` is `@MainActor @Observable
  final class` with no escape hatches (no `nonisolated`, no
  `nonisolated(unsafe)`, no `@unchecked Sendable` in production code). Every
  stored property (`isEntitled`, `lastSyncedAt`, `settings`, `source`,
  `listenerTask`) is mutated only from methods on this MainActor-isolated
  type. `resync()`'s suspension point (`await source.currentFacts()`)
  resumes back on the main actor automatically because the enclosing method
  is MainActor-isolated — `apply(entitled:)` runs on the main actor both
  before and after the await, confirmed by zero diagnostics under forced
  `SWIFT_STRICT_CONCURRENCY=complete`.
- [x] `listenerTask` double-start guard: PASS, race-free. `guard
  listenerTask == nil else { return }` and the subsequent `listenerTask =
  Task { ... }` assignment are both synchronous, with no `await` between
  them, inside a synchronous (non-`async`) MainActor method. Actor-isolated
  synchronous code cannot be preempted mid-execution by a second call to the
  same method — two calls from `EarshotApp.swift`'s `.task` (even a
  hypothetical re-run) execute this method to completion one at a time on
  the main actor, so there is no reentrancy window. Covered by
  `testCallingStartObservingTwiceDoesNotCrashOrDoubleStart`.
- [x] `EntitlementTransactionSource: Sendable` / `StoreKitEntitlementSource`
  Sendability: PASS (see above). `updateSignals()`'s `AsyncStream<Void>`
  construction is correct: the build closure runs synchronously inside
  `AsyncStream.init`, so the internal `Task { for await result in
  Transaction.updates { ... } }` is created with the *static* isolation of
  `updateSignals()` itself (a plain nonisolated struct method) — not the
  caller's actor — so this listener loop correctly runs off the main actor,
  appropriate for a pure StoreKit-listening/processing loop that touches no
  UI state. `continuation.yield(())` and `continuation.onTermination = { _
  in task.cancel() }` are both safe: `AsyncStream.Continuation` is designed
  to be called from any concurrent context, and `task.cancel()` is captured
  by value (`Task` is `Sendable`). Cancellation propagates correctly:
  `EntitlementStore.stopObservingTransactionUpdates()` cancels
  `listenerTask`, which cancels its `for await` loop over
  `source.updateSignals()`, whose consumer-side cancellation tears down the
  `AsyncStream` and fires `onTermination`, cancelling the inner
  `Transaction.updates` task.
- [x] `[weak self]` capture in the listener `Task`: PASS. Inside
  `startObservingTransactionUpdates()`'s `Task { [weak self] in for await _
  in source.updateSignals() { guard let self else { return }; await
  self.resync() } }`, the `Task{}` itself inherits `@MainActor` isolation
  from its enclosing (MainActor) method, so every loop iteration resumes on
  the main actor. `guard let self else { return }` synchronously produces a
  strongly-retained local binding on the main actor before the `await
  self.resync()` call, so there is no window where a weakly-captured,
  possibly-deallocated `self` is read racily — the strong reference is held
  for the full synchronous span leading into the isolated `resync()` call.
- [x] `Transaction`/`VerificationResult` Sendability: PASS. Confirmed
  empirically, not just by assumption — the forced
  `SWIFT_STRICT_CONCURRENCY=complete` build produced zero diagnostics
  anywhere in `EntitlementTransactionSource.swift`, meaning the compiler
  accepted `VerificationResult<Transaction>` crossing into
  `Self.processUpdate(result)` (an `async` static function) and `Transaction`
  crossing into `await transaction.finish()` under full strict checking, not
  merely under today's `minimal` setting.
- [x] `EntitlementFact`/`EntitlementEngine`/`EntitlementFactMapper`/
  `RawTransactionResult` Sendable: PASS (see Sendable conformance above) —
  all four are usable synchronously from any context, confirmed by
  `EntitlementEngineTests` and `EntitlementFactMapperTests` calling them with
  no actor annotation and no async required.
- [x] Structured concurrency: PASS. No `Task.detached` anywhere in the diff.
  Both `Task{}` usages (`EntitlementStore.startObservingTransactionUpdates()`
  and `StoreKitEntitlementSource.updateSignals()`) are plain `Task{}`,
  correctly long-running-but-cancellable via `stopObservingTransactionUpdates()`
  / `AsyncStream.Continuation.onTermination`, not orphaned.
- [x] Global state: PASS. None introduced; `EntitlementStore` is
  instance-owned (`@State private var entitlements = EntitlementStore()` in
  `EarshotApp.swift`), no new `static var`.
- [x] Swift 6 build clean (for the new/changed files): PASS. Zero errors or
  warnings anywhere in the six Monetization files or three test files under
  both the project's real settings and forced
  `SWIFT_STRICT_CONCURRENCY=complete`.

Build detail:
- Normal build (`xcodebuild build`, default settings, pinned iPhone 17 sim):
  **BUILD SUCCEEDED**, zero warnings anywhere in the log (the one line
  matching "warning:" is an unrelated `appintentsmetadataprocessor` Info
  line, not a compiler diagnostic).
- `SWIFT_STRICT_CONCURRENCY=complete` override: **BUILD FAILED**, but only on
  the three previously-documented pre-existing baseline issues (identical to
  the #639/#631/#640 gate reports): `QueueRepository.swift:345` `KeyPath`-not-
  `Sendable` warning, `QueueScreen.swift:100` compiler-internal "failed to
  produce diagnostic" crash, `QuickActionRepository.swift:64` `KeyPath`-not-
  `Sendable` warning. Grepped the full log for "Monetization" and
  "Entitlement" in both error and warning lines — zero matches. None of this
  issue's files are touched by any of the three baseline diagnostics.

Precision on the Swift-6-strict-concurrency-clean question (relevant to
#390): this diff's own files are genuinely Swift-6-strict-concurrency-clean
today, not merely "compiles fine under minimal mode" — verified by actually
building them under `SWIFT_STRICT_CONCURRENCY=complete`, not by inspection
alone. The *project* as a whole is still not strict-concurrency-clean (the
three baseline diagnostics above, tracked by #390), but nothing in this
issue adds to that debt.

Test verification: no fixes were needed, so no additional commit. Ran the
full pinned-simulator suite once as confirmation:
`xcodebuild test -project Earshot.xcodeproj -scheme Earshot -destination
'platform=iOS Simulator,id=C7CE2A99-3D54-42BB-8D59-97F7F5A00362'` — **1211
executed, 1 skipped, 0 failures**, matching the stated baseline exactly,
including all 24 new `EntitlementEngineTests`/`EntitlementFactMapperTests`/
`EntitlementStoreTests` cases (the async
`testStartObservingTransactionUpdatesResyncsOnEachSignal` listener-wiring
test passed, not flaky).

New agents created: none.

Overall: PASS.

## Testing Gate — Issue #634 (earshot-testing)

earshot-testing gate complete. Issue #634 (Earshot Plus: on-device StoreKit 2
receipt validation). Worktree `earshot-wt-634`, branch
`feat/issue-634-receipt-validation`, starting commit `8f88c84` (domain agent +
earshot-security PASS + earshot-swift6 PASS, both zero-code-change reviews).

**Coverage assessment against the issue's 4 acceptance criteria + the
ambiguous-state requirement**, tracing each to specific existing tests (per
the #640 gate's approach):

1. Entitlement check on app launch + `Transaction.updates` listener observed:
   `EarshotApp.swift`'s launch `.task` calls `configure(context:)` ->
   `startObservingTransactionUpdates()` -> `await resync()`, guarded by the
   same `isRunningTests` pattern already used for
   `BackgroundFeedRefresher`/`NotificationService` — not unit-tested at the
   App level, matching that established precedent. Each piece is covered at
   the component level: `testConfigureLoadsPersistedEntitledFlagWithNoAsyncWork`
   / `testConfigureDefaultsToNotEntitledWhenNeverPersisted` (configure),
   `testResyncWithAQualifyingFactGrantsEntitlement` (resync),
   `testStartObservingTransactionUpdatesResyncsOnEachSignal` +
   `testCallingStartObservingTwiceDoesNotCrashOrDoubleStart` (listener).
2. `.verified` grants, `.unverified` denies, logged not silent:
   `testVerifiedKnownProductProducesAFact` /
   `testVerifiedKnownProductCarriesRevocationAndExpirationThrough` vs.
   `testUnverifiedTransactionProducesNoFact`. Both deny branches in
   `EntitlementFactMapper.fact(from:)` log via `AppLog.monetization.error`
   before returning nil (confirmed by direct source read and observed in the
   test log output, e.g. "[monetization] Unverified transaction for
   media.payown.earshot.plus.lifetime: signature validation failed; not
   granting entitlement") — this codebase has no log-capture test double
   anywhere (`AppLog` is a plain `os.Logger` factory), so, consistent with
   every other gate's practice here, log presence is verified by inspection
   rather than an assertion on logger output.
3. Persisted state readable synchronously without hitting StoreKit:
   `testConfigureLoadsPersistedEntitledFlagWithNoAsyncWork` — `isEntitled` is
   read immediately after the non-async `configure(context:)`, no `resync()`
   involved.
4. Revoked/refunded transactions downgrade entitlement gracefully, without
   deleting user data: `testRevokedTransactionDowngradesEntitlementOnResync`,
   `testExpiredSubscriptionDowngradesEntitlementOnResync`, and the explicit
   regression guard `testResyncDoesNotDeleteAnyUserDataOnRevocation` (inserts
   a real `Podcast`, revokes entitlement, asserts it survives).
5. Ambiguous states deny, not grant: unrecognized product ID —
   `testVerifiedButUnrecognizedProductIDProducesNoFact`; expiration boundary
   — `testExpirationExactlyNowDoesNotGrantEntitlement` (`expirationDate ==
   now` denies, not just `< now`).

All 4 criteria plus the ambiguous-state requirement were already directly
traceable to a specific passing test before this gate touched anything —
confirms the security and swift6 gates' shared assessment that this issue
needed no code changes.

**Coverage gap found and closed.** `EntitlementStore.apply(entitled:)`
persists via `settings?.setBool(...)` / `settings?.setDate(...)` — optional
chaining against `settings: AppSettingsStore?`, which is `nil` until
`configure(context:)` runs. In the real launch sequence `configure()` always
precedes `resync()`, but nothing in `EntitlementStore` itself enforces that
ordering as a precondition, and no existing test exercised calling
`resync()` first. That's exactly the kind of edge case in the stateful type
itself (as opposed to the already-well-covered pure `EntitlementEngine`/
`EntitlementFactMapper` logic) this gate's mandate calls out. Added 4 tests
to `EntitlementStoreTests.swift` (no production code changes needed — the
optional-chaining behavior was already correct, just unasserted):

- `testConfigureLoadsPersistedLastSyncedAt` — `configure(context:)` restores
  `lastSyncedAt` from a persisted row on its own, without requiring a fresh
  `resync()` (previously only `isEntitled` was asserted after a
  configure-only call).
- `testConfigureLeavesLastSyncedAtNilWhenNeverPersisted` — companion nil case.
- `testResyncBeforeConfigureUpdatesInMemoryStateWithoutCrashing` — calling
  `resync()` before `configure()` does not crash and still updates
  `isEntitled`/`lastSyncedAt` in memory from the freshly computed result.
- `testResyncBeforeConfigureDoesNotPersistToAppSettingsStore` — companion
  assertion that the optional-chained persistence calls are true no-ops in
  that ordering (a later `AppSettingsStore` read against the same context
  finds nothing written), not a silent partial write.

No production files changed; no extraction was warranted — `EntitlementEngine`
and `EntitlementFactMapper` are already pure, already isolated into their own
files, and already have direct fixture-based tests for every branch (see the
per-criterion trace above), so there was no incidentally-covered pure logic
left to pull out.

**Full suite.** Baseline confirmed first: `xcodebuild test` on the pinned
simulator (`id=C7CE2A99-3D54-42BB-8D59-97F7F5A00362`) reproduced exactly
**1211 executed, 1 skipped, 0 failures** before any test additions. After
adding the 4 tests above: **1215 executed, 1 skipped (env-gated
`ScaleDiagnosticTests`, unchanged), 0 failures**. Ran the full suite twice
(once pre-change to confirm baseline, once post-change) plus a
`-only-testing` pass scoped to the three Monetization test files
(30 executed, 0 failures) to iterate quickly while writing the new tests.

**Release build.** `xcodebuild build -configuration Release -destination
'generic/platform=iOS Simulator'`: **BUILD SUCCEEDED**. Grepped the log for
"warning:" lines touching "Entitlement"/"Monetization" — zero matches, no new
warnings in any changed file. (This issue touches no migration/schema files —
2 plain `AppSetting` rows, no `@Model` — so the IS_BETA_BUILD migration-sheet
gate scenario doesn't apply here; ran the plain Release build per this gate's
standing instructions regardless.)

**Regressions found:** none.

Committed the 4 new tests plus this log entry in a single commit on
`feat/issue-634-receipt-validation` (test-only change, no production code
touched). Did not push, did not open a PR.

```
earshot-testing complete. Issue #634.

New tests written: 4
Previous test count: 1211 executed, 1 skipped, 0 failures
New test count: 1215 executed, 1 skipped, 0 failures
Count increased: yes

Release build (IS_BETA_BUILD absent): PASS (plain Release build; no
migration/schema files touched by this issue)
PRD acceptance criteria covered: 1 (launch check + Transaction.updates
listener), 2 (.verified grants / .unverified denies, logged), 3 (persisted
state readable synchronously), 4 (revoked/refunded downgrades gracefully,
no data deleted) — plus the ambiguous-state requirement (unrecognized
product ID, expiration boundary both deny)

Regressions found: none

Overall: PASS
```

## Security Review — Issue #633

earshot-security review complete. Issue #633 (Earshot Plus: restore
purchases flow). Branch `feat/issue-633-restore-purchases`, commit
`b68a65e` on top of `swift` tip `76c551b`, reviewed in worktree
`earshot-wt-633`. Files reviewed: `EntitlementTransactionSource.swift`,
`EntitlementStore.swift`, `SettingsScreen.swift`,
`EntitlementStoreTests.swift`, `RestorePurchasesTests.swift`,
`project.pbxproj`.

Checklist:
- [x] Force-unwraps: PASS — none. Every `!` match is boolean negation
  (`!wasEntitled`, `!isRestoring`).
- [x] Silent try?: PASS — none introduced by this diff. The 2 `try?` in
  `EntitlementStoreTests.swift` (lines 150, 160) are pre-existing, untouched
  by this commit.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — the new `Task { }` in `RestorePurchasesRow.restore()`
  lives inside a `View` struct (value type), no `self`-retention risk.
  `EntitlementStore.restorePurchases()` is a plain async method, not a
  closure capturing `self`.
- [x] @MainActor: PASS — `EntitlementStore` is `@MainActor @Observable`;
  `restorePurchases()`/`resync()` are fully main-actor-serialized.
  `RestorePurchasesRow` is main-actor-inferred via `View` conformance, so
  `isRestoring` and the `Task` body are isolated too. Non-blocking note:
  `restorePurchases()` reads `wasEntitled` before `await source.sync()`; if
  the background `Transaction.updates` listener's `resync()` interleaves
  during that suspension, the `.restored`/`.noChange` *announcement* can be
  stale in a narrow window. Persisted state is never wrong (`resync()`
  always recomputes from the true snapshot) — flagged as a minor UX note,
  not blocking.
- [ ] IS_BETA_BUILD Release build: N/A — no migration/schema files changed.
- [ ] Entitlements: N/A — `Earshot.entitlements`/App Group settings
  untouched; `project.pbxproj` diff is only xcodegen wiring for the new
  `RestorePurchasesTests.swift` file.
- [x] No secrets: PASS.
- [x] Error types: PASS — `RestoreOutcome` is a typed enum (`.restored` /
  `.noChange` / `.failed(String)`).
- [x] AppLog coverage: PASS — `restorePurchases()`'s `catch` logs via
  `AppLog.monetization.error` before returning `.failed`; the UI layer logs
  again (redundant, harmless) before announcing a generic, non-sensitive
  VoiceOver message.

Specifically verified: `restorePurchases()` returns `.failed` inside the
`catch`, before ever calling `resync()`, so a failed history refresh is
never treated as "confirmed no purchases" — confirmed by
`testRestoreWhenSyncThrowsNeverCallsResyncEvenWithAQualifyingFactAvailable`
and `testRestoreWhenAlreadyEntitledAndSyncThrowsReportsFailedNotNoChange`,
both passing. `.failed(String)` carries `error.localizedDescription`, only
ever logged, never surfaced verbatim to VoiceOver (the UI announces a fixed
generic string) — no sensitive-text leak.

Build/test verification (simulator `CBBB2872-D6EA-40F5-AF56-0FDC5E59BAEB`):
Debug build **BUILD SUCCEEDED**; `RestorePurchasesTests` +
`EntitlementStoreTests` — 24/24 passed, 0 failures.

No code changes made. No new feature suggestions this review.

Overall: PASS

## Testing Gate — Issue #633

earshot-testing gate complete. Issue #633 (Earshot Plus: restore purchases
flow). Branch `feat/issue-633-restore-purchases`, HEAD `4489e2a` (4 commits
on `swift` tip `76c551b`), reviewed in worktree `earshot-wt-633` on
simulator `CBBB2872-D6EA-40F5-AF56-0FDC5E59BAEB`.

**Test coverage spot-check.** Read `RestorePurchasesTests.swift` (10 tests)
against #633's required outcome matrix: lifetime restore, monthly-subscription
restore, yearly-subscription restore (both subscription products, not just
one), the two distinct "nothing to restore" shapes (already-entitled from
lifetime, already-entitled from subscription, and genuinely-never-entitled —
three separate tests, all mapping to `.noChange`), the sync-throws-so-resync-
never-runs failure path (two dedicated regression tests, one of which
pre-loads a qualifying fact specifically to prove the early return is real,
not structurally implied), an already-entitled-and-sync-throws case
(`.failed`, not `.noChange`), and cross-instance persistence. This is
complete coverage of the matrix — no gap found, no additional tests written.
`RestorePurchasesRow`'s "offered inline in the paywall" sub-task from the
issue body is out of scope for this PR: no paywall view exists yet in this
codebase (`grep -ril paywall` finds only forward-references marked #632,
which is unbuilt), so there's nothing to test there — not a coverage gap in
this PR's actual diff.

**Full suite.** `xcodebuild test` on the pinned simulator:
**1225 executed, 1 skipped (env-gated `ScaleDiagnosticTests`, unchanged),
8 failures**, all in `ProductCatalogServiceTests`. Matches the domain agent's
reported 1215 → 1225 (10 new `RestorePurchasesTests`, all passing).

**Independent regression check on the 8 `ProductCatalogServiceTests`
failures** (not just trusting the implementer's report): this PR's diff
(`git diff --stat 76c551b..4489e2a`) touches only
`EntitlementStore.swift`, `EntitlementTransactionSource.swift`,
`SettingsScreen.swift`, `EntitlementStoreTests.swift`,
`RestorePurchasesTests.swift`, and `project.pbxproj` (xcodegen wiring) —
nowhere near `ProductCatalogService.swift`, `Configuration.storekit`, or
`ProductCatalogServiceTests.swift`. To confirm rather than assume, built a
throwaway worktree at `origin/swift` tip `76c551b` (this branch's unmodified
base) and ran `-only-testing:EarshotTests/ProductCatalogServiceTests` there
directly: **identical 8/9 failures**, identical root cause in the log
(`[SKTestSession] Error saving configuration file: Error Domain=
SKInternalErrorDomain Code=3`) — a local StoreKitTest/simulator
infrastructure fault loading `SKTestSession` from the `.storekit` config
file by URL, not a product-ID mismatch caused by any code change. This also
matches this exact failure signature already logged against issue #631 in
this file (`ProductCatalogServiceTests` needs an Xcode-GUI test run or a
device, not headless `xcodebuild test`, to load StoreKit test sessions
reliably) — a known, pre-existing, well-documented environmental gap, not a
regression introduced by #633. Worktree removed after the check.

**Release build.** `xcodebuild -configuration Release -destination
'platform=iOS Simulator,id=CBBB2872-D6EA-40F5-AF56-0FDC5E59BAEB' build`:
**BUILD SUCCEEDED**. This issue touches no migration/schema files, so the
IS_BETA_BUILD gate doesn't apply — ran the plain Release build per standing
instructions regardless.

**Regressions found:** none. No new tests written (coverage was already
complete). No commits made to the branch.

```
earshot-testing complete. Issue #633.

New tests written: 0 (existing 10 RestorePurchasesTests already cover the
full outcome matrix — spot-checked against the issue body, no gap found)
Previous test count: 1215 executed, 1 skipped
New test count: 1225 executed, 1 skipped, 8 failures (all pre-existing
ProductCatalogServiceTests StoreKitTest-simulator failures, independently
reproduced on unmodified origin/swift tip 76c551b — not a regression)
Count increased: yes

Release build (IS_BETA_BUILD absent): PASS
PRD acceptance criteria covered: lifetime restore, subscription restore
(monthly + yearly), already-entitled no-change (both product shapes),
never-entitled no-change, sync-throws failure path (including the
never-falls-through-to-resync regression test), cross-instance persistence

Regressions found: none

Overall: PASS
```

## Security Review — Issue #635

earshot-security review complete. Issue #635 (Earshot Plus: enforce
10-podcast free tier cap). Branch `feat/issue-635-podcast-cap`, reviewed at
commit `cfc9b9b` on top of `swift` tip `76c551b`, in isolated worktree
`earshot-wt-635`. One fix applied at commit `31d1cbf`.

Checklist:
- [x] Force-unwraps: PASS — none found. Every `!` in the diff is boolean
  negation (`!isEntitled`, `!feedURLs.isEmpty`, etc.).
- [x] Silent try?: PASS after fix — the three new cap-enforcement
  `try? context.fetch...` calls in `SubscriptionRepository.swift`
  (`subscribe`, `subscribeAll`, `autoDownloadRecent`) fell back to `0`/`[]`
  on a fetch failure with no logging. Because these gate an
  entitlement-bypass check, a silent fallback is fail-open (a rare local
  SwiftData read error would silently under-enforce the cap). Extracted into
  `currentPodcastCountForCapCheck()`/`allPodcastsForCapCheck()` private
  helpers that `do`/`catch` and log via `AppLog.subscriptions.error`, same
  fallback value, now observable. Pre-existing `try?` fetch patterns
  elsewhere in the file (podcast/episode lookups, `mergeBackgroundWrites`)
  are untouched — genuinely benign "not found" cases, matching established
  codebase convention.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new `Task {}`, `.sink`, `addObserver`, or
  `Timer` closures; every `Task {}` in the diff is a pre-existing context
  line.
- [x] @MainActor: PASS — all new/changed code lives on already
  `@MainActor`-isolated types (`SubscriptionRepository`,
  `OPMLImportService`, `AppSettingsStore`, SwiftUI views); no SwiftData
  access from a background `Task`.
- [ ] IS_BETA_BUILD Release build: N/A — no migration-sheet code in this
  diff; ran the Release build anyway as a general gate — BUILD SUCCEEDED.
- [ ] Entitlements: N/A — `Earshot.entitlements`/`project.yml` entitlement
  settings untouched.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — new `SubscriptionError.podcastCapReached(currentCount:limit:)`
  is a typed enum case with `LocalizedError` conformance; no string-thrown
  errors.
- [x] AppLog coverage: PASS after fix — see try? item above.

Issue-specific checks:
1. No data destruction on lapse: PASS. No `.delete(` or other destructive
   call anywhere in the diff. `readOnlyPodcastIDs` (both the
   `PodcastCapPolicy` pure function and `SubscriptionsView`'s wrapper) is
   computed live off current entitlement + podcast list, never persisted,
   never deletes. `autoDownloadRecent` only skips downloading for read-only
   podcasts. Confirmed by
   `PodcastCapPolicyTests.testReadOnlyPodcastIDsRecomputesLiveWhenEntitlementIsRestored`.
2. Cap can't be trivially bypassed: PASS. Grepped every production
   (non-test) call site of `SubscriptionRepository(...isEntitled:)`,
   `OPMLImportService(...isEntitled:)`, and
   `OPMLFileImporter.importFile(...isEntitled:)` myself — all 9 UI call
   sites pass `entitlements.isEntitled` sourced from a real
   `@Environment(EntitlementStore.self)`, never a literal or user-settable
   value. `EntitlementStore.isEntitled` is `private(set)`, synced by
   `resync()` from `EntitlementEngine.isEntitled(from:)` reading real
   `Transaction.currentEntitlements` (#634). The one non-UI call site left
   at the `nil` default (`BackgroundFeedRefresher.runRefresh`) only calls
   `refreshAll()`, never a subscribe path — correct to leave unenforced.
3. Grandfathering snapshot integrity: PASS.
   `introducePodcastCapGatingIfNeeded` guards on
   `!podcastCapGatingIntroduced()` before either write, and the two writes
   can't be reordered to re-arm the guard. Verified by
   `AppSettingsStoreTests.testIntroducePodcastCapGatingIfNeededIsNoOpOnSecondCall`.
4. No secrets/entitlement receipts logged: PASS. No `AppLog` call in this
   diff (including my follow-up fix) logs entitlement/receipt payloads —
   only counts, booleans, feed URLs, and error descriptions.

Build + test verification (ran myself on simulator
`F868F72E-091C-47D9-B003-1AE0670E5455`):
- Debug build: BUILD SUCCEEDED (before and after my fix).
- Release build: BUILD SUCCEEDED, no new warnings (one pre-existing
  unrelated warning at `OPMLImportService.swift:99` predates this PR).
- Full test suite: 1244 tests, 8 failures — all 8 are the documented
  `ProductCatalogServiceTests` StoreKit-sandbox `SKInternalErrorDomain
  Code=3` failures (out of scope per the Testing Review — Issue #631
  section above). Zero failures in `PodcastCapPolicyTests` (14),
  `SubscriptionRepositoryTests` (47), `OPMLBulkImportTests` (11), and
  `AppSettingsStoreTests` (18). Re-ran the full suite after the fix:
  identical result, no regressions.

Environment note (not a code issue): the `earshot-wt-635` worktree had no
`.dart_tool` (never had `flutter pub get` run in it), so the repo's
`pre-commit` hook (`dart format --set-exit-if-changed lib/ test/`) couldn't
resolve `very_good_analysis` from `analysis_options.yaml` and reformatted
~66 unrelated Flutter files with default formatter settings as a side
effect of committing the Swift-only fix above. Those Dart changes were
deliberately left unstaged/uncommitted (not part of commit `31d1cbf`), but
still sit as local working-tree noise in this worktree. Recommend running
`flutter pub get` in this worktree (or discarding those files) before any
further work there.

New agents created: none.
Feature suggestions identified: none this review.

Overall: PASS

## Swift 6 Review — Issue #635

earshot-swift6 review complete. Issue #635 (Earshot Plus: enforce
10-podcast free tier cap). Branch `feat/issue-635-podcast-cap`, reviewed at
HEAD `72a7cf9` (domain `cfc9b9b` + security fix `31d1cbf` + docs `72a7cf9`)
in isolated worktree `earshot-wt-635`. No fix required.

Concurrency mode: real project settings — `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (confirmed by reading `project.yml`
myself, not assumed).

Checklist:
- [x] Sendable conformance: PASS — `PodcastCapPolicy` is a plain, non-actor
  enum that takes `[Podcast]` (`@Model`, not `Sendable`) and primitives, and
  returns `Set<PersistentIdentifier>`/`Bool`/`Int`. It is called
  synchronously, only from already-`@MainActor` call sites
  (`SubscriptionRepository`, `OPMLFileImporter`, `SubscriptionsView`) —
  grepped every call site to confirm. It never crosses an actor boundary and
  is never called from `FeedRefreshActor`, so the non-`Sendable` `Podcast`
  argument never needs to be `Sendable`; the enum correctly does not need
  `@MainActor` or `Sendable` annotations itself. `SubscriptionRepository`'s
  new `isEntitled: Bool?` stored property and `BulkSubscribeResult`/
  `BulkSubscribeOutcome` structs are all-value-type and trivially `Sendable`.
  `SubscriptionError.podcastCapReached(currentCount:limit:)` carries only
  `Int`s.
- [x] Actor isolation: PASS — all new/changed cap-check code
  (`currentPodcastCountForCapCheck()`, `allPodcastsForCapCheck()`, the cap
  gate in `subscribe()`/`subscribeAll()`, `AppSettingsStore` calls) runs on
  `SubscriptionRepository`'s `@MainActor` isolation, confirmed by reading the
  class declaration (`@MainActor final class SubscriptionRepository`) and
  every call site. The cap check in `subscribe(feedURL:)` (lines ~125-134)
  runs and can throw BEFORE `FeedRefreshActor(modelContainer:)` is
  constructed — verified from the actual code, not assumed from the issue
  description — so a capped-out user's request never even hands off to the
  background actor. Same ordering in `subscribeAll()`: `feedURLs` is trimmed
  by the cap on the main actor before the single `FeedRefreshActor.subscribeAll`
  call. `RootView`'s new one-time grandfathering snapshot
  (`capSettings.introducePodcastCapGatingIfNeeded`) runs inside the existing
  `@MainActor` launch `.task`, using `AppSettingsStore` (`@MainActor`) and a
  synchronous `modelContext.fetchCount` — no isolation violation. All 9 new
  `@Environment(EntitlementStore.self)` UI call sites (`RootView`,
  `OnboardingView`, `PodcastPreviewView`, `SearchView`, `DataSettingsView`,
  `AddFeedView`, `AddPodcastView`, `EpisodeListView`, `SubscriptionsView`)
  read `entitlements.isEntitled` synchronously on the main actor from a
  `@MainActor @Observable` store and pass it as a plain `Bool` into
  `@MainActor`-isolated inits/methods — no boundary crossing.
- [x] @Model/SwiftData actor boundary: PASS — the cap check's
  `context.fetch`/`context.fetchCount` calls in
  `currentPodcastCountForCapCheck()`/`allPodcastsForCapCheck()` run on the
  main `ModelContext` from the main actor, never touching
  `FeedRefreshActor`'s background context. No `@Model` object (`Podcast`,
  `Episode`) is passed into or out of `FeedRefreshActor` by this diff; only
  `Sendable` `PersistentIdentifier`s and the pre-existing `RefreshOutcome`/
  new `BulkSubscribeOutcome`/`BulkSubscribeResult` value types cross that
  boundary, matching the established pattern in this file.
- [ ] AVAudioSession main actor: N/A — this diff touches no audio code.
- [ ] Combine publishers: N/A — no Combine in this diff.
- [x] nonisolated functions: PASS — no `nonisolated` added or needed;
  `PodcastCapPolicy`'s static funcs are pure and free-standing (not
  actor-isolated in the first place) rather than `nonisolated` members of an
  isolated type.
- [x] Structured concurrency: PASS — no `Task.detached` anywhere in the
  diff. `RootView.handleIncomingURL` and the UI call sites use plain `Task {
  }` (inherits the calling `@MainActor` context), matching pre-existing
  usage. No new `withTaskGroup`.
- [x] Global state: PASS — no new global/static `var`. `PodcastCapPolicy
  .freeTierLimit` is `static let Int` (immutable, trivially safe). New
  `SettingsKey`/`SettingsDefault` entries (`podcastCapGatingIntroduced`,
  `grandfatheredPodcastCount`) are `static let String`/`Bool`/`Int`
  constants, same pattern as every existing key in that enum.
- [x] Swift 6 build clean: PASS — Debug build under the real project
  settings (`SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: minimal`) on
  simulator `F868F72E-091C-47D9-B003-1AE0670E5455`: **BUILD SUCCEEDED**,
  zero warnings, zero errors.

Secondary informational check (forced `SWIFT_STRICT_CONCURRENCY=complete`
override, not the shipping config): **BUILD FAILED**, but with the same
documented pre-existing baseline signature as prior gates on this repo —
`QueueScreen.swift:100` compiler-crash diagnostic, `KeyPath`-not-`Sendable`
warnings (`FoldersScreen.swift`, `QueueRepository.swift:345`,
`QuickActionRepository.swift:64`, and the `@Query`/`#Predicate` macro
expansions in `RootView`/`InboxScreen`), `EarshotSchema*.versionIdentifier`
global-state warnings, `EpisodeSummaryCache.shared`, `RSSParser`'s static
`ISO8601DateFormatter`s, and `DownloadManager.swift:122`. One warning
initially looked diff-related — `SubscriptionRepository.swift:181:
sending 'episode' ... non-Sendable type 'any EpisodeDownloading'` — but
`git diff 76c551b..HEAD` shows that exact `await downloader.download(episode)`
line is an untouched context line (pre-existing at old line 154, now at 181
purely from insertions above it), so it's the same root-cause baseline issue
as `DownloadManager.swift:122`, just visible at a second call site — not a
new violation introduced by #635. No finding in this diff triggers a NEW
warning or error under forced strict-complete mode.

Test verification (ran myself on simulator
`F868F72E-091C-47D9-B003-1AE0670E5455`, Debug/real settings): `-only-testing`
run of `PodcastCapPolicyTests` (14), `SubscriptionRepositoryTests` (47),
`OPMLBulkImportTests` (11), `AppSettingsStoreTests` (18) — 90 tests, all
passed, 0 failures.

`git status --short` in the worktree was clean before and after this
review; no dart-format hook side effect to restore (no commit made).

New agents created: none — no CarPlay or background-URLSession-delegate
pattern encountered in this diff to warrant one.

Overall: PASS

## Accessibility Review — Issue #635

earshot-accessibility review complete. Issue #635 (Earshot Plus: enforce
10-podcast free tier cap). Reviewed at HEAD `114fd0e` (domain `cfc9b9b` +
security fix `31d1cbf` + docs `72a7cf9`/`114fd0e`) in isolated worktree
`earshot-wt-635`, branch `feat/issue-635-podcast-cap`. One fix applied at
commit `bae6125`.

Checklist:
- [x] Library "Read-only" indicator: PASS. `Label("Read-only", systemImage:
  "lock.fill")` is icon+text, not color alone; it's
  `.accessibilityHidden(true)` because the same text ("Read-only, upgrade
  to Earshot Plus to make changes") is folded into
  `rowLabel(for:isReadOnly:)`, which becomes the row's ONE
  `.accessibilityLabel(...)` (an explicit `accessibilityLabel` overrides
  `.accessibilityElement(children: .combine)` entirely, so there's no
  duplicate node/double-read). Verified by reading `row(for:)` and
  `rowLabel(for:isReadOnly:)` together, not assuming from a partial read.
- [x] Rotor actions on a read-only row: PASS, no fix needed.
  `rotorActions(for:)` builds toggleNotifications/toggleAutoQueue/
  unsubscribe/share — none of these add a subscription (the only thing
  #635 gates at the repository layer), so none silently no-op or behave
  oddly on a read-only podcast. Unsubscribe deliberately still works
  (frees a slot).
- [x] Cap-reached error surfacing: PASS. `AddFeedView`'s existing
  icon+text error `Section` now displays
  `SubscriptionError.podcastCapReached.errorDescription` verbatim ("You've
  reached the 10-podcast limit on the free plan (currently 10). Upgrade to
  Earshot Plus for unlimited podcasts.") — plain language, states limit +
  current count + remedy. `SearchView`/`PodcastPreviewView`'s catch blocks
  now speak the same specific message via `Announcer.announce` instead of
  a generic "Couldn't follow {title}."
- [x] OPML partial-import skip messaging: PASS. `OPMLImportOutcome`
  (importedCount + skippedForCapCount) threads through to
  `OPMLFileImporter.importFile`'s extended announcement. Verified the
  skipped count runs through `String(localized: "^[...](inflect: true)")`
  the same way the existing `imported` count does, so singular/plural both
  resolve correctly. Reachable via the existing `announceSettled` (0.5s
  delay + `assertive: true`), clear about the cap and the upgrade path.
- [x] Dynamic Type / touch targets: PASS. No `.frame(` anywhere in
  `SubscriptionsView.swift`; the new Label uses `.font(.caption)` (semantic,
  matches the adjacent episode-count caption) with no `lineLimit`. At AX5
  the caption `HStack` may wrap to a second line (no `Spacer`/priority
  tuning) but nothing clips, and VoiceOver reads the correct combined label
  regardless of visual wrap.

FINDING — fixed, not just flagged: no live announcement existed for a
*mid-session* entitlement transition. `EntitlementStore.resync()` can flip
`isEntitled` at any time (the `Transaction.updates` listener — expiry,
refund, another device), not just at launch. If that happens while the
Library is open, several rows can flip read-only status at once with
nothing telling the user — the row-level indicator is a passive disclosure
only heard by revisiting that exact row, unlike every other consequential
state change this app actively announces (speed, sleep timer, queue
changes, download complete). This didn't violate the issue's literal text
(the row indicator IS the required "visible, VoiceOver-reachable
indicator," per SWIFTUI_PLAN's own #635 Data Decisions), but it left a real
gap between the letter of the requirement and a blind user actually
discovering their library changed. Fixed at `bae6125`: added
`.onChange(of: entitlements.isEntitled)` to `SubscriptionsView` comparing
`PodcastCapPolicy.readOnlyPodcastIDs(...)` (already exhaustively covered by
`PodcastCapPolicyTests`) just before vs. after the transition, announcing
(assertive) only when the read-only count actually changes — one message
for newly-read-only ("Your Earshot Plus subscription has ended. N podcasts
in your library now read-only. Upgrade to Earshot Plus to make changes
again.") and one for restoration. No new untested pure logic — thin
view-layer wrapper around the already-tested policy function, matching this
codebase's existing convention that view-layer `Announcer` calls (e.g. the
adjacent `librarySortOrder` announcement) aren't independently unit-tested.

Verification: `xcodebuild build` on simulator
`F868F72E-091C-47D9-B003-1AE0670E5455` — BUILD SUCCEEDED. `-only-testing`
run of `PodcastCapPolicyTests` (14), `SubscriptionRepositoryTests` (47),
`OPMLBulkImportTests` (11), `AppSettingsStoreTests` (18) — 90 tests, 0
failures, after the fix. A full `xcodebuild test` run separately showed 8
pre-existing `ProductCatalogServiceTests` failures from a StoreKitTest
`SKTestSession` configuration error in this simulator environment —
unrelated to this diff (file untouched by #635; reproduces in isolation via
`-only-testing:EarshotTests/ProductCatalogServiceTests`).

`git status --short` clean before and after the fix commit; dart-format
pre-commit hook reformatted 0 files.

Overall: PASS

## Swift 6 Review — Issue #636

earshot-swift6 review complete. Issue #636 (Tip jar: consumable IAP).
Branch `feat/issue-636-tip-jar`, reviewed at commit `dedcc42` (on top of
`swift` tip `c9bdf79`) in isolated worktree `earshot-wt-636`. No fix
required.

Concurrency mode: real project settings — `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (confirmed by reading `project.yml`).

Checklist:
- [x] Sendable conformance: PASS. `TipPurchaseAttempt: Sendable` holds
  `result: RawPurchaseResult` (Sendable, Equatable, only `String`/productID
  payloads) and `finish: (@Sendable () async -> Void)?`. The `finish`
  closure, built in `StoreKitTipPurchaseSource.attempt(from:)`, captures a
  real `StoreKit.Transaction` — verified `Transaction` is itself `Sendable`
  per StoreKit 2's API and confirmed the already-merged
  `StoreKitEntitlementSource.processUpdate(_:)`
  (`EntitlementTransactionSource.swift`) relies on the identical fact
  (`await transaction.finish()` called across an actor-hopping `Task`).
  `RawPurchaseResult`/`TipJarOutcome` are plain `Sendable, Equatable` enums
  with no non-Sendable associated values.
- [x] Actor isolation: PASS. `TipJarViewModel` is `@MainActor @Observable`.
  `purchase(_:)` awaits `purchaseSource.purchase(product)` (crossing into
  the non-isolated but `Sendable` `TipPurchaseSource` protocol), then every
  mutation (`purchasingProduct`, `lastOutcome`, `lastOutcomeProduct`,
  `productsState`) happens after the `await` resumes on the main actor.
  `apply(_:for:)` correctly sequences outcome-set-and-announce BEFORE
  `await attempt.finish?()`, matching the doc comment's load-bearing
  ordering claim. No live `Transaction`/`Product` ever crosses into the view
  model — only the reduced `Sendable` `TipPurchaseAttempt`.
- [ ] @Model/SwiftData actor boundary: N/A — no `@Model` types touched.
- [ ] AVAudioSession main actor: N/A — no audio code touched.
- [ ] Combine publishers: N/A — no Combine in this diff.
- [x] nonisolated functions: PASS — no `nonisolated` needed or added.
  `TipJarDecisionLogic`'s static funcs are pure, free-standing,
  non-actor-isolated, matching the `PodcastCapPolicy` precedent from #635.
- [x] Structured concurrency: PASS — no `Task.detached` anywhere.
  `TipPresetButton`'s `Task { await action() }` inside a SwiftUI `Button`
  action closure runs on the enclosing `@MainActor`-isolated view context
  (SwiftUI's own global-actor annotations, not implicit inheritance from a
  non-isolated context) — confirmed by the forced strict-complete build
  below producing zero warnings on that line. `TipJarView.body`'s
  `.task { await viewModel.loadProducts() }` is plain structured work.
- [x] Global state: PASS — no new `static var`. `EarshotPlusProduct
  .tipProducts` is pre-existing (#631), not new.
- [x] `@unknown default` exhaustiveness: PASS —
  `StoreKitTipPurchaseSource.attempt(from:)`'s outer switch on
  `Product.PurchaseResult` has an explicit `@unknown default` mapping to
  `.pending` (never-finish); the inner `VerificationResult` switch is a
  2-case enum handled exhaustively with no payload silently dropped.
- [x] Swift 6 build clean: PASS — Debug build under real project settings
  on simulator `399785CB-676D-4415-98D8-40B4E04DA264`: **BUILD SUCCEEDED**,
  zero warnings, zero errors (only a benign AppIntents-framework-not-found
  notice, unrelated to this diff).

Secondary informational check (forced `SWIFT_STRICT_CONCURRENCY=complete`
override): **BUILD FAILED**, but exclusively with this repo's documented
pre-existing baseline signature — `QueueScreen.swift:100` compiler-crash
diagnostic, `KeyPath`-not-`Sendable` warnings (`FoldersScreen.swift`,
`QueueRepository.swift:345`, `QuickActionRepository.swift:64`,
`RootView`/`InboxScreen` `@Query`/`#Predicate` macros),
`EarshotSchema*.versionIdentifier` global-state warnings,
`EpisodeSummaryCache.shared`, `RSSParser`'s static `ISO8601DateFormatter`s,
and `DownloadManager.swift:122` + `SubscriptionRepository.swift:181`
non-Sendable `Episode`/`EpisodeDownloading` warnings. Grepped the full log
specifically for `TipJarDecisionLogic.swift`, `TipPurchaseSource.swift`,
`TipJarViewModel.swift`, `TipJarView.swift`, `HelpSettingsView.swift` — all
five appear only in `SwiftCompile` invocation lines, zero diagnostics
attributed to them.

Test verification (isolated `-derivedDataPath` to avoid a build-database
lock collision with the concurrently-running earshot-security gate in the
same worktree): `-only-testing` run of `TipJarDecisionLogicTests` (8) +
`TipJarViewModelTests` (13) — 21 tests, all passed, 0 failures. Includes
`testSuccessfulPurchaseShowsThankYouBeforeFinishing` and
`testSuccessfulPurchaseFinishesExactlyOnce`, which directly exercise the
ordering/actor-isolation guarantee in `apply(_:for:)`.

Re-checked `git log`/`git status` before finishing: HEAD still `dedcc42`,
working tree clean — the concurrent earshot-security gate had not added a
follow-up commit as of this review.

New agents created: none.

Overall: PASS

## Security Review — Issue #636

earshot-security gate. Issue #636 (tip jar consumable IAP). Reviewed at
commit `dedcc42` in the isolated worktree `earshot-wt-636`, branch
`feat/issue-636-tip-jar`. **Verdict: PASS.** No fixes required; the branch
is unchanged from `dedcc42`.

Read all 6 new/changed files in full plus the pre-existing files the primary
focus area required tracing into (`EntitlementTransactionSource.swift`,
`EntitlementStore.swift`, `EntitlementFactMapper.swift`, `EntitlementFact.swift`,
`EarshotPlusProduct.swift`, `ProductCatalogService.swift`). Confirmed via the
installed SDK's `StoreKit.swiftinterface` (not assumed) that `StoreKit
.Transaction` has unconditional `Sendable` conformance, since the project
builds with `SWIFT_STRICT_CONCURRENCY: minimal` and a clean build alone
wouldn't prove this. Ran `xcodebuild build` (BUILD SUCCEEDED) and
`xcodebuild test -only-testing:EarshotTests/TipJarDecisionLogicTests
-only-testing:EarshotTests/TipJarViewModelTests` (21/21 passed) on
`platform=iOS Simulator,id=399785CB-676D-4415-98D8-40B4E04DA264`.

**`Transaction.finish()` analysis (the primary ask) — all five sub-questions
checked out clean:**
1. `finish` is `nil` for `.unverified`/`.userCancelled`/`.pending`/
   `@unknown default` at the type level in `StoreKitTipPurchaseSource
   .attempt(from:)`, and gated again by `TipJarDecisionLogic
   .shouldFinish(for:)` before ever being called.
2. `apply(_:for:)` sets `lastOutcome`/`lastOutcomeProduct` and announces via
   VoiceOver strictly before the `guard shouldFinish` + `await attempt
   .finish?()` — no intervening `await`, so no race.
3. A thrown `purchaseSource.purchase()` produces no `TipPurchaseAttempt` at
   all. Traced the cross-file interaction with `EntitlementStore`'s global
   `Transaction.updates` listener: it does see tip transactions (single
   global stream), maps them to an `EntitlementFact`, but `EarshotPlusProduct
   .earshotPlusProducts` excludes the three tip cases so it never finishes
   them and never grants entitlement from one — confirmed no double-finish
   path exists. Flagged one non-bug inefficiency (a redundant `resync()` per
   tip purchase) for awareness only, not fixed — out of this diff's scope
   and structurally harmless since `Transaction.currentEntitlements`
   excludes consumables.
4. `purchasingProduct` guard prevents any double-purchase/double-finish from
   a double-tap or re-entrant call; verified by
   `testPurchaseIsIgnoredWhileAnotherPurchaseIsInFlight`.
5. Sendability confirmed sound at the SDK level, not just "it compiled."

Full checklist (force-unwraps, `try?`, `fatalError`, retain cycles,
`@MainActor`, entitlements/secrets, typed errors, `AppLog` coverage) also
passed. No hardcoded secrets; no PII logged (product IDs and error
descriptions only). Confirmed this code path never reads or writes
`EntitlementStore.isEntitled` — tips can neither be gated by entitlement nor
grant it.

Full structured review posted to the issue:
https://github.com/payown/earshot/issues/636#issuecomment-4931735122

Overall: PASS

## Accessibility Review — Issue #636

earshot-accessibility gate. Issue #636 (Leave a Tip). Reviewed at commit
`dedcc42` in the isolated worktree `earshot-wt-636`, branch
`feat/issue-636-tip-jar` — working tree clean, no concurrent commits from
the security/swift6 gates as of this review. No accessibility defects
found; no fix commit necessary.

Read all five relevant files in full (`TipJarView.swift`,
`TipJarViewModel.swift`, `TipPurchaseSource.swift`,
`TipJarDecisionLogic.swift`, `HelpSettingsView.swift`'s new row), plus
`EarshotPlusProduct.swift` (exact product IDs/order), `Core/Accessibility
/ReduceMotion.swift` (motionAwareAnimation definition), and `Earshot
/Testing/Configuration.storekit` (exact StoreKit displayName/displayPrice
strings used in this review's transcripts).

**Every string on screen, in visual/reading order:**
1. Nav title: "Leave a Tip"
2. Body text: "Earshot is free to use, with no ads and no trackers. If it's
   useful to you, a tip helps keep it that way."
3. Loading state (transient): "Loading tip options"
4. Loaded state — three preset rows (`Configuration.storekit` values):
   "Small Tip" / "$1.99", "Medium Tip" / "$4.99", "Large Tip" / "$9.99"
5. Failed-to-load state: "Couldn't load tip options." / "Check your
   connection and try again." / "Try Again" (button)
6. Outcome status text (only after an attempt), one of: "Thank you for your
   $X.XX tip." (or "Thank you for your tip." if price unavailable), "Tip
   cancelled.", "Purchase pending approval.", "Tip failed. Try again."

**Full VoiceOver focus order** (verified against the actual `body`
structure, matches the view's own doc comment):
1. Navigation bar back button (system-standard)
2. Body text, single stop (one `Text`, no internal concatenation)
3. Preset 1 (Small): label `"Leave a $1.99 tip"` idle / `"Purchasing $1.99
   tip"` mid-purchase; hint `"Purchases a one-time tip. Does not unlock
   Earshot Plus."`
4. Preset 2 (Medium): label `"Leave a $4.99 tip"` / `"Purchasing $4.99
   tip"`; same hint
5. Preset 3 (Large): label `"Leave a $9.99 tip"` / `"Purchasing $9.99
   tip"`; same hint
6. Outcome status (only present after an attempt):
   `.accessibilityElement(children: .combine)` + `.accessibilityLabel
   (message)` — reads exactly the on-screen message text, single stop, no
   icon double-read

No `.accessibilitySortPriority` anywhere in `Features/Monetization/` —
order is pure DOM order as documented.

**Announcement text and firing points** (`Announcer.announce(_,
assertive: true)`, verified in `TipJarViewModel.swift`):
- On `purchase()` entry, before the async purchase call: `"Purchasing
  $X.XX tip."` (or `"Purchasing tip."` if price unavailable)
- In `apply(_:for:)`, after the outcome is set but before `attempt
  .finish?()` is awaited: the same string as `outcomeMessage`
- In the `catch` block of `purchase()`: `"Tip failed. Try again."`
- Race check: `purchase()` guards on `purchasingProduct == nil`, so a
  second tap can't start a concurrent purchase; no double-announce or
  stale-state path found, including across backgrounding mid-purchase.

**Other checks, all PASS:** heart icon `.accessibilityHidden(true)`, not
double-announced; `TipOutcomeStatus` icons follow the established
icon+text+color pattern (never color alone); Dynamic Type — only
`.lineLimit(2)` on the product name (cosmetic), no fixed-height frames,
`.frame(minHeight: 44)` is a minimum not a fixed height; touch targets all
>=44pt; `motionAwareAnimation` genuinely branches on `Motion.isReduced`
(`UIAccessibility.isReduceMotionEnabled`); price is a real visible `Text`,
not VoiceOver-only; grepped the whole feature folder — the screen is never
gated behind `EntitlementStore.isEntitled`.

**Dismissal-without-tipping judgment call:** the domain agent's choice
(standard system back button only, no extra close button, since this is a
pushed `NavigationLink` screen, not a sheet) is **sufficient as-is** —
matches the identical pattern already used for `SendFeedbackView`/
`AboutView` in the same `HelpSettingsView`, and the back button is already
first in focus order, always visible, and 44pt. Agreed with the domain
agent's flagged call: no change needed.

Overall: PASS

## Issue #636 Summary (Tip jar consumable IAP — Leave a Tip)

**Owner:** earshot-ui (implementation spanned Domain/Data/Presentation
under `Features/Monetization/`, matching the issue's dual "earshot-ui +
earshot-data" ownership and the #631-#638 A-series precedent).

**Gates:** earshot-security PASS, earshot-swift6 PASS, earshot-accessibility
PASS. All three ran independently against commit `dedcc42`; none required a
fix commit (only earshot-swift6 added a docs-only follow-up, `e75b6a5`,
logging its own review into this file).

**What shipped:** Settings > Help & About > "Leave a Tip" — three consumable
presets ($1.99/$4.99/$9.99, `media.payown.earshot.tip.small/medium/large`,
built on the #631 catalog), available to free and paid users (never gated
on `EntitlementStore.isEntitled`). Purchase flow: verify (StoreKit 2 local
cryptographic check) -> set outcome + announce to VoiceOver (thank-you is
visible/spoken before anything else happens) -> `Transaction.finish()`,
gated by a new pure `TipJarDecisionLogic.shouldFinish(for:)` so finish only
ever runs for a verified result. New `TipPurchaseSource` protocol (mirroring
the `EntitlementTransactionSource` pattern from #634) makes the finish-timing
behavior directly unit-testable with a fake purchase source.

**Test count:** 1254 -> 1275 (+21: 8 `TipJarDecisionLogicTests`, 13
`TipJarViewModelTests`). The only failures in a full-suite run are 8
pre-existing `ProductCatalogServiceTests` failures from a StoreKitTest
`SKTestSession` configuration error in this simulator environment —
documented as pre-existing/unrelated in the #631 and #635 gate reviews, not
introduced here. Release build clean.

**Process note:** the fresh worktree's `.dart_tool` package resolution was
stale, which made the repo's unscoped `dart format --set-exit-if-changed
lib/ test/` pre-commit hook reformat 66 unrelated legacy Flutter files (the
tracked #660 noise) and block the commit. Fixed by running `flutter pub get`
in the worktree (confirmed 0 files changed afterward) rather than bypassing
the hook — no `--no-verify` used.

**Branch:** `feat/issue-636-tip-jar` into `swift`, PR opened per Michael's
explicit instruction to review design/copy before merge — **not merged, not
closed.** Michael is reviewing this together with the #632 paywall PR.

## Testing Gate — Issue #632

earshot-testing gate complete. Issue #632 (Earshot Plus: paywall / upgrade
screen). Worktree `earshot-wt-632`, branch `feat/issue-632-paywall`, HEAD
`a166f72` (on `swift` tip `c9bdf79`), reviewed on pinned simulator
`39E0DF74-2312-4D8B-8612-05AAD43EB8B5` (iPhone 17e).

**Test coverage spot-check.** Read `PaywallLogic.swift`,
`PaywallViewModel.swift`, `PaywallView.swift`, and all three trigger-point
call sites (`SearchView.swift`, `PodcastPreviewView.swift`,
`DataSettingsView.swift`/`OPMLFileImporter.swift`, `SettingsScreen.swift`)
against #632's requirements. `PaywallLogicTests.swift` (20 tests) is
StoreKit-free and covers the full pure-logic surface: best-value badge math
(honest percentage, floor-never-round-up, nil for a false/non-existent
saving, nil for missing/zero-price/malformed inputs), combined
accessibility labels (name + price + cadence for subscriptions, name +
price + "one-time purchase" for lifetime), subscription vs. lifetime
disclosure copy (auto-renew/cancel language present for subscriptions,
explicitly absent for lifetime), spoken cadence singular/plural forms, and
every purchase-outcome announcement (in-progress polite, success/pending/
failed all assertive, cancelled polite and never phrased like an error,
and a compile-time-enforced guarantee that cancellation has no case in
`PaywallPurchaseOutcome`). `PaywallViewModelTests.swift` (3 tests) exercises
`loadProducts()` against a real `SKTestSession`, inheriting the same
`SKInternalErrorDomain Code=3` headless-CI limitation already documented
for #631/#633 (see below) — not a gap in this PR.

**Coverage gap found and closed.** The three trigger points wire a new
`showPaywall` sheet flag from three different failure paths, but one of
them — `OPMLFileImporter.importFile`'s new `onCapSkipped` callback
parameter, the signal `DataSettingsView` uses to present the paywall after
a cap-trimmed OPML import — had zero test coverage. Neither
`OPMLFileImporterTests.swift` nor `OPMLImportProgressTests.swift` passed
`isEntitled` or `onCapSkipped` to any existing call, and the domain agent's
own two new test files never touch `OPMLFileImporter` at all (that logic
lives one layer up from `PaywallViewModel`/`PaywallLogic`). The other two
trigger points (`SearchView`'s and `PodcastPreviewView`'s `subscribe(_:)`/
`toggleFollow()` catch blocks) and the Settings row's `if
!entitlements.isEntitled` guard are plain `@State`/view-body logic with no
`ViewInspector` (or equivalent) in this codebase's dependency graph to
drive a SwiftUI view tree in a headless unit test — consistent with every
prior gate in this file, sheet-presentation wiring at the view-body level
is verified by device/simulator testing, not XCTest. `onCapSkipped`,
by contrast, is a plain synchronous callback on a `@MainActor` static
function with a real, headless-testable seam, so its absence was a genuine
gap, not an inherent view-testing limitation. Added 4 tests to
`OPMLFileImporterTests.swift`:
- `testOnCapSkippedFiresOnceWhenImportIsFullyTrimmedByCap` — a non-entitled
  user already at/over the free-tier limit (15 existing podcasts, cap 10)
  gets the whole 3-feed request trimmed to zero
  (`PodcastCapPolicy.allowedNewSubscriptions` clamps at 0), and
  `onCapSkipped` fires exactly once, not once per skipped feed. Stays fully
  offline: because the request is trimmed to zero, none of the 3 requested
  feeds are ever attempted, so they need not be pre-seeded as
  already-subscribed.
- `testOnCapSkippedDoesNotFireForEntitledUser` — an entitled (Plus) user's
  import is never trimmed, so the callback must never fire even though
  every feed is genuinely new.
- `testOnCapSkippedDoesNotFireWhenImportStaysUnderCap` — a free-tier import
  comfortably under the cap must not fire either; the paywall is only for a
  genuinely trimmed import.
- `testOnCapSkippedDoesNotFireWhenEntitlementIsNil` — `isEntitled == nil`
  (the default, matching every legacy/test call site that predates #635)
  means the cap isn't enforced at this call site at all, so the callback
  must never fire regardless of requested count.

All 4 new tests use the `@MainActor final class CapSkippedSpy` pattern
already established by `OPMLBulkImportTests`' `ProgressRecorder` — a plain
same-actor reference type captured by the `@MainActor @Sendable` callback,
not a lock-guarded counter (unlike `OPMLBulkImportTests`' cross-actor
`onMerge` spy, `onCapSkipped` only ever fires on the main actor here).
Committed at `6a6f7ee`.

**Full suite.** `xcodebuild test` on the pinned simulator: **1281 executed,
1 skipped (env-gated `ScaleDiagnosticTests`, unchanged), 13 failures**
(11 unique test methods — 2 appear twice in xcodebuild's summary listing
but each `Test Case` log entry confirms a single run). Baseline of record
was **1254 executed, 1 skipped, 8 known-environmental failures**. Count
math: 1254 + 20 (`PaywallLogicTests`) + 3 (`PaywallViewModelTests`) + 4
(this gate's `OPMLFileImporterTests` additions) = 1281. **Count increased,
zero regressions** — every one of the original 1246 passing baseline tests
(1254 minus the 8 known failures) still passes.

**Independent verification of the StoreKit failures (not just trusting the
domain agent's report).** The 11 unique failing tests are the same 8
`ProductCatalogServiceTests` already logged against #631/#633 in this file,
plus the domain agent's 3 `PaywallViewModelTests`. Grepped the actual test
run's console output rather than assuming: every one of the 3
`PaywallViewModelTests` failures logs the identical signature already
documented for #631 —
```
[SKTestSession] Error saving configuration file: Error Domain=SKInternalErrorDomain Code=3 "(null)"
[SKTestSession] Error clearing overrides: Error Domain=SKInternalErrorDomain Code=3 "(null)"
[SKTestSession] Error setting value to 1 for identifier 2 for media.payown.earshot: Error Domain=SKInternalErrorDomain Code=3 "(null)"
[SKTestSession] Error deleting all transactions: Error Domain=SKInternalErrorDomain Code=3 "(null)"
[monetization] Paywall product fetch failed: The operation couldn't be completed. (Earshot.ProductCatalogService.CatalogError error 0.)
```
— the local StoreKitTest daemon failing to persist `SKTestSession`
configuration in this headless environment, not a defect in
`PaywallViewModel.loadProducts()` or `ProductCatalogService`. This is the
exact same root cause already independently reproduced against an
unmodified `swift` tip for #633's gate. Not a #632 regression.

**Release build.** `xcodebuild -configuration Release build` on the pinned
simulator: **BUILD SUCCEEDED**. First run reused already-built products
from this worktree's DerivedData with zero recompilation, so re-ran after
touching all 8 changed production files (`PaywallLogic.swift`,
`PaywallView.swift`, `PaywallViewModel.swift`, `PodcastPreviewView.swift`,
`SearchView.swift`, `DataSettingsView.swift`, `SettingsScreen.swift`,
`OPMLFileImporter.swift`) to force a real recompile under Release/WMO.
Second run: **BUILD SUCCEEDED**, 7 warning lines resolving to 3 unique
messages (each appearing twice from two compile passes) — `ChapterParser.swift`
(unused loop variable), `OPMLImportService.swift` (redundant `await`), and
`DownloadManager.swift` (Swift 6 Sendable warning) — **none in a file this
diff touches** (confirmed against the `git diff swift..HEAD --stat` file
list). Zero new warnings introduced by #632.

**Regressions found:** none.

```
earshot-testing complete. Issue #632.

New tests written: 4 (OPMLFileImporterTests.swift — onCapSkipped paywall
trigger wiring, a real coverage gap the domain agent's own two new test
files didn't reach)
Previous test count: 1254 executed, 1 skipped
New test count: 1281 executed, 1 skipped, 13 failures / 11 unique failing
tests (8 pre-existing ProductCatalogServiceTests + 3 new
PaywallViewModelTests, all independently confirmed as the same
SKInternalErrorDomain Code=3 StoreKitTest-sandbox limitation documented for
#631/#633 — not a regression)
Count increased: yes

Release build (IS_BETA_BUILD absent): PASS — BUILD SUCCEEDED, 0 new
warnings introduced by this diff
PRD acceptance criteria covered: three products displayed with correct
combined accessible labels (name+price+period), best-value badge honest
percentage math, subscription vs. lifetime disclosure copy correctness,
purchase-outcome-to-announcement mapping (in-progress/success/pending/
failed/cancelled, including the compile-time guarantee cancellation has no
outcome case), the OPML-import trigger point's onCapSkipped wiring (closed
gap). The other two trigger points' sheet-presentation wiring and the
Settings row's entitled-hide guard are plain SwiftUI view-body logic with
no ViewInspector in this codebase to drive headlessly — consistent with
every prior gate, verified by device/simulator testing, not XCTest.

Regressions found: none

Overall: PASS

## Security Review — Issue #632

earshot-security review complete. Issue #632 (Earshot Plus: paywall /
upgrade screen). Branch `feat/issue-632-paywall`, reviewed at HEAD `60d9c47`
(domain `a166f72` + testing-gate follow-up `6a6f7ee`/`60d9c47`) on top of
`swift` tip, in isolated worktree `earshot-wt-632`. No fix required.

Checklist:
- [x] Force-unwraps: PASS — none found. Every `!` in the diff's production
  files is boolean negation (`!isEntitled`, `!episodes.isEmpty`,
  `!isRestoring`, etc.).
- [x] Silent try?: PASS — no new `try?` introduced by this diff. The two
  `try?` calls that exist in `OPMLFileImporter.swift`
  (`String(contentsOf:)` at the top of `importFile`, and
  `Task.sleep(nanoseconds:)` inside `announceSettled`) are both pre-existing
  lines untouched by this PR — confirmed against the file's diff hunks,
  which only touch the `onCapSkipped` parameter and its one call site.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new `Task {}` captures `self` on a class.
  `PaywallViewModel` (the one new reference type) spawns no `Task` of its
  own; every `Task {}` in the diff lives in a SwiftUI `View` struct
  (`PaywallView`, `SettingsScreen`, `DataSettingsView`) capturing `model`/
  local state, which is not a retain-cycle risk for a value type. No new
  `.sink`, `addObserver`, or `Timer` in this diff.
- [x] @MainActor: PASS — `PaywallViewModel` is `@MainActor @Observable`;
  `purchase(_:entitlements:)` and `handle(result:for:entitlements:)` run
  entirely on the main actor, and `EntitlementStore.resync()` (called from
  inside `handle`) is itself `@MainActor`-isolated (confirmed by reading
  `EntitlementStore.swift`'s class declaration). No SwiftData access in
  this diff at all — `PaywallLogic`/`PaywallProductDisplay` are plain
  StoreKit-free, SwiftData-free structs.
- [ ] IS_BETA_BUILD Release build: N/A (no migration-sheet code in this
  diff) — ran the Release build anyway as a general gate on the pinned
  simulator (`39E0DF74-2312-4D8B-8612-05AAD43EB8B5`): **BUILD SUCCEEDED**,
  zero errors/warnings.
- [ ] Entitlements: N/A — `Earshot.entitlements` untouched;
  `project.pbxproj` changed only to wire in the five new files
  (`PaywallLogic.swift`, `PaywallView.swift`, `PaywallViewModel.swift`,
  `PaywallLogicTests.swift`, `PaywallViewModelTests.swift`) — verified all
  four required sections present for each (PBXBuildFile, PBXFileReference,
  group children, PBXSourcesBuildPhase).
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new `Error` types introduced; this diff
  reuses the existing `SubscriptionError.podcastCapReached` (#635) as a
  catch target and StoreKit's own `Product.PurchaseResult`/
  `VerificationResult` enums. No string-thrown errors.
- [x] AppLog coverage: PASS — every catch/error branch in
  `PaywallViewModel` logs via `AppLog.monetization.error(...)` (product
  fetch failure, purchase throw, unverified transaction) before updating
  state. No empty catch blocks.

Purchase-flow-specific checks (issue-specific, per the task brief):
1. **`Product.purchase()` verification handling**: PASS. `handle(result:for:
   entitlements:)` switches on `Product.PurchaseResult` and, within
   `.success`, on `VerificationResult` explicitly. `.verified(transaction)`
   is the only path that calls `transaction.finish()` and
   `entitlements.resync()`. `.unverified(_, error)` never finishes the
   transaction and never touches entitlement state — it only logs via
   `AppLog.monetization.error` and sets `outcome = .failed`. This is the
   same "verify or deny, no middle ground" convention already established
   and reviewed in `EntitlementFactMapper`/`EntitlementEngine` (#634); the
   file's own doc comment explicitly calls out mirroring
   `StoreKitEntitlementSource`'s conservative handling.
2. **`transaction.finish()` timing**: PASS, reviewed in depth.
   `transaction.finish()` is called *before* `entitlements.resync()` inside
   the `.verified` branch, not after. This is a deliberate deviation from
   the strict WWDC "verify → deliver content → finish" ordering, but it is
   safe here and does not risk losing a grant: `EntitlementStore.resync()`
   derives entitlement purely from `Transaction.currentEntitlements`
   (confirmed by reading `EntitlementStore.swift`'s doc comment and body),
   which is unaffected by a transaction's finished/unfinished state — only
   the *redelivery* of that transaction via `Transaction.updates` depends
   on finish state, not its presence in `currentEntitlements`. If the app
   crashes between `finish()` and `resync()`, `EarshotApp.swift` calls
   `entitlements.resync()` unconditionally at every launch (confirmed by
   reading `EarshotApp.swift:102-103`), which self-heals the flag on next
   launch by re-deriving it from the still-intact `currentEntitlements`
   read. No double-finish risk: `purchase(_:entitlements:)` guards
   re-entrancy with `purchasingProduct == nil` before any StoreKit call is
   made, so a given `PaywallViewModel` instance can't race itself into two
   `product.purchase()` calls, and StoreKit itself is the source of truth
   for whether a given `Transaction` was already finished (finishing an
   already-finished transaction is a documented safe no-op). The failure
   path (`catch` around `product.purchase()`, `.pending`, `.userCancelled`,
   `.unverified`) never calls `finish()`, so a transaction that didn't
   settle as verified-success is correctly left for `Transaction.updates`
   to pick up later — no unfinished-transaction leak on the success path,
   no premature finish on any other path.
3. **No sensitive data logged**: PASS. Every `AppLog.monetization` call in
   `PaywallViewModel` logs only `display.product.rawValue` (a product ID
   string) and `error.localizedDescription` — no transaction ID, no JWS
   payload, no receipt data, no price. Matches the established
   `EntitlementStore`/`RestorePurchasesRow` convention exactly (both log
   `error.localizedDescription` only).
4. **Race/reentrancy**: PASS, defense in depth at three layers. (a)
   `PaywallViewModel.purchase(_:entitlements:)` itself: `guard
   purchasingProduct == nil, let product = products[display.product] else
   { return }` — a second call while one is in flight is a no-op. (b) Each
   product's purchase `Button` in `PaywallView.productCard(_:badge:)`:
   `.disabled(model.purchasingProduct != nil || model.outcome == .success)`.
   (c) The whole `loadedView` scroll content:
   `.disabled(model.purchasingProduct != nil)`. This exactly mirrors
   `RestorePurchasesRow`'s `guard !isRestoring else { return }` +
   `.disabled(isRestoring)` busy-guard pattern cited in the task brief.
5. **Failure/cancellation paths never silently swallow errors**: PASS.
   `product.purchase()`'s thrown-error catch, the `.unverified` branch, and
   the `@unknown default` case all log via `AppLog.monetization.error`
   before updating `outcome`. `.userCancelled` is the one path that
   deliberately does not log or set `outcome` — this is correct, documented
   behavior (not a swallowed error): cancellation is a normal user action,
   not a failure, and the doc comment on `PaywallPurchaseOutcome` explains
   why it has no case for it. `.pending` also doesn't log (also correct —
   not an error, it's Ask-to-Buy/parental-approval, a valid non-failure
   settlement state, and it does update `outcome = .pending` so the UI
   reflects it).
6. **`onCapSkipped` additive-only**: PASS, confirmed by reading the diff
   hunk directly. New parameter `onCapSkipped: (@MainActor @Sendable () ->
   Void)? = nil` defaults to `nil`; the one new call
   (`onCapSkipped?()`) fires only inside the existing `if
   outcome.skippedForCapCount > 0` branch, strictly after the existing
   `announceSettled` message is composed and in addition to it (the
   `await announceSettled(message)` call and its `return
   outcome.importedCount` are unchanged and unmoved). No new
   fetch/save/logic path — it's a single closure invocation appended to an
   existing branch. `DataSettingsView`'s only call site
   (`OPMLFileImporter.importFile(...)`) adds the new argument as a trailing
   closure that just flips local `@State private var showPaywall`; every
   other existing call site (onboarding, share-extension `onOpenURL`, and
   all `OPMLFileImporterTests` cases not specifically testing the new
   parameter) is untouched and continues to pass no closure. Verified this
   compiles and behaves correctly via the 8/8 passing
   `OPMLFileImporterTests` (including 4 new `onCapSkipped`-specific cases)
   run myself on the pinned simulator.
7. **Entitlements / project.pbxproj**: PASS — see checklist item above.
   Nothing StoreKit-adjacent in this issue required a new entitlement
   (StoreKit purchases don't need an App Group or any other capability);
   `project.pbxproj` diff is pure xcodegen file-wiring, all four required
   sections present for all five new files, no other project settings
   touched.

Build + test verification (ran myself on the pinned simulator
`39E0DF74-2312-4D8B-8612-05AAD43EB8B5`, booted, `xcodebuild` run from
`EarshotSwift/` with no `cd` to repo root):
- Release build: **BUILD SUCCEEDED**, 0 errors, 0 warnings.
- `PaywallLogicTests`: 20/20 passed (pure StoreKit-free logic — full
  coverage, no environment limitation).
- `OPMLFileImporterTests`: 8/8 passed, including all 4 new
  `onCapSkipped`-specific cases.
- `PaywallViewModelTests`: 3/3 failed — independently reproduced and
  confirmed these are exactly the documented, pre-existing
  `SKInternalErrorDomain Code=3` local-StoreKit-test-daemon limitation
  (`[SKTestSession] Error saving configuration file:` in the log output),
  the same failure signature already carried as a known environment gap
  for `ProductCatalogServiceTests` since #631 and re-confirmed in the
  #635 and testing-gate-#632 reviews above. Not a #632 regression — the
  logic these tests exercise (`loadProducts()`'s delegation to
  `ProductCatalogService.fetchEarshotPlusProducts()`) is otherwise
  identical to already-covered code, and the StoreKit-free logic it feeds
  (`PaywallLogic`) is fully covered and passing.

New agents created: none.
Feature suggestions identified: none this review — #632 itself already
covers the natural iOS-native surface (StoreKit 2 paywall); no additional
Siri Shortcut / Live Activity / Spotlight / Focus filter / Share Extension
opportunity was identified specific to this diff's purchase-flow code that
isn't already tracked by an existing open issue.

Overall: PASS
```

## Swift 6 Review — Issue #632

earshot-swift6 review complete. Issue #632 (Earshot Plus: paywall / upgrade
screen). Branch `feat/issue-632-paywall`, reviewed at HEAD `56b4cd0` (domain
`a166f72` + testing-gate `6a6f7ee`/`60d9c47` + security-gate docs-only
`56b4cd0`) in isolated worktree `earshot-wt-632`. No fix required.

Concurrency mode: real project settings — `SWIFT_VERSION: "5.0"` /
`SWIFT_STRICT_CONCURRENCY: minimal` (confirmed by reading `project.yml`
myself, not assumed).

Checklist:
- [x] Sendable conformance: PASS — `PaywallViewModel` is correctly
  `@MainActor @Observable` and correctly NOT marked `Sendable` (a mutable
  reference type with `@MainActor` isolation is the right shape; adding
  `Sendable` on top would be redundant/wrong). `PaywallProductDisplay` and
  `PaywallSubscriptionPeriod` are `Equatable, Sendable` plain value structs
  built entirely from `Sendable` primitives (`String`, `Decimal`, `Int`,
  a `Sendable` nested `Unit` enum) — no `Product`/StoreKit reference
  escapes them. `PaywallPurchaseOutcome` and `PaywallLogic.Announcement`
  are `Equatable, Sendable` value types. `PaywallViewModel.LoadState` is
  `Equatable, Sendable`. `PaywallLogic` itself is a StoreKit-free,
  stored-property-free `enum` of pure static functions — needs no
  isolation or `Sendable` annotation at all, confirming the domain agent's
  stated design goal. `ProductCatalogService` (pre-existing, unchanged by
  this diff) is `Sendable`; `EntitlementStore` (pre-existing, unchanged) is
  `@MainActor @Observable`, matching `PaywallViewModel`'s own shape.
- [x] Actor isolation: PASS, traced every `await` call site by hand.
  `PaywallViewModel.loadProducts()` and `purchase(_:entitlements:)` are
  `async` methods on a `@MainActor` class, so every `await` inside them
  (`catalog.fetchEarshotPlusProducts()`, `product.purchase()`,
  `transaction.finish()`, `entitlements.resync()`) resumes back on the
  main actor — confirmed there is no `nonisolated`, no `Task.detached`,
  and no escaping closure anywhere in the type that would hop off it.
  `handle(result:for:entitlements:)` is a private method on the same
  `@MainActor` class, so it and every mutation of `purchasingProduct` /
  `outcome` inside it are main-actor-isolated too. `EntitlementStore
  .resync()` (called from `handle(result:...)`) is itself `@MainActor`
  (unchanged pre-existing code, re-verified by reading the class
  declaration), so this is a same-actor call, not a boundary crossing —
  no `await MainActor.run` wrapper needed or present. In `PaywallView`,
  `@State private var model = PaywallViewModel()` and `@Environment
  (EntitlementStore.self) private var entitlements` are both read/written
  only from `View.body`/button-action closures, which SwiftUI always runs
  on the main actor for a (implicitly `@MainActor`) `View` conformer — the
  `Task { await model.purchase(display, entitlements: entitlements) }`
  call in `productCard(_:badge:)` inherits that main-actor context
  (plain `Task {}`, not `.detached`). Same pattern, independently verified,
  for the four wiring call sites: `PodcastPreviewView.toggleFollow()`'s
  and `SearchView.subscribe(_:)`'s catch blocks set `showPaywall = true`
  synchronously inside an already-`@MainActor` `Task { }` body (the View's
  own async subscribe task, not a new isolation context);
  `SettingsScreen`'s "Upgrade to Earshot Plus" button and `DataSettingsView`
  's `onCapSkipped: { showPaywall = true }` closure are both synchronous,
  non-`Task`-wrapped mutations of `@State` directly inside `View` body/
  button-action/closure contexts — no `await`, no boundary crossing
  possible.
- [x] @Model/SwiftData actor boundary: PASS — grepped the full diff for
  `Podcast`/`Episode`/any `@Model` type; none appears anywhere in
  `PaywallView.swift`, `PaywallViewModel.swift`, or `PaywallLogic.swift`.
  This is purchase-flow code operating entirely on StoreKit `Product`/
  `Transaction` types and the StoreKit-free `PaywallProductDisplay`
  mirror — no SwiftData object of any kind is constructed, read, or passed
  across an actor boundary by this diff.
- [ ] AVAudioSession main actor: N/A — this diff touches no audio code.
- [ ] Combine publishers: N/A — no Combine in this diff; `PaywallViewModel`
  uses `@Observable`, not `ObservableObject`/`@Published`.
- [x] nonisolated functions: PASS — no `nonisolated` keyword appears
  anywhere in the diff. `PaywallLogic`'s static functions
  (`bestValueBadge(monthly:yearly:)`, `accessibilityLabel(for:)`,
  `subscriptionDisclosure(for:)`, `lifetimeDisclosure(for:)`,
  `inProgressAnnouncement(displayName:)`, `announcement(for:)`) are pure,
  free-standing static functions on a non-isolated `enum` with no stored
  state — correctly need no explicit `nonisolated` marker because the
  enclosing type was never actor-isolated in the first place (same
  reasoning `PodcastCapPolicy` was credited for in the #635 gate).
  `OPMLFileImporter.importFile(...)`'s new `onCapSkipped` parameter is
  correctly typed `(@MainActor @Sendable () -> Void)?` rather than plain
  `nonisolated` `() -> Void` — since `OPMLFileImporter` itself is
  `@MainActor` and `onCapSkipped?()` is invoked synchronously in that same
  context (line 107, inside the `if outcome.skippedForCapCount > 0`
  branch, no `await`), the `@MainActor` annotation on the closure type is
  correct and sufficient; it documents the isolation contract explicitly
  rather than relying on inference, and matches the doc comment's claim
  that it "fires once, synchronously on the main actor."
- [x] Structured concurrency: PASS — grepped the entire diff for
  `Task.detached`: zero occurrences. Every `Task { }` introduced or touched
  by this diff (`PaywallView.swift` lines 107 and 232;
  `PodcastPreviewView.swift`'s pre-existing `toggleFollow()` task, whose
  catch block this diff only adds two lines to; `SearchView.swift`'s
  pre-existing `subscribe(_:)` task, same shape; `DataSettingsView.swift`
  line 98's pre-existing OPML-import task, whose call this diff only adds
  a trailing closure argument to) is a plain, unstored, non-escaping
  `Task { }` that inherits the calling `@MainActor` context — none of them
  are retained past their triggering action, none race each other. Cross-
  referenced against the security gate's finding
  (`PaywallViewModel.purchase`'s `guard purchasingProduct == nil` at line
  97): this guard is what actually prevents a double-tap from spawning a
  second overlapping `product.purchase()` `Task` — the `Task {}` at
  `PaywallView.swift:232` itself has no guard of its own, by design, since
  the view is also `.disabled(model.purchasingProduct != nil)` while a
  purchase is in flight (belt-and-suspenders, matches the security gate's
  three-layer analysis). No dangling/leaked task: a second tap either
  can't reach the button (disabled) or, if it somehow did, the view-model
  guard makes the resulting `Task` an immediate no-op that returns without
  mutating any state — never a redundant concurrent purchase attempt.
- [x] Global state: PASS — no new global or static `var` anywhere in the
  diff. `EarshotPlusProduct` (pre-existing, unchanged) is a `String,
  CaseIterable, Sendable` enum with no stored mutable state.
  `PaywallProductDisplay`/`PaywallSubscriptionPeriod`/
  `PaywallPurchaseOutcome`/`PaywallLogic.Announcement` are all instance
  values, never `static var`. `PaywallLogic.cancelledAnnouncement` is
  `static let` (immutable `Announcement` value) — safe.
- [x] Swift 6 build clean: PASS — Debug build under the real project
  settings (`SWIFT_VERSION: "5.0"`, `SWIFT_STRICT_CONCURRENCY: minimal`) on
  the pinned simulator `39E0DF74-2312-4D8B-8612-05AAD43EB8B5` (`xcodebuild`
  run from `EarshotSwift/`, no `cd` to repo root): **BUILD SUCCEEDED**, 0
  errors, 0 warnings.

Secondary informational check (forced `SWIFT_STRICT_CONCURRENCY=complete`
override, not the shipping config), same simulator: **BUILD FAILED**, but
with exactly the same documented pre-existing baseline signature as prior
gates on this repo — `QueueScreen.swift:100` compiler-crash diagnostic
(`failed to produce diagnostic for expression`) and `KeyPath`-not-`Sendable`
macro-expansion warnings (`AppSettingsStore.swift`'s `@Query`/`#Predicate`
expansions, `QueueRepository.swift:345`). Grepped the full build log for
every file touched by this diff (`PaywallView.swift`, `PaywallViewModel
.swift`, `PaywallLogic.swift`, `SearchView.swift`, `PodcastPreviewView
.swift`, `OPMLFileImporter.swift`, `DataSettingsView.swift`,
`SettingsScreen.swift`) by name — zero warnings, zero errors from any of
them, confirming this diff introduces no new concurrency issue under the
stricter mode. One warning pair not previously itemized in the documented
baseline set turned up (`AppearanceSettings.swift:119-120`, main-actor-
isolated property mutation from a nonisolated context) — confirmed via
`git diff swift...HEAD -- .../AppearanceSettings.swift` that this file is
completely untouched by #632, so regardless of whether it's new baseline
drift or simply undocumented until now, it is not this diff's problem; not
attributing it to #632.

New agents created: none — no CarPlay or background-URLSession-delegate
pattern encountered in this diff to warrant one.

Overall: PASS

## Accessibility Review — Issue #632

earshot-accessibility review complete. Issue #632 (Earshot Plus: paywall /
upgrade screen). Reviewed at HEAD `df0bf01` (domain `a166f72` + testing-gate
`60d9c47` + security-gate `56b4cd0` + swift6-gate `df0bf01`, all docs-only
after the domain commit) in isolated worktree `earshot-wt-632`, branch
`feat/issue-632-paywall`, on the pinned simulator
`39E0DF74-2312-4D8B-8612-05AAD43EB8B5`. No fix required — read
`PaywallView.swift`, `PaywallViewModel.swift`, `PaywallLogic.swift`,
`SettingsScreen.swift`, `SearchView.swift`, `PodcastPreviewView.swift`, and
`DataSettingsView.swift` in full against all 13 of Michael's hard
requirements individually, not just the domain agent's doc-comment claims.

Checklist:
- [x] No dark patterns: PASS. Grepped every changed file for
  hurry/limited-time/spots-left/today-only/act-now/expires/offer-ends
  language — zero hits. Header, disclosure, footer, and all four
  announcement strings are plain factual statements ("Follow unlimited
  podcasts...", "Auto-renews unless cancelled. Cancel anytime in Settings or
  the App Store.", "Manage or cancel a subscription anytime in Settings,
  under your Apple ID."). No countdown, no pre-checked upsell, no guilt copy
  on any path including dismiss.
- [x] Close button label: PASS. Verified the literal string at
  `PaywallView.swift:75` — `.accessibilityLabel("Close")` on the toolbar
  `Button` wrapping `Image(systemName: "xmark")` — an explicit word, not
  shape recognition of the glyph. Standard `.topBarLeading` placement,
  matches `NowPlayingScreen`/`AddFeedView`'s existing Close-button
  convention in this codebase.
- [x] Price/terms visible before purchase button reachable: PASS, verified
  by tracing `productCard(_:badge:)`'s actual `VStack` order
  (`PaywallView.swift:200-249`): name+price `HStack` → optional badge →
  `Text(subscriptionDisclosure/lifetimeDisclosure)` → `Button`. The
  disclosure `Text` is a standalone always-visible element, never a button
  hint or inside a `DisclosureGroup`, and sits both visually and in default
  top-to-bottom VoiceOver order strictly before the purchase `Button` in
  every one of the three cards.
- [x] Monthly/Yearly/Lifetime equal weight: PASS. Diffed the SwiftUI
  modifiers applied to all three `productCard` calls
  (`PaywallView.swift:187-197`) — identical `.font(.title3.weight
  (.semibold))` name/price, identical `.borderedProminent`/
  `.controlSize(.large)` button, identical card padding/background. The only
  difference is Yearly's optional `Label(badge, systemImage: "star.fill")`
  at `.caption.weight(.semibold)` — a small factual line below the
  name/price row, not a size/color/muting change to Monthly or Lifetime.
  Badge text itself is honestly computed (`PaywallLogic.bestValueBadge`
  rounds down, returns `nil` on any non-positive or non-saving case) — not
  hardcoded marketing copy.
- [x] Combined price+period+name VoiceOver label: PASS. Verified the exact
  composed strings in `PaywallLogic.accessibilityLabel(for:)`
  (`PaywallLogic.swift:125-130`) — e.g. "Earshot Plus Monthly, $2.99 per
  month" for subscriptions, "Earshot Plus Lifetime, $49.00, one-time
  purchase" for the non-consumable — and confirmed it's wired as
  `.accessibilityLabel(...)` directly on the purchase `Button` at
  `PaywallView.swift:243-245` (swapped for "Purchasing {name}" while that
  specific product is mid-purchase), not left as default fragmented
  visible-only text.
- [x] Focus order: PASS, traced myself top-to-bottom rather than trusting
  the file's doc comment. `loadedView`'s `VStack` is header (title,
  `.accessibilityAddTraits(.isHeader)`, then subtitle) → outcome banner (if
  `model.outcome != nil`) → Monthly card → Yearly card → Lifetime card →
  footer note. Grepped the file for `accessibilitySortPriority` and
  `accessibilityElement(children:` — the only `children:` usage is
  `.combine` on the loading/failed/banner views (merges an icon+text pair
  into one node, does not reorder anything) and none of it changes reading
  order. No override needed since default `VStack` order already matches
  intended order. One minor observation, not a defect: `productCard`'s
  name `Text` and price `Text` are separate sibling VoiceOver stops (not
  merged via `.accessibilityElement(children: .combine)`), so a linear
  swipe-through hears name, then price, then (for Yearly) the badge, then
  the disclosure, then the button restating name+price+cadence as one
  phrase. This is mild restatement, not fragmentation — the button's label
  is still the single authoritative combined phrase required by #632, and
  VoiceOver users using rotor "buttons" navigation (which most paywall users
  purchasing by button would use) skip straight to it. Not fixing; flagging
  only because the review must justify why this wasn't treated as a
  fragmentation defect.
- [x] State announcements distinct + correct assertiveness: PASS. Verified
  all four/five strings and their `assertive:` flags directly in
  `PaywallLogic.swift`: in-progress "Purchasing {name}." (`assertive:
  false`), success "Earshot Plus unlocked." (`assertive: true`), pending
  "Purchase pending approval. You'll be notified once it's approved."
  (`assertive: true`), failed "Purchase failed. Check your connection and
  try again." (`assertive: true`), cancelled "Purchase cancelled."
  (`assertive: false`). All five strings are lexically distinct — a user
  can tell cancellation from failure from the wording alone. Checked the
  assertiveness choices against `Announcer.announce`'s actual implementation
  (`assertive: false` sets `.accessibilitySpeechQueueAnnouncement: true`,
  i.e. queues behind current speech; `assertive: true` omits it, i.e.
  interrupts): in-progress and cancelled are correctly polite (reassurance/
  neutral non-events that shouldn't interrupt), the three settled outcomes
  are correctly assertive (a result the user is actively waiting on).
  Nothing backwards — this is the exact policy Michael's brief asked me to
  check for, already implemented correctly.
- [x] No drag-only gestures: PASS. Sheet dismiss is an explicit toolbar
  Close button (see above), reachable and functional in every state — see
  the dismissal trace below. No reorderable list or drag gesture exists on
  this screen at all.
- [x] No unlabeled images: PASS. `Image(systemName: "xmark")` is labeled via
  the parent Button's explicit `.accessibilityLabel("Close")`.
  `Image(systemName: "exclamationmark.triangle.fill")`,
  `"checkmark.circle.fill"`, and `"clock.fill"` in `failedView`/
  `outcomeBanner` are each inside a SwiftUI `Label`, which VoiceOver already
  presents as one element keyed to the title text (icon not separately
  exposed) — no `ExcludeSemantics` equivalent needed, this is `Label`'s
  built-in behavior. `Image(systemName: "star.fill")` in the badge `Label`
  same treatment. No bare `Image(systemName:)` outside a `Label` or an
  explicitly-labeled `Button` exists anywhere in the diff.
- [x] Dynamic Type: PASS. Grepped `PaywallView.swift` for
  `font(.system(size:`, `.frame(height:`, and `lineLimit(1)` — zero hits.
  All text uses semantic styles (`.largeTitle`, `.title3`, `.body`,
  `.footnote`, `.caption`, `.headline`). The one `lineLimit(2)` (product
  name) is the permitted cosmetic-truncation ceiling, not `lineLimit(1)`.
  No fixed-height container wraps any text.
- [x] Touch targets: PASS. Purchase buttons explicit
  `.frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)` (44pt).
  "Try Again" explicit `.frame(minHeight: Spacing.minTouchTarget)`. Close
  button has no explicit frame, consistent with every other toolbar Close
  button already shipped in this codebase (`NowPlayingScreen.swift`,
  `AddFeedView.swift`) — system nav-bar toolbar buttons meet 44pt via
  standard chrome, not a new gap introduced by this diff.
- [x] Reduce Motion: N/A. Grepped the whole `Features/Monetization/`
  directory for `Motion.`, `withAnimation`, and `ViewThatFits` — zero hits.
  No animation or transition was introduced by this diff to guard.
- [x] Contrast / color independence: PASS. All banner/error states use
  semantic `AppColor` tokens (`AppColor.played`/`.error`/`.secondaryText`/
  `.accent`, all backed by system dynamic colors, not hardcoded hex) paired
  with an icon and explanatory text — success/pending/failed/badge are all
  icon+text+color, never color alone.
- [x] Settings "Upgrade to Earshot Plus" row: PASS. Confirmed
  `!entitlements.isEntitled` correctly gates the row
  (`SettingsScreen.swift:22`) and "Restore Purchases" stays visible either
  way (documented judgment call, reasonable — it's the reinstall/new-device
  recovery path). The row itself is a plain `Button` + `Text` with a factual
  hint ("Unlimited podcast subscriptions, no free-tier cap") — no badge,
  icon, color treatment, or copy that reads as a promotional banner; it's
  the plainest row in the whole Earshot Plus section. On the
  disappear-after-purchase question: no new `.onChange`/announcement was
  added for this row's conditional visibility, and I confirmed that's the
  right call rather than a gap — unlike #635's fix (an entitlement lapsing
  silently on ANOTHER screen while a user isn't looking, which genuinely
  needed a fresh announcement), a purchase completed via this exact row
  already spoke "Earshot Plus unlocked." inside the still-open paywall sheet
  before the user explicitly taps Close, so there is no silent state change
  this user hasn't already been told about. The one edge case worth naming:
  if VoiceOver's post-dismiss focus return targets the "Upgrade to Earshot
  Plus" button specifically and it has since vanished, UIKit's own
  presentation-controller fallback (not something this diff controls or
  regresses) picks the nearest remaining accessible element — standard,
  widely-shipped iOS behavior, not a new defect.
- [x] Dismissal friction/guilt copy: PASS, traced `dismiss()`'s call site
  directly. The Close button's `Button { dismiss() }` at
  `PaywallView.swift:68-70` is a toolbar item, never wrapped in the
  `loadedView` `ScrollView`'s `.disabled(model.purchasingProduct != nil)`
  modifier and has no guard/confirmation of its own — it is reachable and
  fires identically at idle, mid-purchase-loading (`purchasingProduct !=
  nil`), post-success (`outcome == .success`), and post-failure (`outcome
  == .failed`). No dialog, no delay, no re-prompt, no copy change on any of
  these paths. A successful purchase deliberately does not auto-dismiss
  (per the file's own doc comment) so a VoiceOver user is never caught by a
  timed disappearance mid-announcement, but the user's own explicit Close
  tap always works immediately in every state.

Verification: `xcodebuild build` on simulator
`39E0DF74-2312-4D8B-8612-05AAD43EB8B5` (run from `EarshotSwift/`, no `cd` to
repo root) — **BUILD SUCCEEDED**. `-only-testing:EarshotTests/
PaywallLogicTests` — 20 tests, 0 failures (covers the pure copy/
announcement/badge logic this review checked strings against).
`-only-testing:EarshotTests/PaywallViewModelTests` reproduces the same
pre-existing `SKInternalErrorDomain Code=3` headless-CI `SKTestSession`
limitation already documented for #631/#633/#632's own testing gate above —
unrelated to this review, not a regression. Confirmed tab bar order in
`RootView.swift:357` reads `case inbox, queue, library, downloads, settings`
— matches the required order exactly (this issue didn't touch `RootView`,
checked directly rather than assumed). Migration sheet (`IS_BETA_BUILD`):
N/A, untouched by this diff.

`git status --short` clean before and after this review — no code changes,
docs-only.

## Security Review — Issue #668

earshot-security review complete. Issue #668 (BUG: no way to add a podcast
to inbox with "Opt-in podcasts only" enabled). Branch
`fix/issue-668-opt-in-inbox`, reviewed at commit `8700b49` on top of `swift`
tip `c9bdf79`, in isolated worktree `earshot-wt-668`. No fixes needed — PASS
on first pass.

Checklist:
- [x] Force-unwraps: PASS — none found. Every `!` in the diff is boolean
  negation (`!(podcast.notificationEnabled ?? false)`, `!podcasts.isEmpty`,
  `!author.isEmpty`, `!notifications.isEmpty`). The `try? XCTUnwrap(...)` /
  `firstOn!` lines in `QuickActionBuildersTests.swift` are pre-existing,
  confirmed untouched by `git diff c9bdf79..HEAD` — out of scope for this
  diff.
- [x] Silent try?: PASS — none introduced.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new `Task {}`, `.sink`, `addObserver`, or
  `Timer` closures. The new `.toggleInboxInclude` case in
  `buildPodcastActions` and the new `toggleInboxInclude(_:)` helper in
  `SubscriptionsView` are synchronous closures capturing a `Podcast`
  (reference type, owned by the caller) and `ModelContext`, matching the
  adjacent `.toggleAutoQueue`/`.toggleNotifications` cases and the existing
  `unsubscribe(_:)` method exactly.
- [x] @MainActor: PASS — `buildPodcastActions` keeps its existing
  `@MainActor` annotation; the new case does a direct synchronous `@Model`
  write (`podcast.inboxIncluded.toggle()`). The new swipe-action button and
  the new `Toggle(isOn: $podcast.inboxIncluded)` binding both run as
  main-thread SwiftUI event handlers — no background `Task`, no `ModelActor`
  crossing.
- [ ] IS_BETA_BUILD Release build: N/A — no migration-related files changed
  (`Podcast.inboxIncluded` and `StoreMigration` untouched; this only adds UI
  writing an existing field). Ran a Debug build instead as a general
  compile gate.
- [ ] Entitlements: N/A — no entitlements/project.yml changes.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new `Error` types introduced. The one save
  path routes through the existing `saveQuickAction(_:_:)` helper
  (`EpisodeActionsBuilder.swift:131-139`), which already does `do`/`catch` +
  `AppLog.quickActions.error(...)`.
- [x] AppLog coverage: PASS — no new catch blocks added by this diff; the
  shared `saveQuickAction` catch (pre-existing) covers both new call sites.

Additional verification performed:
- Confirmed no other exhaustive `switch` over `PodcastAction` exists outside
  `PodcastActionsBuilder.swift` that could have silently missed the new
  `.toggleInboxInclude` case (checked `QuickActionRepository.swift`,
  `QuickActionStore.swift`, `QuickActionsSettingsView.swift` — all only
  reference `PodcastAction.allCases`/arrays).
- `xcodebuild build` (scheme Earshot, Debug, iPhone 17 sim) — BUILD
  SUCCEEDED.
- `xcodebuild build-for-testing` — TEST BUILD SUCCEEDED.
- `-only-testing:EarshotTests/QuickActionBuildersTests
  -only-testing:EarshotTests/DownloadsInboxLogicTests` — 60 tests, 0
  failures, including the 6 new #668 tests (3 `InboxRepository` opt-in
  inclusion cases, `testDefaultPodcastActionsIncludesToggleInboxInclude`,
  `testToggleInboxIncludeLabelReflectsState`,
  `testToggleInboxIncludeRunFlipsAndPersists`, plus the two rotor-filter
  predicate tests).

Non-blocking observation (pre-existing pattern, not introduced by this
diff): the new swipe action and rotor toggle don't check
`readOnlyPodcastIDs`/free-tier entitlement gating before writing
`inboxIncluded` — but neither do the adjacent `.toggleAutoQueue`/
`.toggleNotifications` actions this mirrors, so this is consistent, not a
regression. Worth a follow-up issue if per-podcast settings should be
entitlement-gated while read-only, but out of scope for #668.

`git status --short` clean before and after review; no fix commit needed.

New agents created: none.
Feature suggestions identified: none this review.

Overall: PASS

## Issue #632 Closed — Earshot Plus paywall / upgrade screen

Implemented by earshot-ui. Gates: earshot-testing, earshot-security,
earshot-swift6, earshot-accessibility — all PASS (see sections above). Michael
reviewed the paywall copy/design/VoiceOver flow from text description (no
device screenshots) per #632's process requirement and approved, contingent
on one fix.

**Price-sync follow-up (post-approval, before merge):** the local
`.storekit` test fixtures used flat $20.00/yr and $49.00 lifetime, which
didn't match the real App Store Connect tiers ($19.99/yr, $49.99 lifetime;
monthly $2.99 unaffected). Fixed in commit `78cf71e` on the same branch:
`Configuration.storekit`, `ConfigurationMissingProduct.storekit` (the #631
missing-product fixture), `EarshotPlusProduct.swift` doc comments, and every
hardcoded price literal in `PaywallLogicTests.swift`/`PaywallViewModelTests.swift`.
The "Best value — about 44% off monthly" badge math is unchanged (19.99/12
still floors to 44%). Confirmed no hardcoded fallback price string exists
anywhere in the paywall UI/logic — `PaywallView`/`PaywallViewModel` read
`Product.displayPrice` directly, and `ProductCatalogService` throws
`CatalogError.productsNotFound` on a missing product rather than falling
back to a wrong number.

Branch was rebased onto `swift` past #666 (tip jar) before merge — two
benign parallel-addition conflicts (`CHANGELOG.md`, `project.pbxproj`
Monetization group children) resolved by keeping both sides; no conflicts in
`SettingsScreen.swift`/`DataSettingsView.swift` (auto-merged cleanly).

Test count: 1302 executed (1254 baseline + 21 from #666 + 27 from #632: 20
`PaywallLogicTests` + 3 `PaywallViewModelTests` + 4 `OPMLFileImporterTests`).
11 unique pre-existing failures (`PaywallViewModelTests` x3,
`ProductCatalogServiceTests` x8), all the documented `SKInternalErrorDomain
Code=3` headless-CI StoreKitTest-sandbox limitation (needs Xcode GUI or
device) — not a regression, tracked against #631/#633/#634/#635/#632
repeatedly. Release build clean.

Merged via PR #667 (squash), issue closed. Next priority-order item per
Fix/Flutter-parity queue: continue down the Flutter parity queue (Export
audio file action, Stop after this episode, Inbox limits per-podcast, Mark
as played from player, Group move actions in queue, OPML share sheet, Quick
Actions rotor order) — see "Work Priority Order" in CLAUDE.md.

**Housekeeping note:** this file is ~4500 lines, well past the 400-line
target. Archiving completed sections to `docs/phases/swiftui/` is overdue
and out of scope for this narrow session — flagging for the next planning
session to do a dedicated archive pass rather than mixing it into an
unrelated fix.

## Security Review — Issue #671

earshot-security review complete. Issue #671 (mirror-image companion to
#668: UI to exclude a podcast from the inbox in normal, non-opt-in mode).
Branch `feat/issue-671-exclude-inbox`, reviewed at commit `0c2d47c` on top of
`swift` tip (via merged #668, commit `9062882`), in isolated worktree
`earshot-wt-671`. No fixes needed — PASS on first pass.

Checklist:
- [x] Force-unwraps: PASS — none found. Every `!` in the four changed
  non-test source files is boolean negation (`!(podcast.notificationEnabled
  ?? false)`, `!podcasts.isEmpty`, `!$0`, `!author.isEmpty`,
  `!settings.inboxOptInOnly`, `!notifications.isEmpty`).
- [x] Silent try?: PASS — none introduced.
- [x] fatalError: PASS — none found.
- [x] Retain cycles: PASS — no new `Task {}`, `.sink`, `addObserver`, or
  `Timer` closures. The new `.toggleInboxExclude` case in
  `buildPodcastActions` and the new `toggleInboxExclude(_:)` helper in
  `SubscriptionsView` are synchronous closures capturing a `Podcast`
  (reference type, owned by the caller) and `ModelContext`, matching
  `.toggleInboxInclude` (#668) and the adjacent `.toggleAutoQueue`/
  `.toggleNotifications` cases exactly.
- [x] @MainActor: PASS — `buildPodcastActions` keeps its existing
  `@MainActor` annotation; the new case does a direct synchronous `@Model`
  write (`podcast.inboxExcluded.toggle()`). The new swipe-action button and
  the new `Toggle(isOn: $podcast.inboxExcluded)` binding both run as
  main-thread SwiftUI event handlers — no background `Task`, no
  `ModelActor` crossing.
- [ ] IS_BETA_BUILD Release build: N/A — no migration-related files changed
  (`Podcast.inboxExcluded` and `EarshotSchema`/`StoreMigration` confirmed
  untouched by `git diff 9062882..0c2d47c`; this diff only adds UI writing a
  pre-existing, already-enforced field). Ran a Debug build instead as a
  general compile gate.
- [ ] Entitlements: N/A — confirmed zero-line diff on
  `Earshot.entitlements`/`project.yml` between `9062882..0c2d47c`.
- [x] No secrets: PASS — none found.
- [x] Error types: PASS — no new `Error` types introduced. Both new save
  paths route through the existing `saveQuickAction(_:_:)` helper, which
  already does `do`/`catch` + `AppLog` logging.
- [x] AppLog coverage: PASS — no new catch blocks added by this diff; the
  shared `saveQuickAction` catch (pre-existing) covers both new call sites.

Additional verification performed:
- Special focus per the task brief: the `rotorActions(for:)` restructuring
  in `SubscriptionsView.swift` (old single-condition `&&`/`||` expression
  replaced with a `guard`+`if` cascade) was diffed line-by-line against the
  #668 behavior it replaces. For `.toggleInboxInclude` the new cascade
  (`if $0 == .toggleInboxInclude { return settings.inboxOptInOnly }`) is
  logically identical to the old `($0 != .toggleInboxInclude ||
  settings.inboxOptInOnly)` term — verified by truth table, not just
  inspection. No regression to the #668 opt-in-mode filter. The new
  `.toggleInboxExclude` arm is the exact mirror. Confirmed with the two new
  predicate-isolation tests
  (`testToggleInboxExcludeDroppedFromOrderWhenOptInOn`,
  `testToggleInboxExcludeKeptInOrderWhenOptInOff`) plus the two pre-existing
  #668 predicate tests, all passing.
- Confirmed `Podcast.inboxExcluded` and its `InboxRepository`/`InboxLogic`
  enforcement are pre-existing and untouched by this diff (`Data/Models/
  Podcast.swift`, `Data/Persistence/EarshotSchema.swift` both show a
  zero-line diff between `9062882..0c2d47c`) — this issue is UI-only, as
  the implementing agent stated.
- Confirmed no other exhaustive `switch` over `PodcastAction` exists outside
  `PodcastActionsBuilder.swift` that could have silently missed the new
  `.toggleInboxExclude` case (`QuickActionRepository.swift`,
  `QuickActionStore.swift`, `QuickActionsSettingsView.swift` all only
  reference `PodcastAction.allCases`/arrays) — same set #668 verified.
- `xcodebuild build` (scheme Earshot, Debug, iPhone 17 sim
  `58857CDF-1560-410D-8F46-7381F7ADF48A`) — BUILD SUCCEEDED.
- `xcodebuild test -only-testing:EarshotTests/QuickActionBuildersTests
  -only-testing:EarshotTests/DownloadsInboxLogicTests
  -only-testing:EarshotTests/PodcastSettingsViewTests` — 109 tests, 0
  failures, including all 10 new #671 tests (3 `InboxRepository`
  normal-mode exclusion cases, 4 `PodcastSettingsViewTests` toggle cases,
  and 3 `QuickActionBuildersTests` builder/predicate cases — plus 2 more
  predicate tests counted above).

`git status --short` clean before and after review (aside from the known
pre-existing unrelated `.dart` formatting noise from #660, left untouched);
no fix commit needed.

New agents created: none.
Feature suggestions identified: none this review.

## Swift 6 Concurrency Review — Issue #671

earshot-swift6 review complete. Issue #671 (mirror-image companion to #668:
UI to exclude a podcast from the inbox in normal, non-opt-in mode). Branch
`feat/issue-671-exclude-inbox`, reviewed at commit `86988e9` in isolated
worktree `earshot-wt-671`. No fixes needed — PASS on first pass, no code
changes.

Concurrency mode: `SWIFT_STRICT_CONCURRENCY: minimal` / `SWIFT_VERSION: 5.0`
(project baseline — Swift 6 not yet flipped on for this target). Ran an
informational `SWIFT_STRICT_CONCURRENCY=complete` override build on top of
the real-settings build, matching the #668/#639/#631 precedent.

Checklist:
- [x] Sendable conformance: PASS — no new `Sendable` surface introduced. The
  new `.toggleInboxExclude` case's closure captures only `podcast` (a
  `@Model` reference type) and `context` (`ModelContext`), never crossing an
  actor boundary, matching every other case in `buildPodcastActions`.
- [x] Actor isolation: PASS — `buildPodcastActions` stays `@MainActor` for
  the whole function (unchanged). `SubscriptionsView` and
  `PodcastSettingsView` are SwiftUI `View`s (implicit `@MainActor`). The new
  `toggleInboxExclude(_:)` helper in `SubscriptionsView.swift` and the new
  switch arm in `PodcastActionsBuilder.swift` both do a synchronous
  `podcast.inboxExcluded.toggle()` write, `saveQuickAction(context, ...)`
  (itself `@MainActor`), and `Announcer.announce(...)` (itself `@MainActor`)
  — identical isolation shape to the pre-existing `.toggleInboxInclude`/
  `toggleInboxInclude(_:)` pair from #668. Verified `saveQuickAction`
  (`EpisodeActionsBuilder.swift:132`) and `Announcer.announce`
  (`Announcer.swift:11`) are both explicitly `@MainActor`.
- [x] @Model/SwiftData actor boundary: PASS — `Podcast` (`@Model`, confirmed
  at `Data/Models/Podcast.swift:5-6`) never crosses an actor boundary in this
  diff. No `PersistentIdentifier` re-fetch pattern needed because the
  `@Model` instance is only ever touched synchronously on the main actor,
  same as every other Quick Action toggle in the file.
- [x] AVAudioSession main actor: N/A — no audio session code touched.
- [x] Combine publishers: N/A — no Combine/`@Published` code touched;
  `PodcastSettingsView`'s new `Toggle(isOn: $podcast.inboxExcluded)` uses
  `@Bindable` (SwiftData's Observation-based binding), not Combine.
- [x] nonisolated functions: PASS — used correctly; nothing in this diff
  needed a `nonisolated` marker (no pure/computation-only helper added).
- [x] Structured concurrency: PASS — `Task.detached` not used anywhere in
  the diff. No new `Task {}` of any kind — both new call sites are plain
  synchronous closures invoked directly from SwiftUI button/rotor actions.
- [x] Global state: PASS — none found. No new global or static `var`.
- [~] Swift 6 build clean: PASS for this diff specifically, project overall
  not yet Swift 6.
  - Real-settings build (`SWIFT_VERSION 5.0`, `SWIFT_STRICT_CONCURRENCY
    minimal`, scheme Earshot, iPhone 17 Pro sim
    `58857CDF-1560-410D-8F46-7381F7ADF48A`) — **BUILD SUCCEEDED**.
  - Informational `SWIFT_STRICT_CONCURRENCY=complete` override build on the
    same destination — **BUILD FAILED**, but grepping the full log for
    `error:`/`warning:` on the four changed source files (`PodcastAction.
    swift`, `PodcastActionsBuilder.swift`, `SubscriptionsView.swift`,
    `PodcastSettingsView.swift`) returns zero matches — no new concurrency
    diagnostic attributable to this diff. The failure is the same
    pre-existing baseline noise documented on #639/#631/#656: the
    `QueueScreen.swift:100` "failed to produce diagnostic for expression"
    compiler-internal crash (tied to the in-progress #390 Swift 6
    migration), `DownloadManager.swift:122` non-Sendable-`Episode`-parameter
    warning, and widespread `@Query`/`#Predicate` macro-expansion
    `KeyPath<...>: Sendable` warnings across `AppSettingsStore.swift`,
    `SubscriptionRepository.swift`, `QueueRepository.swift`, and
    `QuickActionRepository.swift`. Confirmed all six of those files have a
    zero-line diff between `9062882..HEAD` (`git diff --stat`), so none of
    that noise originates in this change.

New agents created: none.
Overall: PASS

Overall: PASS

## Accessibility Review — Issue #671

earshot-accessibility review complete. Issue #671 (mirror-image companion to
#668: UI to exclude a podcast from the inbox in normal, non-opt-in mode).
Branch `feat/issue-671-exclude-inbox`, reviewed at commit `26b4f80` in
isolated worktree `earshot-wt-671`. No fixes needed — PASS on first pass, no
code changes.

VoiceOver:
- [x] Labels/roles: PASS — the new `.toggleInboxExclude` rotor action, the
  leading-edge swipe `Button`, and the `Toggle` all use state-derived,
  unambiguous labels ("Exclude from Inbox" / "Include in Inbox") that name
  the action and its target without relying on surrounding context. No role
  words baked into the label text (SwiftUI's native `Toggle`/`Button`/rotor
  action supply "switch"/"button" automatically).
- [x] Hints: PASS — none added, none needed. The label alone states the
  outcome plainly for both the swipe action and the rotor action, matching
  #668's `.toggleInboxInclude` precedent (no hint there either). The
  mandatory OPML-export hint requirement is not applicable to this diff.
- [x] No empty accessibilityValue: PASS — none introduced. This diff never
  sets `.accessibilityValue` at all; the settings `Toggle` gets its On/Off
  value from the native control for free.
- [x] Tab bar order: N/A — `RootView.swift` (verified directly, confirmed
  zero-line diff between `9062882..HEAD`) is untouched by this issue; tab
  order is unaffected.
- [x] Migration sheet (IS_BETA_BUILD): N/A — no migration-sheet files
  touched; confirmed via `git diff --stat` (only `PodcastAction.swift`,
  `PodcastActionsBuilder.swift`, `PodcastSettingsView.swift`,
  `SubscriptionsView.swift`, `CHANGELOG.md`, and three test files changed).
- [x] No drag-only gestures: PASS — the new swipe action is `.swipeActions`
  with a `Button`, which SwiftUI already exposes as an ordinary activatable
  action in the VoiceOver Actions rotor (no drag required to reach it from
  VoiceOver) — same mechanism #668's opt-in swipe action uses, already
  verified working. The mirrored rotor action
  (`buildPodcastActions`/`.toggleInboxExclude`) is the primary
  VoiceOver-native path regardless, so the swipe gesture itself is never the
  only way to reach this action.
- [x] Rotor actions: PASS — `rotorActions(for:)` in `SubscriptionsView.swift`
  was restructured from a single boolean expression into a `guard`+`if`
  cascade so it can hold both the #668 opt-in-mode filter
  (`.toggleInboxInclude` kept only when `settings.inboxOptInOnly`) and the
  new #671 normal-mode filter (`.toggleInboxExclude` kept only when
  `!settings.inboxOptInOnly`) without either one leaking into the wrong
  mode. Verified by truth table against the old expression (not just
  inspection) and confirmed against the dedicated predicate-isolation tests:
  `testToggleInboxExcludeDroppedFromOrderWhenOptInOn`,
  `testToggleInboxExcludeKeptInOrderWhenOptInOff`, plus the two pre-existing
  #668 predicate tests
  (`testToggleInboxIncludeDroppedFromOrderWhenOptInOff`,
  `testToggleInboxIncludeKeptInOrderWhenOptInOn`) — all four pass. The
  user's configured Quick Actions order still drives rotor action order;
  this is a display-time filter only, the persisted order is untouched.
- [x] Focus management: PASS/N/A — this diff adds no modal, sheet, screen
  push, or list-collapsing delete; it's a same-row state toggle (rotor
  action, swipe button, and settings `Toggle`), so none of the
  dismiss-returns-focus / push-lands-on-heading / paged-TabView /
  deferred-post-delete-focus patterns apply. VoiceOver stays on the same row
  or the same settings `Toggle` after activation in all three paths, which
  is correct here (no navigation occurred).
- [x] State announcements: PASS — the rotor action and swipe action both
  call `Announcer.announce("Excluded from inbox" / "Included in inbox")`
  with no `assertive:` argument, i.e. `assertive: false` (confirmed the
  `Announcer.announce` signature at
  `Core/Accessibility/Announcer.swift:12` defaults `assertive` to `false`),
  identical to `.toggleInboxInclude`'s `Announcer.announce("Added to inbox"
  / "Removed from inbox")` call from #668. The settings-screen `Toggle`
  path deliberately does **not** call `Announcer.announce` at all — it
  relies on the native SwiftUI `Toggle`'s own On/Off announcement, exactly
  matching the `autoQueue`/opt-in-mode `Toggle` precedent and the "Adjustable
  value pickers" project lesson (never announce over a control that already
  self-announces). No double-announcement or assertive/interrupting
  announcement found anywhere in this diff.

Dynamic Type:
- [x] Semantic fonts only: PASS — no `Font` or `.font(.system(size:))` of
  any kind introduced by this diff.
- [x] No lineLimit(1) on essential content: PASS — none introduced.
- [x] No fixed-height text containers: PASS — none introduced; the new
  `Toggle` and swipe `Button` both use standard List/`.swipeActions` sizing.
- [x] ViewThatFits on Now Playing bar: N/A — Now Playing bar untouched.

Touch targets (44pt minimum): PASS — no custom-frame interactive elements
introduced. The new `Toggle` is a standard `List` row toggle and the new
swipe action is a standard `.swipeActions` `Button`; both get their touch
target from the system List/swipe-action chrome, same as every other
row/toggle in these two files (including the #668 toggle/swipe this diff
mirrors, which already passed this exact check).

Motion (Reduce Motion guard): N/A — no animation, transition, or
`withAnimation` call introduced by this diff.

Contrast (WCAG 2.2 AA): PASS — no new colors introduced; the swipe action
uses `.tint(.accentColor)` (the existing semantic accent color, same as
#668's opt-in swipe action), and the settings `Toggle` uses the system
toggle appearance. No raw hex or `Color(red:green:blue:)` literals.

Color independence: PASS — the swipe action pairs its label text
("Exclude from Inbox" / "Include in Inbox") with a state-derived SF Symbol
(`tray.and.arrow.up` / `tray.and.arrow.down`) in addition to the accent-color
tint, so state is never conveyed by color alone. The rotor action and the
settings `Toggle` both convey state through text/native control state, not
color.

F1-F16 patterns applied:
- No `Focus(autofocus:)` misuse — none introduced (N/A, no container focus
  code in this diff).
- Announcement convention (non-assertive `Announcer.announce`, matching
  `.toggleAutoQueue`/`.toggleInboxInclude`) — directly verified above; this
  is the primary pattern this review was asked to confirm, and it holds.
- Group header vs button separation, visible-but-hidden restore button,
  deferred announce after delete, focusable empty states — not applicable;
  this diff touches no group headers, no Downloads rows, no delete flow, and
  no empty-state view.

Additional verification performed:
- `xcodebuild test -only-testing:EarshotTests/QuickActionBuildersTests
  -only-testing:EarshotTests/DownloadsInboxLogicTests
  -only-testing:EarshotTests/PodcastSettingsViewTests` on simulator
  `58857CDF-1560-410D-8F46-7381F7ADF48A` — 109 tests, 0 failures, including
  all #671 tests.
- Read all four changed source files in full
  (`PodcastAction.swift`, `PodcastActionsBuilder.swift`,
  `PodcastSettingsView.swift`, `SubscriptionsView.swift`) plus the settings
  footer text change, to confirm no double-reading between the new footer
  string ("New episodes from this podcast appear in the inbox unless you
  exclude it here.") and any hint — no hint exists on the `Toggle`, so no
  double-reading risk.

`git status --short` clean at end of review (aside from the known
pre-existing unrelated `.dart` formatting noise from #660, left untouched);
no fix commit needed.

New agents created: none.
Feature suggestions identified: none this review.

Overall: PASS
