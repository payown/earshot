# Changelog

All notable changes to Earshot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Export audio file: every episode now has an "Export audio file" action that
  opens the share sheet, so you can save the audio to Files, AirDrop it, or open
  it in another app. It's in the Now Playing player's "Episode actions" menu
  (next to "Mark as played") and the episode actions menu on other screens, plus
  the VoiceOver/TalkBack actions rotor in both places. If the episode isn't
  downloaded yet, tapping Export downloads it in the background and opens the
  share sheet automatically when it's ready — even if you've moved to another
  screen. On cellular it asks once before using mobile data. The exported file
  keeps its original format and is named "Podcast name - Episode title" instead
  of an internal filename. If a download fails you get a clear message with a way
  to try again.
- Now Playing: a "Stop after this episode" action lets you stop playback when the
  current episode finishes, just this once, without changing your settings. It's
  in the "Episode actions" menu and the VoiceOver/TalkBack actions rotor, and it
  clears itself after the episode ends (or when you play something else). Tip: if
  you want to stop after every episode, turn both "Continue after…" switches off
  in Playback settings.
- Inbox limits: each podcast can now cap how many episodes stay in the inbox and
  auto-remove episodes older than a set time (6 hours up to 2 weeks), both set on
  the podcast's settings page in the Library. A global "Default episodes per
  podcast in inbox" choice under Inbox settings sets the default (No limit by
  default, so nothing changes unless you opt in). Trimmed episodes aren't
  deleted; they stay unplayed in the show's episode list. Anything you've
  played, started, or queued is never touched.
- Now Playing: a "Mark as played" action lets you finish the current episode
  without listening to the end. It marks the episode played, removes it from
  the queue, and moves on to the next queued episode (or stops when the queue
  is empty). Available from the "Episode actions" menu and the
  VoiceOver/TalkBack actions rotor on the artwork.
- Queue: in the "Group by podcast" view, each podcast group now has "Move
  group to top/up/down/bottom" actions in the VoiceOver/TalkBack actions
  rotor, mirroring the per-episode move actions.
- OPML: Earshot now appears as "Open in Earshot" in Mail/Files and "Share to
  Earshot" in the share sheet for `.opml` files exported from other podcast
  apps (e.g. Castro, Overcast). Tapping or sharing an OPML file opens the
  Import OPML screen pre-loaded with the file; multiple shared files are
  imported one after another. (iOS only for now.)

### Changed
- Quick Actions: your configured episode-action order now drives the VoiceOver
  Actions rotor too, not just the menu and default double-tap. Reorder your
  actions in Settings and the rotor follows the same order (the menu and default
  update instantly; the rotor applies the next time you open Earshot, which the
  app announces when you save).
- Episode actions are now identical across Inbox, Queue, Library, and Downloads.
  Every tab uses one shared "Play now" path, one shared actions bottom sheet, and
  the same VoiceOver rotor actions in the order set in Quick Actions settings.
  Queue keeps its move/remove actions; Downloads tiles gain a "more actions"
  button. Downloaded episodes now always play the local file instead of streaming.
  Destructive actions (Remove from queue, Delete download) show a leading icon in
  the sheet so danger is not signaled by color alone.

### Fixed
- Player: tabs now switch instantly while audio is playing. Before, tapping a tab
  did nothing until you paused, which left VoiceOver users unable to move around
  the app during playback. The fix throttles how often the playback position is
  saved to disk (it was saving every second on the main thread and starving the
  UI). Position is still saved on pause, seek, and episode change, so nothing is
  lost. (closes #362)
- Quick Actions: reordering your episode or podcast actions now saves reliably.
  Some setups (carried over from an older app version) could hit a hidden
  conflict that silently rolled back the save, so the order reverted every time
  you reopened the app. The save now collapses that conflict, and the
  configurator confirms "Quick actions saved" (or tells you if a save fails)
  instead of failing without a word.
- Playback: with both "Continue after…" switches off, playback now stops at the
  end of the current episode instead of rolling on to another one. And when
  playback does continue, finishing an episode you started from the middle of the
  queue now moves to the next episode below it, not back to the top of the queue.
  "Continue after group ends = off" now reliably stops when the next episode is a
  different show, even when you started a single episode rather than a whole
  group. (closes #327)
- Queue: the playing episode now stays in its real position in the list with a
  "Now playing" label, instead of being lifted to the top. The list reads in true
  play order.
- Feeds: when a podcast republishes an episode under the same ID with a newer
  date, it now returns to the Inbox instead of staying hidden — but only if it
  was auto-filed backlog you never touched. Episodes you played, started,
  queued, or cleared are left exactly as they were.
- Queue: "Remove from queue" on the episode that's currently playing now marks it
  played, removes it, and moves on to the next episode, the same as the player's
  "Mark as played". Before, it appeared to do nothing (the playing episode stayed
  pinned at the top) and wrongly reset its status. Removing any other queued
  episode is unchanged.
- Performance: the Inbox is now interactive immediately on cold launch instead
  of being unreachable for a minute or more on large libraries. The app no
  longer force-refreshes every feed on every cold start (it skips the refresh if
  the feeds were checked in the last 15 minutes, matching the on-resume
  behavior), episode writes during a refresh are now batched, the inbox query
  and unread badge are backed by a new database index, and the badge is counted
  in the database instead of by loading every unread episode. Pull-to-refresh
  still forces a full refresh.
- Inbox: VoiceOver/TalkBack now reads a short show-notes preview for each
  episode after its title, show, and status, so you can hear what an episode is
  about while browsing without opening it. The full notes remain one rotor
  action away via "Open show notes". HTML and entities are stripped so no markup
  is read aloud.
- Show notes: opening an episode's show notes from the Inbox, Queue, Library, or
  Downloads now announces "Show notes" to VoiceOver/TalkBack when it opens and
  exposes the episode title as a heading, so screen reader users can read an
  episode's notes while browsing without starting playback.
- Player: the sleep timer's increase/decrease (chevron) buttons now meet the
  minimum touch-target size on all platforms. They were slightly under the
  Android 48dp minimum, making them harder to tap accurately.
- Queue: removing the next episode while another is playing no longer lets the
  removed episode play anyway. Earshot preloads the next episode for gapless
  playback; if you removed or reordered that episode out of the next slot, the
  preloaded copy used to still play when the current one finished. It's now
  dropped as soon as the queue changes, and the correct next episode plays.
- Inbox: a podcast with a single mis-dated "future" episode no longer goes
  silent. Previously one episode dated in the future pushed that show's
  high-water mark ahead of real time, so every later, correctly-dated episode
  was treated as old backlog and never reached the Inbox. Future-dated items are
  now ignored when tracking what's new, and a one-time database fix repairs any
  show already affected so new episodes start arriving again.
- Queue: "Move up"/"Move down" Quick Actions on a grouped episode now reliably
  reorder it within its podcast group. Previously they swapped the episode's
  position in the global flat queue, which could land on a different podcast's
  episode and produce no visible change in the grouped view.
- Privacy: crash reporting and anonymous analytics now actually respect the
  opt-out toggles in Privacy & History. Previously these toggles had no effect
  on whether Sentry/PostHog initialized. Privacy settings note that changes
  take effect on next app restart.
- Search: fixed podcast search still returning no results. iTunes API returns
  `Content-Type: text/javascript`; response is now fetched as plain text and
  decoded manually, bypassing Dio's content-type-based auto-parsing entirely.
- Search: moved search entry point from the Library AppBar to the Library screen's
  FAB area. A small search FAB now sits above the "Add by URL" FAB in the bottom
  right corner — both have accessible tooltips for VoiceOver/TalkBack.
- Inbox: removed the folder-queue button from the Inbox AppBar.
- Inbox: "Mark all as played" no longer crashes the app. Any database error is now
  caught and shown as a snackbar instead of crashing the app.
- Search: fixed podcast search returning no results. iTunes API returns
  `Content-Type: text/javascript`; Dio now forces JSON parsing regardless of
  content type.
- Search: tapping a search result now opens a podcast preview screen with title,
  author, description, and episode list from the RSS feed. VoiceOver users can
  flick down on any result to access a "Follow" action directly from the list.
- Search: Clear search (X) button no longer announces twice. Only
  "Clear search, button" is visible to screen readers.
- Inbox: "Add folder to queue" sheet barrier is now labeled "Dismiss folder queue
  sheet" so VoiceOver users know how to dismiss it.
- Inbox: "Add folder to queue" sheet heading no longer announces twice.
- Library screen: "All Podcasts" row no longer appears as an unlabeled button
  in the VoiceOver/TalkBack accessibility tree.
- Folder picker sheet: "Done" button now has an explicit semantic label and hint.
- Manage Folders flow: VoiceOver no longer lands on "scrim" when the folder
  picker sheet opens via a quick action. The barrier is now labeled "Dismiss
  folder picker" and the sheet claims focus on open.
- Play All Unplayed Episodes now starts playback immediately instead of only
  adding episodes to the queue.
- Folder picker sheet: Removed duplicate "Add to Folder" heading, unlabeled
  button after Done, and extra VoiceOver traversal stop. Done button moved to
  sheet footer so it is reachable by swiping forward after selecting folders.
- Folder picker sheet: "Create new folder" no longer appears as two buttons in
  the VoiceOver tree.
- Folder picker sheet: VoiceOver no longer announces "Add to Folder, Done,
  heading" on open. Removed `Focus(autofocus: true)` container wrapper that was
  causing VoiceOver to group and summarise all children on sheet entry.
- Folder picker checkboxes no longer announced as "dimmed, switch button off".
  Replaced custom Semantics/ExcludeSemantics wrappers with plain CheckboxListTile
  whose built-in MergeSemantics correctly maps to "checkbox, checked/unchecked"
  on iOS VoiceOver. Same fix applied to "Create new folder" row.

### Phase 8 complete — Alpha build prep

- Version set to 0.1.0+1
- Release CI workflow at .github/workflows/release.yml (triggered on v*.*.* tags)
- Android signing config ready (key.properties template provided)
- build_runner codegen step added to all CI jobs (fixes *.g.dart not committed)
- Replaced file_picker with file_selector (Flutter team package, fixes Android namespace error)
- Upgraded sentry_flutter to v9 (fixes Kotlin 1.6 deprecation on CI)
- CI: Analyze and test ✓, Build iOS ✓, Build Android ✓

### Phase 7 complete — Polish: sleep timer, onboarding, bookmarks, telemetry

- Sleep timer: presets (end of episode, 5–60 min), Extend +5 min in now-playing bar and player screen, all actions announced to screen readers
- Onboarding: 7 screens shown on first launch, skippable, "Next" gated on screen 6 until a podcast is added, completion persisted
- Bookmarks: Quick Action captures current playback position, announced "Bookmarked at M:SS"
- Sentry crash reporting wired (opt-out, DSN via compile-time env var, no-op when empty)
- PostHog analytics wired (opt-out, API key via env var, no-op when empty)
- Privacy Settings: crash reports and analytics toggles, history retention, delete all
- CSV stats export from Stats screen via share sheet
- **Deferred to Phase 8 prep:** chapter support, volume boost/mono audio, silence trim, CarPlay/Android Auto, beta build upload

### Phase 6 complete — Search, OPML import/export, podcast discovery

- Search icon in Subscriptions opens podcast directory search (Podcast Index API)
- Debounced search (300ms), result list with per-row Subscribe buttons
- Subscribe confirmation announced via SemanticsService
- OPML import: file picker → bulk subscribe with live progress as semantic live region
- OPML export: generates OPML 2.0 and shares via system share sheet
- Settings → Subscriptions section with Import and Export
- 7 OPML unit tests (parse, edge cases, generate, round-trip)
- **Deferred:** Local audio import (iOS "Open In" / Android SAF) — Phase 7
- **Deferred:** Podcast Index integration — Phase 7 or later
- **Deferred:** In-app subscription filter (type to filter subscribed list) — Phase 7

### Phase 5 complete — Stats, listening history, privacy controls

- App records listening sessions (episode, podcast, duration, speed, date) on pause and stop
- Stats screen: time listened, time saved by speed, episodes completed — all as plain text
- Per-podcast breakdown sorted by time
- Period selector: This Week, This Month, This Year, All Time
- Privacy Settings: history retention (30d/90d/1y/forever), "Delete all history"
- Retention applied automatically on app launch
- Settings → Listening Stats and Settings → Privacy & History navigation
- 10 unit tests for stats aggregations, period filtering, and retention
- **Deferred:** CSV export, year-in-review, streaks — Phase 7 polish

### Phase 4 complete — Downloads, Inbox, queue expiration, bottom navigation

- Subscribe auto-downloads 3 most recent episodes (configurable, default 3)
- Download manager with progress tracking and cancellation via dio
- Inbox tab: all new untriaged episodes with Add to queue, Mark played, Delete actions
- Queue tab: reorderable list with Remove and Move-to-top Quick Actions
- Downloads tab: downloaded episodes + Recently Expired with 7-day restore window
- Queue expiration: items older than per-podcast age limit auto-move to Recently Expired
- Bottom navigation bar with badge count on Inbox
- Schema version 3: app_settings (key-value), recently_expired tables
- **Deferred:** Wi-Fi-only enforcement (connectivity_plus/xml version conflict) — Phase 7
- **Deferred:** Auto-queue toggle and change-queue-age-limit Quick Actions — still stubs

### Phase 3 complete — Quick Actions, Settings, accessibility layer

- Episode and podcast rows expose VoiceOver actions rotor / TalkBack custom actions via `customSemanticsActions`
- Default episode Quick Actions: Play now, Add to queue, Mark played/unplayed, Open show notes
- Default podcast Quick Actions: Open, Toggle notifications, Toggle auto-queue, Unsubscribe
- First action in user's list is the default double-tap action
- Settings screen accessible via gear icon in app bar
- Quick Action configurator: drag-to-reorder list with up/down button alternatives for screen readers
- Quick Action order persists to SQLite and takes effect immediately
- `ReduceMotion` extension on `BuildContext` ready for all future animations
- High-contrast theme wired to system setting via `MaterialApp.highContrastTheme`
- **Deferred:** Toggle notifications and Toggle auto-queue actions (stubs — need Phase 4 backend)
- **Deferred:** Share action (Phase 7)
- **Deferred:** Manual VoiceOver/TalkBack test — carry into Phase 4

### Phase 2 complete — Playback engine, queue, player UI

- Tap any episode to play it — audio streams via `just_audio` with background playback
- Lock screen and Control Center controls wired via `audio_service` (iOS and Android)
- Now-playing bar on subscriptions list and podcast detail screens: artwork, title, skip, play/pause
- Full player screen: large artwork, progress bar with position announced for screen readers, speed selector (0.5x–3.0x), skip controls
- Playback position auto-saves on pause and restores on resume
- Episode marked played at completion
- Queue data model persists across restarts
- Platform configuration: iOS background audio mode, Android foreground service and media permissions
- **Deferred:** Periodic position save while playing (every 10s) — Phase 7 polish
- **Deferred:** VoiceOver/TalkBack manual test — carry into Phase 3

### Phase 1 complete — Core data model, RSS, subscriptions

- Subscribe to any podcast by RSS URL
- RSS parser handles RSS 2.0, iTunes namespace, and Podcasting 2.0 (chapters, transcripts)
- Subscriptions list with podcast artwork, title, and author
- Podcast detail screen with episode list (most recent first)
- Episode rows show title, duration, and relative date
- Pull-to-refresh updates all subscribed feeds
- Subscriptions and episodes persist in SQLite via drift
- All screens accessible: semantic labels on every interactive element, error messages announced via SemanticsService
- **Deferred:** Background feed refresh (every 6 hours) — moved to Phase 4 alongside download manager and background services
- **Deferred:** VoiceOver/TalkBack manual test — carry into Phase 2 PR checklist

### Phase 0 complete — Project setup, tooling, CI

- Flutter 3.41.9 project scaffolded (bundle ID `media.payown.earshot`, iOS + Android)
- Core dependencies added: `flutter_riverpod`, `just_audio`, `audio_service`, `drift`, `dio`, `logging`, `package_info_plus`, `path_provider`, `sqlite3_flutter_libs`
- Dev dependencies added: `mocktail`, `build_runner`, `drift_dev`, `very_good_analysis`
- Feature-first folder structure in place (`lib/core/`, `lib/features/`, `lib/data/`)
- Light, dark, and high-contrast themes wired to system settings
- Spacing token constants defined
- "Welcome to Earshot" screen with accessible `Semantics(header: true)` heading
- Widget test verifying semantic heading label
- CI passing: lint, format check, tests, iOS + Android debug builds
- Accessibility enforcement hooks installed via Community Access agents
- **Deferred:** Manual VoiceOver test on welcome screen (carry into Phase 1 PR checklist)

### Added
- Initial project structure
- Product requirements document (`docs/PRD.md`)
- Phase plans (`docs/phases/`) with just-in-time progression
- Repository hygiene: LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY
- GitHub Actions CI workflow
- Issue and PR templates
- Phase progression rule (`.claude/rules/phase-progression.md`) for just-in-time phase doc generation
- Integration with Community Access Accessibility Agents (community-access.org)
