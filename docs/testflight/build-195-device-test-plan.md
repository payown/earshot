# Build 195 single-podcast auto-queue retest

- Owner: Michael Babcock
- Tracking issue: #816
- Environment: CloudKit Development only

Build 195 wires the podcast-detail Refresh button into Auto-Queue. Build 194
already verified that background auto-queued episodes publish through CloudKit.
Do not deploy the production CloudKit schema during this test.

## Regression gate

- [ ] Keep Earshot closed on Mac before the next Fox News Hourly Update episode
  is published.
- [ ] On iPhone, confirm Fox News Hourly Update has Auto-Queue on.
- [ ] Use the podcast-detail Refresh button after the new episode is available.
- [ ] Confirm the genuinely new episode enters the iPhone Queue automatically;
  do not add it manually.
- [ ] Record its title, position/count, time, and VoiceOver output.
- [ ] Open build 195 on Mac and confirm the episode arrives through iCloud.
- [ ] Record the Mac position/count, arrival time, and VoiceOver output.

The 11AM ET 08/14/2026 episode was consumed by the build 194 failing path and
will not be retroactively auto-queued. Use the next genuinely new episode.
