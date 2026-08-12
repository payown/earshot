# Earshot iCloud sync device test

The measured 2026-08-08 build-155 V5 to build-186 V10 upgrade and two-device
record is in
`docs/device-test-artifacts/2026-08-08-v5-v10-upgrade.md`. It is the completed
migration-only 1.1.0 release gate; the remaining sync matrix below is deferred
to 1.2.0.

Status: development CloudKit only. Do not use this document against production
CloudKit until the production schema has been reviewed and deployed.

Devices:

- Michael's iPhone running the current development build.
- M3 MacBook running Earshot as Designed for iPhone from Xcode.
- Both devices signed into the same iCloud account with iCloud Drive enabled.

Recording rule: write down the local start time, the local time the other device
changes, and the final count or value. “Eventually” is not a result.

## Preparation

1. Confirm the iPhone build number in Earshot Settings.

2. In Xcode, select the Earshot CloudKit Development scheme.

3. Select My Mac, Designed for iPhone, as the destination.

4. Choose Product, Run.

5. On each device, open Settings, iCloud Sync.

6. Confirm VoiceOver reads the heading “iCloud Sync.”

7. Confirm VoiceOver reads a Status label and its text value.

8. Confirm neither device says “Paused after account change.”

9. Record the podcast count on each device.

10. Record the queue count on each device.

11. Record whether either device has a download in progress.

## Pass 1: iPhone to Mac

1. On iPhone, create a folder named Sync Test Phone.

2. Record the creation time.

3. Move one existing podcast into Sync Test Phone.

4. Record the podcast title and move time.

5. Add one episode from that podcast to the queue.

6. Record the episode title and queue time.

7. Play that episode long enough to establish a nonzero position.

8. Pause playback.

9. Record the displayed position and pause time.

10. Add a bookmark at the current position.

11. Record the bookmark time.

12. On Mac, leave Earshot active and wait for each corresponding change.

13. Record the Mac arrival time for the folder, membership, queue item, playback
position, and bookmark separately.

14. Confirm the Mac download count did not change.

15. Confirm the Mac purchase entitlement did not change.

## Pass 2: Mac to iPhone

1. On Mac, create a subfolder named Sync Test Mac inside Sync Test Phone.

2. Record the creation time.

3. Move the test podcast into Sync Test Mac.

4. Record the move time.

5. Reorder the queued test episode.

6. Record the reorder time.

7. Advance the episode playback position on Mac.

8. Pause playback.

9. Record the new position and pause time.

10. Change playback speed to a distinctive value such as 1.7x.

11. Record the settings-change time.

12. On iPhone, wait for each corresponding change.

13. Record the iPhone arrival time for the subfolder, membership, queue order,
playback position, and playback speed separately.

14. Confirm the iPhone download count did not change.

15. Confirm the iPhone lifetime entitlement remains active.

## Pass 3: stale progress and explicit rewind

1. Put the Mac offline.

2. On Mac, note the current test-episode position without changing it.

3. On iPhone, advance the same episode by at least two minutes.

4. Pause on iPhone and record the position and time.

5. Bring the Mac online without changing its older position.

6. Confirm the newer iPhone position reaches Mac and does not move backward.

7. Record the arrival time and final position on both devices.

8. On Mac, explicitly move the episode backward using the playback scrubber.

9. Pause and record the explicit-rewind time and position.

10. Confirm that explicit rewind reaches iPhone.

11. Record the arrival time and final position on both devices.

## Pass 4: offline changes and restart

1. Put the Mac offline.

2. Confirm Earshot remains usable and its local library stays visible.

3. Force quit Earshot on Mac.

4. Reopen Earshot on Mac while still offline.

5. Confirm the local library remains visible.

6. On Mac, add a different existing episode to the queue.

7. Record the episode and time.

8. Force quit Earshot again.

9. Reopen Earshot while still offline.

10. Confirm the offline queue change survived the restart.

11. Bring the Mac online.

12. Put Earshot in the background, then return it to the foreground.

13. Confirm iCloud Sync no longer reports an unavailable state.

14. Confirm the queued episode reaches iPhone.

15. Record reconnect time, arrival time, and final queue counts.

## Pass 5: concurrent deletion safety

Point of no return: unfollowing the selected podcast removes its local episode
catalog and can remove its queue and bookmark state. Use only a disposable test
podcast.

1. Follow one disposable podcast and wait for it to appear on both devices.

2. Start one of its episodes playing on iPhone.

3. Put the Mac offline.

4. Unfollow the disposable podcast on Mac.

5. Bring the Mac online.

6. Confirm iPhone playback stops safely when the unfollow arrives.

7. Confirm Earshot remains open and responsive.

8. Confirm the podcast disappears from both devices.

9. Confirm later pause and seek commands do not recreate the podcast or episode.

10. Record all times and whether any download file remained for that podcast.

## Pass 6: VoiceOver and playback heat

Run each sample for 30 minutes while both devices are online and occasional sync
changes are made on the other device.

1. Play at 1x for 30 minutes.

2. Record start time, end time, battery percentage, perceived temperature, and
VoiceOver responsiveness.

3. Play at 1.5x for 30 minutes.

4. Record start time, end time, battery percentage, perceived temperature, and
VoiceOver responsiveness.

5. Play at 2x for 30 minutes.

6. Record start time, end time, battery percentage, perceived temperature, and
VoiceOver responsiveness.

7. During each sample, make one queue or playback-position change on the Mac.

8. Record its iPhone arrival time.

9. A pass requires no unexpected heating, no VoiceOver freeze, no routine sync
announcement, no playback interruption, and no backward progress movement.

## Final record

Record:

- iPhone build and iOS version.
- Mac build and macOS version.
- iCloud account availability shown by each app.
- Before and after podcast, queue, folder, bookmark, and history counts.
- Every propagation latency.
- Every conflict outcome.
- Download and entitlement values that remained device-local.
- Any force quit, crash, silence, bounce, inaccessible control, or unexpected
announcement.
- Whether both devices end with the same synchronized library state.
