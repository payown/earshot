# Plan: Playback heat trim + downloads management (July 2026)

Four work items, shipped as separate stacked branches/PRs into one TestFlight
build so Michael can verify all four on device at once. Nothing merges until
device verification.

Investigation basis: two read-only diagnosis passes over the `swift` branch on
2026-07-22 (build 155). Findings summarized inline below.

## Delivery topology

Stacked branches, each based on the previous so per-PR diffs stay clean and the
tip contains all four for a single build:

```
swift
 └─ perf/playback-heat-micro-opts        (W1 + this plan doc)
     └─ feat/clear-downloads              (W2)
         └─ feat/auto-remove-after-played (W3)
             └─ feat/auto-download-queued (W4)  <- TestFlight build cut here
```

Merge order after device verification: W1, W2, W3, W4 into `swift`.

No schema bump in any item. New settings use the generic key/value `AppSetting`
model, which needs no SwiftData migration. No new `Podcast`/`Episode` fields.
This keeps all four off the migration-risk path (`database-migrations.md`).

---

## W1 - Playback heat micro-optimizations

**Branch:** `perf/playback-heat-micro-opts` (off `swift`)

Build 155 already moved the pathological cost (Inbox badge re-scan per position
save, mini player live when idle) off the playback path. The residual heat is:

1. **Time-stretch DSP at >1.0x speed** - inherent, deliberately tuned for audio
   quality (#607/#697). Not touched. This is the main remaining floor and is
   expected, not a defect.
2. **Now-playing info sync does a redundant cross-process getter** every ~5 media
   seconds (`PlayerService.updateNowPlayingElapsed`). It reads the whole
   `MPNowPlayingInfoCenter` dict back (a `mediaserverd` round-trip copying the
   artwork reference) just to mutate 3 keys.
3. **Redundant per-tick `Task` hop** - `observePeriodicTime`'s observer already
   fires on `.main`, then re-wraps work in `Task { @MainActor in ... }`,
   allocating a task and deferring a runloop hop every tick.

**Changes (both no-quality-impact):**
- Cache a mutable `[String: Any]` copy of the now-playing dict in `PlayerService`
  (the app is the only writer) and mutate/assign that, dropping the getter
  round-trip. Keep the existing 5s throttle. Keep a getter fallback only for the
  first build after launch / external mutations.
- Replace the per-tick `Task { @MainActor in self.handleTick(...) }` with a
  direct `MainActor.assumeIsolated { self.handleTick(...) }` since the observer
  callback is already main-queue.

**Not doing:** the Battery Saver / cheaper-DSP toggle (Michael chose safe
micro-opts only). Recorded here in case it is wanted later: `.lowQualityZeroLatency`
at <=2x is the only cheaper algorithm.

**Tests:** unit-level assertion that the now-playing sync path does not call the
getter on the throttled update; keep existing player tests green.

---

## W2 - Clear downloads (one tap)

**Branch:** `feat/clear-downloads` (off W1)

There is a per-episode `DownloadManager.removeDownload(_:)` but no "remove all".
A raw folder wipe alone would leave stale `.downloaded` episode rows, so the new
path must reset state too.

**Changes:**
- Add `DownloadManager.clearAllDownloads()` that enumerates episodes with
  `downloadPath != nil`, deletes each file via `localAudioURL`, and clears state
  through `ActiveDownload.setDownloadStatus(.none, on:in:)` so `downloadStatus`
  and the `ActiveDownload` mirror stay consistent in one save. Cancels any
  in-flight download tasks first.
- Destructive, confirmed entry point (VoiceOver-labeled) in
  `DownloadsScreen` toolbar and in `DownloadsSettingsView`. Confirmation dialog
  states how many downloads / how much space will be removed. Disabled when there
  are zero downloads.

**Tests:** seed downloaded episodes, call `clearAllDownloads`, assert files gone
and all rows back to `.none`; assert no-op when nothing is downloaded.

**Accessibility gate:** SwiftUI review (button label, destructive role,
confirmation dialog reachable).

---

## W3 - Auto-remove downloads after played (global, off by default)

**Branch:** `feat/auto-remove-after-played` (off W2)

Global setting. Per-podcast is out of scope (would need a `Podcast` field +
migration).

**Changes:**
- New setting key `delete_after_played` (Bool, default `false` - destructive, so
  opt-in). Add reader/writer through `AppSettingsStore` -> `SettingsStore`.
- Toggle in `DownloadsSettingsView` with a clear explanation.
- Hook the mark-played choke points to call `DownloadManager.removeDownload(_:)`
  when the setting is on: `PlayerService.markCurrentEpisodePlayed()`,
  `handlePlaybackEnded()`, `QueueRepository.markPlayedAndRemove(_:)`, plus the
  manual mark-played paths (`EpisodeActionsBuilder`, `InboxRepository.markPlayed`).
  Centralize in one helper so every path is covered once.

**Tests:** with setting on, marking an episode played deletes its file and resets
status; with setting off, the file is kept.

**Accessibility gate:** SwiftUI review (toggle label/state/hint).

---

## W4 - Auto-download queued episodes (on by default)

**Branch:** `feat/auto-download-queued` (off W3)

Both auto-queued and manually queued episodes should be available offline.
Episodes reach the queue by TWO paths, so both must be hooked.

**Changes:**
- New setting key `auto_download_queued` (Bool, default `true`). Reader/writer via
  `AppSettingsStore` -> `SettingsStore`. Toggle in `DownloadsSettingsView`.
- Respects the existing `wifi_only_downloads` gate automatically because it routes
  through `DownloadManager.download(_:)`.
- Hook path A (main context): `QueueRepository.enqueue(_:)` - covers manual add,
  Play Next, binge, and the auto-queue opt-in immediate enrollment.
- Hook path B (refresh auto-queue on background context):
  `FeedRefreshActor.apply` enqueues auto-queued episodes on a background context
  and never touches `QueueRepository`. Mirror the existing
  `SubscriptionRepository.autoDownloadRecent` pattern: after
  `mergeBackgroundWrites`, re-fetch the newly auto-queued episode IDs on the main
  actor and call `DownloadManager.download(_:)`. Do not call the main-actor
  downloader from the background actor.
- Skip episodes already downloaded / in-flight. No duplicate enqueues of the
  downloader.

**Tests:** with setting on, enqueuing an episode triggers a download request
(mock downloader); with setting off, it does not; already-downloaded episodes are
skipped; wifi-only gate still respected.

**Accessibility gate:** SwiftUI review (toggle label/state/hint).

---

## Cross-cutting gates before the build

- SwiftUI accessibility review on every UI change (W2, W3, W4).
- `xcodebuild test` (EarshotTests) green, including new tests.
- No `schemaVersion` bump (verify), so no migration test needed.
- Swift 6 concurrency clean (W4 crosses an actor boundary - verified by build).
- CHANGELOG updated for the user-visible items (W2/W3/W4; W1 is invisible).
- Do NOT bump build number manually; the deploy script owns it.
- Do NOT merge or close anything until Michael verifies on device.
