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
| 8 | Downloads + Inbox + queue expiration | PRD 5.2, 5.3 | #343 | [ ] | |
| 9 | Settings — all screens + documented prefs | PRD 7, 9 | #344 | [ ] | |
| 10 | Search + OPML import/export | PRD 5.7, 5.1 | #345 | [ ] | |
| 11 | Folders — grouping + per-folder queue age limit | PRD 5.2 | #346 | [ ] | |
| 12 | Bookmarks — saved timestamps | PRD 5.5 | #347 | [ ] | |
| 13 | Stats — listening stats, retention, CSV export | PRD 5.9 | #348 | [ ] | |
| 14 | Chapters + sleep timer + audio enhancements | PRD 5.5, 5.6 | #349 | [ ] | |
| 15 | Onboarding — 7 screens, contextual tips, app icon | PRD 6 | #350 | [ ] | |
| 16 | Polish — performance + full VoiceOver / Dynamic Type audit | PRD 7, 8 | #351 | [ ] | |

Deferred (folded into the nearest feature or appended as issues once prerequisites
land): Transcripts (5.6), Local audio import (5.8), Notifications (5.10), Sharing /
Universal Links (5.11).

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

## Blockers

None.
