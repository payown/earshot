# Build 197 concurrent remote-unfollow retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 196 dismissed the stale podcast screen but crashed during its outgoing
transition when VoiceOver requested an episode row's accessibility label after
SwiftData had deleted that episode. Build 197 suppresses deleted episode rows at
the row, visual-content, accessibility-label, accessibility-value, and selection
boundaries.

## Regression gate

- [ ] Follow a disposable podcast and refresh its catalog on both devices.
- [ ] On iPhone, play an episode and remain on that podcast's episode list.
- [ ] Put Mac offline, unfollow the podcast there, and reconnect.
- [ ] Confirm playback stops without another interruption.
- [ ] Confirm Earshot remains foregrounded and responsive.
- [ ] Confirm the stale episode screen dismisses automatically.
- [ ] Record the exact VoiceOver announcement and resulting focus location.
- [ ] Confirm the podcast disappears from both devices without resurrection.

Build 196 failure: `Earshot-2026-08-14-122914.ips`, SIGTRAP on the main
thread in `Episode.isPlayed.getter`, called by
`EpisodeRow.accessibilityLabel.getter` during the deletion transition.
