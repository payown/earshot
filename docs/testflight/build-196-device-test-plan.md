# Build 196 concurrent remote-unfollow retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 196 guards the visible episode list when another device deletes its
podcast. Do not deploy the production CloudKit schema during this test.

## Regression gate

- [ ] Follow a disposable podcast and wait for its catalog to reach both devices.
- [ ] On iPhone, open that podcast and start one episode.
- [ ] Put Mac offline, unfollow the podcast there, and reconnect.
- [ ] Confirm iPhone playback stops safely and Earshot remains foreground and
  responsive instead of returning to the Home Screen.
- [ ] Confirm the stale episode screen dismisses without VoiceOver focus loss or
  duplicate announcements.
- [ ] Confirm the podcast disappears from both devices.
- [ ] Confirm later pause or seek actions do not recreate the podcast.
- [ ] Record whether any downloaded file remains.

The build 195 failure produced `Earshot-2026-08-14-102655.ips`: SIGTRAP on the
main thread in `EpisodeListView.unplayedCount`, reached while faulting the
deleted podcast's `episodes` relationship.
