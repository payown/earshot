# Build 275 TestFlight handoff

Version 1.2.5, build 275, Chapter 96. App Store Connect build
`08452fd7-bfc0-4d1e-8f82-58adf0828b0a` processed as `VALID` on
2026-10-08. PR: https://github.com/payown/earshot/pull/998 .

## Changes

- An off-default Playback option retains queued episodes after natural completion. Automatic advance skips completed entries; explicit replay and download cleanup remain separate.
- VoiceOver actions move episode rows to either end of their current podcast or folder group, and group headings move whole groups to either end.
- Pick up, drop before/after, and cancel actions support exact placement of episodes within their current group or whole groups among groups.
- Cloud Queue reconciliation preserves a retained episode's played state during a remote membership refresh.
- No persistence schema change was added.

## Verification

- Focused Queue, playback, action, and Cloud projection tests passed on simulator, including persisted ordering and remote refresh of a retained played row.
- The Keep finished setting UI test passed.
- Independent subagent review found a stale episode capture in the new rotor action; the action now resolves both live rows when activated, and the fix was re-reviewed.
- Physical-device VoiceOver placement, focus, and responsiveness checks remain for tester acceptance. Michael's phone was unavailable to the local device tools during this handoff.

## Distribution

- The first 1.2.4 (275) upload failed Apple's closed prerelease train validation; it was never distributed. Version 1.2.5 (275) is the accepted build.
- The `en-US` What to Test notes match `build-275-notes.txt` (Apple trims its final newline). The full chapter is also in `docs/kashe.md`.
- Internal Testing Group has all-build access and build 275 is `IN_BETA_TESTING` internally.
- Public Testers has explicit build 275 membership. External beta review was submitted on 2026-10-08 and is `WAITING_FOR_REVIEW`; its build state is `WAITING_FOR_BETA_REVIEW`, so external availability is not yet confirmed.
- Automatic tester notification is enabled. The distribution command reported `notified: false` with `notificationAction: auto_notify_enabled`; individual delivery has not been verified.
