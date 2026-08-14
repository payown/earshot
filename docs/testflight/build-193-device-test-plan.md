# Build 193 development iCloud test plan

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 193 includes the final live playback-position refresh from PR #837. The
playback-heat investigation is already confirmed resolved and is not repeated
here. Do not deploy the CloudKit production schema during this test.

Record the local time for every action and arrival. If a change does not arrive,
record how long you waited and the status shown on each device. Do not reinstall
Earshot or delete either library to obtain a pass.

## Setup

- [ ] On iPhone, confirm Settings reports build 193.
- [ ] Run the same build on the Mac with the Earshot CloudKit Development scheme
  and the My Mac, Designed for iPhone destination.
- [ ] Confirm both devices use the same iCloud account with iCloud Drive enabled.
- [ ] Open Settings, iCloud Sync on both devices.
- [ ] Confirm VoiceOver reads the iCloud Sync heading, Status, and Last completed
  on this device without moving focus or repeating routine announcements.
- [ ] Record podcast and queue counts on both devices.
- [ ] Confirm downloads and the lifetime purchase entitlement remain local.

## Test 1: live paused position in both directions

This is the physical regression gate for PR #837.

- [ ] Play an episode on iPhone, pause, and record its position and time.
- [ ] Leave the Now Playing screen open on Mac. Confirm the new position appears
  without relaunching and record its arrival time.
- [ ] Advance and pause the same episode on Mac.
- [ ] Leave Now Playing open on iPhone. Confirm the position appears without
  relaunching and record its arrival time.
- [ ] Confirm VoiceOver reads the new position on both devices.

## Test 2: stale progress and explicit rewind

- [ ] Put the Mac offline and record its current position for the test episode.
- [ ] Advance the episode by at least two minutes on iPhone and pause.
- [ ] Bring the Mac online without changing its older position.
- [ ] Confirm the newer iPhone position reaches Mac and neither device moves
  backward.
- [ ] On Mac, deliberately scrub backward and pause.
- [ ] Confirm that explicit rewind reaches iPhone without relaunching.
- [ ] Record both final positions and arrival times.

## Test 3: offline mutation, restart, and reconnect

- [ ] Put the Mac offline and confirm its library remains usable.
- [ ] Force quit and reopen Earshot while still offline.
- [ ] Add a different episode to the queue and record the time.
- [ ] Force quit and reopen again; confirm the queue change survived.
- [ ] Bring the Mac online, background Earshot, and return it to the foreground.
- [ ] Confirm iCloud Sync leaves the unavailable state.
- [ ] Confirm the queued episode reaches iPhone and record reconnect and arrival
  times plus final queue counts.

## Test 4: synced subscriptions refresh honestly

This is the physical gate for #821.

- [ ] On the device receiving synced subscriptions, request a refresh.
- [ ] Confirm the app does not immediately report completion while zero feeds
  were processed.
- [ ] Confirm newly synced podcasts acquire real episode catalogs.
- [ ] Confirm Inbox begins showing durable results without waiting for the entire
  large library refresh to finish.
- [ ] Record the visible status, first-result time, and final podcast count.

## Test 5: older episode paging with VoiceOver

This is the physical gate for #833. Prefer a feed with at least 4,000 episodes.

- [ ] Open the podcast and locate Load 10 Older Episodes with VoiceOver.
- [ ] Activate it once and confirm exactly the next 10 episodes appear.
- [ ] Confirm focus remains stable and the new state is announced once.
- [ ] Activate it again and confirm the next page appears without duplicates.
- [ ] Confirm the historical episodes do not flood Inbox.
- [ ] Confirm VoiceOver remains responsive and record any delay or unexpected
  announcement.

## Test 6: concurrent deletion safety

Use only a disposable podcast. Unfollowing it removes its local catalog.

- [ ] Follow the disposable podcast and wait for it to reach both devices.
- [ ] Start one of its episodes on iPhone.
- [ ] Put Mac offline, unfollow the podcast there, then reconnect.
- [ ] Confirm iPhone playback stops safely and Earshot remains responsive.
- [ ] Confirm the podcast disappears from both devices.
- [ ] Confirm later pause or seek actions do not recreate it.
- [ ] Record whether any downloaded file remains.

## Send back

For each failed checkbox, send the test number, device, local time, what
VoiceOver said, the value on each device, and whether relaunch changed the
result. A screenshot is optional; the spoken text and exact values are the
important evidence.

If all tests pass, #816 can close and production-schema review under #817 is the
next gate.
