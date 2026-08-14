# Build 198 concurrent remote-unfollow retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Builds 196 and 197 deleted the SwiftData episode graph before SwiftUI and
VoiceOver finished dismissing the visible episode list. Build 198 changes the
ordering: the remote tombstone synchronously stops playback and dismisses the
matching destination, waits 750 milliseconds for the UI transition, rechecks
that the tombstone still wins, and only then performs the cascade delete.

## Regression gate

- [ ] Follow a disposable podcast and refresh its catalog on both devices.
- [ ] On iPhone, play an episode and remain on that podcast's episode list.
- [ ] Put Mac offline, unfollow the podcast there, and reconnect.
- [ ] Confirm playback stops without another interruption.
- [ ] Confirm Earshot remains foregrounded and responsive.
- [ ] Confirm the stale episode screen dismisses automatically.
- [ ] Record the exact VoiceOver announcement and resulting focus location.
- [ ] Confirm the podcast disappears from both devices without resurrection.

Build 197 failure: `Earshot-2026-08-14-125400.ips`, SIGTRAP on the main thread
in `Episode.isPlayed.getter` from `EpisodeRow.accessibilityLabel.getter`. The
guard/deletion race proves the fix must order dismissal before deletion rather
than attempt another read-time guard.

## Physical result

Build 198 passed the crash regression on iPhone: the Mac's offline unfollow
synced after reconnect, playback stopped, and Earshot remained foregrounded.
The tester was viewing the full Now Playing sheet rather than the podcast episode
list; that sheet remained open after its episode unloaded. Build 199 addresses
that remaining stale-presentation behavior.
