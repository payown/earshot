# Build 199 remote-unfollow presentation retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 198 passed the crash regression: playback stopped and Earshot remained
foregrounded. The full Now Playing sheet remained visible after its episode was
unloaded, however. Build 199 dismisses that sheet when the player's observed
episode identity clears.

## Regression gate

- [x] Follow a disposable podcast and refresh its catalog on both devices.
- [x] On iPhone, play an episode and open the full Now Playing screen.
- [x] Put Mac offline, unfollow the podcast there, and reconnect.
- [x] Confirm playback stops without another interruption.
- [x] Confirm Earshot remains foregrounded and responsive.
- [x] Confirm the full Now Playing screen dismisses automatically.
- [ ] Record the exact VoiceOver announcement and resulting focus location.
- [x] Confirm the podcast disappears from both devices without resurrection.

## Physical result

Build 199 passed on the real iPhone/Mac Development pair. Playback stopped,
Earshot remained foregrounded, and the full Now Playing sheet dismissed cleanly.
The Mac application store no longer contained Swift over Coffee, its cloud row
was tombstoned, and no new Earshot crash report appeared on the iPhone. Michael
reported that the flow "worked perfectly." Exact VoiceOver announcement/focus
wording remains to be recorded.
