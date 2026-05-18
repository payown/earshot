# Phase 5: Stats and year-in-review

**Goal:** Earshot tracks listening time, shows the user meaningful stats, and lets them export their history.

**Estimated duration:** 1-2 weeks (part-time)

## Prerequisites

- Phase 4 complete: episodes are marked played, positionSeconds is tracked
- `episodes.played_at` and `episodes.position_seconds` already in the schema

## Tasks

### 1. Listening history schema
- [ ] Add `listening_sessions` drift table: `id`, `episode_id` (FK cascade), `podcast_id`, `duration_seconds` (how long actually listened), `speed` (playback speed during session), `date` (UTC date of session)
- [ ] Schema version 4 with migration
- [ ] Write a session on pause/stop: compute seconds listened = position delta, capture speed

### 2. Stats computation
- [ ] `StatsRepository` interface and implementation
- [ ] Total time listened (all-time, this week, this month, this year)
- [ ] Time saved by speed (vs 1.0x baseline): `duration * (1 - 1/speed)` per session
- [ ] Episodes completed count
- [ ] Per-podcast breakdown: time and episode count

### 3. Stats screen
- [ ] `lib/features/stats/` feature module
- [ ] Stats screen accessible from Settings (or a 5th nav tab — decide at implementation time)
- [ ] All numbers announced as plain text: "3 hours, 47 minutes" not "3.78 hours"
- [ ] Charts optional; if included, text-equivalent is the primary representation
- [ ] Sections: This Week, This Month, All Time, Per Podcast

### 4. Privacy controls
- [ ] Listening history retention setting: Don't keep / 30 days / 90 days (default) / 1 year / Keep forever
- [ ] Store in `app_settings` drift table
- [ ] Apply retention: on app launch, delete `listening_sessions` older than retention window
- [ ] "Delete all history" button in Settings → Privacy with strong confirmation dialog
- [ ] Setting already described in PRD onboarding screen 3

### 5. CSV export
- [ ] Export `listening_sessions` as CSV: date, podcast, episode, duration, speed
- [ ] Share via iOS share sheet / Android share intent
- [ ] Export button in Stats screen

### 6. Tests
- [ ] Unit tests: StatsRepository aggregations (total time, time saved, per-podcast)
- [ ] Unit tests: retention cleanup deletes correct rows
- [ ] Widget tests: Stats screen numbers are readable as text, section headings accessible

## Definition of done

- App records listening sessions
- Stats screen shows total time, time saved, episodes completed
- Per-podcast breakdown is accurate
- Listening history retention setting works
- "Delete all history" clears the sessions table
- CSV export shares a valid file
- All stats displayed as plain text (no chart-only data)
- Tests pass

## Commands to use during this phase

```bash
dart run build_runner build  # after adding listening_sessions table
flutter analyze
flutter test
```

## Claude Code prompts for this phase

**Prompt 1: listening session schema and recording**
```
Read docs/phases/phase-5-stats.md. Add a listening_sessions drift table (schema v4). On pause or stop in PositionTracker, record a session: duration = position delta, speed = current playback speed, date = today UTC. Write unit tests for session recording logic.
```

**Prompt 2: stats repository and screen**
```
Build StatsRepository with: totalTimeListened(period), timeSavedBySpeed(period), episodesCompleted(period), perPodcastBreakdown(period). Period is an enum: thisWeek, thisMonth, thisYear, allTime. Build a Stats screen in lib/features/stats/. Show all numbers as plain text ("3 hours, 47 minutes"). Section headings marked as headers for screen readers.
```

**Prompt 3: privacy controls and CSV export**
```
Add listening history retention setting to AppSettingsRepository. On app launch, delete sessions older than the retention window. Add a "Delete all history" button with confirmation. Add CSV export: write listening_sessions to a temp file and share via the system share sheet.
```
