# Phase 7: Polish, performance, beta build

**Goal:** Everything the app needs to feel complete for private alpha testers. Onboarding, sleep timer, playback extras, bookmarks, chapter support, crash reporting, and a TestFlight build.

**Estimated duration:** 2-3 weeks (part-time)

## Prerequisites

- Phases 0-6 complete
- Apple Developer account active (for TestFlight)
- Google Play Developer account active (for Internal Testing)

## Tasks

### 1. Sleep timer
- [ ] Sleep timer options: end of episode, 5, 10, 15, 30, 45, 60 minutes
- [ ] Persistent "Extend +5 min" button on now-playing bar and player screen while timer is running
- [ ] Timer state shown in player screen
- [ ] Fade out audio 5 seconds before end
- [ ] Announcement: "Sleep timer set for 30 minutes", "Sleep timer extended to 35 minutes"
- [ ] No shake gesture (per PRD)

### 2. Onboarding (7 screens)
- [ ] Screen 1: Welcome — "Welcome to Earshot"
- [ ] Screen 2: How content flows — subscribe → download → Inbox → Queue
- [ ] Screen 3: Privacy — crash reports, analytics, history retention toggles
- [ ] Screen 4: Quick Actions — explain and offer "Customize now" / "Use Defaults"
- [ ] Screen 5: Queue expiration — explain freshness limit concept
- [ ] Screen 6: Add your first podcast — Search / RSS URL / Import OPML, enable "Start Listening" once added
- [ ] Screen 7: You're all set
- [ ] Show only on first launch (track in `app_settings`)
- [ ] All screens fully accessible, same experience for everyone

### 3. Chapter support
- [ ] Fetch and parse chapter JSON from `chapterUrl` (Podcasting 2.0 format)
- [ ] Chapter list view in player screen (list of chapter names with start time + duration)
- [ ] Tap chapter to seek
- [ ] Skip forward/back by chapter from player controls (long-press gesture alternative for screen readers)
- [ ] Current chapter name shown in player screen

### 4. Bookmarks
- [ ] `bookmarks` drift table: `id`, `episode_id`, `position_seconds`, `note`, `created_at`
- [ ] Schema version 5 with migration
- [ ] "Bookmark" Quick Action on episode rows
- [ ] Bookmarks list in episode detail or a dedicated screen
- [ ] Share bookmark as timestamp URL `https://earshot.payown.media/episode/{id}?t={seconds}`

### 5. Playback extras
- [ ] Volume boost (1x to 3x gain via `just_audio` volume control)
- [ ] Mono audio toggle (mix stereo to mono for accessibility)
- [ ] Silence trimming (if supported by `just_audio` — check `skipSilence` API)
- [ ] Per-podcast speed persisted (already in schema, wire up in player)
- [ ] Skip amounts configurable: 15s/30s/60s back, 30s/60s/90s forward

### 6. CSV stats export
- [ ] Export `listening_sessions` as CSV (date, podcast, episode, duration, speed)
- [ ] Share via share_plus from Stats screen
- [ ] Deferred from Phase 5

### 7. Crash reporting (Sentry)
- [ ] Add `sentry_flutter` package
- [ ] Initialize in `main()` with DSN from environment/config
- [ ] Opt-out toggle in Privacy Settings (default on)
- [ ] Never capture: subscriptions, episode titles, user notes

### 8. Analytics (PostHog)
- [ ] Add `posthog_flutter` package
- [ ] Initialize in `main()` with project key
- [ ] Opt-out toggle in Privacy Settings (default on)
- [ ] Capture: screen views, feature usage counts only — never content names

### 9. Performance
- [ ] Profile startup time on device — target < 2s cold launch
- [ ] Profile episode list scroll on large subscription list (100+ podcasts)
- [ ] Reduce unnecessary widget rebuilds (use `select` in Riverpod where helpful)
- [ ] Lazy-load episode descriptions (don't preload off-screen)

### 10. Beta build prep
- [ ] App icon (placeholder if final not ready)
- [ ] Bundle ID `media.payown.earshot` confirmed in Xcode
- [ ] iOS provisioning profile for distribution
- [ ] Increase build number, set version `0.1.0`
- [ ] TestFlight: upload, add internal testers
- [ ] Android: sign APK, upload to Play Internal Testing

## Definition of done

- Sleep timer works and fade-out is smooth
- Onboarding shows on first launch, skippable at any point
- At least one podcast added during onboarding unlocks "Start Listening"
- Chapters load and are tappable in player
- Bookmarks can be created and shared
- Sentry and PostHog initialized with opt-out toggles wired
- App builds for distribution (TestFlight + Play Internal)
- All new UI passes `flutter analyze` and tests

## Commands to use during this phase

```bash
flutter pub add sentry_flutter posthog_flutter

# Build for TestFlight
flutter build ipa --export-options-plist ios/ExportOptions.plist

# Build for Play Internal Testing
flutter build appbundle

flutter analyze
flutter test
```

## Claude Code prompts for this phase

**Prompt 1: sleep timer**
```
Read docs/phases/phase-7-polish.md. Build the sleep timer. Options: end of episode, 5/10/15/30/45/60 minutes. Show a persistent "Extend +5 min" button in NowPlayingBar and PlayerScreen while the timer is active. Fade audio 5 seconds before end. Announce "Sleep timer set for X minutes" via SemanticsService. No shake gesture.
```

**Prompt 2: onboarding**
```
Build the 7-screen onboarding flow. Show only on first launch (track in app_settings). Screens: Welcome, How content flows, Privacy, Quick Actions, Queue expiration, Add first podcast, You're all set. All screens accessible — same experience for everyone. Screen 6 enables "Start Listening" once at least one podcast is added.
```

**Prompt 3: chapters**
```
Fetch the chapter JSON from episode.chapterUrl. Parse Podcasting 2.0 chapters format. Show a chapter list sheet from the player screen. Tapping a chapter seeks to that position. Display the current chapter name in the player. Write unit tests for the chapter JSON parser.
```

**Prompt 4: bookmarks and stats CSV export**
```
Add a bookmarks drift table (schema v5). Wire the Bookmark Quick Action. Show bookmarks in episode detail. Export bookmark share URL. Also implement CSV export of listening_sessions from the Stats screen (deferred from Phase 5).
```

**Prompt 5: crash reporting and analytics**
```
Add sentry_flutter and posthog_flutter. Initialize both in main.dart. Add opt-out toggles in Privacy Settings. Sentry captures crashes only — never subscription or episode data. PostHog captures screen views and feature usage counts only.
```
