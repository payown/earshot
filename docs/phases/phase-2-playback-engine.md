# Phase 2: Playback engine, queue, basic UI

**Goal:** A user can tap an episode and hear it play, with full lock screen / Control Center / media notification controls, per-episode position persistence, and a basic queue.

**Estimated duration:** 2-3 weeks (part-time)

## Prerequisites

- Phase 1 complete: subscriptions, episodes in SQLite, all three screens working
- `just_audio` and `audio_service` already added to `pubspec.yaml`

## Tasks

### 1. Audio service setup
- [ ] Create `lib/features/player/data/audio_handler.dart` extending `BaseAudioHandler`
- [ ] Register handler in `main()` via `AudioService.init`
- [ ] Configure `audio_service` for background playback on iOS and Android
- [ ] Verify iOS background audio mode in `Info.plist` (already prepped in Phase 0)
- [ ] Verify Android `FOREGROUND_SERVICE` permission and `audio_service` service declaration in `AndroidManifest.xml`

### 2. Playback controls
- [ ] Implement: play, pause, stop, seek, skip forward 30s, skip back 15s
- [ ] Wire skip amounts to user settings (constants for now, configurable in Phase 3)
- [ ] Emit correct `PlaybackState` from handler (playing, paused, buffering, stopped)
- [ ] Handle audio focus (interruptions: phone calls, other apps)
- [ ] Handle headphone unplug (pause on disconnect)
- [ ] Handle Bluetooth reconnect (resume)

### 3. Queue data model
- [ ] Add `queue_items` drift table: `id`, `episode_id` (FK → episodes), `position` (sort order), `added_at`
- [ ] Enable cascade delete when episode is deleted
- [ ] Run `build_runner` to regenerate
- [ ] Add `QueueRepository` interface and implementation: `addToQueue`, `removeFromQueue`, `reorder`, `watchQueue`
- [ ] Add `queueProvider` StreamProvider

### 4. Play an episode
- [ ] Make episode rows in `PodcastDetailScreen` tappable
- [ ] On tap: add episode to queue (if not already in it) and start playback
- [ ] `EpisodeListTile` gets a play button affordance (icon + semantic label "Play {title}")

### 5. Now-playing bar
- [ ] Persistent bottom bar visible whenever something is playing or paused
- [ ] Shows: artwork thumbnail, episode title (truncated), podcast title
- [ ] Controls: play/pause button, skip forward button
- [ ] Tapping bar opens full player screen
- [ ] Full Semantics labels on all controls
- [ ] Animates in/out respecting Reduce Motion

### 6. Full player screen
- [ ] Large artwork
- [ ] Episode title and podcast name
- [ ] Playback progress bar with current position and total duration (Semantics: "Position: 12 minutes of 45 minutes")
- [ ] Play/pause, skip forward 30s, skip back 15s
- [ ] Playback speed selector (0.5x–3.0x in 0.5x increments for now; full range in Phase 3)
- [ ] All controls minimum 44pt / 48dp touch targets

### 7. Position persistence
- [ ] On pause or stop: write `position_seconds` to `episodes` table
- [ ] On play: resume from saved position (if < 95% complete, otherwise restart)
- [ ] Mark episode `played` when position reaches 95% of duration

### 8. Lock screen / Control Center / media notification
- [ ] `audio_service` handles this automatically via `MediaItem` and `PlaybackState`
- [ ] Populate `MediaItem` with episode title, podcast name, and artwork URI
- [ ] Verify lock screen controls work on iOS simulator
- [ ] Verify Android media notification with controls on emulator

### 9. Tests
- [ ] Unit tests for `QueueRepository` with in-memory drift DB
- [ ] Widget tests for now-playing bar (shows/hides, correct title, play/pause accessible)
- [ ] Widget tests for full player screen (progress announced, controls labeled)

## Definition of done

- Tapping an episode starts audio playback
- Lock screen and Control Center show episode info and controls (iOS)
- Android media notification shows episode info and controls
- Playback position saves on pause and restores on resume
- Episode marked played at 95% completion
- Queue persists across app restarts
- Now-playing bar visible on subscriptions list and podcast detail screens while playing
- All new UI passes `flutter analyze` and widget tests
- VoiceOver manual test: can play, pause, and skip without visual interaction

## Commands to use during this phase

```bash
# Regenerate drift code after queue_items table is added
dart run build_runner build

# Run on simulator with audio enabled
flutter run -d <device-id>

# Check for regressions
flutter analyze
flutter test
```

## Claude Code prompts for this phase

**Prompt 1: audio handler setup**
```
Read docs/phases/phase-2-playback-engine.md and lib/features/player/. Set up the AudioHandler in lib/features/player/data/audio_handler.dart extending BaseAudioHandler from audio_service. Wire it up in main.dart. Implement play, pause, seek, skipForward, skipBackward. Handle audio focus interruptions. Don't build the UI yet.
```

**Prompt 2: queue data model**
```
Add a queue_items drift table to lib/data/db/. Columns: id, episode_id (FK → episodes with cascade), position (sort order integer), added_at. Regenerate with build_runner. Implement QueueRepository with addToQueue, removeFromQueue, reorder, and watchQueue. Write repository tests with in-memory drift DB.
```

**Prompt 3: episode tap + now-playing bar**
```
Make EpisodeListTile tappable to play. Add a persistent NowPlayingBar at the bottom of SubscriptionsScreen and PodcastDetailScreen that shows when audio is playing or paused. Include play/pause and skip forward controls. Full Semantics labels. Respect Reduce Motion for the bar's appear/disappear animation. Write widget tests verifying the bar's semantic labels.
```

**Prompt 4: full player screen**
```
Build the full player screen in lib/features/player/presentation/. Large artwork, episode title, podcast name, progress bar with position/duration announced via Semantics, play/pause, skip forward 30s, skip back 15s, speed selector. All touch targets 48dp minimum. Test with VoiceOver before marking done.
```

**Prompt 5: position persistence and played state**
```
On pause or stop, write the current position_seconds to the episodes table. On play, read the saved position and resume from it (unless >= 95% complete). Mark the episode status as "played" when position reaches 95% of duration. Write unit tests covering resume-from-position and played-marking logic.
```
