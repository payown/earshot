# Build 199 remote-unfollow presentation retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 198 passed the crash regression: playback stopped and Earshot remained
foregrounded. The full Now Playing sheet remained visible after its episode was
unloaded, however. Build 199 dismisses that sheet when the player's observed
episode identity clears.

## Regression gate

- [ ] Follow a disposable podcast and refresh its catalog on both devices.
- [ ] On iPhone, play an episode and open the full Now Playing screen.
- [ ] Put Mac offline, unfollow the podcast there, and reconnect.
- [ ] Confirm playback stops without another interruption.
- [ ] Confirm Earshot remains foregrounded and responsive.
- [ ] Confirm the full Now Playing screen dismisses automatically.
- [ ] Record the exact VoiceOver announcement and resulting focus location.
- [ ] Confirm the podcast disappears from both devices without resurrection.
