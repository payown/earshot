# Build 194 auto-queue sync retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 194 fixes the missing CloudKit projection notification for queue items
created by refresh-time auto-queue. Do not deploy the production CloudKit
schema during this test.

## Preserve the build 193 evidence

Before installing, record that the iPhone has 23 queue items and the Mac has 22,
with `5PM ET 08/13/2026 Newscast` present only on iPhone. The build 194 test does
not require deleting or reordering that item.

## Auto-queue export gate

- [ ] Confirm build 194 and iCloud Sync `Available` on both devices.
- [ ] Leave auto-queue enabled for the existing test podcast.
- [ ] Refresh that podcast on iPhone and wait for a genuinely new episode to be
  auto-queued. Do not add it manually.
- [ ] Record its title, iPhone queue position/count, and time.
- [ ] Leave Earshot open on Mac and confirm the auto-queued episode arrives
  without relaunching.
- [ ] Record the Mac queue position/count, arrival time, and VoiceOver output.
- [ ] Repeat in the opposite direction if another genuinely new episode is
  available; otherwise the iPhone-to-Mac direction is the regression gate.

If the new auto-queued episode reaches Mac, resume the remaining build 193
tests beginning with synced-subscription refresh. The pre-existing 23-versus-22
item is retained as diagnostic evidence and is not itself expected to be
backfilled by this event-driven fix.
